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
    private let lock = NSLock()

    public init() {}

    /// Ingest a single segment from a streaming window.
    ///
    /// Segments from the same speaker whose time range overlaps with the
    /// incoming segment are replaced (the newer transcription is assumed
    /// to be more accurate because Whisper has more context).
    public func ingest(_ seg: TranscriptSegment) {
        lock.lock(); defer { lock.unlock() }

        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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

    public func finals() -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        return segments.filter { !$0.isPartial }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        segments.removeAll()
    }
}
