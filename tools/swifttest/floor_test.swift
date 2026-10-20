// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  floor_test.swift
//
//  Host-run test for the immersive floor anchor's pure math,
//  App/Sources/FloorMath.swift: which detected plane is the floor, where
//  the Quake point at the tracking origin goes once the player's feet are
//  on that floor, what the engine is told the eye is above vieworg, and
//  the recenter correction that keeps height. Compiled and linked ALONE
//  against that one file by tools/check-swift-floor.sh -- no ARKit, no
//  Metal, no engine.
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

func near(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) < eps }

/// Same direction, allowing for the turn of the circle. atan2 of a
/// negative zero puts a wall dead ahead of you at -180 rather than +180,
/// which is the same wall; the engine takes the direction modulo 90 and
/// could not tell them apart either.
func nearAngle(_ a: Float, _ b: Float, _ eps: Float = 0.01) -> Bool {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return abs(d) < eps
}

func cand(_ y: Float, _ area: Float, _ dist: Float) -> FloorMath.FloorCandidate {
    FloorMath.FloorCandidate(y: y, area: area, horizontalDistance: dist)
}

@main
struct FloorTest {
    static func main() {
        runSelectTests()
        runAnchorTests()
        runCorrectionTests()
        runWallTests()
        print("PASSED")
    }

    static func runSelectTests() {
        check(FloorMath.select([cand(0.7, 2, 1), cand(0.0, 4, 1)], current: nil, headY: 1.1) == 0.0,
              "select_rejectsPlaneAboveHead: a 0.7 m 'floor' under a 1.1 m head loses to the real floor")
        check(FloorMath.select([cand(0.7, 2, 1)], current: nil, headY: 1.1) == nil,
              "select_rejectsPlaneAboveHead: alone, it is rejected outright")
        check(FloorMath.select([cand(0.1, 3, 1), cand(0.0, 1, 1)], current: nil, headY: 1.6) == 0.0,
              "select_prefersLowest")
        check(FloorMath.select([cand(0.0, 0.3, 1), cand(0.0, 3, 3.0)], current: nil, headY: 1.6) == nil,
              "select_rejectsSmallAndFar")
        // the caller keeps the current plane in the candidate list
        check(FloorMath.select([cand(0.0, 2, 1), cand(0.01, 1, 1)], current: 0.0, headY: 1.6) == 0.0,
              "select_keepsCurrentUnlessLowerOrLarger: a plane 1 cm up does not replace it")
        check(FloorMath.select([cand(0.0, 2, 1), cand(-0.05, 1, 1)], current: 0.0, headY: 1.6) == -0.05,
              "select_keepsCurrentUnlessLowerOrLarger: a lower plane does")
        check(FloorMath.select([cand(0.0, 2, 1), cand(0.01, 5, 1)], current: 0.0, headY: 1.6) == 0.01,
              "select_keepsCurrentUnlessLowerOrLarger: a larger plane at the same height does")
        check(FloorMath.select([cand(0.0, 2, 1), cand(0.7, 5, 1)], current: 0.0, headY: 1.7) == 0.0,
              "select_rejectsPlaneAboveHead: a larger 'floor' 0.7 m up never beats the floor under a standing head")
        check(FloorMath.select([cand(0.12, 1, 1)], current: nil, headY: 1.6) == 0.12,
              "select_freshLifeTakesFirstPlane")

        // "Lowest wins" is only true among surfaces you could be standing
        // on. A plane metres below the head is another storey, a stairwell
        // or a detection artefact, and taking it drops the whole world.
        check(FloorMath.select([cand(0.0, 4, 1), cand(-8.0, 4, 1)], current: nil, headY: 1.78) == 0.0,
              "select_rejectsImplausiblyDeepPlane: 9.8 m below the head is not your floor")
        check(FloorMath.select([cand(-8.0, 4, 1)], current: nil, headY: 1.78) == nil,
              "select_rejectsImplausiblyDeepPlane: alone, it is rejected outright")
        check(FloorMath.select([cand(0.0, 4, 1), cand(-8.0, 4, 1)], current: -8.0, headY: 1.78) == 0.0,
              "select_rejectsImplausiblyDeepPlane: and a deep plane already chosen is abandoned")
        // Seated on the floor still leaves the head well inside the band.
        check(FloorMath.select([cand(0.0, 4, 1)], current: nil, headY: 0.9) == 0.0,
              "select: a floor is still found from a low seated head")

        // Distance is to the nearest point of the plane's extent, not its
        // centre: a big room's floor has its centre metres away while you
        // stand on it.
        check(near(FloorMath.extentDistance(headInExtent: SIMD3(0.5, 1.6, 0.2), halfWidth: 3, halfHeight: 2), 0),
              "extentDistance: a head over the plane is at distance zero")
        check(near(FloorMath.extentDistance(headInExtent: SIMD3(4, 1.6, 0), halfWidth: 3, halfHeight: 2), 1),
              "extentDistance: one metre past the edge is one metre")
        check(near(FloorMath.extentDistance(headInExtent: SIMD3(6, 1.6, 6), halfWidth: 3, halfHeight: 2), 5),
              "extentDistance: past a corner is the corner distance (3-4-5)")
    }

    static func runAnchorTests() {
        let s: Float = 0.0254
        // vieworg is the entity origin plus viewheight; the feet are the
        // origin minus the hull bottom, 24 units. Eye 146 -> origin 124 ->
        // feet 100.
        check(near(FloorMath.anchorZ(vieworgZ: 146, viewheight: 22, floorYRoom: 0, worldScale: s, trimMetres: 0), 100),
              "anchorZ_usesEyeNotOrigin: eye 146 minus viewheight 22 minus the hull bottom 24 is the feet at 100")
        check(near(FloorMath.anchorZ(vieworgZ: 146, viewheight: 22, floorYRoom: -0.0254, worldScale: s, trimMetres: 0), 101),
              "anchorZ_usesEyeNotOrigin: a floor one unit below the origin raises the anchor one unit")
        check(near(FloorMath.anchorZ(vieworgZ: 146, viewheight: 22, floorYRoom: 0, worldScale: s, trimMetres: 0.0254), 101),
              "anchorZ: one unit of trim raises the world one unit")
        // The floor is measured raw; the anchor works in the corrected
        // frame. A height-zeroing correction carries minus the recenter
        // height in its translation; a height-keeping one carries zero.
        var zeroing = matrix_identity_float4x4
        zeroing.columns.3 = SIMD4(0.3, -1.6, 0.2, 1)
        check(near(FloorMath.floorYRoom(raw: 0.05, correction: zeroing), 0.05 - 1.6),
              "floorYRoom: under a height-zeroing correction the floor is head-relative")
        var keeping = matrix_identity_float4x4
        keeping.columns.3 = SIMD4(0.3, 0, 0.2, 1)
        check(near(FloorMath.floorYRoom(raw: 0.05, correction: keeping), 0.05),
              "floorYRoom: under a height-keeping correction the floor is its raw height")
        check(near(FloorMath.fallbackAnchorZ(vieworgZ: 100, worldScale: s, trimMetres: 0), 100 + 0.4 / s, 1e-3),
              "fallbackAnchorZ_matchesToday")
        check(near(FloorMath.fallbackAnchorZ(vieworgZ: 100, worldScale: s, trimMetres: 0.1), 100 + 0.5 / s, 1e-3),
              "fallbackAnchorZ: the trim adds to the baked 0.40")
        check(near(FloorMath.effectiveTrim(anchorZ: 124, cameraYRoom: 1.65, vieworgZ: 146, worldScale: s),
                   124 + 1.65 / s - 146, 1e-2),
              "effectiveTrim_isCameraAboveVieworg")
        check(near(FloorMath.eased(from: 0, to: 10, progress: 0), 0), "eased_endpoints: start")
        check(near(FloorMath.eased(from: 0, to: 10, progress: 1), 10), "eased_endpoints: end")
        check(near(FloorMath.eased(from: 0, to: 10, progress: 0.5), 5), "eased_endpoints: midpoint")
        check(near(FloorMath.eased(from: 0, to: 10, progress: 2), 10), "eased: progress past 1 clamps")
    }

    static func runCorrectionTests() {
        let yaw: Float = 30 * .pi / 180
        var pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(1, 1.6, 2, 1)

        let zeroed = FloorMath.correction(zeroing: pose, keepHeight: false) * pose
        let t0 = zeroed.columns.3
        check(near(t0.x, 0) && near(t0.y, 0) && near(t0.z, 0),
              "correction_keepHeightLeavesY: without keepHeight the pose lands at the origin")

        let kept = FloorMath.correction(zeroing: pose, keepHeight: true) * pose
        let t1 = kept.columns.3
        check(near(t1.x, 0) && near(t1.y, 1.6) && near(t1.z, 0),
              "correction_keepHeightLeavesY: with keepHeight only x and z are zeroed")

        // yaw is undone either way: the corrected forward points down -Z
        let f = -(kept.columns.2)
        check(near(f.x, 0) && near(f.z, -1),
              "correction: yaw is neutralised with keepHeight too")
    }

    /// Room alignment publishes wall directions to the engine, and the
    /// engine adds body_yaw and nothing else. So the whole frame
    /// convention lives here: atan2(-x, -z) over the CORRECTED normal,
    /// zero straight ahead, increasing to the left like a Quake yaw. An
    /// inverted sign survives a square room untouched, so these tests
    /// use angles that are neither 0 nor 45.
    static func runWallTests() {
        let r = matrix_identity_float3x3

        // A wall ahead of you: its normal faces back at you, along +Z.
        var dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0, 1), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 180, 0.01),
              "walls: a normal along +Z reads 180 (got \(dirs.first?.degrees ?? -999))")

        // Straight ahead, -Z, is zero.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0, -1), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 0, 0.01),
              "walls: a normal along -Z reads 0")

        // LEFT is positive, the same sense as a Quake yaw. Left is -X.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(-1, 0, 0), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 90, 0.01),
              "walls: a normal to the left reads +90 (got \(dirs.first?.degrees ?? -999))")
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(1, 0, 0), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, -90, 0.01),
              "walls: a normal to the right reads -90")

        // A 23-degree wall, the kind of angle that catches a sign error.
        let a: Float = 23 * .pi / 180
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(-sin(a), 0, -cos(a)), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 23, 0.01),
              "walls: a wall 23 degrees to the left reads +23 (got \(dirs.first?.degrees ?? -999))")

        // The recenter correction's rotation is applied, not ignored: with
        // the player recentred 40 degrees round, the same real wall reads
        // 40 degrees further on.
        let yaw: Float = 40 * .pi / 180
        let rot = simd_float3x3(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0, -1), area: 6)],
            rotation: rot, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 40, 0.01),
              "walls: the correction's rotation is applied (got \(dirs.first?.degrees ?? -999))")

        // Floors and ceilings are not walls, however large.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 1, 0), area: 20),
             FloorMath.WallPlane(normal: SIMD3(0, -1, 0), area: 20)],
            rotation: r, limit: 16)
        check(dirs.isEmpty, "walls: a horizontal normal is not a wall")

        // A sloped surface is not a wall either.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0.6, -0.8), area: 20)],
            rotation: r, limit: 16)
        check(dirs.isEmpty, "walls: a sloped normal is not a wall")

        // Slivers are dropped: a door frame's edge is not evidence.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0, -1), area: 0.1)],
            rotation: r, limit: 16)
        check(dirs.isEmpty, "walls: a sliver is dropped")

        // Heaviest first, and clamped to the limit -- the engine's table is
        // fixed, so the walls that survive must be the ones worth keeping.
        let many = (0..<20).map { i in
            FloorMath.WallPlane(normal: SIMD3(0, 0, -1), area: Float(i + 1))
        }
        dirs = FloorMath.wallDirections(many, rotation: r, limit: 16)
        check(dirs.count == 16, "walls: the table is clamped to the limit")
        check(near(dirs[0].weight, 20) && near(dirs[15].weight, 5),
              "walls: heaviest first, so the clamp drops the smallest")

        // Weight is area, verbatim: the engine's own threshold is in square
        // metres and a rescale here would make that number mean nothing.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(0, 0, -1), area: 7.5)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && near(dirs[0].weight, 7.5),
              "walls: weight is the area in square metres")

        // An unnormalised normal still reads its direction.
        dirs = FloorMath.wallDirections(
            [FloorMath.WallPlane(normal: SIMD3(-3, 0, -3), area: 6)],
            rotation: r, limit: 16)
        check(dirs.count == 1 && nearAngle(dirs[0].degrees, 45, 0.01),
              "walls: the normal need not be unit length")

        // Nothing detected is an empty table, not a zero-direction one.
        check(FloorMath.wallDirections([], rotation: r, limit: 16).isEmpty,
              "walls: no planes publishes nothing")
    }
}
