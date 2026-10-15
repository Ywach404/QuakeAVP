// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WheelState.swift
//
//  The weapon wheel's input-side brain. Hold sources (palm-up hands, a
//  held Sense face button) merge here; the wrist anchor arrives in tracking
//  space and leaves for the engine as body-frame Quake units through
//  QC_InputSetWheel. On open the ring locks at the wrist's opening pose and
//  the highlight is read from how far the wrist has since travelled in the
//  ring plane -- reach toward a weapon to pick it. Committing sends
//  `impulse N` through the one existing console route -- no second path in.
//
//  Highlight math mirrors the engine's ring layout exactly: owned weapons
//  in impulse order, item k at (90 - k*step) degrees in the plane spanned
//  by body-right and world-up. Both sides derive the owned set from
//  cl.items (published in the packet), so they cannot disagree about what
//  the ring contains. (Sense controllers still ray-point via setPointer.)
//
//  Body-frame convention throughout: SIMD3(fwd, right, up), Quake units.
//

import Foundation
import GameController
import QuartzCore
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
    /// Where the wrist was when the wheel opened. The ring locks here (the
    /// engine freezes its world pose to match); selection then reads off how
    /// far the wrist has travelled from this point.
    private var lockedAnchor: SIMD3<Float>?
    private var highlight = -1
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

    /// Metres per Quake unit, latest from the packet — shared so other input
    /// sources (the M6 hand aim) can place body-frame points in Quake units.
    var currentWorldScale: Float {
        lock.lock(); defer { lock.unlock() }
        return worldScale
    }

    // MARK: - Hold / commit

    /// Selection: move the pointer onto a slot to HIGHLIGHT it, then release
    /// the hold to commit that slot -- see setHold below. Point-dwell came
    /// first (VRChat's gauge idea: rest on a slot for `dwellTime` and the
    /// weapon swaps live, in front of you), but the slightest jitter reset
    /// the timer and it never fired. `dwellTime` and the three fields under
    /// it are what is left of that; nothing reads them now.
    private static let dwellTime = 0.28
    private var dwellSlot = -1
    private var dwellSince = 0.0
    private var committedSlot = -1

    func setHold(_ on: Bool, source: Source) {
        lock.lock()
        let wasOpen = !holds.isEmpty
        if on { holds.insert(source) } else { holds.remove(source) }
        let nowOpen = !holds.isEmpty
        if !wasOpen, nowOpen {
            highlight = -1
            dwellSlot = -1
            committedSlot = -1
            lockedAnchor = nil      // re-locks to wherever the wrist is next frame
        }
        // Commit on RELEASE: hold to open, aim at a weapon, let go to pick.
        // (Dwell-while-held kept resetting on the slightest jitter and never
        // fired.) The full menu commits engine-side, so skip it there.
        var releaseImpulse: Int?
        if wasOpen, !nowOpen {
            lockedAnchor = nil
            if !VRSettings.shared.fullMenu, highlight >= 0 {
                releaseImpulse = impulseForOwnedIndex(highlight)
            }
        }
        lock.unlock()
        if let impulse = releaseImpulse { sendCommand?("impulse \(impulse)\n") }
        push()

        if on, source == .sense { startSensePump() }
        if !on, source == .sense { sensePump?.cancel(); sensePump = nil }
    }

    /// No-op: the commit is on release (setHold) now, not dwell. Kept as a
    /// hook the selection paths still call so their call sites stay unchanged.
    private func considerDwellLocked(now: Double) { }

    // MARK: - Geometry (tracking space in, body frame out)

    /// Off-hand wrist position, tracking space metres, ALREADY corrected
    /// by TrackingSpace.correction.
    /// Stand the ring off in front of the hand and lift it toward eye level.
    /// Pinned right on the wrist (held low, near the body) it lands too close
    /// and too low to select comfortably. This is a CONSTANT body-frame
    /// offset (x = forward, z = up), so it moves the whole ring -- the engine
    /// draws it here and the pointer/ray select against it -- while the
    /// wrist-travel highlight, which is anchor-RELATIVE, is unchanged (the
    /// constant cancels in live - locked).
    private static let placeForward: Float = 16   // ~0.4 m out along the gaze
    private static let placeUp: Float = 10         // ~0.25 m up toward eye level

    func setAnchor(trackingPosition p: SIMD3<Float>) {
        lock.lock()
        let body = SIMD3(-p.z / worldScale + Self.placeForward,
                         p.x / worldScale,
                         p.y / worldScale + Self.placeUp)
        anchor = body
        if !holds.isEmpty {
            // Wheel open: lock the ring at the wrist's opening pose, then read
            // the highlight from how far the whole hand has since moved in the
            // ring plane (body-right, world-up). Moving the wrist toward a
            // weapon selects it; a small deadzone ignores idle drift.
            if lockedAnchor == nil { lockedAnchor = body }
            let off = body - lockedAnchor!
            let r = off.y, u = off.z
            var next = -1
            let count = ownedCount()
            if count > 0, r * r + u * u > 4 {   // ~0.05 m of intent
                let angle = atan2(u, r) * 180 / .pi
                let step = 360 / Float(count)
                var k = Int(((90 - angle) / step).rounded())
                k %= count
                if k < 0 { k += count }
                next = k
            }
            if next != highlight { highlight = next }
            considerDwellLocked(now: CACurrentMediaTime())
        }
        pushLocked()
        lock.unlock()
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
        defer {
            if next != highlight { highlight = next; pushLocked() }
            considerDwellLocked(now: CACurrentMediaTime())
        }

        // Plain body plane, deliberately NOT tilted by the wheel trims: those
        // aim the drawn guide ring only. The weapons stay where they always
        // were, so what you point at must too.
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
                // Off hand anchors the ring, dominant hand points.
                let rightHanded = VRSettings.shared.rightHanded
                if let anchorPose = SpatialControllerTracker.shared.pose(left: rightHanded) {
                    let p = correction * anchorPose.columns.3
                    self.setAnchor(trackingPosition: SIMD3(p.x, p.y, p.z))
                }
                if let pointPose = SpatialControllerTracker.shared.pose(left: !rightHanded) {
                    let c = correction * pointPose
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
        // While open, feed the LOCKED pose so the engine's ring stays put;
        // the live wrist is used only for selection, above.
        let a = holds.isEmpty ? anchor : (lockedAnchor ?? anchor)
        QC_InputSetWheel(holds.isEmpty ? 0 : 1, a != nil ? 1 : 0,
                         a?.x ?? 0, a?.y ?? 0, a?.z ?? 0, Int32(highlight))
    }
}
