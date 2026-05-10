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

    public let url: URL

    public init(url: URL) { self.url = url }

    public var metadataURL: URL { url.appendingPathComponent(Self.metadataFilename) }
    public var transcriptURL: URL { url.appendingPathComponent(Self.transcriptFilename) }
    public var summaryURL: URL { url.appendingPathComponent(Self.summaryFilename) }
    public var segmentsURL: URL { url.appendingPathComponent(Self.segmentsFilename) }
    public var audioURL: URL { url.appendingPathComponent(Self.audioFilename) }

    public var isMeeting: Bool {
        FileManager.default.fileExists(atPath: metadataURL.path)
    }
}
