import Foundation
import Observation
import VMCore
import VMStorage
import VMTranscription

/// Tracks one "identify speakers" run for a meeting.
@Observable
@MainActor
final class DiarizationJob {
    enum Status: Equatable {
        case running
        /// `speakers` is how many remote speakers the transcript now distinguishes
        /// (0 when nothing was split, e.g. a 1:1).
        case completed(speakers: Int)
        case failed(String)
    }

    let meetingID: UUID
    fileprivate(set) var status: Status = .running

    init(meetingID: UUID) {
        self.meetingID = meetingID
    }
}

/// Splits a meeting's "Others" into individual speakers after the fact.
///
/// The other participants arrive as one mixed system-audio stream, so the live
/// transcript can only say "Others". Once a recording is saved, this diarizes
/// that channel of `audio.m4a` on-device and relabels the transcript
/// ("Speaker 1", "Speaker 2" …), which the user can then rename. A meeting
/// with one remote speaker (a 1:1) is left exactly as it was.
@Observable
@MainActor
final class SpeakerDiarizationService {
    private var jobs: [UUID: DiarizationJob] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private let diarizer = SpeakerDiarizer()

    func job(for meetingID: UUID) -> DiarizationJob? { jobs[meetingID] }

    func isRunning(for meetingID: UUID) -> Bool {
        jobs[meetingID]?.status == .running
    }

    func clearJob(for meetingID: UUID) {
        guard !isRunning(for: meetingID) else { return }
        jobs.removeValue(forKey: meetingID)
    }

    /// Identify the speakers in a saved meeting and relabel its transcript.
    /// Returns whether the transcript changed. Never throws: any failure
    /// (no audio, models can't download, …) leaves the meeting untouched and
    /// is recorded on the job for the UI.
    @discardableResult
    func diarize(meetingID: UUID, store: any MeetingStore) async -> Bool {
        if let running = tasks[meetingID] { return await running.value }
        let job = DiarizationJob(meetingID: meetingID)
        jobs[meetingID] = job
        let task = Task { await self.run(job, store: store) }
        tasks[meetingID] = task
        let changed = await task.value
        tasks[meetingID] = nil
        return changed
    }

    // MARK: - Pipeline

    private func run(_ job: DiarizationJob, store: any MeetingStore) async -> Bool {
        let started = Date()
        do {
            // Resolve the folder now, not when the recording stopped: "Save & file"
            // may have moved or renamed it in the meantime.
            let handle = try await store.openMeeting(id: job.meetingID)
            let folder = MeetingFolder(url: handle.folderURL)

            // A 1:1 has one remote person — nothing to split (and on real
            // recordings the diarizer would split one voice into several).
            guard case .diarize(let maxSpeakers) = DiarizationAssigner.policy(for: handle.meeting) else {
                job.status = .completed(speakers: 0)
                return false
            }
            guard FileManager.default.fileExists(atPath: folder.audioURL.path) else {
                job.status = .failed("This meeting has no audio recording.")
                return false
            }

            let audioURL = folder.audioURL
            let decoded: (samples: [Float], duration: TimeInterval)
            do {
                decoded = try await Task.detached(priority: .utility) {
                    try StereoAudioLoader.loadSystemChannel(url: audioURL)
                }.value
            } catch {
                job.status = .failed("This meeting's audio file couldn't be read. It may be from a recording that was interrupted.")
                return false
            }
            let (samples, duration) = decoded
            let turns = try await diarizer.diarize(samples: samples, maxSpeakers: maxSpeakers)

            let segments = try await store.loadTranscript(for: job.meetingID)
            let offset = Self.timelineOffset(segments: segments, audioDuration: duration, folder: folder)
            let result = DiarizationAssigner.assign(
                turns: turns.map { .init(start: $0.start, end: $0.end, cluster: $0.cluster) },
                segments: segments,
                timelineOffset: offset
            )

            if result.changed {
                // Read-modify-write keyed by segment id, as close to the write as
                // possible, so edits made meanwhile keep their text.
                let labels = Dictionary(uniqueKeysWithValues: result.segments.map { ($0.id, $0.speakerId) })
                var fresh = try await store.loadTranscript(for: job.meetingID)
                for i in fresh.indices where fresh[i].channel == .system {
                    if let label = labels[fresh[i].id] { fresh[i].speakerId = label }
                }
                // Participants first: replaceTranscript re-renders transcript.md
                // from the meeting.json on disk.
                var meeting = try await store.openMeeting(id: job.meetingID).meeting
                meeting.participants = DiarizationAssigner.mergeParticipants(
                    existing: meeting.participants, assigned: result.speakers
                )
                try await store.updateMeeting(meeting)
                try await store.replaceTranscript(fresh, for: job.meetingID)
            }

            Self.writeStats(
                DiarizationStats(
                    clustersFound: Set(turns.map(\.cluster)).count,
                    speakersAssigned: result.speakers.count,
                    speechSecondsBySpeaker: result.speechBySpeaker,
                    audioSeconds: duration,
                    timelineOffset: offset,
                    runtimeSeconds: Date().timeIntervalSince(started),
                    changed: result.changed
                ),
                in: (try? await store.openMeeting(id: job.meetingID).folderURL) ?? folder.url
            )
            job.status = .completed(speakers: result.changed ? result.speakers.count : 0)
            return result.changed
        } catch {
            job.status = .failed(error.localizedDescription)
            return false
        }
    }

    /// Transcript time at which `audio.m4a` starts. Zero, except after
    /// "Resume recording": the file then holds only the latest session, while the
    /// transcript continues from the earlier one.
    private static func timelineOffset(segments: [TranscriptSegment], audioDuration: TimeInterval, folder: MeetingFolder) -> TimeInterval {
        let resumed = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path))?
            .contains { $0.hasPrefix("audio-before-resume-") } ?? false
        guard resumed else { return 0 }
        let transcriptEnd = segments.map(\.end).max() ?? 0
        return max(0, transcriptEnd - audioDuration)
    }

    private struct DiarizationStats: Encodable {
        let clustersFound: Int
        let speakersAssigned: Int
        let speechSecondsBySpeaker: [String: TimeInterval]
        let audioSeconds: TimeInterval
        let timelineOffset: TimeInterval
        let runtimeSeconds: TimeInterval
        let changed: Bool
    }

    private static func writeStats(_ stats: DiarizationStats, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stats) {
            try? data.write(to: folder.appendingPathComponent("diar-stats.json"))
        }
    }
}
