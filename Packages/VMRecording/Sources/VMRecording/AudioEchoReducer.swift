import Accelerate
import AVFoundation
import Foundation

/// Post-processes a stereo M4A (mic=L, system=R) to reduce echo/crosstalk
/// from the system audio bleeding into the mic channel.
///
/// Uses spectral subtraction: the system channel is treated as the "noise
/// reference." For each FFT frame, magnitudes in the mic spectrum that
/// correlate with the system spectrum are attenuated. The result is a
/// cleaner mic channel with less echo.
///
/// This is a best-effort physics-limited process — it won't eliminate echo
/// perfectly but typically reduces it enough to improve transcript clarity.
public enum AudioEchoReducer {

    /// Process the audio file at `inputURL` and write a cleaned mono version
    /// to `outputURL`. Returns `true` on success.
    public static func reduceEcho(inputURL: URL, outputURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            Self.processSync(inputURL: inputURL, outputURL: outputURL)
        }.value
    }

    // MARK: - Private

    private static let fftSize = 2048
    private static let hopSize = 512

    private static func processSync(inputURL: URL, outputURL: URL) -> Bool {
        // 1. Read the stereo file.
        guard let file = try? AVAudioFile(forReading: inputURL),
              file.processingFormat.channelCount == 2 else {
            print("[EchoReducer] Input is not stereo or cannot be read")
            return false
        }

        let sampleRate = file.processingFormat.sampleRate
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else { return false }

        do {
            try file.read(into: buffer)
        } catch {
            print("[EchoReducer] Read error: \(error)")
            return false
        }

        guard let channels = buffer.floatChannelData else { return false }
        let mic = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let sys = Array(UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength)))

        // 2. Apply spectral subtraction.
        let cleaned = spectralSubtract(mic: mic, reference: sys)

        // 3. Write the cleaned mono output.
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: AVAudioFrameCount(cleaned.count)
        ) else { return false }

        outBuffer.frameLength = AVAudioFrameCount(cleaned.count)
        cleaned.withUnsafeBufferPointer { src in
            outBuffer.floatChannelData![0].update(from: src.baseAddress!, count: cleaned.count)
        }

        // Write as M4A (AAC).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let outFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try outFile.write(from: outBuffer)
            print("[EchoReducer] Wrote cleaned audio: \(cleaned.count) samples")
            return true
        } catch {
            print("[EchoReducer] Write error: \(error)")
            return false
        }
    }

    /// Spectral subtraction: for each STFT frame, subtract the reference
    /// (system audio) magnitude spectrum from the mic spectrum, then
    /// reconstruct using the mic's phase. This removes frequency content
    /// that's common to both channels (i.e., echo).
    private static func spectralSubtract(mic: [Float], reference: [Float]) -> [Float] {
        let n = min(mic.count, reference.count)
        guard n > fftSize else { return mic }

        let halfN = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return mic }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Output accumulator and normalization.
        var output = [Float](repeating: 0, count: n)
        var normalization = [Float](repeating: 0, count: n)

        // Subtraction strength: 1.0 = full subtraction, >1.0 = over-subtract for
        // more aggressive echo removal. 1.5 is a reasonable middle ground.
        let alpha: Float = 1.5

        // Spectral floor: prevents "musical noise" artefacts by ensuring the
        // result never drops below this fraction of the original magnitude.
        let beta: Float = 0.02

        // Temporary buffers.
        var micFrame = [Float](repeating: 0, count: fftSize)
        var refFrame = [Float](repeating: 0, count: fftSize)
        var micReal = [Float](repeating: 0, count: halfN)
        var micImag = [Float](repeating: 0, count: halfN)
        var refReal = [Float](repeating: 0, count: halfN)
        var refImag = [Float](repeating: 0, count: halfN)

        var frameStart = 0
        while frameStart + fftSize <= n {
            // Extract and window frames.
            for i in 0..<fftSize {
                micFrame[i] = mic[frameStart + i] * window[i]
                refFrame[i] = reference[frameStart + i] * window[i]
            }

            // Forward FFT — mic.
            micFrame.withUnsafeMutableBufferPointer { micBuf in
                micReal.withUnsafeMutableBufferPointer { rBuf in
                    micImag.withUnsafeMutableBufferPointer { iBuf in
                        var splitMic = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        micBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                            vDSP_ctoz(ptr, 2, &splitMic, 1, vDSP_Length(halfN))
                        }
                        vDSP_fft_zrip(fftSetup, &splitMic, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }

            // Forward FFT — reference.
            refFrame.withUnsafeMutableBufferPointer { refBuf in
                refReal.withUnsafeMutableBufferPointer { rBuf in
                    refImag.withUnsafeMutableBufferPointer { iBuf in
                        var splitRef = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        refBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                            vDSP_ctoz(ptr, 2, &splitRef, 1, vDSP_Length(halfN))
                        }
                        vDSP_fft_zrip(fftSetup, &splitRef, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }

            // Spectral subtraction: |cleaned| = max(|mic| - alpha * |ref|, beta * |mic|)
            // Phase is preserved from the mic channel.
            for i in 0..<halfN {
                let micMag = sqrt(micReal[i] * micReal[i] + micImag[i] * micImag[i])
                let refMag = sqrt(refReal[i] * refReal[i] + refImag[i] * refImag[i])

                let subtracted = micMag - alpha * refMag
                let floor = beta * micMag
                let cleanedMag = max(subtracted, floor)

                // Apply gain: scale mic's complex value by (cleanedMag / micMag).
                let gain = micMag > 1e-10 ? cleanedMag / micMag : 0
                micReal[i] *= gain
                micImag[i] *= gain
            }

            // Inverse FFT.
            micReal.withUnsafeMutableBufferPointer { rBuf in
                micImag.withUnsafeMutableBufferPointer { iBuf in
                    var splitCleaned = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &splitCleaned, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                    // Unpack and overlap-add.
                    micFrame.withUnsafeMutableBufferPointer { outBuf in
                        outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                            vDSP_ztoc(&splitCleaned, 1, ptr, 2, vDSP_Length(halfN))
                        }
                    }
                }
            }

            // Scale by 1/(2*fftSize) — vDSP convention.
            var scale = 1.0 / Float(2 * fftSize)
            vDSP_vsmul(micFrame, 1, &scale, &micFrame, 1, vDSP_Length(fftSize))

            // Overlap-add.
            for i in 0..<fftSize {
                output[frameStart + i] += micFrame[i] * window[i]
                normalization[frameStart + i] += window[i] * window[i]
            }

            frameStart += hopSize
        }

        // Normalize overlap-add.
        for i in 0..<n {
            if normalization[i] > 1e-8 {
                output[i] /= normalization[i]
            }
        }

        return output
    }
}
