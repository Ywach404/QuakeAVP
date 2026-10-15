// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  ConsoleArgument.swift
//
//  What the window is allowed to paste into a console command line.
//
//  Everything the window sends reaches the engine through Cbuf_AddText, which
//  is a command BUFFER, not a function call: Cbuf_Execute splits the text on
//  newlines and on unquoted semicolons, then Cmd_TokenizeString splits what is
//  left on whitespace. So a user-typed savegame name or server address is not
//  an argument until the engine has finished parsing it, and three ordinary
//  characters change its meaning:
//
//    space      -- splits the token, so `save my game` arrives as three
//                  arguments and Host_Savegame_f's `Cmd_Argc() != 2` prints
//                  its usage line and does nothing. Silent, from the player's
//                  side: a Save button that appears to do nothing at all.
//    semicolon  -- ends the command. Everything after it is a NEW command.
//    newline    -- the same, and send() appends one itself.
//
//  Quoting would handle the first and the engine strips quotes, but then the
//  file on disk is named with whatever was quoted and `load` has to re-quote
//  it identically forever. A whitelist is the smaller promise: these are
//  filenames and host addresses, and neither needs a space.
//
//  Pure Foundation, no engine import -- tools/check-swift-session.sh compiles
//  this and SaveGames.swift alone against their host test.
//

import Foundation

enum ConsoleArgument {

    /// Letters, digits, `-` and `_`. No dot, so Host_Savegame_f's `..` check
    /// can never be reached, and no `/` or `\`, so the name cannot climb out
    /// of the game directory. COM_AddExtension appends the `.sav`.
    private static let savegameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Host addresses: a dotted quad or a hostname, optionally `:port`. The
    /// dot is allowed here because this never becomes a path -- NET_Connect
    /// hands it to the datagram driver's address parser.
    private static let addressAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:[]")

    /// Quake's own savegame names are short (`s0`...`s11`, `quick`); the
    /// engine's limit is MAX_OSPATH on the whole path, so this is a UI cap
    /// that keeps a row readable rather than an engine constraint.
    static let savegameNameLimit = 24

    /// Trim, drop anything outside the whitelist, and cap the length. Used as
    /// the text field's own filter, so the player sees what will be sent
    /// instead of typing something that is quietly rewritten on submit.
    static func sanitizedSavegameName(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { savegameAllowed.contains($0) }
            .prefix(savegameNameLimit))
    }

    /// True when `save <name>` / `load <name>` would reach the engine as two
    /// arguments with the name intact.
    static func isValidSavegameName(_ name: String) -> Bool {
        !name.isEmpty && sanitizedSavegameName(name) == name
    }

    static func sanitizedAddress(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { addressAllowed.contains($0) })
    }

    /// True when `connect <address>` would reach the engine intact. The
    /// address is not validated as an address -- that is NET_Connect's job,
    /// and it prints its own failure to the console.
    static func isValidAddress(_ address: String) -> Bool {
        !address.isEmpty && sanitizedAddress(address) == address
    }
}
