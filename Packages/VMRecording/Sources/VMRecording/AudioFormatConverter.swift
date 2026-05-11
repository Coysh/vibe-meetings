import AVFoundation
import VMCore

/// Converts arbitrary `AVAudioPCMBuffer`s to the engine contract: 16 kHz, mono, Float32.
public final class AudioFormatConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMChunk.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        // Recreate the converter when the input format changes. We also call
        // reset() before every conversion because AVAudioConverter's
        // input-block API is stateful — after the block returns
        // .endOfStream the converter won't call it again on subsequent
        // convert() invocations unless reset.
        if inputFormat != buffer.format || converter == nil {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        converter.reset()

        // Capacity at the new sample rate, with a small slack.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil { return [] }

        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
