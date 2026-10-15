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

    var canSave: Bool { saveBlock == .none }

    private var timer: Timer?

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

        levelLoaded = state.level_loaded != 0
        connected = state.connected != 0
        saveBlock = SaveBlock(rawValue: state.save_block) ?? .noLocalGame
        isSearching = state.slist_in_progress != 0

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
    }

    /// Rescan the engine's game directory for savegames.
    func refreshSlots() {
        guard let gameDirectory else { slots = []; return }
        slots = SaveGameHeader.list(in: gameDirectory)
    }

    // MARK: - actions (all of them ordinary console commands)

    /// `save <name>`. Refuses locally only for what the console cannot
    /// recover from -- a name that would not survive Cbuf's tokenizer, and a
    /// state the engine would refuse anyway. Everything else is the engine's
    /// call, and it prints its own reason.
    func save(_ name: String) {
        guard canSave, ConsoleArgument.isValidSavegameName(name) else { return }
        QuakeEngineViewModel.shared.send("save \(name)")
        // The engine writes the file on its next drained frame, so a rescan
        // here would miss it. Rescan twice: once for the common case, and
        // again later because the write itself is not instant -- Host_
        // Savegame_f fflushes after every edict and then syncs the
        // filesystem, which on a big level is long enough for one 600 ms
        // rescan to show nothing and leave the player tapping Rescan.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refreshSlots()
            try? await Task.sleep(for: .milliseconds(2500))
            self?.refreshSlots()
        }
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
        try? FileManager.default.removeItem(at: slot.url)
        refreshSlots()
    }

    func connect(to address: String) {
        guard ConsoleArgument.isValidAddress(address) else { return }
        QuakeEngineViewModel.shared.send("connect \(address)")
    }

    func disconnect() {
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
