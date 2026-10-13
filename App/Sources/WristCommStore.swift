//
//  WristCommStore.swift
//
//  The wrist communicator's bindings store (plan Task 3): the main-actor
//  shell that reads the T1 `vr_wristcomm_*` cvars into a plain-value
//  snapshot the render thread can read lock-protected, and fires a cell's
//  bound console command. Mirrors `HudEditor.Session`'s exact shape
//  (nonisolated(unsafe) static snapshot behind an NSLock, a
//  publishRenderSnapshot() on every change, a nonisolated static reader) --
//  see that file's doc comment for why the split exists: the render thread
//  can never touch @MainActor storage, and the engine-thread cvar reads
//  that seed it can only ever happen from the main actor.
//

import Foundation
import Observation

/// The wrist communicator's live bindings, read from the `vr_wristcomm_*`
/// cvars T1 registered. `@MainActor` because every cvar read/write is
/// main-actor/engine-thread-only per the repo's thread rule -- this store is
/// exactly the sanctioned main-actor caller the render thread defers to
/// (via `requestRefresh()`/`snapshot()`) rather than touching `QC_Cvar*`
/// itself. `@Observable` so a settings surface, if one is ever added, can
/// mirror this without a hand-rolled publisher.
@MainActor
@Observable
final class WristCommStore {

    static let shared = WristCommStore()

    /// One side's (off-wrist or gun-wrist) six-cell binding state: whether
    /// that side's panel is enabled at all, and each cell's button label
    /// alongside the console command it fires -- index-aligned 0...5, same
    /// order as the `_cmdN`/`_labelN` cvar suffixes.
    struct SideState {
        var enabled: Bool
        var labels: [String]
        var commands: [String]
    }

    /// Plain-value mirror of both sides' bindings, read by the render
    /// thread (grid draw, Task 4/5) and by `fire(side:cell:)` for the
    /// cached command. `sides[0]` is the off wrist, `sides[1]` is the gun
    /// wrist -- the same index convention T1's cvar names spell out
    /// (`vr_wristcomm_off`/`_gun`).
    struct Snapshot {
        var sides: [SideState]
    }

    /// `vr_wristcomm_<side>` cvar name for each `sides` index, in index
    /// order -- the one place that mapping is spelled out, mirroring
    /// `HudEditor.Session.tileCvarNames`.
    private static let sideCvarNames = ["off", "gun"]

    /// Inert placeholder: both sides disabled, every label/command empty --
    /// what a `Snapshot` reads before the first `refresh()` has run.
    /// `nonisolated` so the `nonisolated(unsafe)` static snapshot below (and
    /// the `sides` default) can read it outside the main actor, mirroring
    /// `HudEditor.Session.defaultWorking`.
    nonisolated private static var inertSides: [SideState] {
        Array(repeating: SideState(enabled: false, labels: Array(repeating: "", count: 6),
                                   commands: Array(repeating: "", count: 6)), count: 2)
    }

    private init() {
        publishRenderSnapshot()
    }

    /// The working copy of both sides' bindings. Starts inert so a
    /// `snapshot()` read before any `refresh()` is still well-formed -- the
    /// same reasoning as `HudEditor.Session.defaultWorking`.
    private var sides: [SideState] = WristCommStore.inertSides { didSet { publishRenderSnapshot() } }

    /// Reads every `vr_wristcomm_*` cvar registered in T1 and republishes
    /// the render snapshot. THE sanctioned main-actor cvar read:
    /// `QC_CvarValue` and `QC_CvarString` are main-actor/engine-thread reads
    /// only, never the render thread -- this is the one place that boundary
    /// is crossed for the communicator's bindings.
    func refresh() {
        var next: [SideState] = []
        for side in Self.sideCvarNames {
            let enabled = QC_CvarValue("vr_wristcomm_\(side)") != 0
            var labels: [String] = []
            var commands: [String] = []
            for cell in 0..<6 {
                labels.append(String(cString: QC_CvarString("vr_wristcomm_\(side)_label\(cell)")))
                commands.append(String(cString: QC_CvarString("vr_wristcomm_\(side)_cmd\(cell)")))
            }
            next.append(SideState(enabled: enabled, labels: labels, commands: commands))
        }
        sides = next
    }

    /// Render-thread entry point: hop to the main actor and refresh. The
    /// render thread calls this on a reveal rising edge (Task 4) rather than
    /// refreshing every frame, since the cvars only change on a console
    /// edit/relaunch, not per frame.
    nonisolated static func requestRefresh() {
        Task { @MainActor in shared.refresh() }
    }

    /// Fires the cached command bound to `side`'s `cell`, or no-ops if the
    /// index is out of range or the command is empty (after trimming
    /// whitespace -- an unset binding reads as "", and a cvar edited to
    /// all-whitespace should behave the same way, not send a blank line to
    /// the engine).
    func fire(side: Int, cell: Int) {
        guard side >= 0, side < sides.count, cell >= 0, cell < sides[side].commands.count else { return }
        let cmd = sides[side].commands[cell].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        QuakeEngineViewModel.shared.send(cmd)
    }

    // MARK: - Render-thread snapshot

    nonisolated private static let renderLock = NSLock()
    nonisolated(unsafe) private static var _renderSnapshot = Snapshot(sides: WristCommStore.inertSides)

    /// Thread-safe from any thread, including the render thread -- the one
    /// sanctioned way to read this store's bindings outside the main actor.
    /// Never touches the `@MainActor` storage above.
    nonisolated static func snapshot() -> Snapshot {
        renderLock.lock(); defer { renderLock.unlock() }
        return _renderSnapshot
    }

    /// Republishes `snapshot()` after every bindings mutation (`sides`'
    /// `didSet`, and `init`) so the render thread never reads a stale
    /// generation.
    private func publishRenderSnapshot() {
        Self.renderLock.lock()
        Self._renderSnapshot = Snapshot(sides: sides)
        Self.renderLock.unlock()
    }
}
