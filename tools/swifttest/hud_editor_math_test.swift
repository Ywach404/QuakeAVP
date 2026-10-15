// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  hud_editor_math_test.swift
//
//  Host-run test for the HUD live editor's pure placement math
//  (App/Sources/HudEditorMath.swift). Compiled and linked ALONE against
//  that one file by tools/check-swift-math.sh -- no ARKit/Metal/Observation,
//  no simulator, no app module. Swift pure-logic is tested with this host
//  harness instead, per the repo's "no simulator while a headset is
//  connected" workflow.
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
// under `-Onone`), and check-swift-math.sh builds with `-O` -- so the grid
// tests below, which use bare `assert(...)` per the brief, need their own
// override of the exact same shape as `check` or they'd pass vacuously no
// matter what the math does. This overload's concrete (non-autoclosure)
// `Bool`/`String` parameters win over the stdlib's autoclosure version for
// every call site here, so it's the one that actually runs.
func assert(_ condition: Bool, _ label: String) {
    check(condition, label)
}

func assertEqual(_ a: Set<Int>, _ b: Set<Int>, _ label: String) {
    check(a == b, label)
}

// A `swiftc` multi-file compile only grants top-level executable statements
// to a file literally named `main.swift`; this file keeps its own name (it
// reads as a test, not an entry point) and wraps its body in `@main`
// instead, which is a declaration, not a top-level statement.
@main
struct HudEditorMathTest {
    static func main() {
        runOffsetInFrameTests()
        runPointInTileTests()
        runResolveDropTests()
        runGridTests()
        print("PASSED (hud_editor_math_test.swift)")
    }
}

// MARK: - offsetInFrame round-trips: build a point from a frame + offset,
// recover the same offset by projecting back onto the frame's axes.

func runOffsetInFrameTests() {
    do {
        let o = SIMD3<Float>(1, 2, 3)
        let r = SIMD3<Float>(1, 0, 0)
        let u = SIMD3<Float>(0, 1, 0)
        let f = SIMD3<Float>(0, 0, 1)
        let p = o + r * 0.1 + u * (-0.05) + f * 0.2
        let off = HudEditor.offsetInFrame(point: p, origin: o, right: r, up: u, forward: f)
        check(abs(off.x - 0.1) < 1e-5 && abs(off.y + 0.05) < 1e-5 && abs(off.z - 0.2) < 1e-5,
              "offsetInFrame round-trips an axis-aligned frame")
    }

    // A non-axis-aligned (but still orthonormal) frame must round-trip too
    // -- otherwise offsetInFrame would only be correct for the lucky case.
    do {
        let o = SIMD3<Float>(5, -1, 2)
        let r = simd_normalize(SIMD3<Float>(1, 0, 1))
        let f = SIMD3<Float>(0, 1, 0)
        let u = simd_cross(f, r)
        let p = o + r * 0.3 + u * 0.4 + f * (-0.2)
        let off = HudEditor.offsetInFrame(point: p, origin: o, right: r, up: u, forward: f)
        check(abs(off.x - 0.3) < 1e-5 && abs(off.y - 0.4) < 1e-5 && abs(off.z + 0.2) < 1e-5,
              "offsetInFrame round-trips a rotated orthonormal frame")
    }
}

// MARK: - pointInTile

func runPointInTileTests() {
    let origin = SIMD3<Float>(0, 0, 0)
    let right = SIMD3<Float>(1, 0, 0)
    let up = SIMD3<Float>(0, 1, 0)
    let inside = SIMD3<Float>(0.05, 0.02, 0)
    let outside = SIMD3<Float>(0.2, 0, 0)
    check(HudEditor.pointInTile(hit: inside, tileOrigin: origin, right: right, up: up, halfW: 0.1, halfH: 0.1),
          "pointInTile: a point inside the half-extents hits")
    check(!HudEditor.pointInTile(hit: outside, tileOrigin: origin, right: right, up: up, halfW: 0.1, halfH: 0.1),
          "pointInTile: a point outside the half-extents misses")
}

// MARK: - resolveDrop

func runResolveDropTests() {
    // Review Focus #2: drop over NO zone must keep the PREVIOUS anchor with
    // show: true -- never silently un-anchor the tile.
    do {
        let d = HudEditor.resolveDrop(point: SIMD3<Float>(9, 9, 9), zones: [], previousAnchor: 1)
        check(d.anchor == 1 && d.show == true, "resolveDrop over no zone keeps the previous anchor, shown")
    }

    // Dropping inside a real zone's radius adopts that zone's anchor and
    // shows the tile, with the offset recomputed against the zone's own
    // frame.
    do {
        let zone = HudEditor.Zone(anchor: 2, origin: SIMD3<Float>(0, 0, 0),
                                   right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                                   forward: SIMD3<Float>(0, 0, 1), radius: 0.5, isHiddenTray: false)
        let point = SIMD3<Float>(0.1, 0.1, 0)
        let d = HudEditor.resolveDrop(point: point, zones: [zone], previousAnchor: 0)
        check(d.anchor == 2 && d.show == true, "resolveDrop over a zone adopts that zone's anchor, shown")
        check(abs(d.offset.x - 0.1) < 1e-5 && abs(d.offset.y - 0.1) < 1e-5,
              "resolveDrop's offset is relative to the zone's own frame")
    }

    // Dropping on the hidden tray keeps the previous anchor but un-shows
    // the tile -- the show flag is what parks it, not the anchor.
    do {
        let tray = HudEditor.Zone(anchor: 0, origin: SIMD3<Float>(0, -1, 0),
                                   right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                                   forward: SIMD3<Float>(0, 0, 1), radius: 0.3, isHiddenTray: true)
        let d = HudEditor.resolveDrop(point: SIMD3<Float>(0, -1, 0), zones: [tray], previousAnchor: 1)
        check(d.anchor == 1 && d.show == false, "resolveDrop over the hidden tray keeps anchor, hides the tile")
    }

    // The nearest zone within its own radius wins on overlap.
    do {
        let near = HudEditor.Zone(anchor: 1, origin: SIMD3<Float>(0, 0, 0),
                                   right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                                   forward: SIMD3<Float>(0, 0, 1), radius: 1.0, isHiddenTray: false)
        let far = HudEditor.Zone(anchor: 2, origin: SIMD3<Float>(0.5, 0, 0),
                                  right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0),
                                  forward: SIMD3<Float>(0, 0, 1), radius: 1.0, isHiddenTray: false)
        let point = SIMD3<Float>(0.05, 0, 0)
        let d = HudEditor.resolveDrop(point: point, zones: [near, far], previousAnchor: 0)
        check(d.anchor == 1, "resolveDrop picks the nearest zone, not just the first in range")
    }
}

// MARK: - Wrist grid (Task 2)

func runGridTests() {
    // spannedCells on the 3x2 grid: 0 1 2 / 3 4 5
    assertEqual(HudEditor.spannedCells(slot: 0, spanW: 2, spanH: 1), [0, 1], "span 2x1 top row")
    assertEqual(HudEditor.spannedCells(slot: 0, spanW: 2, spanH: 2), [0, 1, 3, 4], "span 2x2 at TL (not the old 2x2-grid {0,1,2,3})")
    assertEqual(HudEditor.spannedCells(slot: 0, spanW: 3, spanH: 2), [0, 1, 2, 3, 4, 5], "span 3x2 covers the whole grid")
    assertEqual(HudEditor.spannedCells(slot: 5, spanW: 1, spanH: 1), [5], "1x1 BR (slot 5)")

    // clampFootprint: BR is now slot 5, and TR (slot 2) can't grow right
    assert(HudEditor.clampFootprint(slot: 5, spanW: 2, spanH: 2) == (1, 1), "slot 5 (BR) clamps to 1x1")
    assert(HudEditor.clampFootprint(slot: 2, spanW: 2, spanH: 1) == (1, 1), "TR (slot 2) cannot grow right")
    assert(HudEditor.clampFootprint(slot: 0, spanW: 2, spanH: 2) == (2, 2), "TL keeps 2x2")
    assert(HudEditor.clampFootprint(slot: 0, spanW: 3, spanH: 2) == (3, 2), "TL keeps the full 3x2 footprint")

    // wristCellOffset: a 1x1 at TL sits up-left; the middle column centres on
    // x; the full 3x2 footprint centres at the origin.
    let tl = HudEditor.wristCellOffset(slot: 0, spanW: 1, spanH: 1)
    assert(tl.offset.x < 0 && tl.offset.y > 0, "TL is up-left of centre")
    let topMid = HudEditor.wristCellOffset(slot: 1, spanW: 1, spanH: 1)
    assert(abs(topMid.offset.x) < 1e-5, "slot 1 (top-middle) centres on x")
    let full = HudEditor.wristCellOffset(slot: 0, spanW: 3, spanH: 2)
    assert(abs(full.offset.x) < 1e-5 && abs(full.offset.y) < 1e-5, "3x2 (full grid) centred")
    assert(full.size.x > tl.size.x, "3x2 wider than 1x1")

    // cellUnderPoint: identity wrist frame, origin at the grid centre
    let wf = HudEditor.WristFrame(anchor: 0, origin: .zero,
                                  right: SIMD3(1,0,0), up: SIMD3(0,1,0),
                                  forward: SIMD3(0,0,1), valid: true)
    let pTL = SIMD3<Float>(-HudEditor.cellPitch, HudEditor.cellPitch * 0.5, 0)
    assert(HudEditor.cellUnderPoint(pTL, frame: wf) == 0, "left column, top row -> slot 0")
    let pTopMid = SIMD3<Float>(0, HudEditor.cellPitch * 0.5, 0)
    assert(HudEditor.cellUnderPoint(pTopMid, frame: wf) == 1, "middle column, top row -> slot 1")
    let pBR = SIMD3<Float>(HudEditor.cellPitch, -HudEditor.cellPitch * 0.5, 0)
    assert(HudEditor.cellUnderPoint(pBR, frame: wf) == 5, "right column, bottom row -> slot 5 (BR)")
    let miss = SIMD3<Float>(1, 1, 0)
    assert(HudEditor.cellUnderPoint(miss, frame: wf) == nil, "far point misses grid")
    // A point dead-centre on cell 0 in x/y but well off the wrist PLANE in z
    // is not "over" the grid -- without a depth bound it would read as slot 0.
    let deepMiss = SIMD3<Float>(-HudEditor.cellPitch, HudEditor.cellPitch * 0.5, 0.5)
    assert(HudEditor.cellUnderPoint(deepMiss, frame: wf) == nil, "a point far off the wrist plane in z misses")
    // A point a hair off the plane (well within the depth tolerance) still
    // registers -- the bound must not reject normal reaching.
    let shallowHit = SIMD3<Float>(-HudEditor.cellPitch, HudEditor.cellPitch * 0.5, 0.01)
    assert(HudEditor.cellUnderPoint(shallowHit, frame: wf) == 0, "a point just off the plane still hits slot 0")

    // occupied: a 2x1 at slot 0 blocks a 1x1 drop at slot 1
    let blocker = HudEditor.TileEdit(anchor: 0, offset: .zero, scale: 1, show: true,
                                     slot: 0, spanW: 2, spanH: 1)
    assert(HudEditor.occupied([blocker], anchor: 0, cells: [1], excluding: 99),
           "slot 1 blocked by 2x1 at slot 0")
    assert(!HudEditor.occupied([blocker], anchor: 0, cells: [2], excluding: 99),
           "slot 2 free")
    assert(!HudEditor.occupied([blocker], anchor: 0, cells: [1], excluding: 0),
           "excluding the blocker itself frees the cell")

    // footprintFromCells on the 3x2 grid
    assert(HudEditor.footprintFromCells(0, 5) == (0, 3, 2), "0..5 -> the full 3x2 grid at slot 0")
    assert(HudEditor.footprintFromCells(0, 4) == (0, 2, 2), "0..4 -> 2x2 at slot 0")
    assert(HudEditor.footprintFromCells(3, 5) == (3, 3, 1), "bottom row -> 3x1 at slot 3")

    print("grid tests ok")
}
