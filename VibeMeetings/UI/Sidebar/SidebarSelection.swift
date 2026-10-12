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
}
