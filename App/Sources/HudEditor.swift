//
//  HudEditor.swift
//
//  The HUD live editor's @Observable shell: the single source of truth for
//  an edit session, per the HUD Live Editor (Modular HUD Phase 2) design.
//  Owns which tiles are being arranged, the entry snapshot Cancel restores,
//  and the live grab state a later task's input code drives. The pure
//  placement math this shell will be driven through -- `offsetInFrame`/
//  `pointInTile`/`resolveDrop`, plus the `Zone`/`TileEdit` value types --
//  lives in HudEditorMath.swift as the `HudEditor` enum this file extends,
//  kept free of Observation/ARKit/Metal so tools/check-swift-math.sh can
//  compile and run it alone on the host. This file is built only as part of
//  the app (`make device`), never by that harness.
//

import Foundation
import Observation
import simd

extension HudEditor {

    /// Which tile is currently grabbed, and where it last was. The grab
    /// input task owns updating this every frame; this file owns only the
    /// storage slot and the "no stale grab" contract a lost hand/controller
    /// must honour -- release at `lastPoint`, never jump to the origin
    /// (plan Review Focus #1).
    struct GrabState {
        var tileID: Int
        var lastPoint: SIMD3<Float>
        /// The other hand's pinch point, when a two-hand scale is live.
        /// `nil` whenever only one hand/controller is tracked -- a missing
        /// second pinch must leave scale untouched rather than apply a
        /// garbage value (plan Review Focus #5).
        var secondPinch: SIMD3<Float>?
    }

    /// The editor's live state while the workbench is open. `@MainActor`
    /// because everything here is UI-touching state, hit-tested from the
    /// render loop and committed through the engine's `send` route on the
    /// main actor; `@Observable` so the workbench view and the settings
    /// mirrors invalidate on a tile edit without a hand-rolled publisher.
    @MainActor
    @Observable
    final class Session {

        static let shared = Session()

        /// Whether the workbench is open. While `true`, the renderer swaps
        /// the live tile-placement path for the workbench one; while
        /// `false`, this type is otherwise inert.
        var active = false { didSet { publishRenderSnapshot() } }

        /// The working copy of all `QC_HUD_TILE_COUNT` tiles' `{anchor,
        /// offset, scale, show}`, indexed by `QC_HUD_TILE_*`. Edited live by
        /// grabs/drops; written out to the `vr_hud_<tile>_*` cvars only on
        /// Done. Starts at the engine's own defaults so a `Session` read
        /// before any `enter()`/`snapshot()` is still well-formed.
        var working: [TileEdit] = Session.defaultWorking { didSet { publishRenderSnapshot() } }

        /// The tile currently being grabbed, or `nil` between grabs.
        var grab: GrabState? { didSet { publishRenderSnapshot() } }

        private var entrySnapshot: [TileEdit]?

        private init() {
            publishRenderSnapshot()
        }

        nonisolated private static var defaultWorking: [TileEdit] {
            Array(
                repeating: TileEdit(anchor: Int(QC_HUD_ANCHOR_OFFWRIST), offset: .zero, scale: 1, show: true),
                count: Int(QC_HUD_TILE_COUNT)
            )
        }

        /// Captures `working` so `restore()` can undo everything a session
        /// does. Call on entering the workbench, before any grab mutates it.
        func snapshot() {
            entrySnapshot = working
        }

        /// Reverts `working` to the last `snapshot()` -- Cancel's contract.
        /// A `restore()` with no prior `snapshot()` is a no-op: there is
        /// nothing to revert to, so it leaves `working` exactly as it is
        /// rather than discarding live edits against a snapshot that was
        /// never taken.
        func restore() {
            guard let entrySnapshot else { return }
            working = entrySnapshot
        }

        // MARK: - Render-thread snapshot

        /// Plain-value mirror of this session's placement state, read by
        /// `ImmersiveRenderer`'s workbench draw path (Task 4). That path
        /// runs on a dedicated render thread, never the main actor, so it
        /// cannot touch `active`/`working`/`grab` above directly -- the
        /// same constraint `GunHand`/`OffHandWrist` solve in HandInput.swift
        /// for the hand poses, mirrored here for the editor's placement
        /// state instead of re-deriving it with a per-frame actor hop.
        struct RenderSnapshot {
            var active: Bool
            var working: [TileEdit]
            var grab: GrabState?
        }

        nonisolated(unsafe) private static let renderLock = NSLock()
        nonisolated(unsafe) private static var _renderSnapshot =
            RenderSnapshot(active: false, working: Session.defaultWorking, grab: nil)

        /// Thread-safe from any thread, including the render thread -- the
        /// one sanctioned way for `ImmersiveRenderer` to read this session.
        /// Never touches the `@MainActor` storage above.
        nonisolated static func renderSnapshot() -> RenderSnapshot {
            renderLock.lock(); defer { renderLock.unlock() }
            return _renderSnapshot
        }

        /// Republishes `renderSnapshot()` after every placement mutation
        /// (`active`/`working`/`grab`'s `didSet`s, and `init`) so the render
        /// thread never reads a stale generation.
        private func publishRenderSnapshot() {
            Session.renderLock.lock()
            Session._renderSnapshot = RenderSnapshot(active: active, working: working, grab: grab)
            Session.renderLock.unlock()
        }
    }

    /// The live editor instance. Spelled `HudEditor.shared` throughout the
    /// rest of the feature (render, input, UI) even though the actual
    /// `@Observable` object is the nested `Session` type below -- the math
    /// namespace and the stateful shell deliberately share the one name,
    /// which is why the shell lives in its own file instead of widening
    /// this `enum` directly (an `enum` can't hold mutable instance state).
    @MainActor
    static var shared: Session { Session.shared }
}
