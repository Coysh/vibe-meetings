import Foundation
import Observation
import VMCore
import VMSummarization

/// Tracks the status of a single summary generation job.
@Observable
@MainActor
final class SummaryJob {
    enum Status: Sendable {
        case running
        case completed
        case failed(String)
    }

    let meetingID: UUID
    private(set) var status: Status = .running
    private(set) var progressText: String = "Generating summary…"
    private(set) var partialSummary: String = ""
    private(set) var error: String?

    init(meetingID: UUID) {
        self.meetingID = meetingID
    }

    fileprivate func appendChunk(_ chunk: String) {
        partialSummary += chunk
    }

    fileprivate func complete() {
        status = .completed
        progressText = "Summary complete"
    }

    fileprivate func fail(with message: String) {
        status = .failed(message)
        error = message
        progressText = "Summary failed"
    }
}

/// App-wide service that runs summary generation in the background.
/// Lives on `AppEnvironment` so jobs survive view lifecycle (navigation away and back).
@Observable
@MainActor
final class SummaryGenerationService {
    private var jobs: [UUID: SummaryJob] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// When set to `false`, suppresses the "Summary Ready" system notification.
    /// Defaults to `true`; bound to `AppEnvironment.notifySummaryReady`.
    var notificationsEnabled: Bool = true

    /// Posts the "Summary Ready" notification. Set by `AppEnvironment`.
    var notifications: NotificationManager?

    /// Returns the in-flight or most-recently-completed job for a meeting, if any.
    func job(for meetingID: UUID) -> SummaryJob? {
        jobs[meetingID]
    }

    /// Returns true if a job for this meeting is currently running.
    func isRunning(for meetingID: UUID) -> Bool {
        guard let job = jobs[meetingID] else { return false }
        if case .running = job.status { return true }
        return false
    }

    /// Start generating a summary in the background. If a job is already running
    /// for this meeting, it is cancelled and replaced.
    ///
    /// - Parameter silent: When `true`, skips the local notification on completion.
    ///   Used for auto-generated summaries triggered when recording stops.
    /// - Returns: the running task, for callers that need to wait until the summary is written.
    @discardableResult
    func generate(
        meetingID: UUID,
        meetingTitle: String,
        segments: [TranscriptSegment],
        meeting: Meeting,
        engine: any SummarizationEngine,
        modelId: String,
        userNotes: String?,
        customPrompt: String?,
        store: any MeetingStore,
        silent: Bool = false
    ) -> Task<Void, Never> {
        // Cancel existing job if any.
        tasks[meetingID]?.cancel()

        let job = SummaryJob(meetingID: meetingID)
        jobs[meetingID] = job

        let task = Task { [weak self] in
            do {
                let stream = engine.summarize(
                    transcript: segments,
                    meeting: meeting,
                    modelId: modelId,
                    style: .standard,
                    userNotes: userNotes,
                    customPrompt: customPrompt
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    job.appendChunk(chunk)
                }
                // Persist completed summary. If it can't be saved the job has
                // failed — don't announce a summary that isn't on disk.
                try await store.writeSummary(job.partialSummary, for: meetingID)
                job.complete()

                // Post a local notification unless silent (auto-generated) or disabled in settings.
                if !silent, self?.notificationsEnabled == true {
                    await self?.notifications?.postSummaryReady(meetingID: meetingID, title: meetingTitle)
                }
            } catch {
                if !Task.isCancelled {
                    job.fail(with: error.localizedDescription)
                }
            }
            // A run that was replaced mustn't forget the one that replaced it.
            if self?.jobs[meetingID] === job { self?.tasks[meetingID] = nil }
        }
        tasks[meetingID] = task
        return task
    }

    // MARK: - Templates

    /// One template run on one meeting.
    struct TemplateKey: Hashable, Sendable {
        let meetingID: UUID
        let templateID: String
    }

    private var templateJobs: [TemplateKey: SummaryJob] = [:]
    private var templateTasks: [TemplateKey: Task<Void, Never>] = [:]

    /// Bumped each time a template run ends, so a meeting's page knows to re-read its outputs.
    private(set) var templateRevision = 0

    func templateJob(for key: TemplateKey) -> SummaryJob? {
        templateJobs[key]
    }

    func isRunning(_ key: TemplateKey) -> Bool {
        guard let job = templateJobs[key] else { return false }
        if case .running = job.status { return true }
        return false
    }

    /// Where a template's output lives inside a meeting's folder.
    static func templateOutputURL(in folder: URL, templateID: String) -> URL {
        folder.appendingPathComponent("templates").appendingPathComponent("\(templateID).md")
    }

    /// Run `systemPrompt` over a meeting's transcript and save the result in the
    /// meeting's `templates/` folder — never over the main summary. The file is only
    /// written when the run completes, so a failed regenerate leaves the earlier
    /// output in place.
    /// - Returns: the running task, for callers that need to wait until it's written.
    @discardableResult
    func generateTemplate(
        key: TemplateKey,
        segments: [TranscriptSegment],
        meeting: Meeting,
        engine: any SummarizationEngine,
        modelId: String,
        userNotes: String?,
        systemPrompt: String,
        store: any MeetingStore
    ) -> Task<Void, Never> {
        templateTasks[key]?.cancel()

        let job = SummaryJob(meetingID: key.meetingID)
        templateJobs[key] = job

        let task = Task { [weak self] in
            do {
                let stream = engine.summarize(
                    transcript: segments,
                    meeting: meeting,
                    modelId: modelId,
                    style: .standard,
                    userNotes: userNotes,
                    customPrompt: systemPrompt
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    job.appendChunk(chunk)
                }
                // Found now, not when the run started: the meeting may have been filed or renamed meanwhile,
                // and writing to the old path would bring the old folder back.
                let folder = try await store.openMeeting(id: key.meetingID).folderURL
                let outputURL = Self.templateOutputURL(in: folder, templateID: key.templateID)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try job.partialSummary.write(to: outputURL, atomically: true, encoding: .utf8)
                job.complete()
            } catch {
                if !Task.isCancelled {
                    job.fail(with: error.localizedDescription)
                }
            }
            if !Task.isCancelled {
                self?.templateRevision += 1
            }
            // A run that was replaced mustn't forget the one that replaced it.
            if self?.templateJobs[key] === job { self?.templateTasks[key] = nil }
        }
        templateTasks[key] = task
        return task
    }

    // MARK: - Waiting to be written

    /// Meetings whose summary is waiting for something else first (the improved transcript).
    private(set) var pendingSummaryIDs: Set<UUID> = []
    /// Templates queued behind a meeting's summary, in the order they'll be written.
    private(set) var pendingTemplateIDs: [UUID: [String]] = [:]

    func isSummaryPending(_ meetingID: UUID) -> Bool { pendingSummaryIDs.contains(meetingID) }

    func setSummaryPending(_ pending: Bool, for meetingID: UUID) {
        if pending { pendingSummaryIDs.insert(meetingID) } else { pendingSummaryIDs.remove(meetingID) }
    }

    func queueTemplates(_ templateIDs: [String], for meetingID: UUID) {
        var queued = pendingTemplateIDs[meetingID] ?? []
        for id in templateIDs where !queued.contains(id) { queued.append(id) }
        if !queued.isEmpty { pendingTemplateIDs[meetingID] = queued }
    }

    func dequeueTemplate(_ templateID: String, for meetingID: UUID) {
        guard var queued = pendingTemplateIDs[meetingID] else { return }
        queued.removeAll { $0 == templateID }
        pendingTemplateIDs[meetingID] = queued.isEmpty ? nil : queued
    }

    func isTemplatePending(_ key: TemplateKey) -> Bool {
        pendingTemplateIDs[key.meetingID]?.contains(key.templateID) == true
    }

    /// Forget everything that was waiting on this meeting (it was deleted, or has nothing to write up).
    func clearPending(for meetingID: UUID) {
        pendingSummaryIDs.remove(meetingID)
        pendingTemplateIDs[meetingID] = nil
    }

    /// Templates waiting or being written for a meeting, so its page can show their tabs.
    func activeTemplateIDs(for meetingID: UUID) -> [String] {
        var ids = pendingTemplateIDs[meetingID] ?? []
        for key in templateJobs.keys where key.meetingID == meetingID && isRunning(key) && !ids.contains(key.templateID) {
            ids.append(key.templateID)
        }
        return ids
    }

    /// Stop a run and forget it. Any saved output is untouched.
    func clearTemplateJob(_ key: TemplateKey) {
        templateTasks[key]?.cancel()
        templateTasks.removeValue(forKey: key)
        templateJobs.removeValue(forKey: key)
    }

    /// Stop an in-flight job and forget it. The previously saved summary (if
    /// any) is untouched, since a summary is only written when a job completes.
    func cancel(for meetingID: UUID) {
        clearJob(for: meetingID)
    }

    /// Clear a completed or failed job so it's no longer tracked.
    func clearJob(for meetingID: UUID) {
        tasks[meetingID]?.cancel()
        tasks.removeValue(forKey: meetingID)
        jobs.removeValue(forKey: meetingID)
    }
}

// MARK: - Writing a meeting up

extension AppEnvironment {
    /// Write a finished meeting up: the summary, then (with `includeDefaults`) each default template — one
    /// after another, since a local model shouldn't run several at once. The transcript, details and notes
    /// are read from disk now, so this uses the improved transcript when there is one; `fallback` is only
    /// for a meeting with nothing saved yet.
    func writeUps(for meetingID: UUID, includeDefaults: Bool, fallback: [TranscriptSegment] = []) async {
        // Straight away, so the page stops saying "waiting" and a second request can't start another write-up.
        summaryService.setSummaryPending(false, for: meetingID)
        let templates = includeDefaults ? summaryTemplates.defaultTemplates : []
        if includeDefaults {
            // Only defaults are ever queued: drop one that stopped being a default while this meeting waited.
            for stale in summaryService.pendingTemplateIDs[meetingID] ?? [] where !templates.contains(where: { $0.id == stale }) {
                summaryService.dequeueTemplate(stale, for: meetingID)
            }
        }
        summaryService.queueTemplates(templates.map(\.id), for: meetingID)

        guard let handle = try? await meetingStore.openMeeting(id: meetingID) else {
            summaryService.clearPending(for: meetingID)   // the meeting was deleted meanwhile
            return
        }
        let saved = (try? await meetingStore.loadTranscript(for: meetingID)) ?? []
        let segments = saved.isEmpty ? fallback : saved
        guard !segments.isEmpty else {
            summaryService.clearPending(for: meetingID)
            return
        }
        let meeting = handle.meeting
        let notes = (try? await meetingStore.loadNotes(for: meetingID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userNotes = (notes?.isEmpty ?? true) ? nil : notes

        await summaryService.generate(
            meetingID: meetingID,
            meetingTitle: meeting.title,
            segments: segments,
            meeting: meeting,
            engine: summarizationEngine,
            modelId: summarizationModelId,
            userNotes: userNotes,
            customPrompt: summaryPromptOverride,
            store: meetingStore,
            silent: true
        ).value

        for queued in templates {
            let key = SummaryGenerationService.TemplateKey(meetingID: meetingID, templateID: queued.id)
            // Skip one whose tab was closed while it waited, or whose template has been deleted.
            guard summaryService.isTemplatePending(key), let template = summaryTemplates.template(id: queued.id) else {
                summaryService.dequeueTemplate(queued.id, for: meetingID)
                continue
            }
            summaryService.dequeueTemplate(template.id, for: meetingID)
            await summaryService.generateTemplate(
                key: key,
                segments: segments,
                meeting: meeting,
                engine: summarizationEngine,
                modelId: summarizationModelId,
                userNotes: userNotes,
                systemPrompt: template.systemPrompt,
                store: meetingStore
            ).value
        }
    }
}
