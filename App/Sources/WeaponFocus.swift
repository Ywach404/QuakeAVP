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

    /// IT_* bit of the weapon currently held, 0 before the first packet.
    /// The Weapon tab watches this with .onChange and re-syncs its sliders.
    private(set) var weapon: UInt32 = 0

    private init() {}

    func set(_ w: UInt32) { weapon = w }
}
