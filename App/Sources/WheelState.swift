//
//  WheelState.swift
//
//  The weapon wheel's input-side brain. Hold sources (palm-up hands, a
//  held Sense face button) merge here; the off-hand anchor and the pointer
//  ray arrive in tracking space and leave for the engine as body-frame
//  Quake units through QC_InputSetWheel. Committing sends `impulse N`
//  through the one existing console route -- no second path in.
//
//  Highlight math mirrors the engine's ring layout exactly: owned weapons
//  in impulse order, item k at (90 - k*step) degrees in the plane spanned
//  by body-right and world-up. Both sides derive the owned set from
//  cl.items (published in the packet), so they cannot disagree about what
//  the ring contains.
//
//  Body-frame convention throughout: SIMD3(fwd, right, up), Quake units.
//

import Foundation
import GameController
import simd

final class WheelState: @unchecked Sendable {

    static let shared = WheelState()

    enum Source: Hashable { case hands, sense }

    /// Ring order = impulse order 1...8.
    private static let bits: [UInt32] = [4096, 1, 2, 4, 8, 16, 32, 64]

    private let lock = NSLock()
    private var holds: Set<Source> = []
    private var items: UInt32 = 0
    private var worldScale: Float = 0.0254
    private var anchor: SIMD3<Float>?
    private var highlight = -1
    private var committed = false
    private var sensePump: Task<Void, Never>?

    /// Wired by the UI to the engine's console queue.
    nonisolated(unsafe) var sendCommand: (@Sendable (String) -> Void)?

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !holds.isEmpty
    }

    // MARK: - Packet facts (render thread)

    func frame(items: UInt32, worldScale: Float) {
        lock.lock()
        self.items = items
        if worldScale > 0 { self.worldScale = worldScale }
        lock.unlock()
    }

    // MARK: - Hold / commit

    func setHold(_ on: Bool, source: Source) {
        lock.lock()
        let wasOpen = !holds.isEmpty
        if on { holds.insert(source) } else { holds.remove(source) }
        let nowOpen = !holds.isEmpty
        var impulse: Int?
        if !wasOpen, nowOpen {
            committed = false
            highlight = -1
        }
        if wasOpen, !nowOpen, !committed, highlight >= 0 {
            impulse = impulseForOwnedIndex(highlight)
        }
        lock.unlock()
        push()

        if on, source == .sense { startSensePump() }
        if !on, source == .sense { sensePump?.cancel(); sensePump = nil }
        if let impulse { sendCommand?("impulse \(impulse)\n") }
    }

    /// Hands commit by pinching without closing the palm; the wheel stays
    /// open so you can watch the view weapon change in slow motion.
    func commitHighlight() {
        lock.lock()
        var impulse: Int?
        if !holds.isEmpty, !committed, highlight >= 0 {
            committed = true
            impulse = impulseForOwnedIndex(highlight)
        }
        lock.unlock()
        if let impulse { sendCommand?("impulse \(impulse)\n") }
    }

    // MARK: - Geometry (tracking space in, body frame out)

    /// Off-hand wrist position, tracking space metres, ALREADY corrected
    /// by TrackingSpace.correction.
    func setAnchor(trackingPosition p: SIMD3<Float>) {
        lock.lock()
        anchor = SIMD3(-p.z / worldScale, p.x / worldScale, p.y / worldScale)
        lock.unlock()
        push()
    }

    /// Pointer ray (corrected tracking space); updates the highlighted
    /// sector. Angle-only, so a slightly stale radius cannot mis-target.
    func setPointer(trackingOrigin o: SIMD3<Float>, direction d: SIMD3<Float>) {
        lock.lock()
        defer { lock.unlock() }
        guard let a = anchor, !holds.isEmpty else { return }
        let origin = SIMD3(-o.z / worldScale, o.x / worldScale, o.y / worldScale)
        let dir = SIMD3(-d.z, d.x, d.y)     // unit direction, body axes

        var next = -1
        defer { if next != highlight { highlight = next; pushLocked() } }

        guard dir.x > 0.05 else { return }
        let t = (a.x - origin.x) / dir.x
        guard t > 0 else { return }
        let hitR = origin.y + dir.y * t - a.y
        let hitU = origin.z + dir.z * t - a.z
        let count = ownedCount()
        guard count > 0, hitR * hitR + hitU * hitU > 9 else { return }
        let angle = atan2(hitU, hitR) * 180 / .pi
        let step = 360 / Float(count)
        var k = Int(((90 - angle) / step).rounded())
        k %= count
        if k < 0 { k += count }
        next = k
    }

    // MARK: - Sense pose pump

    /// While a Sense hold is active, poll the accessory tracker: left
    /// controller anchors the ring, the right one points.
    private func startSensePump() {
        sensePump?.cancel()
        sensePump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let correction = TrackingSpace.correction
                if let left = SpatialControllerTracker.shared.pose(left: true) {
                    let p = correction * left.columns.3
                    self.setAnchor(trackingPosition: SIMD3(p.x, p.y, p.z))
                }
                if let right = SpatialControllerTracker.shared.pose(left: false) {
                    let c = correction * right
                    let o = c.columns.3
                    let f = -c.columns.2    // controller forward = -z
                    self.setPointer(trackingOrigin: SIMD3(o.x, o.y, o.z),
                                    direction: simd_normalize(SIMD3(f.x, f.y, f.z)))
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: - Internals

    private func ownedCount() -> Int {
        Self.bits.reduce(0) { $0 + ((items & $1) != 0 ? 1 : 0) }
    }

    private func impulseForOwnedIndex(_ k: Int) -> Int? {
        var seen = 0
        for (i, bit) in Self.bits.enumerated() where (items & bit) != 0 {
            if seen == k { return i + 1 }
            seen += 1
        }
        return nil
    }

    private func push() {
        lock.lock()
        pushLocked()
        lock.unlock()
    }

    private func pushLocked() {
        let a = anchor
        QC_InputSetWheel(holds.isEmpty ? 0 : 1, a != nil ? 1 : 0,
                         a?.x ?? 0, a?.y ?? 0, a?.z ?? 0, Int32(highlight))
    }
}
