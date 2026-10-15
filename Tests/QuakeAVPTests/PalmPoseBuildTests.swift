// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez

import XCTest
import simd
@testable import QuakeAVP

/// Building the palm plane from joints.
///
/// It must come from the METACARPALS (the palm bones), not the knuckles. On
/// device, ARKit stops reporting `indexFingerKnuckle`, `middleFingerKnuckle`
/// and `littleFingerKnuckle` as the hands come together -- at 0.31m apart one
/// knuckle drops, at 0.09m all three are gone -- because the prayer sign hides
/// the fingers from the cameras. The metacarpals are inferred from the hand's
/// rigid pose and were never once absent across a whole session's log.
///
/// Room frame, ARKit convention: +y up, +x right, -z away from the viewer.
/// Metacarpals sit near the wrist, spread across the base of the palm.

final class PalmPoseBuildTests: XCTestCase {

    /// Left hand held palm-up, fingers pointing away.
    func testLeftHandPalmUp() throws {
        let pose = try XCTUnwrap(PalmPose(wrist: .zero,
                                          indexMetacarpal: SIMD3(0.02, 0, -0.03),
                                          littleMetacarpal: SIMD3(-0.03, 0, -0.03),
                                          isLeft: true))
        XCTAssertEqual(abs(pose.normal.y), 1, accuracy: 0.01)  // plane is the palm's
        XCTAssertEqual(pose.forward.z, -1, accuracy: 0.01)    // fingers: away
    }

    /// Same pose, right hand. The winding mirrors, so without the correction
    /// this normal points at the floor and the finger axis points backwards.
    func testRightHandPalmUpAgreesWithLeft() throws {
        let pose = try XCTUnwrap(PalmPose(wrist: .zero,
                                          indexMetacarpal: SIMD3(-0.02, 0, -0.03),
                                          littleMetacarpal: SIMD3(0.03, 0, -0.03),
                                          isLeft: false))
        XCTAssertEqual(abs(pose.normal.y), 1, accuracy: 0.01)
        XCTAssertEqual(pose.forward.z, -1, accuracy: 0.01)
    }

    /// Left hand in the prayer sign: palm faces right (toward the other hand),
    /// fingers up.
    func testLeftHandInPrayerFacesRightWithFingersUp() throws {
        let pose = try XCTUnwrap(PalmPose(wrist: .zero,
                                          indexMetacarpal: SIMD3(0, 0.03, -0.025),
                                          littleMetacarpal: SIMD3(0, 0.03, 0.025),
                                          isLeft: true))
        XCTAssertEqual(abs(pose.normal.x), 1, accuracy: 0.01)  // palm plane is vertical
        XCTAssertEqual(pose.forward.y, 1, accuracy: 0.01)     // fingers up
    }

    /// Degenerate input (wrist and both metacarpals collinear) has no plane.
    /// nil is right; normalising a zero vector would hand the detector a NaN.
    func testCollinearJointsHaveNoPlane() {
        XCTAssertNil(PalmPose(wrist: .zero,
                              indexMetacarpal: SIMD3(0, 0.03, 0),
                              littleMetacarpal: SIMD3(0, 0.06, 0),
                              isLeft: true))
    }

    /// End to end, in the terms ingest uses: two hands built from metacarpal
    /// positions, held in the sign, match. Wrists 9cm apart -- the figure the
    /// device actually reports while the sign is held.
    func testTwoHandsBuiltFromJointsMatchThePrayerSign() {
        let left = PalmPose(wrist: SIMD3(-0.045, 1.10, -0.30),
                            indexMetacarpal: SIMD3(-0.045, 1.13, -0.325),
                            littleMetacarpal: SIMD3(-0.045, 1.13, -0.275),
                            isLeft: true)
        let right = PalmPose(wrist: SIMD3(0.045, 1.10, -0.30),
                             indexMetacarpal: SIMD3(0.045, 1.13, -0.325),
                             littleMetacarpal: SIMD3(0.045, 1.13, -0.275),
                             isLeft: false)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertTrue(PrayerPose.matches(left: left, right: right))
    }
}
