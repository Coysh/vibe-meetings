import Foundation
import VMCore

/// Interleaves segments arriving from the mic and system streams (or from re-transcribe
/// of a 2-channel file) by `start`. Replaces in-flight partials with their finals when
/// both refer to the same `(speakerId, start window)`.
public final class SegmentMerger: @unchecked Sendable {
    private var segments: [TranscriptSegment] = []
    private let lock = NSLock()

    public init() {}

    /// Inserts or updates a segment. Partials are replaced when a final covers the same
    /// `(speakerId, start)` to within `partialWindow` seconds.
    public func ingest(_ seg: TranscriptSegment) {
        lock.lock(); defer { lock.unlock() }

        if let existingIndex = segments.firstIndex(where: { existing in
            existing.speakerId == seg.speakerId
            && abs(existing.start - seg.start) < 0.5
            && existing.isPartial
        }) {
            segments[existingIndex] = seg
            return
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
