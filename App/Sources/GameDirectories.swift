// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  GameDirectories.swift
//
//  Which mods, expansions and map packs are installed, and what maps each
//  one holds.
//
//  The engine has always been able to play them: `game <dir>` is a stock
//  console command, and the app sets `UIFileSharingEnabled`, so a pack
//  dropped into Documents from the Files app is already loadable. What was
//  missing was any way to SEE them, which meant knowing both the command and
//  the folder's exact name. This is the data behind the window's picker.
//
//  `COM_Game_f` accepts a single directory name under basedir or userdir and
//  nothing else: no paths, no separators. So discovery is one level deep in
//  each, and a candidate qualifies by holding a `.pak` or a `maps/` folder.
//  That is the same test a player would apply by eye, and it keeps `music`,
//  `localization` and the save directories out of the list.
//
//  Pure: no SwiftUI, no engine. tools/check-swift-session.sh compiles it
//  alone against its test.
//

import Foundation

enum GameDirectories {

    /// The stock game, which is always offered even before anything is
    /// installed beside it. Named here rather than spelled in three places.
    static let base = "id1"

    /// The two expansions the engine wants a second argument for.
    ///
    /// `COM_Game_f` takes `-hipnotic`, `-rogue` or `-quoth` after the
    /// directory, and the mission packs need it: without the flag the pack's
    /// maps load but the HUD and the progs behaviour stay id1's. A third
    /// party pack takes no flag at all, so this is a lookup rather than a
    /// guess from the name.
    static let missionPackFlag: [String: String] = [
        "hipnotic": "-hipnotic",
        "rogue": "-rogue",
        "quoth": "-quoth",
    ]

    /// The console command that switches to `directory`.
    static func command(for directory: String) -> String {
        if let flag = missionPackFlag[directory.lowercased()] {
            return "game \(directory) \(flag)"
        }
        return "game \(directory)"
    }

    /// A human label. The stock directories get their real names; anything
    /// else is shown as installed, because a pack's folder name is the only
    /// name we have and inventing a prettier one would be guessing.
    static func label(for directory: String) -> String {
        switch directory.lowercased() {
        case "id1":      return "Quake"
        case "hipnotic": return "Scourge of Armagon"
        case "rogue":    return "Dissolution of Eternity"
        case "dopa":     return "Dimension of the Past"
        case "mg1":      return "Dimension of the Machine"
        case "mg3":      return "Dawn of the Machine"
        default:         return directory
        }
    }

    /// Whether a directory's contents make it a game directory.
    ///
    /// A `.pak` or a `maps/` folder. Deliberately NOT "contains any file":
    /// `music`, `localization` and anything else sitting beside the games
    /// would pass that and then fail to load.
    static func isGameDirectory(contents: [String]) -> Bool {
        contents.contains { $0.lowercased().hasSuffix(".pak") }
            || contents.contains { $0.lowercased() == "maps" }
    }

    /// Release year of each official game, for ordering the picker.
    ///
    /// Chronological rather than alphabetical because that is the order they
    /// were meant to be played and the order a player thinks in: Quake, then
    /// its two 1997 mission packs, then the three modern episodes. Sorting by
    /// name put Dawn of the Machine second and Quake fourth, which reads as
    /// scrambled to anyone who knows the games.
    static let releaseYear: [String: Int] = [
        "id1": 1996,
        "hipnotic": 1997,       // Scourge of Armagon
        "rogue": 1997,          // Dissolution of Eternity
        "dopa": 2016,           // Dimension of the Past
        "mg1": 2021,            // Dimension of the Machine
        "mg3": 2024,            // Dawn of the Machine
    ]

    /// Installed game directories: the official games in release order, then
    /// everything else alphabetically.
    ///
    /// Merged across basedir and userdir because `COM_Game_f` accepts either,
    /// and deduplicated case-insensitively because the same pack can exist in
    /// both and the engine would treat them as one.
    ///
    /// A third-party pack has no year we can know, so it sorts after the
    /// official ones rather than being given a guessed date. That also keeps
    /// the official list stable as packs are added and removed.
    static func merge(base baseNames: [String], user userNames: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in baseNames + userNames {
            let key = name.lowercased()
            if seen.insert(key).inserted { out.append(name) }
        }
        out.sort { a, b in
            let ya = releaseYear[a.lowercased()]
            let yb = releaseYear[b.lowercased()]
            switch (ya, yb) {
            case let (ya?, yb?):
                if ya != yb { return ya < yb }
                // Same year: the two 1997 packs, in the order they shipped.
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            case (nil, _?): return false        // packs after the official games
            case (_?, nil): return true
            default: return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        return out
    }

    /// Map names from a list of file paths, as `map <name>` wants them:
    /// `maps/e1m1.bsp` becomes `e1m1`.
    ///
    /// Takes paths rather than reading anything, so the same rule serves a
    /// pak's directory listing and a loose `maps/` folder.
    static func mapNames(fromPaths paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let lower = path.lowercased()
            guard lower.hasSuffix(".bsp") else { continue }
            // Submodel BSPs (`maps/bmodel/b_shot2.bsp`) are not levels and
            // cannot be loaded with `map`. They live one folder deeper.
            let parts = lower.split(separator: "/")
            guard parts.count == 2, parts[0] == "maps" else { continue }
            let name = String(parts[1].dropLast(4))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out.sorted()
    }
}
