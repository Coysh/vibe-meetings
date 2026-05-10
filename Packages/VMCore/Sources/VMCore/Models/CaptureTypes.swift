import Foundation

public enum CaptureState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case error(String)
}

public struct LevelSnapshot: Sendable {
    public let mic: Float        // dBFS, typically -120…0
    public let system: Float
    public let timestamp: TimeInterval

    public init(mic: Float, system: Float, timestamp: TimeInterval) {
        self.mic = mic
        self.system = system
        self.timestamp = timestamp
    }
}

public struct CaptureResult: Sendable {
    public let audioFileURL: URL?
    public let duration: TimeInterval
    public let droppedFrames: Int

    public init(audioFileURL: URL?, duration: TimeInterval, droppedFrames: Int) {
        self.audioFileURL = audioFileURL
        self.duration = duration
        self.droppedFrames = droppedFrames
    }
}
