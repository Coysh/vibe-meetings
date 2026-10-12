import AVFoundation
import Foundation
import VMCore

/// Reads one side of a saved recording. `audio.m4a` is stereo: the microphone ("You") on the left, the
/// system audio ("Others") on the right. Whisper wants 16 kHz mono, so each side is decoded and resampled
/// on its own, which keeps the two speakers apart exactly as the live pass does.
public enum StereoAudio {
    public enum LoadError: Error, LocalizedError {
        case notStereo(channels: Int)
        case cannotConvert

        public var errorDescription: String? {
            switch self {
            case .notStereo(let channels): return "Expected a two-channel recording, found \(channels) channel(s)."
            case .cannotConvert: return "Couldn't convert the recording to 16 kHz mono."
            }
        }
    }

    public static let micChannel = 0
    public static let systemChannel = 1

    /// Length of the recording in seconds, or `nil` if it can't be read.
    public static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Decode channel `channel` (0 = microphone, 1 = system) to 16 kHz mono, optionally only the first
    /// `maxSeconds`. Read in short blocks, so memory is the output array and nothing more.
    public static func loadChannel(_ channel: Int, from url: URL, maxSeconds: Double? = nil) throws -> [Float] {
        try loadChannel(channel, from: AVAudioFile(forReading: url), maxSeconds: maxSeconds)
    }

    /// The same, from a file that's already open. It reads from the start each time, so one open file
    /// serves both sides — and keeps working if the meeting folder is renamed or moved in between,
    /// which a path would not.
    public static func loadChannel(_ channel: Int, from file: AVAudioFile, maxSeconds: Double? = nil) throws -> [Float] {
        file.framePosition = 0
        let format = file.processingFormat
        guard Int(format.channelCount) == 2 else { throw LoadError.notStereo(channels: Int(format.channelCount)) }

        let sourceRate = format.sampleRate
        let frameLimit = maxSeconds.map { AVAudioFramePosition($0 * sourceRate) } ?? file.length
        let end = min(file.length, frameLimit)

        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMChunk.sampleRate, channels: 1, interleaved: false),
              let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)
        else { throw LoadError.cannotConvert }

        let needsResample = abs(sourceRate - PCMChunk.sampleRate) > 0.5
        let converter = needsResample ? AVAudioConverter(from: monoFormat, to: target) : nil
        if needsResample, converter == nil { throw LoadError.cannotConvert }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(end) / sourceRate * PCMChunk.sampleRate))

        while file.framePosition < end {
            let remaining = AVAudioFrameCount(end - file.framePosition)
            try file.read(into: block, frameCount: min(block.frameCapacity, remaining))
            if block.frameLength == 0 { break }
            guard let channels = block.floatChannelData,
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: block.frameLength)
            else { throw LoadError.cannotConvert }
            mono.frameLength = block.frameLength
            mono.floatChannelData![0].update(from: channels[channel], count: Int(block.frameLength))

            guard let converter else {
                output.append(contentsOf: UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
                continue
            }
            try convert(mono, with: converter, to: target, appendingTo: &output, endOfStream: false)
        }
        if let converter, let silence = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1) {
            silence.frameLength = 0
            try convert(silence, with: converter, to: target, appendingTo: &output, endOfStream: true)
        }
        return output
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat,
        appendingTo output: inout [Float],
        endOfStream: Bool
    ) throws {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4_096
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw LoadError.cannotConvert }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            if input.frameLength == 0 {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? LoadError.cannotConvert }
        if converted.frameLength > 0, let data = converted.floatChannelData {
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
        }
    }
}
