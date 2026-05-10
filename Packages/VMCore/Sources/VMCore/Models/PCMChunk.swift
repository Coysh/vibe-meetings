import Foundation

/// A chunk of PCM audio handed to a transcription engine.
/// Contract: 16 kHz, mono, Float32, normalized to [-1, 1].
public struct PCMChunk: Sendable {
    public let samples: [Float]
    public let timestamp: TimeInterval

    public init(samples: [Float], timestamp: TimeInterval) {
        self.samples = samples
        self.timestamp = timestamp
    }

    public static let sampleRate: Double = 16_000
}
