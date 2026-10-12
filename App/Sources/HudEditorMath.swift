//
//  HudEditorMath.swift
//
//  The HUD live editor's pure placement math: projecting a world point onto
//  a frame's own axes, testing whether a hit lands inside a tile's bbox, and
//  resolving a drop against the four zone proxies (wrist/gun/float/hidden
//  tray). Everything here is a static value function over SIMD3<Float> --
//  no app types, no @MainActor, no Observation -- so tools/check-swift-math.sh
//  can compile and run it alone, against tools/swifttest/hud_editor_math_test.swift,
//  on the host with no simulator. The @MainActor @Observable editor shell
//  that owns the live instance state lives in HudEditor.swift, as an
//  extension of this same `HudEditor` namespace.
//

import simd

/// Namespace for the editor's pure math (and the plain value types it
/// takes/returns), kept separate from the `@Observable` shell so the host
/// harness can compile this file alone.
enum HudEditor {

    /// One per-tile edit the working copy tracks: `anchor` is a
    /// `QC_HUD_ANCHOR_*` value, `offset` is in the anchor frame's own
    /// right/up/forward axes (metres), matching `qc_hud_tile_t`.
    struct TileEdit {
        var anchor: Int
        var offset: SIMD3<Float>
        var scale: Float
        var show: Bool
    }

    /// A drop-zone proxy in the workbench scene: wrist, gun, float, or the
    /// hidden tray. `origin`/`right`/`up`/`forward` must be unit and
    /// mutually orthogonal, same contract as `RendererCore.HudAnchorFrame`
    /// -- this type is deliberately its own plain struct (not that one) so
    /// this file stays free of the Metal-importing renderer module.
    ///
    /// `anchor` is the `QC_HUD_ANCHOR_*` value a drop here assigns -- except
    /// for the hidden tray, where it is ignored: the tray hides a tile
    /// (`show = false`) without touching its anchor, per the design (the
    /// tray parks a tile, it does not un-anchor it).
    struct Zone {
        var anchor: Int
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
        var radius: Float
        var isHiddenTray: Bool
    }

    /// Projects `point - origin` onto the frame's own axes, i.e. the inverse
    /// of `origin + right*offset.x + up*offset.y + forward*offset.z` -- the
    /// same construction `RendererCore.hudTileModel` uses to place a tile
    /// from its stored offset, run backwards to recover that offset from a
    /// world point (a grab/drop hit).
    static func offsetInFrame(point: SIMD3<Float>, origin: SIMD3<Float>,
                               right: SIMD3<Float>, up: SIMD3<Float>,
                               forward: SIMD3<Float>) -> SIMD3<Float> {
        let d = point - origin
        return SIMD3<Float>(simd_dot(d, right), simd_dot(d, up), simd_dot(d, forward))
    }

    /// Whether `hit` lands inside a tile's bbox, in the tile's own frame.
    /// `right`/`up` must be unit; `halfW`/`halfH` are half-extents (metres)
    /// along those axes, so the tile's depth along `forward` is ignored --
    /// a hit test against the tile's face, not a 3D box.
    static func pointInTile(hit: SIMD3<Float>, tileOrigin: SIMD3<Float>,
                             right: SIMD3<Float>, up: SIMD3<Float>,
                             halfW: Float, halfH: Float) -> Bool {
        let d = hit - tileOrigin
        let x = simd_dot(d, right)
        let y = simd_dot(d, up)
        return abs(x) <= halfW && abs(y) <= halfH
    }

    /// Resolves a drop at `point` against the workbench's zone proxies.
    ///
    /// The nearest zone whose `origin` is within its own `radius` wins:
    /// - A normal zone sets `anchor` to the zone's `anchor` and shows the
    ///   tile, with `offset` recomputed against that zone's own frame.
    /// - The hidden tray keeps `previousAnchor` but sets `show: false` --
    ///   parking the tile without un-anchoring it.
    /// - No zone in range (Review Focus #2: a drop between zones, over
    ///   nothing) keeps `previousAnchor` and `show: true` -- never silently
    ///   un-anchors the tile. The offset is recomputed against whichever
    ///   zone in `zones` already carries `previousAnchor` (so the tile's
    ///   stored offset still means something next frame); with no such zone
    ///   to recompute against (e.g. no zones at all), the offset falls back
    ///   to zero rather than fabricating one.
    static func resolveDrop(point: SIMD3<Float>, zones: [Zone],
                             previousAnchor: Int) -> (anchor: Int, show: Bool, offset: SIMD3<Float>) {
        var best: Zone?
        var bestDistance = Float.greatestFiniteMagnitude
        for zone in zones {
            let distance = simd_length(point - zone.origin)
            if distance <= zone.radius && distance < bestDistance {
                bestDistance = distance
                best = zone
            }
        }

        if let zone = best {
            let offset = offsetInFrame(point: point, origin: zone.origin, right: zone.right,
                                        up: zone.up, forward: zone.forward)
            if zone.isHiddenTray {
                return (previousAnchor, false, offset)
            }
            return (zone.anchor, true, offset)
        }

        if let previousZone = zones.first(where: { $0.anchor == previousAnchor && !$0.isHiddenTray }) {
            let offset = offsetInFrame(point: point, origin: previousZone.origin, right: previousZone.right,
                                        up: previousZone.up, forward: previousZone.forward)
            return (previousAnchor, true, offset)
        }

        return (previousAnchor, true, .zero)
    }
}
