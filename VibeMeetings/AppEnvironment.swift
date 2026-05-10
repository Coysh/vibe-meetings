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

    /// User-configured Ollama base URL. Defaults to `http://127.0.0.1:11434`;
    /// can be pointed at a self-hosted instance on the LAN
    /// (e.g. `http://192.168.1.50:11434`). The single non-loopback host this
    /// app's `LocalhostOnlySession` allows.
    var ollamaBaseURL: URL

    /// Live state snapshot for the privacy badge.
    var privacyState: PrivacyState = .localOnly

    enum PrivacyState: Sendable, Equatable {
        case localOnly
        case lan(host: String)
        case downloadingModel(progress: Double)
    }

    static let defaultOllamaURL = URL(string: "http://127.0.0.1:11434")!
    private static let ollamaURLKey = "VibeMeetings.OllamaBaseURL"

    init() throws {
        let defaults = UserDefaults.standard
        let rootKey = "VibeMeetings.RootURL.bookmark"
        let modelKey = "VibeMeetings.SelectedTranscriptionModelId"
        let ollamaModelKey = "VibeMeetings.SelectedOllamaModelId"

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = homeDir.appendingPathComponent("MeetingNotes")

        if let bookmark = defaults.data(forKey: rootKey) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                self.rootURL = resolved
            } else {
                self.rootURL = defaultRoot
            }
        } else {
            self.rootURL = defaultRoot
        }

        self.meetingStore = try FilesystemMeetingStore(rootURL: self.rootURL)

        let whisperKit = WhisperKitEngine()
        let whisperCpp = WhisperCppEngine()
        self.transcriptionEngines = [whisperKit, whisperCpp]
        self.activeTranscriptionEngine = whisperKit

        self.selectedModelId = defaults.string(forKey: modelKey) ?? "whisper-medium"
        self.selectedOllamaModelId = defaults.string(forKey: ollamaModelKey) ?? "llama3.1:8b-instruct-q4_K_M"

        let storedOllama = (defaults.string(forKey: Self.ollamaURLKey)).flatMap(URL.init(string:))
        let resolvedOllama = storedOllama ?? Self.defaultOllamaURL
        self.ollamaBaseURL = resolvedOllama
        AppEnvironment.applyAllowedOllamaHost(resolvedOllama)

        self.summarizationEngine = OllamaEngine(baseURL: resolvedOllama, promptBundle: .main)

        let cal = EventKitCalendarService()
        self.calendarService = cal
        self.bannerCoordinator = BannerCoordinator(calendar: cal)

        self.privacyState = AppEnvironment.privacyState(for: resolvedOllama)
    }

    func setRoot(_ url: URL) throws {
        self.rootURL = url
        self.meetingStore = try FilesystemMeetingStore(rootURL: url)
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "VibeMeetings.RootURL.bookmark")
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
