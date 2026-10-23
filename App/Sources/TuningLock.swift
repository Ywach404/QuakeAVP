// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  TuningLock.swift
//
//  The @Observable shell around Tuning.Logger: whether the panel's tuned
//  values may be moved at all, and the timer that gets a change reported.
//  The pure half -- what counts as a change, what the line says -- is in
//  TuningLockPolicy.swift, which the host harness compiles alone.
//
//  WHY A LOCK. Every control in the panel is reached by looking at it and
//  pinching. Scrolling the panel is also a pinch and a drag, so the gesture
//  that moves the view and the gesture that moves a slider are the same
//  gesture, and the only thing separating them is whether your gaze landed
//  on a control. Hugging the window's edge to avoid the controls is what
//  one does, and missing is what happens.
//
//  WHAT IT COVERS: anything adjusted by DRAGGING. That is the rule, and it
//  comes from the mechanism rather than from tidiness -- a slider or a gyro
//  disc moves continuously under exactly the gesture used to scroll, while a
//  button, a toggle or a segmented picker needs a discrete press on a
//  specific target. So the drag-driven controls go quiet and everything else
//  stays live: Resume, Save, Load, the map cards, the tab bar and the
//  console all work with the lock on, which is what makes leaving it on all
//  the time practical.
//
//  LOCKED AT EVERY LAUNCH, AND NOT PERSISTED. A lock remembered in the
//  wrong state is worse than none, because it is remembered as UNLOCKED on
//  the one day you forgot you left it there. Tuning is one focused session
//  and then set-and-forget, so the cost of unlocking again is a single
//  press. It is held here rather than in a @State on the view so that
//  dismissing and re-summoning the window mid-session does not re-lock the
//  panel under A.'s hands -- the window is summoned often, the lock should
//  change only when asked.
//

import Foundation
import Observation
import QuartzCore
import SwiftUI

@MainActor
@Observable
final class TuningLock {

    /// One lock for the app, outliving any one window.
    static let shared = TuningLock()

    /// Locked. See the file comment: this default is the feature.
    var isLocked = true {
        didSet {
            // Re-locking mid-gesture would otherwise strand whatever was
            // pending, and a dropped line is a silent edit.
            guard isLocked != oldValue, isLocked else { return }
            emit(logger.drain())
        }
    }

    @ObservationIgnored private var logger = Tuning.Logger()
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// One setter call on a tuned control. `name` is what the row is called
    /// on screen, qualified by its tab -- that is the handle A. has for it
    /// when a line turns up, rather than the cvar it may or may not map to.
    func note(_ name: String, from: Float, to: Float) {
        logger.note(name, from: from, to: to, at: CACurrentMediaTime())
        scheduleFlush()
    }

    /// Report anything still pending. For the window going away: a change
    /// that has not yet gone quiet would otherwise never be reported.
    func drainNow() {
        emit(logger.drain())
    }

    /// One task at a time, living only as long as something is pending.
    ///
    /// The clock is `CACurrentMediaTime`, which is monotonic. Wall time is
    /// not: a clock correction mid-drag would either flush a gesture that is
    /// still moving or strand one that has stopped.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            while let self, !self.logger.isEmpty {
                try? await Task.sleep(for: .seconds(Tuning.quietPeriod))
                self.emit(self.logger.flush(at: CACurrentMediaTime()))
            }
            self?.flushTask = nil
        }
    }

    /// To the in-headset console as well as stdout. print() alone is
    /// invisible on a detached launch, which is the only way audio and the
    /// immersive space work -- so a log that only printed would be a log
    /// that is never read in the one place it matters.
    private func emit(_ lines: [String]) {
        for line in lines { HandDebug.shared.log(line) }
    }
}

extension View {

    /// Marks a control that HOLDS a tuned value and is moved by dragging, so
    /// the lock can take it out of reach. Applied to the whole row rather
    /// than the slider alone, so the label and the readout dim with it and
    /// the row reads as held rather than as broken.
    ///
    /// `dims: true` for a control drawn by hand. `.disabled()` greys a
    /// `Slider` for free because the control knows its own disabled
    /// appearance, but it cannot know how to grey a `ZStack` of `Shape`s --
    /// and a dial that refuses to turn without looking as though it would is
    /// a bug report waiting to happen.
    @MainActor
    func tuningLocked(dims: Bool = false) -> some View {
        let locked = TuningLock.shared.isLocked
        return self.disabled(locked).opacity(dims && locked ? 0.4 : 1)
    }
}
