// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  GestureDwell.swift
//
//  "Held this pose long enough" as a value type, so the summon's timing can be
//  tested without ARKit. Pure: the caller passes the clock in.
//
//  Two properties that are easy to get wrong by hand and have bitten this
//  codebase before (see the flick snap-turn's pulse): ONE fire per hold, and a
//  flicker must not accumulate toward a trigger.
//

struct GestureDwell {

    /// Seconds of continuous hold before the gesture fires.
    let dwell: Double
    /// Seconds after a fire during which a fresh hold is swallowed, so one
    /// enthusiastic sign can't stack two windows.
    let cooldown: Double

    private var heldSince: Double?
    private var firedThisHold = false
    private var lastFired: Double?

    init(dwell: Double, cooldown: Double) {
        self.dwell = dwell
        self.cooldown = cooldown
    }

    /// Feed one sample. Returns true on the single frame the gesture fires.
    mutating func update(active: Bool, now: Double) -> Bool {
        guard active else {
            heldSince = nil
            firedThisHold = false
            return false
        }
        guard let since = heldSince else {
            heldSince = now                     // the hold starts here, not earlier
            return false
        }
        guard !firedThisHold, now - since >= dwell else { return false }
        if let last = lastFired, now - last < cooldown {
            // Inside the cooldown. Consume the hold anyway, so that letting go
            // and holding again doesn't leave a fire queued to land the instant
            // the cooldown lapses.
            firedThisHold = true
            return false
        }
        firedThisHold = true
        lastFired = now
        return true
    }
}
