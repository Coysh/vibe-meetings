import Foundation

/// Shared filter for transcription noise and common Whisper hallucinations.
///
/// Whisper (and WhisperKit) emit predictable junk on silence, music, and
/// echo: bracketed sound descriptions (`[silence]`, `(keyboard clicking)`),
/// video-outro boilerplate ("Thanks for watching", "Please subscribe",
/// "Subtitles by the Amara.org community"), and degenerate repetition
/// ("you you you you"). This lives in `VMCore` so the live view, the saved
/// transcript, and the LLM export all filter the same way.
public enum TranscriptNoiseFilter {

    /// avgLogprob below this is treated as low-confidence. Confident speech is
    /// typically well above −1.0; silence hallucinations sit well below it.
    private static let lowConfidenceLogProb: Float = -1.0

    /// Returns `true` when `rawText` carries no meeting content and should be
    /// dropped. `confidence` is WhisperKit's `avgLogprob` (a negative log-prob,
    /// *not* 0…1) when known; pass `nil` if unavailable (older transcripts).
    public static func isNoise(_ rawText: String, confidence: Float? = nil) -> Bool {
        let lower = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return true }

        // Strip a single wrapping bracket/paren: "[silence]" -> "silence".
        let unwrapped: String
        if (lower.hasPrefix("[") && lower.hasSuffix("]"))
            || (lower.hasPrefix("(") && lower.hasSuffix(")")) {
            unwrapped = String(lower.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        } else {
            unwrapped = lower
        }
        if bracketNoise.contains(unwrapped) { return true }

        // Whole-segment normalized form (trim surrounding punctuation) so
        // "Thanks for watching!" matches "thanks for watching".
        let normalized = unwrapped
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?…–—-\"'"))

        // 1) Video-outro / subtitle-credit hallucinations essentially never
        //    occur as the sole content of a real meeting — drop unconditionally.
        if outroHallucinations.contains(normalized) { return true }

        // 2) Degenerate repetition ("you you you you", "so so so so").
        let toks = TextSimilarity.tokens(lower)
        if toks.isEmpty { return true }
        if toks.count >= 4 {
            let unique = Set(toks)
            if unique.count == 1 { return true }
            if Double(unique.count) / Double(toks.count) < 0.34 { return true }
        }

        // 3) Bare pleasantries ("thank you", "you", "bye") — Whisper fills
        //    silence with these constantly. Only drop when confidence is known
        //    and low, so a genuinely-spoken "Thank you." is preserved.
        if let c = confidence, c < lowConfidenceLogProb, barePleasantries.contains(normalized) {
            return true
        }

        return false
    }

    private static let bracketNoise: Set<String> = [
        "silence", "blank audio", "blank_audio", "no audio", "noise",
        "background noise", "static", "light wind", "wind", "bubbling",
        "keyboard clicking", "keyboard tapping", "keyboard clacking",
        "typing", "mouse clicking", "clicking", "tapping",
        "music", "music playing", "gentle music", "upbeat music",
        "inaudible", "unintelligible", "beep", "clears throat",
        "coughs", "cough", "laughter", "laughs", "sighs", "applause",
    ]

    private static let outroHallucinations: Set<String> = [
        "thanks for watching", "thank you for watching",
        "thanks for watching everyone", "thank you all for watching",
        "please subscribe", "don't forget to subscribe", "like and subscribe",
        "please like and subscribe", "subscribe to my channel",
        "see you in the next video", "see you in the next one",
        "see you next time", "see you guys next time",
        "subtitles by the amara.org community", "subtitles by amara.org",
        "amara.org", "transcription by castingwords",
        "www.mooji.org", "for more information visit www.fema.gov",
    ]

    private static let barePleasantries: Set<String> = [
        "thank you", "thank you very much", "thanks", "you", "bye",
        "bye bye", "okay bye", "goodbye", "so", "yeah", "mm hmm", "mhm",
    ]
}
