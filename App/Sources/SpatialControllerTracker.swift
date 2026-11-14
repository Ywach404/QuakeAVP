// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
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
import QuartzCore
import simd

final class SpatialControllerTracker: @unchecked Sendable {

    static let shared = SpatialControllerTracker()

    private let lock = NSLock()
    /// Poses keyed by controller, resolved to left/right by live X position in
    /// pose(left:). Storing by key rather than into left/right slots is the fix
    /// for PSVR2 chirality coming back .none: both controllers used to fall into
    /// the same slot, so pose(left:) returned the wrong hand (and the aim path
    /// reads pose(left:), so aim could track the wrong controller too).
    private var _poseForKey: [ObjectIdentifier: simd_float4x4] = [:]
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

    /// Latest pose in tracking-origin space, or nil while untracked. Resolved by
    /// live X (left-most controller IS the left hand) when both are tracked, the
    /// same reliable signal isLeft() uses; falls back to chirality, then to the
    /// only pose present (single controller).
    func pose(left: Bool) -> simd_float4x4? {
        lock.lock(); defer { lock.unlock() }
        // Two controllers: the smaller-X key is the left hand.
        if _posX.count >= 2 {
            let ascending = _posX.sorted { $0.value < $1.value }
            let key = left ? ascending.first!.key : ascending.last!.key
            return _poseForKey[key]
        }
        // One controller tracked: use chirality if known, else just return it.
        if let key = _chirality.first(where: { $0.value == left })?.key {
            return _poseForKey[key]
        }
        return _poseForKey.values.first
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

    /// How often the accessory stream actually delivers, per accessory.
    ///
    /// This number is the one thing that decides what the Sense controllers'
    /// judder actually is. The gun is deliberately not late-latched, so it
    /// moves at whatever rate its pose source updates: a stream near 90 Hz
    /// means the stream is fine and the consumer is resampling a stale cache,
    /// a stream at 30 or 60 means only prediction or interpolation can help,
    /// and the two have completely different fixes. Nothing in the app
    /// measured it, and the SDK does not document it.
    ///
    /// Counted here rather than at the aim feed, because the aim feed is
    /// called by the render thread and would read ~90 Hz no matter how slow
    /// this stream is: it would measure the poll, not the pose.
    private var rateCount: [Accessory.ID: Int] = [:]
    private var rateStart: [Accessory.ID: Double] = [:]

    private func noteRate(_ anchor: AccessoryAnchor) {
        guard VRSettings.shared.inputLog else { return }
        let id = anchor.accessory.id
        let now = CACurrentMediaTime()
        let start = rateStart[id] ?? now
        let n = (rateCount[id] ?? 0) + 1
        if now - start >= 1.0 {
            print(String(format: "[rate] accessory %@ %.1f Hz over %d update(s)",
                         String(describing: id), Double(n) / (now - start), n))
            rateCount[id] = 0
            rateStart[id] = now
        } else {
            rateCount[id] = n
            rateStart[id] = start
        }
    }

    private func store(_ anchor: AccessoryAnchor) {
        noteRate (anchor)
        let xform = anchor.originFromAnchorTransform
        lock.lock()
        // Store pose + X per controller; pose(left:) resolves handedness by X.
        if let key = _controllerForAccessory[anchor.accessory.id] {
            _posX[key] = xform.columns.3.x
            _poseForKey[key] = xform
        }
        lock.unlock()
    }

    private func setTracking(_ value: Bool) {
        lock.lock()
        _tracking = value
        if !value {
            _poseForKey.removeAll()
            _chirality.removeAll()
            _controllerForAccessory.removeAll()
            _posX.removeAll()
        }
        lock.unlock()
    }
}
