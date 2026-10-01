import AppKit
import Foundation
import UserNotifications

/// Something the user asked for from outside the main window — a
/// notification button, the menu bar, or the floating overlay.
enum AppCommand: Sendable, Equatable {
    case recordDetectedCall(sessionID: UUID?)
    case recordEvent(eventID: String)
    case joinAndRecord(url: URL?, eventID: String?)
    case openStartSheet(preselectEventID: String?)
    case snoozeCall(sessionID: UUID?)
    case notAMeeting(sessionID: UUID?)
    case stopRecording
    case keepRecording
    case openMeeting(UUID)
    case openMainWindow
}

/// Turns notification responses into `AppCommand`s and runs them.
///
/// The notification delegate is installed in `applicationWillFinishLaunching`
/// so a click that *launches* the app isn't lost; commands that arrive before
/// the environment is ready are queued and run once `attach` is called.
@MainActor
final class NotificationActionRouter {
    static let shared = NotificationActionRouter()

    private weak var env: AppEnvironment?
    private var pending: [AppCommand] = []

    func attach(_ env: AppEnvironment) {
        self.env = env
        let queued = pending
        pending.removeAll()
        for command in queued { perform(command) }
    }

    /// Maps a notification response to a command.
    static func command(
        action: String,
        category: String,
        userInfo: [String: String]
    ) -> AppCommand? {
        typealias A = NotificationManager.Action
        typealias C = NotificationManager.Category
        typealias K = NotificationManager.Key

        let sessionID = userInfo[K.sessionID].flatMap(UUID.init(uuidString:))
        let eventID = userInfo[K.eventID]
        let joinURL = (userInfo[K.joinURL] ?? userInfo[K.legacyTeamsURL]).flatMap(URL.init(string:))
        let meetingID = userInfo[K.meetingID].flatMap(UUID.init(uuidString:))

        switch action {
        case A.record:
            return .recordDetectedCall(sessionID: sessionID)
        case A.snooze:
            return .snoozeCall(sessionID: sessionID)
        case A.notAMeeting:
            return .notAMeeting(sessionID: sessionID)
        case A.recordEvent, A.legacyStartListening:
            return eventID.map { .recordEvent(eventID: $0) } ?? .recordDetectedCall(sessionID: nil)
        case A.joinAndRecord:
            return .joinAndRecord(url: joinURL, eventID: eventID)
        case A.legacyStartRecording:
            return .recordDetectedCall(sessionID: nil)
        case A.stopRecording:
            return .stopRecording
        case A.keepRecording:
            return .keepRecording
        case UNNotificationDismissActionIdentifier:
            return nil
        case UNNotificationDefaultActionIdentifier:
            // Clicking the notification body.
            switch category {
            case C.callDetected, C.eventReminder, C.eventReminderWithLink, C.eventStarting,
                 C.legacyDetected, C.legacyReminder, C.legacyReminderTeams:
                return .openStartSheet(preselectEventID: eventID)
            default:
                return meetingID.map { .openMeeting($0) } ?? .openMainWindow
            }
        default:
            return .openMainWindow
        }
    }

    func handle(action: String, category: String, userInfo: [String: String]) {
        guard let command = Self.command(action: action, category: category, userInfo: userInfo) else { return }
        perform(command)
    }

    func perform(_ command: AppCommand) {
        guard let env else {
            pending.append(command)
            return
        }
        switch command {
        case .recordDetectedCall:
            Task { await env.recordingService.startDetectedCall() }
        case .recordEvent(let eventID):
            Task { await env.recordingService.startEvent(id: eventID) }
        case .joinAndRecord(let url, let eventID):
            Task { await env.recordingService.joinAndRecord(url: url, eventID: eventID) }
        case .openStartSheet(let eventID):
            env.appRouter.requestNewMeeting(preselectEventID: eventID)
            env.presenter.show()
        case .snoozeCall(let id):
            env.bannerCoordinator.snooze(sessionID: id)
        case .notAMeeting(let id):
            env.bannerCoordinator.notAMeeting(sessionID: id)
        case .stopRecording:
            Task { await env.recordingService.stop() }
        case .keepRecording:
            env.bannerCoordinator.dismissMeetingEnd()
        case .openMeeting(let id):
            env.appRouter.selectMeetingID = id
            env.presenter.show()
        case .openMainWindow:
            env.presenter.show()
        }
    }
}
