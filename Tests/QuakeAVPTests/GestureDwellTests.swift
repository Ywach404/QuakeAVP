import XCTest
@testable import QuakeAVP

/// The summon's timing half. A held pose has to fire exactly once, survive a
/// tracking flicker without accumulating toward a false trigger, and refuse to
/// re-arm until the hand has actually let go -- the same class of bug as the
/// flick snap-turn's single-frame pulse, which got dropped between ticks.
final class GestureDwellTests: XCTestCase {

    private func dwell() -> GestureDwell { GestureDwell(dwell: 0.6, cooldown: 3.0) }

    func testDoesNotFireBeforeTheDwellElapses() {
        var d = dwell()
        XCTAssertFalse(d.update(active: true, now: 100.0))
        XCTAssertFalse(d.update(active: true, now: 100.5))
    }

    func testFiresOnceTheDwellElapses() {
        var d = dwell()
        _ = d.update(active: true, now: 100.0)
        XCTAssertTrue(d.update(active: true, now: 100.7))
    }

    func testFiresOnlyOncePerHold() {
        var d = dwell()
        _ = d.update(active: true, now: 100.0)
        XCTAssertTrue(d.update(active: true, now: 100.7))
        // Still holding, well past the dwell and past the cooldown: one hold,
        // one window. Repeating here would stack console windows.
        XCTAssertFalse(d.update(active: true, now: 101.5))
        XCTAssertFalse(d.update(active: true, now: 110.0))
    }

    func testReleasingBeforeTheDwellResetsTheTimer() {
        var d = dwell()
        _ = d.update(active: true, now: 100.0)
        _ = d.update(active: false, now: 100.4)          // flicker / hand dropped
        _ = d.update(active: true, now: 100.5)
        // 0.5s after the RESTART, not 0.7s after the original hold.
        XCTAssertFalse(d.update(active: true, now: 101.0))
        XCTAssertTrue(d.update(active: true, now: 101.2))
    }

    func testReArmsOnlyAfterReleaseAndCooldown() {
        var d = dwell()
        _ = d.update(active: true, now: 100.0)
        XCTAssertTrue(d.update(active: true, now: 100.7))
        _ = d.update(active: false, now: 101.0)          // released
        // Released, but inside the cooldown: a second sign is swallowed.
        _ = d.update(active: true, now: 101.5)
        XCTAssertFalse(d.update(active: true, now: 102.3))
        // Released again, now past the cooldown from the fire: it re-arms.
        _ = d.update(active: false, now: 104.0)
        _ = d.update(active: true, now: 104.1)
        XCTAssertTrue(d.update(active: true, now: 104.8))
    }
}
