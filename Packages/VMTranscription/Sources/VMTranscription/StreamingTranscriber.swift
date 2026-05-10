import Foundation
import VMCore

/// Maintains a sliding-window audio ring used by engines that lack native streaming
/// (e.g. whisper.cpp). Pulls 16 kHz mono Float32 chunks off an `AsyncStream` and exposes
/// a callback when a full window is ready for inference.
public actor StreamingTranscriber {
    public struct Configuration: Sendable {
        public var windowSeconds: Double
        public var hopSeconds: Double

        public init(windowSeconds: Double = 30, hopSeconds: Double = 1.0) {
            self.windowSeconds = windowSeconds
            self.hopSeconds = hopSeconds
        }
    }

    private let config: Configuration
    private var ring: [Float] = []
    private var ringStartTimestamp: TimeInterval = 0
    private var samplesAtLastEmit: Int = 0

    public init(config: Configuration = .init()) {
        self.config = config
    }

    private var windowSampleCount: Int { Int(PCMChunk.sampleRate * config.windowSeconds) }
    private var hopSampleCount: Int { Int(PCMChunk.sampleRate * config.hopSeconds) }

    /// Run until `input` finishes. Calls `onWindow` whenever a hop has elapsed; the slice
    /// is always the trailing window (up to `windowSeconds`) of audio.
    public func run(
        input: AsyncStream<PCMChunk>,
        onWindow: @Sendable (_ samples: [Float], _ windowStart: TimeInterval) async -> Void
    ) async {
        for await chunk in input {
            if ring.isEmpty { ringStartTimestamp = chunk.timestamp }
            ring.append(contentsOf: chunk.samples)

            if ring.count > windowSampleCount {
                let drop = ring.count - windowSampleCount
                ring.removeFirst(drop)
                ringStartTimestamp += Double(drop) / PCMChunk.sampleRate
            }

            if ring.count - samplesAtLastEmit >= hopSampleCount {
                samplesAtLastEmit = ring.count
                let snapshot = ring
                let start = ringStartTimestamp
                await onWindow(snapshot, start)
            }
        }
    }
}
