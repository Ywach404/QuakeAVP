import XCTest
@testable import Quake

final class ExportPresetTests: XCTestCase {

    func testFileName() {
        var p = ExportPreset()
        p.fps = 60; p.slowMo = 0.5; p.motionBlurSamples = 4; p.camera = .head
        XCTAssertEqual(p.fileName(demo: "run1"), "run1-1080p60-slow2-mb4-head.mov")
        p.slowMo = 1; p.motionBlurSamples = 1
        XCTAssertEqual(p.fileName(demo: "run1"), "run1-1080p60-head.mov")
    }

    func testSubStepsCappedAtOneMillisecond() {
        var p = ExportPreset()
        p.fps = 120; p.slowMo = 0.25; p.motionBlurSamples = 8
        XCTAssertEqual(p.subSteps, 2)      // 0.25/120 = 2.08 ms per frame
        p.fps = 60; p.slowMo = 1; p.motionBlurSamples = 8
        XCTAssertEqual(p.subSteps, 8)
        p.motionBlurSamples = 1
        XCTAssertEqual(p.subSteps, 1)
    }

    func testParse() {
        let p = ExportPreset.parse("2160p30,slow0.25,mb8,gun,h264")
        XCTAssertEqual(p.resolution, .p2160)
        XCTAssertEqual(p.fps, 30)
        XCTAssertEqual(p.slowMo, 0.25)
        XCTAssertEqual(p.motionBlurSamples, 8)
        XCTAssertEqual(p.camera, .gun)
        XCTAssertEqual(p.codec, .h264)
        XCTAssertEqual(ExportPreset.parse("garbage"), ExportPreset())
    }

    func testSizeIs16by9() {
        var p = ExportPreset(); p.resolution = .p1440
        XCTAssertEqual(p.width, 2560); XCTAssertEqual(p.height, 1440)
    }
}
