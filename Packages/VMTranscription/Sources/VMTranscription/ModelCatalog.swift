import Foundation
import VMCore

/// Static catalog of known Whisper models for both engines. The shipping list is small
/// and curated; users can download more variants by adding entries here.
public enum ModelCatalog {
    public struct Entry: Sendable, Hashable {
        public let id: String                   // canonical id used in `meeting.json.modelId`
        public let displayName: String
        public let sizeBytes: Int64
        public let recommended: Bool
        public let engineKind: String           // "whisperkit" | "whispercpp"
        public let sourceURL: URL               // Hugging Face / argmax CDN
        public let sha256: String?
    }

    public static let entries: [Entry] = [
        // WhisperKit (Argmax CoreML packages)
        Entry(
            id: "whisper-base",
            displayName: "base",
            sizeBytes: 150_000_000,
            recommended: false,
            engineKind: "whisperkit",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-base")!,
            sha256: nil
        ),
        Entry(
            id: "whisper-small",
            displayName: "small",
            sizeBytes: 500_000_000,
            recommended: false,
            engineKind: "whisperkit",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small")!,
            sha256: nil
        ),
        Entry(
            id: "whisper-medium",
            displayName: "medium",
            sizeBytes: 1_500_000_000,
            recommended: true,
            engineKind: "whisperkit",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-medium")!,
            sha256: nil
        ),
        Entry(
            id: "whisper-large-v3",
            displayName: "large-v3",
            sizeBytes: 3_100_000_000,
            recommended: false,
            engineKind: "whisperkit",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-large-v3")!,
            sha256: nil
        ),

        // whisper.cpp (ggml)
        Entry(
            id: "ggml-base.bin",
            displayName: "base (ggml)",
            sizeBytes: 150_000_000,
            recommended: false,
            engineKind: "whispercpp",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            sha256: nil
        ),
        Entry(
            id: "ggml-medium.bin",
            displayName: "medium (ggml)",
            sizeBytes: 1_500_000_000,
            recommended: true,
            engineKind: "whispercpp",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            sha256: nil
        )
    ]

    public static func entries(for engineKind: String) -> [Entry] {
        entries.filter { $0.engineKind == engineKind }
    }

    public static func entry(id: String) -> Entry? {
        entries.first(where: { $0.id == id })
    }

    /// Default install root: `~/Library/Application Support/VibeMeetings/Models/<engineKind>/<id>/`.
    public static func defaultInstallURL(for entry: Entry) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("VibeMeetings")
            .appendingPathComponent("Models")
            .appendingPathComponent(entry.engineKind)
            .appendingPathComponent(entry.id)
    }

    public static func isDownloaded(_ entry: Entry) -> Bool {
        guard let url = try? defaultInstallURL(for: entry) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        // An empty directory is left behind by a failed or interrupted download.
        // Treat it as not-downloaded so the user can retry.
        return (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == false
    }
}
