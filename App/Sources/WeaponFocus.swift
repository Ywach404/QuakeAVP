// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WeaponFocus.swift
//
//  The held weapon, as an observable fact the window UI can react to.
//
//  WeaponTrim stores the per-weapon rig and is written from the render
//  threads, so it is a plain lock-guarded Sendable, not @Observable. The
//  Weapon tab needs to re-read its sliders the instant the held weapon
//  changes, and for that it needs a main-actor observable signal. This is that
//  signal -- updated by WeaponTrim.frame via a hop to the main actor, the same
//  render-thread-to-UI pattern RendererCoordinator uses.
//

import Foundation

@MainActor
@Observable
final class WeaponFocus {
    static let shared = WeaponFocus()

    /// The held weapon as the frame packet carries it: its IDENTITY plus one,
    /// 0 for an empty hand and before the first packet. Not an IT_* bit any
    /// more, because one item bit means different weapons in different games.
    ///
    /// Only ever compared for CHANGE, never decoded: the Weapon tab watches it
    /// with .onChange and re-syncs its sliders from WeaponTrim, which holds the
    /// identity itself. Decode it with WeaponTrimMigration.identity(fromPublished:)
    /// rather than subtracting one here, if that ever becomes necessary.
    private(set) var weapon: UInt32 = 0

    private init() {}

    func set(_ w: UInt32) { weapon = w }
}
