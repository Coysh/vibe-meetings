import XCTest
@testable import VMRecording

final class SpeexEchoCancellerTests: XCTestCase {

    /// Run the canceller over `mic`/`ref` (already aligned) frame by frame.
    private func run(_ aec: SpeexEchoCanceller, mic: [Float], ref: [Float]) -> [Float] {
        let f = aec.frameSize
        var out = [Float](repeating: 0, count: mic.count)
        var i = 0
        while i + f <= mic.count {
            mic.withUnsafeBufferPointer { m in
                ref.withUnsafeBufferPointer { r in
                    out.withUnsafeMutableBufferPointer { o in
                        aec.process(mic: m.baseAddress! + i, reference: r.baseAddress! + i, out: o.baseAddress! + i)
                    }
                }
            }
            i += f
        }
        return out
    }

    /// A far-end talker heard back through a reverberant room (40 ms delay,
    /// 0.4 s RT60): once converged the canceller removes >15 dB of the echo.
    func testConvergesOnReverberantRoom() {
        let seconds = 10.0
        let ref = TestSignals.speechLike(seconds: seconds, seed: 1)
        let h = TestSignals.roomResponse(delayMs: 40, rt60: 0.4)
        let echo = TestSignals.convolve(ref, h)
        let aec = SpeexEchoCanceller(frameSize: 256, tailLength: 4096)
        let out = run(aec, mic: echo, ref: ref)

        let tail = (Int(7.0 * 16000))..<(Int(10.0 * 16000))      // last 3 s, after convergence
        let erle = TestSignals.db(TestSignals.energy(echo[tail]) / TestSignals.energy(out[tail]))
        print("ERLE (reverberant room, 40 ms): \(erle) dB")
        XCTAssertGreaterThan(erle, 15)
    }

    /// With no echo path at all (headphones), speech from the user passes
    /// through with little loss.
    func testNearEndSpeechSurvivesWithoutEcho() {
        let ref = TestSignals.speechLike(seconds: 8, seed: 3)
        let user = TestSignals.speechLike(seconds: 8, seed: 99)
        let aec = SpeexEchoCanceller(frameSize: 256, tailLength: 4096)
        let out = run(aec, mic: user, ref: ref)
        let tail = (Int(4.0 * 16000))..<(Int(8.0 * 16000))
        let loss = TestSignals.db(TestSignals.energy(user[tail]) / TestSignals.energy(out[tail]))
        print("Near-end attenuation with no echo: \(loss) dB")
        XCTAssertLessThan(abs(loss), 3, "user speech must not be materially attenuated when there is no echo")
    }
}
