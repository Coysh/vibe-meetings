import AVFoundation

/// Sendable transport wrapper around `AVAudioPCMBuffer`.
///
/// `AVAudioPCMBuffer` is a class without `Sendable` conformance, so Swift 6
/// strict concurrency refuses to ferry one through an `AsyncStream` (which
/// crosses isolation domains). The wrapper marks the type `@unchecked
/// Sendable`; the unchecked-ness is justified by the way we actually use it:
///
/// - At the producer (`MicrophoneCapturer` / `SystemAudioCapturer`) the
///   buffer is created fresh in the audio callback and immediately copied
///   before being yielded — no other reference exists.
/// - At every consumer (`AudioCaptureCoordinator`, `DualChannelM4AWriter`,
///   `AudioFormatConverter`) the buffer is read-only: we extract samples
///   and never mutate.
///
/// In other words, the buffer is effectively immutable once it leaves the
/// callback, which makes the cross-actor hop race-free in practice.
public struct SendableAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
