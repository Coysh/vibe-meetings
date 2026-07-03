import Foundation

/// Removes the *other party's* echo from the user's ("You" / mic) channel.
///
/// When the user isn't wearing headphones, the system audio (others' voices)
/// plays out of the speakers and bleeds into the microphone, so the mic
/// transcription ends up containing echoed copies of what the other side said —
/// which is why the "You" transcript looks garbled and duplicated.
///
/// The system-tap channel captures that same audio cleanly (it is tapped
/// *before* the speakers), so we can use it as ground truth: any mic segment
/// that overlaps in time with — and closely matches the text of — a system
/// segment is an echo and is dropped. System ("Others") segments are the
/// reference and are never dropped.
public enum EchoDedup {

    /// - Parameters:
    ///   - timeTolerance: how far apart (seconds) a mic and system segment may
    ///     sit and still be considered the same moment. Echo lags the source by
    ///     only milliseconds, but the two channels are transcribed in separate
    ///     sliding windows so their segment boundaries drift.
    ///   - similarityThreshold: minimum word-set overlap to call it an echo.
    ///   - minWords: mic segments shorter than this are kept — short
    ///     backchannel ("yeah", "right") is too easy to false-match and carries
    ///     little risk of being echo of a substantial utterance.
    public static func suppress(
        _ segments: [TranscriptSegment],
        timeTolerance: TimeInterval = 2.0,
        // Echo is the *same audio* re-recorded through the speakers, so the two
        // channels transcribe it near-identically (high overlap). A genuine
        // simultaneous agreement is paraphrased and rarely clears 0.8, so this
        // catches echo while sparing legitimate overlapping speech.
        similarityThreshold: Double = 0.8,
        minWords: Int = 3
    ) -> [TranscriptSegment] {
        let systemSegs = segments
            .filter { $0.channel == .system }
            .sorted { $0.start < $1.start }
        guard !systemSegs.isEmpty else { return segments }

        return segments.filter { seg in
            guard seg.channel == .mic else { return true }   // only the mic channel echoes

            let micTokens = TextSimilarity.tokens(seg.text)
            guard micTokens.count >= minWords else { return true }

            for sys in systemSegs {
                // systemSegs is sorted by start; once a system segment begins
                // well after this mic segment ends, no later one can overlap.
                if sys.start > seg.end + timeTolerance { break }

                let overlaps = sys.start < seg.end + timeTolerance
                    && sys.end + timeTolerance > seg.start
                if overlaps,
                   TextSimilarity.similar(seg.text, sys.text, threshold: similarityThreshold) {
                    return false   // echo of the other party — drop the mic copy
                }
            }
            return true
        }
    }
}
