// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  TuningLockPolicy.swift
//
//  The pure half of the panel's tuning lock: what a change to a tuned value
//  is, and what it says in the console when it happens.
//
//  WHY THERE IS A LOG AT ALL. The lock is the fix; this is the fallback for
//  the lock being off, which is the state it has to be in to tune anything.
//  A value nudged by a stray pinch changes the game and says nothing, and
//  what that costs is not the setting -- it is the DEBUGGING. A front gun
//  trim moved by accident, unnoticed, got blamed on three successive builds
//  before anyone looked at the value itself. A lock can be left off; a line
//  in the console cannot fail silently.
//
//  ONE LINE PER GESTURE, NOT PER CALL. A slider's binding setter fires
//  dozens of times across a single drag, and a line each would be a log
//  nobody reads -- which is the same as no log. So changes coalesce per
//  control: earliest `from`, latest `to`, emitted once the control has been
//  still for `quietPeriod`. That is also why this is a timer and not
//  `onEditingChanged`: the gyro discs are a raw DragGesture with no such
//  hook, and one mechanism that does not care which control it is beats two
//  that each only handle half of them.
//
//  No SwiftUI, no Observation, no engine: tools/check-swift-session.sh
//  compiles this alone against its test. The @Observable shell that owns
//  the lock flag and drives the flush is TuningLock.swift.
//

import Foundation

enum Tuning {

    /// How still a control must be before its change is reported. Long
    /// enough to span the gaps in a slow drag -- a careful adjustment
    /// pauses while you look at the number -- and short enough that the
    /// line arrives while you still remember doing it.
    static let quietPeriod: TimeInterval = 0.75

    /// Below this, a value did not really move. Sliders are continuous and
    /// a gaze that drifts a pixel should not be an event; what matters is
    /// whether the value is DIFFERENT now.
    ///
    /// Exactly half the resolution the line is PRINTED at, which ties the
    /// two together deliberately. At 1e-4 against a `%.3f` readout a real
    /// change could round to the same three decimals on both sides and emit
    /// `0.000 -> 0.000` -- a line that reports a change while showing none,
    /// which teaches you to distrust the log. Anything reported now differs
    /// in the digits shown.
    static let changeEpsilon: Float = 5e-4

    /// Coalesces setter calls into one report per gesture.
    ///
    /// A value type with no clock of its own: every entry point takes the
    /// time, so the test drives it with numbers rather than by waiting.
    struct Logger {

        private struct Pending {
            /// Where the gesture STARTED. Never overwritten, which is what
            /// makes the line describe the drag rather than its last two
            /// samples.
            let from: Float
            var to: Float
            var last: TimeInterval
        }

        private var pending: [String: Pending] = [:]

        /// One setter call: the value before this change and after it.
        ///
        /// Taking both ends rather than just the new value is deliberate.
        /// The first call of a gesture already carries the changed value, so
        /// a logger that saw only `to` could not know where the drag began
        /// -- it would report the last sample pair and call it the gesture.
        /// At the top of a binding's `set:` the old value is still in hand,
        /// so the caller can simply pass it.
        mutating func note(_ name: String, from: Float, to: Float, at now: TimeInterval) {
            // `to` must be finite: that is the value being stored, and a
            // NaN reaching a gyro disc's accumulator would persist and print
            // forever. `from` is only the value being LEFT, and refusing on
            // it would lose the one gesture that matters most -- dragging a
            // control whose value has already gone bad back to a real number
            // would be the silent edit, with the first note of the drag
            // thrown away and the rest opening a pending entry from
            // mid-gesture.
            guard to.isFinite else { return }
            if var entry = pending[name] {
                entry.to = to
                entry.last = now
                pending[name] = entry
            } else {
                pending[name] = Pending(from: from, to: to, last: now)
            }
        }

        /// Report every control that has gone quiet since the last call.
        ///
        /// Ordered oldest-first so a flurry of edits reads in the order they
        /// were made, with the name breaking ties so the output is stable.
        mutating func flush(at now: TimeInterval) -> [String] {
            let ready = pending
                .filter { now - $0.value.last >= Tuning.quietPeriod }
                .sorted { ($0.value.last, $0.key) < ($1.value.last, $1.key) }
            for (name, _) in ready { pending.removeValue(forKey: name) }
            return ready.compactMap { Self.line($0.key, from: $0.value.from, to: $0.value.to) }
        }

        /// Report everything outstanding, quiet period or not.
        ///
        /// For the lock being re-engaged mid-gesture: the change is already
        /// made, so waiting out a quiet period that can no longer end in
        /// another move would just delay the line, and dropping it would be
        /// a silent edit -- the thing this exists to prevent. The window
        /// closing needs nothing, because the flush task belongs to the
        /// app-lived shell rather than to any view.
        mutating func drain() -> [String] {
            let all = pending.sorted { ($0.value.last, $0.key) < ($1.value.last, $1.key) }
            pending.removeAll()
            return all.compactMap { Self.line($0.key, from: $0.value.from, to: $0.value.to) }
        }

        /// Whether anything is waiting, so the shell knows to keep its timer
        /// running rather than polling an empty logger forever.
        var isEmpty: Bool { pending.isEmpty }

        /// The line, or nil when the value ended up where it started.
        ///
        /// Dropping the no-op is what keeps the log worth reading: every
        /// line in it is a value that is actually different from what it was
        /// before you touched it.
        static func line(_ name: String, from: Float, to: Float) -> String? {
            guard to.isFinite else { return nil }
            // Coming back from a bad value is always worth reporting, and
            // there is no meaningful distance from NaN to compare.
            guard from.isFinite else { return "[tune] \(name) invalid -> \(number(to))" }
            guard abs(to - from) >= Tuning.changeEpsilon else { return nil }
            return "[tune] \(name) \(number(from)) -> \(number(to))"
        }

        /// Three decimals, and never "-0.000": `%f` prints the sign bit even
        /// though -0.0 == 0.0, so a dial resting at zero would show a minus
        /// depending on which side it last came from. commPlaceRow
        /// normalises its on-screen readout for the same reason.
        private static func number(_ v: Float) -> String {
            String(format: "%.3f", v == 0 ? 0 : v)
        }
    }
}
