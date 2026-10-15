// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  SessionState.swift
//
//  The Game tab's read-back of the engine: whether `save` would be accepted
//  and why not, where saves live, whether we are connected, and what `slist`
//  found. The engine assembles all of it on its own thread each frame
//  (platform/session_avp.c); this polls it through the any-thread
//  QC_SessionCopyState/QC_ServerListCopy only while the tab is on screen, the
//  same arrangement EnemyRoster has with the admin roster.
//
//  Nothing here writes engine state. The actions below are console commands
//  through the one send path, exactly as if they had been typed -- which is
//  the point: `save`, `load`, `connect`, `disconnect` and `slist` keep all
//  their engine-side behaviour, including the lines they print when they
//  refuse. The window shows the same refusal in advance instead of inventing
//  rules of its own.
//

import Foundation
import Observation

@Observable
@MainActor
final class SessionState {

    /// Why `save` would be refused right now -- the engine's own guard order,
    /// decided in session_avp.c and mirrored here only as text.
    enum SaveBlock: Int32 {
        case none = 0
        case noLocalGame = 1
        case nomonsters = 2
        case intermission = 3
        case multiplayer = 4
        case playerDead = 5

        /// What the console would have printed, said to a player.
        var caption: String? {
            switch self {
            case .none:          return nil
            case .noLocalGame:   return "Start a level to save."
            case .nomonsters:    return "Can't save with nomonsters on."
            case .intermission:  return "Can't save during the intermission."
            case .multiplayer:   return "Can't save a multiplayer game."
            case .playerDead:    return "Can't save with a dead player."
            }
        }
    }

    /// One row of the LAN browser, as `slist` filled it.
    struct Server: Identifiable, Hashable {
        /// The address `connect` takes. Unique per row, and the thing a tap
        /// actually uses, so it is the identity.
        let address: String
        let name: String
        let map: String
        let users: Int
        /// 0 when the server did not report a limit (the engine prints the
        /// row without a count in that case, and so does the window).
        let maxUsers: Int

        var id: String { address }

        var playersText: String? {
            maxUsers > 0 ? "\(users)/\(maxUsers) players" : nil
        }
    }

    private(set) var levelLoaded = false
    private(set) var connected = false
    private(set) var saveBlock: SaveBlock = .noLocalGame
    private(set) var isSearching = false
    private(set) var servers: [Server] = []
    /// `com_gamedir`, the directory the engine reads and writes savegames in.
    /// Nil until the engine has published a snapshot.
    private(set) var gameDirectory: URL?
    /// The `.sav` files in `gameDirectory`, newest first. Rescanned on the
    /// tab appearing and after a save or a delete -- not on the poll, which
    /// would stat the directory twice a second for nothing.
    private(set) var slots: [SaveGameSlot] = []
    /// A save has been sent and its slot has not shown up yet. Drives the
    /// "Saving…" caption and keeps the row from flickering (see `pendingSave`).
    var isSaving: Bool { pendingSave != nil }
    /// `connect` has been sent and `cls.state` has not reached ca_connected.
    /// NET_Connect blocks the engine thread for up to about a second and a
    /// half while it resolves and handshakes; without a state for that, the
    /// tap reads as a hang.
    private(set) var isConnecting = false

    var canSave: Bool { saveBlock == .none }

    private var timer: Timer?

    /// The save we are waiting to see on disk, what the slot's timestamp was
    /// before it (nil if the slot is new), and when we asked.
    ///
    /// There is no engine signal for "the savegame is written", and guessing
    /// with a sleep is both a guess and wrong in a specific way:
    /// `Host_Savegame_f` opens with `fopen(name, "w")`, which TRUNCATES
    /// immediately, and stdio then buffers the version and comment lines
    /// until the first `fflush` after edict 0. A scan landing inside that
    /// window reads a zero-byte file, `readHeader` returns nil, and the slot
    /// is dropped -- so overwriting an existing save made its row vanish and
    /// come back, which reads as having destroyed it.
    ///
    /// So the poll that is already running does the work: while this is set,
    /// every tick rescans and the previous row is held in place until the new
    /// one parses. Bounded, because a write that never lands must not pin the
    /// poll to the filesystem forever.
    private var pendingSave: (name: String, previous: Date?, requestedAt: Date)?
    private static let pendingSaveTimeout: TimeInterval = 10
    /// How long to wait for `cls.state` before giving up on the badge. The
    /// engine's own NET_Connect timeout is well inside this.
    private static let connectTimeout: TimeInterval = 8
    private var connectRequestedAt: Date?

    // MARK: - polling

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var state = qc_session_state_t()
        QC_SessionCopyState(&state)

        // Equality-guarded, every one. @Observable's generated setters fire
        // on assignment, not on change, and this poll runs twice a second for
        // as long as the window is up -- an unguarded write would re-evaluate
        // the whole tab 2 Hz forever for values that almost never move.
        let newLevelLoaded = state.level_loaded != 0
        if newLevelLoaded != levelLoaded { levelLoaded = newLevelLoaded }
        let newConnected = state.connected != 0
        if newConnected != connected { connected = newConnected }
        let newSaveBlock = SaveBlock(rawValue: state.save_block) ?? .noLocalGame
        if newSaveBlock != saveBlock { saveBlock = newSaveBlock }
        let newSearching = state.slist_in_progress != 0
        if newSearching != isSearching { isSearching = newSearching }

        updateConnecting()

        let directory = Self.string(from: &state.gamedir, capacity: Int(QC_GAMEDIR_LEN))
        let url = directory.isEmpty ? nil : URL(fileURLWithPath: directory, isDirectory: true)
        if url != gameDirectory {
            gameDirectory = url
            refreshSlots()      // `game <mod>` moved the save directory
        }

        // The rows come through the list copier rather than being unpacked
        // from the tuple above, so the count and the rows are one consistent
        // copy even if the engine refreshed in between the two calls.
        var raw = [qc_server_t](repeating: qc_server_t(), count: Int(QC_SERVER_MAX))
        let count = Int(QC_ServerListCopy(&raw, Int32(QC_SERVER_MAX)))
        var list: [Server] = []
        list.reserveCapacity(count)
        for i in 0..<count {
            let address = Self.string(from: &raw[i].cname, capacity: Int(QC_SERVER_CNAME_LEN))
            guard !address.isEmpty else { continue }
            list.append(Server(address: address,
                               name: Self.string(from: &raw[i].name,
                                                 capacity: Int(QC_SERVER_NAME_LEN)),
                               map: Self.string(from: &raw[i].map,
                                                capacity: Int(QC_SERVER_MAP_LEN)),
                               users: Int(raw[i].users),
                               maxUsers: Int(raw[i].maxusers)))
        }
        if list != servers { servers = list }

        // The one thing the poll does with the filesystem, and only while a
        // save is actually in flight.
        if pendingSave != nil { refreshSlots() }
    }

    /// Rescan the engine's game directory for savegames.
    ///
    /// While a save is pending, a slot that was already there is CARRIED
    /// OVER if this scan cannot read it: that is the truncate-then-buffer
    /// window described on `pendingSave`, and showing the row disappear
    /// during it would say the save had been destroyed.
    func refreshSlots() {
        guard let gameDirectory else {
            if !slots.isEmpty { slots = [] }
            return
        }
        var scanned = SaveGameHeader.list(in: gameDirectory)

        if let pending = pendingSave {
            let found = scanned.first { $0.name == pending.name }
            let landed = found.map { slot in
                pending.previous.map { slot.modified > $0 } ?? true
            } ?? false

            if landed {
                pendingSave = nil
            } else {
                if found == nil, let stale = slots.first(where: { $0.name == pending.name }) {
                    scanned.append(stale)
                    scanned.sort { $0.modified > $1.modified }
                }
                if Date().timeIntervalSince(pending.requestedAt) > Self.pendingSaveTimeout {
                    // Give up watching rather than scan forever. The list is
                    // left exactly as the last scan saw it, and Rescan is
                    // still there.
                    pendingSave = nil
                }
            }
        }

        if scanned != slots { slots = scanned }
    }

    /// Clear the connecting badge once the engine says so, or once it has
    /// plainly not worked. `connect` prints its own failure to the console.
    private func updateConnecting() {
        guard isConnecting else { return }
        if connected {
            isConnecting = false
            connectRequestedAt = nil
        } else if let since = connectRequestedAt,
                  Date().timeIntervalSince(since) > Self.connectTimeout {
            isConnecting = false
            connectRequestedAt = nil
        }
    }

    // MARK: - actions (all of them ordinary console commands)

    /// `save <name>`. Refuses locally only for what the console cannot
    /// recover from -- a name that would not survive Cbuf's tokenizer, and a
    /// state the engine would refuse anyway. Everything else is the engine's
    /// call, and it prints its own reason.
    func save(_ name: String) {
        guard canSave, ConsoleArgument.isValidSavegameName(name) else { return }
        // Record what the slot looked like BEFORE the send, so the poll can
        // tell an overwrite from the file that was already there. Everything
        // else about waiting for the write is on `pendingSave`.
        pendingSave = (name: name,
                       previous: slots.first { $0.name == name }?.modified,
                       requestedAt: Date())
        QuakeEngineViewModel.shared.send("save \(name)")
    }

    /// `load <name>`. Allowed with no level loaded -- that is how a session
    /// resumes from cold -- and allowed on a version mismatch only because
    /// the row for such a save is not offered in the first place.
    func load(_ name: String) {
        guard ConsoleArgument.isValidSavegameName(name) else { return }
        QuakeEngineViewModel.shared.send("load \(name)")
    }

    /// Delete a slot. There is no engine command for this; the file is the
    /// engine's, so the only honest thing to do is remove it and rescan.
    func delete(_ slot: SaveGameSlot) {
        // A delete of the slot being written would fight the poll. Drop the
        // watch first so the carry-over cannot resurrect the row.
        if pendingSave?.name == slot.name { pendingSave = nil }
        try? FileManager.default.removeItem(at: slot.url)
        refreshSlots()
    }

    /// `connect <address>`. NET_Connect runs a silent `slist` and then spins
    /// `while (slistInProgress) NET_Poll();` on the ENGINE thread, so this
    /// freezes the simulation for up to about a second and a half and empties
    /// the browser list on the way through (NET_Slist_f zeroes
    /// hostCacheCount). That is upstream's own behaviour and the menu did the
    /// same; making it asynchronous is a separate job. What the
    /// window owes the player is a state for it, which `isConnecting` is.
    func connect(to address: String) {
        guard ConsoleArgument.isValidAddress(address) else { return }
        isConnecting = true
        connectRequestedAt = Date()
        QuakeEngineViewModel.shared.send("connect \(address)")
    }

    func disconnect() {
        isConnecting = false
        connectRequestedAt = nil
        QuakeEngineViewModel.shared.send("disconnect")
    }

    /// `slist`. The engine ignores a second one while a search is in flight
    /// (NET_Slist_f returns immediately on slistInProgress), so the button is
    /// disabled while searching rather than queueing a no-op.
    func searchServers() {
        QuakeEngineViewModel.shared.send("slist")
    }

    // MARK: - Private

    /// A fixed-width C char array in an imported struct arrives as a tuple;
    /// rebind it to read the string, the way EnemyRoster reads a classname.
    private static func string<T>(from field: inout T, capacity: Int) -> String {
        withUnsafePointer(to: &field) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
