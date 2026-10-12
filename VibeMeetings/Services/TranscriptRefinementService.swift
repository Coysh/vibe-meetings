import Foundation
import Observation
import os
import VMCore
import VMStorage
import VMTranscription

/// What an improved transcript was made with, kept next to the meeting.
struct RefinementRecord: Codable, Equatable {
    var model: String
    var date: Date
    var words: Int
    var liveWords: Int

    static let filename = "refined.json"
    /// The live transcript as it was before the first improvement, so it can always be restored.
    static let liveBackupFilename = "segments.live.json"

    static func read(in folder: URL) -> RefinementRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(filename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RefinementRecord.self, from: data)
    }

    func write(in folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: folder.appendingPathComponent(Self.filename), options: .atomic)
        }
    }

    static func hasLiveBackup(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(liveBackupFilename).path)
    }
}

/// The post-meeting transcript pass: transcribes the saved audio again with a larger model, and swaps the
/// result in for the live transcript (which is kept, to restore).
///
/// It's the biggest accuracy gain available: the live pass works in real time with whatever keeps up, while
/// this has the whole recording and no hurry. It never runs while a recording is in progress (it would
/// compete with the live transcription for the same hardware), and one meeting is done at a time.
@Observable
@MainActor
final class TranscriptRefinementService {
    enum Status: Equatable {
        case waiting(String)
        /// Getting the model ready; progress while it downloads.
        case preparing(Double?)
        case running(Double)
        /// The transcript is replaced; now splitting "Others" into individual speakers.
        case identifyingSpeakers
        case completed
        case failed(String)
    }

    /// One meeting that can be improved.
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let title: String
        let folder: URL
    }

    /// What a request to improve several meetings would do: the ones that will be improved, and why the rest won't.
    struct Plan: Equatable {
        var meetings: [Candidate] = []
        var alreadyImproved = 0
        var unavailable = 0
    }

    /// Progress through a run over several meetings.
    struct BulkProgress: Equatable {
        var done: Int
        var total: Int
        var current: String
        var improved = 0
        var failed = 0
    }

    private(set) var bulk: BulkProgress?
    /// How the last run over several meetings ended, until dismissed.
    private(set) var bulkSummary: String?
    private var bulkTask: Task<Void, Never>?
    private(set) var statuses: [UUID: Status] = [:]
    /// Meetings whose transcript has been improved. Seeded from disk when the library loads and kept current
    /// as passes finish, so lists can show it without touching the disk themselves.
    private(set) var improvedIDs: Set<UUID> = []
    private var tasks: [UUID: Task<Bool, Never>] = [:]
    /// One pass at a time: each wants most of the machine.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func status(for meetingID: UUID) -> Status? { statuses[meetingID] }

    func isActive(_ meetingID: UUID) -> Bool {
        switch statuses[meetingID] {
        case .waiting?, .preparing?, .running?, .identifyingSpeakers?: true
        default: false
        }
    }

    /// Dismiss a finished or failed status.
    func clear(_ meetingID: UUID) {
        if !isActive(meetingID) { statuses[meetingID] = nil }
    }

    func isImproved(_ meetingID: UUID) -> Bool { improvedIDs.contains(meetingID) }

    /// Re-read which meetings have been improved. Called whenever the library changes.
    func syncImproved(from tree: FolderNode?) {
        let fm = FileManager.default
        let ids = Set((tree?.allMeetingNodes ?? []).compactMap { node -> UUID? in
            guard let id = node.meeting?.id,
                  fm.fileExists(atPath: node.url.appendingPathComponent(RefinementRecord.filename).path) else { return nil }
            return id
        })
        if ids != improvedIDs { improvedIDs = ids }
    }

    func dismissBulkSummary() { bulkSummary = nil }

    func cancel(_ meetingID: UUID) {
        tasks[meetingID]?.cancel()
        tasks[meetingID] = nil
        statuses[meetingID] = nil
    }

    /// Why a meeting can't be improved, or nil if it can.
    static func unavailableReason(folder: URL) -> String? {
        let folderModel = MeetingFolder(url: folder)
        guard FileManager.default.fileExists(atPath: folderModel.audioURL.path) else {
            return "This meeting has no saved audio."
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.contains(where: { $0.hasPrefix("audio-before-resume") }) {
            // The audio file holds only the part recorded after resuming, so it can't rebuild the whole transcript.
            return "This meeting was resumed, so its audio doesn't cover the whole transcript."
        }
        return nil
    }

    /// Transcribe the meeting's saved audio again and replace its transcript with the result.
    /// Returns whether the transcript was replaced.
    ///
    /// `onWaitingForRecording` is called (once) the first time the pass has to wait for a recording to end,
    /// so the caller needn't hold other work back until then.
    @discardableResult
    func refine(
        meetingID: UUID,
        folderURL: URL,
        env: AppEnvironment,
        onWaitingForRecording: (@MainActor @Sendable () -> Void)? = nil
    ) async -> Bool {
        guard !isActive(meetingID) else { return false }
        // Before the first await, so a second request can't slip in behind this one.
        statuses[meetingID] = .waiting("Waiting to start…")
        // Where the meeting is now, not where it was when the caller looked: "Save & file" may have moved it.
        let folderURL = (try? await env.meetingStore.openMeeting(id: meetingID).folderURL) ?? folderURL
        if let reason = Self.unavailableReason(folder: folderURL) {
            statuses[meetingID] = .failed(reason)
            return false
        }
        let task = Task {
            await self.run(meetingID: meetingID, folderURL: folderURL, env: env, onWaitingForRecording: onWaitingForRecording)
        }
        tasks[meetingID] = task
        let replaced = await task.value
        tasks[meetingID] = nil
        return replaced
    }

    /// The meeting as something that can be improved, or nil if it has no finished recording to work from.
    static func candidate(for meeting: Meeting, folder: URL) -> Candidate? {
        guard meeting.endedAt != nil, meeting.hasAudio, unavailableReason(folder: folder) == nil else { return nil }
        return Candidate(id: meeting.id, title: meeting.title, folder: folder)
    }

    /// Sort `meetings` into those that will be improved and those that won't (no recording, or already done).
    static func plan(for meetings: [(meeting: Meeting, folder: URL)]) -> Plan {
        var plan = Plan()
        for (meeting, folder) in meetings {
            guard let candidate = candidate(for: meeting, folder: folder) else {
                plan.unavailable += 1
                continue
            }
            if RefinementRecord.read(in: folder) != nil {
                plan.alreadyImproved += 1
            } else {
                plan.meetings.append(candidate)
            }
        }
        return plan
    }

    /// Past meetings that haven't been improved and can be.
    static func improvableMeetings(in tree: FolderNode?) -> [Candidate] {
        let nodes = tree?.allMeetingNodes ?? []
        return plan(for: nodes.compactMap { node in node.meeting.map { ($0, node.url) } }).meetings
    }

    /// Improve every past meeting that can be, one after another, newest first. Pauses while recording.
    func improveAllPastMeetings(env: AppEnvironment) {
        improve(Self.improvableMeetings(in: env.folderTree), env: env)
    }

    /// Improve these meetings one after another, newest first. Pauses while recording.
    func improve(_ meetings: [Candidate], env: AppEnvironment) {
        guard bulk == nil else { return }
        let meetings = meetings.sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }
        guard let first = meetings.first else { return }
        bulkSummary = nil
        bulk = BulkProgress(done: 0, total: meetings.count, current: first.title)
        bulkTask = Task { [weak self] in
            var improved = 0
            var failed = 0
            for (index, meeting) in meetings.enumerated() {
                if Task.isCancelled { break }
                self?.bulk = BulkProgress(done: index, total: meetings.count, current: meeting.title, improved: improved, failed: failed)
                if await self?.refine(meetingID: meeting.id, folderURL: meeting.folder, env: env) == true {
                    improved += 1
                } else if case .failed? = self?.status(for: meeting.id) {
                    failed += 1
                }
                // Drop the per-meeting status so a long run doesn't leave a banner on every meeting.
                self?.clear(meeting.id)
            }
            if !Task.isCancelled {
                self?.bulkSummary = Self.summary(improved: improved, failed: failed)
            }
            self?.bulk = nil
            self?.bulkTask = nil
        }
    }

    private static func summary(improved: Int, failed: Int) -> String {
        var text = "Improved \(improved) transcript\(improved == 1 ? "" : "s")."
        if failed > 0 { text += " \(failed) couldn't be improved." }
        return text
    }

    func cancelBulk() {
        bulkTask?.cancel()
        bulkTask = nil
        bulk = nil
        for id in Array(tasks.keys) { cancel(id) }
    }

    /// Put the live transcript back.
    func restoreLiveTranscript(meetingID: UUID, folderURL: URL, env: AppEnvironment) async -> Bool {
        let backup = folderURL.appendingPathComponent(RefinementRecord.liveBackupFilename)
        guard let data = try? Data(contentsOf: backup),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else { return false }
        guard await env.attempt("restore the live transcript", {
            try await env.meetingStore.replaceTranscript(segments, for: meetingID)
        }) != nil else { return false }
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(RefinementRecord.filename))
        improvedIDs.remove(meetingID)
        statuses[meetingID] = nil
        return true
    }

    // MARK: - The pass

    private func run(
        meetingID: UUID,
        folderURL: URL,
        env: AppEnvironment,
        onWaitingForRecording: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        await acquire()
        defer { release() }

        var onWaiting = onWaitingForRecording
        while true {
            // Don't compete with a recording for the same hardware.
            while env.recordingService.isBusy {
                statuses[meetingID] = .waiting("Waiting for your recording to finish…")
                onWaiting?()
                onWaiting = nil
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { statuses[meetingID] = nil; return false }
            }

            let engine = WhisperKitEngine()
            statuses[meetingID] = .preparing(nil)
            do {
                try await engine.loadModel(id: env.refinementModelId) { [weak self] fraction in
                    Task { @MainActor in self?.setStatus(meetingID, .preparing(fraction)) }
                }
            } catch {
                statuses[meetingID] = .failed("Couldn't load the transcription model: \(error.localizedDescription)")
                return false
            }

            // A recording that starts mid-pass stops it, and it begins again afterwards.
            let interrupted = OSAllocatedUnfairLock(initialState: false)
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if env.recordingService.isBusy { interrupted.withLock { $0 = true } }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { watcher.cancel() }

            // Find the folder now, not when the recording stopped: "Save & file" may have moved or renamed it,
            // and the model can take minutes to download.
            guard let handle = try? await env.meetingStore.openMeeting(id: meetingID) else {
                statuses[meetingID] = .failed("This meeting can't be found any more.")
                return false
            }
            let meeting = handle.meeting
            let audio = MeetingFolder(url: handle.folderURL).audioURL
            let options = env.transcriptionOptions(for: meeting, commitStreaming: false)
            let echo: EchoDedup.Config = Self.recordedOnHeadphones(folder: handle.folderURL) ? .conservative : .default
            statuses[meetingID] = .running(0)

            do {
                let result = try await TranscriptRefiner.refine(
                    audioURL: audio,
                    engine: engine,
                    options: options,
                    echo: echo,
                    vocabulary: env.vocabularyTerms(for: meeting),
                    progress: { [weak self] fraction in
                        Task { @MainActor in self?.setStatus(meetingID, .running(fraction)) }
                        return !interrupted.withLock { $0 }
                    }
                )
                return await install(result, meetingID: meetingID, folderURL: folderURL, env: env)
            } catch is CancellationError {
                if Task.isCancelled { statuses[meetingID] = nil; return false }
                continue   // interrupted by a recording: wait it out, then start again
            } catch {
                statuses[meetingID] = .failed("Couldn't improve the transcript: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Swap the new transcript in, keeping the live one.
    private func install(_ result: TranscriptRefiner.Result, meetingID: UUID, folderURL: URL, env: AppEnvironment) async -> Bool {
        // The pass can take a long while; the meeting may have been filed or renamed since it started.
        let folderURL = (try? await env.meetingStore.openMeeting(id: meetingID).folderURL) ?? folderURL
        let live = (try? await env.meetingStore.loadTranscript(for: meetingID)) ?? []
        let liveWords = Self.wordCount(live)
        let newWords = Self.wordCount(result.segments)

        guard newWords > 0 else {
            statuses[meetingID] = .failed("No speech was found in the recording, so the transcript was left as it was.")
            return false
        }
        // A pass that finds far less than the live one did has gone wrong (a silent channel, a bad file).
        // The live transcript is the safer answer.
        if liveWords >= 60, Double(newWords) < Double(liveWords) * 0.4 {
            statuses[meetingID] = .failed("The improved transcript was much shorter than the live one, so the live transcript was kept.")
            return false
        }

        // Keep the live transcript the first time only, so "restore" always means the original.
        let segmentsFile = MeetingFolder(url: folderURL).segmentsURL
        let backup = folderURL.appendingPathComponent(RefinementRecord.liveBackupFilename)
        if !FileManager.default.fileExists(atPath: backup.path), FileManager.default.fileExists(atPath: segmentsFile.path) {
            try? FileManager.default.copyItem(at: segmentsFile, to: backup)
        }

        guard await env.attempt("save the improved transcript", {
            try await env.meetingStore.replaceTranscript(result.segments, for: meetingID)
        }) != nil else {
            statuses[meetingID] = .failed("Couldn't save the improved transcript.")
            return false
        }
        RefinementRecord(model: env.refinementModelId, date: Date(), words: newWords, liveWords: liveWords).write(in: folderURL)
        improvedIDs.insert(meetingID)

        // The new transcript labels the other side "Others" again, so split it into speakers again — when
        // speaker detection is on, or the meeting had been split before. (A 1:1 has nothing to split.)
        let meeting = try? await env.meetingStore.openMeeting(id: meetingID).meeting
        let hadSplit = meeting?.participants.contains(where: { $0.id.hasPrefix("others-") }) ?? false
        if env.speakerDetectionEnabled || hadSplit {
            statuses[meetingID] = .identifyingSpeakers
            _ = await env.diarizationService.diarize(meetingID: meetingID, store: env.meetingStore)
            if Task.isCancelled { statuses[meetingID] = nil; return true }
        }
        statuses[meetingID] = .completed
        return true
    }

    // MARK: - Helpers

    private func setStatus(_ meetingID: UUID, _ status: Status) {
        // Late progress from a pass that has already ended must not overwrite its outcome.
        guard isActive(meetingID) else { return }
        statuses[meetingID] = status
    }

    private static func wordCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The echo canceller noted that this recording was made on headphones (so there's little echo to remove).
    private static func recordedOnHeadphones(folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("aec-stats.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (json["mode"] as? String) == "bypass"
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }
}
