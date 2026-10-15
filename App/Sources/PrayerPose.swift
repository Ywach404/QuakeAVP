// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  PrayerPose.swift
//
//  The two-handed prayer sign, kept as pure geometry over three facts per
//  hand so it can be tested off device -- the same reason the renderer
//  bridge is pure C. HandInput reduces each ARKit skeleton to a PalmPose
//  and asks this; nothing here touches ARKit, the engine or the main actor.
//
//  Why this gesture owns the console summon: visionOS reserves the palm.
//  Palm toward your face shows the Home View dot, palm away shows the status
//  bar into Control Center, and `persistentSystemOverlays(.hidden)` is only a
//  preference -- the system still surfaces them when the user looks and
//  pinches. Prayer holds both palms edge-on to the face, facing each other,
//  which is a pose the system makes no claim on.
//

import simd

/// One hand reduced to what the sign needs. All unit vectors, room frame
/// (uncorrected), ARKit convention: +y up, +x right, -z away from the viewer.
struct PalmPose {
    /// Palm centroid.
    var center: SIMD3<Float>
    /// Out of the palm, already un-mirrored so both hands agree.
    var normal: SIMD3<Float>
    /// Where the fingers point: the palm's long axis, up the hand.
    var forward: SIMD3<Float>
}

extension PalmPose {

    /// Build the palm plane from the wrist and the index/little METACARPALS.
    ///
    /// Not the knuckles. ARKit stops reporting the knuckle joints as the hands
    /// close -- one gone at 0.31m apart, all three at 0.09m -- because the sign
    /// hides the fingers from the cameras, so a knuckle-based plane is nil in
    /// exactly the pose it has to recognise. The metacarpals are the palm bones,
    /// inferred from the hand's rigid pose, and were never absent in a full
    /// session's log. They also describe the palm plane more honestly.
    ///
    /// `nil` when the three points are collinear and the plane is undefined.
    init?(wrist: SIMD3<Float>, indexMetacarpal: SIMD3<Float>,
          littleMetacarpal: SIMD3<Float>, isLeft: Bool) {
        var n = simd_cross(indexMetacarpal - wrist, littleMetacarpal - wrist)
        // Across the palm, index side to little side. Both this and the normal
        // mirror between hands, so one flip serves both.
        var across = indexMetacarpal - littleMetacarpal
        if !isLeft { n = -n; across = -across }
        let len = simd_length(n), acrossLen = simd_length(across)
        guard len > 0, acrossLen > 0 else { return nil }
        let normal = n / len
        // The third axis of the palm frame. Taken as a cross product rather than
        // read off a fingertip joint, so the finger direction survives the
        // fingers themselves being invisible to the cameras -- which is the
        // whole difficulty with this sign. Unit by construction: the normal is
        // perpendicular to every vector in the palm plane, `across` included.
        self.init(center: (wrist + indexMetacarpal + littleMetacarpal) / 3,
                  normal: normal,
                  forward: simd_cross(normal, across / acrossLen))
    }
}

enum PrayerPose {

    /// Thresholds are deliberately loose. A real sign is asymmetric, and
    /// palms together partially occlude each other from the cameras, so tight
    /// values read as "never triggers" on device. Calibrate against the
    /// [inputlog] prayer facts, not against argument.

    /// Palms need only be near each other, not touching -- each palm centroid
    /// sits inside its own hand, so even pressed together they read a few cm
    /// apart. MEASURED: a held sign reports 0.07-0.14 m on device, so 0.12
    /// rejected real holds outright. 0.16 covers the measured range and still
    /// rejects hands genuinely apart, which read 0.18 and up.
    static let gapMax: Float = 0.16
    /// Normals oppose. -1 is palm-flat-on-palm; this admits 113 degrees between
    /// them, i.e. ~33 degrees of splay per hand, because the steeple form of
    /// the sign -- fingertips together, heels apart, palms in a V -- is how
    /// plenty of people hold it and lands near -0.5. Tightening this to -0.6
    /// rejected a 30-degree steeple outright.
    static let facingDotMax: Float = -0.4
    /// Fingers up. This is the condition that separates the sign from hands
    /// clasped in the lap (fingers down) and a two-handed grab (fingers
    /// forward), both of which satisfy everything else.
    static let fingersUpMin: Float = 0.5

    /// Whether both hands are held in the prayer sign. `nil` for either hand
    /// means untracked, which is a no -- never guess the sign from one hand.
    ///
    /// There is deliberately NO check that each palm faces the other, which
    /// would also reject hands held back to back. That check needs the sign of
    /// the palm normal, and the device disagreed with every convention derived
    /// at a desk: it reported the normals pointing apart (dot -0.90, steady)
    /// while gap, facing and fingers-up all passed throughout a held sign. The
    /// guard defended against a pose -- fingers up, backs touching, palms
    /// outward, inside 16cm -- that does not occur while playing, and it was
    /// the only thing standing between a correct detector and a working one.
    static func matches(left: PalmPose?, right: PalmPose?) -> Bool {
        guard let l = left, let r = right else { return false }
        guard simd_distance(l.center, r.center) <= gapMax else { return false }
        guard simd_dot(l.normal, r.normal) <= facingDotMax else { return false }
        return l.forward.y >= fingersUpMin && r.forward.y >= fingersUpMin
    }
}
