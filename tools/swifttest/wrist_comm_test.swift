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
    // finger model can never alternate hands under a two-handed hover.
    let tie = WristComm.hoverPick([1, 1])
    assert(tie?.cell == 1 && tie?.tip == 0, "a tie on one cell breaks to the lower tip index")
    print("hover pick ok")
}

// MARK: - Orientation: the free in-plane Rotate dial

/// Bit-identical component comparison, for the one claim a tolerance cannot
/// make: `rotate = 0` must be the EARLY-RETURN identity, not a rotation by
/// zero that happens to land within 1e-7. The across-wrist unit A. already
/// tuned on device is that path, and it must be untouched to the last bit.
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
/// with, so a continuous dial cannot quietly re-seat or re-orient the unit
/// A. already tuned.
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
        //    DEVICE-DECIDED: the opposite pair shipped first and A. read it
        //    off a screenshot as upside down, which is the only test this
        //    choice has.
        //  * `up' = -right` then puts the glyph tops toward the wrist
        //    frame's own LEFT, which is what handedness forces once the
        //    glyph advance is pinned -- the pair cannot be mixed.
        //
        // This is also the ALONG view's persisted default, so these two
        // assertions are what guarantee the Bool-to-degrees change is a
        // no-op for A.'s current along-arm tuning.
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

    // The renderer's ALONG path in full: forearmFrame -> the caller's
    // mid-forearm origin with the dials along the frame's OWN axes ->
    // adjustedFrame for the tilt alone. Every cell must still hit-test to
    // itself, which is what keeps the hover highlight, the drawn quad and
    // the published hit-test geometry on one plane.
    for deg in [Float(0), 37] {
        let r = WristComm.forearmFrame(wrist: wrist, elbow: elbow,
                                       lateral: lateral, rollDegrees: deg)
        let mid = (elbow + wrist) * 0.5
        var seated = mid
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
