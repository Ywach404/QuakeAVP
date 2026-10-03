import XCTest
import simd
@testable import Quake

final class VRTrackTests: XCTestCase {

    private func sample(cl: Float, wall: Float, x: Float) -> VRTrackSample {
        var s = VRTrackSample.identity
        s.clTime = cl; s.wall = wall; s.position = SIMD3(x, 0, 0)
        return s
    }

    private func assertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
    }

    func testResampleSpreadsEqualTimesByWallClock() {
        var t = VRTrack(samples: [sample(cl: 1, wall: 0, x: 0), sample(cl: 1, wall: 0.011, x: 1),
                                  sample(cl: 1.022, wall: 0.022, x: 2)])
        t.resample()
        assertEqual(t.samples.map(\.clTime), [1, 1.011, 1.022], accuracy: 1e-4)
    }

    func testResampleSingleTimeRun() {
        var t = VRTrack(samples: [sample(cl: 5, wall: 0, x: 0), sample(cl: 5, wall: 0.01, x: 1)])
        t.resample()
        XCTAssertEqual(t.samples.count, 2)
        XCTAssertLessThan(t.samples[0].clTime, t.samples[1].clTime)
    }

    func testResampleIdenticalWallStampsStayOrdered() {
        var t = VRTrack(samples: [sample(cl: 5, wall: 0, x: 0), sample(cl: 5, wall: 0, x: 1),
                                  sample(cl: 5, wall: 0, x: 2), sample(cl: 6, wall: 1, x: 3)])
        t.resample()
        for i in 1..<t.samples.count { XCTAssertLessThan(t.samples[i - 1].clTime, t.samples[i].clTime) }
    }

    func testSampleInterpolatesPosition() {
        var t = VRTrack(samples: [sample(cl: 0, wall: 0, x: 0), sample(cl: 1, wall: 1, x: 10)])
        t.resample()
        XCTAssertEqual(t.sample(at: 0.25).position.x, 2.5, accuracy: 1e-5)
    }

    func testSampleBeforeFirstKeyClampsToFirst() {
        var t = VRTrack(samples: [sample(cl: 3, wall: 0, x: 7), sample(cl: 4, wall: 1, x: 8)])
        t.resample()
        XCTAssertEqual(t.sample(at: 1).position.x, 7)
        XCTAssertEqual(t.sample(at: 9).position.x, 8)
    }

    func testSampleWrapsYawAcrossThe180Seam() {
        var a = sample(cl: 0, wall: 0, x: 0); a.bodyYaw = 170
        var b = sample(cl: 1, wall: 1, x: 0); b.bodyYaw = -170
        var t = VRTrack(samples: [a, b]); t.resample()
        XCTAssertEqual(VRTrack.wrapDegrees(t.sample(at: 0.5).bodyYaw - 180), 0, accuracy: 1e-3)
    }

    func testRoundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).vrtrack")
        var s = sample(cl: 1, wall: 0, x: 3)
        s.orientation = simd_quatf(angle: 0.3, axis: simd_normalize(SIMD3(1, 2, 3)))
        s.aimValid = true; s.aimYaw = -12.5; s.headOffset = SIMD3(1, 2, 3); s.heightTrim = 4
        let t = VRTrack(samples: [s])
        try t.write(to: url)
        let back = try VRTrack.load(url: url)
        XCTAssertEqual(back.samples.count, 1)
        XCTAssertEqual(back.samples[0], s)
    }

    func testLoadRejectsGarbage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID()).vrtrack")
        try? Data([1, 2, 3]).write(to: url)
        XCTAssertThrowsError(try VRTrack.load(url: url))
    }

    func testSmoothedTrackLagsBehindStep() {
        var t = VRTrack(samples: (0..<100).map { sample(cl: Float($0) / 90, wall: Float($0) / 90, x: $0 < 50 ? 0 : 10) })
        t.resample()
        let s = VRTrack.smoothed(t, tau: 0.12)
        XCTAssertLessThan(s.sample(at: 50.0 / 90).position.x, 5)
        XCTAssertGreaterThan(s.sample(at: 99.0 / 90).position.x, 9)
    }
}
