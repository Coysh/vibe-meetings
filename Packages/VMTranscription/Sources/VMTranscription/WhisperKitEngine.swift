import Foundation
import os
import VMCore
import WhisperKit

/// Sendable transport for the `WhisperKit` pipeline. WhisperKit isn't `Sendable`
/// in current releases, so we can't capture it directly in `@Sendable` closures
/// (e.g. the Task that drives streaming). The pipeline is functionally read-only
/// after construction — `transcribe(...)` is async and handles its own
/// concurrency internally — so `@unchecked Sendable` is safe here.
private struct PipelineBox: @unchecked Sendable {
    let value: WhisperKit
}

private struct EngineState: @unchecked Sendable {
    var pipeline: PipelineBox?
    var loadedModelId: String?
}

/// `TranscriptionEngine` backed by WhisperKit. WhisperKit handles model
/// download/load and exposes both batch transcription and a buffered API we
/// drive from `StreamingTranscriber` for live mode.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public static let kind = "whisperkit"
    public let displayName = "WhisperKit"

    /// Async-safe state mutation. `OSAllocatedUnfairLock.withLock` is sync
    /// and never spans a suspension point, so it's legal in async contexts —
    /// unlike `NSLock.lock()/unlock()`.
    private let state = OSAllocatedUnfairLock<EngineState>(initialState: EngineState())

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
        let already = state.withLock { s -> Bool in
            s.loadedModelId == id && s.pipeline != nil
        }
        if already { return }

        guard let entry = ModelCatalog.entry(id: id) else {
            throw TranscriptionEngineError.modelNotFound(id: id)
        }

        let installURL = try ModelCatalog.defaultInstallURL(for: entry)
        let exists = FileManager.default.fileExists(atPath: installURL.path)

        let config = WhisperKitConfig(
            model: id,
            modelFolder: installURL.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: !exists
        )
        let pipe = try await WhisperKit(config)
        progress(1.0)

        state.withLock { s in
            s.pipeline = PipelineBox(value: pipe)
            s.loadedModelId = id
        }
    }

    public func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        guard let box = state.withLock({ $0.pipeline }) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        let pipeline = box.value
        let decodingOptions = Self.makeDecodingOptions(for: options, isStreaming: false)
        let results = try await pipeline.transcribe(audioPath: url.path, decodeOptions: decodingOptions)
        return Self.makeSegments(
            from: results,
            speakerId: Speaker.imported.id,
            channel: .mixed,
            isPartial: false
        )
    }

    public func transcribeStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        // Resolve the pipeline once, in this nonisolated context, and pass
        // the Sendable box into the @Sendable Task closure below.
        let pipelineBox = state.withLock { $0.pipeline }

        return AsyncThrowingStream { continuation in
            guard let pipelineBox else {
                continuation.finish(throwing: TranscriptionEngineError.modelNotLoaded)
                return
            }

            let decodingOptions = Self.makeDecodingOptions(for: options, isStreaming: true)
            let task = Task {
                let streamer = StreamingTranscriber(config: .init(windowSeconds: 30, hopSeconds: 1.5))
                await streamer.run(input: input) { samples, windowStart in
                    do {
                        let pipeline = pipelineBox.value
                        let res = try await pipeline.transcribe(
                            audioArray: samples,
                            decodeOptions: decodingOptions
                        )
                        let segments = Self.makeSegments(
                            from: res,
                            speakerId: speakerId,
                            channel: channel,
                            isPartial: true,
                            timeOffset: windowStart
                        )
                        for seg in segments {
                            continuation.yield(seg)
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

    // MARK: - Helpers

    /// Builds `DecodingOptions` against WhisperKit's current API. Only the
    /// arguments we actually need are passed; everything else takes the
    /// library's defaults so we ride out parameter renames between releases.
    private static func makeDecodingOptions(
        for options: TranscriptionOptions,
        isStreaming: Bool
    ) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: options.translate ? .translate : .transcribe,
            language: options.language,
            temperature: options.temperature,
            wordTimestamps: options.enableWordTimestamps
        )
    }

    /// Convert WhisperKit's per-request results into our `TranscriptSegment`
    /// model. Pulled out of the call sites so the type-checker doesn't time
    /// out on the nested closure.
    private static func makeSegments(
        from results: [TranscriptionResult],
        speakerId: String,
        channel: AudioChannel,
        isPartial: Bool,
        timeOffset: TimeInterval = 0
    ) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let words = seg.words?.map { w in
                    Word(
                        text: w.word,
                        start: TimeInterval(w.start) + timeOffset,
                        end: TimeInterval(w.end) + timeOffset,
                        probability: w.probability
                    )
                }
                out.append(TranscriptSegment(
                    speakerId: speakerId,
                    channel: channel,
                    start: TimeInterval(seg.start) + timeOffset,
                    end: TimeInterval(seg.end) + timeOffset,
                    text: seg.text,
                    isPartial: isPartial,
                    confidence: nil,
                    words: words
                ))
            }
        }
        return out
    }
}
