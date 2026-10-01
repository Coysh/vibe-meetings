import Foundation

/// How a process holding the microphone should be treated by call detection.
public enum MeetingAppKind: String, Sendable, Hashable {
    /// Dedicated calling app — mic use is a strong signal of a call.
    case call
    /// Web browser — mic use is probably a web call (Meet, Teams web, …) but
    /// browsers also use the mic for other things, so it gets a longer debounce.
    case browser
    /// System service that uses the mic for non-call reasons (Siri, dictation).
    case ignored
}

/// A known app that can hold the microphone.
public struct MeetingApp: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let platform: MeetingPlatform?
    public let kind: MeetingAppKind
    /// Bundle-ID prefixes (case-insensitive) that belong to this app. Prefixes
    /// rather than exact IDs so helper processes (`com.google.Chrome.helper`,
    /// `com.tinyspeck.slackmacgap.helper`, …) map back to their parent app.
    public let bundleIDPrefixes: [String]
    /// Process names for daemons that report no bundle ID (FaceTime's audio
    /// runs through `avconferenced`).
    public let processNames: [String]

    public init(
        id: String,
        displayName: String,
        platform: MeetingPlatform?,
        kind: MeetingAppKind,
        bundleIDPrefixes: [String],
        processNames: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.kind = kind
        self.bundleIDPrefixes = bundleIDPrefixes
        self.processNames = processNames
    }
}

/// Single source of truth for which apps count as meeting/call apps. Used by
/// call detection (who holds the mic), the calendar suggestion banner (is a
/// meeting app running) and auto-end detection (did the meeting app quit).
public enum MeetingAppCatalog {
    public static let teams = MeetingApp(
        id: "teams", displayName: "Microsoft Teams", platform: .teams, kind: .call,
        bundleIDPrefixes: ["com.microsoft.teams"],   // classic + teams2
        processNames: ["Microsoft Teams", "Microsoft Teams (work or school)", "Microsoft Teams classic"]
    )
    public static let zoom = MeetingApp(
        id: "zoom", displayName: "Zoom", platform: .zoom, kind: .call,
        bundleIDPrefixes: ["us.zoom."], processNames: ["zoom.us"]
    )
    public static let webex = MeetingApp(
        id: "webex", displayName: "Webex", platform: .webex, kind: .call,
        bundleIDPrefixes: ["com.cisco.webex", "com.webex."]
    )
    /// Safari (and other WebKit-based apps) capture the mic from the shared
    /// `com.apple.WebKit.GPU` process, so it can't be attributed more precisely.
    public static let safari = MeetingApp(
        id: "safari", displayName: "Safari", platform: nil, kind: .browser,
        bundleIDPrefixes: ["com.apple.WebKit.GPU", "com.apple.Safari"]
    )

    /// Looks up a catalog entry by `MeetingApp.id`.
    public static func app(withID id: String) -> MeetingApp? {
        all.first { $0.id == id }
    }

    /// Order matters only where prefixes could overlap; specific entries come
    /// before the generic Apple rule applied in `classify`.
    public static let all: [MeetingApp] = [
        teams,
        zoom,
        webex,
        MeetingApp(id: "slack", displayName: "Slack", platform: nil, kind: .call,
                   bundleIDPrefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(id: "facetime", displayName: "FaceTime", platform: nil, kind: .call,
                   bundleIDPrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"],
                   processNames: ["avconferenced", "FaceTime"]),
        MeetingApp(id: "discord", displayName: "Discord", platform: nil, kind: .call,
                   bundleIDPrefixes: ["com.hnc.Discord"]),
        MeetingApp(id: "whatsapp", displayName: "WhatsApp", platform: nil, kind: .call,
                   bundleIDPrefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        MeetingApp(id: "signal", displayName: "Signal", platform: nil, kind: .call,
                   bundleIDPrefixes: ["org.whispersystems.signal-desktop"]),
        MeetingApp(id: "skype", displayName: "Skype", platform: nil, kind: .call,
                   bundleIDPrefixes: ["com.skype."]),

        MeetingApp(id: "chrome", displayName: "Google Chrome", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["com.google.Chrome"]),
        MeetingApp(id: "edge", displayName: "Microsoft Edge", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["com.microsoft.edgemac"]),
        MeetingApp(id: "brave", displayName: "Brave", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["com.brave.Browser"]),
        MeetingApp(id: "arc", displayName: "Arc", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["company.thebrowser."]),
        MeetingApp(id: "firefox", displayName: "Firefox", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer"]),
        MeetingApp(id: "vivaldi", displayName: "Vivaldi", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["com.vivaldi.Vivaldi"]),
        MeetingApp(id: "opera", displayName: "Opera", platform: nil, kind: .browser,
                   bundleIDPrefixes: ["com.operasoftware.Opera"]),
        safari,

        MeetingApp(id: "siri", displayName: "Siri & Dictation", platform: nil, kind: .ignored,
                   bundleIDPrefixes: [
                       "com.apple.corespeechd", "com.apple.assistantd", "com.apple.Siri",
                       "com.apple.SpeechRecognitionCore", "com.apple.speech.",
                       "com.apple.dictation", "com.apple.DictationIM",
                       "com.apple.accessibility.heard",
                   ],
                   processNames: ["corespeechd", "assistantd", "Siri", "DictationIM", "heard"]),
    ]

    /// Classifies a process by bundle ID (preferred) or process name.
    ///
    /// Returns `nil` for apps we don't know. Unknown `com.apple.*` processes
    /// are classified as ignored — system services shouldn't trigger call
    /// reminders unless they're explicitly listed above (FaceTime, WebKit).
    public static func classify(bundleID: String?, processName: String? = nil) -> MeetingApp? {
        if let bid = bundleID?.lowercased(), !bid.isEmpty {
            for app in all where app.bundleIDPrefixes.contains(where: { bid.hasPrefix($0.lowercased()) }) {
                return app
            }
            if bid.hasPrefix("com.apple.") { return unknownSystemService }
        }
        if let name = processName, !name.isEmpty {
            for app in all where app.processNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return app
            }
        }
        return nil
    }

    /// The first dedicated call app (not a browser) among the given running
    /// apps, if any.
    public static func runningCallApp(
        in running: some Sequence<(bundleID: String?, name: String?)>
    ) -> MeetingApp? {
        for app in running {
            if let hit = classify(bundleID: app.bundleID, processName: app.name), hit.kind == .call {
                return hit
            }
        }
        return nil
    }

    static let unknownSystemService = MeetingApp(
        id: "system", displayName: "System service", platform: nil, kind: .ignored,
        bundleIDPrefixes: []
    )
}
