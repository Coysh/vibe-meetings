import Foundation

/// What the sidebar has selected. It decides the root page of the main pane:
/// the home screen, every meeting, or the meetings inside one folder (a
/// "project").
///
/// Folders are keyed by URL (not UUID) because non-meeting folders don't have one.
enum SidebarItem: Hashable {
    case home
    /// Meetings not filed in any folder.
    case inbox
    case allMeetings
    /// Full-text search across every meeting, with filters.
    case search
    case folder(URL)
    /// Summary templates.
    case templates

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }
}

/// A meeting pushed onto the main pane's navigation stack. Its own type, so no
/// other `UUID` destination can collide with it.
struct MeetingRoute: Hashable {
    let id: UUID
    /// Where to open it (a search hit); nil opens it as usual.
    var focus: MeetingFocus? = nil
}

/// A place inside a meeting to open it at.
enum MeetingFocus: Hashable {
    case summary
    case notes
    case template(String)
    /// A transcript line, with the words to find there.
    case transcript(TranscriptJump)
}

/// A transcript line to scroll to, with the matched words to put in the transcript's find bar.
struct TranscriptJump: Hashable {
    var segmentID: UUID?
    var start: TimeInterval?
    var find: String
}
