import Foundation

/// Tree queries shared by the sidebar, dashboard, chat and filing sheets.
/// (These were previously copy-pasted, with small differences, into five views.)
public extension FolderNode {

    /// Every meeting at or below this node, in tree order.
    var allMeetings: [Meeting] {
        var out: [Meeting] = []
        collectMeetings(into: &out)
        return out
    }

    /// Every meeting *node* (folder that holds a meeting) at or below this node,
    /// in tree order — for callers that need the folder URL as well.
    var allMeetingNodes: [FolderNode] {
        var out: [FolderNode] = []
        collectMeetingNodes(into: &out)
        return out
    }

    /// Every non-meeting folder at or below this node (including this node if it
    /// is a folder), in tree order. Meeting folders are leaves and are skipped.
    var allFolders: [FolderNode] {
        var out: [FolderNode] = []
        collectFolders(into: &out)
        return out
    }

    /// The node (folder or meeting) located at `url`, if any.
    func node(at url: URL) -> FolderNode? {
        let target = url.standardizedFileURL
        if self.url.standardizedFileURL == target { return self }
        for child in children {
            if let hit = child.node(at: url) { return hit }
        }
        return nil
    }

    /// The node for the meeting with this id, if any.
    func meetingNode(id: UUID) -> FolderNode? {
        if isMeeting, meeting?.id == id { return self }
        for child in children {
            if let hit = child.meetingNode(id: id) { return hit }
        }
        return nil
    }

    /// The direct parent of `target` within this subtree, if any.
    func parent(of target: FolderNode) -> FolderNode? {
        if children.contains(where: { $0.id == target.id }) { return self }
        for child in children {
            if let hit = child.parent(of: target) { return hit }
        }
        return nil
    }

    /// Path of this node relative to `root` ("Clients/Acme"), or "/" for the root itself.
    func displayPath(relativeTo root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let nodePath = url.standardizedFileURL.path
        guard nodePath.hasPrefix(rootPath) else { return name }
        let relative = String(nodePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/" : relative
    }

    private func collectMeetings(into out: inout [Meeting]) {
        if isMeeting, let m = meeting { out.append(m) }
        for child in children { child.collectMeetings(into: &out) }
    }

    private func collectMeetingNodes(into out: inout [FolderNode]) {
        if isMeeting, meeting != nil { out.append(self) }
        for child in children { child.collectMeetingNodes(into: &out) }
    }

    private func collectFolders(into out: inout [FolderNode]) {
        guard !isMeeting else { return }
        out.append(self)
        for child in children { child.collectFolders(into: &out) }
    }
}
