import Foundation

enum AtomicWriter {
    /// Writes `data` to `url` atomically: write to a sibling temp file then `replaceItemAt`.
    /// Crash-safe: readers see either the previous contents or the new ones, never partial.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Creates a new directory atomically: build under a hidden temp name, then rename.
    static func createDirectory(at url: URL, populate: (URL) throws -> Void) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        do {
            try populate(tmp)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
