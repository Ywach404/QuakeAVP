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
