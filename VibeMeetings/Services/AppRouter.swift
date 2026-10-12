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

    /// Show the "New folder" sheet (set by the File menu; consumed by the sidebar).
    var pendingNewFolder = false

    /// Open this meeting in the main pane.
    var selectMeetingID: UUID?

    /// Open the Templates page (from a meeting's "+ Template" picker).
    var showTemplatesPage = false

    /// Focus the meeting list's search field (⌥⌘F); consumed by the list once it's on screen.
    var pendingSearchFocus = false

    func requestNewFolder() {
        pendingNewFolder = true
    }

    func requestNewMeeting(preselectEventID: String? = nil) {
        pendingNewMeeting = NewMeetingRequest(preselectEventID: preselectEventID)
    }
}
