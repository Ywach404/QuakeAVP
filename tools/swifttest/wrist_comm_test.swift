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
        runTouchStateTests()
        runSeedingTests()
        runRevealTests()
        runFireGateTests()
        print("PASSED (wrist_comm_test.swift)")
    }
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
    let r2 = WristComm.updateTouch(state: WristComm.TouchState(), touched: [0, nil], now: 1.0, revealed: false)
    assert(r2.fire == nil, "hidden communicator never fires")
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
