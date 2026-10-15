import XCTest
@testable import QuakeAVP

final class CaptureStateTests: XCTestCase {

    func testDemoNameSanitised() {
        XCTAssertEqual(CaptureState.sanitise("my run ../x"), "myrunx")
        XCTAssertEqual(CaptureState.sanitise("   "), "clip")
        XCTAssertEqual(CaptureState.sanitise("Frag_Comp-2"), "Frag_Comp-2")
    }

    func testDefaultNameFormat() {
        let utc = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.timeZone = utc; c.year = 2026; c.month = 9; c.day = 24; c.hour = 1; c.minute = 13
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(CaptureState.defaultName(now: d, timeZone: utc), "clip-20260924-0113")
    }

    @MainActor
    func testRefreshListsDemosNewestFirstWithTrackBadge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("old.dem"))
        try Data([1]).write(to: dir.appendingPathComponent("old.vrtrack"))
        Thread.sleep(forTimeInterval: 0.05)
        try Data([1]).write(to: dir.appendingPathComponent("new.dem"))
        try Data([1]).write(to: dir.appendingPathComponent("notademo.txt"))
        let state = CaptureState()
        state.refresh(gameDirectory: dir)
        XCTAssertEqual(state.demos.map(\.name), ["new", "old"])
        XCTAssertEqual(state.demos.map(\.hasTrack), [false, true])
    }
}
