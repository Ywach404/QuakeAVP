// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  session_test.swift
//
//  Host-run test for the window's Game-tab pure halves:
//  App/Sources/SaveGames.swift (reading Quake's own `.sav` header) and
//  App/Sources/ConsoleArgument.swift (what may be pasted into a console
//  command). Compiled and linked ALONE against those two files by
//  tools/check-swift-session.sh -- no Observation, no engine, no simulator.
//
//  The savegame fixtures are written here rather than committed: the format
//  under test is the two lines Host_Savegame_f emits, and writing them from
//  the same description the parser claims to read is the point.
//

import Foundation

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok:   \(label)")
    } else {
        print("FAIL: \(label)")
        exit(1)
    }
}

/// What Host_SavegameComment produces: 39 characters, level name in the first
/// 22, "kills:%3i/%3i" at offset 22, every space turned into an underscore.
func engineComment(level: String, kills: Int, total: Int) -> String {
    var text = Array(repeating: Character(" "), count: 39)
    for (i, c) in level.prefix(22).enumerated() { text[i] = c }
    let killsText = String(format: "kills:%3i/%3i", kills, total)
    for (i, c) in killsText.enumerated() where 22 + i < 39 { text[22 + i] = c }
    return String(text).replacingOccurrences(of: " ", with: "_")
}

@main
struct SessionTest {

    static func main() {
        runHeaderParseTests()
        runDifficultyTests()
        runDifficultyWatchTests()
        runCoverFlowTests()
        runSaveNamingTests()
        runSlotListTests()
        runConsoleArgumentTests()
        print("PASSED")
    }

    // MARK: - difficulty

    /// A whole savegame header the way Host_Savegame_f writes it: version,
    /// comment, NUM_SPAWN_PARMS (16) floats, current_skill, map name, time.
    /// Built from that description rather than committed, for the same reason
    /// the two-line fixtures above are.
    static func saveHeader(skill: String, version: Int = 5,
                           parms: Int = 16) -> String {
        let comment = engineComment(level: "the Slipgate Complex", kills: 7, total: 31)
        var s = "\(version)\n\(comment)\n"
        for _ in 0..<parms { s += "0.000000\n" }
        s += "\(skill)\ne1m1\n12.345000\n"
        return s
    }

    static func runDifficultyTests() {
        // The four the engine clamps to (sv_main.c:1489-1492).
        check(Difficulty.allCases.count == 4, "there are exactly four difficulties")
        check(Difficulty.allCases.map(\.label) == ["Easy", "Normal", "Hard", "Nightmare"],
              "the labels are the four Quake names, in skill order")
        check(Difficulty.easy.rawValue == 0 && Difficulty.nightmare.rawValue == 3,
              "the raw values are the engine's skill numbers")

        check(Difficulty.from(skillLine: "0") == .easy, "skill 0 is Easy")
        check(Difficulty.from(skillLine: "2") == .hard, "skill 2 is Hard")
        check(Difficulty.from(skillLine: "3") == .nightmare, "skill 3 is Nightmare")
        // Written by fprintf("%d") today, but a float-formatted line is the
        // obvious thing a mod or a hand edit produces, and it means the same.
        check(Difficulty.from(skillLine: "2.000000") == .hard,
              "a float-formatted skill line still reads as Hard")
        check(Difficulty.from(skillLine: " 1 ") == .normal,
              "surrounding whitespace is ignored")

        // Out of range is REFUSED, never clamped: clamping would label a save
        // with a difficulty it was not played on.
        check(Difficulty.from(skillLine: "7") == nil, "a skill above 3 is refused")
        check(Difficulty.from(skillLine: "-1") == nil, "a negative skill is refused")
        check(Difficulty.from(skillLine: "1.5") == nil, "a non-integral skill is refused")
        check(Difficulty.from(skillLine: "") == nil, "an empty skill line is refused")
        check(Difficulty.from(skillLine: "x") == nil, "a non-numeric skill line is refused")

        // Through the real parse, at the real line.
        check(SaveGameHeader.parse(saveHeader(skill: "2"))?.difficulty == .hard,
              "the parse finds the difficulty on line 19")
        check(SaveGameHeader.parse(saveHeader(skill: "0"))?.difficulty == .easy,
              "and on line 19 for Easy too")

        // A truncated file still LISTS, it just has no pip. A save you cannot
        // describe is better than a row that vanished.
        let short = SaveGameHeader.parse(saveHeader(skill: "2", parms: 3))
        check(short != nil, "a header with too few spawn parms still parses")
        check(short?.difficulty == nil, "and reports no difficulty rather than guessing")
        check(SaveGameHeader.parse("5\n\(engineComment(level: "x", kills: 0, total: 0))\n")?
                .difficulty == nil,
              "the old two-line fixture has no difficulty and does not crash")

        // The clamp VRSettings.skill is built on, kept here so it has one
        // definition and a host test.
        check(clampSkill(-3) == 0, "a stored skill below range clamps to Easy")
        check(clampSkill(9) == 3, "a stored skill above range clamps to Nightmare")
        check(clampSkill(2) == 2, "a stored skill in range is untouched")
    }

    // MARK: - adopting an engine-side difficulty change

    static func runDifficultyWatchTests() {
        typealias W = DifficultyWatch

        // --- the decision, as an action rather than a bare value ----------
        // A load writes the skill cvar from the file it is loading. Masking
        // that stops it rewriting the player's PREFERENCE, which was right,
        // but it left the ENGINE holding the loaded save's skill -- so every
        // level started afterwards spawned at that, not at what was chosen.
        // Found on device: the cvar read 3, the next save recorded 0.
        check(W.decide(engineSkill: 3, stored: 3, lastSeen: 3, loadInFlight: false) == nil,
              "agreement all round does nothing")
        check(W.decide(engineSkill: 2, stored: 1, lastSeen: 1, loadInFlight: false)
                == .adopt(2),
              "a fresh engine-side change is the player choosing: adopt it")
        check(W.decide(engineSkill: 0, stored: 3, lastSeen: 3, loadInFlight: true) == nil,
              "during a load, only observe")
        check(W.decide(engineSkill: 0, stored: 3, lastSeen: 0, loadInFlight: false)
                == .restore(3),
              "after the load, the engine is put BACK to the chosen difficulty")
        check(W.decide(engineSkill: 0, stored: 0, lastSeen: 0, loadInFlight: false) == nil,
              "a load of a save that matches the preference needs no restore")
        check(W.decide(engineSkill: 9, stored: 1, lastSeen: 1, loadInFlight: false) == nil,
              "an out-of-range read is ignored entirely")

        // Restoring must not fight an adopt: a hub door is a fresh change and
        // wins, even when the engine also differs from what is stored.
        check(W.decide(engineSkill: 2, stored: 3, lastSeen: 1, loadInFlight: false)
                == .adopt(2),
              "a fresh change is adopted, never mistaken for a load to undo")

    }

    // MARK: - the carousel's arithmetic

    static func runCoverFlowTests() {
        typealias M = CoverFlowMetrics

        // Pitch is what decides how many cards fit. The flankers overlap each
        // other by a fraction of a card, which is the negative HStack spacing.
        check(abs(M.pitch - M.cardWidth * (1 - M.flankerOverlapFraction)) < 0.01,
              "pitch is a card less its overlap (\(M.pitch))")

        // contentMargins is NOT centring -- it shrinks the measured region to
        // one card so only the centre card can reach .identity. Get this wrong
        // and the cards sit flat with no Cover Flow at all.
        check(abs(M.contentMargin(forWidth: 560) - (560 - M.cardWidth) / 2) < 0.01,
              "the margin insets the region to a single card's width")
        check(M.contentMargin(forWidth: 100) == 0,
              "a column narrower than a card gives no margin, never a negative one")

        check(M.visibleCardCount(forWidth: 560) == 5,
              "the 560pt column floor shows a five-card deck")
        check(M.visibleCardCount(forWidth: 300) == 3,
              "a narrow column still shows a hero and one flanker each side")
        check(M.visibleCardCount(forWidth: 0) == 1,
              "there is always at least the hero")

        // The deck is TALLER than a card. A card tilted in perspective is
        // taller than its flat self, and a container of exactly cardHeight is
        // where the corners were being cut.
        check(M.deckHeight > M.cardHeight,
              "the deck leaves headroom for a tilted card (\(M.deckHeight) vs \(M.cardHeight))")
        check(M.deckHeight >= M.cardHeight * 1.2,
              "and enough of it to cover a 55 degree turn")

        // The two orange refusals are independent and a save can be both.
        let both = SaveGameSlot(name: "my save", url: URL(fileURLWithPath: "/tmp/my save.sav"),
                                version: 4, comment: "", difficulty: nil,
                                modified: .distantPast)
        let badges = CoverFlowMetrics.badges(for: both)
        check(badges.count == 2, "a foreign version with an unusable name shows BOTH warnings")
        check(badges.contains(.versionMismatch(4)), "the version badge carries the file's version")
        check(badges.contains(.unaddressable), "and the name badge is there too")

        let fine = SaveGameSlot(name: "s3", url: URL(fileURLWithPath: "/tmp/s3.sav"),
                                version: SaveGameHeader.version, comment: "",
                                difficulty: .hard, modified: .distantPast)
        check(CoverFlowMetrics.badges(for: fine).isEmpty,
              "a loadable, addressable save shows no warning")

        check(CoverBadge.versionMismatch(4).caption
                == "Savegame version 4 — this engine reads version \(SaveGameHeader.version).",
              "the version caption is the engine's own wording")
        check(CoverBadge.unaddressable.caption
                == "Rename this file (letters, digits, - and _) to load it — the console cannot take a name with a space or a dot in it.",
              "the name caption is the engine's own wording")

        // Two different empty states, and they say different things.
        check(CoverFlowMetrics.emptyMessage(gameDirectory: nil) == "Waiting for the engine.",
              "no game directory yet reads as waiting for the engine")
        check(CoverFlowMetrics.emptyMessage(gameDirectory: URL(fileURLWithPath: "/tmp"))
                == "No saved games yet.",
              "a directory with nothing in it reads as no saved games")
    }

    // MARK: - naming a new save

    static func runSaveNamingTests() {
        typealias N = SaveNaming

        check(N.nextFreeSlotName(existing: []) == "s0", "the first save is s0")
        check(N.nextFreeSlotName(existing: ["s0"]) == "s1", "the next one does not overwrite it")
        check(N.nextFreeSlotName(existing: ["s0", "s1", "s2"]) == "s3", "and keeps counting up")

        // Counting the saves would be wrong here, which is the point of the
        // function: with s1 deleted there are two saves, and "s2" is taken.
        check(N.nextFreeSlotName(existing: ["s0", "s2"]) == "s1",
              "a gap left by a delete is filled, not skipped")
        check(N.nextFreeSlotName(existing: ["quicksave", "my run"]) == "s0",
              "names that are not s-numbers do not consume a slot")

        check(N.nextFreeSlotName(existing: (0..<100).map { "s\($0)" }).hasPrefix("save"),
              "a hundred s-numbers falls back to a name that cannot collide")

    }

    // MARK: - header parsing

    static func runHeaderParseTests() {
        let comment = engineComment(level: "the Slipgate Complex", kills: 7, total: 31)
        let header = "5\n\(comment)\n0.000000\n0.000000\n"

        let parsed = SaveGameHeader.parse(header)
        check(parsed?.version == 5, "version comes off the first line")
        check(parsed?.comment == comment, "comment comes off the second line, raw")
        check(SaveGameHeader.displayText(for: comment)
                == "the Slipgate Complex  kills:  7/ 31",
              "display swaps underscores back to spaces and trims the padding")

        check(SaveGameHeader.parse("") == nil, "an empty file is not a savegame")
        check(SaveGameHeader.parse("not-a-number\ncomment\n") == nil,
              "a non-numeric first line is not a savegame")
        check(SaveGameHeader.parse("5") == nil,
              "a lone version with no second line is not a savegame")
        // An EMPTY comment line is not malformed: Host_Loadgame_f parses the
        // comment with COM_ParseStringNewline and never looks at it again, so
        // such a save loads. The row just shows its name and nothing else.
        check(SaveGameHeader.parse("5\n\n")?.comment == "",
              "an empty comment line parses -- the engine would still load it")
        check(SaveGameHeader.parse("4\n\(comment)\n")?.version == 4,
              "a foreign version still parses -- it is reported, not hidden")

        // A pak-era level name with an underscore in it comes back as a space,
        // exactly as the engine menu showed it. Pinned so the lossiness is a
        // decision rather than a surprise.
        let underscored = engineComment(level: "e1m1_test", kills: 0, total: 0)
        check(SaveGameHeader.displayText(for: underscored).hasPrefix("e1m1 test"),
              "an underscore in the level name reads back as a space, as upstream")
    }

    // MARK: - listing a game directory

    static func runSlotListTests() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("qavp-session-test-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func write(_ name: String, version: Int, level: String, bodyBytes: Int = 4096) {
            let comment = engineComment(level: level, kills: 1, total: 2)
            var text = "\(version)\n\(comment)\n"
            // A real savegame is every edict in the level. The header reader
            // must not depend on the file being small.
            text += String(repeating: "0.000000\n", count: bodyBytes / 9)
            try! text.write(to: dir.appendingPathComponent(name), atomically: true,
                            encoding: .utf8)
        }

        write("s0.sav", version: 5, level: "Slipgate")
        // Distinct mtimes so the newest-first order is actually tested.
        Thread.sleep(forTimeInterval: 0.02)
        write("s1.sav", version: 4, level: "Castle")
        Thread.sleep(forTimeInterval: 0.02)
        write("quick.sav", version: 5, level: "Necropolis")
        try! "garbage".write(to: dir.appendingPathComponent("broken.sav"),
                             atomically: true, encoding: .utf8)
        try! "nothing".write(to: dir.appendingPathComponent("config.cfg"),
                             atomically: true, encoding: .utf8)

        let slots = SaveGameHeader.list(in: dir)
        check(slots.count == 3, "three readable saves listed, the junk .sav dropped")
        check(slots.map(\.name) == ["quick", "s1", "s0"], "newest first")
        check(!slots.contains { $0.name == "config" }, "non-.sav files are ignored")
        check(slots.first { $0.name == "s0" }?.isLoadable == true,
              "a version-5 save is loadable")
        check(slots.first { $0.name == "s1" }?.isLoadable == false,
              "a version-4 save is reported unloadable rather than offered")
        check(slots.first { $0.name == "quick" }?.displayText.hasPrefix("Necropolis") == true,
              "the row shows the level name the engine wrote")

        check(SaveGameHeader.list(in: dir.appendingPathComponent("nope")).isEmpty,
              "a missing game directory lists as empty, not a crash")

        // A .sav dropped in over the Files app can be called anything. Such a
        // slot must still list and still show its comment -- it just cannot
        // be the argument of a `load`, and the row has to say so rather than
        // offering a button that no-ops.
        write("my save.sav", version: 5, level: "Dropped In")
        let withSpace = SaveGameHeader.list(in: dir).first { $0.name == "my save" }
        check(withSpace != nil, "a save with a space in its name still lists")
        check(withSpace?.isLoadable == true, "...and its version is fine")
        check(withSpace?.isAddressable == false,
              "...but it is not addressable, because `load my save` would not tokenize")
        check(slots.first { $0.name == "s0" }?.isAddressable == true,
              "an ordinary slot name is addressable")

        // Quake's high-bit charset: 0x80...0xFF are the gold twins of
        // 0x00...0x7F. Decoded as UTF-8 they are invalid and the row would be
        // a run of replacement characters, so bit 7 is stripped first.
        let gold = Data([0x35, 0x0a]                                  // "5\n"
                        + "Gold".utf8.map { $0 | 0x80 }               // high-bit text
                        + [0x0a])
        try! gold.write(to: dir.appendingPathComponent("gold.sav"))
        let goldSlot = SaveGameHeader.list(in: dir).first { $0.name == "gold" }
        check(goldSlot?.displayText == "Gold",
              "a high-bit level name reads as plain text, not replacement characters")

        check(SaveGameHeader.quickSlotNames.first == "s0"
                && SaveGameHeader.quickSlotNames.last == "s11",
              "quick slots mirror menu.c's s0...s11")
    }

    // MARK: - console arguments

    static func runConsoleArgumentTests() {
        check(ConsoleArgument.isValidSavegameName("s0"), "s0 is a valid savegame name")
        check(ConsoleArgument.isValidSavegameName("before_shambler"),
              "underscores are fine in a savegame name")
        check(!ConsoleArgument.isValidSavegameName(""), "an empty name is refused")
        check(!ConsoleArgument.isValidSavegameName("my save"),
              "a space is refused -- it would split the token and save nothing")
        check(!ConsoleArgument.isValidSavegameName("a;quit"),
              "a semicolon is refused -- it would end the command and start another")
        check(!ConsoleArgument.isValidSavegameName("a\nquit"),
              "a newline is refused for the same reason")
        check(!ConsoleArgument.isValidSavegameName("../config"),
              "no dots and no slashes, so the name cannot leave the game directory")
        check(ConsoleArgument.sanitizedSavegameName("my save; quit") == "mysavequit",
              "sanitizing strips exactly the characters that change the meaning")
        check(ConsoleArgument.sanitizedSavegameName(String(repeating: "a", count: 99)).count
                == ConsoleArgument.savegameNameLimit,
              "the name is capped")

        check(ConsoleArgument.isValidAddress("192.168.1.9"), "a dotted quad is a valid address")
        check(ConsoleArgument.isValidAddress("192.168.1.9:26000"), "a port is allowed")
        check(ConsoleArgument.isValidAddress("quake.local"), "a hostname is allowed")
        check(ConsoleArgument.isValidAddress("local"),
              "the loopback host `slist` reports is itself connectable")
        check(!ConsoleArgument.isValidAddress(""), "an empty address is refused")
        check(!ConsoleArgument.isValidAddress("host; quit"),
              "a semicolon in an address is refused")
        check(!ConsoleArgument.isValidAddress("host name"), "a space in an address is refused")
    }
}
