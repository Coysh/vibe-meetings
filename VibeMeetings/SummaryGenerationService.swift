import Foundation
import Observation
import UserNotifications
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
    func generate(
        meetingID: UUID,
        meetingTitle: String,
        segments: [TranscriptSegment],
        meeting: Meeting,
        engine: any SummarizationEngine,
        modelId: String,
        userNotes: String?,
        customPrompt: String?,
        store: any MeetingStore
    ) {
        // Cancel existing job if any.
        tasks[meetingID]?.cancel()

        let job = SummaryJob(meetingID: meetingID)
        jobs[meetingID] = job

        tasks[meetingID] = Task { [weak self] in
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
                // Persist completed summary.
                try? await store.writeSummary(job.partialSummary, for: meetingID)
                job.complete()

                // Post a local notification.
                await self?.postCompletionNotification(title: meetingTitle)
            } catch {
                if !Task.isCancelled {
                    job.fail(with: error.localizedDescription)
                }
            }
            self?.tasks[meetingID] = nil
        }
    }

    /// Clear a completed or failed job so it's no longer tracked.
    func clearJob(for meetingID: UUID) {
        tasks[meetingID]?.cancel()
        tasks.removeValue(forKey: meetingID)
        jobs.removeValue(forKey: meetingID)
    }

    // MARK: - Notifications

    private func postCompletionNotification(title: String) async {
        let center = UNUserNotificationCenter.current()
        // Request permission if not already granted (no-op if already allowed).
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Summary Ready"
        content.body = "Summary for \"\(title)\" is complete."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "summary-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        try? await center.add(request)
    }
}
