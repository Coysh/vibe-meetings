import XCTest
@testable import VMRecording

final class DelayEstimatorTests: XCTestCase {

    /// Build the mic/ref windows the estimator expects from a longer pair of
    /// aligned signals (same time base), mic window starting at sample `t0`.
    private func windows(_ est: DelayEstimator, mic: [Float], ref: [Float], t0: Int) -> ([Float], [Float]) {
        let m = Array(mic[t0..<(t0 + est.micLength)])
        let r = Array(ref[(t0 - est.preSamples)..<(t0 - est.preSamples + est.refLength)])
        return (m, r)
    }

    private func estimate(delayMs: Double, rt60: Double = 0.3) -> DelayEstimator.Result? {
        let est = DelayEstimator()
        let ref = TestSignals.speechLike(seconds: 8, seed: 5)
        let echo = TestSignals.convolve(ref, TestSignals.roomResponse(delayMs: delayMs, rt60: rt60))
        let noise = TestSignals.speechLike(seconds: 8, seed: 77, level: 0.01)
        let mic = zip(echo, noise).map { $0 + $1 }
        let (m, r) = windows(est, mic: mic, ref: ref, t0: 4 * 16000)
        return est.estimate(mic: m, ref: r)
    }

    func testFindsShortDelay() throws {
        let r = try XCTUnwrap(estimate(delayMs: 40))
        print("40 ms → \(Double(r.delaySamples) / 16) ms, confidence \(r.confidence)")
        XCTAssertEqual(Double(r.delaySamples) / 16, 40, accuracy: 1)
    }

    func testFindsBluetoothSizedDelay() throws {
        let r = try XCTUnwrap(estimate(delayMs: 250))
        print("250 ms → \(Double(r.delaySamples) / 16) ms, confidence \(r.confidence)")
        XCTAssertEqual(Double(r.delaySamples) / 16, 250, accuracy: 1)
    }

    /// Calibration: confidence for a real echo vs. a mic that has nothing to do
    /// with the reference (headphones).
    func testConfidenceSeparatesEchoFromNoCoupling() throws {
        let echo = try XCTUnwrap(estimate(delayMs: 40, rt60: 0.4))
        let est = DelayEstimator()
        let ref = TestSignals.speechLike(seconds: 8, seed: 5)
        let user = TestSignals.speechLike(seconds: 8, seed: 123)
        let (m, r) = windows(est, mic: user, ref: ref, t0: 4 * 16000)
        let none = try XCTUnwrap(est.estimate(mic: m, ref: r))
        print("confidence: echo=\(echo.confidence)  uncorrelated=\(none.confidence)")
        XCTAssertGreaterThan(echo.confidence, none.confidence * 1.5)
    }
}
