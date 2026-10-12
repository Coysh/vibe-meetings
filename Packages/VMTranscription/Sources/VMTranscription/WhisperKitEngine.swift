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

    public func loadModel(id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let already = state.withLock { s -> Bool in
            s.loadedModelId == id && s.pipeline != nil
        }
        if already { return }

        guard let entry = ModelCatalog.entry(id: id) else {
            throw TranscriptionEngineError.modelNotFound(id: id)
        }

        let installURL = try ModelCatalog.defaultInstallURL(for: entry)
        let exists = ModelCatalog.isDownloaded(entry)

        // WhisperKit's `modelFolder` is the exact directory where component
        // files (MelSpectrogram.mlmodelc etc.) live.
        //
        // IMPORTANT: When `modelFolder` is passed to WhisperKitConfig, the
        // `download` and `model` parameters are ignored — WhisperKit uses
        // the folder as-is. So we must download separately first, then point
        // WhisperKit at the populated directory.
        if !exists {
            let whisperKitModelName = entry.sourceURL.lastPathComponent
            let downloadedURL = try await WhisperKit.download(
                variant: whisperKitModelName
            ) { dlProgress in
                progress(dlProgress.fractionCompleted)
            }

            // Copy downloaded files from the Hub cache into our install dir
            // so `isDownloaded` returns true on subsequent launches.
            let fm = FileManager.default
            try fm.createDirectory(at: installURL, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(
                at: downloadedURL,
                includingPropertiesForKeys: nil
            )
            for item in items {
                let dest = installURL.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: item, to: dest)
                }
            }
        }

        let config = WhisperKitConfig(
            modelFolder: installURL.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        progress(1.0)

        // Box the pipeline before capturing it in the @Sendable withLock
        // closure — WhisperKit itself isn't Sendable.
        let box = PipelineBox(value: pipe)
        state.withLock { s in
            s.pipeline = box
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

    /// Transcribe a whole channel of a finished recording (16 kHz mono) in one pass — the post-meeting
    /// pass. Unlike the live path there are no overlapping windows to stitch: Whisper sees the file in
    /// order, with each window's text as context for the next, and speech-based chunking keeps long
    /// silences out of it.
    ///
    /// - Parameter progress: called with the fraction done (0…1); return `false` to stop early, which
    ///   throws `CancellationError`.
    public func transcribeSamples(
        _ samples: [Float],
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Bool
    ) async throws -> [TranscriptSegment] {
        guard let box = state.withLock({ $0.pipeline }) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        let pipeline = box.value

        var decoding = Self.makeDecodingOptions(for: options, isStreaming: false)
        decoding.promptTokens = Self.promptTokens(for: options.initialPrompt, pipeline: pipeline, allowed: promptsAreSafe())
        // One 30-second window is Whisper's native size; longer audio is cut at speech boundaries.
        let windowSamples = Int(30 * PCMChunk.sampleRate)
        decoding.chunkingStrategy = samples.count > windowSamples ? .vad : nil
        // A few windows at a time: the Mac stays responsive while this runs in the background.
        decoding.concurrentWorkerCount = 4

        let totalWindows = max(1, Int((Double(samples.count) / Double(windowSamples)).rounded(.up)))
        let flags = OSAllocatedUnfairLock(initialState: (highestWindow: 0, stopped: false))
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: decoding) { update in
            let keepGoing = flags.withLock { state -> Bool in
                state.highestWindow = max(state.highestWindow, update.windowId)
                let fraction = min(1, Double(state.highestWindow + 1) / Double(totalWindows))
                if !progress(fraction) { state.stopped = true }
                return !state.stopped
            }
            return keepGoing ? nil : false
        }
        if flags.withLock({ $0.stopped }) { throw CancellationError() }

        return Self.makeSegments(from: results, speakerId: speakerId, channel: channel, isPartial: false)
    }

    public func transcribeStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        options.commitStreaming
            ? committedStream(input: input, channel: channel, speakerId: speakerId, options: options)
            : slidingWindowStream(input: input, channel: channel, speakerId: speakerId, options: options)
    }

    /// Live transcription that commits settled text and advances (see `LiveTranscriptionSession`).
    private func committedStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let pipelineBox = state.withLock { $0.pipeline }

        return AsyncThrowingStream { continuation in
            guard let pipelineBox else {
                continuation.finish(throwing: TranscriptionEngineError.modelNotLoaded)
                return
            }
            let decoding = Self.makeDecodingOptions(for: options, isStreaming: true)
            let promptsAllowed = promptsAreSafe()
            // With no language chosen, work it out from the first speech and then keep it: detecting on every
            // short window is how a "yeah" gets transcribed as another language.
            let detectedLanguage = OSAllocatedUnfairLock<String?>(initialState: nil)
            var sessionConfig = LiveTranscriptionSession.Configuration()
            sessionConfig.hopSeconds = options.liveHopSeconds
            sessionConfig.contextCharacters = options.liveContextCharacters
            let session = LiveTranscriptionSession(
                channel: channel,
                speakerId: speakerId,
                vocabulary: options.initialPrompt,
                configuration: sessionConfig
            ) { samples, prompt in
                var window = decoding
                window.promptTokens = Self.promptTokens(for: prompt, pipeline: pipelineBox.value, allowed: promptsAllowed)
                if options.language == nil, let language = detectedLanguage.withLock({ $0 }) {
                    window.language = language
                    window.detectLanguage = false
                }
                let results = try await pipelineBox.value.transcribe(audioArray: samples, decodeOptions: window)
                let decoded = Self.decodedSegments(from: results)
                if options.language == nil, !decoded.isEmpty, detectedLanguage.withLock({ $0 }) == nil,
                   decoded.reduce(0, { $0 + $1.text.count }) >= 40,
                   let language = results.first?.language, !language.isEmpty {
                    detectedLanguage.withLock { $0 = language }
                }
                return decoded
            }

            let task = Task {
                for await chunk in input {
                    do {
                        for segment in try await session.ingest(chunk) { continuation.yield(segment) }
                    } catch is CancellationError {
                        break
                    } catch {
                        // One failed decode shouldn't end the transcript; the next hop tries again.
                        print("[Transcriber] \(channel) decode failed: \(error.localizedDescription)")
                    }
                }
                if let rest = try? await session.finish() {
                    for segment in rest { continuation.yield(segment) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The original strategy: decode the last 30 s every 5 s and let each decode replace the overlap.
    private func slidingWindowStream(
        input: AsyncStream<PCMChunk>,
        channel: AudioChannel,
        speakerId: String,
        options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        // Resolve the pipeline once, in this nonisolated context, and pass
        // the Sendable box into the @Sendable Task closure below.
        let pipelineBox = state.withLock { $0.pipeline }
        let promptsAllowed = promptsAreSafe()

        return AsyncThrowingStream { continuation in
            guard let pipelineBox else {
                continuation.finish(throwing: TranscriptionEngineError.modelNotLoaded)
                return
            }

            var liveOptions = Self.makeDecodingOptions(for: options, isStreaming: true)
            liveOptions.promptTokens = Self.promptTokens(for: options.initialPrompt, pipeline: pipelineBox.value, allowed: promptsAllowed)
            let decodingOptions = liveOptions
            let task = Task {
                let streamer = StreamingTranscriber()
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

    /// Whether the loaded model copes with a prompt. The "turbo" and distilled models have a cut-down decoder
    /// and, given any prompt, write almost nothing — measured on real recordings, a short glossary cut a
    /// turbo transcript to about a fifth of its words. So prompts are only used where they work.
    private func promptsAreSafe() -> Bool {
        guard let id = state.withLock({ $0.loadedModelId }) else { return true }
        return !(id.contains("turbo") || id.contains("distil"))
    }

    /// Whisper reads a short "initial prompt" as what came before the audio, which makes it far more
    /// likely to spell names and terms the way the prompt does. Returns the prompt as tokens.
    private static func promptTokens(for prompt: String?, pipeline: WhisperKit, allowed: Bool) -> [Int]? {
        guard allowed, let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let tokenizer = pipeline.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // The decoder has room for about half its context; the end of the prompt matters most.
        return tokens.isEmpty ? nil : Array(tokens.suffix(200))
    }

    /// Builds `DecodingOptions` against WhisperKit's current API. Only the
    /// arguments we actually need are passed; everything else takes the
    /// library's defaults so we ride out parameter renames between releases.
    private static func makeDecodingOptions(
        for options: TranscriptionOptions,
        isStreaming: Bool
    ) -> DecodingOptions {
        // `suppressBlank` drops empty/near-blank decodes (a common source of
        // hallucinated pleasantries on silence). For the live streaming path we
        // also turn word timestamps OFF: nothing in the app reads `seg.words`,
        // and the DTW alignment they require is pure latency on the medium model
        // running two channels in parallel.
        DecodingOptions(
            verbose: false,
            task: options.translate ? .translate : .transcribe,
            language: options.language,
            temperature: options.temperature,
            temperatureFallbackCount: isStreaming ? 3 : 5,
            // No language chosen means "work it out"; otherwise WhisperKit assumes English.
            detectLanguage: options.language == nil,
            wordTimestamps: isStreaming ? false : options.enableWordTimestamps,
            suppressBlank: true
        )
    }

    /// WhisperKit's results as plain segments (times in seconds from the start of the decoded audio).
    private static func decodedSegments(from results: [TranscriptionResult]) -> [DecodedSegment] {
        results.flatMap { result in
            result.segments.compactMap { segment -> DecodedSegment? in
                let text = stripSpecialTokens(segment.text)
                guard !text.isEmpty else { return nil }
                return DecodedSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: text,
                    confidence: segment.avgLogprob
                )
            }
        }
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
                let cleaned = stripSpecialTokens(seg.text)
                guard !cleaned.isEmpty else { continue }
                let words = seg.words?.map { w in
                    Word(
                        text: stripSpecialTokens(w.word),
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
                    text: cleaned,
                    isPartial: isPartial,
                    // WhisperKit's `avgLogprob` (a negative log-prob) — used
                    // downstream to distinguish confident speech from silence
                    // hallucinations. Not a 0…1 score.
                    confidence: seg.avgLogprob,
                    words: words
                ))
            }
        }
        return out
    }

    /// Remove WhisperKit special tokens like `<|startoftranscript|>`,
    /// `<|en|>`, `<|transcribe|>`, `<|0.00|>`, `<|endoftext|>`, etc.
    /// Also strips Whisper noise markers like `[BLANK_AUDIO]`.
    private static func stripSpecialTokens(_ text: String) -> String {
        TranscriptNoiseFilter.stripNoiseMarkers(
            text.replacing(/<\|[^|]*\|>/, with: "")
        )
    }
}
