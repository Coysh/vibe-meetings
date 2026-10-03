import VMCore
import XCTest
@testable import VMRecording

final class EchoCancellationPipelineTests: XCTestCase {
    private let fs = 16_000.0

    struct Simulation {
        var chunks: [PCMChunk]
        var stats: EchoCancellationStats
        var output: [Float] { chunks.flatMap(\.samples) }
    }

    /// Feed the pipeline the way the coordinator does: ~85 ms mic chunks and
    /// ~10 ms reference chunks, each stamped on its own device clock, delivered
    /// in order of when they would have finished being captured.
    ///
    /// - Parameters:
    ///   - refPPM: the speaker/tap clock runs this many ppm fast relative to the mic.
    ///   - jitterMs: random ± timestamp jitter on every chunk.
    private func simulate(
        far: [Float], mic: [Float], sendReference: Bool = true,
        refPPM: Double = 0, jitterMs: Double = 0, micOffsetSeconds: Double = 0,
        config: EchoCancellationPipeline.Configuration = .init()
    ) async -> Simulation {
        var rng = XorShift(seed: 4242)
        func jitter() -> Double { jitterMs == 0 ? 0 : Double(rng.uniform()) * jitterMs / 1000 }

        let eps = refPPM * 1e-6
        let refRate = fs * (1 + eps)
        // The reference device clock samples the same far-end signal at its own rate.
        let refCount = Int(Double(far.count) / (1 + eps))
        // Resample with the high-quality windowed-sinc kernel: a cheap (linear)
        // resampler would make the "reference" differ from the true echo source
        // by ~-20 dB and cap every result, whatever the pipeline does.
        var refSig = [Float](repeating: 0, count: refCount)
        let table = FractionalDelayTable.shared
        let taps = FractionalDelayTable.taps, phases = FractionalDelayTable.phases
        for i in 0..<refCount {
            let pos = Double(i) / (1 + eps)
            let i0 = Int(pos.rounded(.down))
            let ph = Int(((pos - Double(i0)) * Double(phases)).rounded())
            if ph == 0 || ph == phases { refSig[i] = far[min(far.count - 1, i0 + (ph == phases ? 1 : 0))]; continue }
            var acc: Float = 0
            for t in 0..<taps {
                let li = i0 - taps / 2 + 1 + t
                if li >= 0 && li < far.count { acc += far[li] * table[ph * taps + t] }
            }
            refSig[i] = acc
        }

        struct Ev { var deliveredAt: Double; var isMic: Bool; var chunk: PCMChunk }
        var events: [Ev] = []
        var i = 0
        while i < mic.count {
            let n = min(1365, mic.count - i)
            events.append(Ev(deliveredAt: Double(i + n) / fs, isMic: true,
                             chunk: PCMChunk(samples: Array(mic[i..<(i + n)]), timestamp: Double(i) / fs + micOffsetSeconds + jitter())))
            i += n
        }
        if sendReference {
            i = 0
            while i < refSig.count {
                let n = min(160, refSig.count - i)
                events.append(Ev(deliveredAt: Double(i + n) / refRate, isMic: false,
                                 chunk: PCMChunk(samples: Array(refSig[i..<(i + n)]), timestamp: Double(i) / refRate + jitter())))
                i += n
            }
        }
        events.sort { $0.deliveredAt < $1.deliveredAt }

        let pipe = EchoCancellationPipeline(configuration: config)
        for e in events {
            if e.isMic { pipe.pushMic(e.chunk) } else { pipe.pushReference(e.chunk) }
        }
        pipe.finish()
        var chunks: [PCMChunk] = []
        for await c in pipe.output { chunks.append(c) }
        return Simulation(chunks: chunks, stats: pipe.stats)
    }

    private func erle(raw: [Float], out: [Float], seconds: ClosedRange<Double>) -> Double {
        let r = Int(seconds.lowerBound * fs)..<Int(seconds.upperBound * fs)
        return TestSignals.db(TestSignals.energy(raw[r]) / TestSignals.energy(out[r]))
    }

    // MARK: - Echo removal

    func testCancelsReverberantEchoAndFindsDelay() async {
        let far = TestSignals.speechLike(seconds: 14, seed: 1)
        let mic = TestSignals.convolve(far, TestSignals.roomResponse(delayMs: 40, rt60: 0.4))
        let sim = await simulate(far: far, mic: mic)
        let e = erle(raw: mic, out: sim.output, seconds: 10...14)
        print("pipeline ERLE (clean clocks): \(e) dB, stats: \(sim.stats)")
        XCTAssertGreaterThan(e, 15)
        XCTAssertEqual(sim.stats.mode, .active)
        XCTAssertEqual(sim.stats.delayMs ?? -1, 40, accuracy: 1.5)
    }

    /// Separate speaker and mic devices: the speaker clock runs 100 ppm fast
    /// (worse than typical) with a little timestamp jitter. Drift must be
    /// tracked smoothly, not by repeated jumps that would break the filter.
    func testCancelsEchoDespiteClockDrift() async {
        let far = TestSignals.speechLike(seconds: 30, seed: 2)
        let mic = TestSignals.convolve(far, TestSignals.roomResponse(delayMs: 45, rt60: 0.35))
        let sim = await simulate(far: far, mic: mic, refPPM: 100, jitterMs: 0.3)
        let e = erle(raw: mic, out: sim.output, seconds: 22...30)
        print("pipeline ERLE (100 ppm drift, ±0.3 ms jitter): \(e) dB, \(sim.stats)")
        XCTAssertGreaterThan(e, 15)
        XCTAssertEqual(sim.stats.driftPPM, 100, accuracy: 15, "should measure the drift")
    }

    /// Stress: ±3 ms timestamp jitter (far noisier than real device timestamps)
    /// plus drift. Cancellation degrades but must not collapse or misbehave.
    func testDegradesGracefullyUnderExtremeTimestampJitter() async {
        let far = TestSignals.speechLike(seconds: 30, seed: 2)
        let mic = TestSignals.convolve(far, TestSignals.roomResponse(delayMs: 45, rt60: 0.35))
        let sim = await simulate(far: far, mic: mic, refPPM: 100, jitterMs: 3)
        let e = erle(raw: mic, out: sim.output, seconds: 22...30)
        print("pipeline ERLE (100 ppm drift, ±3 ms jitter): \(e) dB")
        XCTAssertGreaterThan(e, 5)
        XCTAssertEqual(sim.stats.slips, 0, "jitter must not trigger hard resyncs")
    }

    // MARK: - Pass-through guarantees

    /// Every input chunk comes back once, same timestamp and length.
    func testPreservesChunkCountsAndTimestamps() async {
        let far = TestSignals.speechLike(seconds: 6, seed: 4)
        let mic = TestSignals.convolve(far, TestSignals.roomResponse(delayMs: 30, rt60: 0.2))
        let sim = await simulate(far: far, mic: mic)
        var expected: [(Double, Int)] = []
        var i = 0
        while i < mic.count { let n = min(1365, mic.count - i); expected.append((Double(i) / fs, n)); i += n }
        XCTAssertEqual(sim.chunks.count, expected.count)
        for (c, e) in zip(sim.chunks, expected) {
            XCTAssertEqual(c.timestamp, e.0, accuracy: 1e-9)
            XCTAssertEqual(c.samples.count, e.1)
        }
    }

    /// System tap unavailable → the mic is untouched (bit-identical).
    func testNoReferenceIsBitIdentical() async {
        let mic = TestSignals.speechLike(seconds: 5, seed: 9)
        let sim = await simulate(far: mic, mic: mic, sendReference: false)
        XCTAssertEqual(sim.output, mic)
        XCTAssertEqual(sim.stats.mode, .noReference)
    }

    /// Headphones: the reference plays but the mic never hears it. After the
    /// no-coupling window the mic passes through unchanged.
    func testHeadphonesGoToBypassWithoutTouchingTheMic() async {
        let far = TestSignals.speechLike(seconds: 50, seed: 11)
        let user = TestSignals.speechLike(seconds: 50, seed: 12)
        var cfg = EchoCancellationPipeline.Configuration()
        cfg.noCouplingSeconds = 20                 // keep the simulation short
        let sim = await simulate(far: far, mic: user, config: cfg)
        XCTAssertEqual(sim.stats.mode, .bypass)
        let r = Int(40 * fs)..<Int(50 * fs)
        XCTAssertEqual(Array(sim.output[r]), Array(user[r]), "bypass must hand the mic through bit-for-bit")
        // Even before the decision, speech must not be materially damaged.
        let early = erle(raw: user, out: sim.output, seconds: 2...15)
        print("headphones, near-end change before bypass: \(early) dB")
        XCTAssertLessThan(abs(early), 3)
    }

    /// If the reference stops arriving, the mic is not held up indefinitely.
    func testDoesNotStallWhenReferenceStops() async throws {
        let far = TestSignals.speechLike(seconds: 4, seed: 21)
        let mic = TestSignals.speechLike(seconds: 8, seed: 22)
        let pipe = EchoCancellationPipeline()
        pipe.pushReference(PCMChunk(samples: Array(far[0..<16000]), timestamp: 0))   // 1 s of reference only
        var i = 0
        while i + 1365 <= mic.count {
            pipe.pushMic(PCMChunk(samples: Array(mic[i..<(i + 1365)]), timestamp: Double(i) / fs)); i += 1365
        }
        let collector = Task { () -> Int in var n = 0; for await _ in pipe.output { n += 1 }; return n }
        try await Task.sleep(for: .seconds(1.5))      // well past maxReferenceWait
        pipe.finish()
        let emitted = await collector.value
        XCTAssertEqual(emitted, i / 1365, "every mic chunk must come out even though reference stopped")
    }
}
