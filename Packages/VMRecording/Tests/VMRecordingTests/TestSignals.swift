import Accelerate
import Foundation

/// Deterministic signal helpers for echo-cancellation tests.
struct XorShift {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    /// Uniform in -1…1.
    mutating func uniform() -> Float { Float(Double(next() % 2_000_001) / 1_000_000.0 - 1.0) }
}

enum TestSignals {
    static let rate = 16_000

    /// Speech-like excitation: low-passed noise, amplitude-modulated at a
    /// syllable rate with pauses, so an adaptive filter sees realistic
    /// non-stationary, band-limited input.
    static func speechLike(seconds: Double, seed: UInt64, level: Float = 0.2) -> [Float] {
        var rng = XorShift(seed: seed)
        let n = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: n)
        var lp1: Float = 0, lp2: Float = 0
        var syllable: Float = 0
        for i in 0..<n {
            // new "syllable" envelope target roughly every 150–250 ms
            if i % 3200 == 0 { syllable = rng.uniform() > -0.3 ? 1 : 0.05 }
            let env = syllable * (0.6 + 0.4 * sinf(Float(i) * 2 * .pi * 4 / Float(rate)))
            let noise = rng.uniform()
            lp1 += 0.45 * (noise - lp1)     // ~ speech-ish spectral tilt
            lp2 += 0.55 * (lp1 - lp2)
            out[i] = level * env * lp2 * 3
        }
        return out
    }

    /// Room impulse response: direct path after `delayMs`, then an exponentially
    /// decaying random tail with the given RT60.
    static func roomResponse(delayMs: Double, rt60: Double, directGain: Float = 0.5, tailGain: Float = 0.25, seed: UInt64 = 7) -> [Float] {
        var rng = XorShift(seed: seed)
        let delay = Int(delayMs / 1000 * Double(rate))
        let length = delay + Int(rt60 * Double(rate))
        var h = [Float](repeating: 0, count: length)
        h[delay] = directGain
        let tau = rt60 * Double(rate) / 6.9    // 60 dB over rt60
        for k in (delay + 1)..<length {
            h[k] = tailGain * rng.uniform() * Float(exp(-Double(k - delay) / tau))
        }
        return h
    }

    /// y[n] = Σ h[k]·x[n−k], truncated to x.count.
    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        let n = x.count, m = h.count
        var padded = [Float](repeating: 0, count: m - 1) + x
        padded += [Float](repeating: 0, count: m)
        let hr = Array(h.reversed())
        var y = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, hr, 1, &y, 1, vDSP_Length(n), vDSP_Length(m))
        return y
    }

    static func energy(_ x: ArraySlice<Float>) -> Double {
        var e: Float = 0
        x.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &e, vDSP_Length($0.count)) }
        return Double(e)
    }

    static func db(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-30)) }
}
