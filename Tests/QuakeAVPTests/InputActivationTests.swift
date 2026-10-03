import XCTest
@testable import Quake

/// The rule that decides when bare hands drive the game. It used to live inside
/// ContentView's onChange, which meant it was only ever evaluated while a
/// console window existed -- so closing the window left hand input in whatever
/// state it happened to be in, with nothing to re-evaluate it.
final class InputActivationTests: XCTestCase {

    func testHandsDriveTheGameOnlyWhileImmersed() {
        XCTAssertTrue(InputActivation.handsActive(immersive: true, hasController: false))
        XCTAssertFalse(InputActivation.handsActive(immersive: false, hasController: false))
    }

    /// Hardware always wins: a controller connecting mid-session takes over.
    func testHardwareBeatsHands() {
        XCTAssertFalse(InputActivation.handsActive(immersive: true, hasController: true))
        XCTAssertFalse(InputActivation.handsActive(immersive: false, hasController: true))
    }
}
