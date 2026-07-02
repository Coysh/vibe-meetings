import Foundation

/// Streams raw interleaved 16-bit PCM to a `.wav` file **incrementally**, so
/// that if the process dies mid-recording the audio captured up to that point
/// is still recoverable.
///
/// `AVAssetWriter` (the m4a path) only produces a playable file once
/// `finishWriting` runs — a crash leaves a truncated, unplayable m4a. A WAV,
/// by contrast, is just a 44-byte header followed by raw samples: every sample
/// we append is durable the moment it hits disk. We write a header with
/// placeholder sizes up front and patch the real sizes in on a clean stop; if
/// we never get that chance, `repairHeader(at:)` reconstructs the sizes from
/// the file length on next launch.
///
/// Not thread-safe: the owner (`DualChannelM4AWriter`) only ever touches it
/// from its own serial queue.
public final class CrashSafeWAVWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let url: URL
    private var dataBytesWritten: Int = 0

    private static let headerSize = 44

    public init(url: URL, sampleRate: Int = 48_000, channels: Int = 2, bitsPerSample: Int = 16) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        // Write a header with a zero data length as a placeholder; patched on stop.
        let header = Self.header(sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample, dataLength: 0)
        handle.write(header)
    }

    /// Append raw interleaved little-endian Int16 samples.
    public func append(_ samples: [Int16]) {
        samples.withUnsafeBytes { raw in
            handle.write(Data(raw))
        }
        dataBytesWritten += samples.count * MemoryLayout<Int16>.size
    }

    /// Patch the RIFF/data chunk sizes to reflect the bytes actually written,
    /// then close the file. Produces a fully valid, playable WAV.
    public func finalize() {
        Self.patchSizes(dataLength: dataBytesWritten, handle: handle)
        try? handle.close()
    }

    /// Close without patching (used when the m4a succeeded and we're about to
    /// delete this sidecar anyway).
    public func close() {
        try? handle.close()
    }

    // MARK: - Recovery

    /// Reconstructs a valid WAV header for a file left behind by a crash. The
    /// data length is derived from the on-disk file size, so any samples that
    /// were flushed before the crash remain playable.
    /// Returns true if the file existed and held at least one sample.
    @discardableResult
    public static func repairHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return false }
        let total = Int(end)
        guard total > headerSize else { return false }
        let dataLength = total - headerSize
        patchSizes(dataLength: dataLength, handle: handle)
        return true
    }

    // MARK: - Header

    private static func header(sampleRate: Int, channels: Int, bitsPerSample: Int, dataLength: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(u32(36 + dataLength))          // ChunkSize
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(u32(16))                        // Subchunk1Size (PCM)
        d.append(u16(1))                         // AudioFormat = PCM
        d.append(u16(channels))
        d.append(u32(sampleRate))
        d.append(u32(byteRate))
        d.append(u16(blockAlign))
        d.append(u16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.append(u32(dataLength))                // Subchunk2Size
        return d
    }

    /// Overwrites the two size fields (offset 4 = RIFF chunk size, offset 40 =
    /// data chunk size) in an already-written header.
    private static func patchSizes(dataLength: Int, handle: FileHandle) {
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        try? handle.seek(toOffset: 4)
        handle.write(u32(36 + dataLength))
        try? handle.seek(toOffset: 40)
        handle.write(u32(dataLength))
    }
}
