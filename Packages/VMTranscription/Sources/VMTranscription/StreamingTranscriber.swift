import Foundation
import VMCore

/// Maintains a sliding-window audio ring used by engines that lack native streaming
/// (e.g. whisper.cpp). Pulls 16 kHz mono Float32 chunks off an `AsyncStream` and exposes
/// a callback when a full window is ready for inference.
public actor StreamingTranscriber {
    public struct Configuration: Sendable {
        public var windowSeconds: Double
        public var hopSeconds: Double

        public init(windowSeconds: Double = 30, hopSeconds: Double = 5) {
            self.windowSeconds = windowSeconds
            self.hopSeconds = hopSeconds
        }
    }

    private let config: Configuration
    private var ring: [Float] = []
    private var ringStartTimestamp: TimeInterval = 0
    /// Monotonically increasing count of all samples ever appended (not
    /// affected by ring trimming). Used to detect when a hop's worth of
    /// new audio has arrived.
    private var totalSamplesReceived: Int = 0
    private var totalSamplesAtLastEmit: Int = 0

    public init(config: Configuration = .init()) {
        self.config = config
    }

    private var windowSampleCount: Int { Int(PCMChunk.sampleRate * config.windowSeconds) }
    private var hopSampleCount: Int { Int(PCMChunk.sampleRate * config.hopSeconds) }

    /// Run until `input` finishes. Calls `onWindow` whenever a hop has elapsed; the slice
    /// is always the trailing window (up to `windowSeconds`) of audio.
    ///
    /// **Skip-ahead**: While `onWindow` runs (WhisperKit inference), chunks keep arriving
    /// in the `AsyncStream` buffer. When inference completes, we drain all waiting chunks
    /// and only fire *one* window for the latest audio, skipping intermediate hops that
    /// would never catch up. This prevents an unbounded backlog when two parallel
    /// transcribers share a single WhisperKit pipeline.
    public func run(
        input: AsyncStream<PCMChunk>,
        onWindow: @Sendable (_ samples: [Float], _ windowStart: TimeInterval) async -> Void
    ) async {
        var chunkCount = 0
        var windowCount = 0
        for await chunk in input {
            chunkCount += 1
            if ring.isEmpty { ringStartTimestamp = chunk.timestamp }
            ring.append(contentsOf: chunk.samples)
            totalSamplesReceived += chunk.samples.count

            if ring.count > windowSampleCount {
                let drop = ring.count - windowSampleCount
                ring.removeFirst(drop)
                ringStartTimestamp += Double(drop) / PCMChunk.sampleRate
            }

            if totalSamplesReceived - totalSamplesAtLastEmit >= hopSampleCount {
                // Skip ahead: snap the emit cursor to the latest received total,
                // discarding any intermediate hops that accumulated during inference.
                let skippedHops = (totalSamplesReceived - totalSamplesAtLastEmit) / hopSampleCount
                totalSamplesAtLastEmit = totalSamplesReceived

                let snapshot = ring
                let start = ringStartTimestamp
                windowCount += 1
                if skippedHops > 1 {
                    print("[Transcriber] window #\(windowCount), \(snapshot.count) samples (skipped \(skippedHops - 1) stale hops)")
                } else {
                    print("[Transcriber] window #\(windowCount), \(snapshot.count) samples")
                }
                await onWindow(snapshot, start)
            }
        }
        print("[Transcriber] input stream ended after \(chunkCount) chunks, \(windowCount) windows")
    }
}
