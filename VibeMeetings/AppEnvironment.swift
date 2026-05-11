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

    /// The current in-progress recording, if any. Set by `RootView` when a
    /// meeting starts; cleared when the user stops. Drives the banner's
    /// "don't suggest while already recording" rule and is the single source
    /// of truth for whether a recording is live.
    var activeRecordingController: RecordingController?

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

    /// Live state snapshot for the privacy badge.
    var privacyState: PrivacyState = .localOnly

    enum PrivacyState: Sendable, Equatable {
        case localOnly
        case lan(host: String)
        case cloud(provider: String)
        case downloadingModel(progress: Double)
    }

    /// Which summarization backend is active: "ollama" or "openai".
    var activeSummarizationKind: String

    /// OpenAI API key (persisted in UserDefaults; empty = not configured).
    var openAIApiKey: String

    /// Selected OpenAI model id for summarization.
    var selectedOpenAIModelId: String

    static let defaultOllamaURL = URL(string: "http://127.0.0.1:11434")!
    private static let ollamaURLKey = "VibeMeetings.OllamaBaseURL"
    private static let micDeviceUIDKey = "VibeMeetings.SelectedMicDeviceUID"
    private static let openAIKeyKey = "VibeMeetings.OpenAI.APIKey"
    private static let openAIModelKey = "VibeMeetings.OpenAI.SelectedModelId"
    private static let summEngineKey = "VibeMeetings.SummarizationEngine"

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

        if storedSummKind == OpenAIEngine.kind && !storedOpenAIKey.isEmpty {
            self.summarizationEngine = OpenAIEngine(apiKey: storedOpenAIKey, promptBundle: .main)
            self.activeSummarizationKind = OpenAIEngine.kind
        } else {
            self.summarizationEngine = OllamaEngine(baseURL: resolvedOllama, promptBundle: .main)
            self.activeSummarizationKind = OllamaEngine.kind
        }

        let cal = EventKitCalendarService()
        self.calendarService = cal
        self.bannerCoordinator = BannerCoordinator(calendar: cal)

        if storedSummKind == OpenAIEngine.kind && !storedOpenAIKey.isEmpty {
            self.privacyState = .cloud(provider: "OpenAI")
        } else {
            self.privacyState = AppEnvironment.privacyState(for: resolvedOllama)
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
        self.privacyState = AppEnvironment.privacyState(for: url)
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
        self.privacyState = .cloud(provider: "OpenAI")
    }

    /// Switch back to Ollama summarization.
    func setOllamaAsSummarizer() {
        self.activeSummarizationKind = OllamaEngine.kind
        UserDefaults.standard.set(OllamaEngine.kind, forKey: Self.summEngineKey)
        self.summarizationEngine = OllamaEngine(baseURL: ollamaBaseURL, promptBundle: .main)
        self.privacyState = AppEnvironment.privacyState(for: ollamaBaseURL)
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

    private static func privacyState(for url: URL) -> PrivacyState {
        guard let host = url.host, !LocalhostOnlySession.isLoopback(host) else {
            return .localOnly
        }
        return .lan(host: host)
    }
}
