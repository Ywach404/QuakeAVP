// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  FistMath.swift
//
//  The off hand's closed fist: the gesture that throws the grappling hook
//  when there are no controllers in the room. Pure, with no ARKit in it, so
//  tools/check-swift-fist.sh can drive it on the host -- what is worth
//  asserting here is a sequence of gesture states, and that needs no device.
//  HandInput measures the four fingers and calls in; nothing else does.
//

enum FistMath {

    /// Straightness thresholds on a finger: the tip->knuckle chord over the
    /// summed bone length, so ~1 is a straight finger and ~0.4 one folded into
    /// the palm. Closes at `close`, opens at `release` -- the same measure and
    /// the same 0.10 of hysteresis as the single-finger trigger curl in
    /// HandInput, whose numbers were settled on device.
    ///
    /// Deliberately NOT `VRSettings.curlSensitivity`, live-tunable though that
    /// is. That knob decides when the trigger finger fires, and sharing it
    /// would hand a player who likes a light trigger a hair-trigger rope.
    static let close: Float = 0.72
    static let release: Float = 0.82

    /// What a finger reads as when ARKit reported no joints for it at all:
    /// straight, not curled, so a hand the cameras can only half see cannot
    /// throw the hook on its own.
    static let unknown: Float = 1

    /// How long the teleport commit stays shut after the fist opens.
    ///
    /// The fist releases on finger STRAIGHTNESS while the blink commits on a
    /// thumb-to-ring-tip DISTANCE, and those two do not cross their thresholds
    /// on the same update. A hand opening from a fist passes through a pose
    /// where the fingers have straightened enough to drop the rope while the
    /// thumb is still inside the ring pinch's 30 mm release radius, and letting
    /// go of that pinch a moment later is a release edge. That edge is the
    /// blink. So the lockout has to outlive the fist rather than merely
    /// coincide with it.
    static let settle: Double = 0.3

    /// Whether four curled fingers add up to a closed fist.
    ///
    /// All four of them, because the hand that points to teleport has one
    /// finger out and must never throw a hook. Measured on the greatest
    /// straightness rather than an average so that one straight finger is
    /// enough to refuse, which an average would let the other three outvote.
    ///
    /// The thumb is not tested. It is the pinch finger, it wraps over the
    /// fingers or tucks beside them depending on whose fist it is, and it is
    /// the joint the pinch state machines already own.
    ///
    /// - Parameters:
    ///   - straightness: index, middle, ring and little, in that order;
    ///     `unknown` for a finger with no joints reported.
    ///   - wasClosed: the previous update's answer, which is the hysteresis.
    static func closed(_ straightness: SIMD4<Float>, wasClosed: Bool) -> Bool {
        straightness.max() < (wasClosed ? release : close)
    }

    /// Whether the teleport commit is still locked out after a fist. See
    /// `settle` for why this outlives the gesture.
    static func blinkLocked(openedAt: Double?, now: Double) -> Bool {
        guard let openedAt else { return false }
        return now - openedAt < settle
    }
}
