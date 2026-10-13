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
    let o = WristComm.commOrigin(wrist: wf)
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
    let o = WristComm.commOrigin(wrist: wf)

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
        let o = WristComm.commOrigin(wrist: wf)

        // Zero adjustments must be the IDENTITY, bit-for-bit as far as these
        // tolerances see it. This is the "unchanged at zero" contract the
        // whole feature rests on: the communicator A. already tuned on device
        // must not move a millimetre until he drags a dial.
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
    // finger wire can never alternate hands under a two-handed hover.
    let tie = WristComm.hoverPick([1, 1])
    assert(tie?.cell == 1 && tie?.tip == 0, "a tie on one cell breaks to the lower tip index")
    print("hover pick ok")
}
