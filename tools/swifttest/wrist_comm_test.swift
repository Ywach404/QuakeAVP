// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  wrist_comm_test.swift
//
//  Host-run test for the wrist communicator's pure math
//  (App/Sources/WristCommMath.swift). Compiled and linked ALONE against
//  that file plus App/Sources/HudEditorMath.swift (whose WristFrame/
//  offsetInFrame/gridHalfY the comm math reuses) by
//  tools/check-swift-wristcomm.sh -- no ARKit/Metal/Observation, no
//  simulator, no app module.
//

import Foundation
import simd

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok:   \(label)")
    } else {
        print("FAIL: \(label)")
        exit(1)
    }
}

// `swiftc -O` compiles the stdlib's `assert(_:_:)` to a no-op (it only fires
// under `-Onone`), and check-swift-wristcomm.sh builds with `-O` -- so bare
// `assert(...)` calls below need their own override of the exact same shape
// as `check` or they'd pass vacuously no matter what the math does. This
// overload's concrete (non-autoclosure) `Bool`/`String` parameters win over
// the stdlib's autoclosure version for every call site here, so it's the one
// that actually runs.
func assert(_ condition: Bool, _ label: String) {
    check(condition, label)
}

// A `swiftc` multi-file compile only grants top-level executable statements
// to a file literally named `main.swift`; this file keeps its own name (it
// reads as a test, not an entry point) and wraps its body in `@main`
// instead, which is a declaration, not a top-level statement.
@main
struct WristCommMathTest {
    static func main() {
        runCommGeometryTests()
        runHoverTests()
        runTouchStateTests()
        runSeedingTests()
        runRevealTests()
        runFireGateTests()
        runSideQualifiesTests()
        runAdjustedFrameTests()
        runHoverPickTests()
        runOrientationTests()
        runForearmFrameTests()
        runAlongBaseFrameTests()
        runAlongSeatTests()
        print("PASSED (wrist_comm_test.swift)")
    }
}

// MARK: - Assert helpers

/// Concrete (non-autoclosure) approximate comparisons, for the same reason
/// `assert` above is redefined: `-O` must not be able to compile a check
/// away, and a vector comparison written inline at every call site is where
/// a transposed component hides.
func near(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool {
    simd_length(a - b) <= tol
}

/// A right-handed orthonormal wrist frame built the way the renderer's
/// `wristFrame` builds one (`RendererCore.billboardBasis` off world up, with
/// `forward` the unit vector from the wrist TOWARD the eye), so these tests
/// run against the same handedness the device does -- `right x up == forward`.
func testFrame(origin: SIMD3<Float>, toward: SIMD3<Float>) -> HudEditor.WristFrame {
    let forward = simd_normalize(toward)
    var right = simd_cross(SIMD3<Float>(0, 1, 0), forward)
    right = simd_length(right) < 1e-4 ? SIMD3<Float>(1, 0, 0) : simd_normalize(right)
    let up = simd_normalize(simd_cross(forward, right))
    return HudEditor.WristFrame(anchor: 0, origin: origin, right: right, up: up,
                                forward: forward, valid: true)
}

// MARK: - Comm grid geometry

func runCommGeometryTests() {
    assert(WristComm.cellCenter(0).x < 0 && WristComm.cellCenter(0).y > 0, "cell 0 up-left")
    assert(abs(WristComm.cellCenter(1).x) < 1e-5, "cell 1 middle column")
    assert(WristComm.cellCenter(5).x > 0 && WristComm.cellCenter(5).y < 0, "cell 5 down-right")

    let wf = HudEditor.WristFrame(anchor: 0, origin: .zero, right: SIMD3(1,0,0),
                                  up: SIMD3(0,1,0), forward: SIMD3(0,0,1), valid: true)
    let o = WristComm.commOrigin(wrist: wf, rollDegrees: 0)
    assert(o.y < -HudEditor.gridHalfY, "comm origin clears the HUD half-height")

    let c4 = WristComm.cellCenter(4)
    let p4 = o + SIMD3(c4.x, c4.y, 0)
    assert(WristComm.touchedCell(p4, commOrigin: o, frame: wf) == 4, "centre of cell 4 -> 4")
    assert(WristComm.touchedCell(p4 + SIMD3(0,0,0.2), commOrigin: o, frame: wf) == nil, "deep z misses")
    assert(WristComm.touchedCell(o + SIMD3(1,0,0), commOrigin: o, frame: wf) == nil, "far point misses")
    var bad = wf; bad.valid = false
    assert(WristComm.touchedCell(p4, commOrigin: o, frame: bad) == nil, "invalid frame never hits")
    print("comm geometry ok")
}

// MARK: - Hover approach band

func runHoverTests() {
    let wf = HudEditor.WristFrame(anchor: 0, origin: .zero, right: SIMD3(1,0,0),
                                  up: SIMD3(0,1,0), forward: SIMD3(0,0,1), valid: true)
    let o = WristComm.commOrigin(wrist: wf, rollDegrees: 0)

    // The band is strictly wider than the touch depth, or "hovering" and
    // "touching" would be the same state and there would be nothing to
    // highlight ahead of a press.
    assert(WristComm.hoverDepth > WristComm.touchDepth, "the hover band is deeper than the touch depth")

    // A fingertip approaching cell 4 head-on: inside the hover band, still
    // short of the touch depth. This is the whole point of the feature --
    // the key lights BEFORE it fires.
    let c4 = WristComm.cellCenter(4)
    let face = o + SIMD3(c4.x, c4.y, 0)
    let approaching = face + SIMD3<Float>(0, 0, 0.05)
    assert(WristComm.hoveredCell(approaching, commOrigin: o, frame: wf) == 4,
           "z = 0.05 hovers cell 4")
    assert(WristComm.touchedCell(approaching, commOrigin: o, frame: wf) == nil,
           "z = 0.05 does NOT touch cell 4 -- the hover band is what caught it")

    // Pressed against the face: both report the cell, so a pressed key is
    // never un-highlighted on the way down.
    let pressing = face + SIMD3<Float>(0, 0, 0.01)
    assert(WristComm.hoveredCell(pressing, commOrigin: o, frame: wf) == 4, "z = 0.01 hovers cell 4")
    assert(WristComm.touchedCell(pressing, commOrigin: o, frame: wf) == 4, "z = 0.01 touches cell 4")

    // Well off the plane: neither. The band is bounded, not a half-space --
    // a hand resting in the lap must not light the keys above it.
    let far = face + SIMD3<Float>(0, 0, 0.2)
    assert(WristComm.hoveredCell(far, commOrigin: o, frame: wf) == nil, "z = 0.2 hovers nothing")
    assert(WristComm.touchedCell(far, commOrigin: o, frame: wf) == nil, "z = 0.2 touches nothing")

    // Inside the band but off the grid laterally: the x/y bounds still apply.
    assert(WristComm.hoveredCell(o + SIMD3(1, 0, 0.05), commOrigin: o, frame: wf) == nil,
           "a point beside the grid never hovers, however close to the plane")

    // An untracked wrist has no plane to hover over.
    var bad = wf; bad.valid = false
    assert(WristComm.hoveredCell(approaching, commOrigin: o, frame: bad) == nil,
           "invalid frame never hovers")

    // Both edges of the band are symmetric about the plane -- a fingertip
    // that has pushed THROUGH the face (negative z) is still on the key.
    assert(WristComm.hoveredCell(face - SIMD3<Float>(0, 0, 0.05), commOrigin: o, frame: wf) == 4,
           "the band is symmetric about the plane")
    print("hover ok")
}

// MARK: - Touch fire state machine

func runTouchStateTests() {
    // A fresh TouchState must SEED on its first update rather than
    // edge-fire -- a finger already resting in a cell when the panel
    // arms (editor close, idle->active, startup) is "already in", not
    // "just arrived". Seed with no touch first, matching every real
    // reset path's actual first tick.
    var s = WristComm.updateTouch(state: WristComm.TouchState(), touched: [nil, nil],
                                  now: 9.9, revealed: true).state
    var r = WristComm.updateTouch(state: s, touched: [4, nil], now: 10.0, revealed: true)
    assert(r.fire == 4, "entering cell 4 fires it")
    s = r.state
    r = WristComm.updateTouch(state: s, touched: [4, nil], now: 10.05, revealed: true)
    assert(r.fire == nil, "holding does not re-fire")
    s = r.state
    s = WristComm.updateTouch(state: s, touched: [nil, nil], now: 10.1, revealed: true).state
    r = WristComm.updateTouch(state: s, touched: [4, nil], now: 10.2, revealed: true)
    assert(r.fire == nil, "re-entry inside the cooldown is blocked")
    s = r.state
    s = WristComm.updateTouch(state: s, touched: [nil, nil], now: 11.0, revealed: true).state
    r = WristComm.updateTouch(state: s, touched: [4, nil], now: 11.1, revealed: true)
    assert(r.fire == 4, "fresh entry after the cooldown fires")
    // The `revealed` gate, asserted so that the gate is demonstrably what
    // blocks the fire. A FRESH state returns on the seeding branch before
    // `guard revealed` is ever evaluated, so asserting against one proved
    // nothing -- deleting `revealed,` from the guard left it green. Seed
    // first (seeding ignores `revealed`), then run the SAME touch twice off
    // that one seeded state: hidden must not fire, revealed must.
    let gateSeed = WristComm.updateTouch(state: WristComm.TouchState(), touched: [nil, nil],
                                         now: 1.0, revealed: false).state
    let hidden = WristComm.updateTouch(state: gateSeed, touched: [0, nil], now: 1.1, revealed: false)
    assert(hidden.fire == nil, "hidden communicator never fires")
    let shown = WristComm.updateTouch(state: gateSeed, touched: [0, nil], now: 1.1, revealed: true)
    assert(shown.fire == 0, "the identical touch fires once revealed -- the gate is what blocked it")
    print("touch state ok")
}

// MARK: - Fresh-state seeding (absorb, don't edge-fire, a resting touch)

func runSeedingTests() {
    // A fresh TouchState seeing an already-present touch on its very
    // first update absorbs it instead of firing -- the fix for the
    // editor-close/idle->active/startup stale-edge bug.
    let seedResult = WristComm.updateTouch(state: WristComm.TouchState(), touched: [4, nil],
                                           now: 5.0, revealed: true)
    assert(seedResult.fire == nil, "fresh state absorbs an already-resting touch, never fires")

    // That same (now-seeded) state genuinely leaving and re-entering the
    // cell still fires -- seeding only swallows the very first update.
    let left = WristComm.updateTouch(state: seedResult.state, touched: [nil, nil],
                                     now: 5.1, revealed: true).state
    let reentry = WristComm.updateTouch(state: left, touched: [4, nil], now: 5.2, revealed: true)
    assert(reentry.fire == 4, "a genuine new entry after seeding still fires")
    print("seeding ok")
}

// MARK: - Reveal-on-glance hysteresis

func runRevealTests() {
    let origin = SIMD3<Float>(0, -0.3, -0.4)
    let head = SIMD3<Float>(0, 0, 0)
    let atIt = simd_normalize(origin - head)
    assert(WristComm.revealTarget(headPos: head, headForward: atIt, commOrigin: origin, wasRevealed: false),
           "looking straight at it reveals")
    assert(!WristComm.revealTarget(headPos: head, headForward: SIMD3(0, 0, -1),
                                   commOrigin: SIMD3(0, -0.6, -0.2), wasRevealed: false),
           "looking away stays hidden")
    // hysteresis: a direction whose dot with atIt lies between revealOffCos and
    // revealOnCos keeps its current state either way
    let mid = simd_normalize(atIt + SIMD3<Float>(0.6, 0, 0))  // tune so dot lands in (0.82, 0.88)
    let aim = simd_dot(mid, atIt)
    assert(aim > WristComm.revealOffCos && aim < WristComm.revealOnCos, "mid direction is in the hysteresis band")
    assert(WristComm.revealTarget(headPos: head, headForward: mid, commOrigin: origin, wasRevealed: true),
           "borderline keeps revealed")
    assert(!WristComm.revealTarget(headPos: head, headForward: mid, commOrigin: origin, wasRevealed: false),
           "borderline keeps hidden")
    print("reveal ok")
}

// MARK: - Fire gate

func runFireGateTests() {
    assert(!WristComm.shouldFire(""), "empty command never fires")
    assert(!WristComm.shouldFire("   "), "whitespace-only command never fires")
    assert(WristComm.shouldFire("god"), "non-empty command fires")
    // The reserved summon: it passes the fire gate like any other binding
    // (the touch is real), and `WristCommStore.fire` then routes it to the
    // window instead of the engine. Pinned here because the string is a
    // contract with r_null.c's vr_wristcomm_off_cmd5 default -- a typo on
    // either side presents as a dead MENU key.
    assert(WristComm.summonWindowCommand == "qavp_window",
           "the summon sentinel is qavp_window")
    assert(WristComm.shouldFire(WristComm.summonWindowCommand),
           "the summon sentinel passes the fire gate")
    assert(WristComm.isSummonWindow("qavp_window"), "the sentinel is recognised")
    assert(WristComm.isSummonWindow("  qavp_window  "),
           "recognised with surrounding whitespace, as shouldFire trims too")
    assert(!WristComm.isSummonWindow("togglemenu"),
           "an ordinary console command is not the sentinel")
    assert(!WristComm.isSummonWindow("qavp_window now"),
           "only the exact binding is the sentinel; anything else goes to the engine")
    print("fire gate ok")
}

// MARK: - Panel-in-use predicate (WristComm.sideQualifies)

func runSideQualifiesTests() {
    assert(!WristComm.sideQualifies(enabled: false, opacity: 1), "disabled never qualifies, however opaque")
    assert(WristComm.sideQualifies(enabled: true, opacity: WristComm.fireRevealFloor), "enabled at the floor qualifies")
    assert(!WristComm.sideQualifies(enabled: true, opacity: WristComm.fireRevealFloor - 0.01), "enabled just under the floor does not")
    print("side qualifies ok")
}

// MARK: - Placement dials (WristComm.adjustedFrame)

func runAdjustedFrameTests() {
    // An axis-aligned frame first (a transposed component is readable off the
    // numbers), then an oblique one (an axis-aligned frame cannot catch a
    // right/up/forward mix-up, since the dials move along the world axes too).
    let axis = testFrame(origin: SIMD3(0, 1.1, -0.4), toward: SIMD3(0, 0, 1))
    let oblique = testFrame(origin: SIMD3(0.2, 0.9, -0.35), toward: SIMD3(0.3, -0.5, 0.8))

    for (name, wf) in [("axis-aligned", axis), ("oblique", oblique)] {
        let o = WristComm.commOrigin(wrist: wf, rollDegrees: 0)

        // Zero adjustments must be the IDENTITY, bit-for-bit as far as these
        // tolerances see it. This is the "unchanged at zero" contract the
        // whole feature rests on: a communicator already tuned on device
        // must not move a millimetre until a dial is dragged.
        let zero = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 0, fwd: 0, side: 0, up: 0)
        assert(near(zero.origin, o, 1e-6), "\(name): zero adjust leaves the origin alone")
        assert(near(zero.frame.right, wf.right, 1e-6), "\(name): zero adjust leaves right alone")
        assert(near(zero.frame.up, wf.up, 1e-6), "\(name): zero adjust leaves up alone")
        assert(near(zero.frame.forward, wf.forward, 1e-6), "\(name): zero adjust leaves forward alone")
        assert(zero.frame.valid, "\(name): zero adjust keeps validity")

        // Each offset dial moves the grid centre along ITS OWN axis, by
        // exactly its own metres -- nothing else moves.
        let f = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 0, fwd: 0.04, side: 0, up: 0)
        assert(near(f.origin, o + wf.forward * 0.04), "\(name): +fwd moves along forward")
        assert(near(f.frame.up, wf.up, 1e-6), "\(name): +fwd does not rotate")
        let s = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 0, fwd: 0, side: -0.03, up: 0)
        assert(near(s.origin, o - wf.right * 0.03), "\(name): -side moves along -right")
        let u = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 0, fwd: 0, side: 0, up: 0.07)
        assert(near(u.origin, o + wf.up * 0.07), "\(name): +up moves along up")

        // All three at once compose, with no cross-talk between the axes.
        let all = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 0,
                                          fwd: 0.02, side: 0.05, up: -0.01)
        assert(near(all.origin, o + wf.forward * 0.02 + wf.right * 0.05 - wf.up * 0.01),
               "\(name): the three offsets compose")

        // Tilt is a rotation about `right`, and its SIGN CONVENTION is the
        // whole point of the dial: positive tilt pitches the TOP of the panel
        // TOWARD the viewer (`forward` is the unit vector from the wrist to
        // the eye), so at +90 deg the panel's up lies exactly along forward.
        let t90 = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 90, fwd: 0, side: 0, up: 0)
        assert(near(t90.frame.up, wf.forward, 1e-4), "\(name): +90 tilt maps up -> +forward")
        assert(near(t90.frame.forward, -wf.up, 1e-4), "\(name): +90 tilt maps forward -> -up")
        assert(near(t90.frame.right, wf.right, 1e-6), "\(name): tilt leaves right alone")
        assert(near(t90.origin, o, 1e-6), "\(name): tilt alone does not translate")

        // The same convention at a dialable angle, stated as the thing a
        // reader can check in the headset rather than as a matrix identity:
        // the top leans toward the eye, and the negative dial leans it away.
        let tp = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: 30, fwd: 0, side: 0, up: 0)
        let tn = WristComm.adjustedFrame(wf, origin: o, tiltDegrees: -30, fwd: 0, side: 0, up: 0)
        assert(simd_dot(tp.frame.up, wf.forward) > 0.49,
               "\(name): +30 tilt leans the top toward the viewer (sin 30)")
        assert(simd_dot(tn.frame.up, wf.forward) < -0.49,
               "\(name): -30 tilt leans the top away from the viewer")

        // The rotated basis must stay a usable frame: the hit-test projects
        // onto these axes (`HudEditor.offsetInFrame`), so a basis that has
        // drifted off unit length silently rescales the grid's own bounds.
        for (label, adj) in [("30", tp), ("-30", tn), ("90", t90)] {
            let r = adj.frame.right, a = adj.frame.up, fw = adj.frame.forward
            assert(near(simd_length(r), 1), "\(name)/\(label): right stays unit")
            assert(near(simd_length(a), 1), "\(name)/\(label): up stays unit")
            assert(near(simd_length(fw), 1), "\(name)/\(label): forward stays unit")
            assert(abs(simd_dot(r, a)) < 1e-4, "\(name)/\(label): right . up stays 0")
            assert(abs(simd_dot(a, fw)) < 1e-4, "\(name)/\(label): up . forward stays 0")
            assert(abs(simd_dot(r, fw)) < 1e-4, "\(name)/\(label): right . forward stays 0")
            // Still right-handed -- a flipped basis would mirror the grid and
            // put the labels on backwards while every dot check above passed.
            assert(near(simd_cross(r, a), fw, 1e-4), "\(name)/\(label): right x up stays forward")
        }

        // A tilted panel's own touch plane follows it: a point `fwd` out along
        // the ADJUSTED forward from the adjusted centre reads as on-plane
        // (local z == that offset), which is what makes one resolved frame
        // enough for draw, hover and hit-test alike.
        let probe = t90.origin + t90.frame.forward * 0.01
        let local = HudEditor.offsetInFrame(point: probe, origin: t90.origin,
                                            right: t90.frame.right, up: t90.frame.up,
                                            forward: t90.frame.forward)
        assert(near(local.z, 0.01) && near(local.x, 0) && near(local.y, 0),
               "\(name): the adjusted frame is the plane the hit-test projects onto")
        assert(WristComm.touchedCell(t90.origin, commOrigin: t90.origin, frame: t90.frame) == 4,
               "\(name): the adjusted centre still touches the centre key")
    }

    // An untracked wrist passes through UNTOUCHED, dials and all: there is no
    // plane to move, and fabricating one would hand the touch loop a grid
    // floating where no wrist is.
    var bad = axis
    bad.valid = false
    let passthrough = WristComm.adjustedFrame(bad, origin: SIMD3(1, 2, 3), tiltDegrees: 40,
                                              fwd: 0.1, side: 0.1, up: 0.1)
    assert(!passthrough.frame.valid, "an invalid frame stays invalid")
    assert(near(passthrough.origin, SIMD3(1, 2, 3), 1e-6), "an invalid frame's origin is untouched")
    assert(near(passthrough.frame.up, bad.up, 1e-6), "an invalid frame's up is untouched")
    assert(near(passthrough.frame.forward, bad.forward, 1e-6),
           "an invalid frame's forward is untouched")
    print("adjusted frame ok")
}

// MARK: - Which fingertip is hovering (WristComm.hoverPick)

func runHoverPickTests() {
    assert(WristComm.hoverPick([nil, nil]) == nil, "no tip over the grid picks nothing")
    assert(WristComm.hoverPick([]) == nil, "no tips at all picks nothing")

    let left = WristComm.hoverPick([3, nil])
    assert(left?.cell == 3 && left?.tip == 0, "the only hovering tip wins, and is reported")
    let right = WristComm.hoverPick([nil, 5])
    assert(right?.cell == 5 && right?.tip == 1, "tip 1 is reported as tip 1, not folded into 0")

    // Two tips over the grid at once is not an interaction anyone aims, but it
    // must not flicker frame to frame: the LOWEST cell wins, which is exactly
    // what the renderer's previous `.min()` picked, so the drawn highlight is
    // unchanged by this helper existing.
    let both = WristComm.hoverPick([4, 2])
    assert(both?.cell == 2 && both?.tip == 1, "the lowest cell wins however the tips are ordered")
    let mirrored = WristComm.hoverPick([2, 4])
    assert(mirrored?.cell == 2 && mirrored?.tip == 0, "and the same cell wins mirrored")
    assert(WristComm.hoverPick([4, 2])?.cell == [4, 2].compactMap { $0 }.min(),
           "the picked cell matches the plain min() the renderer used before")

    // Both tips on the SAME cell: the lower tip index breaks the tie, so the
    // finger model can never alternate hands under a two-handed hover.
    let tie = WristComm.hoverPick([1, 1])
    assert(tie?.cell == 1 && tie?.tip == 0, "a tie on one cell breaks to the lower tip index")
    print("hover pick ok")
}

// MARK: - Orientation: the free in-plane Rotate dial

/// Bit-identical component comparison, for the one claim a tolerance cannot
/// make: `rotate = 0` must be the EARLY-RETURN identity, not a rotation by
/// zero that happens to land within 1e-7. The across-wrist unit as tuned on
/// device is that path, and it must be untouched to the last bit.
func exact(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
    a.x == b.x && a.y == b.y && a.z == b.z
}

/// `WristComm.orientedFrame(_:rollDegrees:)` + the rotation-aware seating
/// (`commOrigin(wrist:rollDegrees:)`), which together are the whole of the
/// per-view Rotate dial -- the renderer applies them in its one placement
/// chain and everything else (cellCenter, touchedCell, the draw, the
/// published geometry) is unchanged, so what is pinned here IS the feature.
///
/// This replaces the round-4/5 `alongArm: Bool` pair. The Bool's two states
/// survive as the two DEFAULTS (across = 0 deg, along = +90 deg) and both
/// are pinned below against the exact mappings those two states shipped
/// with, so a continuous dial cannot quietly re-seat or re-orient a unit
/// already tuned on device.
func runOrientationTests() {
    let axis = testFrame(origin: SIMD3(0, 1.1, -0.4), toward: SIMD3(0, 0, 1))
    let oblique = testFrame(origin: SIMD3(0.2, 0.9, -0.35), toward: SIMD3(0.3, -0.5, 0.8))

    // The long axis IS the long one -- three columns against two rows. Every
    // claim below about "the long axis runs down the arm" rests on this, and
    // a future grid that was 3x3 would make the whole dial meaningless.
    assert(WristComm.gridHalfX > WristComm.gridHalfY, "the 3-key axis is the longer one")

    for (name, wf) in [("axis-aligned", axis), ("oblique", oblique)] {

        // MARK: 0 deg is the bit-identical identity

        // The ACROSS default. Not "within tolerance" -- the same floats back:
        // this is the unit already tuned on device, and the Rotate dial
        // arriving must not move it by an ulp.
        let across = WristComm.orientedFrame(wf, rollDegrees: 0)
        assert(exact(across.right, wf.right), "\(name): 0 deg leaves right bit-identical")
        assert(exact(across.up, wf.up), "\(name): 0 deg leaves up bit-identical")
        assert(exact(across.forward, wf.forward), "\(name): 0 deg leaves forward bit-identical")
        assert(exact(across.origin, wf.origin), "\(name): 0 deg leaves the origin bit-identical")
        assert(across.valid, "\(name): 0 deg keeps validity")
        assert(near(WristComm.commOrigin(wrist: wf, rollDegrees: 0),
                    wf.origin - wf.up * (HudEditor.gridHalfY + WristComm.hudGap + WristComm.gridHalfY),
                    1e-7),
               "\(name): 0 deg seats at the old across drop, unchanged")

        // MARK: +90 deg reproduces the old along-arm mapping EXACTLY

        // THE SIGN, which is the one thing in here a reader cannot derive:
        // at +90, `right' = +up`, `up' = -right`. Both halves are forced
        // together by handedness -- `right' x up' == forward` -- so the only
        // other candidate is the opposite pair (`-up`/`+right`), and these
        // are what choose between them:
        //
        //  * `right` is the axis `textQuads` lays glyphs along and the axis
        //    the three columns run along. With `right' = +up` the key run
        //    and the legend both read from the ELBOW end up toward the
        //    wrist -- cell 0 (cmd0, the first binding) furthest down the
        //    forearm, the keys counting toward the hand, and every legend
        //    reading the way a head looking down its own forearm reads.
        //    DEVICE-DECIDED: the opposite pair shipped first and read as
        //    upside down off a device screenshot, which is the only test
        //    this choice has.
        //  * `up' = -right` then puts the glyph tops toward the wrist
        //    frame's own LEFT, which is what handedness forces once the
        //    glyph advance is pinned -- the pair cannot be mixed.
        //
        // This is also the ALONG view's persisted default, so these two
        // assertions are what guarantee the Bool-to-degrees change is a
        // no-op for the current along-arm tuning.
        let along = WristComm.orientedFrame(wf, rollDegrees: 90)
        assert(near(along.right, wf.up, 1e-6), "\(name): +90 maps right -> +up (the old along pair)")
        assert(near(along.up, -wf.right, 1e-6), "\(name): +90 maps up -> -right (the old along pair)")
        assert(near(along.forward, wf.forward, 1e-7), "\(name): +90 leaves the panel normal alone")
        assert(near(along.origin, wf.origin, 1e-7), "\(name): the rotation does not translate")
        assert(along.valid, "\(name): +90 keeps validity")
        assert(near(WristComm.commOrigin(wrist: wf, rollDegrees: 90),
                    wf.origin - wf.up * (HudEditor.gridHalfY + WristComm.hudGap + WristComm.gridHalfX),
                    1e-6),
               "\(name): +90 seats at the old along drop, unchanged")

        // The long (3-key) axis runs ALONG the arm at +90: the panel's own
        // +x extent points along the wrist frame's +up, i.e. the glyph
        // advance runs back up the forearm toward the hand.
        assert(simd_dot(along.right, wf.up) > 0.999, "\(name): at +90 the long axis runs along the arm")

        // ...and cell 0 sits at the ELBOW end of it, not the wrist end --
        // the half of the sign choice the dot product above cannot see,
        // since the panel's extents are symmetric either way. The unit is
        // seated BELOW the wrist frame's origin (`commOrigin` subtracts
        // along `up`), so -up is further down the forearm and +up is back
        // toward the hand: cell 0 lowest, cell 5 nearest the wrist.
        let c0 = WristComm.cellCenter(0)
        let w0 = along.right * c0.x + along.up * c0.y
        assert(simd_dot(w0, wf.up) < 0, "\(name): at +90 cell 0 sits at the elbow end")
        let c5 = WristComm.cellCenter(5)
        let w5 = along.right * c5.x + along.up * c5.y
        assert(simd_dot(w5, wf.up) > 0, "\(name): at +90 cell 5 sits at the wrist end")

        // MARK: an orthonormal, right-handed frame at EVERY angle

        // The hit-test projects onto these axes (`HudEditor.offsetInFrame`),
        // so a basis off unit length silently rescales the grid's bounds,
        // and a LEFT-handed one would mirror every legend while all three
        // dot products still read zero. A free dial means this must hold
        // at the awkward angles too, not just the two the Bool had.
        for deg in [Float(-180), -137, -90, -37, 0, 1, 30, 45, 90, 137, 180] {
            let f = WristComm.orientedFrame(wf, rollDegrees: deg)
            let r = f.right, a = f.up, fw = f.forward
            assert(near(simd_length(r), 1), "\(name)/\(deg): right stays unit")
            assert(near(simd_length(a), 1), "\(name)/\(deg): up stays unit")
            assert(near(simd_length(fw), 1), "\(name)/\(deg): forward stays unit")
            assert(abs(simd_dot(r, a)) < 1e-5, "\(name)/\(deg): right . up stays 0")
            assert(abs(simd_dot(a, fw)) < 1e-5, "\(name)/\(deg): up . forward stays 0")
            assert(abs(simd_dot(r, fw)) < 1e-5, "\(name)/\(deg): right . forward stays 0")
            assert(near(simd_cross(r, a), fw, 1e-5), "\(name)/\(deg): right x up stays forward")
            assert(near(f.forward, wf.forward, 1e-6), "\(name)/\(deg): the panel normal never moves")
            assert(near(f.origin, wf.origin, 1e-7), "\(name)/\(deg): the rotation never translates")
        }

        // The rotation really is an in-plane rotation BY that angle, not a
        // snap: the turned `right` makes exactly the dialled angle with the
        // original one, swept toward `up`.
        for deg in [Float(30), 137] {
            let f = WristComm.orientedFrame(wf, rollDegrees: deg)
            let rad = deg * .pi / 180
            assert(near(simd_dot(f.right, wf.right), cos(rad), 1e-5),
                   "\(name)/\(deg): right turns by cos(theta) onto the old right")
            assert(near(simd_dot(f.right, wf.up), sin(rad), 1e-5),
                   "\(name)/\(deg): ...and by sin(theta) onto up -- the sweep goes right -> up")
        }

        // MARK: rotation-aware seating

        // Whichever way the unit is turned, its top edge sits exactly
        // `hudGap` below the HUD grid above it. The extent is read off the
        // ROTATED frame's OWN CORNERS rather than restated, so this fails if
        // the drop and the rotation ever disagree -- which is exactly what a
        // drop left at a fixed half-extent would be. This is the formula
        // `|sin t|*gridHalfX + |cos t|*gridHalfY` pinned by its meaning.
        for deg in [Float(-180), -137, -90, -45, 0, 30, 45, 60, 90, 137, 180] {
            let f = WristComm.orientedFrame(wf, rollDegrees: deg)
            let o = WristComm.commOrigin(wrist: wf, rollDegrees: deg)
            var top = -Float.greatestFiniteMagnitude
            for sx in [Float(-1), 1] {
                for sy in [Float(-1), 1] {
                    let corner = o + f.right * (sx * WristComm.gridHalfX)
                                   + f.up * (sy * WristComm.gridHalfY)
                    top = max(top, simd_dot(corner - wf.origin, wf.up))
                }
            }
            assert(near(top, -(HudEditor.gridHalfY + WristComm.hudGap), 2e-5),
                   "\(name)/\(deg): the unit's top edge sits hudGap below the HUD")
        }

        // The two old states are reproduced exactly, and a half-turn is
        // strictly OUTSIDE both of them: a dial that snapped to one state or
        // the other (or ignored the angle) would fail this even though both
        // endpoints above pass.
        func drop(_ deg: Float) -> Float {
            simd_dot(wf.origin - WristComm.commOrigin(wrist: wf, rollDegrees: deg), wf.up)
        }
        let d0 = drop(0), d45 = drop(45), d90 = drop(90)
        assert(near(d0, HudEditor.gridHalfY + WristComm.hudGap + WristComm.gridHalfY, 1e-5),
               "\(name): the 0 deg drop is the old across drop")
        assert(near(d90, HudEditor.gridHalfY + WristComm.hudGap + WristComm.gridHalfX, 1e-5),
               "\(name): the 90 deg drop is the old along drop")
        // NOT between the two endpoints: at 45 deg it is the rotated
        // rectangle's CORNER that reaches furthest down, and a corner is
        // further out than either half-edge. This is precisely why the
        // formula is a SUM of the two projected half-extents rather than a
        // choice between them -- a `max(gridHalfX, gridHalfY)` or a
        // nearest-state select would seat the unit too high here and let
        // the turned corner overlap the HUD, which is the bug the corner
        // sweep above catches and this one names.
        let corner = sqrt(WristComm.gridHalfX * WristComm.gridHalfX
                          + WristComm.gridHalfY * WristComm.gridHalfY)
        assert(d45 > d90 + 1e-4, "\(name): the 45 deg drop is deeper than BOTH endpoints")
        assert(near(d45 - d0 + WristComm.gridHalfY,
                    (WristComm.gridHalfX + WristComm.gridHalfY) * (sqrt(Float(2)) / 2), 1e-5),
               "\(name): the 45 deg extent is the two half-extents projected and summed")
        assert(d45 - d0 + WristComm.gridHalfY < corner + 1e-5,
               "\(name): ...and never beyond the unit's own corner radius")
        // Symmetric in the sign of the angle -- the unit's extent does not
        // care which way it was turned, which is what the two absolute
        // values in the formula are for.
        assert(near(drop(-45), d45, 1e-5), "\(name): the drop is symmetric about 0")
        assert(near(drop(-90), d90, 1e-5), "\(name): ...and at the quarter turn too")
        assert(near(drop(180), d0, 1e-5), "\(name): a half turn seats like no turn at all")

        // MARK: the composed chain -- a key fires where it lights

        // The rotation lives ENTIRELY in the frame: `cellCenter` and
        // `touchedCell` stay panel-local and unchanged, so every key's world
        // centre still hit-tests to its own index under a rotated frame.
        // Run at a NON-RIGHT angle on purpose: 90 deg permutes the axes and
        // would pass even if the hit-test secretly assumed an axis swap
        // rather than a general basis.
        for deg in [Float(37), 90] {
            let f = WristComm.orientedFrame(wf, rollDegrees: deg)
            let o = WristComm.commOrigin(wrist: wf, rollDegrees: deg)
            for cell in 0 ..< (WristComm.cols * WristComm.rows) {
                let c = WristComm.cellCenter(cell)
                let p = o + f.right * c.x + f.up * c.y
                assert(WristComm.touchedCell(p, commOrigin: o, frame: f) == cell,
                       "\(name)/\(deg): cell \(cell) hit-tests to itself")
            }

            // ...and through the user's dials too, which is the FULL chain
            // the renderer runs (orientedFrame -> commOrigin -> adjustedFrame).
            // A dialled, rotated unit is still hit-tested where it is drawn.
            let dialled = WristComm.adjustedFrame(f, origin: o, tiltDegrees: 20,
                                                  fwd: 0.01, side: -0.02, up: 0.015)
            for cell in 0 ..< (WristComm.cols * WristComm.rows) {
                let c = WristComm.cellCenter(cell)
                let p = dialled.origin + dialled.frame.right * c.x + dialled.frame.up * c.y
                assert(WristComm.touchedCell(p, commOrigin: dialled.origin,
                                             frame: dialled.frame) == cell,
                       "\(name)/\(deg): dialled cell \(cell) hit-tests to itself")
            }
        }

        // The dials act in the ROTATED unit's own axes, deliberately (the
        // rotation enters the chain BEFORE them): at +90 the tilt pitches
        // about the new right, which is the arm's long axis, and the
        // Side/Height offsets run down and across the arm respectively.
        // Pinned so the settings caption that says so cannot drift.
        let o90 = WristComm.commOrigin(wrist: wf, rollDegrees: 90)
        let side = WristComm.adjustedFrame(along, origin: o90, tiltDegrees: 0,
                                           fwd: 0, side: 0.03, up: 0)
        assert(near(side.origin, o90 + wf.up * 0.03),
               "\(name): at +90 +Side moves the unit up the arm toward the hand")
        let height = WristComm.adjustedFrame(along, origin: o90, tiltDegrees: 0,
                                             fwd: 0, side: 0, up: 0.03)
        assert(near(height.origin, o90 - wf.right * 0.03),
               "\(name): at +90 +Height moves the unit across the arm")

        // MARK: an untracked wrist

        // Passes through whole at any angle, same contract `adjustedFrame`
        // keeps: there is no plane to rotate.
        var bad = wf
        bad.valid = false
        for deg in [Float(0), 37, 90] {
            let dead = WristComm.orientedFrame(bad, rollDegrees: deg)
            assert(!dead.valid, "\(name)/\(deg): an invalid frame stays invalid")
            assert(exact(dead.right, bad.right), "\(name)/\(deg): an invalid frame's right is untouched")
            assert(exact(dead.up, bad.up), "\(name)/\(deg): an invalid frame's up is untouched")
            assert(exact(dead.forward, bad.forward), "\(name)/\(deg): an invalid frame's forward is untouched")
        }
    }
    print("orientation ok")
}

// MARK: - The forearm-locked (along-arm) frame

/// `WristComm.forearmFrame` builds the along-arm view's panel basis STRAPPED
/// TO THE ARM, from the two forearm joints plus a lateral axis -- no eye, no
/// billboard, no HUD plane. These tests pin the three things a reader cannot
/// derive from the signature: which way the long axis runs, which way the
/// face points, and what the Rotate dial does to both.
func runForearmFrameTests() {

    // THE REFERENCE POSE, used by every assertion below that talks about
    // "the wearer": a right-handed player's LEFT forearm lifted across the
    // chest into the Buzz L, in the renderer's corrected tracking space (+Y
    // up, the player facing -Z, so the player's own right is +X).
    //
    //   elbow  left of centre, wrist across to the right  -> the arm runs +X
    //   lateral +Y                                        -> out of the INNER
    //                                                        forearm face,
    //                                                        toward the
    //                                                        looking-down head
    let elbow = SIMD3<Float>(-0.20, 1.05, -0.25)
    let wrist = SIMD3<Float>(0.10, 1.05, -0.25)
    let lateral = SIMD3<Float>(0, 1, 0)
    let armAxis = simd_normalize(wrist - elbow)

    let f = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                   lateral: lateral, rollDegrees: 0)
    assert(f.valid, "forearm: a tracked forearm builds a valid frame")

    // MARK: the long axis runs ALONG the arm, toward the hand

    // `right` is both the axis the three key columns run along and the axis
    // `RendererCore.textQuads` lays glyphs along, so this single assertion
    // is what makes the unit a strap rather than a billboard.
    assert(near(f.right, armAxis, 1e-5), "forearm: right is the arm axis, elbow -> wrist")
    assert(simd_dot(f.right, wrist - elbow) > 0, "forearm: ...pointing toward the HAND, not the elbow")

    // MARK: the face comes off the inner forearm

    let projected = simd_normalize(lateral - armAxis * simd_dot(lateral, armAxis))
    assert(near(f.forward, projected, 1e-5),
           "forearm: at roll 0 the face normal is the lateral axis, orthonormalised")
    assert(simd_dot(f.forward, lateral) > 0,
           "forearm: ...on the lateral's OWN side of the arm, not the opposite face")

    // MARK: legends upright for a head looking down at the L

    // A wearer facing -Z who tips their head down to read the unit carries
    // their head-up vector from +Y round to -Z. The panel's `up` has to
    // agree with it or every legend reads upside down -- the exact failure
    // the across view's `orientedFrame` hit on device and had to have called
    // off a screenshot. Here it is derived and PINNED instead.
    assert(near(f.up, SIMD3<Float>(0, 0, -1), 1e-5),
           "forearm: in the L pose the panel's up is the looking-down head's up")

    // ...and the key run reads from the elbow toward the wrist: cell 0 (the
    // first binding) at the elbow end, cell 2 (the end of the top row) at
    // the wrist end -- this view's own reading direction, derived above
    // from its own joints, not a cross-check against the across view (its
    // `rot` default is 0, a billboarded panel with no elbow to read from).
    //
    // The two asserts below reduce, by `f.right`/`f.up` orthonormality (the
    // dot product kills the `c*.y` term and `dot(f.right, f.right) == 1`),
    // to `c0.x < 0` / `c2.x > 0` -- a property of `cellCenter`'s own layout,
    // already pinned in `runCommGeometryTests`, not of this frame. They are
    // kept here as a cheap sanity check that the two don't disagree, not as
    // independent proof that the composed placement reads elbow-to-wrist.
    let c0 = WristComm.cellCenter(0), c2 = WristComm.cellCenter(2)
    assert(simd_dot(f.right * c0.x + f.up * c0.y, f.right) < 0,
           "forearm: cellCenter(0).x is on the elbow side of the grid's own layout")
    assert(simd_dot(f.right * c2.x + f.up * c2.y, f.right) > 0,
           "forearm: cellCenter(2).x is on the wrist side of the grid's own layout")

    // MARK: orthonormal and right-handed at EVERY roll

    // Same invariant every frame in this file keeps. `HudEditor.offsetInFrame`
    // assumes unit axes (a short basis silently widens the grid's bounds) and
    // a LEFT-handed triple mirrors every legend while all three dot products
    // still read zero.
    for deg in [Float(-180), -137, -90, -37, 0, 1, 30, 45, 90, 137, 180] {
        let r = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                       lateral: lateral, rollDegrees: deg)
        assert(r.valid, "forearm/\(deg): still valid")
        assert(near(simd_length(r.right), 1), "forearm/\(deg): right stays unit")
        assert(near(simd_length(r.up), 1), "forearm/\(deg): up stays unit")
        assert(near(simd_length(r.forward), 1), "forearm/\(deg): forward stays unit")
        assert(abs(simd_dot(r.right, r.up)) < 1e-5, "forearm/\(deg): right . up stays 0")
        assert(abs(simd_dot(r.up, r.forward)) < 1e-5, "forearm/\(deg): up . forward stays 0")
        assert(abs(simd_dot(r.right, r.forward)) < 1e-5, "forearm/\(deg): right . forward stays 0")
        assert(near(simd_cross(r.right, r.up), r.forward, 1e-5),
               "forearm/\(deg): right x up stays forward")
        // Roll is AROUND THE ARM: the long axis is the rotation axis and
        // must not move an inch, whatever the dial says.
        assert(near(r.right, armAxis, 1e-5), "forearm/\(deg): the arm axis is the roll axis")
    }

    // MARK: what the Rotate dial actually does

    // A half turn puts the unit on the OPPOSITE face of the forearm -- the
    // one lever for "the derivation picked the wrong face on device".
    let flipped = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                         lateral: lateral, rollDegrees: 180)
    assert(near(flipped.forward, -f.forward, 1e-4), "forearm: 180 flips the face")
    assert(near(flipped.up, -f.up, 1e-4), "forearm: 180 turns the legends end over end with it")

    // The sweep DIRECTION, which is the half of the sign choice a flip
    // cannot see: at +90 the old face normal has swung onto the old `up`.
    let quarter = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                         lateral: lateral, rollDegrees: 90)
    assert(near(simd_dot(quarter.forward, f.up), -1, 1e-4),
           "forearm: +90 sweeps the face normal onto -up")
    assert(near(simd_dot(quarter.up, f.forward), 1, 1e-4),
           "forearm: ...and up onto the old face normal")

    // ...and it really is a rotation BY the dialled angle, not a snap.
    for deg in [Float(30), 137] {
        let r = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                       lateral: lateral, rollDegrees: deg)
        let rad = deg * .pi / 180
        assert(near(simd_dot(r.forward, f.forward), cos(rad), 1e-5),
               "forearm/\(deg): the face turns by cos(theta) onto the old face")
        assert(near(simd_dot(r.forward, f.up), -sin(rad), 1e-5),
               "forearm/\(deg): ...and by -sin(theta) onto up -- the sweep goes forward -> -up")
    }

    // MARK: handedness of the HAND is not baked in

    // The publisher mirrors `lateral` per chirality so it means
    // "out of the inner forearm" for BOTH hands (see `ForearmPose`). The
    // frame builder therefore must be chirality-BLIND: the same arm pointing
    // the other way, with its own lateral, builds the mirror-image placement
    // and still a right-handed basis. A builder that hard-coded a hand would
    // pass every assertion above and fail here.
    let rElbow = SIMD3<Float>(0.20, 1.05, -0.25)
    let rWrist = SIMD3<Float>(-0.10, 1.05, -0.25)
    let g = WristComm.forearmFrame(wrist: rWrist, elbow: rElbow,
                                   lateral: lateral, rollDegrees: 0)
    assert(g.valid, "forearm: the other arm builds a valid frame too")
    assert(near(g.right, simd_normalize(rWrist - rElbow), 1e-5),
           "forearm: the other arm's long axis still runs elbow -> wrist")
    assert(near(simd_cross(g.right, g.up), g.forward, 1e-5),
           "forearm: the other arm's basis is right-handed too")
    assert(near(g.up, SIMD3<Float>(0, 0, 1), 1e-5),
           "forearm: the other arm's legends are upright for the same looking-down head")

    // MARK: degenerate inputs are INVALID, never a NaN basis

    // Every one of these is a real tracking state: a collapsed forearm (both
    // joints reported at one point), a lateral axis that came back zero, and
    // a lateral that is parallel to the bone -- which is what a WRONGLY
    // CHOSEN joint-rotation column looks like (see `ForearmPose`'s
    // documentation of the column pick). Gram-Schmidt divides by zero on all
    // three, so they have to be refused before the division, not after.
    let degenerate: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, String)] = [
        (wrist, wrist, lateral, "a collapsed forearm"),
        (wrist, wrist + SIMD3<Float>(0, 0, 5e-5), lateral, "a sub-0.1 mm forearm"),
        (wrist, elbow, .zero, "a zero lateral axis"),
        (wrist, elbow, armAxis, "a lateral parallel to the bone"),
        (wrist, elbow, armAxis * -3, "a lateral antiparallel to the bone"),
    ]
    for (w, e, l, name) in degenerate {
        for deg in [Float(0), 90] {
            let bad = WristComm.forearmFrame(wrist: w, elbow: e, lateral: l, rollDegrees: deg)
            assert(!bad.valid, "forearm: \(name) is invalid (\(deg))")
            assert(bad.right.x.isFinite && bad.up.y.isFinite && bad.forward.z.isFinite,
                   "forearm: \(name) is finite, not a NaN basis (\(deg))")
        }
    }

    // MARK: the composed chain -- a key fires where it lights

    // The renderer's ALONG path in full: forearmFrame -> the seated origin
    // (`alongSeatDistance` down the arm from the wrist) with the dials along
    // the frame's OWN axes -> adjustedFrame for the tilt alone. Every cell
    // must still hit-test to itself, which is what keeps the hover
    // highlight, the drawn quad and the published hit-test geometry on one
    // plane.
    for deg in [Float(0), 37] {
        let r = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                       lateral: lateral, rollDegrees: deg)
        var seated = wrist - r.right * WristComm.alongSeatDistance(rollDegrees: deg)
        seated += r.right * 0.02
        seated += r.up * -0.01
        seated += r.forward * 0.01
        let dialled = WristComm.adjustedFrame(r, origin: seated, tiltDegrees: 12,
                                              fwd: 0, side: 0, up: 0)
        // The tilt-only call must not move the unit a second time: the
        // offsets are already in `seated` (they run in the arm's axes, not
        // the eye's), and double-applying them is the one mistake this
        // chain invites.
        assert(near(dialled.origin, seated, 1e-6),
               "forearm/\(deg): the tilt-only call leaves the seated origin alone")
        for cell in 0 ..< (WristComm.cols * WristComm.rows) {
            let c = WristComm.cellCenter(cell)
            let p = dialled.origin + dialled.frame.right * c.x + dialled.frame.up * c.y
            assert(WristComm.touchedCell(p, commOrigin: dialled.origin,
                                         frame: dialled.frame) == cell,
                   "forearm/\(deg): dialled cell \(cell) hit-tests to itself")
        }
    }

    // What these three actually pin: the frame-axis identities the settings
    // caption's dial meanings (Forward ALONG the arm, Side ACROSS it, Height
    // OFF the skin) are DOCUMENTED to rely on -- `f.right == armAxis`,
    // `f.forward == +Y` and `f.right perp f.up` are all already established
    // 150-odd lines above; these three restate them in the dial's own
    // vocabulary. They do NOT reach `resolveCommPlacement`, which is where
    // the dials are actually multiplied onto the frame -- that function
    // lives in `ImmersiveRenderer.swift`, which this host harness does not
    // compile, so a caption and a renderer that disagree would NOT fail
    // here. Honest framing only; see the renderer's own doc and the device
    // checklist for the thing this cannot check.
    let mid = (elbow + wrist) * 0.5
    assert(near(mid + f.right * 0.05, mid + armAxis * 0.05, 1e-6),
           "forearm: f.right is the arm axis toward the hand -- what +Forward would ride")
    assert(near(mid + f.forward * 0.01, mid + SIMD3<Float>(0, 0.01, 0), 1e-6),
           "forearm: f.forward is the face normal off the skin -- what +Height would ride")
    assert(abs(simd_dot(f.up, armAxis)) < 1e-5,
           "forearm: f.up is perpendicular to the arm axis -- what +Side would ride, never along it")

    print("forearm frame ok")
}

/// `ImmersiveRenderer.resolveCommPlacement`'s ALONG case, MIRRORED: the
/// oriented base frame, the origin seated down the arm, and `adjustedFrame`
/// with the three offsets permuted onto the axes the dial NAMES mean.
///
/// THE PERMUTATION IS THE WHOLE REASON THIS HELPER EXISTS. `adjustedFrame`
/// is written for the across view, where the panel's `forward` is the
/// Height-ish "toward you" axis and its `right` is the Side-ish one; the
/// along base frame's axes are a different assignment of the same three
/// names (`right` is the ARM, `forward` is toward the eye, `up` is across
/// the panel), so the three dials have to be handed in rotated by one.
/// Passing them positionally compiles, type-checks, and silently gives three
/// wrong dials -- which is exactly what shipped and what the directional
/// assertions below now catch.
///
/// This harness does not compile `ImmersiveRenderer.swift`, so this is a
/// MIRROR and not the thing itself: it can only hold the renderer honest if
/// the two are changed together. That is the standing cost of a pure-math
/// harness, already noted at the end of `runForearmFrameTests`, and it is
/// why the permutation is spelled out in both places rather than inferred.
func alongChain(_ base: HudEditor.WristFrame, rollDegrees: Float,
                seated: SIMD3<Float>, tilt: Float,
                fwd: Float, side: Float, up: Float)
    -> (frame: HudEditor.WristFrame, origin: SIMD3<Float>) {
    let oriented = WristComm.orientedFrame(base, rollDegrees: rollDegrees)
    // Forward -> `side` (rides `right`, the arm), Side -> `up` (across the
    // panel), Height -> `fwd` (rides `forward`, toward the eye). Mirrors
    // `resolveCommPlacement`, which spells the same mapping out.
    return WristComm.adjustedFrame(oriented, origin: seated, tiltDegrees: tilt,
                                   fwd: up, side: fwd, up: side)
}

// MARK: - The along view's eye-facing base frame

/// `WristComm.alongBaseFrame` is the along view's panel basis as it stands
/// now: anchored to the forearm but BILLBOARDED TO THE EYE. The skin-locked
/// construction it replaces (`forearmFrame`, still in the file and still
/// tested below) put the panel's face on the forearm itself, which reads
/// edge-on -- "a horizontal line" -- from every natural glance pose, and no
/// amount of Angle/Rotate recovers that: the gimbal turns a panel the head
/// is looking along the plane of. The fix is to keep the POSITION on the arm
/// and hand the ORIENTATION to the eye.
///
/// These tests pin the three things that makes true: the face always points
/// at the eye, the key run still reads elbow -> wrist, and the frame stays a
/// right-handed orthonormal basis through the shared `orientedFrame` spin.
func runAlongBaseFrameTests() {

    // THE REFERENCE POSE: a right-handed player's LEFT forearm lifted across
    // the chest into the Buzz L, in the renderer's corrected tracking space
    // (+Y up, the player facing -Z, so the player's own right is +X). The
    // arm runs +X; the eye is above and in front of the wrist, which is
    // where a head that has glanced down at its own arm is.
    let elbow = SIMD3<Float>(-0.20, 1.05, -0.25)
    let wrist = SIMD3<Float>(0.10, 1.05, -0.25)
    let eye = SIMD3<Float>(0.05, 1.55, 0.05)
    let armAxis = simd_normalize(wrist - elbow)

    let f = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: eye)
    assert(f.valid, "along base: a tracked forearm and a head build a valid frame")

    // MARK: the face points AT THE EYE -- the whole round's reason

    assert(near(f.forward, simd_normalize(eye - wrist), 1e-5),
           "along base: forward is the unit vector from the wrist toward the eye")
    assert(near(simd_length(f.forward), 1), "along base: ...and it is unit")

    // MARK: the long axis is the arm AS SEEN IN THE PANEL PLANE

    // Gram-Schmidt rather than the raw bone: `right` has to lie IN the
    // panel's plane or the basis is not orthonormal and
    // `HudEditor.offsetInFrame` mis-projects every touch. What survives the
    // projection is the arm's apparent direction, which is what keeps three
    // keys reading down the forearm.
    let projectedArm = simd_normalize(armAxis - f.forward * simd_dot(armAxis, f.forward))
    assert(near(f.right, projectedArm, 1e-5),
           "along base: right is the arm axis orthonormalised against the face")
    assert(simd_dot(f.right, armAxis) > 0,
           "along base: ...still pointing toward the HAND, so the keys read elbow -> wrist")

    // MARK: orthonormal, right-handed, and still so after the Rotate spin

    // `HudEditor.offsetInFrame` assumes unit axes (a short basis silently
    // widens the grid's bounds) and a LEFT-handed triple mirrors every
    // legend while all three dot products still read zero. The spin is the
    // SHARED `orientedFrame`, the same one the across view uses -- the
    // structural point of the shared frame -- so it is checked through it.
    func pinBasis(_ r: HudEditor.WristFrame, _ what: String) {
        assert(near(simd_length(r.right), 1), "\(what): right is unit")
        assert(near(simd_length(r.up), 1), "\(what): up is unit")
        assert(near(simd_length(r.forward), 1), "\(what): forward is unit")
        assert(abs(simd_dot(r.right, r.up)) < 1e-5, "\(what): right . up is 0")
        assert(abs(simd_dot(r.up, r.forward)) < 1e-5, "\(what): up . forward is 0")
        assert(abs(simd_dot(r.right, r.forward)) < 1e-5, "\(what): right . forward is 0")
        assert(near(simd_cross(r.right, r.up), r.forward, 1e-5),
               "\(what): right x up == forward")
    }
    pinBasis(f, "along base")
    for deg in [Float(-180), -137, -90, -45, -37, 0, 1, 30, 45, 90, 137, 180] {
        let r = WristComm.orientedFrame(f, rollDegrees: deg)
        pinBasis(r, "along base/\(deg)")
        // THE PANEL NEVER GOES EDGE-ON. An in-plane spin is a rotation about
        // the face normal, so Rotate turns the key run and leaves the face
        // pointing exactly where it was -- at the eye. This is the assertion
        // the skin-locked construction could not make at any angle, and it
        // is the device symptom stated as a number.
        assert(near(r.forward, f.forward, 1e-6),
               "along base/\(deg): Rotate spins the keys IN the plane, the face stays on the eye")
    }

    // MARK: the panel faces the eye from WHEREVER the eye is

    // Swept rather than asserted once, because "faces you" is a claim about
    // every glance pose, and the failure seen on device was pose-dependent: the old
    // frame was perfectly face-on in the one contrived pose and edge-on in
    // the natural ones.
    for dx in [Float(-0.6), -0.2, 0, 0.2, 0.6] {
        for dy in [Float(-0.3), 0.1, 0.5] {
            for dz in [Float(-0.4), 0.05, 0.7] {
                let e = wrist + SIMD3(dx, dy, dz)
                let r = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: e)
                assert(r.valid, "along base/eye(\(dx),\(dy),\(dz)): valid")
                assert(near(simd_dot(r.forward, simd_normalize(e - wrist)), 1, 1e-5),
                       "along base/eye(\(dx),\(dy),\(dz)): the face is square to the eye, never edge-on")
                pinBasis(r, "along base/eye(\(dx),\(dy),\(dz))")
            }
        }
    }

    // MARK: the arm pointing AT the eye falls back rather than vanishing

    // The one genuinely degenerate direction: with the bone along the line
    // of sight there is no arm direction left in the panel plane to lay the
    // keys along. Refusing the frame would blank the unit every time the arm
    // swung through the view axis -- a flicker, in the middle of a reach --
    // so it falls back to the worldUp billboard basis instead, exactly as
    // `RendererCore.billboardBasis` builds one.
    let axial = wrist + armAxis * 0.5
    let fb = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: axial)
    assert(fb.valid, "along base: the arm pointing at the eye still builds a frame")
    pinBasis(fb, "along base/axial")
    assert(near(fb.right, simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fb.forward)), 1e-5),
           "along base/axial: the fallback right is the worldUp billboard's")
    assert(simd_dot(fb.up, SIMD3<Float>(0, 1, 0)) > 0.9,
           "along base/axial: ...which leaves the legends upright, not rolled onto their side")

    // ...and the fallback's OWN degenerate case, a face straight up the
    // world axis, where `cross(worldUp, forward)` is itself zero: the arm
    // held vertical with the eye above it.
    let upWrist = SIMD3<Float>(0.10, 1.20, -0.25)
    let upElbow = SIMD3<Float>(0.10, 0.90, -0.25)
    let overhead = WristComm.alongBaseFrame(wrist: upWrist, elbow: upElbow,
                                            eye: upWrist + SIMD3<Float>(0, 0.5, 0))
    assert(overhead.valid, "along base: a vertical arm under a vertical eye still builds a frame")
    pinBasis(overhead, "along base/overhead")
    assert(near(overhead.right, SIMD3<Float>(1, 0, 0), 1e-5),
           "along base/overhead: ...on the billboard basis's own (1,0,0) fallback")

    // MARK: degenerate inputs are INVALID, never a NaN basis

    // Both are real tracking states: a collapsed forearm (both joints
    // reported at one point, which is what an untracked pair reports) and an
    // eye at the wrist (a head pose that has not resolved). Both divide by
    // zero in a normalisation, so both are refused before the division.
    let degenerate: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, String)] = [
        (wrist, wrist, eye, "a collapsed forearm"),
        (wrist, wrist + SIMD3<Float>(0, 0, 5e-5), eye, "a sub-0.1 mm forearm"),
        (wrist, elbow, wrist, "an eye at the wrist"),
        (wrist, elbow, wrist + SIMD3<Float>(5e-5, 0, 0), "an eye 0.05 mm off the wrist"),
    ]
    for (w, e, y, name) in degenerate {
        let bad = WristComm.alongBaseFrame(wrist: w, elbow: e, eye: y)
        assert(!bad.valid, "along base: \(name) is invalid")
        assert(bad.right.x.isFinite && bad.up.y.isFinite && bad.forward.z.isFinite,
               "along base: \(name) is finite, not a NaN basis")
    }

    // MARK: the renderer's chain in full -- a key fires where it lights

    // `resolveCommPlacement`'s ALONG case, reproduced: the base frame, the
    // shared `orientedFrame` spin, the seated origin down the arm, and
    // `adjustedFrame` with ALL FOUR dials -- the same chain shape the across
    // case has, differing only in the base frame and the seating axis. Every
    // cell must hit-test to itself, which is what keeps the hover highlight,
    // the drawn quad and the published hit-test geometry on one plane.
    for deg in [Float(0), 37] {
        let oriented = WristComm.orientedFrame(f, rollDegrees: deg)
        let seated = wrist - armAxis * WristComm.alongSeatDistance(rollDegrees: deg)
        let dialled = alongChain(f, rollDegrees: deg, seated: seated, tilt: 12,
                                 fwd: 0.01, side: 0.02, up: -0.005)
        assert(near(dialled.frame.right, oriented.right, 1e-6),
               "along base/\(deg): the chain's frame is the oriented one")
        for cell in 0 ..< (WristComm.cols * WristComm.rows) {
            let c = WristComm.cellCenter(cell)
            let p = dialled.origin + dialled.frame.right * c.x + dialled.frame.up * c.y
            assert(WristComm.touchedCell(p, commOrigin: dialled.origin,
                                         frame: dialled.frame) == cell,
                   "along base/\(deg): dialled cell \(cell) hit-tests to itself")
        }
        // ...and cell 0, the first binding, is at the ELBOW end of the run:
        // the reading direction this view derives from its own joints and
        // keeps through the spin.
        let c0 = WristComm.cellCenter(0)
        let p0 = dialled.origin + dialled.frame.right * c0.x + dialled.frame.up * c0.y
        assert(simd_dot(p0 - dialled.origin, armAxis) < 0,
               "along base/\(deg): cell 0 sits on the ELBOW side of the panel")
    }

    // MARK: WHAT THE DIAL NAMES MEAN -- directional, not an identity

    // The assertion this block replaces restated `adjustedFrame`'s own
    // formula ("the offsets ride the oriented panel's axes") and was
    // therefore unable to fail for the bug it was supposed to cover: the
    // renderer's three offsets went in POSITIONALLY, so Forward rode
    // `forward` (at the player's face) instead of the arm, Side rode the
    // arm, and Height rode the across-panel axis -- three dials permuted
    // against every caption, default and doc in the round, and the default
    // 1 cm Height sank the hit-test plane into the forearm instead of
    // lifting it clear.
    //
    // These are the captions' claims as DIRECTIONS, one `simd_dot` each,
    // measured as the DELTA a single dial makes against the all-zero
    // placement. An identity cannot express "+Forward moves it along your
    // arm"; a dot product can, and it fails the moment the permutation is
    // wrong whichever way round it is written.
    let toEyeUnit = simd_normalize(eye - wrist)
    func movedBy(_ deg: Float, fwd: Float = 0, side: Float = 0, up: Float = 0) -> SIMD3<Float> {
        let seated = wrist - armAxis * WristComm.alongSeatDistance(rollDegrees: deg)
        let zero = alongChain(f, rollDegrees: deg, seated: seated, tilt: 0,
                              fwd: 0, side: 0, up: 0)
        let one = alongChain(f, rollDegrees: deg, seated: seated, tilt: 0,
                             fwd: fwd, side: side, up: up)
        return one.origin - zero.origin
    }

    // The REFERENCE POSE HERE IS SQUARE TO THE ARM -- `squareF` below puts
    // the eye in the plane through the wrist perpendicular to a +X bone, so
    // the projected arm IS the arm and each claim can be checked as an exact
    // length rather than a sign. The general (oblique) pose follows after.
    let squareEye = SIMD3<Float>(0.10, 1.55, 0.15)
    let squareF = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: squareEye)
    let squareToEye = simd_normalize(squareEye - wrist)
    assert(near(squareF.right, armAxis, 1e-5),
           "along dials: the square reference pose really does project the arm whole")
    func squareMovedBy(fwd: Float = 0, side: Float = 0, up: Float = 0) -> SIMD3<Float> {
        let seated = wrist - armAxis * WristComm.alongSeatDistance(rollDegrees: 0)
        let zero = alongChain(squareF, rollDegrees: 0, seated: seated, tilt: 0,
                              fwd: 0, side: 0, up: 0)
        let one = alongChain(squareF, rollDegrees: 0, seated: seated, tilt: 0,
                             fwd: fwd, side: side, up: up)
        return one.origin - zero.origin
    }
    let step: Float = 0.03

    // FORWARD SLIDES IT ALONG YOUR ARM, toward the hand for a positive dial
    // -- the dial the caption tells the player to re-seat the unit with.
    let dFwd = squareMovedBy(fwd: step)
    assert(near(simd_dot(dFwd, armAxis), step, 1e-6),
           "along dials: +Forward slides the unit ALONG the arm, toward the hand")
    assert(near(simd_length(dFwd), step, 1e-6),
           "along dials: ...and along it ALONE, with nothing left over")

    // HEIGHT BRINGS IT TOWARD YOU. This is the one the default depends on:
    // `commUpAlongDefault` is 1 cm, and it has to be 1 cm of CLEARANCE in
    // front of the arm or the hit-test plane sits inside the forearm and a
    // fingertip stopped by the skin never reaches the touch band.
    let dUp = squareMovedBy(up: step)
    assert(near(simd_dot(dUp, squareToEye), step, 1e-6),
           "along dials: +Height brings the unit TOWARD THE EYE, off the arm")
    assert(near(simd_length(dUp), step, 1e-6),
           "along dials: ...and toward it ALONE")

    // SIDE MOVES IT ACROSS THE PANEL -- perpendicular to both of the above,
    // which is the only direction left.
    let dSide = squareMovedBy(side: step)
    assert(abs(simd_dot(dSide, armAxis)) < 1e-6,
           "along dials: +Side does not move the unit along the arm")
    assert(abs(simd_dot(dSide, squareToEye)) < 1e-6,
           "along dials: ...nor toward the eye")
    assert(near(simd_length(dSide), step, 1e-6),
           "along dials: ...it moves it ACROSS the panel, the one axis left")

    // THE OBLIQUE POSE, where the projected arm is foreshortened and the
    // exact lengths above no longer hold: the SIGNS still must. This is the
    // pose the device is actually in -- the eye is never exactly square to
    // the forearm -- and it is where a permutation that happened to look
    // right in the contrived pose would still show.
    for deg in [Float(0), 37] {
        let fwdDelta = movedBy(deg, fwd: step)
        assert(simd_dot(fwdDelta, armAxis) > 0,
               "along dials/\(deg): +Forward still carries the unit toward the hand")
        assert(abs(simd_dot(fwdDelta, toEyeUnit)) < 1e-6,
               "along dials/\(deg): ...and never at the player's face")
        // `orientedFrame` leaves `forward` alone, so Height is exactly the
        // toward-the-eye axis at EVERY Rotate angle, not merely in sign.
        let upDelta = movedBy(deg, up: step)
        assert(near(simd_dot(upDelta, toEyeUnit), step, 1e-6),
               "along dials/\(deg): +Height is the toward-the-eye axis at every Rotate")
    }

    print("along base frame ok")
}

/// The panel's WRIST-SIDE EDGE in the arm's own coordinate: the largest
/// projection of its four corners back onto the arm axis, with the wrist
/// joint at 0 and the elbow in the negative direction. Measured off a real
/// frame rather than restated from `alongSeatDistance`, which is the whole
/// point of composing it -- the two can disagree, and that disagreement is
/// the overlap the seat exists to prevent.
func cornerReach(_ centre: SIMD3<Float>, _ frame: HudEditor.WristFrame,
                 _ armAxis: SIMD3<Float>, _ wrist: SIMD3<Float>) -> Float {
    var edge = -Float.greatestFiniteMagnitude
    for sx in [Float(-1), 1] {
        for sy in [Float(-1), 1] {
            let alongRight: SIMD3<Float> = frame.right * (sx * WristComm.gridHalfX)
            let alongUp: SIMD3<Float> = frame.up * (sy * WristComm.gridHalfY)
            let corner: SIMD3<Float> = centre + alongRight + alongUp
            edge = max(edge, simd_dot(corner - wrist, armAxis))
        }
    }
    return edge
}

// MARK: - The along view's seat below the HUD grid

/// `WristComm.alongSeatDistance` is the along view's answer to the across
/// view's `commOrigin`: one derivation, two drop axes. The across unit drops
/// DOWN the billboarded wrist plane; this one backs DOWN THE ARM from the
/// wrist joint, because the HUD grid is billboarded AT that joint and the
/// along unit used to be seated mid-forearm with nothing clearing it at all
/// -- which is the collision seen on device, where no setting of the
/// parameters stopped the gauntlet fighting the modular HUD's wrist tiles.
///
/// THE REQUIREMENT these pin, in one line: the unit's near edge clears the
/// HUD grid's long reach by at least `hudGap` at EVERY Rotate angle. The
/// seat is whatever serves that, and what serves it here is a CONSTANT --
/// see the first block below.
func runAlongSeatTests() {
    let hudReach = HudEditor.gridHalfX          // the HUD grid's LONG half
    let floor = hudReach + WristComm.hudGap     // no seat may be this close

    // THE SEAT FOLLOWS THE ROTATE DIAL AGAIN. Under the forearm-locked
    // construction this view used to have, `rollDegrees` was a roll ABOUT
    // THE ARM -- the long axis WAS the rotation axis, so no angle could
    // present the short half down the arm and the seat was flat. The
    // billboarded along view turns the panel IN ITS OWN PLANE instead
    // (`orientedFrame`, the same function the across view uses), so the four
    // corners genuinely swing and the supporting half-extent along the arm
    // is the rotated rectangle's again:
    //
    //     |cos t| * gridHalfX + |sin t| * gridHalfY
    //
    // -- the long half end-on at 0, the short half at a quarter turn, and a
    // smooth sweep between, so the unit starts clear of the HUD at every
    // angle rather than overlapping it part-way through a turn.
    func expected(_ deg: Float) -> Float {
        let t = deg * .pi / 180
        return floor + abs(cos(t)) * WristComm.gridHalfX + abs(sin(t)) * WristComm.gridHalfY
    }

    // THE ENDPOINTS, which are the two readings the formula exists to tell
    // apart: a flat seat passes the first and fails the second.
    assert(near(WristComm.alongSeatDistance(rollDegrees: 0), floor + WristComm.gridHalfX),
           "along seat/0: end-on, so the panel's LONG half supports it")
    for deg in [Float(180), -180] {
        assert(near(WristComm.alongSeatDistance(rollDegrees: deg), floor + WristComm.gridHalfX),
               "along seat/\(deg): a half turn is end-on again")
    }
    for deg in [Float(90), -90] {
        assert(near(WristComm.alongSeatDistance(rollDegrees: deg), floor + WristComm.gridHalfY),
               "along seat/\(deg): a quarter turn presents the SHORT half down the arm")
    }
    // ...and the diagonal, where BOTH halves contribute. A formula that took
    // the larger of the two extents rather than their supporting sum would
    // pass every endpoint above and fail here.
    let diagonal = floor + (WristComm.gridHalfX + WristComm.gridHalfY) * cos(Float.pi / 4)
    for deg in [Float(45), -45, 135, -135] {
        assert(near(WristComm.alongSeatDistance(rollDegrees: deg), diagonal),
               "along seat/\(deg): both halves support the panel at the diagonal")
    }
    // ...and in metres, the number to measure against on device:
    // 0.0755 + 0.012 + 0.057.
    assert(near(WristComm.alongSeatDistance(rollDegrees: 0), 0.1445, 1e-5),
           "along seat: the seat is 14.45 cm down the arm at Rotate 0")

    // Swept at 5 degrees rather than at the pretty angles alone: a seat that
    // agreed at the endpoints and dipped between them -- which is what a
    // wrong trig term looks like -- slips between any coarser pair.
    for deg in stride(from: Float(-180), through: 180, by: 5) {
        assert(near(WristComm.alongSeatDistance(rollDegrees: deg), expected(deg)),
               "along seat/\(deg): the rotated rectangle's own support, on a fine sweep")
        // THE INVARIANT, stated separately from the value: the seat is
        // strictly past the HUD's own long reach plus the gap, so the unit's
        // CENTRE is clear of the grid before its own extent is counted at
        // all. A seat that dropped the `hudReach` term would still look
        // plausible on a slider and would fail here at every angle.
        assert(WristComm.alongSeatDistance(rollDegrees: deg) > floor,
               "along seat/\(deg): never inside the HUD's long reach + gap")
    }

    // Symmetry: an extent does not care which way the panel was spun, which
    // is exactly what the absolute values in the formula are there for. -45
    // therefore seats identically to +45, and a sign slip that only showed
    // on one side of zero is caught here rather than on device.
    for deg in [Float(1), 17, 45, 73, 90, 137, 180] {
        assert(near(WristComm.alongSeatDistance(rollDegrees: deg),
                    WristComm.alongSeatDistance(rollDegrees: -deg)),
               "along seat/\(deg): -t seats exactly like +t")
    }

    // MARK: composed -- the seat through the real origin math

    // The renderer's ALONG chain as it now stands: `alongBaseFrame` for the
    // basis, the shared `orientedFrame` for the Rotate spin, then
    // `wrist - armAxis * seat` for the centre. Measured in the arm's own
    // coordinate -- dot with the arm axis, the wrist joint at 0, the elbow
    // in the negative direction -- which is the coordinate the HUD grid's
    // half-extents are expressed in too.
    //
    // THE EYE IS PLACED SQUARE TO THE ARM here (same x as the wrist, so the
    // line of sight is perpendicular to a +X bone), which is the pose the
    // seat formula is the exact answer for: the panel's long axis is the
    // PROJECTED arm, and only in this pose does the projection preserve its
    // full length. Every other pose foreshortens it, and the sweep below
    // pins that the foreshortening can only ever help.
    let elbow = SIMD3<Float>(-0.20, 1.05, -0.25)
    let wrist = SIMD3<Float>(0.10, 1.05, -0.25)
    let squareEye = SIMD3<Float>(0.10, 1.55, 0.15)
    let armAxis = simd_normalize(wrist - elbow)

    // Run at 0 AND at 90: the quarter turn is where the seat differs most
    // from a flat one, and where a formula with the two halves swapped
    // would put the unit's edge 2 cm inside the grid.
    for deg in [Float(0), 90] {
        let base = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: squareEye)
        assert(base.valid, "along seat/\(deg): the reference pose builds a valid frame")
        let frame = WristComm.orientedFrame(base, rollDegrees: deg)
        let seat = WristComm.alongSeatDistance(rollDegrees: deg)
        let centre = wrist - armAxis * seat
        assert(near(simd_dot(centre - wrist, armAxis), -seat, 1e-6),
               "along seat/\(deg): the seated centre sits exactly `seat` down the arm")
        assert(simd_dot(centre - wrist, armAxis) > simd_dot(elbow - wrist, armAxis),
               "along seat/\(deg): ...and still on the forearm, not past the elbow")

        // The unit's own WRIST-SIDE EDGE, taken from the panel's four
        // corners projected back onto the arm axis rather than from the seat
        // formula -- the one quantity here that can disagree with
        // `alongSeatDistance`, and so the one worth composing. It has to sit
        // a full `hudGap` clear of the HUD grid's near reach, which is
        // -gridHalfX in this coordinate. This is the requirement itself,
        // measured off the real frame rather than restated.
        assert(near(cornerReach(centre, frame, armAxis, wrist),
                    -(hudReach + WristComm.hudGap), 1e-5),
               "along seat/\(deg): the wrist-side edge lands exactly a hudGap below the grid")
    }

    // MARK: off-axis glances can only seat the panel FURTHER out, never nearer

    // The honest half of the nominal. The panel's long axis is the arm as
    // seen in the panel plane, so at any other glance angle it is the bone
    // foreshortened by the sine of the arm-to-eye angle -- which shrinks the
    // extent along the arm. The seat is computed from the unforeshortened
    // figure, so the real edge can only ever come out below the required
    // clearance line, never above it. (What this does NOT bound is the HUD
    // grid's own billboarded reach; see `alongSeatDistance`'s doc for the
    // ~0.109 m adversarial case, which is a property of the grid, not of
    // this panel.)
    let line = -(hudReach + WristComm.hudGap)
    for dx in [Float(-0.8), -0.3, 0, 0.3, 0.8] {
        for dy in [Float(-0.4), 0.2, 0.6] {
            for dz in [Float(-0.5), 0.1, 0.9] {
                let eye = wrist + SIMD3(dx, dy, dz)
                let base = WristComm.alongBaseFrame(wrist: wrist, elbow: elbow, eye: eye)
                assert(base.valid, "along seat/eye(\(dx),\(dy),\(dz)): valid")
                for deg in [Float(0), 45, 90, 137] {
                    let frame = WristComm.orientedFrame(base, rollDegrees: deg)
                    let centre = wrist - armAxis * WristComm.alongSeatDistance(rollDegrees: deg)
                    assert(cornerReach(centre, frame, armAxis, wrist) <= line + 1e-5,
                           "along seat/eye(\(dx),\(dy),\(dz))/\(deg): still clear of the grid")
                }
            }
        }
    }

    print("along seat ok")
}
