// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  SaveGames.swift
//
//  Reading Quake's own `.sav` files, so the window's slot list shows what the
//  engine wrote rather than a parallel record of its own.
//
//  A savegame is plain text. Host_Savegame_f (engine/host_cmd.c) writes the
//  version on the first line and a fixed-width comment on the second, then
//  dumps every edict -- megabytes of them. Everything here reads the first two
//  lines and stops.
//
//  The comment is built by Host_SavegameComment: SAVEGAME_COMMENT_LENGTH (39)
//  characters, the level name in the first 22, "kills:%3i/%3i" at offset 22,
//  and then every space replaced with an underscore "to make stdio happy".
//  menu.c's M_ScanSaves undoes that substitution for display and so does
//  `displayText` below -- the same unconditional swap, because the engine's
//  was unconditional too. A level name that genuinely contained an underscore
//  came back as a space in the engine menu and comes back as one here.
//
//  No Observation, no UIKit, no engine import: this file is the pure half and
//  tools/check-swift-session.sh compiles it alone against its host test.
//

import Foundation

/// Quake's four skill levels, which the engine clamps to 0...3 when a level
/// spawns (`engine/sv_main.c:1489-1492`). The raw values ARE the `skill` cvar's
/// numbers, so a `Difficulty` can be sent to the console as-is.
enum Difficulty: Int, CaseIterable, Hashable, Sendable {
    case easy = 0
    case normal = 1
    case hard = 2
    case nightmare = 3

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        case .nightmare: return "Nightmare"
        }
    }

    /// Read a savegame's `current_skill` line. `Host_Savegame_f` writes it with
    /// `fprintf("%d")`, but a float-formatted line is what a mod or a hand edit
    /// produces and it means the same thing, so both are accepted.
    ///
    /// Out of range is REFUSED rather than clamped. Clamping here would label a
    /// save with a difficulty it was not played on, which is worse than showing
    /// no pip at all -- the display can say nothing, but it must not lie.
    static func from(skillLine: String) -> Difficulty? {
        let trimmed = skillLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let d = Double(trimmed),
              d == d.rounded(), let i = Int(exactly: d.rounded())
        else { return nil }
        return Difficulty(rawValue: i)
    }
}

/// Clamp a stored skill into the engine's range. The defaults domain is not
/// trustworthy input -- it survives downgrades and can be written by hand -- so
/// this is applied on read as well as on write, and lives here so it has one
/// definition and a host test.
func clampSkill(_ value: Int) -> Int {
    min(max(value, 0), 3)
}

/// One `.sav` in the current game directory, as the slot list shows it.
struct SaveGameSlot: Identifiable, Hashable {
    /// The savegame name without the extension -- exactly the argument
    /// `save`/`load` take ("s0", "quick").
    let name: String
    let url: URL
    /// The file's own SAVEGAME_VERSION line.
    let version: Int
    /// The raw comment line, underscores and all, as written.
    let comment: String
    /// The skill the save was written on, from its own `current_skill` line.
    /// nil when the file is too short or the line is unreadable: the slot
    /// still lists, it just cannot say which difficulty it was.
    let difficulty: Difficulty?
    let modified: Date

    var id: String { name }

    /// The comment as the engine menu showed it: underscores back to spaces,
    /// trailing padding dropped.
    var displayText: String { SaveGameHeader.displayText(for: comment) }

    /// A savegame the running engine would refuse. `load` calls Host_Error on
    /// a version mismatch, which drops to the console -- worth saying before
    /// the tap, not after.
    var isLoadable: Bool { version == SaveGameHeader.version }

    /// Whether `load <name>` can even be issued. A `.sav` dropped in over the
    /// Files app can be called anything, including things with a space or a
    /// semicolon in them, and those cannot survive Cbuf's tokenizer -- see
    /// ConsoleArgument. Separate from `isLoadable`, which is about the file's
    /// version: this one is about its NAME, and a button that is enabled and
    /// then silently does nothing is worse than one that explains itself.
    var isAddressable: Bool { ConsoleArgument.isValidSavegameName(name) }
}

/// Parsing and listing. Pure functions over bytes and paths.
enum SaveGameHeader {

    /// SAVEGAME_VERSION, host_cmd.c. Bumping this in the engine without
    /// bumping it here would show old saves as loadable.
    static let version = 5
    /// SAVEGAME_COMMENT_LENGTH, quakedef.h.
    static let commentLength = 39
    /// The quick-save slots the engine menu offers (menu.c's MAX_SAVEGAMES
    /// names them s0...s11). Mirrored so the window's quick row and the
    /// console's `load s3` mean the same file.
    static let quickSlotNames = (0..<12).map { "s\($0)" }

    /// Enough bytes for the version line and the full comment line with room
    /// to spare; a savegame's third line is already spawn parms.
    // 19 lines: a version, a 39-char comment, sixteen "%f" spawn parms at
    // nine bytes each, then the skill line -- about 190 bytes, which 256
    // covered with no margin for a longer comment.
    private static let headerBytes = 512

    /// Underscores back to spaces, trailing padding trimmed -- M_ScanSaves'
    /// display rule.
    static func displayText(for comment: String) -> String {
        comment.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The version and comment from a savegame's first two lines, or nil if
    /// the file does not start like one.
    ///
    /// Deliberately lenient about the comment and strict about the version:
    /// the version is what decides whether `load` will work, while the
    /// comment is cosmetic and a mod could write anything into it.
    static func parse(_ header: String) -> (version: Int, comment: String,
                                            difficulty: Difficulty?)? {
        // `\n` only: Host_Savegame_f writes with fprintf to a text-mode FILE,
        // and nothing in the format uses a bare CR.
        //
        // Split far enough to reach current_skill. The layout is version,
        // comment, NUM_SPAWN_PARMS (16, engine/server.h:86) floats, skill, map
        // name, time -- so skill is line 19, element 18. The old limit of 2
        // stopped at the comment.
        let lines = header.split(separator: "\n", maxSplits: skillLineIndex + 1,
                                 omittingEmptySubsequences: false)
        guard lines.count >= 2,
              let version = Int(lines[0].trimmingCharacters(in: .whitespaces))
        else { return nil }
        // A short or malformed file still parses: it lists with no pip rather
        // than vanishing from the browser.
        let difficulty = lines.count > skillLineIndex
            ? Difficulty.from(skillLine: String(lines[skillLineIndex]))
            : nil
        return (version, String(lines[1]), difficulty)
    }

    /// Zero-based index of `current_skill`: one version line, one comment line,
    /// then NUM_SPAWN_PARMS of them.
    static let skillLineIndex = 2 + 16

    /// Read just the header off disk. Opens, reads one small chunk, closes --
    /// a `.sav` is every edict in the level and must never be slurped whole
    /// to show a row in a list.
    static func readHeader(of url: URL) -> (version: Int, comment: String,
                                            difficulty: Difficulty?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerBytes), !data.isEmpty
        else { return nil }
        // Strip bit 7 before decoding -- upstream's own "dequake". A level
        // name comes from worldspawn.message, and plenty of maps write it in
        // Quake's high-bit charset, where 0x80...0xFF are the gold-coloured
        // twins of 0x00...0x7F. The engine menu drew those as glyphs; decoded
        // as UTF-8 they are invalid bytes and the row would read as a run of
        // replacement characters. Everything else in these two lines is ASCII
        // digits, the comment's own text and a newline, so the mask costs
        // nothing there.
        let ascii = Data(data.map { $0 & 0x7f })
        // Still lossy-decode rather than returning nil: a slot with an odd
        // name should be loadable, not invisible.
        let text = String(data: ascii, encoding: .utf8)
            ?? String(decoding: ascii, as: UTF8.self)
        return parse(text)
    }

    /// Every `.sav` in one game directory, newest first.
    ///
    /// The directory is the engine's live `com_gamedir` and nothing else: a
    /// save written under `-game hipnotic` is not listed while id1 is loaded,
    /// which is exactly what `load` would do with it. No cleverness about
    /// other gamedirs -- the engine has none either.
    static func list(in directory: URL) -> [SaveGameSlot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var slots: [SaveGameSlot] = []
        for url in entries where url.pathExtension.lowercased() == "sav" {
            guard let header = readHeader(of: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            slots.append(SaveGameSlot(name: url.deletingPathExtension().lastPathComponent,
                                      url: url,
                                      version: header.version,
                                      comment: header.comment,
                                      difficulty: header.difficulty,
                                      modified: modified))
        }
        slots.sort { $0.modified > $1.modified }
        return slots
    }
}
