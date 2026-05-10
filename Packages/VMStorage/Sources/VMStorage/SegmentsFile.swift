import Foundation
import VMCore

/// `segments.json` — the canonical, machine-readable transcript. The .md is rendered
/// from this; this is the source of truth for re-renders, edits and re-transcription.
public enum SegmentsFile {
    public static func load(from url: URL) throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    public static func save(_ segments: [TranscriptSegment], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(segments)
        try AtomicWriter.write(data, to: url)
    }
}
