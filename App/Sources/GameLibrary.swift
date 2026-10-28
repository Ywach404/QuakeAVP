// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  GameLibrary.swift
//
//  Reads the installed games off disk. The rules it applies are in
//  GameDirectories.swift, which is pure and host-tested; this file is only
//  the IO, including the one piece that needs a format reader: a pack's maps
//  usually live inside a `.pak`, so listing them means parsing the pak's
//  directory.
//
//  A pak's directory is twelve bytes of header and a flat table: "PACK", the
//  table's offset and its length, then 64-byte entries of a 56-byte
//  NUL-padded name and two offsets. Only the names are read here, never the
//  file bodies, so listing a 468 MB pack costs one seek and a few kilobytes.
//

import Foundation

enum GameLibrary {

    /// Installed game directories across basedir and userdir, base first.
    static func installed(base: URL, user: URL) -> [String] {
        func scan(_ root: URL) -> [String] {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
            return entries.compactMap { url -> String? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return nil }
                let inner = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                guard GameDirectories.isGameDirectory(contents: inner) else { return nil }
                return url.lastPathComponent
            }
        }
        var names = GameDirectories.merge(base: scan(base), user: scan(user))
        // id1 is offered even when its paks have not been dropped in yet, so
        // the picker never comes up empty and the way back is always there.
        if !names.contains(where: { $0.lowercased() == GameDirectories.base }) {
            names.insert(GameDirectories.base, at: 0)
        }
        return names
    }

    /// Every map a game directory can load: loose `maps/*.bsp` plus the
    /// contents of every `.pak` beside them.
    static func maps(in directory: URL) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        let loose = directory.appendingPathComponent("maps", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: loose.path)) ?? [] {
            paths.append("maps/\(name)")
        }
        for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        where name.lowercased().hasSuffix(".pak") {
            paths.append(contentsOf:
                pakEntries(at: directory.appendingPathComponent(name)))
        }
        return GameDirectories.mapNames(fromPaths: paths)
    }

    /// The names in a pak's directory table. Empty for anything that is not
    /// a pak, which is the same answer a missing file gives: a malformed
    /// pack should leave the picker short an entry, never crash the window.
    private static func pakEntries(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4).elementsEqual("PACK".utf8)
        else { return [] }

        let dirofs = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
        let dirlen = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int32.self) }
        guard dirofs > 0, dirlen > 0, dirlen % 64 == 0,
              dirlen < 1 << 24               // a sane table, not a corrupt length
        else { return [] }

        guard (try? handle.seek(toOffset: UInt64(dirofs))) != nil,
              let table = try? handle.read(upToCount: Int(dirlen)),
              table.count == Int(dirlen)
        else { return [] }

        var out: [String] = []
        out.reserveCapacity(Int(dirlen) / 64)
        for start in stride(from: 0, to: table.count, by: 64) {
            let raw = table[table.index(table.startIndex, offsetBy: start)...].prefix(56)
            let name = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            if !name.isEmpty { out.append(name) }
        }
        return out
    }
}
