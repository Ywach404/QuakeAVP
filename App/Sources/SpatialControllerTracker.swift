//
//  SpatialControllerTracker.swift
//
//  6DOF poses for PSVR2 Sense controllers through ARKit's accessory
//  tracking. Runs its own ARKitSession (the render thread owns the world
//  tracking one); the anchor loop stores the latest per-hand transform in
//  tracking-origin space behind a lock.
//
//  M6: the render thread reads the dominant controller's pose each frame and
//  feeds it to the engine as the aim (QC_InputSetAim), so a Sense controller
//  aims the gun exactly as a hand does. The off-hand pose still anchors the
//  weapon wheel. Chirality is resolved by live X position (isLeft), not
//  ARKit's undocumented inherentChirality.
//

import ARKit
import GameController
import simd

final class SpatialControllerTracker: @unchecked Sendable {

    static let shared = SpatialControllerTracker()

    private let lock = NSLock()
    private var _leftPose: simd_float4x4?
    private var _rightPose: simd_float4x4?
    private var _tracking = false
    /// ARKit's inherentChirality per controller -- a fallback only; it's
    /// undocumented for PSVR2 and often resolves to .none, which is why the
    /// old routing fell through to the connection-order coin flip.
    private var _chirality: [ObjectIdentifier: Bool] = [:]
    /// The far more reliable signal: each controller's live X in the tracking
    /// frame (+X is right). Whichever is further left IS the left hand, no
    /// matter how the pair paired. Keyed by the accessory the anchor carries.
    private var _controllerForAccessory: [Accessory.ID: ObjectIdentifier] = [:]
    private var _posX: [ObjectIdentifier: Float] = [:]

    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    var isTracking: Bool {
        lock.lock(); defer { lock.unlock() }
        return _tracking
    }

    /// Latest pose in tracking-origin space, or nil while untracked.
    func pose(left: Bool) -> simd_float4x4? {
        lock.lock(); defer { lock.unlock() }
        return left ? _leftPose : _rightPose
    }

    /// Which hand this controller is, or nil if not yet known (caller falls
    /// back to the GameController guess). Prefers live position -- the
    /// left-most controller is the left hand -- over ARKit's chirality.
    func isLeft(_ controller: GCController) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(controller)
        if let myX = _posX[key], let otherX = _posX.first(where: { $0.key != key })?.value {
            return myX < otherX     // +X is right, so smaller X = left hand
        }
        return _chirality[key]      // fallback until both are tracked
    }

    /// Restart tracking for the current accessory set. Main-actor callers
    /// (GameControllerInput) hand over the controllers; an empty set stops.
    func setControllers(_ controllers: [GCController]) {
        task?.cancel()
        task = nil
        session?.stop()
        session = nil
        setTracking(false)

        guard !controllers.isEmpty else { return }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                var accessories: [Accessory] = []
                for controller in controllers {
                    let accessory = try await Accessory(device: controller)
                    accessories.append(accessory)
                    let key = ObjectIdentifier(controller)
                    let chir = accessory.inherentChirality
                    print("[input] accessory \(controller.vendorName ?? "?") chirality=\(chir)")
                    self.lock.lock()
                    self._controllerForAccessory[accessory.id] = key
                    if chir == .left || chir == .right { self._chirality[key] = chir == .left }
                    self.lock.unlock()
                }
                let provider = AccessoryTrackingProvider(accessories: accessories)
                let session = ARKitSession()
                self.session = session
                try await session.run([provider])
                self.setTracking(true)
                for await update in provider.anchorUpdates {
                    if Task.isCancelled { break }
                    self.store(update.anchor)
                }
            } catch {
                print("[input] accessory tracking unavailable: \(error)")
            }
            self.setTracking(false)
        }
    }

    private func store(_ anchor: AccessoryAnchor) {
        let xform = anchor.originFromAnchorTransform
        lock.lock()
        // Track each controller's X so isLeft() can compare positions.
        if let key = _controllerForAccessory[anchor.accessory.id] {
            _posX[key] = xform.columns.3.x
        }
        // Pose slots still labelled by chirality (only the aim work reads them).
        if anchor.accessory.inherentChirality == .left {
            _leftPose = xform
        } else {
            _rightPose = xform
        }
        lock.unlock()
    }

    private func setTracking(_ value: Bool) {
        lock.lock()
        _tracking = value
        if !value {
            _leftPose = nil
            _rightPose = nil
            _chirality.removeAll()
            _controllerForAccessory.removeAll()
            _posX.removeAll()
        }
        lock.unlock()
    }
}
