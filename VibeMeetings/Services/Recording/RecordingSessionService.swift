import AppKit
import Foundation
import Observation
import VMCalendar
import VMCore
import VMStorage
import VMSummarization

/// The one place recordings start and stop.
///
/// Every entry point (the New Meeting sheet, "Resume recording", notification
/// buttons, the floating overlay, the menu bar) goes through here, so the
/// side-effects — dock badge, call-reminder state, auto-end detection,
/// post-recording sheet, background summary — happen exactly once, and
/// recording works with the main window closed.
@Observable
@MainActor
final class RecordingSessionService {
    enum StopReason { case user, meetingEnded }

    /// The in-progress recording, if any.
    private(set) var controller: RecordingController?
    /// True between a start request and the meeting being created.
    private(set) var isStarting = false
    /// Last start failure, shown briefly by the overlay.
    private(set) var lastStartError: String?

    @ObservationIgnored private unowned let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// A recording is being set up or is running — further starts are ignored.
    var isBusy: Bool { isStarting || controller != nil }

    var isRecording: Bool { controller?.state == .recording }

    // MARK: - Start

    /// Creates the meeting and starts recording it. Returns `nil` if a
    /// recording is already running or starting.
    @discardableResult
    func start(_ request: MeetingStartRequest, fallbackParent: FolderNode? = nil) async throws -> MeetingHandle? {
        guard !isBusy else { return nil }
        isStarting = true
        lastStartError = nil
        defer { isStarting = false }

        let handle = try await MeetingDraftFactory.createMeeting(for: request, env: env, fallbackParent: fallbackParent)
        let c = RecordingController(env: env)
        begin(c, meetingID: handle.meeting.id, eventID: handle.meeting.calendarEventID)
        Task { await self.run(c) { await c.start(handle: handle) } }
        return handle
    }

    /// Resume recording into an existing meeting.
    func resume(handle: MeetingHandle) async {
        guard !isBusy else { return }
        let c = RecordingController(env: env)
        begin(c, meetingID: handle.meeting.id, eventID: handle.meeting.calendarEventID)
        await run(c) { await c.resume(handle: handle) }
    }

    /// One-click start for the call currently detected from mic activity (or
    /// just "now"), linked to the best-matching calendar event.
    func startDetectedCall() async {
        guard !isBusy else { return }
        let call = env.bannerCoordinator.currentCall
        let event = await env.bannerCoordinator.bestCurrentEvent()
        let app = call.flatMap { MeetingAppCatalog.app(withID: $0.client.appID) }
        await startReportingErrors(.detectedCall(
            appName: call?.client.appName,
            platform: app?.platform,
            event: event
        ))
    }

    /// One-click start for a specific calendar event (by id).
    func startEvent(id: String) async {
        if let event = await env.calendarService.upcomingEvents(within: 24 * 60 * 60).first(where: { $0.id == id }) {
            await startReportingErrors(.event(event))
        } else {
            // Event vanished (deleted/moved out of range) — fall back to the sheet.
            env.appRouter.requestNewMeeting()
            env.presenter.show()
        }
    }

    /// Open the meeting's join link, then start recording it.
    func joinAndRecord(event: CalendarEvent) async {
        if let url = event.meetingLink?.url {
            NSWorkspace.shared.open(url)
        }
        await startReportingErrors(.event(event))
    }

    func joinAndRecord(url: URL?, eventID: String?) async {
        if let eventID,
           let event = await env.calendarService.upcomingEvents(within: 24 * 60 * 60).first(where: { $0.id == eventID }) {
            await joinAndRecord(event: event)
            return
        }
        if let url { NSWorkspace.shared.open(url) }
        await startDetectedCall()
    }

    private func startReportingErrors(_ request: MeetingStartRequest) async {
        do {
            try await start(request)
        } catch {
            await reportStartFailure(error.localizedDescription)
        }
    }

    private func begin(_ c: RecordingController, meetingID: UUID, eventID: String?) {
        controller = c
        env.appRouter.selectMeetingID = meetingID
        env.bannerCoordinator.recordingDidStart()
        env.eventReminders.recordingStarted(eventID: eventID)
        env.notifications.removeCallReminder()
        DockIconManager.showRecordingBadge()
    }

    /// Runs the controller's start and cleans up if it ends in an error.
    private func run(_ c: RecordingController, _ body: () async -> Void) async {
        await body()
        if case .error(let message) = c.state, controller === c {
            controller = nil
            DockIconManager.clearRecordingBadge()
            env.bannerCoordinator.recordingFailed()
            env.meetingEndDetector.recordingDidStop()
            await reportStartFailure(message)
        }
    }

    private func reportStartFailure(_ message: String) async {
        lastStartError = message
        await env.notifications.postRecordingStartFailed(message)
        // Clear the overlay's error state after a while.
        Task {
            try? await Task.sleep(for: .seconds(15))
            if self.lastStartError == message { self.lastStartError = nil }
        }
    }

    // MARK: - Stop

    /// Stops the recording, persists it, kicks off the background summary and
    /// queues the post-recording sheet.
    func stop(reason: StopReason = .user) async {
        // Only a running capture can be stopped; a start that's still loading
        // the model finishes (or fails) on its own.
        guard let controller, controller.state == .recording || controller.state == .paused,
              let handle = controller.meetingHandle
        else { return }
        _ = await controller.stop()
        guard self.controller === controller else { return }

        let meetingID = handle.meeting.id
        let folderURL = handle.folderURL

        // Snapshot data needed for summary before clearing the controller.
        let segments = controller.liveSegments.map { seg in
            var s = seg
            s.isPartial = false
            return s
        }
        let meeting = handle.meeting
        let userNotes = controller.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : controller.notes

        self.controller = nil
        DockIconManager.clearRecordingBadge()
        env.bannerCoordinator.recordingDidStop()
        env.meetingEndDetector.recordingDidStop()
        env.notifications.removeMeetingEndSuggestion()
        env.appRouter.pendingPostRecording = .init(meetingID: meetingID, folderURL: folderURL)

        if !env.presenter.isMainWindowVisible {
            await env.notifications.postRecordingSaved(meetingID: meetingID, title: meeting.title)
        }

        // Auto-generate the summary in the background (silently, no
        // notification) from the dual-channel live transcript, which
        // `RecordingController.stop()` has already cleaned and persisted.
        // NOTE: we deliberately do NOT re-transcribe the echo-reduced audio —
        // that file is mono with the other party spectrally removed, so it
        // would collapse both speakers into one and drop the "Others" side.
        guard !segments.isEmpty else { return }

        let modelId = env.activeSummarizationKind == OpenAIEngine.kind
            ? env.selectedOpenAIModelId
            : env.selectedOllamaModelId
        let prompt = env.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : env.customSystemPrompt

        env.summaryService.generate(
            meetingID: meetingID,
            meetingTitle: meeting.title,
            segments: segments,
            meeting: meeting,
            engine: env.summarizationEngine,
            modelId: modelId,
            userNotes: userNotes,
            customPrompt: prompt,
            store: env.meetingStore,
            silent: true
        )
    }
}
