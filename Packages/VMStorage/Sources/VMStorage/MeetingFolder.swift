import Foundation

/// Convention for what files live inside a single meeting's folder.
///
/// A folder is a meeting iff it contains `meeting.json`. That's the entire
/// data model — no SQLite, no manifest, no hidden state.
public struct MeetingFolder: Sendable {
    public static let metadataFilename = "meeting.json"
    public static let transcriptFilename = "transcript.md"
    public static let summaryFilename = "summary.md"
    public static let segmentsFilename = "segments.json"
    public static let audioFilename = "audio.m4a"
    public static let cleanedAudioFilename = "audio-cleaned.m4a"
    /// Crash-safe raw WAV written incrementally alongside the m4a while
    /// recording. Deleted on a clean stop (the m4a is authoritative); if the
    /// app crashes mid-meeting this file survives and is repaired on next launch.
    public static let partialAudioFilename = "audio-partial.wav"
    /// A `partialAudioFilename` whose header has been repaired at launch after
    /// an interrupted recording. Playable standalone.
    public static let recoveredAudioFilename = "audio-recovered.wav"
    public static let notesFilename = "notes.md"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var metadataURL: URL { url.appendingPathComponent(Self.metadataFilename) }
    public var transcriptURL: URL { url.appendingPathComponent(Self.transcriptFilename) }
    public var summaryURL: URL { url.appendingPathComponent(Self.summaryFilename) }
    public var segmentsURL: URL { url.appendingPathComponent(Self.segmentsFilename) }
    public var audioURL: URL { url.appendingPathComponent(Self.audioFilename) }
    public var cleanedAudioURL: URL { url.appendingPathComponent(Self.cleanedAudioFilename) }
    public var partialAudioURL: URL { url.appendingPathComponent(Self.partialAudioFilename) }
    public var recoveredAudioURL: URL { url.appendingPathComponent(Self.recoveredAudioFilename) }
    public var notesURL: URL { url.appendingPathComponent(Self.notesFilename) }

    public var isMeeting: Bool {
        FileManager.default.fileExists(atPath: metadataURL.path)
    }
}
