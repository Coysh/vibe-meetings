import AVFoundation
import CoreAudio
import Foundation
import Observation
import VMCore
import VMRecording
import VMStorage
import VMTranscription
import VMSummarization
import VMCalendar

/// Process-wide DI container. Held as a `@StateObject`-equivalent (here `@State`) on
/// `VibeMeetingsApp` and injected into views via `@Environment`.
@Observable
@MainActor
final class AppEnvironment {
    var rootURL: URL
    var meetingStore: FilesystemMeetingStore
    var transcriptionEngines: [any TranscriptionEngine]
    var activeTranscriptionEngine: any TranscriptionEngine
    var summarizationEngine: any SummarizationEngine
    let calendarService: any CalendarService
    let bannerCoordinator: BannerCoordinator
    let summaryService = SummaryGenerationService()
    let updateChecker = UpdateChecker()
    let sparkleUpdater = SparkleUpdater()
    let meetingEndDetector = MeetingEndDetector()
    let notifications = NotificationManager()
    let appRouter = AppRouter()
    @ObservationIgnored let presenter = MainWindowPresenter()
    @ObservationIgnored let eventReminders: EventReminderScheduler
    @ObservationIgnored private(set) lazy var recordingService = RecordingSessionService(env: self)
    @ObservationIgnored private var overlay: RecordingOverlayController?
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapped = false

    /// The current in-progress recording, if any. Owned by
    /// `RecordingSessionService`; drives the "don't suggest while already
    /// recording" rule and is the single source of truth for whether a
    /// recording is live.
    var activeRecordingController: RecordingController? { recordingService.controller }

    /// Selected default model id (`whisper-medium` per plan).
    var selectedModelId: String

    /// Selected Ollama model id (resolved at runtime from `/api/tags`).
    var selectedOllamaModelId: String

    /// The UID of the user's preferred microphone, or `nil` for system default.
    /// Persisted as a stable string that survives reboots (unlike `AudioDeviceID`).
    var selectedMicDeviceUID: String?

    /// Resolved `AudioDeviceID` from `selectedMicDeviceUID`. Returns `nil`
    /// when no specific device is selected (use system default).
    var selectedMicDeviceID: AudioDeviceID? {
        guard let uid = selectedMicDeviceUID else { return nil }
        return AudioDeviceEnumerator.inputDevices().first(where: { $0.uid == uid })?.id
    }

    /// User-configured Ollama base URL. Defaults to `http://127.0.0.1:11434`;
    /// can be pointed at a self-hosted instance on the LAN
    /// (e.g. `http://192.168.1.50:11434`). The single non-loopback host this
    /// app's `LocalhostOnlySession` allows.
    var ollamaBaseURL: URL

    /// Current folder tree, kept in sync with `meetingStore`. Owned here so
    /// views can read it without subscribing to the async stream themselves,
    /// and so that a refresh after folder creation lands before sheet dismissal.
    var folderTree: FolderNode?

    /// Which summarization backend is active: "ollama" or "openai".
    var activeSummarizationKind: String

    /// OpenAI API key (persisted in UserDefaults; empty = not configured).
    var openAIApiKey: String

    /// Selected OpenAI model id for summarization.
    var selectedOpenAIModelId: String

    /// User-editable system prompt override for summarization.
    /// When non-empty, replaces the bundled prompt sent to the LLM.
    var customSystemPrompt: String

    /// User-configured organizations shown in the org picker.
    var configuredOrgs: [String]

    static let defaultOllamaURL = URL(string: "http://127.0.0.1:11434")!
    private static let ollamaURLKey = "VibeMeetings.OllamaBaseURL"
    private static let micDeviceUIDKey = "VibeMeetings.SelectedMicDeviceUID"
    private static let openAIKeyKey = "VibeMeetings.OpenAI.APIKey"
    private static let openAIModelKey = "VibeMeetings.OpenAI.SelectedModelId"
    private static let summEngineKey = "VibeMeetings.SummarizationEngine"
    private static let customPromptKey = "VibeMeetings.CustomSystemPrompt"
    private static let configuredOrgsKey = "VibeMeetings.ConfiguredOrgs"

    // MARK: - Notification preferences

    private static let notifyMeetingDetectedKey = "VibeMeetings.Notify.MeetingDetected"
    private static let notifyPreMeetingReminderKey = "VibeMeetings.Notify.PreMeetingReminder"
    private static let notifySummaryReadyKey = "VibeMeetings.Notify.SummaryReady"
    private static let notifyReminderMinutesKey = "VibeMeetings.Notify.ReminderMinutes"
    private static let notifyEscalatingKey = "VibeMeetings.Notify.EscalatingReminders"
    private static let notifyAtEventStartKey = "VibeMeetings.Notify.AtEventStart"
    private static let detectBrowserCallsKey = "VibeMeetings.Detection.BrowserCalls"
    private static let showOverlayKey = "VibeMeetings.Overlay.Enabled"
    /// `@AppStorage` key for the menu bar extra (read by the App scene).
    static let menuBarEnabledKey = "VibeMeetings.MenuBar.Enabled"

    /// Whether to post a system notification when a meeting/call is detected.
    var notifyMeetingDetected: Bool {
        didSet { UserDefaults.standard.set(notifyMeetingDetected, forKey: Self.notifyMeetingDetectedKey) }
    }

    /// Whether to post pre-meeting reminder notifications before calendar events.
    var notifyPreMeetingReminder: Bool {
        didSet {
            UserDefaults.standard.set(notifyPreMeetingReminder, forKey: Self.notifyPreMeetingReminderKey)
            eventReminders.setNeedsReconcile()
        }
    }

    /// Whether to post a notification when summary generation completes.
    var notifySummaryReady: Bool {
        didSet {
            UserDefaults.standard.set(notifySummaryReady, forKey: Self.notifySummaryReadyKey)
            summaryService.notificationsEnabled = notifySummaryReady
        }
    }

    /// How many minutes before a meeting to send the reminder (default 3).
    var notifyReminderMinutes: Int {
        didSet {
            UserDefaults.standard.set(notifyReminderMinutes, forKey: Self.notifyReminderMinutesKey)
            eventReminders.setNeedsReconcile()
        }
    }

    /// Keep re-sending the "not recording" reminder (now, +2, +5, then every
    /// 5 min) instead of sending it once per call.
    var notifyEscalatingReminders: Bool {
        didSet { UserDefaults.standard.set(notifyEscalatingReminders, forKey: Self.notifyEscalatingKey) }
    }

    /// Also notify at the start time of calendar events with a join link.
    var notifyAtEventStart: Bool {
        didSet {
            UserDefaults.standard.set(notifyAtEventStart, forKey: Self.notifyAtEventStartKey)
            eventReminders.setNeedsReconcile()
        }
    }

    /// Treat a browser using the microphone as a call (Google Meet, Teams web…).
    var detectBrowserCalls: Bool {
        didSet { UserDefaults.standard.set(detectBrowserCalls, forKey: Self.detectBrowserCallsKey) }
    }

    /// Show the floating "not recording / recording" indicator.
    var showRecordingOverlay: Bool {
        didSet { UserDefaults.standard.set(showRecordingOverlay, forKey: Self.showOverlayKey) }
    }

    init() throws {
        let defaults = UserDefaults.standard
        let rootKey = "VibeMeetings.RootURL.bookmark"
        let modelKey = "VibeMeetings.SelectedTranscriptionModelId"
        let ollamaModelKey = "VibeMeetings.SelectedOllamaModelId"

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = homeDir.appendingPathComponent("MeetingNotes")

        let resolvedRoot: URL
        if let bookmark = defaults.data(forKey: rootKey) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                resolvedRoot = resolved
            } else {
                resolvedRoot = defaultRoot
            }
        } else {
            resolvedRoot = defaultRoot
        }

        self.rootURL = resolvedRoot

        // Failsafe: before the store scans, salvage any meeting whose recording
        // was cut short by a crash/force-quit — repair its crash-safe audio and
        // stamp an end time so the checkpointed transcript + audio are retrievable.
        RecordingRecoveryService.recoverInterruptedMeetings(in: resolvedRoot)

        self.meetingStore = try FilesystemMeetingStore(rootURL: resolvedRoot)

        let whisperKit = WhisperKitEngine()
        let whisperCpp = WhisperCppEngine()
        self.transcriptionEngines = [whisperKit, whisperCpp]
        self.activeTranscriptionEngine = whisperKit

        self.selectedModelId = defaults.string(forKey: modelKey) ?? "whisper-medium"
        self.selectedOllamaModelId = defaults.string(forKey: ollamaModelKey) ?? "llama3.1:8b-instruct-q4_K_M"
        self.selectedMicDeviceUID = defaults.string(forKey: Self.micDeviceUIDKey)

        let storedOllama = (defaults.string(forKey: Self.ollamaURLKey)).flatMap(URL.init(string:))
        let resolvedOllama = storedOllama ?? Self.defaultOllamaURL
        self.ollamaBaseURL = resolvedOllama
        AppEnvironment.applyAllowedOllamaHost(resolvedOllama)

        let storedOpenAIKey = defaults.string(forKey: Self.openAIKeyKey) ?? ""
        let storedOpenAIModel = defaults.string(forKey: Self.openAIModelKey) ?? "gpt-4o-mini"
        let storedSummKind = defaults.string(forKey: Self.summEngineKey) ?? OllamaEngine.kind

        self.openAIApiKey = storedOpenAIKey
        self.selectedOpenAIModelId = storedOpenAIModel
        self.customSystemPrompt = defaults.string(forKey: Self.customPromptKey) ?? ""
        self.configuredOrgs = defaults.stringArray(forKey: Self.configuredOrgsKey) ?? ["Evangelical Alliance", "Coysh Digital"]

        // Notification preferences (default: all enabled, 3-minute lead).
        self.notifyMeetingDetected = defaults.object(forKey: Self.notifyMeetingDetectedKey) as? Bool ?? true
        self.notifyPreMeetingReminder = defaults.object(forKey: Self.notifyPreMeetingReminderKey) as? Bool ?? true
        self.notifySummaryReady = defaults.object(forKey: Self.notifySummaryReadyKey) as? Bool ?? true
        self.notifyReminderMinutes = defaults.object(forKey: Self.notifyReminderMinutesKey) as? Int ?? 3
        self.notifyEscalatingReminders = defaults.object(forKey: Self.notifyEscalatingKey) as? Bool ?? true
        self.notifyAtEventStart = defaults.object(forKey: Self.notifyAtEventStartKey) as? Bool ?? true
        self.detectBrowserCalls = defaults.object(forKey: Self.detectBrowserCallsKey) as? Bool ?? true
        self.showRecordingOverlay = defaults.object(forKey: Self.showOverlayKey) as? Bool ?? true

        if storedSummKind == OpenAIEngine.kind && !storedOpenAIKey.isEmpty {
            self.summarizationEngine = OpenAIEngine(apiKey: storedOpenAIKey, promptBundle: .main)
            self.activeSummarizationKind = OpenAIEngine.kind
        } else {
            self.summarizationEngine = OllamaEngine(baseURL: resolvedOllama, promptBundle: .main)
            self.activeSummarizationKind = OllamaEngine.kind
        }

        let cal = EventKitCalendarService()
        self.calendarService = cal
        self.bannerCoordinator = BannerCoordinator(calendar: cal, notifications: notifications)
        self.eventReminders = EventReminderScheduler(calendar: cal, notifications: notifications)

        // Sync summary notification preference to the service (after all stored properties init).
        self.summaryService.notificationsEnabled = self.notifySummaryReady
        self.summaryService.notifications = notifications
        self.meetingEndDetector.notifications = notifications
    }

    /// Starts everything that must run whether or not a window is open:
    /// call detection, calendar reminders, the folder tree, the overlay.
    /// Called from `applicationDidFinishLaunching`; safe to call again.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        bannerCoordinator.configure(
            isRecording: { [unowned self] in recordingService.isBusy },
            activeEvent: { [unowned self] in activeRecordingController?.linkedCalendarEvent },
            meetingEndDetector: meetingEndDetector,
            notifyMeetingDetected: { [unowned self] in notifyMeetingDetected },
            escalatingReminders: { [unowned self] in notifyEscalatingReminders },
            detectBrowserCalls: { [unowned self] in detectBrowserCalls },
            isMainWindowKey: { [unowned self] in presenter.isMainWindowKey },
            onCalendarChanged: { [unowned self] in eventReminders.setNeedsReconcile() }
        )
        eventReminders.setProviders(
            leadMinutes: { [unowned self] in notifyPreMeetingReminder ? notifyReminderMinutes : nil },
            atStart: { [unowned self] in notifyAtEventStart }
        )

        startTreeSubscription()

        let overlay = RecordingOverlayController(env: self)
        overlay.start()
        self.overlay = overlay

        Task {
            // Request permissions on every launch. If already granted these are
            // no-ops; if macOS reset them after an app update (ad-hoc signing
            // changes the code identity) the user gets re-prompted immediately
            // instead of discovering broken features later.
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await calendarService.requestAccess()
            await notifications.ensureAuthorized()
            bannerCoordinator.start()
            eventReminders.start()
        }
    }

    private func startTreeSubscription() {
        treeTask?.cancel()
        let store = meetingStore
        treeTask = Task { [weak self] in
            for await tree in store.tree {
                self?.folderTree = tree
            }
        }
    }

    /// Fetch the latest tree from the store and update `folderTree` on the
    /// main actor. Call this after any mutation (create/rename/delete) to
    /// ensure the sidebar reflects the change before the calling sheet closes.
    func refreshFolderTree() async {
        folderTree = await meetingStore.currentTree()
    }

    func setRoot(_ url: URL) throws {
        self.rootURL = url
        self.meetingStore = try FilesystemMeetingStore(rootURL: url)
        if bootstrapped { startTreeSubscription() }
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "VibeMeetings.RootURL.bookmark")
        }
    }

    /// Update the selected microphone device and persist.
    /// Pass `nil` to revert to the system default input.
    func setMicDevice(uid: String?) {
        self.selectedMicDeviceUID = uid
        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.micDeviceUIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.micDeviceUIDKey)
        }
    }

    /// Update the Ollama endpoint, persist, rebuild the engine, and update
    /// the LocalhostOnlySession allowlist + privacy badge to match.
    func setOllamaBaseURL(_ url: URL) {
        self.ollamaBaseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.ollamaURLKey)
        AppEnvironment.applyAllowedOllamaHost(url)
        self.summarizationEngine = OllamaEngine(baseURL: url, promptBundle: .main)
    }

    /// Switch to the OpenAI summarization engine.
    func setOpenAI(apiKey: String, modelId: String) {
        self.openAIApiKey = apiKey
        self.selectedOpenAIModelId = modelId
        self.activeSummarizationKind = OpenAIEngine.kind
        UserDefaults.standard.set(apiKey, forKey: Self.openAIKeyKey)
        UserDefaults.standard.set(modelId, forKey: Self.openAIModelKey)
        UserDefaults.standard.set(OpenAIEngine.kind, forKey: Self.summEngineKey)
        self.summarizationEngine = OpenAIEngine(apiKey: apiKey, promptBundle: .main)
    }

    /// Switch back to Ollama summarization.
    func setOllamaAsSummarizer() {
        self.activeSummarizationKind = OllamaEngine.kind
        UserDefaults.standard.set(OllamaEngine.kind, forKey: Self.summEngineKey)
        self.summarizationEngine = OllamaEngine(baseURL: ollamaBaseURL, promptBundle: .main)
    }

    /// Update the configured organizations list and persist.
    func setConfiguredOrgs(_ orgs: [String]) {
        self.configuredOrgs = orgs
        UserDefaults.standard.set(orgs, forKey: Self.configuredOrgsKey)
    }

    private static func applyAllowedOllamaHost(_ url: URL) {
        guard let host = url.host?.lowercased() else {
            LocalhostOnlySession.setAllowedExtraHost(nil)
            return
        }
        if LocalhostOnlySession.isLoopback(host) {
            LocalhostOnlySession.setAllowedExtraHost(nil)
        } else {
            LocalhostOnlySession.setAllowedExtraHost(host)
        }
    }

}
