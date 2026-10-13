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
    static let hoverDepth: Float = 0.08    // approach band: highlight before the touch
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
    /// How long a fired key stays lit, seconds -- the press flash window
    /// `WristCommFeedback`'s last fire is read against. Shorter than
    /// `cooldown` deliberately: the flash must have finished before the
    /// same key can fire again, so two presses read as two flashes.
    static let pressFlash: Double = 0.25

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

    /// The communicator's player-adjusted placement: `origin` shifted along
    /// the wrist frame's own axes and the frame pitched about its `right`,
    /// from the four `VRSettings.wristComm*` dials.
    ///
    /// Both halves come back TOGETHER, as one resolved pair, because they are
    /// only ever correct together: the renderer feeds this single result to
    /// the drawn quads, to the hover highlight and to the published
    /// `WristCommGeometry` side, so a dialled panel is hit-tested where the
    /// eye sees it. (The same three-path discipline `commWristFrame`'s doc
    /// comment states for the occlusion hold -- the dials are a second way to
    /// move the plane, and would break it exactly as a stale frame would.)
    ///
    /// Sign conventions, both chosen for how the dial reads in the headset:
    ///
    ///  * `fwd`/`side`/`up` are metres along `forward`/`right`/`up`. `forward`
    ///    is the unit vector from the wrist TOWARD the eye (see the renderer's
    ///    `wristFrame`), so +fwd brings the unit closer to your face.
    ///  * `tiltDegrees` is a POSITIVE rotation about `right`, which pitches
    ///    the TOP of the panel toward the viewer (at +90 the panel's `up`
    ///    lies along `forward`). That is the direction a forearm-strapped
    ///    unit has to lean to face a head looking down at it.
    ///
    /// `right` is deliberately untouched: it is the tilt axis, and it is also
    /// the axis the six keys are laid out along, so leaving it alone keeps the
    /// grid's columns where the hand learned them. `frame.origin` is untouched
    /// too -- that is the WRIST plane's own origin (the HUD tiles hang off it);
    /// the communicator's centre is the separate `origin` returned here, which
    /// is the only point the hit-test projects against.
    ///
    /// An invalid (untracked) frame passes through whole, dials ignored: there
    /// is no plane to move, and translating a zero frame would hand the touch
    /// loop a grid floating where no wrist is. At all-zero dials this is the
    /// identity, so the tuned-on-device behaviour is literally unchanged until
    /// a dial moves.
    static func adjustedFrame(_ frame: HudEditor.WristFrame, origin: SIMD3<Float>,
                              tiltDegrees: Float, fwd: Float, side: Float,
                              up: Float) -> (frame: HudEditor.WristFrame, origin: SIMD3<Float>) {
        guard frame.valid else { return (frame, origin) }

        let moved = origin + frame.right * side + frame.up * up + frame.forward * fwd
        guard tiltDegrees != 0 else {
            return (frame, moved)
        }

        // Rodrigues about `right`, written out rather than via simd_quatf so
        // the host test harness needs nothing but simd's free functions: for a
        // unit axis perpendicular to v, v' = v cos + (axis x v) sin.
        let angle = tiltDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize(v * c + simd_cross(frame.right, v) * s)
        }
        var tilted = frame
        tilted.up = rotate(frame.up)
        tilted.forward = rotate(frame.forward)
        return (tilted, moved)
    }

    /// The hovered cell AND which fingertip produced it, from one entry per
    /// tracked tip (`nil` = that tip is not over the grid; index 0 = left,
    /// 1 = right, the order `FingerTips` publishes).
    ///
    /// The cell is the MINIMUM hovered cell, which is exactly what the
    /// renderer's previous `.min()` picked, so the drawn highlight is
    /// unchanged by this existing; the point of the helper is the second
    /// half, the tip, which is the hand the finger wireframe is drawn on. A
    /// tie on one cell breaks to the lower tip index, so two hands over the
    /// same key cannot alternate the wire between them frame to frame --
    /// deterministic for the same reason the `.min()` was.
    static func hoverPick(_ cells: [Int?]) -> (cell: Int, tip: Int)? {
        var best: (cell: Int, tip: Int)?
        for (tip, cell) in cells.enumerated() {
            guard let cell else { continue }
            if best == nil || cell < best!.cell { best = (cell, tip) }
        }
        return best
    }

    /// The cell a world point lands on within `depth` of the grid plane, or
    /// nil (untracked wrist, off the grid laterally, or too far off the
    /// plane). The ONE hit-test body: `touchedCell` and `hoveredCell` are
    /// the same test at two depths, so a change to the grid's lateral
    /// bounds or its row/column rounding can never apply to the press but
    /// not the highlight -- which would light one key and fire another.
    private static func cell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                             frame: HudEditor.WristFrame, depth: Float) -> Int? {
        guard frame.valid else { return nil }
        let local = HudEditor.offsetInFrame(point: p, origin: commOrigin,
                                            right: frame.right, up: frame.up, forward: frame.forward)
        guard abs(local.x) <= gridHalfX, abs(local.y) <= gridHalfY,
              abs(local.z) <= depth else { return nil }
        let col = min(max(Int((local.x / cellPitch + Float(cols - 1) * 0.5).rounded()), 0), cols - 1)
        let row = min(max(Int((Float(rows - 1) * 0.5 - local.y / cellPitch).rounded()), 0), rows - 1)
        return row * cols + col
    }

    /// The cell a world point touches, or nil (off the grid or off the plane).
    static func touchedCell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                            frame: HudEditor.WristFrame) -> Int? {
        cell(p, commOrigin: commOrigin, frame: frame, depth: touchDepth)
    }

    /// The cell a world point is APPROACHING -- the same grid test as
    /// `touchedCell`, bounded by the wider `hoverDepth` instead. Feedback
    /// only: the renderer brightens this key so a fingertip on its way in
    /// can see which one it is about to press, several centimetres before
    /// `touchedCell` (and therefore the fire gate) agrees. `touchDepth` is
    /// a strict subset of `hoverDepth`, so a key being pressed is always
    /// also hovered and never flickers un-highlighted on the way down.
    static func hoveredCell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                            frame: HudEditor.WristFrame) -> Int? {
        cell(p, commOrigin: commOrigin, frame: frame, depth: hoverDepth)
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

    /// The one "panel in use" predicate for a single published side: up
    /// (`enabled`) and faded in at least to the fire floor. Both
    /// `WristCommInput.anySideQualifies` and `HandInput.wristCommInUse`
    /// `.contains` their own `WristCommGeometry.Side` arrays through this,
    /// so there is exactly one definition of "the panel is up" -- a second
    /// opinion here would hold turning on frames where no key could be
    /// pressed, or free it on frames where one could.
    static func sideQualifies(enabled: Bool, opacity: Float) -> Bool {
        enabled && opacity >= fireRevealFloor
    }
}
