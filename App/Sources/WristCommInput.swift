// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WristCommInput.swift
//
//  The wrist communicator's touch->fire loop (plan Task 5): reads the
//  published fingertip positions (`FingerTips`) and comm geometry
//  (`WristCommGeometry`), hit-tests them against each revealed side's grid
//  with the PURE `WristComm.touchedCell`/`updateTouch` (WristCommMath.swift),
//  and fires a cell's bound command through `WristCommStore.shared.fire` on
//  the main actor -- the only main-actor touch in this file, and the only
//  place this loop calls no `QC_*` at all (everything else comes off the
//  published snapshots). Clones `HudEditorInput`'s own loop shape, since
//  this is the same "thin plumbing around pure math" problem: read
//  cross-loop snapshots at this loop's own cadence, hop to the main actor
//  only for the side effect.
//
//  Review Focus: while the HUD live editor is open
//  (`HudEditor.Session.renderSnapshot().active`), this loop resets every
//  side's touch state to a fresh, unseeded `WristComm.TouchState` and skips
//  the tick entirely -- a fingertip dragging a tile across the wrist must
//  never also fire a communicator cell underneath it. That reset alone does
//  NOT prevent a fire on the close transition: `WristComm.updateTouch`'s
//  own seeding step is what does, by absorbing whatever the fingers are
//  already doing on a fresh state's first armed tick instead of reading it
//  as a rising edge against `wasIn == nil`. The exact same reset-then-
//  reseed happens on the idle->active transition (nothing revealed) and at
//  startup -- one mechanism covers all three, because every reset path
//  here constructs the same fresh `TouchState()`.
//

import Foundation
import QuartzCore
import simd

final class WristCommInput: @unchecked Sendable {
    static let shared = WristCommInput()

    private var runTask: Task<Void, Never>?

    /// One `TouchState` per published side (0 = off wrist, 1 = gun wrist) --
    /// the same index convention `WristCommGeometry.Snapshot.sides` and
    /// `WristCommStore.Snapshot.sides` use. Touched only from this
    /// instance's own single sequential loop task, never concurrently.
    private var states: [WristComm.TouchState] = [WristComm.TouchState(), WristComm.TouchState()]

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        let budget = 1.0 / 90.0
        while !Task.isCancelled {
            if Self.anySideQualifies() {
                // Rate-compensate: sleep only the REMAINDER of the 90 Hz
                // budget after the tick's own work, so the loop holds a
                // true 90 Hz instead of 90 Hz PLUS the tick duration --
                // the same reasoning `HudEditorInput.run` documents for its
                // own loop.
                let start = CACurrentMediaTime()
                tick()
                let remaining = budget - (CACurrentMediaTime() - start)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            } else {
                // Nothing revealed anywhere: poll slowly rather than spin,
                // and drop any stale per-side touch state so a later reveal
                // starts clean (no phantom "was already in cell 4" edge).
                states = [WristComm.TouchState(), WristComm.TouchState()]
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Idle gate: nothing to hit-test unless at least one published side is
    /// both enabled and revealed past the fire floor -- matches the reveal
    /// state the render thread is actually drawing, not just "enabled".
    /// `WristComm.sideQualifies` is the one shared predicate; see its doc.
    private static func anySideQualifies() -> Bool {
        WristCommGeometry.shared.snapshot().sides.contains {
            WristComm.sideQualifies(enabled: $0.enabled, opacity: $0.opacity)
        }
    }

    private func tick() {
        // No cheat fires while arranging tiles (Review Focus above):
        // HudEditorInput's own grab loop is reading these same fingertips
        // this tick, and a drag across the wrist must not also trigger a
        // comm cell.
        if HudEditor.Session.renderSnapshot().active {
            states = [WristComm.TouchState(), WristComm.TouchState()]
            return
        }

        let geometry = WristCommGeometry.shared.snapshot()
        let tips = FingerTips.shared.snapshot()
        let now = CACurrentMediaTime()

        for s in 0..<geometry.sides.count {
            let side = geometry.sides[s]
            guard side.enabled else { continue }

            let revealed = side.opacity >= WristComm.fireRevealFloor
            let touched = [tips.left, tips.right].map {
                $0.flatMap { WristComm.touchedCell($0, commOrigin: side.commOrigin, frame: side.frame) }
            }

            let state = s < states.count ? states[s] : WristComm.TouchState()
            let result = WristComm.updateTouch(state: state, touched: touched, now: now, revealed: revealed)
            if s < states.count {
                states[s] = result.state
            } else {
                states.append(result.state)
            }

            guard let cell = result.fire else { continue }

            // The command is read from the SAME cached snapshot `fire`
            // itself will re-read on the main actor -- this is just the
            // pre-check that lets an unbound cell's touch skip the actor
            // hop entirely, not a second source of truth.
            let storeSides = WristCommStore.snapshot().sides
            guard s < storeSides.count, cell >= 0, cell < storeSides[s].commands.count else { continue }
            let command = storeSides[s].commands[cell]
            guard WristComm.shouldFire(command) else { continue }

            // Tell the renderer which key just went down, BEFORE the actor
            // hop that actually runs the command -- this is the press
            // flash's only source, and `now` is the tick that saw the
            // fingertip cross the plane rather than whenever the main actor
            // next gets a slot. Only fires that pass every gate above are
            // published, so a touch on an unbound cell flashes nothing.
            WristCommFeedback.shared.noteFire(side: s, cell: cell, at: now)

            Task { @MainActor in WristCommStore.shared.fire(side: s, cell: cell) }
        }
    }
}
