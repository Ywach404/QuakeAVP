// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  fist_test.swift
//
//  Host-run test for the off-hand fist's pure gate, App/Sources/FistMath.swift:
//  which four-finger poses read as a closed fist, the hysteresis band that
//  stops the rope chattering, and the lockout that keeps opening the fist at
//  the end of a swing from committing a teleport. Compiled and linked ALONE
//  against that one file by tools/check-swift-fist.sh -- no ARKit, no Metal,
//  no engine.
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
struct FistTest {
    static func main() {
        // Straightness is the tip->knuckle chord over the summed bone length,
        // so a straight finger reads near 0.95 and one folded into the palm
        // near 0.40. Same measure the trigger curl already uses.
        let open = SIMD4<Float>(repeating: 0.95)
        let fist = SIMD4<Float>(repeating: 0.40)

        check(!FistMath.closed(open, wasClosed: false),
              "an open hand is not a fist")
        check(FistMath.closed(fist, wasClosed: false),
              "four curled fingers are a fist")

        // The case the hook cannot afford to get wrong. Teleport is aimed with
        // an extended finger, so a hand with one finger out must neither throw
        // a hook nor keep one.
        let pointing = SIMD4<Float>(0.95, 0.40, 0.40, 0.40)
        check(!FistMath.closed(pointing, wasClosed: false),
              "a pointing hand is not a fist")
        check(!FistMath.closed(pointing, wasClosed: true),
              "and pointing opens a fist that was held")

        // Hysteresis: the band between the two thresholds holds a fist that is
        // already closed and cannot close one that is not.
        let band = SIMD4<Float>(repeating: (FistMath.close + FistMath.release) / 2)
        check(FistMath.closed(band, wasClosed: true),
              "a held fist survives the hysteresis band (\(band.x))")
        check(!FistMath.closed(band, wasClosed: false),
              "and the same hand cannot start a fist there")

        // Strictly below, so the threshold itself is open.
        check(!FistMath.closed(SIMD4(repeating: FistMath.close), wasClosed: false),
              "the close threshold itself is not a fist (\(FistMath.close))")

        // A finger ARKit reported no joints for reads STRAIGHT, not curled, so
        // a hand the cameras can only half see cannot throw the hook by
        // accident.
        let halfSeen = SIMD4<Float>(0.40, 0.40, 0.40, FistMath.unknown)
        check(!FistMath.closed(halfSeen, wasClosed: false),
              "a finger ARKit cannot see is not a curled one")

        // The blink lockout. Opening a fist passes through a pose where the
        // fingers have straightened but the thumb is still inside the ring
        // pinch's release radius, and letting go of THAT is the teleport
        // commit, so the lockout has to outlive the fist.
        check(!FistMath.blinkLocked(openedAt: nil, now: 100),
              "a hand that was never fisted locks nothing")
        check(FistMath.blinkLocked(openedAt: 100, now: 100 + FistMath.settle / 2),
              "the blink is locked out just after the fist opens")
        check(!FistMath.blinkLocked(openedAt: 100, now: 100 + FistMath.settle * 2),
              "and unlocks once the hand has settled (\(FistMath.settle) s)")

        print("\nall passed")
    }
}
