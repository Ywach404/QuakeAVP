//
//  SpatialControllerTracker.swift
//
//  6DOF poses for PSVR2 Sense controllers through ARKit's accessory
//  tracking. Runs its own ARKitSession (the render thread owns the world
//  tracking one); the anchor loop stores the latest per-hand transform in
//  tracking-origin space behind a lock.
//
//  Nothing consumes the poses yet: controller-aimed weaponry needs the
//  aim/body split in the packet (M6 — the same split hand-attached weapons
//  need). The tracker exists now so the input stack detects, authorizes,
//  and observes the accessories correctly, and so the poses are one field
//  read away when the aim work lands.
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
                    accessories.append(try await Accessory(device: controller))
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
        let left = anchor.accessory.inherentChirality == .left
        lock.lock()
        if left {
            _leftPose = anchor.originFromAnchorTransform
        } else {
            _rightPose = anchor.originFromAnchorTransform
        }
        lock.unlock()
    }

    private func setTracking(_ value: Bool) {
        lock.lock()
        _tracking = value
        if !value {
            _leftPose = nil
            _rightPose = nil
        }
        lock.unlock()
    }
}
