//
//  WristCommMath.swift
//
//  Pure wrist-communicator math: the 2x3 action grid seated below the HUD,
//  its touch hit-test, the edge/cooldown fire state machine, and the
//  reveal-on-glance decision. No engine, ARKit, or UI imports, so the
//  tools/check-swift-wristcomm.sh host harness compiles and runs it alone
//  (with HudEditorMath.swift, whose WristFrame/offsetInFrame/gridHalfY it
//  reuses).
//

import simd
import Foundation

enum WristComm {

    static let cols = 3, rows = 2
    static let cellSize: Float = 0.034     // metres, one action cell
    static let cellGap: Float = 0.006
    static let cellPitch: Float = cellSize + cellGap
    static let bezelPad: Float = 0.006     // bezel margin around the grid
    static let gridHalfX: Float = (Float(cols) * cellSize + Float(cols - 1) * cellGap) * 0.5
    static let gridHalfY: Float = (Float(rows) * cellSize + Float(rows - 1) * cellGap) * 0.5
    static let hudGap: Float = 0.012       // separation from the HUD grid above
    static let touchDepth: Float = 0.025   // fingertip must be this close to the plane
    static let cooldown: Double = 0.6      // per-cell re-fire gate, seconds
    static let revealOnCos: Float = 0.88   // ~28 deg: reveal when gaze this centred
    static let revealOffCos: Float = 0.82  // ~35 deg: hide past this (hysteresis)
    static let fireRevealFloor: Float = 0.6
    static let revealRate: Float = 8       // opacity lerp rate, 1/s
    /// How long a revealed side keeps using its last valid wrist frame after
    /// the live one goes invalid, seconds. The arm reaching to press a cell
    /// is exactly what hides that wrist from the cameras, and the editor's
    /// own latch in `wristFrames()` does not apply outside an edit session --
    /// so without this the panel fades out from under the fingertip. Bounded
    /// (not a permanent latch) because a wrist that has genuinely been
    /// lowered must still hide, and only ever applied while the side is above
    /// `fireRevealFloor`: a stale frame plus a blind touch must not fire.
    static let occlusionHold: Double = 0.25

    /// Cell N's centre in the comm's local right/up plane (row-major 2x3).
    static func cellCenter(_ index: Int) -> SIMD2<Float> {
        let row = index / cols, col = index % cols
        return SIMD2((Float(col) - Float(cols - 1) * 0.5) * cellPitch,
                     (Float(rows - 1) * 0.5 - Float(row)) * cellPitch)
    }

    /// The communicator's centre, seated below the HUD grid on the wrist plane.
    static func commOrigin(wrist: HudEditor.WristFrame) -> SIMD3<Float> {
        wrist.origin - wrist.up * (HudEditor.gridHalfY + hudGap + gridHalfY)
    }

    /// The cell a world point touches, or nil (off the grid or off the plane).
    static func touchedCell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                            frame: HudEditor.WristFrame) -> Int? {
        guard frame.valid else { return nil }
        let local = HudEditor.offsetInFrame(point: p, origin: commOrigin,
                                            right: frame.right, up: frame.up, forward: frame.forward)
        guard abs(local.x) <= gridHalfX, abs(local.y) <= gridHalfY,
              abs(local.z) <= touchDepth else { return nil }
        let col = min(max(Int((local.x / cellPitch + Float(cols - 1) * 0.5).rounded()), 0), cols - 1)
        let row = min(max(Int((Float(rows - 1) * 0.5 - local.y / cellPitch).rounded()), 0), rows - 1)
        return row * cols + col
    }

    /// Edge/cooldown fire gate. `touched` holds the cell under each tracked
    /// fingertip this tick (nil = none). A cell fires on a fingertip's rising
    /// edge into it, only while revealed; its cooldown then blocks re-fires,
    /// and holding never repeats.
    ///
    /// At most ONE cell fires per tick, deliberately: two fingertips entering
    /// two different cells within the same 90 Hz tick is not an interaction a
    /// hand can aim, and one command per tick keeps a fire unambiguously
    /// attributable to a single touch (the second entry is still recorded in
    /// `wasIn`, so it is consumed rather than deferred into a later tick).
    struct TouchState {
        var wasIn: [Int?] = [nil, nil]
        var cooldownUntil: [Double] = Array(repeating: 0, count: 6)
        /// False until this state's first `updateTouch` call. A fresh state
        /// arms wherever the fingers already happen to be (editor-close,
        /// idle->active, startup) -- without this, a finger already resting
        /// in a cell at that instant reads as a rising edge against `wasIn
        /// == nil` and fires the bound command unintended. The first call
        /// instead just RECORDS the current touches as the baseline.
        var seeded: Bool = false
    }

    static func updateTouch(state: TouchState, touched: [Int?], now: Double,
                            revealed: Bool) -> (state: TouchState, fire: Int?) {
        var next = state
        if next.wasIn.count != touched.count { next.wasIn = Array(repeating: nil, count: touched.count) }
        guard next.seeded else {
            next.wasIn = touched
            next.seeded = true
            return (next, nil)
        }
        var fire: Int? = nil
        for (i, cell) in touched.enumerated() {
            let was = i < state.wasIn.count ? state.wasIn[i] : nil
            next.wasIn[i] = cell
            guard revealed, let cell, cell != was, cell >= 0, cell < 6,
                  now >= next.cooldownUntil[cell], fire == nil else { continue }
            fire = cell
            next.cooldownUntil[cell] = now + cooldown
        }
        return (next, fire)
    }

    /// Reveal decision with hysteresis: ON past revealOnCos, OFF past
    /// revealOffCos, holds the current state in between.
    static func revealTarget(headPos: SIMD3<Float>, headForward: SIMD3<Float>,
                             commOrigin: SIMD3<Float>, wasRevealed: Bool) -> Bool {
        let to = commOrigin - headPos
        let len = simd_length(to)
        guard len > 1e-4 else { return wasRevealed }
        let aim = simd_dot(simd_normalize(headForward), to / len)
        if aim >= revealOnCos { return true }
        if aim <= revealOffCos { return false }
        return wasRevealed
    }

    static func smoothedOpacity(current: Float, target: Float, dt: Float) -> Float {
        let t = min(max(revealRate * dt, 0), 1)
        return current + (target - current) * t
    }

    /// The touch loop's fire gate: a cell with no bound command (or one
    /// that's only whitespace -- the same "unset" reading `WristCommStore.
    /// fire` already applies) is a no-op touch, not a blank line sent to
    /// the engine. Pure so the loop can check it before ever hopping to
    /// the main actor.
    static func shouldFire(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
