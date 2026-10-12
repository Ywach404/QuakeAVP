//
//  HudEditor.swift
//
//  The HUD live editor's @Observable shell: the single source of truth for
//  an edit session, per the HUD Live Editor (Modular HUD Phase 2) design.
//  Owns which tiles are being arranged, the entry snapshot Cancel restores,
//  and the live grab state the input layer (HudEditorInput.swift, Task 5)
//  drives through the pure `updateGrab` state machine. The pure placement
//  math this shell is driven through -- `offsetInFrame`/`pointInTile`/
//  `resolveDrop`/`updateGrab`, plus the `Zone`/`TileEdit`/`GrabState` value
//  types -- lives in HudEditorMath.swift as the `HudEditor` enum this file
//  extends, kept free of Observation/ARKit/Metal so tools/check-swift-math.sh
//  and tools/check-swift-input.sh can compile and run it alone on the host.
//  This file is built only as part of the app (`make device`), never by
//  either harness.
//

import Foundation
import Observation
import simd

extension HudEditor {

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

        /// The `vr_hud` mode in effect before `enter()` forced mode 3, so
        /// `commit()`/`cancel()` can restore it. `nil` while inactive.
        private var priorHudMode: Int?

        private init() {
            publishRenderSnapshot()
        }

        /// `QC_HUD_TILE_*`-indexed, matching the shipped default layout A
        /// in r_null.c byte-for-byte (anchor, offset, scale) -- ammo on the
        /// gun, face/health+armor on the wrist, all shown, 1.6x scale. This
        /// is also what a `Session` reads before any `enter()`, and what
        /// `enter()` leaves offset/scale at on the very first call of a
        /// process's lifetime (see `enter()`'s doc comment on why offset/
        /// scale aren't re-seeded on every call the way anchor/show are).
        nonisolated private static var defaultWorking: [TileEdit] {
            var tiles = Array(
                repeating: TileEdit(anchor: Int(QC_HUD_ANCHOR_OFFWRIST), offset: .zero, scale: 1.6, show: true),
                count: Int(QC_HUD_TILE_COUNT)
            )
            tiles[Int(QC_HUD_TILE_AMMO)].anchor = Int(QC_HUD_ANCHOR_GUN)
            tiles[Int(QC_HUD_TILE_FACE)].offset = SIMD3(0, 0.035, 0)
            tiles[Int(QC_HUD_TILE_HEALTHARMOR)].offset = SIMD3(0, -0.035, 0)
            return tiles
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

        // MARK: - Enter / Done / Cancel (Task 6)

        /// Enters the workbench from the "Edit HUD Layout" button.
        ///
        /// Refreshes `working`'s anchor/show from the Phase 1 mirrors
        /// ContentView passes in -- those pickers/toggles are the only
        /// live source of "current" anchor/show ContentView has (there is
        /// no cvar read-back; see `hudTileControl`'s doc comment), so this
        /// keeps the workbench honest about anything the Phase 1 UI set
        /// since the last time the workbench ran. Offset/scale have no
        /// Phase 1 mirror at all -- nothing before this feature could set
        /// them -- so they are left exactly as `working` already holds
        /// them: the shipped engine defaults on the first `enter()` of a
        /// process's lifetime, or whatever the last `commit()`/`cancel()`
        /// in this process left behind otherwise. (A relaunch resets this
        /// `Session` to the shipped defaults even if the archived cvars
        /// hold a previously customized scale/offset -- the same read-back
        /// gap Phase 1 already accepts for anchor/show, just not yet hit
        /// in practice because Phase 1 never offered offset/scale controls.)
        ///
        /// Takes the Cancel snapshot, opens the workbench, and forces
        /// `vr_hud 3` so the workbench's frozen tile row has something to
        /// draw -- the row only renders while the engine is emitting
        /// modular tiles (Review Focus #4) -- recording `currentHudMode`
        /// so `commit()`/`cancel()` can restore it.
        func enter(ammoAnchor: Int, ammoShown: Bool,
                   faceAnchor: Int, faceShown: Bool,
                   healthArmorAnchor: Int, healthArmorShown: Bool,
                   currentHudMode: Int) {
            working[Int(QC_HUD_TILE_AMMO)].anchor = ammoAnchor
            working[Int(QC_HUD_TILE_AMMO)].show = ammoShown
            working[Int(QC_HUD_TILE_FACE)].anchor = faceAnchor
            working[Int(QC_HUD_TILE_FACE)].show = faceShown
            working[Int(QC_HUD_TILE_HEALTHARMOR)].anchor = healthArmorAnchor
            working[Int(QC_HUD_TILE_HEALTHARMOR)].show = healthArmorShown
            snapshot()
            priorHudMode = currentHudMode
            active = true
            QuakeEngineViewModel.shared.send("vr_hud 3")
        }

        /// `vr_hud_<tile>_*` cvar name for each `QC_HUD_TILE_*` index, in
        /// index order -- the one place that mapping is spelled out.
        private static let tileCvarNames = ["ammo", "face", "healtharmor"]

        /// Writes one `TileEdit` out to its tile's six `vr_hud_<tile>_*`
        /// cvars (all `CVAR_ARCHIVE` -- this is what persists the layout
        /// across a relaunch; there is no separate profile store for it).
        private func sendTileCvars(_ edit: TileEdit, cvar: String) {
            let engine = QuakeEngineViewModel.shared
            engine.send("vr_hud_\(cvar)_anchor \(edit.anchor)")
            engine.send("vr_hud_\(cvar)_off_x \(edit.offset.x)")
            engine.send("vr_hud_\(cvar)_off_y \(edit.offset.y)")
            engine.send("vr_hud_\(cvar)_off_z \(edit.offset.z)")
            engine.send("vr_hud_\(cvar)_scale \(edit.scale)")
            engine.send("vr_hud_\(cvar)_show \(edit.show ? 1 : 0)")
        }

        /// Done: commits every tile's working edit to the engine, restores
        /// whatever `vr_hud` mode was active before `enter()`, and closes
        /// the workbench. Returns the committed anchor/show per tile so
        /// ContentView can keep its Phase 1 mirrors in sync.
        @discardableResult
        func commit() -> [TileEdit] {
            for (index, cvar) in Session.tileCvarNames.enumerated() {
                sendTileCvars(working[index], cvar: cvar)
            }
            let committed = working
            exit()
            return committed
        }

        /// Cancel: discards every edit made since `enter()`, re-sends the
        /// entry snapshot's cvars so the engine matches exactly what the
        /// (now-reverted) `working` shows -- nothing touches the live
        /// cvars while the workbench is open, so this is normally a no-op,
        /// but it is cheap and keeps the engine from ever disagreeing with
        /// `working` by construction rather than by assumption -- restores
        /// the prior `vr_hud` mode, and closes the workbench.
        func cancel() {
            restore()
            for (index, cvar) in Session.tileCvarNames.enumerated() {
                sendTileCvars(working[index], cvar: cvar)
            }
            exit()
        }

        /// Shared tail of `commit()`/`cancel()`: restore the mode `enter()`
        /// recorded and close the workbench.
        private func exit() {
            if let priorHudMode {
                QuakeEngineViewModel.shared.send("vr_hud \(priorHudMode)")
            }
            priorHudMode = nil
            active = false
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
