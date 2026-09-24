//
//  EnemyRoster.swift
//
//  The Admin tab's read-back of the server's monsters: who is alive, how far
//  away, and whom each one is hunting. The engine refreshes a snapshot on its
//  own thread a few times a second (admin_avp.c); this polls it through the
//  any-thread QC_AdminCopyState only while the tab is on screen, so the
//  window costs nothing when the panel is elsewhere. Commands go back out the
//  usual console route -- this class never writes engine state.
//

import Foundation
import Observation

@Observable
@MainActor
final class EnemyRoster {

    struct Monster: Identifiable, Hashable {
        /// Server edict number: the handle `ai_target` takes.
        let id: Int32
        let classname: String
        let health: Float
        /// Edict it is hunting, 0 for none.
        let enemy: Int32
        /// Quake units to the player.
        let distance: Float

        /// "monster_army" reads as Grunt in the picker.
        var displayName: String {
            let key = classname.hasPrefix("monster_")
                ? String(classname.dropFirst("monster_".count)) : classname
            return Self.names[key] ?? key.capitalized
        }

        private static let names: [String: String] = [
            "army": "Grunt", "dog": "Rottweiler", "ogre": "Ogre", "ogre_marksman": "Ogre",
            "knight": "Knight", "zombie": "Zombie", "wizard": "Scrag", "demon1": "Fiend",
            "shambler": "Shambler", "tarbaby": "Spawn", "hell_knight": "Death Knight",
            "enforcer": "Enforcer", "shalrath": "Vore", "fish": "Rotfish",
            "boss": "Chthon", "oldone": "Shub-Niggurath",
        ]
    }

    /// Live monsters, nearest first.
    private(set) var monsters: [Monster] = []
    /// `sv_killai` as the engine last reported it (the console can flip it too).
    private(set) var killAI = false
    private(set) var playerEdict: Int32 = 0
    private(set) var levelLoaded = false

    private var timer: Timer?

    /// 1 Quake unit = 1 inch at the default world scale.
    static let metersPerUnit: Float = 0.0254

    func monster(_ edict: Int32) -> Monster? {
        monsters.first { $0.id == edict }
    }

    /// One line for a picker row: "Grunt #89 · 30 hp · 12 m · hunting you".
    func label(for m: Monster) -> String {
        var parts = ["\(m.displayName) #\(m.id)",
                     "\(Int(m.health.rounded())) hp",
                     "\(Int((m.distance * Self.metersPerUnit).rounded())) m"]
        if m.enemy != 0 {
            if m.enemy == playerEdict {
                parts.append("hunting you")
            } else if let target = monster(m.enemy) {
                parts.append("hunting \(target.displayName) #\(target.id)")
            } else {
                parts.append("hunting #\(m.enemy)")
            }
        }
        return parts.joined(separator: " · ")
    }

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
        var state = qc_admin_state_t()
        QC_AdminCopyState(&state)

        levelLoaded = state.active != 0
        killAI = state.killai != 0
        playerEdict = state.player_edict

        let count = Int(min(state.count, Int32(QC_ADMIN_MAX_MONSTERS)))
        var list: [Monster] = []
        list.reserveCapacity(count)
        withUnsafePointer(to: &state.monsters) { tuple in
            tuple.withMemoryRebound(to: qc_monster_t.self, capacity: Int(QC_ADMIN_MAX_MONSTERS)) { base in
                for i in 0..<count {
                    var raw = base[i]
                    let name = withUnsafePointer(to: &raw.classname) { chars in
                        chars.withMemoryRebound(to: CChar.self, capacity: Int(QC_ADMIN_CLASSNAME_LEN)) {
                            String(cString: $0)
                        }
                    }
                    list.append(Monster(id: raw.edict, classname: name, health: raw.health,
                                        enemy: raw.enemy, distance: raw.distance))
                }
            }
        }
        list.sort { $0.distance < $1.distance }
        if list != monsters { monsters = list }
    }
}
