import Foundation
import VMCore

/// Recovers meetings whose recording was interrupted by a crash, force-quit, or
/// power loss.
///
/// A live recording leaves `meeting.json` with `endedAt == nil` for its whole
/// duration; a clean stop sets `endedAt`. So at launch — when nothing is
/// recording yet — any meeting still carrying `endedAt == nil` was interrupted.
/// For those we:
///
///   1. Repair the crash-safe WAV sidecar (`audio-partial.wav`) so the captured
///      audio is playable, renaming it to `audio-recovered.wav`. The truncated,
///      unplayable `audio.m4a` (if any) is removed.
///   2. Stamp `endedAt` (best-estimated from the newest artefact's mtime) so the
///      meeting no longer looks perpetually in-progress and gets a duration.
///   3. Tag it `recovered` so the user can see it was salvaged.
///
/// The transcript itself needs no repair: it is checkpointed to disk every few
/// seconds while recording, so `segments.json`/`transcript.md` already hold the
/// last checkpoint.
public enum RecordingRecoveryService {

    /// Scans the tree under `rootURL` and recovers any interrupted meetings.
    /// Safe to call on every launch — meetings that already have `endedAt`
    /// set are skipped. Returns the number of meetings recovered.
    @discardableResult
    public static func recoverInterruptedMeetings(in rootURL: URL) -> Int {
        var recovered = 0
        for metadataURL in findMeetingMetadataFiles(under: rootURL) {
            if recoverMeeting(at: metadataURL) { recovered += 1 }
        }
        if recovered > 0 {
            print("[Recovery] Recovered \(recovered) interrupted meeting(s)")
        }
        return recovered
    }

    // MARK: - Per-meeting

    private static func recoverMeeting(at metadataURL: URL) -> Bool {
        guard var meeting = try? FolderTreeScanner.loadMeeting(from: metadataURL),
              meeting.endedAt == nil else { return false }

        let folder = MeetingFolder(url: metadataURL.deletingLastPathComponent())
        let fm = FileManager.default

        let hasPartialWav = fileHasSamples(folder.partialAudioURL)
        let hasSegments = (try? SegmentsFile.load(from: folder.segmentsURL))?.isEmpty == false

        // Only treat as an interrupted recording if there's real evidence of one.
        // (Avoids stamping brand-new, never-recorded draft folders.)
        guard hasPartialWav || hasSegments else { return false }

        var recoveredAudio = false
        if hasPartialWav {
            if CrashSafeWAVWriter.repairHeader(at: folder.partialAudioURL) {
                // The m4a never got its moov atom written — it's unplayable. Drop it.
                try? fm.removeItem(at: folder.audioURL)
                // Promote the repaired sidecar to its finalized name.
                try? fm.removeItem(at: folder.recoveredAudioURL)
                try? fm.moveItem(at: folder.partialAudioURL, to: folder.recoveredAudioURL)
                recoveredAudio = true
            }
        }

        meeting.endedAt = bestEndDate(for: folder, fallback: meeting.startedAt)
        if recoveredAudio {
            meeting.hasAudio = true
        }
        var labels = meeting.labels ?? []
        if !labels.contains("recovered") {
            labels.append("recovered")
            meeting.labels = labels
        }

        do {
            try FolderTreeScanner.writeMeeting(meeting, to: metadataURL)
            return true
        } catch {
            print("[Recovery] Failed to write recovered meeting.json at \(metadataURL.path): \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private static func fileHasSamples(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 44   // larger than a bare WAV header
    }

    /// Best estimate of when the meeting actually ended: the newest modification
    /// date across its recording artefacts, or the start time if none are found.
    private static func bestEndDate(for folder: MeetingFolder, fallback: Date) -> Date {
        let candidates = [folder.recoveredAudioURL, folder.partialAudioURL, folder.segmentsURL, folder.transcriptURL]
        let dates = candidates.compactMap { url -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return dates.max() ?? fallback
    }

    /// Depth-first walk collecting every `meeting.json` under `rootURL`.
    private static func findMeetingMetadataFiles(under rootURL: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        var stack: [URL] = [rootURL]
        while let dir = stack.popLast() {
            let metadata = dir.appendingPathComponent(MeetingFolder.metadataFilename)
            if fm.fileExists(atPath: metadata.path) {
                results.append(metadata)
                continue   // meeting folders are leaves
            }
            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { stack.append(entry) }
            }
        }
        return results
    }
}
