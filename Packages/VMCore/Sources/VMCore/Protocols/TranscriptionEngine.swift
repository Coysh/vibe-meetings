import Foundation

public protocol TranscriptionEngine: Sendable {
    /// Stable identifier persisted in `meeting.json` (e.g. "whisperkit", "whispercpp").
    static var kind: String { get }

    /// Human-readable name for UI ("WhisperKit", "whisper.cpp").
    var displayName: String { get }

    /// Models known to this engine. `isDownloaded` tells the UI which need fetching.
    func availableModels() async throws -> [TranscriptionModelInfo]

    /// Loads a model into memory. Idempotent — calling twice with the same id is a no-op.
    func loadModel(id: String, progress: @Sendable (Double) -> Void) async throws

    /// Batch transcription of a complete audio file. Used for imports and re-transcribe.
    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment]

    /// Streaming transcription. The caller pushes 16 kHz mono Float32 PCM chunks; the
    /// engine emits partial segments continuously and finals when a window closes.
    /// The output stream finishes when the input stream finishes.
    func transcribeStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error>
}

public enum TranscriptionEngineError: Error, Sendable, Equatable {
    case modelNotLoaded
    case modelNotFound(id: String)
    case unsupportedAudioFormat(String)
    case engineUnavailable(reason: String)
    case cancelled
}
