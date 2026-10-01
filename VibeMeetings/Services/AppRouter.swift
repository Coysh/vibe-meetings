import Foundation
import Observation

/// App-level navigation requests that must survive the main window being
/// closed. Notification actions, the menu bar and the overlay write here;
/// `RootView` consumes the requests whenever a window exists.
@Observable
@MainActor
final class AppRouter {
    struct NewMeetingRequest: Equatable, Identifiable {
        let id = UUID()
        var preselectEventID: String?
    }

    struct PostRecordingItem: Equatable, Identifiable {
        let meetingID: UUID
        let folderURL: URL
        var id: UUID { meetingID }
    }

    /// Show the "Start a new meeting" sheet.
    var pendingNewMeeting: NewMeetingRequest?

    /// Show the post-recording metadata sheet for a just-finished recording.
    var pendingPostRecording: PostRecordingItem?

    /// Select this meeting in the sidebar.
    var selectMeetingID: UUID?

    func requestNewMeeting(preselectEventID: String? = nil) {
        pendingNewMeeting = NewMeetingRequest(preselectEventID: preselectEventID)
    }
}
