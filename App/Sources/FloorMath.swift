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
    /// A plane has to be this much lower to replace the current one; the
    /// same floor re-reported a few millimetres off is not a new floor.
    static let replaceBelow: Float = 0.02

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
        }
        guard let lowest = qualifying.min(by: { $0.y < $1.y }) else { return nil }
        guard let current else { return lowest.y }

        // The current plane is the candidate nearest the current height.
        let currentArea = qualifying.min(by: { abs($0.y - current) < abs($1.y - current) })?.area ?? 0
        if lowest.y < current - replaceBelow { return lowest.y }
        if let larger = qualifying.max(by: { $0.area < $1.area }), larger.area > currentArea {
            return larger.y
        }
        return current
    }

    /// The Quake z placed at the tracking origin so the hull bottom sits on
    /// the measured floor. The eye, not the entity origin, because the
    /// engine eases vieworg up stairs while the origin snaps.
    static func anchorZ(vieworgZ: Float, viewheight: Float, floorYRoom: Float,
                        worldScale: Float, trimMetres: Float) -> Float {
        vieworgZ - viewheight - floorYRoom / worldScale + trimMetres / worldScale
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

    /// Smoothstep between two values; progress outside [0, 1] clamps.
    static func eased(from a: Float, to b: Float, progress: Float) -> Float {
        let t = max(0, min(1, progress))
        let s = t * t * (3 - 2 * t)
        return a + (b - a) * s
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
