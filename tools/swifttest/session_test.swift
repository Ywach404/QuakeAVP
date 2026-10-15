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
        runSlotListTests()
        runConsoleArgumentTests()
        print("PASSED")
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
