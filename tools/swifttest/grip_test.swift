// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  grip_test.swift
//
//  Host-run test for App/Sources/GripLatch.swift: whether the off hand is
//  still gripping the rope, decided from a sequence of hand updates. The
//  question it answers is what to do with an update that did not actually
//  measure the hand, which is the common case when the throwing arm sweeps
//  across the gripping one. Compiled and linked ALONE against that one file
//  by tools/check-swift-grip.sh -- no ARKit, no Metal, no engine.
//

import Foundation

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok:   \(label)")
    } else {
        print("FAIL: \(label)")
        exit(1)
    }
}

@main
struct GripTest {
    static func main() {
        // A measurement, either way, is always obeyed.
        var g = GripLatch()
        check(!g.gripping, "a hand starts not gripping")
        check(g.update(.measured(fistClosed: true)),
              "a measured fist grips")
        check(!g.update(.measured(fistClosed: false)),
              "a measured open hand lets go")

        // THE BUG. Turning left sweeps the dominant hand across the off hand,
        // which hides it from the cameras. The rope used to drop here and the
        // player fell out of mid air. An update that did not see the hand says
        // nothing about what the hand is doing, so it must not move the grip.
        g = GripLatch()
        _ = g.update(.measured(fistClosed: true))
        check(g.update(.lost),
              "a grip survives an update with no skeleton at all")
        check(g.update(.untrusted),
              "and one whose finger joints ARKit only inferred")

        // Indefinitely, not for a window. A hand behind the other hand can be
        // gone for as long as the turn takes, and there is no duration at which
        // falling off the rope becomes the right answer.
        g = GripLatch()
        _ = g.update(.measured(fistClosed: true))
        for _ in 0 ..< 10_000 { _ = g.update(.lost) }
        check(g.gripping, "and through ten thousand lost updates")

        // The dangerous direction, which is not symmetric with the above: an
        // unreadable hand must never CREATE a grip, or a hand the cameras lose
        // while open would throw a hook on its own.
        g = GripLatch()
        check(!g.update(.lost), "an unreadable hand cannot start a grip")
        check(!g.update(.untrusted), "nor can an untrusted one")

        // Recovery, in A.'s own terms: still a fist means the rope was meant
        // to stay, an open hand means let go.
        g = GripLatch()
        _ = g.update(.measured(fistClosed: true))
        _ = g.update(.lost)
        check(g.update(.measured(fistClosed: true)),
              "recovering still in a fist keeps the rope")

        g = GripLatch()
        _ = g.update(.measured(fistClosed: true))
        _ = g.update(.lost)
        check(!g.update(.measured(fistClosed: false)),
              "recovering with an open hand releases it")

        // And a release sticks: losing the hand again after letting go must not
        // resurrect the grip it was holding before.
        check(!g.update(.lost), "a hand lost after releasing stays released")

        print("\nall passed")
    }
}
