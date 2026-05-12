import Foundation
import VMCore

/// Selection identifier for the sidebar's `List`. We need both
/// folders and meetings selectable so the toolbar's "New folder" / "New
/// meeting" actions know where to act, and so context menus on rows can
/// drive folder edits.
///
/// Folders are keyed by URL (not UUID) because non-meeting folders don't
/// have one; meetings are keyed by their stable UUID.
///
/// The sidebar uses `Set<SidebarSelection>` for multi-select support
/// (CMD-click / SHIFT-click), enabling bulk delete via the DELETE key.
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

extension Set where Element == SidebarSelection {
    /// The first meeting ID in the selection, for driving the detail pane.
    var firstMeetingID: UUID? {
        for item in self {
            if case .meeting(let id) = item { return id }
        }
        return nil
    }

    /// The single selection if exactly one item is selected.
    var single: SidebarSelection? {
        count == 1 ? first : nil
    }
}
