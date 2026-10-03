import Foundation
import VMCore

/// What the echo canceller is currently doing, for diagnostics and UI.
public struct EchoCancellationStats: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable {
        /// No reference audio (system tap unavailable): mic passes through untouched.
        case noReference
        /// Reference present but no echo path found (headphones): mic passes through untouched.
        case bypass
        /// Echo path found: the cancelled mic is what gets transcribed.
        case active
    }

    public var mode: Mode = .noReference
    /// Committed speaker→mic bulk delay, in milliseconds.
    public var delayMs: Double?
    /// Peak-to-mean confidence of the last delay estimate (≥ ~10 means a real echo path).
    public var delayConfidence: Double = 0
    /// Median echo-return-loss-enhancement over the last ~10 s of reference-active audio, dB.
    public var erleDB: Double?
    /// Relative clock drift between speaker and mic devices, parts per million.
    public var driftPPM: Double = 0
    /// Hard re-synchronisations after large timeline jumps (drift itself is tracked smoothly).
    public var slips: Int = 0
    /// Times the mic had to be processed without up-to-date reference audio.
    public var referenceUnderruns: Int = 0
    public var referenceGaps: Int = 0
    public var framesProcessed: Int = 0
    /// Times the adaptive filter was thrown away (delay moved, timeline jumped, device changed).
    public var filterResets: Int = 0
    /// Number of distinct bulk-delay commits.
    public var delayCommits: Int = 0
    /// RMS disagreement (in samples) between the timestamp-derived reference
    /// position and the smoothed read position — how noisy the clocks are.
    public var alignErrorRMS: Double = 0
    /// Seconds of audio processed in each mode.
    public var activeSeconds: Double = 0
    public var bypassSeconds: Double = 0

    public init() {}
}

/// Real-time acoustic echo cancellation of the microphone feed that goes to the
/// transcriber, using the system-audio tap as the far-end reference.
///
/// The app captures the meeting's far-end audio *before* it reaches the
/// speakers (the tap), and the mic hears that same audio again through the
/// room. That makes this a textbook AEC problem with a perfect reference —
/// the one thing missing is that the app never renders the far-end through its
/// own output, so Apple's built-in voice processing can't do it. Instead the two
/// streams are aligned by timestamp here and fed to SpeexDSP's echo canceller.
///
/// Contract:
///  * One output chunk per input mic chunk, with the same timestamp and sample
///    count (the downstream sliding-window transcriber counts samples).
///  * Never blocks the mic: if the reference is late or absent, it waits at most
///    `maxReferenceWait`, then processes anyway (or passes the mic through).
///  * Headphones (no echo path) → output is the untouched mic.
///  * The raw mic is still recorded to disk elsewhere; this only changes what
///    the transcriber hears.
public final class EchoCancellationPipeline: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var frameSize = 256                 // 16 ms @ 16 kHz
        public var tailLength = 4096               // 256 ms echo-path model
        public var maxReferenceWait: TimeInterval = 0.25
        /// Delay-estimate confidence needed to call it a real echo path.
        public var minDelayConfidence = 10.0
        /// Seconds of reference-active audio with no echo path found before
        /// concluding "headphones" and passing the mic through untouched.
        public var noCouplingSeconds = 30.0
        public var residualSuppression = true
        public var crossfadeSeconds = 0.05
        /// Seconds between delay estimates.
        public var estimateInterval = 1.0
        public init() {}
    }

    /// Cancelled mic audio, one chunk per pushed mic chunk.
    public let output: AsyncStream<PCMChunk>

    private let cfg: Configuration
    private let continuation: AsyncStream<PCMChunk>.Continuation
    private let queue = DispatchQueue(label: "vibe.aec", qos: .userInitiated)
    private let fs = PCMChunk.sampleRate

    private let aligner = ReferenceAligner()
    private let canceller: SpeexEchoCanceller
    private let estimator = DelayEstimator()

    // Mic side
    private var micClock = SampleClock(maxPoints: 300)
    private var micSamples: [Float] = []
    private var micHead = 0
    private var micTotal = 0                      // global index one past newest pushed sample
    private var micProcessed = 0                  // global index of next sample to process
    private var history: [Float] = []             // recent raw mic, for delay estimation
    private var historyBase = 0
    private var pending: [(timestamp: TimeInterval, count: Int)] = []
    private var outBuf: [Float] = []
    private var outHead = 0

    // Reference alignment
    /// Reference position (global sample index, fractional) aligned with the
    /// start of the next mic frame. Tracked by a first-order loop, see `alignReference`.
    private var readPos: Double = 0
    private var readInit = false
    private var alignErrSq = 0.0
    private var alignErrN = 0
    private var appliedDelay: TimeInterval = 0
    private var committedDelaySamples: Int?
    private var recentEstimates: [Int] = []

    // Mode / mixing
    private var mode: EchoCancellationStats.Mode = .active
    private var mixWeight: Float = 0              // 0 = raw mic … 1 = cancelled
    private var refActiveSecondsWithoutEcho = 0.0
    private var waitStart: UInt64?
    private var startWait: UInt64?
    private var fallbackScheduled = false
    private var framesSinceEstimate = 0

    // Frame scratch
    private var micFrame: [Float]
    private var refFrame: [Float]
    private var aecFrame: [Float]
    private var erleRing: [Float] = []

    // Stats
    private let statsLock = NSLock()
    private var _stats = EchoCancellationStats()
    private var stat = EchoCancellationStats()

    public init(configuration: Configuration = .init()) {
        self.cfg = configuration
        (output, continuation) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        canceller = SpeexEchoCanceller(
            frameSize: configuration.frameSize,
            tailLength: configuration.tailLength,
            sampleRate: Int(PCMChunk.sampleRate),
            residualSuppression: configuration.residualSuppression
        )
        micFrame = [Float](repeating: 0, count: configuration.frameSize)
        refFrame = micFrame
        aecFrame = micFrame
    }

    // MARK: - Public API

    public func pushMic(_ chunk: PCMChunk) {
        queue.async { self.handleMic(chunk) }
    }

    public func pushReference(_ chunk: PCMChunk) {
        queue.async {
            self.aligner.append(chunk)
            self.drain()
        }
    }

    /// Call after switching the microphone: the echo path changed.
    public func resetForDeviceChange() {
        queue.async {
            self.micClock.reset()
            self.resetFilter()
            self.readInit = false
            self.recentEstimates.removeAll()
            self.committedDelaySamples = nil
            self.appliedDelay = 0
        }
    }

    /// Process whatever is buffered, emit the final chunks and end `output`.
    public func finish() {
        queue.sync {
            self.drain(flushing: true)
            self.publishStats()
            self.continuation.finish()
        }
    }

    /// Block until everything pushed so far has been processed (for tests and
    /// offline tools that want to sample `stats` at known points).
    public func waitUntilIdle() {
        queue.sync {}
    }

    public var stats: EchoCancellationStats {
        statsLock.lock(); defer { statsLock.unlock() }
        return _stats
    }

    // MARK: - Mic ingest

    private func handleMic(_ chunk: PCMChunk) {
        guard !chunk.samples.isEmpty else { return }
        if startWait == nil { startWait = DispatchTime.now().uptimeNanoseconds }

        if micClock.isValid {
            let err = chunk.timestamp - micClock.time(at: Double(micTotal))
            if abs(err) > 0.05 {
                // Mic timeline jumped (engine restart, device change): the old
                // echo-path estimate and clock fit are stale.
                micClock.reset()
                resetFilter()
                readInit = false
            }
        }
        micClock.add(index: micTotal, time: chunk.timestamp)
        micSamples.append(contentsOf: chunk.samples)
        history.append(contentsOf: chunk.samples)
        micTotal += chunk.samples.count
        pending.append((chunk.timestamp, chunk.samples.count))

        let keep = Int(3.5 * fs)
        if history.count > keep + Int(fs) {
            let drop = history.count - keep
            history.removeFirst(drop)
            historyBase += drop
        }
        drain()
    }

    // MARK: - Processing

    private func drain(flushing: Bool = false) {
        let f = cfg.frameSize
        while true {
            let avail = micTotal - micProcessed
            if avail <= 0 { break }
            if avail < f && !flushing { break }

            let count = min(avail, f)
            let frameStartIndex = micProcessed
            let frameTime = micClock.isValid ? micClock.time(at: Double(frameStartIndex)) : 0

            // Decide whether we can run, must wait for reference, or pass through.
            if !aligner.hasData {
                if !flushing, let s = startWait, elapsed(since: s) < cfg.maxReferenceWait {
                    scheduleFallback()
                    break                           // still hoping a reference shows up
                }
                mode = .noReference
            } else {
                if mode == .noReference { mode = .active }          // reference arrived late
                let needed = frameTime + Double(f) / fs - appliedDelay
                if aligner.newestTime < needed && !flushing {
                    if waitStart == nil { waitStart = DispatchTime.now().uptimeNanoseconds }
                    if elapsed(since: waitStart!) < cfg.maxReferenceWait {
                        scheduleFallback()
                        break                       // reference for this frame hasn't arrived yet
                    }
                    stat.referenceUnderruns += 1    // give up waiting: zero-fill the missing tail
                }
                waitStart = nil
            }

            // Pull the frame.
            for i in 0..<f {
                let li = micHead + i
                micFrame[i] = (i < count && li < micSamples.count) ? micSamples[li] : 0
            }

            if mode == .noReference {
                for i in 0..<f { aecFrame[i] = micFrame[i] }
            } else {
                alignReference(frameTime: frameTime)
                micFrame.withUnsafeBufferPointer { m in
                    refFrame.withUnsafeBufferPointer { r in
                        aecFrame.withUnsafeMutableBufferPointer { o in
                            canceller.process(mic: m.baseAddress!, reference: r.baseAddress!, out: o.baseAddress!)
                        }
                    }
                }
                recordERLE()
            }

            mixAndEmit(count: count)

            micHead += count
            micProcessed += count
            if micHead > 16384 {
                micSamples.removeFirst(micHead)
                micHead = 0
            }
            stat.framesProcessed += 1
            if mode == .active { stat.activeSeconds += Double(count) / fs } else { stat.bypassSeconds += Double(count) / fs }

            framesSinceEstimate += 1
            if framesSinceEstimate >= Int(cfg.estimateInterval * fs) / f {
                framesSinceEstimate = 0
                runDelayEstimation()
                publishStats()
            }
        }
        emitCompleteChunks()
    }

    /// Position the reference read pointer for this mic frame.
    ///
    /// The mic and the speaker/tap run on separate device clocks, so the
    /// reference position drifts relative to the mic by tens of ppm, and every
    /// timestamp carries a little jitter. Rather than snapping to the noisy
    /// timestamp (which makes the alignment jump around and breaks the adaptive
    /// filter), this is a first-order tracking loop:
    ///  * feed-forward: advance by `frame × (refRate / micRate)` using the
    ///    long-window clock fits, which follows steady drift smoothly;
    ///  * feedback: nudge toward the timestamp-derived position by a small
    ///    fraction of the error each frame, which low-passes the jitter.
    /// The frame is then read with sub-sample interpolation.
    private func alignReference(frameTime: TimeInterval) {
        let f = cfg.frameSize
        let desired = aligner.globalIndex(at: frameTime - appliedDelay)
        let ratio = min(1.002, max(0.998, aligner.clock.rate / micClock.rate))
        if !readInit {
            readPos = desired
            readInit = true
        } else {
            let err = desired - readPos
            alignErrSq += err * err
            alignErrN += 1
            if abs(err) > 64 {
                // Big discontinuity (≥4 ms): re-sync and relearn the path.
                readPos = desired
                resetFilter()
                stat.slips += 1
            } else {
                readPos += 0.03 * err
            }
        }
        refFrame.withUnsafeMutableBufferPointer {
            aligner.readInterpolated(from: readPos, step: ratio, count: f, into: $0.baseAddress!)
        }
        readPos += Double(f) * ratio
    }

    /// Crossfade between raw mic and cancelled mic according to `mode`.
    private func mixAndEmit(count: Int) {
        let target: Float = (mode == .active) ? 1 : 0
        let step = 1 / Float(max(1, cfg.crossfadeSeconds * fs))
        for i in 0..<count {
            if mixWeight < target { mixWeight = min(target, mixWeight + step) }
            else if mixWeight > target { mixWeight = max(target, mixWeight - step) }
            let raw = micFrame[i]
            let sample: Float
            if mixWeight <= 0 { sample = raw }
            else if mixWeight >= 1 { sample = aecFrame[i] }
            else { sample = raw * (1 - mixWeight) + aecFrame[i] * mixWeight }
            outBuf.append(sample)
        }
    }

    private func emitCompleteChunks() {
        while let head = pending.first, outBuf.count - outHead >= head.count {
            let slice = Array(outBuf[outHead..<(outHead + head.count)])
            continuation.yield(PCMChunk(samples: slice, timestamp: head.timestamp))
            outHead += head.count
            pending.removeFirst()
        }
        if outHead > 16384 {
            outBuf.removeFirst(outHead)
            outHead = 0
        }
    }

    private func scheduleFallback() {
        guard !fallbackScheduled else { return }
        fallbackScheduled = true
        queue.asyncAfter(deadline: .now() + cfg.maxReferenceWait + 0.01) { [self] in
            fallbackScheduled = false
            drain()
        }
    }

    private func elapsed(since nanos: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- nanos) / 1e9
    }

    // MARK: - Delay estimation / mode decision

    private func runDelayEstimation() {
        let L = estimator.micLength
        guard aligner.hasData, micClock.isValid, micProcessed - L >= historyBase else { return }
        let micStart = micProcessed - L
        let lo = micStart - historyBase
        guard lo >= 0, lo + L <= history.count else { return }
        let micWindow = Array(history[lo..<(lo + L)])

        let t0 = micClock.time(at: Double(micStart))
        let refStart = Int(aligner.globalIndex(at: t0 - Double(estimator.preSamples) / fs).rounded())
        var refWindow = [Float](repeating: 0, count: estimator.refLength)
        refWindow.withUnsafeMutableBufferPointer { aligner.read(from: refStart, count: estimator.refLength, into: $0.baseAddress!) }

        // Only learn from windows where the far end was actually talking.
        let block = 320
        var active = 0, blocks = 0
        var i = estimator.preSamples
        while i + block <= estimator.preSamples + L {
            var e: Float = 0
            for k in i..<(i + block) { e += refWindow[k] * refWindow[k] }
            if (e / Float(block)).squareRoot() > 0.00316 { active += 1 }   // −50 dBFS
            blocks += 1
            i += block
        }
        guard blocks > 0, Double(active) / Double(blocks) >= 0.5 else { return }

        guard let result = estimator.estimate(mic: micWindow, ref: refWindow) else { return }
        stat.delayConfidence = result.confidence

        if result.confidence >= cfg.minDelayConfidence {
            refActiveSecondsWithoutEcho = 0
            recentEstimates.append(result.delaySamples)
            if recentEstimates.count > 5 { recentEstimates.removeFirst() }
            commitDelayIfStable()
        } else {
            refActiveSecondsWithoutEcho += cfg.estimateInterval
        }

        // No echo path for long enough while the far end talks → headphones.
        let wanted: EchoCancellationStats.Mode = refActiveSecondsWithoutEcho >= cfg.noCouplingSeconds ? .bypass : .active
        if mode != .noReference { mode = wanted }
    }

    /// Commit a new bulk delay when 3 of the last 5 estimates agree within 1 ms.
    private func commitDelayIfStable() {
        guard recentEstimates.count >= 3 else { return }
        let tolerance = Int(0.001 * fs)
        for candidate in recentEstimates.reversed() {
            let cluster = recentEstimates.filter { abs($0 - candidate) <= tolerance }
            guard cluster.count >= 3 else { continue }
            let median = cluster.sorted()[cluster.count / 2]
            if let committed = committedDelaySamples, abs(median - committed) <= Int(0.0005 * fs) { return }
            committedDelaySamples = median
            stat.delayCommits += 1
            // Leave a little slack before the echo so the filter's early taps
            // can still model the direct path. Deliberately *not* clamped at
            // zero: a negative lag (reference timestamped later than the mic
            // frame it caused — a systematic timestamp offset between the two
            // capture paths) means the filter, which is causal, must be handed
            // reference audio from slightly in the future of the mic frame.
            let newApplied = min(0.6, max(-0.05, Double(median) / fs - 0.005))
            let moved = abs(newApplied - appliedDelay)
            appliedDelay = newApplied
            readInit = false                     // re-sync the read pointer immediately
            if moved > 0.004 { resetFilter() }
            return
        }
    }

    private func resetFilter() {
        canceller.reset()
        stat.filterResets += 1
    }

    private func recordERLE() {
        var micE: Float = 0, refE: Float = 0, outE: Float = 0
        for i in 0..<cfg.frameSize {
            micE += micFrame[i] * micFrame[i]
            refE += refFrame[i] * refFrame[i]
            outE += aecFrame[i] * aecFrame[i]
        }
        let n = Float(cfg.frameSize)
        guard (refE / n).squareRoot() > 0.00316, micE > 0 else { return }   // reference active only
        let erle = 10 * log10f((micE + 1e-9) / (outE + 1e-9))
        erleRing.append(max(-10, min(60, erle)))
        if erleRing.count > 625 { erleRing.removeFirst(erleRing.count - 625) }
    }

    private func publishStats() {
        var s = stat
        s.mode = mode
        if let d = committedDelaySamples { s.delayMs = Double(d) / fs * 1000 }
        if !erleRing.isEmpty { s.erleDB = Double(erleRing.sorted()[erleRing.count / 2]) }
        s.driftPPM = micClock.isValid && aligner.hasData ? (aligner.clock.rate / micClock.rate - 1) * 1e6 : 0
        s.referenceGaps = aligner.gapCount
        if alignErrN > 0 { s.alignErrorRMS = (alignErrSq / Double(alignErrN)).squareRoot() }
        statsLock.lock()
        _stats = s
        statsLock.unlock()
    }
}
