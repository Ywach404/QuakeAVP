// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  HeadPoseRing.swift
//
//  A second of head poses, so a save's cover can be drawn from where the
//  player was looking BEFORE they summoned the window.
//
//  A single remembered slot would be wrong, and the reason is the gesture.
//  Both ways into the window are hand gestures: the prayer sign dwells for
//  0.6 s with the palms held in front of the face, and the wrist gauntlet's
//  MENU cell is pressed while looking at the wrist. Freezing the pose at the
//  moment of summon therefore captures the player staring at their own hands
//  -- the anti-goal in a different costume. What is wanted is the room as it
//  was a moment before the gesture began.
//
//  So: a ring written every immersive frame, frozen when the window is
//  summoned, and read backwards from that instant.
//
//  The writer is the render thread and the reader is the summon, so it takes
//  a lock -- but never allocates on the write path, which runs at 90 Hz
//  forever. One second at 90 Hz is 90 slots of 64 bytes plus a timestamp,
//  under 6 KB, which is cheaper than almost anything else in this app.
//
//  No engine import and no SwiftUI: tools/check-swift-session.sh compiles
//  this alone against its test.
//

import Foundation
import simd

final class HeadPoseRing: @unchecked Sendable {

    /// One ring for the app. Written by whichever render thread owns the
    /// immersive consumer, read by the summon, so it outlives both.
    static let shared = HeadPoseRing()


    /// One second at 90 Hz. Long enough to predate the prayer sign's 0.6 s
    /// dwell with room to spare, short enough that the oldest pose is still
    /// the same room the player is standing in.
    static let capacity = 90

    private let lock = NSLock()
    private var poses = [simd_float4x4](repeating: matrix_identity_float4x4,
                                        count: HeadPoseRing.capacity)
    private var times = [TimeInterval](repeating: 0, count: HeadPoseRing.capacity)
    /// Where the NEXT write goes. Also the count, until the ring wraps.
    private var next = 0
    private var filled = 0
    /// The pose chosen when the window was summoned, RESOLVED at that moment
    /// rather than looked up later.
    ///
    /// A first version pinned the summon's timestamp and searched for it when
    /// the save happened. That cannot work: the player has to look at the
    /// panel and press a button, which takes seconds, and one second of ring
    /// has rolled entirely past the pinned instant by then -- every pose held
    /// is NEWER than the thing being searched for, and the search returns
    /// nothing. Measured on device at 3.5 s between summon and save.
    private var latched: simd_float4x4?
    private var latchedAt: TimeInterval?

    /// Called every immersive frame, on the render thread.
    func note(_ pose: simd_float4x4, at time: TimeInterval) {
        lock.lock()
        poses[next] = pose
        times[next] = time
        next = (next + 1) % Self.capacity
        if filled < Self.capacity { filled += 1 }
        lock.unlock()
    }

    /// Called when the window is summoned. Resolves the look-back NOW and
    /// keeps the matrix, because by the time a save happens the ring no
    /// longer reaches back this far.
    func freeze(at time: TimeInterval, lookBack: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard filled > 0 else { return }
        let target = time - lookBack
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for i in 0..<filled {
            let idx = filled == Self.capacity ? (next + i) % Self.capacity : i
            let delta = abs(times[idx] - target)
            if delta < bestDelta { bestDelta = delta; best = idx }
        }
        latched = poses[best]
        latchedAt = times[best]
    }

    /// The pose a cover should be drawn from.
    ///
    /// The latched one when the window was summoned this session; otherwise
    /// the most recent pose held. That fallback matters: with the panel
    /// already open, a save never re-summons, so nothing is latched -- and
    /// the newest pose is still a view of the room, just the direction the
    /// panel happens to be in. A cover of the room beats no cover.
    ///
    /// Nil only when the ring has never been written, which is what a save
    /// taken with the immersive space never opened looks like.
    func coverPose() -> simd_float4x4? {
        lock.lock(); defer { lock.unlock() }
        if let latched { return latched }
        guard filled > 0 else { return nil }
        return poses[(next + Self.capacity - 1) % Self.capacity]
    }

    /// How many poses are held, whether one was latched at a summon, and the
    /// newest time seen. For working out WHY a cover found no pose.
    var debugState: (held: Int, latched: TimeInterval?, newest: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let newest = filled == 0 ? 0 : times[(next + Self.capacity - 1) % Self.capacity]
        return (filled, latchedAt, newest)
    }
}
