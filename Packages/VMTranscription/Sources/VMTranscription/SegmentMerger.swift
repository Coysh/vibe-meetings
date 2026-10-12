import Foundation
import VMCore

/// Merges streaming transcript segments from overlapping sliding windows.
///
/// The sliding-window transcriber sends the same audio through Whisper
/// multiple times (each window overlaps heavily with the previous one).
/// This merger deduplicates by treating each new batch of segments from a
/// given channel as a *replacement* for any previous segments whose time
/// range overlaps, keeping only the latest transcription of any given
/// time span.
public final class SegmentMerger: @unchecked Sendable {
    private var segments: [TranscriptSegment] = []
    private var echoConfig: EchoDedup.Config
    private var vocabulary: VocabularyCorrector?
    private let lock = NSLock()

    public init(echoConfig: EchoDedup.Config = .default) {
        self.echoConfig = echoConfig
    }

    /// Names and terms to respell wherever the model gets them slightly wrong. Applied to everything ingested
    /// from here on.
    public func setVocabulary(_ corrector: VocabularyCorrector?) {
        lock.lock(); defer { lock.unlock() }
        vocabulary = corrector?.isEmpty == true ? nil : corrector
    }

    /// Switch the echo-suppression strictness mid-recording (e.g. to
    /// `.conservative` once acoustic cancellation reports the user is on
    /// headphones and there is no echo path to catch).
    public func setEchoConfig(_ config: EchoDedup.Config) {
        lock.lock(); defer { lock.unlock() }
        echoConfig = config
    }

    /// Ingest a single segment from a streaming window.
    ///
    /// Segments from the same speaker whose time range overlaps with the
    /// incoming segment are replaced (the newer transcription is assumed
    /// to be more accurate because Whisper has more context).
    public func ingest(_ incoming: TranscriptSegment) {
        lock.lock(); defer { lock.unlock() }

        // A segment sent again with the same id replaces its earlier version — that's how the live
        // "in progress" text is rewritten as it firms up — and if the new one is empty it just goes away.
        if let existing = segments.firstIndex(where: { $0.id == incoming.id }) {
            segments.remove(at: existing)
        }

        var seg = incoming
        let text = TranscriptNoiseFilter.stripNoiseMarkers(incoming.text)
        guard !text.isEmpty else { return }
        seg.text = vocabulary?.correct(text) ?? text

        // Drop obvious noise / hallucinations at the door so they never reach
        // the live view or the merge state.
        if TranscriptNoiseFilter.isNoise(text, confidence: seg.confidence) { return }

        // Remove existing segments from the same speaker that overlap with
        // this one. "Overlap" means the existing segment's time range
        // intersects the incoming segment's range.
        segments.removeAll { existing in
            existing.speakerId == seg.speakerId
            && existing.isPartial
            && existing.start < seg.end
            && existing.end > seg.start
        }

        // Insert in sorted order by start.
        if let insertAt = segments.firstIndex(where: { $0.start > seg.start }) {
            segments.insert(seg, at: insertAt)
        } else {
            segments.append(seg)
        }
    }

    public func snapshot() -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        return segments
    }

    /// Cleaned view for the live transcript: cross-channel echo suppression and
    /// adjacent-duplicate collapsing applied, partial flags preserved so the
    /// "…" in-progress indicator still shows.
    public func displaySnapshot() -> [TranscriptSegment] {
        lock.lock(); let segs = segments; let cfg = echoConfig; lock.unlock()
        return Self.clean(segs, promoteFinal: false, echoConfig: cfg)
    }

    /// Cleaned, finalized transcript for persistence (checkpoint + stop):
    /// echo-deduped, adjacent duplicates collapsed, all partials promoted to
    /// final so a saved/recovered transcript reads cleanly.
    public func finalSnapshot() -> [TranscriptSegment] {
        lock.lock(); let segs = segments; let cfg = echoConfig; lock.unlock()
        return Self.clean(segs, promoteFinal: true, echoConfig: cfg)
    }

    public func finals() -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        return segments.filter { !$0.isPartial }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        segments.removeAll()
    }

    // MARK: - Cleanup

    /// `segments` is kept in start-sorted order by `ingest`, so a single linear
    /// pass is enough. Order of operations: echo-suppress (uses the clean system
    /// channel as reference), then collapse consecutive same-speaker duplicates
    /// that the overlapping sliding windows produced.
    private static func clean(
        _ input: [TranscriptSegment],
        promoteFinal: Bool,
        echoConfig: EchoDedup.Config
    ) -> [TranscriptSegment] {
        var out = EchoDedup.suppress(input, config: echoConfig)
        out = collapseAdjacentDuplicates(out)
        if promoteFinal {
            out = out.map { seg in
                var s = seg
                s.isPartial = false
                return s
            }
        }
        return out
    }

    /// Merge back-to-back segments from the same speaker whose text is a
    /// near-duplicate — the classic artefact of a 30 s window being
    /// re-transcribed every 5 s. Keeps the longer (more complete) text and
    /// extends the time range.
    private static func collapseAdjacentDuplicates(_ segs: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segs {
            if let last = out.last,
               last.speakerId == seg.speakerId,
               // Only collapse when the two are temporally adjacent — the
               // signature of one utterance re-emitted by overlapping windows.
               // A real pause between similar sentences leaves them distinct.
               seg.start - last.end < 2.0,
               TextSimilarity.similar(last.text, seg.text, threshold: 0.85) {
                var merged = last
                if seg.text.count > last.text.count { merged.text = seg.text }
                merged.start = min(last.start, seg.start)
                merged.end = max(last.end, seg.end)
                merged.isPartial = last.isPartial && seg.isPartial
                out[out.count - 1] = merged
            } else {
                out.append(seg)
            }
        }
        return out
    }
}
