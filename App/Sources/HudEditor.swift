// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
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

        /// `r_drawviewmodel` before `enter()` hid the view weapon (set 0),
        /// restored on exit. The gun is hidden while editing so it doesn't
        /// block the wrist tiles; both hand models are forced on in HandInput
        /// for the same reason (see its VirtualHand publish).
        private var priorDrawViewModel: Float?

        private init() {
            publishRenderSnapshot()
        }

        /// `QC_HUD_TILE_*`-indexed, matching the shipped default layout A
        /// in r_null.c byte-for-byte (anchor, offset, scale) -- ammo on the
        /// gun, face/health+armor on the wrist, all shown, 1.6x scale. Only
        /// a placeholder now: `enter()` always re-seeds every field from the
        /// live `vr_hud_<tile>_*` cvars via `QC_CvarValue`, so this is just
        /// what a `Session` reads before any `enter()` has run at all (e.g.
        /// the render thread's very first `renderSnapshot()`), kept in sync
        /// with r_null.c's registered defaults rather than read from them.
        nonisolated private static var defaultWorking: [TileEdit] {
            var tiles = Array(
                repeating: TileEdit(anchor: Int(QC_HUD_ANCHOR_WRIST_OFF), offset: .zero,
                                    scale: 1.6, show: true, slot: 0, spanW: 1, spanH: 1),
                count: Int(QC_HUD_TILE_COUNT)
            )
            tiles[Int(QC_HUD_TILE_AMMO)].anchor = Int(QC_HUD_ANCHOR_GUN)       // free, by the gun, 1.6x
            tiles[Int(QC_HUD_TILE_FACE)].slot = 0                             // off wrist, top-left
            tiles[Int(QC_HUD_TILE_FACE)].scale = 1.0                          // fit the cell (not 1.6x)
            tiles[Int(QC_HUD_TILE_HEALTHARMOR)].slot = 3                      // off wrist, bottom-left
            tiles[Int(QC_HUD_TILE_HEALTHARMOR)].scale = 1.0                   // fit the cell (not 1.6x)
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
        /// Seeds every tile's `working` edit straight from the live
        /// `vr_hud_<tile>_*` cvars via `QC_CvarValue`, closing the
        /// relaunch read-back gap: previously `working` started from
        /// `defaultWorking` (a hardcoded mirror of r_null.c's shipped
        /// defaults) and `commit()` wrote all six cvars per tile
        /// unconditionally, so re-opening the editor after a relaunch --
        /// where the archived `CVAR_ARCHIVE` cvars hold a customized
        /// layout but this in-process `Session` starts at the hardcoded
        /// defaults -- and hitting Done silently clobbered the saved
        /// layout with those stale defaults. Reading back here instead
        /// means the workbench always starts from whatever is actually
        /// live, on the very first `enter()` of a process's lifetime
        /// (freshly registered cvars) exactly as much as any later one.
        ///
        /// Also clears a leftover `grab` from an aborted prior session
        /// before anything else can touch `working`, defensively -- there
        /// should be no live grab across an `enter()`, but a stale one
        /// carrying over would otherwise still answer `updateGrab` calls
        /// against a tile index from the previous session.
        ///
        /// Takes the Cancel snapshot, opens the workbench, and forces
        /// `vr_hud 3` so the workbench's frozen tile row has something to
        /// draw -- the row only renders while the engine is emitting
        /// modular tiles (Review Focus #4) -- reading the LIVE `vr_hud`
        /// cvar itself (not a passed-in value) so `commit()`/`cancel()`
        /// restore whatever mode the player actually had archived. A
        /// caller-supplied mode would be a SwiftUI mirror with no cvar
        /// read-back of its own (see `ContentView.hudPanelMode`), so on an
        /// install whose archived `vr_hud` differs from that mirror's
        /// hardcoded default, Done/Cancel would silently overwrite the
        /// player's choice -- reading it here instead means this can never
        /// diverge from what is actually live, exactly as the tile seeding
        /// above does.
        func enter() {
            grab = nil
            for (index, cvar) in Session.tileCvarNames.enumerated() {
                working[index] = TileEdit(
                    anchor: Int(QC_CvarValue("vr_hud_\(cvar)_anchor")),
                    offset: SIMD3(
                        QC_CvarValue("vr_hud_\(cvar)_off_x"),
                        QC_CvarValue("vr_hud_\(cvar)_off_y"),
                        QC_CvarValue("vr_hud_\(cvar)_off_z")),
                    scale: QC_CvarValue("vr_hud_\(cvar)_scale"),
                    show: QC_CvarValue("vr_hud_\(cvar)_show") != 0)
                working[index].slot  = Int(QC_CvarValue("vr_hud_\(cvar)_slot"))
                working[index].spanW = Int(QC_CvarValue("vr_hud_\(cvar)_span_w"))
                working[index].spanH = Int(QC_CvarValue("vr_hud_\(cvar)_span_h"))
            }
            snapshot()
            priorHudMode = Int(QC_CvarValue("vr_hud"))
            priorDrawViewModel = QC_CvarValue("r_drawviewmodel")
            active = true
            QuakeEngineViewModel.shared.send("vr_hud 3")
            // Hide the view weapon while arranging so it doesn't obscure the
            // wrist tiles (both hand models come on in HandInput).
            QuakeEngineViewModel.shared.send("r_drawviewmodel 0")
        }

        /// `vr_hud_<tile>_*` cvar name for each `QC_HUD_TILE_*` index, in
        /// index order -- the one place that mapping is spelled out.
        private static let tileCvarNames = ["ammo", "face", "healtharmor"]

        /// Writes one `TileEdit` out to its tile's nine `vr_hud_<tile>_*`
        /// cvars -- anchor, the three offset components, scale, show, and the
        /// wrist-grid slot/span_w/span_h (all `CVAR_ARCHIVE`, so this is what
        /// persists the layout across a relaunch; there is no separate
        /// profile store for it).
        private func sendTileCvars(_ edit: TileEdit, cvar: String) {
            let engine = QuakeEngineViewModel.shared
            engine.send("vr_hud_\(cvar)_anchor \(edit.anchor)")
            engine.send("vr_hud_\(cvar)_off_x \(edit.offset.x)")
            engine.send("vr_hud_\(cvar)_off_y \(edit.offset.y)")
            engine.send("vr_hud_\(cvar)_off_z \(edit.offset.z)")
            engine.send("vr_hud_\(cvar)_scale \(edit.scale)")
            engine.send("vr_hud_\(cvar)_show \(edit.show ? 1 : 0)")
            engine.send("vr_hud_\(cvar)_slot \(edit.slot)")
            engine.send("vr_hud_\(cvar)_span_w \(edit.spanW)")
            engine.send("vr_hud_\(cvar)_span_h \(edit.spanH)")
        }

        /// Reset ONE tile's SIZE -- its uniform scale back to the tile's default
        /// (ammo 1.6x on the gun, the wrist tiles 1.0 to fit their cell) and its
        /// wrist footprint back to a single cell -- while leaving its position
        /// (anchor/slot/offset/show) untouched. Per-tile so the off-wrist
        /// health/face can be restored without disturbing a tuned ammo tile.
        /// Writes the three size cvars live so it works whether or not the
        /// editor is open, and mirrors them into `working` so an open edit shows
        /// it at once (and Cancel still reverts it with the session's edits).
        func resetSize(tileIndex: Int) {
            guard tileIndex >= 0, tileIndex < working.count else { return }
            let cvar = Session.tileCvarNames[tileIndex]
            // Ammo rides the gun at 1.6x (pixel-scaled); the wrist tiles fit
            // their cell at 1.0 (contain-fit). Matches r_null.c's defaults.
            let sc: Float = tileIndex == Int(QC_HUD_TILE_AMMO) ? 1.6 : 1.0
            working[tileIndex].scale = sc
            working[tileIndex].spanW = 1
            working[tileIndex].spanH = 1
            let engine = QuakeEngineViewModel.shared
            engine.send("vr_hud_\(cvar)_scale \(sc)")
            engine.send("vr_hud_\(cvar)_span_w 1")
            engine.send("vr_hud_\(cvar)_span_h 1")
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
            if let priorDrawViewModel {
                QuakeEngineViewModel.shared.send("r_drawviewmodel \(priorDrawViewModel)")
            }
            priorHudMode = nil
            priorDrawViewModel = nil
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
