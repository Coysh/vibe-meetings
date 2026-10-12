import Foundation

/// Where the speech is in a stretch of 16 kHz mono audio, from its loudness alone.
///
/// Whisper does badly on a window that's mostly silence with a few words in it: it writes "[silence]"
/// and drops the words. Knowing where speech starts and stops lets the live transcriber skip silence
/// entirely and start each decode at the first word. This is a deliberately simple energy detector (no
/// model to load, microseconds per second of audio); it only has to be right about "is anyone talking".
struct SpeechActivity {
    struct Analysis: Equatable {
        /// Seconds from the start of the audio to the first speech, or nil if there's none.
        var firstSpeech: Double?
        /// Seconds from the start of the audio to the end of the last speech.
        var lastSpeech: Double?
        /// Average level of the speech frames, in dBFS.
        var speechLevel: Float?
        /// The room's noise level if this audio had enough quiet in it to measure (dBFS), else nil.
        var measuredFloor: Float?
        /// Total time with speech in it, in seconds.
        var speechSeconds: Double = 0

        var hasSpeech: Bool { firstSpeech != nil }
    }

    static let frameSamples = 320            // 20 ms
    static let frameSeconds = 0.02
    /// Speech shorter than this is a click or a breath.
    private static let minimumSpeechFrames = 5       // 100 ms
    /// A gap shorter than this between speech is a pause between words, not silence.
    private static let bridgedGapFrames = 15         // 300 ms

    /// - Parameter noiseFloor: what earlier audio showed the room's noise to be, used when this stretch has
    ///   no quiet in it to measure (someone already talking). Without it, a stretch that's all speech looks
    ///   like it has no speech, because everything in it is "as loud as the floor".
    static func analyze(_ samples: [Float], noiseFloor: Float? = nil) -> Analysis {
        let frameCount = samples.count / frameSamples
        guard frameCount > 0 else { return Analysis() }

        var levels = [Float](repeating: -120, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var energy: Float = 0
                let base = frame * frameSamples
                for i in 0..<frameSamples {
                    let value = buffer[base + i]
                    energy += value * value
                }
                let rms = (energy / Float(frameSamples)).squareRoot()
                levels[frame] = rms > 1e-6 ? 20 * log10(rms) : -120
            }
        }

        // The room's noise floor is the quiet tenth of the audio — if there is any. A stretch whose quietest
        // tenth is louder than -50 dBFS is all speech (or a very noisy room), so fall back to what we knew
        // before, or a typical quiet room. Mistaking quiet audio for speech just costs a decode; the other
        // mistake loses words.
        let sorted = levels.sorted()
        let quietTenth = sorted[sorted.count / 10]
        let measured: Float? = quietTenth <= -50 ? max(quietTenth, -70) : nil
        let floor = measured ?? noiseFloor ?? -60
        let threshold = max(floor + 8, -55)

        var speech = levels.map { $0 > threshold }
        bridgeGaps(&speech)
        dropShortRuns(&speech)

        guard let first = speech.firstIndex(of: true), let last = speech.lastIndex(of: true) else {
            return Analysis(measuredFloor: measured)
        }
        let speechLevels = zip(levels, speech).filter { $0.1 }.map { $0.0 }
        return Analysis(
            firstSpeech: Double(first) * frameSeconds,
            lastSpeech: Double(last + 1) * frameSeconds,
            speechLevel: speechLevels.reduce(0, +) / Float(max(speechLevels.count, 1)),
            measuredFloor: measured,
            speechSeconds: Double(speechLevels.count) * frameSeconds
        )
    }

    /// Fill short gaps between speech frames.
    private static func bridgeGaps(_ flags: inout [Bool]) {
        var i = 0
        while i < flags.count {
            guard !flags[i] else { i += 1; continue }
            var j = i
            while j < flags.count, !flags[j] { j += 1 }
            let isInterior = i > 0 && j < flags.count
            if isInterior, j - i <= bridgedGapFrames {
                for k in i..<j { flags[k] = true }
            }
            i = j
        }
    }

    /// Remove speech runs too short to be words.
    private static func dropShortRuns(_ flags: inout [Bool]) {
        var i = 0
        while i < flags.count {
            guard flags[i] else { i += 1; continue }
            var j = i
            while j < flags.count, flags[j] { j += 1 }
            if j - i < minimumSpeechFrames {
                for k in i..<j { flags[k] = false }
            }
            i = j
        }
    }

    /// Bring quiet speech up to a level Whisper reads well, without amplifying a noisy room: only audio
    /// that already has speech in it, and never by more than 18 dB.
    static func normalized(_ samples: [Float], speechLevel: Float?) -> [Float] {
        guard let speechLevel, speechLevel < -30 else { return samples }
        let gainDB = min(18, -26 - speechLevel)
        guard gainDB > 1 else { return samples }
        let gain = powf(10, gainDB / 20)
        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}
