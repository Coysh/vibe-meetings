import CSpeexDSP

/// Thin Swift wrapper over SpeexDSP's MDF echo canceller plus its preprocessor
/// (which supplies the *residual* echo suppression the linear canceller can't).
///
/// Operates in fixed-size frames of 16 kHz mono audio. `mic` is the microphone
/// frame, `reference` the far-end frame that was playing out of the speakers
/// at the same moment (already delay-aligned by the caller). Not thread-safe:
/// the owner (`EchoCancellationPipeline`) only touches it from its own queue.
final class SpeexEchoCanceller: @unchecked Sendable {
    let frameSize: Int
    let tailLength: Int
    let sampleRate: Int

    private var echo: OpaquePointer?
    private var preprocess: OpaquePointer?
    private var micI16: [Int16]
    private var refI16: [Int16]
    private var outI16: [Int16]

    /// - Parameters:
    ///   - frameSize: samples per processing frame (256 = 16 ms @ 16 kHz).
    ///   - tailLength: echo-path length the adaptive filter can model, in
    ///     samples (4096 = 256 ms: direct path + early room reflections of a
    ///     desk setup; the preprocessor handles the longer reverb tail).
    ///   - residualSuppression: run SpeexDSP's preprocessor with the echo state
    ///     attached so leftover echo the linear filter missed is attenuated.
    init(frameSize: Int = 256, tailLength: Int = 4096, sampleRate: Int = 16_000, residualSuppression: Bool = true) {
        self.frameSize = frameSize
        self.tailLength = tailLength
        self.sampleRate = sampleRate
        micI16 = [Int16](repeating: 0, count: frameSize)
        refI16 = [Int16](repeating: 0, count: frameSize)
        outI16 = [Int16](repeating: 0, count: frameSize)

        echo = speex_echo_state_init(Int32(frameSize), Int32(tailLength))
        var rate = Int32(sampleRate)
        _ = speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

        if residualSuppression {
            preprocess = speex_preprocess_state_init(Int32(frameSize), Int32(sampleRate))
            var on: Int32 = 1
            var off: Int32 = 0
            // Denoise stays ON: SpeexDSP only applies its residual-echo gain
            // inside the same spectral-gain stage as noise suppression.
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &on)
            var noiseSuppress: Int32 = -8        // mild: avoid musical-noise artefacts Whisper might hallucinate on
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noiseSuppress)
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_AGC, &off)
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_VAD, &off)
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DEREVERB, &off)
            var echoSuppress: Int32 = -40
            var echoSuppressActive: Int32 = -15  // gentler while the user is talking over the far end
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &echoSuppress)
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &echoSuppressActive)
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        }
    }

    deinit {
        if let preprocess { speex_preprocess_state_destroy(preprocess) }
        if let echo { speex_echo_state_destroy(echo) }
    }

    /// Cancel the echo in one frame. All three buffers must hold `frameSize`
    /// samples (full-scale ±1.0 floats).
    func process(mic: UnsafePointer<Float>, reference: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
        for i in 0..<frameSize {
            micI16[i] = Self.toInt16(mic[i])
            refI16[i] = Self.toInt16(reference[i])
        }
        speex_echo_cancellation(echo, micI16, refI16, &outI16)
        if let preprocess {
            _ = speex_preprocess_run(preprocess, &outI16)
        }
        for i in 0..<frameSize {
            out[i] = Float(outI16[i]) / 32768
        }
    }

    /// Forget the learned echo path (call when the delay or devices change).
    func reset() {
        speex_echo_state_reset(echo)
    }

    @inline(__always)
    private static func toInt16(_ x: Float) -> Int16 {
        // Speex's API is 16-bit: clamp rather than wrap on loud input.
        Int16(max(-32768, min(32767, (x * 32768).rounded())))
    }
}
