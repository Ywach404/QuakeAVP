// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  FloorMath.swift
//
//  The immersive floor anchor's pure math: which detected plane is the
//  floor, where the Quake point at the tracking origin goes once the
//  player's feet stand on that floor, what the engine is told the rendered
//  eye is above vieworg, and the recenter correction that keeps height.
//
//  Compiled ALONE by tools/check-swift-floor.sh against its host test, so
//  this file imports only simd. ARKit types never reach it: the caller
//  reduces a plane anchor to a FloorCandidate first.
//

import simd

enum FloorMath {

    /// One horizontal plane classified as floor, reduced to what the
    /// selection needs. Metres, in the tracking frame the provider reports.
    struct FloorCandidate {
        var y: Float
        var area: Float
        var horizontalDistance: Float
    }

    /// Smallest plane that can be the floor; a cushion or a step is less.
    static let minimumArea: Float = 0.5
    /// Planes further than this from the head are another room's.
    static let maximumDistance: Float = 2.5
    /// A floor is never within this of the head: that is a table or a
    /// mis-read, and a seated head is still half a metre above the seat.
    static let headClearance: Float = 0.5
    /// Nor is it further below than this. "Lowest wins" holds only among
    /// surfaces you could be standing on; a plane metres down is another
    /// storey, a stairwell, or an artefact, and choosing it drops the whole
    /// world by that much. Generous enough for a tall player on a step.
    static let maximumDrop: Float = 2.5
    /// A plane has to be this much lower to replace the current one; the
    /// same floor re-reported a few millimetres off is not a new floor.
    static let replaceBelow: Float = 0.02
    /// A larger plane counts as the same floor, re-measured, only within
    /// this of the current height. Beyond it, a bigger plane is a bigger
    /// table, and the lowest plane wins.
    static let sameFloorBand: Float = 0.05
    /// Within this of a plane's extent you count as standing ON it, and a
    /// plane you are standing on outranks every plane you are not --
    /// however much lower the others are. Without that rank, lowest-wins
    /// handed the floor to a step down into a hallway, a sunken room or a
    /// stair landing: legitimately classified floor, inside the distance
    /// gate, lower, so it won outright. And it could never be given back,
    /// because every replacement rule below only ever goes lower.
    static let standingTolerance: Float = 0.3
    /// The player's hull bottom below the entity origin: where the feet
    /// are, in Quake units. vieworg is the origin plus viewheight.
    static let hullBottom: Float = 24

    /// The floor height to use, or nil when nothing qualifies. The caller
    /// keeps the current plane in `candidates` (it is a live anchor like
    /// any other), and `current` is the height chosen last time; the rule
    /// keeps it unless a qualifying plane is lower by `replaceBelow` or has
    /// a larger area than the current plane's.
    static func select(_ candidates: [FloorCandidate], current: Float?, headY: Float) -> Float? {
        let qualifying = candidates.filter {
            $0.area >= minimumArea
                && $0.horizontalDistance <= maximumDistance
                && $0.y <= headY - headClearance
                && $0.y >= headY - maximumDrop
        }
        // The planes you are standing on, if any. Everything below is
        // decided within this pool, so a lower plane you are NOT standing
        // on cannot take the floor from one you are. Over nothing -- off
        // the edge of what has been scanned -- the whole qualifying set is
        // the pool and lowest-wins is still the rule, because height is
        // then the only thing protecting you from a counter top.
        let underfoot = qualifying.filter { $0.horizontalDistance <= standingTolerance }
        let pool = underfoot.isEmpty ? qualifying : underfoot

        guard let lowest = pool.min(by: { $0.y < $1.y }) else { return nil }
        guard let current else { return lowest.y }

        // A choice is only worth keeping while a qualifying plane still
        // sits at that height. Without this a plane that was chosen and
        // then stopped qualifying -- it shrank, you walked away from it,
        // or the rules tightened under it -- is kept for ever, because
        // every other test below only ever replaces it with something
        // LOWER.
        guard let nearest = pool.min(by: {
            abs($0.y - current) < abs($1.y - current)
        }), abs(nearest.y - current) <= sameFloorBand else {
            return lowest.y
        }

        // The current plane is the candidate nearest the current height.
        let currentArea = nearest.area
        if lowest.y < current - replaceBelow { return lowest.y }
        let sameFloor = pool.filter { abs($0.y - current) <= sameFloorBand }
        if let larger = sameFloor.max(by: { $0.area < $1.area }), larger.area > currentArea {
            return larger.y
        }
        // The plane's LIVE height, not the height it had when it was
        // chosen. ARKit refines a plane's y by centimetres for as long as
        // the room is being scanned; returning `current` here tracked a
        // refinement downward (the rule above) but not one upward inside
        // the band, which made the floor a ratchet -- a running minimum of
        // every reading the plane ever gave, drifting low over a session
        // and popping back whenever it crossed the band edge.
        return nearest.y
    }

    /// The Quake z placed at the tracking origin so the hull bottom sits on
    /// the measured floor. Reconstructed from the eye, not read from the
    /// entity origin, because the engine eases vieworg up stairs while the
    /// origin snaps: eye minus viewheight is the origin, minus the hull
    /// bottom is the feet.
    static func anchorZ(vieworgZ: Float, viewheight: Float, floorYRoom: Float,
                        worldScale: Float, trimMetres: Float) -> Float {
        vieworgZ - viewheight - hullBottom - floorYRoom / worldScale + trimMetres / worldScale
    }

    /// Today's eye-locked mapping, for a session with no measured floor:
    /// the 0.40 m the old slider defaulted to is baked, and the trim rides
    /// on top so the knob means the same thing in both states.
    static let fallbackEyeHeight: Float = 0.4

    static func fallbackAnchorZ(vieworgZ: Float, worldScale: Float, trimMetres: Float) -> Float {
        vieworgZ + (fallbackEyeHeight + trimMetres) / worldScale
    }

    /// What QC_InputSetHeightTrim is fed: how far the rendered eye is above
    /// vieworg, in Quake units. Every engine-side reconstruction of the eye
    /// adds this to vieworg.
    static func effectiveTrim(anchorZ: Float, cameraYRoom: Float, vieworgZ: Float,
                              worldScale: Float) -> Float {
        anchorZ + cameraYRoom / worldScale - vieworgZ
    }

    /// The head is never this close above a floor it is standing on, nor
    /// this far above one. Not a selection rule -- the selector already
    /// has those -- but a sanity check on a height that is already in use,
    /// for the cases where the number stops meaning anything: a plane
    /// provider rebuilt with a new tracking origin leaves the last
    /// measurement readable in a frame it no longer belongs to, and the
    /// head comes from a SECOND session that can rebuild on its own
    /// schedule. Either way the two stop being comparable and nothing
    /// downstream can tell, because each number is individually fine.
    static let minimumStandingHeight: Float = 0.5
    static let maximumStandingHeight: Float = 2.4

    /// Whether a measured floor still puts the head at a height a person
    /// could be. False means fall back to the eye-locked mapping: a wrong
    /// floor is worse than no floor, because the player cannot tell it is
    /// wrong, only that the world sits oddly.
    static func believable(floorY: Float, headY: Float) -> Bool {
        let standing = headY - floorY
        return standing >= minimumStandingHeight && standing <= maximumStandingHeight
    }

    /// The measured floor in the corrected frame. A height-zeroing
    /// correction carries minus the recenter head height in its
    /// translation; a height-keeping one carries zero; either way adding
    /// it puts the raw height in the same frame the head offset is in.
    static func floorYRoom(raw: Float, correction: simd_float4x4) -> Float {
        raw + correction.columns.3.y
    }

    /// Distance from the head to the nearest point of a plane's extent,
    /// in the extent's own frame (x and z span it). The centre of a big
    /// room's floor is metres away while you stand on it.
    static func extentDistance(headInExtent: SIMD3<Float>, halfWidth: Float, halfHeight: Float) -> Float {
        let dx = max(0, abs(headInExtent.x) - halfWidth)
        let dz = max(0, abs(headInExtent.z) - halfHeight)
        return (dx * dx + dz * dz).squareRoot()
    }

    /// Smoothstep between two values; progress outside [0, 1] clamps.
    static func eased(from a: Float, to b: Float, progress: Float) -> Float {
        let t = max(0, min(1, progress))
        let s = t * t * (3 - 2 * t)
        return a + (b - a) * s
    }

    /// One detected vertical plane as the room-alignment publisher sees
    /// it: the plane's normal and its area, both in the RAW tracking
    /// frame the provider reports. Stored raw on purpose -- the recenter
    /// correction's rotation changes under the player's feet whenever
    /// they recentre, and a direction baked at detection time would go
    /// stale there with nothing to invalidate it.
    struct WallPlane {
        var normal: SIMD3<Float>
        var area: Float
    }

    /// A wall direction in the form the engine is told it: see
    /// QC_SetRoomWalls.
    struct WallDirection {
        var degrees: Float
        var weight: Float
    }

    /// Below this, in square metres, a detected plane is a door frame's
    /// edge or a picture, not a wall worth steering a room by.
    static let minimumWallArea: Float = 0.5

    /// How far a wall's normal may lean off horizontal before it is
    /// something else. A real wall's normal has essentially no vertical
    /// component; a ramp or a ceiling slope does, and left in they drag
    /// the mean somewhere no wall is.
    static let maximumWallTilt: Float = 0.3

    /// The wall directions to publish, newest correction applied.
    ///
    /// This function IS the frame contract. The engine adds body_yaw to
    /// what comes out of here and does nothing else, so the sign and
    /// origin of the angle are decided in this one place: atan2(-x, -z)
    /// over the corrected normal, which puts zero straight ahead (-Z) and
    /// increases to the left, the same sense as a Quake yaw. That matches
    /// how every other heading in this port is read off a transform.
    ///
    /// Heaviest first, because the engine's table is a fixed size and a
    /// cluttered room overflows it; the walls that survive the clamp
    /// should be the ones there is most of.
    static func wallDirections(_ walls: [WallPlane],
                               rotation: simd_float3x3,
                               limit: Int) -> [WallDirection] {
        var out: [WallDirection] = []
        out.reserveCapacity(min(walls.count, limit))
        for wall in walls {
            guard wall.area >= minimumWallArea else { continue }
            let n = rotation * wall.normal
            let horizontal = (n.x * n.x + n.z * n.z).squareRoot()
            guard horizontal > 1e-5,
                  abs(n.y) <= maximumWallTilt * horizontal else { continue }
            out.append(WallDirection(
                degrees: atan2(-n.x, -n.z) * 180 / .pi,
                weight: wall.area))
        }
        out.sort { $0.weight > $1.weight }
        if out.count > limit {
            out.removeSubrange(limit..<out.count)
        }
        return out
    }

    /// The correction that maps `pose`'s yaw and horizontal position to
    /// neutral. Pitch and roll are left alone, they are genuinely the
    /// head's. With `keepHeight` the vertical translation is left alone
    /// too, because a measured floor, not the head, defines vertical.
    static func correction(zeroing pose: simd_float4x4, keepHeight: Bool) -> simd_float4x4 {
        // Device forward is -Z; its XZ heading is the yaw to undo.
        let f = -pose.columns.2
        let yaw = atan2(-f.x, -f.z)
        let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        var neutral = rotation
        neutral.columns.3 = pose.columns.3
        if keepHeight { neutral.columns.3.y = 0 }
        return neutral.inverse
    }
}
