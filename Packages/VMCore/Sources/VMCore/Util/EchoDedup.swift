import Foundation

/// Removes the *other party's* echo from the user's ("You" / mic) channel.
///
/// When the user isn't wearing headphones, the system audio (others' voices)
/// plays out of the speakers and bleeds into the microphone, so the mic
/// transcription ends up containing echoed copies of what the other side said —
/// which is why the "You" transcript looks garbled and duplicated.
///
/// The system-tap channel captures that same audio cleanly (it is tapped
/// *before* the speakers), so we can use it as ground truth: mic text that
/// reproduces, in order, words the system channel heard at about the same time
/// is an echo. System ("Others") segments are the reference and are never
/// dropped.
///
/// This is the *safety net*; the primary fix is acoustic echo cancellation of
/// the mic feed before it reaches Whisper (see `VMRecording`). Text-level
/// matching still matters because no canceller removes everything.
public enum EchoDedup {

    public struct Config: Sendable {
        /// Mic segments are compared against system words within this many
        /// seconds either side of the segment. The two channels are transcribed
        /// in separate sliding windows so segment boundaries drift.
        public var window: TimeInterval = 4.0
        /// A mic word may pair with a system word at most this far *after* it
        /// (echo trails its source: acoustic delay plus window skew) …
        public var lagTolerance: TimeInterval = 3.0
        /// … and at most this far *before* it. Physically an echo cannot precede
        /// its source, but the two channels are transcribed in independent
        /// sliding windows and Whisper's segment timestamps drift by seconds, so
        /// real echoes routinely appear to lead. Measured on recorded meetings:
        /// tightening this to 1.5 s let clearly-echoed lines through, so it is
        /// deliberately symmetric.
        public var leadTolerance: TimeInterval = 3.0
        /// Fraction of a mic segment's words that must align (in order) with
        /// system words for the segment to be dropped (segments of 5+ words).
        public var coverageThreshold: Double = 0.6
        /// Stricter threshold for 3–4 word segments, which match by chance more
        /// easily.
        public var shortCoverageThreshold: Double = 0.7
        /// Same, but counting only content words (not "the", "and", …).
        public var contentCoverageThreshold: Double = 0.6
        /// Segments with fewer words go through the (very conservative)
        /// fragment rule instead.
        public var minWords: Int = 3
        /// A run of echoed words inside an otherwise genuine segment is trimmed
        /// out when it is at least this many tokens long …
        public var trimMinRun: Int = 4
        /// … tolerates at most this many unmatched tokens between matches …
        public var trimMaxGap: Int = 2
        /// … and at least this fraction of the run matched.
        public var trimDensity: Double = 0.75
        /// 1–2 word fragments are only dropped when their system twin is this
        /// close in time.
        public var fragmentTolerance: TimeInterval = 1.0
        /// Use the original single-segment containment algorithm. Appropriate
        /// when acoustic cancellation reports "no echo path" (headphones), where
        /// the aggressive matcher has nothing to catch and only risks dropping
        /// genuine speech.
        public var legacy: Bool = false

        public init() {}

        public static let `default` = Config()

        public static var conservative: Config {
            var c = Config()
            c.legacy = true
            return c
        }
    }

    public static func suppress(
        _ segments: [TranscriptSegment],
        config: Config = .default
    ) -> [TranscriptSegment] {
        if config.legacy { return suppressLegacy(segments) }

        var stream: [SystemToken] = []
        var order = 0
        for seg in segments where seg.channel == .system {
            let toks = TextSimilarity.tokens(seg.text)
            guard !toks.isEmpty else { continue }
            let dur = max(seg.end - seg.start, 0)
            for (i, t) in toks.enumerated() {
                let time = seg.start + dur * (Double(i) + 0.5) / Double(toks.count)
                stream.append(SystemToken(text: t, time: time, order: order))
                order += 1
            }
        }
        guard !stream.isEmpty else { return segments }
        // Tie-break on original order: zero-length segments give every token
        // the same time, and the sequence must survive for LCS to mean anything.
        stream.sort { ($0.time, $0.order) < ($1.time, $1.order) }

        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            guard seg.channel == .mic else { out.append(seg); continue }
            if let kept = filterMic(seg, stream: stream, config: config) {
                out.append(kept)
            }
        }
        return out
    }

    // MARK: - Internals

    private struct SystemToken {
        let text: String
        let time: TimeInterval
        let order: Int
    }

    /// Returns the (possibly trimmed) segment to keep, or `nil` to drop it.
    private static func filterMic(
        _ seg: TranscriptSegment,
        stream: [SystemToken],
        config: Config
    ) -> TranscriptSegment? {
        let mic = TextSimilarity.tokenRanges(seg.text)
        let n = mic.count
        guard n > 0 else { return seg }

        let window = slice(stream, from: seg.start - config.window, to: seg.end + config.window)
        guard !window.isEmpty else { return seg }

        // 1–2 word fragments: nearly always keep.
        if n < config.minWords {
            return isEchoFragment(mic.map(\.token), seg: seg, window: window, config: config) ? nil : seg
        }

        let dur = max(seg.end - seg.start, 0)
        let align = TextSimilarity.lcsAlignment(micCount: n, sysCount: window.count) { i, j in
            let micTime = seg.start + dur * (Double(i) + 0.5) / Double(n)
            let lag = micTime - window[j].time          // >0: mic trails system
            return lag <= config.lagTolerance && -lag <= config.leadTolerance
                && TextSimilarity.fuzzyEqual(mic[i].token, window[j].text)
        }
        let matched = align.map { $0 != nil }

        // A segment made only of function words ("i think that we should") is
        // never treated as echo: it would match almost anything.
        let contentIdx = mic.indices.filter { isContent(mic[$0].token) }
        guard !contentIdx.isEmpty else { return seg }

        let coverage = Double(matched.filter { $0 }.count) / Double(n)
        let contentCoverage = Double(contentIdx.filter { matched[$0] }.count) / Double(contentIdx.count)
        let threshold = n <= 4 ? config.shortCoverageThreshold : config.coverageThreshold
        if coverage >= threshold && contentCoverage >= config.contentCoverageThreshold {
            return nil
        }

        return trimmed(seg, mic: mic, matched: matched, config: config)
    }

    /// Cuts echoed runs out of a segment that also contains genuine speech
    /// (the user talking over the other party), keeping the user's own words.
    private static func trimmed(
        _ seg: TranscriptSegment,
        mic: [(token: String, range: Range<String.Index>)],
        matched: [Bool],
        config: Config
    ) -> TranscriptSegment? {
        let n = mic.count
        var spans: [(first: Int, last: Int)] = []
        var i = 0
        while i < n {
            guard matched[i] else { i += 1; continue }
            var last = i
            var j = i + 1
            var gap = 0
            while j < n {
                if matched[j] { last = j; gap = 0 }
                else { gap += 1; if gap > config.trimMaxGap { break } }
                j += 1
            }
            let length = last - i + 1
            let hits = (i...last).filter { matched[$0] }
            let density = Double(hits.count) / Double(length)
            if length >= config.trimMinRun,
               density >= config.trimDensity,
               hits.contains(where: { isContent(mic[$0].token) }) {
                spans.append((i, last))
            }
            i = last + 1
        }
        guard !spans.isEmpty else { return seg }

        let removed = spans.reduce(0) { $0 + ($1.last - $1.first + 1) }
        guard n - removed >= 2 else { return nil }

        var pieces: [Substring] = []
        var cursor = seg.text.startIndex
        for span in spans {
            pieces.append(seg.text[cursor..<mic[span.first].range.lowerBound])
            cursor = mic[span.last].range.upperBound
        }
        pieces.append(seg.text[cursor...])
        let text = pieces
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        guard !text.isEmpty else { return nil }

        let dur = max(seg.end - seg.start, 0)
        let leading = spans.first!.first == 0 ? spans.first!.last + 1 : 0
        let trailing = spans.last!.last == n - 1 ? n - spans.last!.first : 0
        var s = seg
        s.text = text
        s.start = seg.start + dur * Double(leading) / Double(n)
        s.end = seg.end - dur * Double(trailing) / Double(n)
        // Per-word timings no longer line up with the trimmed text.
        s.words = nil
        return s
    }

    /// A 1–2 word mic fragment is only called echo when every word is a
    /// distinctive (content, ≥4 letter, non-backchannel) word that the system
    /// channel said, verbatim, within about a second.
    private static func isEchoFragment(
        _ tokens: [String],
        seg: TranscriptSegment,
        window: [SystemToken],
        config: Config
    ) -> Bool {
        let lo = seg.start - config.fragmentTolerance
        let hi = seg.end + config.fragmentTolerance
        for t in tokens {
            guard t.count >= 4, isContent(t) else { return false }
            let heard = window.contains { $0.text == t && $0.time >= lo && $0.time <= hi }
            if !heard { return false }
        }
        return !tokens.isEmpty
    }

    /// Binary-searched window of the time-sorted system stream.
    private static func slice(
        _ stream: [SystemToken],
        from lo: TimeInterval,
        to hi: TimeInterval
    ) -> [SystemToken] {
        var a = 0, b = stream.count
        while a < b {                       // first index with time >= lo
            let mid = (a + b) / 2
            if stream[mid].time < lo { a = mid + 1 } else { b = mid }
        }
        var end = a
        while end < stream.count && stream[end].time <= hi { end += 1 }
        // A real Array (zero-based): callers index it with 0..<count.
        return Array(stream[a..<end])
    }

    private static func isContent(_ token: String) -> Bool {
        token.count > 1 && !functionWords.contains(token)
    }

    /// Function words, fillers and backchannel. These carry little meaning, so
    /// they can't by themselves justify calling a segment an echo, and a
    /// fragment made of them is always kept.
    private static let functionWords: Set<String> = [
        // articles / pronouns / auxiliaries / prepositions / conjunctions
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "than", "as",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "she", "it", "its",
        "they", "them", "their", "this", "that", "these", "those", "there", "here",
        "is", "am", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "will", "would", "should", "could", "can", "may", "might",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into",
        "not", "no", "what", "which", "who", "how", "when", "where", "why", "s", "t",
        // discourse fillers
        "think", "know", "mean", "just", "like", "really", "very", "well", "now",
        "um", "uh", "er", "oh", "ah", "hmm", "mm", "mhm",
        // backchannel
        "yeah", "yes", "yep", "yup", "nope", "right", "okay", "ok", "sure", "exactly",
        "absolutely", "definitely", "totally", "great", "good", "cool", "nice",
        "perfect", "alright", "thanks", "thank", "bye", "hello", "hi", "hey",
    ]

    // MARK: - Legacy (conservative) algorithm

    /// The original algorithm: drop a mic segment only if ≥80% of its words
    /// appear in a *single* time-overlapping system segment that is at least as
    /// wordy.
    private static func suppressLegacy(
        _ segments: [TranscriptSegment],
        timeTolerance: TimeInterval = 1.5,
        containmentThreshold: Double = 0.8,
        minWords: Int = 3
    ) -> [TranscriptSegment] {
        let systemSegs = segments
            .filter { $0.channel == .system }
            .sorted { $0.start < $1.start }
        guard !systemSegs.isEmpty else { return segments }

        return segments.filter { seg in
            guard seg.channel == .mic else { return true }

            let micTokens = TextSimilarity.tokens(seg.text)
            guard micTokens.count >= minWords else { return true }

            for sys in systemSegs {
                if sys.start > seg.end + timeTolerance { break }

                let overlaps = sys.start < seg.end + timeTolerance
                    && sys.end + timeTolerance > seg.start
                guard overlaps else { continue }

                // Echo can only *lose* words versus its clean source, so the
                // source must be at least as wordy as the mic copy.
                let sysTokens = TextSimilarity.tokens(sys.text)
                guard sysTokens.count >= micTokens.count else { continue }

                if TextSimilarity.containment(seg.text, sys.text) >= containmentThreshold {
                    return false
                }
            }
            return true
        }
    }
}
