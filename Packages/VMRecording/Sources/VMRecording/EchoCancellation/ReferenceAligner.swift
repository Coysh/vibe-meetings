import Foundation
import VMCore

/// Online linear model mapping a stream's sample index to host time.
///
/// The mic and the system tap run on different device clocks (a USB speaker and
/// a separate mic can drift by tens of ppm) and each chunk's timestamp carries
/// a little jitter. A least-squares line through recent `(index, timestamp)`
/// points averages the jitter out and tracks the drift, so we can ask "which
/// reference sample was playing when this mic sample was captured".
struct SampleClock {
    private let maxPoints: Int
    private let nominalRate: Double
    private var xs: [Double] = []          // sample index relative to `baseIndex`
    private var ys: [Double] = []          // time relative to `baseTime`
    private var baseIndex: Double = 0
    private var baseTime: Double = 0
    private var slope: Double              // seconds per sample
    private var intercept: Double = 0

    init(maxPoints: Int, nominalRate: Double = PCMChunk.sampleRate) {
        self.maxPoints = maxPoints
        self.nominalRate = nominalRate
        self.slope = 1 / nominalRate
    }

    var isValid: Bool { !xs.isEmpty }

    /// Effective samples per second (nominal until enough points to fit).
    var rate: Double { 1 / slope }

    mutating func reset() {
        xs.removeAll(keepingCapacity: true)
        ys.removeAll(keepingCapacity: true)
        slope = 1 / nominalRate
        intercept = 0
    }

    mutating func add(index: Int, time: Double) {
        if xs.isEmpty {
            baseIndex = Double(index)
            baseTime = time
        }
        xs.append(Double(index) - baseIndex)
        ys.append(time - baseTime)
        if xs.count > maxPoints {
            xs.removeFirst()
            ys.removeFirst()
        }
        refit()
    }

    func time(at index: Double) -> Double {
        baseTime + intercept + slope * (index - baseIndex)
    }

    func index(at time: Double) -> Double {
        baseIndex + (time - baseTime - intercept) / slope
    }

    private mutating func refit() {
        let n = Double(xs.count)
        let span = (xs.last ?? 0) - (xs.first ?? 0)
        // Need a long enough baseline before trusting a fitted slope; until
        // then assume the nominal rate and only fit the offset.
        if xs.count >= 16 && span >= nominalRate * 1.0 {
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for i in 0..<xs.count {
                let dx = xs[i] - mx
                sxx += dx * dx
                sxy += dx * (ys[i] - my)
            }
            if sxx > 0 {
                let nominal = 1 / nominalRate
                // Real clocks are within a few hundred ppm; clamp away fit noise.
                slope = min(nominal * 1.002, max(nominal * 0.998, sxy / sxx))
                intercept = my - slope * mx
                return
            }
        }
        slope = 1 / nominalRate
        var acc = 0.0
        for i in 0..<xs.count { acc += ys[i] - slope * xs[i] }
        intercept = acc / n
    }
}

/// Holds the far-end (system-tap) reference stream and lets the echo canceller
/// read it back *by time*, so the mic frame and the reference frame that
/// produced its echo can be lined up despite independent clocks, jitter and
/// gaps.
final class ReferenceAligner: @unchecked Sendable {
    // ~15 s of 10 ms chunks: long enough that timestamp jitter averages out.
    private(set) var clock = SampleClock(maxPoints: 1500)
    private var samples: [Float] = []
    private var baseIndex = 0               // global index of samples[0]
    private(set) var total = 0              // global index one past the newest sample
    private(set) var chunksReceived = 0
    private(set) var gapCount = 0

    /// Host time of the sample *after* the newest one held. `-inf` until data arrives.
    private(set) var newestTime: Double = -.infinity

    private let retain: Int
    private let gapThreshold: Double

    init(retainSeconds: Double = 6, gapThreshold: Double = 0.05) {
        self.retain = Int(retainSeconds * PCMChunk.sampleRate)
        self.gapThreshold = gapThreshold
    }

    var hasData: Bool { chunksReceived > 0 }

    /// Effective reference rate relative to nominal, in parts per million.
    var rateOffsetPPM: Double { (clock.rate / PCMChunk.sampleRate - 1) * 1e6 }

    func append(_ chunk: PCMChunk) {
        guard !chunk.samples.isEmpty else { return }
        if clock.isValid {
            let err = chunk.timestamp - clock.time(at: Double(total))
            if err > gapThreshold {
                // The tap stopped delivering for a while: keep the store
                // time-contiguous by filling the hole with silence.
                let missing = min(Int((err * PCMChunk.sampleRate).rounded()), Int(10 * PCMChunk.sampleRate))
                samples.append(contentsOf: [Float](repeating: 0, count: missing))
                total += missing
                gapCount += 1
            } else if err < -gapThreshold {
                // Timestamps jumped backwards (stream restart): re-anchor and
                // drop history, which no longer lines up with the new timeline.
                clock.reset()
                samples.removeAll(keepingCapacity: true)
                baseIndex = total
                gapCount += 1
            }
        }
        clock.add(index: total, time: chunk.timestamp)
        samples.append(contentsOf: chunk.samples)
        total += chunk.samples.count
        chunksReceived += 1
        newestTime = clock.time(at: Double(total))

        if samples.count > retain + Int(PCMChunk.sampleRate) {
            let drop = samples.count - retain
            samples.removeFirst(drop)
            baseIndex += drop
        }
    }

    /// Copy `count` reference samples starting at global index `from` into
    /// `out`, zero-filling anything outside what is held.
    func read(from index: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        let lo = index - baseIndex
        for k in 0..<count {
            let li = lo + k
            out[k] = (li >= 0 && li < samples.count) ? samples[li] : 0
        }
    }

    /// Read `count` samples starting at fractional global position `start`,
    /// advancing `step` reference-samples per output sample (≈1, nudged to
    /// track clock drift). Uses a polyphase windowed-sinc interpolator
    /// (`FractionalDelayTable`): accurate across the speech band and exact at
    /// integer positions. This turns drift into a smooth resampling instead of
    /// the periodic one-sample jumps that would repeatedly break the adaptive
    /// filter — and, unlike a cheap cubic, its amplitude/phase error is small
    /// enough not to show up as residual echo.
    func readInterpolated(from start: Double, step: Double, count: Int, into out: UnsafeMutablePointer<Float>) {
        let taps = FractionalDelayTable.taps
        let half = taps / 2
        let phases = FractionalDelayTable.phases
        let table = FractionalDelayTable.shared
        for k in 0..<count {
            let p = start + Double(k) * step
            let i = Int(p.rounded(.down))
            let phase = Int(((p - Double(i)) * Double(phases)).rounded())     // 0…phases
            if phase == 0 || phase == phases {
                let g = phase == 0 ? i : i + 1
                let li = g - baseIndex
                out[k] = (li >= 0 && li < samples.count) ? samples[li] : 0
                continue
            }
            var acc: Float = 0
            let row = phase * taps
            for t in 0..<taps {
                let li = i - half + 1 + t - baseIndex
                if li >= 0 && li < samples.count { acc += samples[li] * table[row + t] }
            }
            out[k] = acc
        }
    }

    /// Global index of the reference sample played at host time `time`.
    func globalIndex(at time: Double) -> Double { clock.index(at: time) }
}

/// Precomputed polyphase windowed-sinc coefficients for fractional-sample
/// delay. `table[phase * taps + t]` weights the sample at `i - taps/2 + 1 + t`
/// when reading at position `i + phase/phases`.
enum FractionalDelayTable {
    static let taps = 16
    static let phases = 256

    static let shared: [Float] = {
        var table = [Float](repeating: 0, count: (phases + 1) * taps)
        let half = taps / 2
        let cutoff = 0.92                      // fraction of Nyquist kept flat
        for ph in 0...phases {
            let frac = Double(ph) / Double(phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: taps)
            for t in 0..<taps {
                let x = Double(t - half + 1) - frac        // distance from the read point
                let sinc = x == 0 ? 1.0 : sin(Double.pi * cutoff * x) / (Double.pi * cutoff * x)
                // Blackman window across the kernel's support.
                let w = 0.42 - 0.5 * cos(2 * Double.pi * (x + Double(half)) / Double(taps))
                    + 0.08 * cos(4 * Double.pi * (x + Double(half)) / Double(taps))
                row[t] = sinc * cutoff * max(w, 0)
                sum += row[t]
            }
            for t in 0..<taps { table[ph * taps + t] = Float(row[t] / sum) }    // unity DC gain
        }
        return table
    }()
}
