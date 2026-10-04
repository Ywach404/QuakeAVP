import XCTest
@testable import Quake

/// The ring cursor. Sinks usually break here, and the failure is audible
/// rather than diagnosable, so the arithmetic is pure and pinned.
final class AudioRingTests: XCTestCase {

    /// shm->samples is a bitmask in snd_mix.c, so a non-power-of-two ring
    /// corrupts audio silently. The type refuses to build one.
    func testRejectsNonPowerOfTwo() {
        XCTAssertNil(AudioRing(monoSamples: 3000, channels: 2))
        XCTAssertNotNil(AudioRing(monoSamples: 4096, channels: 2))
    }

    /// samplePosition is in MONO samples, which is what SNDDMA_GetDMAPos
    /// returns and what snd_mix paints against.
    func testAdvanceCountsMonoSamples() throws {
        var r = try XCTUnwrap(AudioRing(monoSamples: 4096, channels: 2))
        XCTAssertEqual(r.samplePosition, 0)
        r.advance(frames: 100)
        XCTAssertEqual(r.samplePosition, 200)   // stereo: 2 mono per frame
    }

    /// The cursor must wrap inside the ring and never run backwards, or the
    /// mixer paints nothing (or everything) on the frame it wraps.
    func testCursorWrapsWithoutGoingBackwards() throws {
        var r = try XCTUnwrap(AudioRing(monoSamples: 4096, channels: 2))
        r.advance(frames: 2048)                 // exactly one lap
        XCTAssertEqual(r.samplePosition, 0)
        r.advance(frames: 1)
        XCTAssertEqual(r.samplePosition, 2)
    }

    /// A read that straddles the end comes back as two ranges; one memcpy per
    /// range is what the render block does.
    func testStraddlingReadSplitsIntoTwoRanges() throws {
        var r = try XCTUnwrap(AudioRing(monoSamples: 4096, channels: 2))
        r.advance(frames: 2000)
        let (a, b) = r.readOffsets(frames: 100)
        XCTAssertEqual(a, 4000..<4096)
        XCTAssertEqual(b, 0..<104)
        XCTAssertEqual(a.count + b.count, 200)
    }

    /// A read that fits returns an empty second range, so the caller's second
    /// memcpy is a no-op rather than a special case.
    func testNonStraddlingReadHasEmptySecondRange() throws {
        var r = try XCTUnwrap(AudioRing(monoSamples: 4096, channels: 2))
        let (a, b) = r.readOffsets(frames: 10)
        XCTAssertEqual(a, 0..<20)
        XCTAssertTrue(b.isEmpty)
    }
}
