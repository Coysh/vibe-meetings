import XCTest
@testable import VMRecording

final class HarmGuardTests: XCTestCase {
    private let frame = 0.016   // 256 samples @ 16 kHz

    /// Three seconds of the canceller making the mic louder is the trip point.
    func testSustainedNegativeERLETrips() {
        var guardian = HarmGuard(tripAfterSeconds: 3)
        var tripped = false
        var seconds = 0.0
        while !tripped && seconds < 10 {
            tripped = guardian.observe(erleDB: -4, seconds: frame)
            seconds += frame
        }
        XCTAssertTrue(tripped)
        XCTAssertEqual(seconds, 3, accuracy: 0.05, "should trip after about 3 s, not sooner")
        XCTAssertEqual(guardian.harmSeconds, 0, "the budget starts over after a trip")
    }

    /// A healthy canceller (positive ERLE, with the odd double-talk dip) never trips.
    func testHealthyCancellerNeverTrips() {
        var guardian = HarmGuard(tripAfterSeconds: 3)
        for i in 0..<(60 * 62) {   // a minute of frames
            let erle: Float = (i % 50 == 0) ? -3 : 12   // a dip every ~0.8 s
            XCTAssertFalse(guardian.observe(erleDB: erle, seconds: frame))
        }
    }

    /// ERLE hovering around zero (the user talking over a silent far end, or a filter that is
    /// simply doing nothing) is not harm.
    func testNearZeroIsNotHarm() {
        var guardian = HarmGuard(tripAfterSeconds: 3)
        for _ in 0..<2000 {
            XCTAssertFalse(guardian.observe(erleDB: -0.6, seconds: frame))
        }
    }

    /// Good frames pay the harm down at half rate: a canceller that is bad half the time still
    /// trips, just later than one that is bad all the time.
    func testIntermittentHarmTripsLater() {
        var guardian = HarmGuard(tripAfterSeconds: 3)
        var seconds = 0.0
        var tripped = false
        var i = 0
        while !tripped && seconds < 60 {
            tripped = guardian.observe(erleDB: i % 2 == 0 ? -5 : 5, seconds: frame)
            seconds += frame
            i += 1
        }
        XCTAssertTrue(tripped)
        XCTAssertGreaterThan(seconds, 6, "half-time harm accrues at a quarter rate")
        XCTAssertLessThan(seconds, 20)
    }

    func testResetForgivesEarlierHarm() {
        var guardian = HarmGuard(tripAfterSeconds: 3)
        for _ in 0..<150 { _ = guardian.observe(erleDB: -5, seconds: frame) }   // 2.4 s of harm
        guardian.reset()
        XCTAssertEqual(guardian.harmSeconds, 0)
        XCTAssertFalse(guardian.observe(erleDB: -5, seconds: frame))
    }
}
