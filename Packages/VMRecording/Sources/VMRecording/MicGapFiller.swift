import Foundation

/// Keeps the mic channel of the saved stereo file on the same timeline as the
/// system channel when the microphone stops delivering audio for a while
/// (e.g. the capture engine is restarting after Teams changed the output
/// device).
///
/// The writer appends audio sequentially, so without this a gap in the mic
/// would shift everything after it earlier than the system channel by the gap's
/// length. Two cooperating rules, both working in 48 kHz frames:
///
///  * **Stall padding** — while the mic is silent the system channel keeps
///    arriving. When it runs more than `stallThreshold` ahead, the mic side is
///    topped up with silence (leaving `stallHeadroom` behind) so the file keeps
///    being written, and memory stays flat during a long stall.
///  * **Gap filling** — when mic audio resumes, its host timestamp is compared
///    with where the previous buffer ended. The measured gap, minus whatever
///    stall padding already covered it, is inserted as silence.
///
/// Not thread-safe: the writer calls it on its own serial queue.
struct MicGapFiller {
    static let sampleRate = 48_000.0
    /// Gaps shorter than this are timestamp jitter, not a stall.
    static let minGapFrames = 2_400            // 50 ms
    /// Larger gaps are treated as clock nonsense and ignored.
    static let maxGapFrames = 2 * 3_600 * 48_000
    /// Mic this far behind the system channel counts as stalled.
    static let stallThreshold = 96_000         // 2 s
    /// Silence is inserted up to this far behind the system channel.
    static let stallHeadroom = 48_000          // 1 s

    private var expectedNextStart: Double?     // host seconds
    private var paddedDuringStall = 0

    /// Call for each arriving mic buffer, before its samples are appended.
    /// Returns how many frames of silence to insert ahead of them.
    mutating func silenceToInsert(hostSeconds: Double?, frames: Int) -> Int {
        defer { paddedDuringStall = 0 }
        guard let hostSeconds else { return 0 }
        var insert = 0
        if let expected = expectedNextStart {
            let gap = Int(((hostSeconds - expected) * Self.sampleRate).rounded())
            if gap > Self.minGapFrames, gap < Self.maxGapFrames {
                insert = max(0, gap - paddedDuringStall)
            }
        }
        expectedNextStart = hostSeconds + Double(frames) / Self.sampleRate
        return insert
    }

    /// Call from the flush path. Returns how many frames of silence to append
    /// to the mic buffer because it has fallen far behind the system channel.
    mutating func stallPadding(micFrames: Int, systemFrames: Int) -> Int {
        let lag = systemFrames - micFrames
        guard lag > Self.stallThreshold else { return 0 }
        let pad = lag - Self.stallHeadroom
        paddedDuringStall += pad
        return pad
    }
}
