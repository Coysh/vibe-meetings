import Foundation
import VMCore
import WhisperKit

/// `TranscriptionEngine` backed by WhisperKit. WhisperKit handles model download/load
/// and exposes both batch transcription and a streaming-friendly buffered API.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public static let kind = "whisperkit"
    public let displayName = "WhisperKit"

    private var pipeline: WhisperKit?
    private var loadedModelId: String?
    private let lock = NSLock()

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

    public func loadModel(id: String, progress: @Sendable (Double) -> Void) async throws {
        if loadedModelId == id, pipeline != nil { return }

        guard let entry = ModelCatalog.entry(id: id) else {
            throw TranscriptionEngineError.modelNotFound(id: id)
        }

        let installURL = try ModelCatalog.defaultInstallURL(for: entry)

        // WhisperKit accepts a model folder URL directly; if the bundle isn't on disk,
        // it will download it from the source you provide. Pass our model storage path
        // so everything lives under Application Support.
        //
        // Check for actual file content, not just directory existence — an interrupted
        // download leaves an empty directory that would falsely suppress the download flag.
        let hasModelFiles = (try? FileManager.default.contentsOfDirectory(atPath: installURL.path))?.isEmpty == false
        let config = WhisperKitConfig(
            model: id,
            modelFolder: installURL.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: !hasModelFiles
        )
        let pipe = try await WhisperKit(config)
        progress(1.0)

        lock.lock()
        self.pipeline = pipe
        self.loadedModelId = id
        lock.unlock()
    }

    public func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        guard let pipeline else { throw TranscriptionEngineError.modelNotLoaded }
        let decodingOptions = DecodingOptions(
            verbose: false,
            task: options.translate ? .translate : .transcribe,
            language: options.language,
            temperature: options.temperature,
            usePrefillPrompt: options.initialPrompt != nil,
            promptTokens: nil,
            wordTimestamps: options.enableWordTimestamps
        )
        let results = try await pipeline.transcribe(audioPath: url.path, decodeOptions: decodingOptions)
        return results.flatMap { result -> [TranscriptSegment] in
            result.segments.map { seg in
                TranscriptSegment(
                    speakerId: Speaker.imported.id,
                    channel: .mixed,
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    text: seg.text,
                    isPartial: false,
                    confidence: nil,
                    words: seg.words?.map { w in
                        Word(text: w.word, start: TimeInterval(w.start), end: TimeInterval(w.end), probability: w.probability)
                    }
                )
            }
        }
    }

    public func transcribeStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                guard let pipeline = self.pipeline else {
                    continuation.finish(throwing: TranscriptionEngineError.modelNotLoaded)
                    return
                }

                let streamer = StreamingTranscriber(config: .init(windowSeconds: 30, hopSeconds: 1.5))
                let decodingOptions = DecodingOptions(
                    verbose: false,
                    task: options.translate ? .translate : .transcribe,
                    language: options.language,
                    temperature: options.temperature,
                    wordTimestamps: options.enableWordTimestamps
                )

                await streamer.run(input: input) { samples, windowStart in
                    do {
                        let res = try await pipeline.transcribe(audioArray: samples, decodeOptions: decodingOptions)
                        for r in res {
                            for seg in r.segments {
                                let absStart = windowStart + TimeInterval(seg.start)
                                let absEnd = windowStart + TimeInterval(seg.end)
                                continuation.yield(TranscriptSegment(
                                    speakerId: speakerId,
                                    channel: channel,
                                    start: absStart,
                                    end: absEnd,
                                    text: seg.text,
                                    isPartial: true
                                ))
                            }
                        }
                    } catch is CancellationError {
                        // expected on stop
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
