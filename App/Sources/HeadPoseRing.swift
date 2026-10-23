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
    /// The instant `pose(secondsBefore:)` measures back from. Nil until the
    /// window is summoned; pinned so frames arriving afterwards -- and they
    /// do, since pause freezes the sim only and the renderer keeps running --
    /// cannot drag the answer forward to the player's palms.
    private var frozenAt: TimeInterval?

    /// Called every immersive frame, on the render thread.
    func note(_ pose: simd_float4x4, at time: TimeInterval) {
        lock.lock()
        poses[next] = pose
        times[next] = time
        next = (next + 1) % Self.capacity
        if filled < Self.capacity { filled += 1 }
        lock.unlock()
    }

    /// How many poses are held, whether an instant has been pinned, and the
    /// newest time seen. For working out WHY a cover found no pose, which is
    /// otherwise two different failures wearing one nil.
    var debugState: (held: Int, frozen: TimeInterval?, newest: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let newest = filled == 0 ? 0 : times[(next + Self.capacity - 1) % Self.capacity]
        return (filled, frozenAt, newest)
    }

    /// Called when the window is summoned: pins the instant to measure from.
    func freeze(at time: TimeInterval) {
        lock.lock(); frozenAt = time; lock.unlock()
    }

    /// The pose from `seconds` before the frozen instant, or nil when the
    /// ring has never been written -- which is what a save taken with the
    /// immersive space never opened looks like, and must produce no cover
    /// rather than a wrong one.
    ///
    /// Asking further back than the ring holds returns the OLDEST pose rather
    /// than nil: a view from slightly too long ago is still a picture of the
    /// room, and nil would mean no cover at all.
    func pose(secondsBefore seconds: TimeInterval) -> simd_float4x4? {
        lock.lock(); defer { lock.unlock() }
        guard filled > 0, let frozen = frozenAt else { return nil }

        let target = frozen - seconds
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for i in 0..<filled {
            // Walk the live slots, oldest first when the ring has wrapped.
            let idx = filled == Self.capacity ? (next + i) % Self.capacity : i
            // Ignore anything newer than the frozen instant: those are the
            // frames that arrived while the panel was coming up.
            if times[idx] > frozen + 0.0001 { continue }
            let delta = abs(times[idx] - target)
            if delta < bestDelta { bestDelta = delta; best = idx }
        }
        return bestDelta == .greatestFiniteMagnitude ? nil : poses[best]
    }
}
