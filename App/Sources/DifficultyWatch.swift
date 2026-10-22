// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  DifficultyWatch.swift
//
//  Noticing when something ENGINE-SIDE changed the difficulty, and deciding
//  whether that counts as the player choosing it.
//
//  The window is not the only way in. The difficulty doors on `start` are
//  QuakeC `trigger_setskill`, which reaches PF_cvar_set (engine/pr_cmds.c:962)
//  and writes the same `skill` cvar the console and the window write -- so
//  walking a door really does set the flag, and the stored value has to follow
//  or the window would start lying about what you are playing.
//
//  But Host_Loadgame_f writes that cvar too (engine/host_cmd.c:1245-1246), from
//  whatever the save file says. So "adopt any engine-side change" would mean
//  loading an Easy save silently rewrites a persisted Nightmare, and the
//  "set Hard, relaunch, still Hard" criterion would pass or fail depending on
//  whether a save happened to be loaded in between. A load is not the player
//  expressing a preference; it is resuming a game that already had one. A hub
//  door IS. So loads are masked and doors are adopted.
//
//  KNOWN GAP: a `load` typed straight into the console is not seen by
//  markLoad(), so that one case is adopted as if it were a preference. Masking
//  it properly needs a signal from inside the engine's load path, which is not
//  worth a vendored hunk for a case that leaves the player's difficulty equal
//  to the save they deliberately loaded.
//
//  No engine import: the decision is pure and the cvar read is injected, so
//  tools/check-swift-session.sh compiles this file alone against its test.
//

import Foundation

/// The decision, alone and total.
enum DifficultyWatch {

    /// What to do about a difference between the engine and the stored choice.
    enum Action: Equatable {
        /// The player changed it engine-side (a hub door, a console `skill`).
        /// Take it as their new preference.
        case adopt(Int)
        /// A LOAD changed it. Put the engine back to what the player chose.
        case restore(Int)
    }

    /// Masking a load stops it rewriting the preference. It does NOT put the
    /// engine back, and that was the missing half: `Host_Loadgame_f` sets the
    /// skill cvar from the file, so after loading an old save the engine held
    /// that save's skill while the preference held the player's. Every level
    /// started afterwards spawned at the engine's value -- found on device as
    /// a cvar reading 3 and the next save recording 0.
    ///
    /// Restoring does not disturb the loaded game: `current_skill` was already
    /// sampled when that level spawned, so the cvar only decides the NEXT one.
    ///
    /// A fresh change always wins over a restore. Otherwise walking a hub door
    /// to a difficulty that differs from the stored one would be undone a
    /// second later by the very mechanism meant to respect it.
    static func decide(engineSkill: Int, stored: Int, lastSeen: Int,
                       loadInFlight: Bool) -> Action? {
        guard (0...3).contains(engineSkill), (0...3).contains(stored) else { return nil }
        guard !loadInFlight else { return nil }
        if engineSkill != lastSeen { return .adopt(engineSkill) }
        if engineSkill != stored { return .restore(stored) }
        return nil
    }

}

/// The live half: polls the engine's `skill` and stores what `sample` accepts.
///
/// A poll rather than a notification because there is nothing engine-side to
/// notify us: `trigger_setskill` is QuakeC writing a cvar, and no hook fires.
/// One read a second is far cheaper than it sounds -- `QC_CvarValue` is a
/// name lookup over a static list -- and difficulty changes at human speed.
@MainActor
final class DifficultyWatcher {

    /// How long after a load to keep ignoring the cvar. Host_Loadgame_f writes
    /// `skill` partway through loading, so the mask has to outlast the load
    /// itself rather than being cleared when the command is issued.
    private static let loadMask: Duration = .seconds(2)

    private let readEngineSkill: () -> Int
    private let readStored: () -> Int
    private let writeStored: (Int) -> Void
    /// Sends `skill N` to the engine. The other half of the load mask.
    private let pushEngineSkill: (Int) -> Void
    private var maskedUntil: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    /// The engine value as of the last tick. Seeded lazily on the first tick
    /// from the stored value, which the launch push has already put into the
    /// engine, so a quiet start observes agreement rather than a change.
    private var lastSeen: Int?

    init(readEngineSkill: @escaping () -> Int,
         readStored: @escaping () -> Int,
         writeStored: @escaping (Int) -> Void,
         pushEngineSkill: @escaping (Int) -> Void) {
        self.readEngineSkill = readEngineSkill
        self.readStored = readStored
        self.writeStored = writeStored
        self.pushEngineSkill = pushEngineSkill
    }

    /// Called immediately BEFORE a load command is issued.
    func markLoad() {
        maskedUntil = ContinuousClock.now.advanced(by: Self.loadMask)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        var inFlight = false
        if let until = maskedUntil {
            if ContinuousClock.now < until { inFlight = true } else { maskedUntil = nil }
        }

        let engine = readEngineSkill()
        guard (0...3).contains(engine) else { return }   // a bad read teaches nothing
        let seen = lastSeen ?? readStored()

        switch DifficultyWatch.decide(engineSkill: engine, stored: readStored(),
                                      lastSeen: seen, loadInFlight: inFlight) {
        case .adopt(let v):
            writeStored(v)
        case .restore(let v):
            // Put the engine back where the player left it. Harmless to the
            // running game: its own skill was sampled when it spawned.
            pushEngineSkill(v)
        case nil:
            break
        }
        // Recorded whether or not anything was done. This is what stops a
        // declined load-driven change reading as a fresh one next tick.
        lastSeen = engine
    }
}
