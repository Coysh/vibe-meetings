import Foundation
import VMCore

/// `TranscriptionEngine` backed by whisper.cpp.
///
/// **Status**: scaffold. The Swift side is fully wired (model catalog, streaming window,
/// segment shape) but the C bridge to whisper.cpp itself is not vendored in this repo —
/// adding it requires:
///   1. Drop the whisper.cpp sources under
///      `Packages/VMTranscription/Sources/WhisperCppC/` (the C target).
///   2. Add a `WhisperCppC` C target to `Package.swift` with `-O3 -DGGML_USE_METAL`
///      and the Metal kernels as bundle resources.
///   3. Replace `loadModel`, `transcribeFile`, and the `runInference` body below with
///      calls to `whisper_init_from_file_with_params` / `whisper_full`.
///
/// Until then, this engine reports itself as available with `isDownloaded == false`
/// for all models, and throws `engineUnavailable` if the user actually selects it.
/// The protocol surface is identical to `WhisperKitEngine` so the rest of the app does
/// not need to know which engine is in use.
public final class WhisperCppEngine: TranscriptionEngine, @unchecked Sendable {
    public static let kind = "whispercpp"
    public let displayName = "whisper.cpp"

    public init() {}

    public func availableModels() async throws -> [TranscriptionModelInfo] {
        ModelCatalog.entries(for: Self.kind).map { e in
            TranscriptionModelInfo(
                id: e.id,
                displayName: e.displayName,
                sizeBytes: e.sizeBytes,
                isDownloaded: ModelCatalog.isDownloaded(e),
                recommended: e.recommended
            )
        }
    }

    public func loadModel(id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw TranscriptionEngineError.engineUnavailable(
            reason: "whisper.cpp C bridge not yet vendored — see Packages/VMTranscription/WhisperCppBridge/README.md"
        )
    }

    public func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        throw TranscriptionEngineError.engineUnavailable(
            reason: "whisper.cpp C bridge not yet vendored"
        )
    }

    public func transcribeStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: TranscriptionEngineError.engineUnavailable(
                reason: "whisper.cpp C bridge not yet vendored"
            ))
        }
    }
}
