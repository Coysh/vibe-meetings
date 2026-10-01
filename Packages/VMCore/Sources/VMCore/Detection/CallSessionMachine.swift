import Foundation

/// A process currently holding the microphone that call detection considers
/// relevant (already filtered + classified by the caller).
public struct CallClient: Sendable, Hashable {
    /// Stable identity used to decide whether a returning call is "the same"
    /// call — a catalog id (`"zoom"`) or a raw bundle ID for unknown apps.
    public var appID: String
    public var appName: String?
    public var kind: MeetingAppKind

    public init(appID: String, appName: String?, kind: MeetingAppKind) {
        self.appID = appID
        self.appName = appName
        self.kind = kind
    }
}

/// Reminder status for one detected call.
public enum CallReminderState: Sendable, Equatable {
    /// Not recording; reminder `attempt` (0-based) is due at `nextAt`.
    case pending(attempt: Int, nextAt: Date)
    /// User snoozed; reminder `attempt` resumes at `until`.
    case snoozed(until: Date, attempt: Int)
    /// Not recording, but the schedule has no more reminders to send.
    case quiet
    /// User said "Not a meeting" — silent for the rest of this call.
    case dismissed
    /// Recording is running.
    case recording
    /// User deliberately stopped a recording during this call — silent.
    case handled

    /// True while the call is unrecorded and the user hasn't opted out.
    public var isUnrecorded: Bool {
        switch self {
        case .pending, .snoozed, .quiet: true
        case .dismissed, .recording, .handled: false
        }
    }
}

public struct CallSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var client: CallClient
    public let startedAt: Date
    public var reminder: CallReminderState

    public init(id: UUID = UUID(), client: CallClient, startedAt: Date, reminder: CallReminderState) {
        self.id = id
        self.client = client
        self.startedAt = startedAt
        self.reminder = reminder
    }
}

public enum CallInput: Sendable, Equatable {
    /// The full set of relevant mic clients right now (empty = mic released).
    case mic([CallClient])
    /// Time passed; process due deadlines.
    case tick
    case recordingStarted
    case recordingStopped
    /// A recording attempt failed to start — resume reminding.
    case recordingFailed
    /// Snooze the current call's reminders. `sessionID` guards against a stale
    /// notification from an earlier call; `nil` means "whatever is current".
    case snooze(sessionID: UUID?)
    /// "Not a meeting" — stop reminding for the current call.
    case notAMeeting(sessionID: UUID?)
}

public enum CallEffect: Sendable, Equatable {
    case sessionStarted(CallSession)
    /// Send (or re-send) the reminder. `attempt` is 0 for the first one.
    case postReminder(CallSession, attempt: Int)
    /// Withdraw any delivered reminder for the current call.
    case removeReminder
    /// Mic released for longer than the grace period — the call is over.
    case sessionEnded(CallSession, wasRecording: Bool)
}

/// Pure state machine that turns microphone activity into call sessions and
/// decides when to remind the user that they're not recording.
///
/// ```
/// idle ─mic─▶ confirming ─debounce─▶ active ⇄ ending ─grace─▶ idle
/// ```
/// - *Debounce* ignores brief mic blips (a voice memo, a dictation burst).
/// - *Grace* keeps a call alive across mute/unmute and device switches, where
///   some apps briefly release the mic.
/// - A call resuming shortly after it ended (same app) continues the previous
///   session, so "Not a meeting" or a deliberate stop isn't forgotten.
public struct CallSessionMachine: Sendable {
    public struct Config: Sendable, Equatable {
        public var callDebounce: TimeInterval = 3
        public var browserDebounce: TimeInterval = 10
        public var endGrace: TimeInterval = 60
        public var snoozeDuration: TimeInterval = 600
        public var resumeWindow: TimeInterval = 600
        public var schedule: ReminderSchedule = .escalating

        public init() {}
    }

    enum Phase: Sendable, Equatable {
        case idle
        case confirming(since: Date, client: CallClient)
        case active(CallSession)
        case ending(CallSession, releasedAt: Date)
    }

    public var config: Config
    private(set) var phase: Phase = .idle
    public private(set) var isRecording: Bool
    private var recentlyEnded: (session: CallSession, endedAt: Date)?

    public init(config: Config = Config(), isRecording: Bool = false) {
        self.config = config
        self.isRecording = isRecording
    }

    // MARK: - Queries

    /// The call in progress (including one in its end-grace period).
    public var currentSession: CallSession? {
        switch phase {
        case .active(let s), .ending(let s, _): s
        case .idle, .confirming: nil
        }
    }

    /// The current call if it's unrecorded and the user hasn't opted out.
    public var unrecordedSession: CallSession? {
        guard let s = currentSession, s.reminder.isUnrecorded else { return nil }
        return s
    }

    /// When the machine next needs a `.tick`, if ever.
    public var nextDeadline: Date? {
        switch phase {
        case .idle:
            return nil
        case .confirming(let since, let client):
            return since.addingTimeInterval(debounce(for: client))
        case .ending(_, let releasedAt):
            return releasedAt.addingTimeInterval(config.endGrace)
        case .active(let s):
            switch s.reminder {
            case .pending(_, let nextAt): return nextAt
            case .snoozed(let until, _): return until
            default: return nil
            }
        }
    }

    // MARK: - Transitions

    public mutating func handle(_ input: CallInput, now: Date) -> [CallEffect] {
        var effects: [CallEffect] = []
        switch input {
        case .mic(let clients):
            effects += handleMic(clients, now: now)
        case .tick:
            break
        case .recordingStarted:
            isRecording = true
            if var s = currentSession {
                s.reminder = .recording
                replaceSession(s)
                effects.append(.removeReminder)
            }
        case .recordingStopped:
            isRecording = false
            if var s = currentSession {
                s.reminder = .handled
                replaceSession(s)
            }
            if var ended = recentlyEnded, ended.session.reminder == .recording {
                ended.session.reminder = .handled
                recentlyEnded = ended
            }
        case .recordingFailed:
            isRecording = false
            if var s = currentSession, s.reminder == .recording {
                s.reminder = .pending(attempt: 0, nextAt: now)
                replaceSession(s)
            }
        case .snooze(let id):
            if var s = currentSession, id == nil || id == s.id, case .pending(let attempt, _) = s.reminder {
                s.reminder = .snoozed(until: now.addingTimeInterval(config.snoozeDuration), attempt: attempt)
                replaceSession(s)
                effects.append(.removeReminder)
            }
        case .notAMeeting(let id):
            if var s = currentSession, id == nil || id == s.id, s.reminder.isUnrecorded {
                s.reminder = .dismissed
                replaceSession(s)
                effects.append(.removeReminder)
            }
        }
        // Every input also advances time, so deadlines that are already due
        // (e.g. a zero debounce, or the first reminder) fire immediately.
        effects += processDeadlines(now: now)
        return effects
    }

    private mutating func handleMic(_ clients: [CallClient], now: Date) -> [CallEffect] {
        let primary = Self.primary(of: clients)
        switch phase {
        case .idle:
            if let primary { phase = .confirming(since: now, client: primary) }
        case .confirming(let since, _):
            phase = primary.map { .confirming(since: since, client: $0) } ?? .idle
        case .active(let s):
            if primary == nil { phase = .ending(s, releasedAt: now) }
        case .ending(let s, _):
            if primary != nil { phase = .active(s) }
        }
        return []
    }

    private mutating func processDeadlines(now: Date) -> [CallEffect] {
        var effects: [CallEffect] = []
        switch phase {
        case .idle:
            break

        case .confirming(let since, let client):
            guard now.timeIntervalSince(since) >= debounce(for: client) else { break }
            let session = startSession(client: client, now: now)
            phase = .active(session)
            effects.append(.sessionStarted(session))
            effects += processDeadlines(now: now) // first reminder is due now

        case .ending(let s, let releasedAt):
            guard now.timeIntervalSince(releasedAt) >= config.endGrace else { break }
            phase = .idle
            recentlyEnded = (s, now)
            if s.reminder.isUnrecorded { effects.append(.removeReminder) }
            effects.append(.sessionEnded(s, wasRecording: s.reminder == .recording))

        case .active(var s):
            switch s.reminder {
            case .snoozed(let until, let attempt) where now >= until:
                s.reminder = .pending(attempt: attempt, nextAt: now)
                phase = .active(s)
                effects += processDeadlines(now: now)
            case .pending(let attempt, let nextAt) where now >= nextAt:
                effects.append(.postReminder(s, attempt: attempt))
                if let gap = config.schedule.gap(afterAttempt: attempt) {
                    s.reminder = .pending(attempt: attempt + 1, nextAt: now.addingTimeInterval(gap))
                } else {
                    s.reminder = .quiet
                }
                phase = .active(s)
            default:
                break
            }
        }
        return effects
    }

    private mutating func startSession(client: CallClient, now: Date) -> CallSession {
        // Same app coming back shortly after its call "ended" (breakout
        // rooms, a long mute, a device switch) continues that session.
        if let ended = recentlyEnded,
           ended.session.client.appID == client.appID,
           now.timeIntervalSince(ended.endedAt) <= config.resumeWindow {
            recentlyEnded = nil
            var s = ended.session
            if isRecording {
                s.reminder = .recording
            } else if s.reminder == .recording {
                // Was recording when the call dropped, isn't now — the
                // recording was stopped deliberately.
                s.reminder = .handled
            }
            return s
        }
        recentlyEnded = nil
        return CallSession(
            client: client,
            startedAt: now,
            reminder: isRecording ? .recording : .pending(attempt: 0, nextAt: now)
        )
    }

    private mutating func replaceSession(_ s: CallSession) {
        switch phase {
        case .active: phase = .active(s)
        case .ending(_, let releasedAt): phase = .ending(s, releasedAt: releasedAt)
        case .idle, .confirming: break
        }
    }

    private func debounce(for client: CallClient) -> TimeInterval {
        client.kind == .call ? config.callDebounce : config.browserDebounce
    }

    /// Prefer a dedicated call app over a browser/unknown client.
    private static func primary(of clients: [CallClient]) -> CallClient? {
        clients.first(where: { $0.kind == .call }) ?? clients.first
    }
}
