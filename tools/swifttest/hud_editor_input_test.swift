//
//  hud_editor_input_test.swift
//
//  Host-run test for the HUD live editor's grab/move/scale state machine
//  (`HudEditor.updateGrab`, in App/Sources/HudEditorMath.swift). Compiled
//  and linked ALONE against that one file by tools/check-swift-input.sh --
//  no ARKit/GameController/Observation, no simulator, no app module, no
//  HudEditorInput.swift (the plumbing that drives this from real poses).
//
//  Covers plan Review Focus #1 (a hand lost / controller disconnected MID-
//  GRAB releases at the last good position, never a stuck grab or a jump to
//  the origin) and #5 (two-hand scale with only ONE hand tracked is a
//  no-op, never a garbage scale), plus the tray-recall confirmation (a
//  release always re-resolves through `resolveDrop`, even out of the hidden
//  tray), plus a review fix: a grab stays bound to its ORIGINATING source
//  (`HudEditor.grabInput(for:...)`) even when a different source is also
//  live -- a controller that goes inactive mid-grab must release, never
//  hand off to a hand that happens to be pinching.
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
// under `-Onone`), and check-swift-input.sh builds with `-O` -- so
// runWristGrabTests, which uses bare `assert(...)` per the brief, needs its
// own override of the exact same shape as `check` or it would pass
// vacuously no matter what the math does. This overload's concrete
// (non-autoclosure) `Bool`/`String` parameters win over the stdlib's
// autoclosure version for every call site here, so it's the one that
// actually runs. (Same fix as hud_editor_math_test.swift's own override.)
func assert(_ condition: Bool, _ label: String) {
    check(condition, label)
}

@main
struct HudEditorInputTest {
    static func main() {
        runGrabStartTests()
        runMoveTests()
        runHandLostReleaseTests()       // Review Focus #1
        runTwoHandScaleTests()
        runOneHandScaleNoOpTests()      // Review Focus #5
        runStickScaleTests()
        runTrayRecallTests()            // tray-recall confirmation
        runSourceStickinessTests()      // review fix: bound source, never re-picked mid-grab
        runWristGrabTests()             // Task 5: wrist snap + footprint gestures
        runWristStretchOccupancyTests() // final-review Important 2: stretch can't eat an occupied cell
        print("PASSED (hud_editor_input_test.swift)")
    }
}

// MARK: - fixtures

/// One tile's hit-test frame centred at `origin`, 0.2m square, axis-aligned.
func tileFrame(_ id: Int, _ origin: SIMD3<Float>) -> HudEditor.TileFrame {
    HudEditor.TileFrame(tileID: id, origin: origin,
                        right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                        halfW: 0.1, halfH: 0.1)
}

/// A normal drop zone (not the tray), axis-aligned, radius 0.5.
func zone(_ anchor: Int, _ origin: SIMD3<Float>, hiddenTray: Bool = false) -> HudEditor.Zone {
    HudEditor.Zone(anchor: anchor, origin: origin,
                   right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                   forward: SIMD3<Float>(0, 0, 1), radius: 0.5, isHiddenTray: hiddenTray)
}

func defaultWorking(count: Int = 3) -> [HudEditor.TileEdit] {
    Array(repeating: HudEditor.TileEdit(anchor: 0, offset: .zero, scale: 1, show: true), count: count)
}

// MARK: - grab start

func runGrabStartTests() {
    let tiles = [tileFrame(0, SIMD3<Float>(0, 0, 0)), tileFrame(1, SIMD3<Float>(1, 0, 0))]
    let working = defaultWorking()

    // A pinch landing inside tile 0's frame grabs tile 0.
    do {
        let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0.02, 0.01, 0))
        let r = HudEditor.updateGrab(grab: nil, input: input, working: working,
                                     tiles: tiles, zones: [], dt: 1.0 / 90.0)
        check(r.grab?.tileID == 0, "pinch inside a tile's frame grabs that tile")
        check(r.grab?.lastPoint == SIMD3<Float>(0.02, 0.01, 0), "a fresh grab's lastPoint is the hit point")
    }

    // A pinch landing outside every tile's frame grabs nothing.
    do {
        let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(5, 5, 5))
        let r = HudEditor.updateGrab(grab: nil, input: input, working: working,
                                     tiles: tiles, zones: [], dt: 1.0 / 90.0)
        check(r.grab == nil, "a pinch outside every tile's frame grabs nothing")
    }

    // No primary signal at all: no grab, regardless of what's under the
    // (absent) point.
    do {
        let input = HudEditor.GrabInput(primaryActive: false, primaryPoint: nil)
        let r = HudEditor.updateGrab(grab: nil, input: input, working: working,
                                     tiles: tiles, zones: [], dt: 1.0 / 90.0)
        check(r.grab == nil, "no primary signal starts no grab")
    }
}

// MARK: - move

func runMoveTests() {
    let working = defaultWorking()
    let grab = HudEditor.GrabState(tileID: 0, lastPoint: SIMD3<Float>(0, 0, 0), secondPinch: nil)
    let newPoint = SIMD3<Float>(0.3, 0.1, -0.2)
    let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: newPoint)
    let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                 tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r.grab?.tileID == 0, "a move keeps the same tile grabbed")
    check(r.grab?.lastPoint == newPoint, "a move advances lastPoint to the new point -- the tile follows it")
}

// MARK: - hand lost / controller disconnected mid-grab (Review Focus #1)

func runHandLostReleaseTests() {
    let lastGood = SIMD3<Float>(0.1, 0, 0)   // inside zone(1, origin: 0,0,0)
    let zones = [zone(1, SIMD3<Float>(0, 0, 0))]
    var working = defaultWorking()
    working[0].anchor = 0

    // Point goes nil while primaryActive is somehow still reported true --
    // the ARKit-lost case. Must release at the LAST point this function was
    // given, never jump to the origin or stay stuck.
    do {
        let grab = HudEditor.GrabState(tileID: 0, lastPoint: lastGood, secondPinch: nil)
        let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: nil)
        let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                     tiles: [], zones: zones, dt: 1.0 / 90.0)
        check(r.grab == nil, "a lost hand/controller releases the grab, doesn't stick")
        check(r.working[0].anchor == 1 && r.working[0].show == true,
              "the release resolves against lastPoint's zone, not the origin")
        let expectedOffset = HudEditor.offsetInFrame(point: lastGood, origin: zones[0].origin,
                                                      right: zones[0].right, up: zones[0].up,
                                                      forward: zones[0].forward)
        check(simd_distance(r.working[0].offset, expectedOffset) < 1e-5,
              "the released offset is computed from the LAST GOOD point, not the origin")
    }

    // primaryActive reported false outright (a plain release) takes the
    // same path -- same guarantee, different cause.
    do {
        let grab = HudEditor.GrabState(tileID: 0, lastPoint: lastGood, secondPinch: nil)
        let input = HudEditor.GrabInput(primaryActive: false, primaryPoint: nil)
        let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                     tiles: [], zones: zones, dt: 1.0 / 90.0)
        check(r.grab == nil, "a deliberate release also ends the grab")
        check(r.working[0].anchor == 1, "a deliberate release resolves the same way as a lost hand")
    }

    // A release over NOTHING (no zone in range of lastPoint) keeps the
    // previous anchor, shown -- never a jump to the origin, never an
    // un-anchored tile either (same contract resolveDrop already proves,
    // exercised here through the grab's own last-good point).
    do {
        working[0].anchor = 7
        let farFromAnyZone = SIMD3<Float>(99, 99, 99)
        let grab = HudEditor.GrabState(tileID: 0, lastPoint: farFromAnyZone, secondPinch: nil)
        let input = HudEditor.GrabInput(primaryActive: false, primaryPoint: nil)
        let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                     tiles: [], zones: zones, dt: 1.0 / 90.0)
        check(r.working[0].anchor == 7 && r.working[0].show == true,
              "releasing over nothing keeps the previous anchor, shown -- not a jump to the origin")
    }
}

// MARK: - two-hand scale

func runTwoHandScaleTests() {
    var working = defaultWorking()
    working[0].scale = 1.0

    // Frame 1: the second pinch APPEARS. No baseline yet, so no scale
    // change -- just records where it is.
    let grab0 = HudEditor.GrabState(tileID: 0, lastPoint: SIMD3<Float>(0, 0, 0), secondPinch: nil)
    let input1 = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0, 0, 0),
                                     secondaryActive: true, secondaryPoint: SIMD3<Float>(0.2, 0, 0))
    let r1 = HudEditor.updateGrab(grab: grab0, input: input1, working: working,
                                  tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r1.working[0].scale == 1.0, "the first frame a second pinch appears sets a baseline, not a scale jump")
    check(r1.grab?.secondPinch == SIMD3<Float>(0.2, 0, 0), "the second pinch's point is recorded as the new baseline")

    // Frame 2: the gap doubles (0.2 -> 0.4m, primary held still) -- scale
    // should double too.
    let input2 = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0, 0, 0),
                                     secondaryActive: true, secondaryPoint: SIMD3<Float>(0.4, 0, 0))
    let r2 = HudEditor.updateGrab(grab: r1.grab, input: input2, working: r1.working,
                                  tiles: [], zones: [], dt: 1.0 / 90.0)
    check(abs(r2.working[0].scale - 2.0) < 1e-4, "doubling the two-pinch gap doubles the scale")

    // Scale is clamped: a huge gap jump doesn't run away past scaleMax.
    let input3 = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0, 0, 0),
                                     secondaryActive: true, secondaryPoint: SIMD3<Float>(400, 0, 0))
    let r3 = HudEditor.updateGrab(grab: r2.grab, input: input3, working: r2.working,
                                  tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r3.working[0].scale == HudEditor.scaleMax, "scale is clamped at scaleMax, never runs away")
}

// MARK: - one-hand-tracked scale no-op (Review Focus #5)

func runOneHandScaleNoOpTests() {
    var working = defaultWorking()
    working[0].scale = 1.5
    let grab = HudEditor.GrabState(tileID: 0, lastPoint: SIMD3<Float>(0, 0, 0),
                                   secondPinch: SIMD3<Float>(0.2, 0, 0))   // a live baseline from last frame

    // The second hand drops OUT (secondaryActive true but no point -- the
    // "only one hand is tracked" case) while the primary keeps moving.
    let movedPoint = SIMD3<Float>(0.05, 0, 0)
    let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: movedPoint,
                                    secondaryActive: true, secondaryPoint: nil)
    let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                 tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r.working[0].scale == 1.5, "a missing second pinch point leaves scale untouched -- never a garbage scale")
    check(r.grab?.lastPoint == movedPoint, "the tile keeps moving even though scale is a no-op this frame")
    check(r.grab?.secondPinch == nil, "the dropped baseline is cleared, not frozen, for a future fresh pinch")

    // The second hand's ACTIVE flag itself goes false (gesture released,
    // not just untracked) -- same no-op guarantee.
    let input2 = HudEditor.GrabInput(primaryActive: true, primaryPoint: movedPoint,
                                     secondaryActive: false, secondaryPoint: nil)
    let r2 = HudEditor.updateGrab(grab: grab, input: input2, working: working,
                                  tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r2.working[0].scale == 1.5, "secondaryActive false also leaves scale untouched")

    // Only one hand EVER tracked (no secondPinch baseline, no secondary
    // this frame either) -- scale stays put and the grab/move still works.
    let soloGrab = HudEditor.GrabState(tileID: 0, lastPoint: SIMD3<Float>(0, 0, 0), secondPinch: nil)
    let input3 = HudEditor.GrabInput(primaryActive: true, primaryPoint: movedPoint,
                                     secondaryActive: false, secondaryPoint: nil)
    let r3 = HudEditor.updateGrab(grab: soloGrab, input: input3, working: working,
                                  tiles: [], zones: [], dt: 1.0 / 90.0)
    check(r3.working[0].scale == 1.5, "a grab that never had a second hand never scales from thin air")
    check(r3.grab?.lastPoint == movedPoint, "single-hand move still tracks correctly")
}

// MARK: - controller thumbstick scale

func runStickScaleTests() {
    var working = defaultWorking()
    working[0].scale = 1.0
    let grab = HudEditor.GrabState(tileID: 0, lastPoint: SIMD3<Float>(0, 0, 0), secondPinch: nil)
    let input = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0, 0, 0),
                                    stickScaleAxis: 1.0)
    let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                 tiles: [], zones: [], dt: 0.5)
    check(abs(r.working[0].scale - (1.0 + HudEditor.stickScaleRate * 0.5)) < 1e-4,
          "a held thumbstick axis scales at stickScaleRate * dt, independent of any second point")

    // A resting stick (within the plumbing's own deadzone, reported as nil)
    // changes nothing.
    let input2 = HudEditor.GrabInput(primaryActive: true, primaryPoint: SIMD3<Float>(0, 0, 0),
                                     stickScaleAxis: nil)
    let r2 = HudEditor.updateGrab(grab: grab, input: input2, working: working,
                                  tiles: [], zones: [], dt: 0.5)
    check(r2.working[0].scale == 1.0, "no stick axis reported leaves scale untouched")
}

// MARK: - tray-recall confirmation

func runTrayRecallTests() {
    // A tile parked in the hidden tray: show == false, but its anchor is
    // whatever zone it was last actually shown at (resolveDrop's own
    // contract -- the tray hides a tile without un-anchoring it). Dragging
    // it out and releasing over a DIFFERENT zone must go through
    // resolveDrop and get that zone's fresh anchor+offset -- never keep a
    // leftover tray-relative offset, and never flip show true without
    // re-resolving.
    var working = defaultWorking()
    working[0].anchor = 1          // last shown at zone 1 (e.g. WRIST)
    working[0].offset = SIMD3<Float>(99, 99, 99)   // a stale/garbage offset from being tray-parked
    working[0].show = false

    let trayOrigin = SIMD3<Float>(0, -1, 0)
    let trayTile = HudEditor.TileFrame(tileID: 0, origin: trayOrigin,
                                       right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                                       halfW: 0.1, halfH: 0.1)

    // Grab it where the tray actually renders it.
    let grabInput = HudEditor.GrabInput(primaryActive: true, primaryPoint: trayOrigin)
    let started = HudEditor.updateGrab(grab: nil, input: grabInput, working: working,
                                       tiles: [trayTile], zones: [], dt: 1.0 / 90.0)
    check(started.grab?.tileID == 0, "a tray-parked tile can be grabbed from where it's actually drawn")

    // Drag it to zone 2 (e.g. GUN) and release there.
    let gunZone = zone(2, SIMD3<Float>(1, 0, 0))
    let dropPoint = SIMD3<Float>(1.05, 0.02, 0)
    let moved = HudEditor.updateGrab(grab: started.grab, input: HudEditor.GrabInput(
        primaryActive: true, primaryPoint: dropPoint), working: started.working,
        tiles: [], zones: [], dt: 1.0 / 90.0)
    let released = HudEditor.updateGrab(grab: moved.grab, input: HudEditor.GrabInput(
        primaryActive: false, primaryPoint: nil), working: moved.working,
        tiles: [], zones: [gunZone], dt: 1.0 / 90.0)

    check(released.grab == nil, "releasing over the new zone ends the grab")
    check(released.working[0].anchor == 2, "recall from the tray adopts the NEW zone's anchor, not the old one")
    check(released.working[0].show == true, "recall from the tray shows the tile")
    let expectedOffset = HudEditor.offsetInFrame(point: dropPoint, origin: gunZone.origin,
                                                  right: gunZone.right, up: gunZone.up, forward: gunZone.forward)
    check(simd_distance(released.working[0].offset, expectedOffset) < 1e-5,
          "the offset is FRESH, relative to the new zone's own frame -- no leftover tray offset")
}

// MARK: - review fix: a grab stays bound to its originating source

func runSourceStickinessTests() {
    // A grab is bound to the CONTROLLER source. The controller then goes
    // INACTIVE (disconnected / out of range) while a HAND is actively
    // pinched elsewhere -- the exact scenario the fix addresses. The grab
    // must release at the controller's own last point, never silently
    // hand off to the hand that happens to be live this tick.
    let lastGood = SIMD3<Float>(0.2, 0, 0)
    let zones = [zone(3, SIMD3<Float>(0, 0, 0))]
    var working = defaultWorking()
    working[0].anchor = 0

    let grab = HudEditor.GrabState(tileID: 0, lastPoint: lastGood, secondPinch: nil)
    let controllerGone = HudEditor.SourceSignal(active: false, point: nil)
    let handLeftLive = HudEditor.SourceSignal(active: true, point: SIMD3<Float>(5, 5, 5))
    let handRightIdle = HudEditor.SourceSignal(active: false, point: nil)

    let input = HudEditor.grabInput(for: .controller, controller: controllerGone,
                                    handLeft: handLeftLive, handRight: handRightIdle,
                                    stickScaleAxis: nil)
    check(input.primaryActive == false,
          "a grab bound to the controller reports the CONTROLLER's own (inactive) signal")
    check(input.primaryPoint == nil,
          "...never a live hand's point, even though a hand is actively pinching elsewhere")

    let r = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                 tiles: [], zones: zones, dt: 1.0 / 90.0)
    check(r.grab == nil, "the grab releases instead of silently switching to the hand that's live")
    check(r.working[0].anchor == 3,
          "the release resolves against the CONTROLLER's lastPoint, not a hand's position")

    // Symmetric sanity: a grab bound to a HAND keeps using that hand's own
    // signal (and the OTHER hand as its two-point scale secondary) even
    // while a controller is tracking and active -- the hand doesn't lose
    // its own grab to the controller either.
    do {
        let controllerLive = HudEditor.SourceSignal(active: true, point: SIMD3<Float>(9, 9, 9))
        let handLeftNow = HudEditor.SourceSignal(active: true, point: SIMD3<Float>(0.01, 0, 0))
        let handRightNow = HudEditor.SourceSignal(active: true, point: SIMD3<Float>(0.3, 0, 0))
        let input2 = HudEditor.grabInput(for: .handLeft, controller: controllerLive,
                                         handLeft: handLeftNow, handRight: handRightNow, stickScaleAxis: nil)
        check(input2.primaryPoint == handLeftNow.point, "a grab bound to the LEFT hand keeps using the left hand's point")
        check(input2.secondaryPoint == handRightNow.point, "...and the RIGHT hand as its two-hand-scale secondary")
        check(input2.stickScaleAxis == nil, "...never a controller stick axis, even though a controller is tracking")
    }

    // A grab bound to the controller carries its stick-scale axis through
    // untouched, ignoring both hands entirely (no two-point secondary).
    do {
        let controllerLive = HudEditor.SourceSignal(active: true, point: SIMD3<Float>(1, 0, 0))
        let input3 = HudEditor.grabInput(for: .controller, controller: controllerLive,
                                         handLeft: HudEditor.SourceSignal(active: true, point: SIMD3<Float>(9, 9, 9)),
                                         handRight: HudEditor.SourceSignal(active: true, point: SIMD3<Float>(8, 8, 8)),
                                         stickScaleAxis: 0.5)
        check(input3.primaryPoint == controllerLive.point, "a grab bound to the controller uses the controller's point")
        check(input3.secondaryActive == false, "...and never a two-hand secondary (controllers scale from the stick)")
        check(input3.stickScaleAxis == 0.5, "...the stick axis passes through")
    }
}

// MARK: - wrist grid snap + footprint gestures (Task 5)

func runWristGrabTests() {
    let off = HudEditor.WristFrame(anchor: 0, origin: .zero,
                                   right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                   forward: SIMD3(0,0,1), valid: true)
    let gun = HudEditor.WristFrame(anchor: 1, origin: SIMD3(1,0,0),
                                   right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                   forward: SIMD3(0,0,1), valid: true)
    var working = [HudEditor.TileEdit(anchor: 0, offset: .zero, scale: 1, show: true,
                                      slot: 0, spanW: 1, spanH: 1)]
    let frame = HudEditor.TileFrame(tileID: 0, origin: .zero,
                                    right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                    halfW: 0.05, halfH: 0.05)

    // Release over the off-wrist bottom-right cell snaps the tile to slot 3.
    let grab = HudEditor.GrabState(tileID: 0,
        lastPoint: SIMD3(HudEditor.cellPitch*0.5, -HudEditor.cellPitch*0.5, 0),
        secondPinch: nil)
    let release = HudEditor.GrabInput(primaryActive: false,
        primaryPoint: SIMD3(HudEditor.cellPitch*0.5, -HudEditor.cellPitch*0.5, 0))
    let r = HudEditor.updateGrab(grab: grab, input: release, working: working,
                                 tiles: [frame], zones: [], off: off, gun: gun, dt: 0.011)
    assert(r.working[0].slot == 3 && r.working[0].anchor == 0, "snaps to off-wrist slot 3")
    assert(r.grab == nil, "released")

    // A two-hand hold across the off-wrist diagonal makes a 2x2 footprint.
    let twoHand = HudEditor.GrabInput(primaryActive: true,
        primaryPoint: SIMD3(-HudEditor.cellPitch*0.5, HudEditor.cellPitch*0.5, 0),  // TL
        secondaryActive: true,
        secondaryPoint: SIMD3(HudEditor.cellPitch*0.5, -HudEditor.cellPitch*0.5, 0)) // BR
    let held = HudEditor.GrabState(tileID: 0, lastPoint: twoHand.primaryPoint!, secondPinch: twoHand.secondaryPoint)
    let r2 = HudEditor.updateGrab(grab: held, input: twoHand, working: working,
                                  tiles: [frame], zones: [], off: off, gun: gun, dt: 0.011)
    assert(r2.working[0].spanW == 2 && r2.working[0].spanH == 2, "diagonal two-hand -> 2x2")

    // Invalid wrist mid-grab must not write NaN and must not crash.
    let bad = HudEditor.WristFrame(anchor: 0, origin: SIMD3(.nan,.nan,.nan),
                                   right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                   forward: SIMD3(0,0,1), valid: false)
    let r3 = HudEditor.updateGrab(grab: grab, input: release, working: working,
                                  tiles: [frame], zones: [], off: bad, gun: bad, dt: 0.011)
    assert(r3.working[0].offset.x.isFinite && r3.working[0].offset.y.isFinite
           && r3.working[0].offset.z.isFinite, "no NaN written with invalid wrists")

    print("wrist grab tests ok")
}

// MARK: - two-hand stretch over an occupied cell (final-review Important 2)

// The default layout has FACE at off-wrist slot 0 (top-left) and HEALTHARMOR
// at off-wrist slot 2 (bottom-left), both shown. Grabbing FACE and stretching
// it DOWN toward HEALTHARMOR's cell with a two-hand hold used to grow FACE's
// footprint live to 1x2 (cells {0,2}) with no occupancy check, and the
// occupied-drop "reject" path then returned that already-grown entry -- so
// FACE ended up spanning HEALTHARMOR's reserved cell 2. After the fix the
// stretch into an occupied cell is refused (clamped live and restored on
// reject), so FACE never covers cell 2.
func runWristStretchOccupancyTests() {
    let off = HudEditor.WristFrame(anchor: 0, origin: .zero,
                                   right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                   forward: SIMD3(0,0,1), valid: true)
    let gun = HudEditor.WristFrame.invalid

    // index 0 = FACE (off-wrist, slot 0, 1x1); index 1 = HEALTHARMOR (off-wrist, slot 2, 1x1).
    var working = [
        HudEditor.TileEdit(anchor: 0, offset: .zero, scale: 1, show: true, slot: 0, spanW: 1, spanH: 1),
        HudEditor.TileEdit(anchor: 0, offset: .zero, scale: 1, show: true, slot: 2, spanW: 1, spanH: 1),
    ]

    // FACE's hit-test frame, drawn at its top-left cell centre.
    let tlCentre = SIMD3<Float>(-HudEditor.cellPitch * 0.5, HudEditor.cellPitch * 0.5, 0)
    let blCentre = SIMD3<Float>(-HudEditor.cellPitch * 0.5, -HudEditor.cellPitch * 0.5, 0)   // cell 2
    let faceFrame = HudEditor.TileFrame(tileID: 0, origin: tlCentre,
                                        right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                        halfW: 0.02, halfH: 0.02)

    // Grab FACE where it's drawn (top-left cell).
    let start = HudEditor.updateGrab(grab: nil,
        input: HudEditor.GrabInput(primaryActive: true, primaryPoint: tlCentre),
        working: working, tiles: [faceFrame], zones: [], off: off, gun: gun, dt: 0.011)
    check(start.grab?.tileID == 0, "stretch test: FACE grabbed from its top-left cell")

    // Two-hand stretch DOWN: primary stays on cell 0, secondary reaches cell 2
    // (HEALTHARMOR's). The previewed 1x2 footprint would cover the occupied
    // cell 2 -- it must not be applied.
    let stretch = HudEditor.GrabInput(primaryActive: true, primaryPoint: tlCentre,
                                      secondaryActive: true, secondaryPoint: blCentre)
    let dragging = HudEditor.updateGrab(grab: start.grab, input: stretch,
        working: start.working, tiles: [faceFrame], zones: [], off: off, gun: gun, dt: 0.011)
    let previewCells = HudEditor.spannedCells(slot: dragging.working[0].slot,
                                              spanW: dragging.working[0].spanW,
                                              spanH: dragging.working[0].spanH)
    check(!previewCells.contains(2),
          "a live two-hand stretch never previews FACE over HEALTHARMOR's reserved cell 2")

    // Release: the occupied drop must leave FACE off cell 2 (snapped back /
    // clamped to a legal footprint), and must not disturb HEALTHARMOR.
    let release = HudEditor.updateGrab(grab: dragging.grab,
        input: HudEditor.GrabInput(primaryActive: false, primaryPoint: nil),
        working: dragging.working, tiles: [faceFrame], zones: [], off: off, gun: gun, dt: 0.011)
    let faceCells = HudEditor.spannedCells(slot: release.working[0].slot,
                                           spanW: release.working[0].spanW,
                                           spanH: release.working[0].spanH)
    check(release.grab == nil, "stretch test: released")
    check(!faceCells.contains(2),
          "after a rejected stretch+release FACE does NOT span HEALTHARMOR's cell 2")
    check(release.working[1].slot == 2 && release.working[1].spanW == 1 && release.working[1].spanH == 1,
          "HEALTHARMOR's own footprint is untouched by FACE's rejected stretch")

    print("wrist stretch occupancy tests ok")
}
