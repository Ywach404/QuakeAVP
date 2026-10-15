// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  HudOverlay.swift
//
//  The export HUD: Quake's status-bar numbers laid out as conchars glyph
//  quads in PIXEL space, drawn once per output frame after the motion-blur
//  resolve so the text stays sharp. Same 9-float vertex the bridge's
//  world-space text uses (xyz, uv, rgba), so it rides the existing text
//  pipeline with an orthographic matrix.
//

import Foundation
import simd

/// cl.stats as the packet carries them.
struct HudStats: Equatable {
    var health: Int32 = 0
    var armor: Int32 = 0
    var ammo: Int32 = 0
    var shells: Int32 = 0
    var nails: Int32 = 0
    var rockets: Int32 = 0
    var cells: Int32 = 0
    var activeWeapon: Int32 = 0
    var kills: Int32 = 0
    var totalMonsters: Int32 = 0
    var secrets: Int32 = 0
    var totalSecrets: Int32 = 0

    init() {}

    /// From the packet's 16-int stats block (STAT_* order).
    init(stats: [Int32]) {
        guard stats.count >= 15 else { return }
        health = stats[0]; ammo = stats[3]; armor = stats[4]
        shells = stats[6]; nails = stats[7]; rockets = stats[8]; cells = stats[9]
        activeWeapon = stats[10]; totalSecrets = stats[11]; totalMonsters = stats[12]
        secrets = stats[13]; kills = stats[14]
    }
}

enum HudOverlay {

    static let white = SIMD4<Float>(1, 1, 1, 1)
    static let gold = SIMD4<Float>(1, 0.82, 0.3, 1)
    static let dim = SIMD4<Float>(0.6, 0.6, 0.6, 1)

    /// IT_* bit of the held weapon.
    static func weaponName(_ bit: Int32) -> String {
        switch bit {
        case 4096: return "AXE"
        case 1: return "SHOTGUN"
        case 2: return "SUPER SHOTGUN"
        case 4: return "NAILGUN"
        case 8: return "SUPER NAILGUN"
        case 16: return "GRENADE LAUNCHER"
        case 32: return "ROCKET LAUNCHER"
        case 64: return "THUNDERBOLT"
        default: return ""
        }
    }

    /// Which ammo counter the held weapon draws from (IT_* bit of that ammo
    /// group: 256 shells, 512 nails, 1024 rockets, 2048 cells).
    static func activeAmmo(_ weapon: Int32) -> Int32 {
        switch weapon {
        case 1, 2: return 256
        case 4, 8: return 512
        case 16, 32: return 1024
        case 64: return 2048
        default: return 0
        }
    }

    /// Append one string as glyph quads. `x`,`y` is the top-left in pixels,
    /// `size` the glyph edge in pixels. Returns the x after the last glyph.
    @discardableResult
    static func glyphs(_ text: String, x: Float, y: Float, size: Float,
                       color: SIMD4<Float>, into verts: inout [Float]) -> Float {
        var cx = x
        for scalar in text.unicodeScalars {
            let c = Int(scalar.value) & 255
            if c != 32 {
                let u0 = Float(c & 15) / 16, v0 = Float(c >> 4) / 16
                let u1 = u0 + 1 / 16, v1 = v0 + 1 / 16
                let x0 = cx, x1 = cx + size, y0 = y, y1 = y + size
                func v(_ px: Float, _ py: Float, _ u: Float, _ vv: Float) {
                    verts.append(contentsOf: [px, py, 0, u, vv, color.x, color.y, color.z, color.w])
                }
                v(x0, y0, u0, v0); v(x1, y0, u1, v0); v(x0, y1, u0, v1)
                v(x1, y0, u1, v0); v(x1, y1, u1, v1); v(x0, y1, u0, v1)
            }
            cx += size
        }
        return cx
    }

    /// Two lines along the bottom: health/armor/ammo, then weapon and tallies.
    static func build(stats s: HudStats, width: Int, height: Int) -> [Float] {
        var verts: [Float] = []
        let size = (8 * Float(height) / 360).rounded()   // 24 px at 1080p
        let margin = size
        let gap = size * 3
        let line1 = Float(height) - margin - size
        let line2 = line1 - size * 1.5

        var x = margin
        func item(_ label: String, _ value: String, valueColor: SIMD4<Float>, line: Float) {
            x = glyphs(label + " ", x: x, y: line, size: size, color: white, into: &verts)
            x = glyphs(value, x: x, y: line, size: size, color: valueColor, into: &verts)
            x += gap
        }
        let active = activeAmmo(s.activeWeapon)
        item("HEALTH", "\(s.health)", valueColor: s.health <= 25 ? SIMD4(1, 0.3, 0.2, 1) : gold, line: line1)
        item("ARMOR", "\(s.armor)", valueColor: gold, line: line1)
        item("SHELLS", "\(s.shells)", valueColor: active == 256 ? gold : dim, line: line1)
        item("NAILS", "\(s.nails)", valueColor: active == 512 ? gold : dim, line: line1)
        item("ROCKETS", "\(s.rockets)", valueColor: active == 1024 ? gold : dim, line: line1)
        item("CELLS", "\(s.cells)", valueColor: active == 2048 ? gold : dim, line: line1)

        x = margin
        let weapon = weaponName(s.activeWeapon)
        if !weapon.isEmpty {
            x = glyphs(weapon, x: x, y: line2, size: size, color: gold, into: &verts)
            x += gap
        }
        item("KILLS", "\(s.kills)/\(s.totalMonsters)", valueColor: gold, line: line2)
        item("SECRETS", "\(s.secrets)/\(s.totalSecrets)", valueColor: gold, line: line2)
        return verts
    }
}
