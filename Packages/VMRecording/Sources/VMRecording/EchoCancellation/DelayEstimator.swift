import Accelerate
import Foundation
import VMCore

/// Estimates the bulk delay between the reference (what the speakers played)
/// and its echo in the microphone using GCC-PHAT cross-correlation.
///
/// Why: the adaptive filter has a finite tail (256 ms). Spending it on dead
/// time (speaker output latency + acoustic travel, typically 20–80 ms for
/// USB/wired speakers, far more over Bluetooth) leaves less for the room's
/// reverb and slows convergence. Knowing the bulk delay lets us shift the
/// reference so the filter models only the actual echo path.
///
/// PHAT weighting (whitening the cross-spectrum) gives a sharp, unambiguous
/// peak even for reverberant, band-limited speech, and the peak-to-mean ratio
/// doubles as a confidence — which is also how we tell "speakers" (strong
/// coherent peak) from "headphones" (no peak at all).
final class DelayEstimator: @unchecked Sendable {

    struct Result: Sendable {
        /// Echo lag in samples: positive = mic hears the reference this many samples late.
        let delaySamples: Int
        /// Peak-to-mean ratio of |correlation| over the search range.
        let confidence: Double
    }

    /// Mic samples analysed per estimate (2.05 s @ 16 kHz).
    let micLength: Int
    /// Largest echo lag searched, in samples (default 600 ms: covers Bluetooth).
    let maxLag: Int
    /// Most negative lag searched (reference *later* than mic, from timestamp skew).
    let minLag: Int

    /// Samples of reference required before / after the mic window.
    var preSamples: Int { maxLag }
    var postSamples: Int { -minLag }
    /// Length of the reference span the caller must supply.
    var refLength: Int { maxLag + micLength - minLag }

    private let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var xr: [Float], xi: [Float], yr: [Float], yi: [Float]
    private let loBin: Int, hiBin: Int

    init(micLength: Int = 32768, maxLagSeconds: Double = 0.6, minLagSeconds: Double = -0.05) {
        let rate = PCMChunk.sampleRate
        self.micLength = micLength
        self.maxLag = Int(maxLagSeconds * rate)
        self.minLag = Int(minLagSeconds * rate)
        var size = 1
        let needed = micLength + (maxLag - minLag)
        while size < needed { size <<= 1 }
        self.n = size
        self.log2n = vDSP_Length(size.trailingZeroBitCount)
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        xr = [Float](repeating: 0, count: size); xi = xr; yr = xr; yi = xr
        // Speech energy that survives loudspeaker + room: 200 Hz – 4 kHz.
        loBin = Int(200.0 * Double(size) / rate)
        hiBin = Int(4000.0 * Double(size) / rate)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// - Parameters:
    ///   - mic: `micLength` samples of microphone audio starting at time T0.
    ///   - ref: `refLength` samples of reference audio starting at
    ///     `T0 − maxLag/fs` (i.e. `preSamples` before the mic window).
    func estimate(mic: [Float], ref: [Float]) -> Result? {
        guard mic.count == micLength, ref.count == refLength else { return nil }

        for i in 0..<n {
            xr[i] = i < mic.count ? mic[i] : 0
            yr[i] = i < ref.count ? ref[i] : 0
            xi[i] = 0; yi[i] = 0
        }
        xr.withUnsafeMutableBufferPointer { a in xi.withUnsafeMutableBufferPointer { b in
            var s = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
            vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Forward))
        } }
        yr.withUnsafeMutableBufferPointer { a in yi.withUnsafeMutableBufferPointer { b in
            var s = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
            vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Forward))
        } }

        // Phase transform of the cross-spectrum conj(X)·Y, band-limited. The
        // result is written over X; bins outside the band (and their mirrors)
        // are zeroed.
        for k in 0..<n {
            let bin = min(k, n - k)
            guard bin >= loBin && bin <= hiBin else { xr[k] = 0; xi[k] = 0; continue }
            let cr = xr[k] * yr[k] + xi[k] * yi[k]          // Re(conj(X)·Y)
            let ci = xr[k] * yi[k] - xi[k] * yr[k]          // Im(conj(X)·Y)
            let mag = (cr * cr + ci * ci).squareRoot()
            if mag > 1e-12 { xr[k] = cr / mag; xi[k] = ci / mag } else { xr[k] = 0; xi[k] = 0 }
        }
        xr.withUnsafeMutableBufferPointer { a in xi.withUnsafeMutableBufferPointer { b in
            var s = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
            vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        } }

        // c[s] = Σ mic[i]·ref[i+s]; the ref window starts `maxLag` early, so the
        // echo lag is d = maxLag − s, for s in 0…(maxLag − minLag).
        let range = maxLag - minLag
        var peak: Float = 0
        var peakS = 0
        var sum: Float = 0
        for s in 0...range {
            let v = abs(xr[s])
            sum += v
            if v > peak { peak = v; peakS = s }
        }
        let mean = sum / Float(range + 1)
        guard mean > 0 else { return nil }
        return Result(delaySamples: maxLag - peakS, confidence: Double(peak / mean))
    }
}
