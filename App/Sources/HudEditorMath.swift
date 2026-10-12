//
//  HudEditorMath.swift
//
//  The HUD live editor's pure placement math: projecting a world point onto
//  a frame's own axes, testing whether a hit lands inside a tile's bbox,
//  resolving a drop against the four zone proxies (wrist/gun/float/hidden
//  tray), and (Task 5) the grab/move/scale state machine itself,
//  `updateGrab`. Everything here is a static value function over
//  SIMD3<Float> -- no app types, no ARKit, no @MainActor, no Observation --
//  so tools/check-swift-math.sh and tools/check-swift-input.sh can compile
//  and run it alone, against tools/swifttest/hud_editor_math_test.swift and
//  hud_editor_input_test.swift respectively, on the host with no simulator.
//  The @MainActor @Observable editor shell that owns the live instance state
//  lives in HudEditor.swift, as an extension of this same `HudEditor`
//  namespace; the ARKit/GameController plumbing that calls `updateGrab` with
//  real poses and applies its result to that shell lives in
//  HudEditorInput.swift.
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

    // MARK: - Grab / move / scale (Task 5)

    /// Which tile is currently grabbed, and where it last was. Storage slot
    /// lives on `HudEditor.Session.grab` (HudEditor.swift); the shape is
    /// pure so `updateGrab` below -- and the host test -- can construct and
    /// inspect it without the @Observable shell.
    struct GrabState {
        var tileID: Int
        var lastPoint: SIMD3<Float>
        /// The other hand's pinch point, when a two-hand scale is live.
        /// `nil` whenever only one hand/controller is tracked -- a missing
        /// second pinch must leave scale untouched rather than apply a
        /// garbage value (plan Review Focus #5).
        var secondPinch: SIMD3<Float>?
    }

    /// A tile's current hit-test frame, for grab-start only: `pointInTile`
    /// against `origin`/`right`/`up`/`halfW`/`halfH` (the tile's face, same
    /// contract as `pointInTile` itself). Wherever the tile is actually
    /// drawn right now -- its home slot, or a hidden-tray parking spot --
    /// the plumbing layer (HudEditorInput.swift) is the one that knows that
    /// and builds this frame from it; `updateGrab` only hit-tests against
    /// whatever frames it's given.
    struct TileFrame {
        var tileID: Int
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var halfW: Float
        var halfH: Float
    }

    /// One frame's injected grab/scale signal, built by the plumbing layer
    /// from real hand pinches or controller triggers/poses/thumbsticks.
    /// `primaryPoint`/`secondaryPoint` are `nil` exactly when that source is
    /// untracked (a lost hand, a disconnected controller) -- `updateGrab`
    /// never treats a `nil` point as "at the origin"; it is the one signal
    /// that ends a grab (Review Focus #1) or holds scale still (Review
    /// Focus #5).
    struct GrabInput {
        /// Pinch (hands) or trigger (controllers) on the hand/controller
        /// that is, or would become, the grab.
        var primaryActive: Bool
        var primaryPoint: SIMD3<Float>?
        /// The OTHER hand's pinch, for two-hand scale. Controllers don't use
        /// this -- they scale from `stickScaleAxis` below instead.
        var secondaryActive: Bool
        var secondaryPoint: SIMD3<Float>?
        /// Controller-only direct scale rate (thumbstick Y, already
        /// deadzoned by the plumbing layer), applied independently of the
        /// two-point mechanism above. `nil` for hands, or when the stick is
        /// at rest.
        var stickScaleAxis: Float?

        init(primaryActive: Bool, primaryPoint: SIMD3<Float>?,
             secondaryActive: Bool = false, secondaryPoint: SIMD3<Float>? = nil,
             stickScaleAxis: Float? = nil) {
            self.primaryActive = primaryActive
            self.primaryPoint = primaryPoint
            self.secondaryActive = secondaryActive
            self.secondaryPoint = secondaryPoint
            self.stickScaleAxis = stickScaleAxis
        }
    }

    /// Tile scale is clamped to this range -- `RendererCore.hudPanelModel`'s
    /// own `tile.scale > 0 ? tile.scale : 1` guard only protects against
    /// zero/negative; these are the editor's own sane working bounds so a
    /// runaway pinch or stick hold can't blow a tile up to something
    /// illegible or down to invisible.
    static let scaleMin: Float = 0.25
    static let scaleMax: Float = 4.0
    /// Scale change per second of a full-deflection thumbstick hold.
    static let stickScaleRate: Float = 0.8

    /// The grab/move/scale state machine. Pure: every real-world input
    /// (hand pinch points, controller poses/triggers/thumbstick) is injected
    /// through `input`; nothing here reads ARKit, GameController, or
    /// `HudEditor.shared` -- that hop is HudEditorInput.swift's job, which
    /// calls this once a frame and applies the result to the `@MainActor`
    /// session.
    ///
    /// State machine:
    /// - **no grab + a primary hit inside a tile's frame** -> starts a grab
    ///   at that tile, pinned to the hit point. No `working` mutation yet --
    ///   grabbing doesn't move anything until the NEXT frame's point differs.
    /// - **no grab + no hit, or no primary** -> stays idle.
    /// - **grabbed + primary lost (`!primaryActive` or `primaryPoint == nil`,
    ///   covering both a deliberate release and a lost hand/disconnected
    ///   controller alike)** -> releases AT `lastPoint`, the last point this
    ///   same function was actually given -- never the input's (possibly
    ///   absent) point, never the origin (Review Focus #1) -- by running it
    ///   through `resolveDrop` exactly as every other release does (the tray-
    ///   recall confirmation below). The render path (Task 4) draws a held
    ///   tile at `grab.lastPoint` directly, which is why move needs no
    ///   `working` mutation of its own -- only `resolveDrop` at release
    ///   touches `offset`.
    /// - **grabbed + primary tracked** -> `lastPoint` advances to the new
    ///   point (the tile keeps following); scale updates from whichever
    ///   source is live this frame:
    ///   - two points (hands): the RATIO of this frame's primary/secondary
    ///     distance to last frame's (`grab.secondPinch` was tracked last
    ///     frame too) multiplies the scale. The first frame a second pinch
    ///     appears only records a baseline -- there is no "last frame's
    ///     distance" yet, so no scale change fires off a single sample.
    ///     Any frame the second point is missing or inactive -- including
    ///     exactly ONE hand tracked -- drops the baseline (`secondPinch`
    ///     goes back to `nil`) and leaves scale untouched: never a garbage
    ///     scale from a missing second pinch (Review Focus #5), and the
    ///     primary move above still applies, so the tile keeps moving.
    ///   - a stick axis (controllers): scale changes by `axis * stickScaleRate
    ///     * dt` directly, independent of the two-point mechanism (which
    ///     controllers never populate).
    static func updateGrab(grab: GrabState?, input: GrabInput, working: [TileEdit],
                           tiles: [TileFrame], zones: [Zone], dt: Float) -> (grab: GrabState?, working: [TileEdit]) {
        var working = working

        guard let current = grab else {
            guard input.primaryActive, let point = input.primaryPoint else { return (nil, working) }
            guard let hit = tiles.first(where: {
                pointInTile(hit: point, tileOrigin: $0.origin, right: $0.right, up: $0.up,
                            halfW: $0.halfW, halfH: $0.halfH)
            }) else { return (nil, working) }
            return (GrabState(tileID: hit.tileID, lastPoint: point, secondPinch: nil), working)
        }

        guard input.primaryActive, let point = input.primaryPoint else {
            // Lost tracking or a deliberate release -- either way, resolve
            // the drop at the LAST point we actually held, through the same
            // resolveDrop every release goes through (so a recall out of
            // the hidden tray always gets a fresh anchor+offset, never a
            // leftover tray offset -- the tray-recall confirmation).
            if current.tileID >= 0, current.tileID < working.count {
                let result = resolveDrop(point: current.lastPoint, zones: zones,
                                          previousAnchor: working[current.tileID].anchor)
                working[current.tileID].anchor = result.anchor
                working[current.tileID].show = result.show
                working[current.tileID].offset = result.offset
            }
            return (nil, working)
        }

        let tileID = current.tileID
        var newSecondPinch: SIMD3<Float>?
        if input.secondaryActive, let secondPoint = input.secondaryPoint {
            if let lastSecond = current.secondPinch {
                let before = simd_distance(current.lastPoint, lastSecond)
                let after = simd_distance(point, secondPoint)
                if before > 1e-4, tileID >= 0, tileID < working.count {
                    let ratio = after / before
                    working[tileID].scale = min(scaleMax, max(scaleMin, working[tileID].scale * ratio))
                }
            }
            newSecondPinch = secondPoint
        }

        if let axis = input.stickScaleAxis, abs(axis) > 0.0001, tileID >= 0, tileID < working.count {
            working[tileID].scale = min(scaleMax, max(scaleMin, working[tileID].scale + axis * stickScaleRate * dt))
        }

        return (GrabState(tileID: tileID, lastPoint: point, secondPinch: newSecondPinch), working)
    }
}
