import Foundation
import VMCore

/// Single-selection identifier for the sidebar's `List`. We need both
/// folders and meetings selectable so the toolbar's "New folder" / "New
/// meeting" actions know where to act, and so context menus on rows can
/// drive folder edits.
///
/// Folders are keyed by URL (not UUID) because non-meeting folders don't
/// have one; meetings are keyed by their stable UUID.
enum SidebarSelection: Hashable {
    case folder(URL)
    case meeting(UUID)

    var meetingID: UUID? {
        if case .meeting(let id) = self { return id }
        return nil
    }

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }
}
