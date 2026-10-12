import AVFoundation
import XCTest
@testable import VMTranscription

/// The post-meeting pass reads `audio.m4a` once per side, minutes apart, while "Save & file" may rename the
/// meeting's folder. These pin that one open file keeps working across a move (a path does not).
final class StereoAudioTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One second of 48 kHz stereo AAC: a tone on the left (the microphone), silence on the right.
    /// Written in its own scope, so the file is closed before it's read.
    private func writeRecording(to url: URL) throws {
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let left = try XCTUnwrap(buffer.floatChannelData)[0]
        let right = try XCTUnwrap(buffer.floatChannelData)[1]
        for i in 0..<Int(frames) {
            left[i] = Float(0.5 * sin(2 * .pi * 440 * Double(i) / rate))
            right[i] = 0
        }
        try file.write(from: buffer)
    }

    private func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

    func testOneOpenFileServesBothSidesAfterTheFolderMoves() throws {
        let folder = root.appendingPathComponent("Meeting A")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("audio.m4a")
        try writeRecording(to: original)

        let file = try AVAudioFile(forReading: original)
        let mic = try StereoAudio.loadChannel(StereoAudio.micChannel, from: file)

        // "Save & file": the folder is moved and renamed while the first side is still being worked on.
        let filed = root.appendingPathComponent("Filed", isDirectory: true)
        try FileManager.default.createDirectory(at: filed, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: filed.appendingPathComponent("Meeting B"))

        // Opening by the old path is what used to fail with 'wht?' (2003334207).
        XCTAssertThrowsError(try StereoAudio.loadChannel(StereoAudio.systemChannel, from: original))

        // The file that's already open still reads, and from the start.
        let system = try StereoAudio.loadChannel(StereoAudio.systemChannel, from: file)
        XCTAssertEqual(mic.count, system.count)
        XCTAssertEqual(Double(mic.count), 16_000, accuracy: 1_600, "one second at 16 kHz")
        XCTAssertGreaterThan(peak(mic), 0.2, "the tone is on the microphone side")
        XCTAssertLessThan(peak(system), 0.05, "and the system side is silent")

        // Reading again starts over rather than carrying on from where the last read stopped.
        let micAgain = try StereoAudio.loadChannel(StereoAudio.micChannel, from: file)
        XCTAssertEqual(micAgain.count, mic.count)
    }
}
