import CoreAudio
import Foundation

public protocol AudioCaptureService: Sendable {
    var state: AsyncStream<CaptureState> { get }
    var levels: AsyncStream<LevelSnapshot> { get }

    /// Two parallel PCM streams for the transcription engines (16 kHz mono Float32).
    /// Each chunk is timestamped against a single `mach_absolute_time` epoch captured
    /// at `start()`, so segments from both streams are mergeable by `start`.
    var micPCM: AsyncStream<PCMChunk> { get }
    var systemPCM: AsyncStream<PCMChunk> { get }

    /// Begins capture. If `writingAudioTo` is non-nil, a 2-channel m4a file (mic on L,
    /// system on R) is written at that URL until `stop()`.
    /// `micDeviceID` selects a specific input device; pass `nil` for the system default.
    func start(writingAudioTo url: URL?, micDeviceID: AudioDeviceID?) async throws

    func pause() async
    func resume() async
    func stop() async throws -> CaptureResult
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case alreadyRunning
    case notRunning
    case audioEngineFailed(String)
    case systemTapFailed(String)
}
