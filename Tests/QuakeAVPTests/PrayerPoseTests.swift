import XCTest
import simd
@testable import Quake

/// The prayer sign is the console summon, so its detector has to reject every
/// pose a player actually holds during play. These cases are the ones that
/// would summon a window mid-fight if the thresholds were sloppy: hands
/// clasped low, both palms the same way while reloading a gesture, and the
/// two-handed grab where the fingers point forward instead of up.
///
/// Room frame throughout, ARKit convention: +y up, +x right, -z away.
final class PrayerPoseTests: XCTestCase {

    /// Palms 6 cm apart facing each other across the midline, fingers straight
    /// up: the canonical sign.
    private func canonicalPrayer() -> (PalmPose, PalmPose) {
        let left = PalmPose(center: SIMD3(-0.03, 1.2, -0.30),
                            normal: SIMD3(1, 0, 0),      // out of the left palm: rightward
                            forward: SIMD3(0, 1, 0))
        let right = PalmPose(center: SIMD3(0.03, 1.2, -0.30),
                             normal: SIMD3(-1, 0, 0),
                             forward: SIMD3(0, 1, 0))
        return (left, right)
    }

    func testCanonicalPrayerMatches() {
        let (left, right) = canonicalPrayer()
        XCTAssertTrue(PrayerPose.matches(left: left, right: right))
    }

    /// A real sign is never symmetric: palms splay open a little and the
    /// fingers tilt back toward the face. 30 degrees of each still counts, or
    /// nobody can trigger it reliably on device.
    func testSloppyButRealPrayerMatches() {
        let tilt = Float.pi / 6                                  // 30 degrees
        let left = PalmPose(center: SIMD3(-0.04, 1.15, -0.28),
                            normal: simd_normalize(SIMD3(cos(tilt), 0, sin(tilt))),
                            forward: simd_normalize(SIMD3(0, cos(tilt), sin(tilt))))
        let right = PalmPose(center: SIMD3(0.04, 1.17, -0.31),
                             normal: simd_normalize(SIMD3(-cos(tilt), 0, sin(tilt))),
                             forward: simd_normalize(SIMD3(0, cos(tilt), sin(tilt))))
        XCTAssertTrue(PrayerPose.matches(left: left, right: right))
    }

    /// Hands held apart, each in the prayer orientation. Facing each other
    /// across a 40 cm gap is two idle hands, not a sign.
    func testHandsApartDoesNotMatch() {
        var (left, right) = canonicalPrayer()
        left.center.x = -0.20
        right.center.x = 0.20
        XCTAssertFalse(PrayerPose.matches(left: left, right: right))
    }

    /// Both palms pointing the same way -- hands stacked or held side by side,
    /// as when resting them together. The normals must oppose.
    func testPalmsFacingTheSameWayDoesNotMatch() {
        var (left, right) = canonicalPrayer()
        right.normal = left.normal
        XCTAssertFalse(PrayerPose.matches(left: left, right: right))
    }

    /// Hands clasped in the lap: touching, palms opposed, fingers DOWN. This is
    /// the pose a player rests in, and it must not summon anything.
    func testHandsClaspedDownwardDoesNotMatch() {
        var (left, right) = canonicalPrayer()
        left.forward = SIMD3(0, -1, 0)
        right.forward = SIMD3(0, -1, 0)
        XCTAssertFalse(PrayerPose.matches(left: left, right: right))
    }

    /// Two-handed grab / handshake: palms opposed and close, but the fingers
    /// point away from the body rather than up.
    func testTwoHandedGrabDoesNotMatch() {
        var (left, right) = canonicalPrayer()
        left.forward = SIMD3(0, 0, -1)
        right.forward = SIMD3(0, 0, -1)
        XCTAssertFalse(PrayerPose.matches(left: left, right: right))
    }

    /// One hand untracked. Palms-together occludes the far hand from the
    /// cameras, so this is the common failure and it must read as "no sign"
    /// rather than crash or guess from one hand.
    func testUntrackedHandDoesNotMatch() {
        let (left, _) = canonicalPrayer()
        XCTAssertFalse(PrayerPose.matches(left: left, right: nil))
        XCTAssertFalse(PrayerPose.matches(left: nil, right: nil))
    }
}
