import SwiftUI
import VMCore
import VMStorage

/// Shown after a recording stops. Presents only metadata fields that couldn't
/// be auto-detected from the calendar event. Always shows the folder destination
/// with an auto-suggestion. The user can confirm quickly or adjust.
struct PostRecordingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let meetingID: UUID
    let meetingFolderURL: URL

    @State private var meeting: Meeting?
    @State private var isLoading = true
    @State private var isSaving = false

    // Editable fields
    @State private var titleText = ""
    @State private var selectedType: MeetingType = .group
    @State private var orgText = ""
    @State private var attendeesText = ""
    @State private var labelsText = ""

    // Folder routing
    @State private var selectedFolderURL: URL?
    @State private var availableFolders: [FolderNode] = []
    @State private var autoSuggested = false

    // Track which fields were pre-filled (to hide them in smart minimal mode)
    @State private var hasCalendarTitle = false
    @State private var hasCalendarAttendees = false
    @State private var hasCalendarOrg = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("Recording Complete")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let meeting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Duration summary
                        if let dur = meeting.duration {
                            Text("Duration: \(dur.formattedDuration)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Title — show only if not pre-filled by calendar
                        if !hasCalendarTitle {
                            LabeledContent("Title") {
                                TextField("Meeting title", text: $titleText)
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            LabeledContent("Title") {
                                Text(titleText)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Type picker — always show, it's quick
                        LabeledContent("Type") {
                            Picker("", selection: $selectedType) {
                                Text("1:1").tag(MeetingType.oneOnOne)
                                Text("Group").tag(MeetingType.group)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }

                        // Org — show only if not pre-filled
                        if !hasCalendarOrg {
                            LabeledContent("Org") {
                                TextField("e.g. EA, Marketing", text: $orgText)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        // Attendees — show only if not pre-filled
                        if !hasCalendarAttendees {
                            LabeledContent("Attendees") {
                                TextField("Comma-separated names", text: $attendeesText)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        // Labels — always show (never auto-detected)
                        LabeledContent("Labels") {
                            TextField("Comma-separated labels", text: $labelsText)
                                .textFieldStyle(.roundedBorder)
                        }

                        Divider()

                        // Folder destination
                        VStack(alignment: .leading, spacing: 6) {
                            Text("File to folder").font(.subheadline.bold())
                            Picker("Folder", selection: $selectedFolderURL) {
                                Text("(keep in current location)").tag(nil as URL?)
                                ForEach(availableFolders, id: \.url) { folder in
                                    Text(folderDisplayPath(folder))
                                        .tag(folder.url as URL?)
                                }
                            }
                            .labelsHidden()

                            if autoSuggested && selectedFolderURL != nil {
                                Label("Auto-suggested based on meeting metadata", systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .padding()
                }

                Divider()

                // Actions
                HStack {
                    Button("Skip") { dismiss() }
                        .keyboardShortcut(.escape)
                    Spacer()
                    Button("Save & File") {
                        Task { await saveAndFile() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
                .padding()
            }
        }
        .frame(width: 520, height: 480)
        .task { await loadMeeting() }
    }

    // MARK: - Load

    private func loadMeeting() async {
        isLoading = true
        defer { isLoading = false }

        // Load the meeting and populate form.
        guard let handle = try? await env.meetingStore.openMeeting(id: meetingID) else { return }
        let m = handle.meeting
        self.meeting = m

        titleText = m.title
        selectedType = m.resolvedType
        orgText = m.org ?? ""
        labelsText = (m.labels ?? []).joined(separator: ", ")

        let attendeeList = m.attendees ?? []
        attendeesText = attendeeList.joined(separator: ", ")

        // Determine which fields were pre-filled from the calendar event.
        hasCalendarTitle = m.calendarEventID != nil
        hasCalendarAttendees = !attendeeList.isEmpty
        hasCalendarOrg = m.org != nil && !m.org!.isEmpty

        // Load folder tree for picker.
        let tree = await env.meetingStore.currentTree()
        availableFolders = collectAllFolders(in: tree)

        // Auto-suggest folder.
        selectedFolderURL = await suggestFolder(for: m)
        autoSuggested = selectedFolderURL != nil
    }

    // MARK: - Save

    private func saveAndFile() async {
        guard var m = meeting else { return }
        isSaving = true
        defer { isSaving = false }

        // Apply edits.
        m.title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        m.meetingType = selectedType

        let org = orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        m.org = org.isEmpty ? nil : org

        let attendees = attendeesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        m.attendees = attendees.isEmpty ? nil : attendees

        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        m.labels = labels.isEmpty ? nil : labels

        // Persist metadata.
        try? await env.meetingStore.updateMeeting(m)

        // Move to selected folder if different from current.
        if let targetURL = selectedFolderURL {
            let currentParent = meetingFolderURL.deletingLastPathComponent()
            if targetURL.standardizedFileURL != currentParent.standardizedFileURL {
                let tree = await env.meetingStore.currentTree()
                if let targetNode = findFolderNode(at: targetURL, in: tree) {
                    try? await env.meetingStore.moveMeeting(id: m.id, to: targetNode)
                }
            }
        } else {
            // No folder selected — try auto-creating one.
            if let autoURL = await autoCreateFolder(for: m) {
                let currentParent = meetingFolderURL.deletingLastPathComponent()
                if autoURL.standardizedFileURL != currentParent.standardizedFileURL {
                    let tree = await env.meetingStore.currentTree()
                    if let targetNode = findFolderNode(at: autoURL, in: tree) {
                        try? await env.meetingStore.moveMeeting(id: m.id, to: targetNode)
                    }
                }
            }
        }

        // Rename folder on disk to use new naming format.
        await renameMeetingFolder(m)

        await env.refreshFolderTree()
        dismiss()
    }

    // MARK: - Folder suggestion

    private func suggestFolder(for meeting: Meeting) async -> URL? {
        // First try series-based routing.
        if let sid = meeting.calendarSeriesID,
           let seriesFolder = await env.meetingStore.folderForSeries(sid) {
            return seriesFolder.url
        }

        // For 1:1 meetings, look for the person's name in existing folders.
        if meeting.resolvedType == .oneOnOne {
            if let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" }) {
                // Try person index first.
                if let personFolder = await env.meetingStore.folderForPerson(person) {
                    return personFolder.url
                }
                // Fallback: scan folder names.
                if let match = findFolderByName(person) {
                    return match.url
                }
            }
        }

        // Try matching org name.
        if let org = meeting.org, !org.isEmpty {
            if let match = findFolderByName(org) {
                return match.url
            }
        }

        // Try matching title keywords.
        let titleWords = meeting.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        for folder in availableFolders {
            let folderLower = folder.name.lowercased()
            for word in titleWords where folderLower.contains(word.lowercased()) {
                return folder.url
            }
        }

        return nil
    }

    private func findFolderByName(_ name: String) -> FolderNode? {
        let lower = name.lowercased()
        if let exact = availableFolders.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        return availableFolders.first(where: {
            $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased())
        })
    }

    /// Auto-creates a folder based on meeting metadata when no folder was selected.
    /// For 1:1s: routes to {OneToOneCategory}/{PersonName}/
    /// For groups: routes to {OrgCategory}/ (matched or created at root)
    private func autoCreateFolder(for meeting: Meeting) async -> URL? {
        guard let root = env.folderTree else { return nil }

        if meeting.resolvedType == .oneOnOne {
            let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" })
            if let person, !person.isEmpty {
                // Find or create a parent category that contains 1:1-style meetings.
                let oneOnOneParent = findOneOnOneCategory() ?? root
                // Find existing person subfolder within the 1:1 parent.
                let personLower = person.lowercased()
                if let existing = availableFolders.first(where: {
                    $0.name.lowercased() == personLower &&
                    $0.url.deletingLastPathComponent().standardizedFileURL == oneOnOneParent.url.standardizedFileURL
                }) {
                    return existing.url
                }
                // Also check anywhere in the tree as fallback.
                if let existing = availableFolders.first(where: { $0.name.lowercased() == personLower }) {
                    return existing.url
                }
                let personFolder = try? await env.meetingStore.createFolder(at: oneOnOneParent, name: person)
                return personFolder?.url
            }
        }

        // For group meetings, look for an org-category folder to file into.
        let org = meeting.org ?? orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty {
            // Find a folder whose name contains the org (e.g., "20-EA-Meetings" for org "EA").
            if let orgCategory = findOrgCategory(org) {
                return orgCategory.url
            }
            // No matching category folder — create one at root.
            if let existing = availableFolders.first(where: { $0.name.lowercased() == org.lowercased() }) {
                return existing.url
            }
            let orgFolder = try? await env.meetingStore.createFolder(at: root, name: org)
            return orgFolder?.url
        }

        return nil
    }

    /// Finds a top-level folder that looks like it's for 1:1 meetings
    /// (e.g., "10-One-to-Ones", "People", "1-1s").
    private func findOneOnOneCategory() -> FolderNode? {
        let patterns = ["one-to-one", "1-1", "1:1", "people", "one to one"]
        return availableFolders.first { folder in
            let lower = folder.name.lowercased()
            return patterns.contains(where: { lower.contains($0) })
        }
    }

    /// Finds a folder whose name contains the org name, typically a top-level
    /// category like "20-EA-Meetings" for org "EA".
    private func findOrgCategory(_ org: String) -> FolderNode? {
        let orgLower = org.lowercased()
        // Prefer a folder that contains the org in its name (e.g., "20-EA-Meetings").
        return availableFolders.first { folder in
            let folderLower = folder.name.lowercased()
            return folderLower.contains(orgLower) && !folder.isMeeting
        }
    }

    /// Renames the meeting folder on disk to match the YYYY-MM-DD-name-title format.
    /// The store's `renameMeeting` method handles the naming convention.
    private func renameMeetingFolder(_ meeting: Meeting) async {
        try? await env.meetingStore.renameMeeting(id: meeting.id, to: meeting.title)
    }

    // MARK: - Helpers

    private func collectAllFolders(in node: FolderNode) -> [FolderNode] {
        var result: [FolderNode] = []
        if !node.isMeeting {
            result.append(node)
            for child in node.children {
                result.append(contentsOf: collectAllFolders(in: child))
            }
        }
        return result
    }

    private func folderDisplayPath(_ node: FolderNode) -> String {
        let rootPath = env.rootURL.path
        let nodePath = node.url.path
        if nodePath.hasPrefix(rootPath) {
            let relative = String(nodePath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "/" : relative
        }
        return node.name
    }

    private func findFolderNode(at url: URL, in node: FolderNode) -> FolderNode? {
        if node.url.standardizedFileURL == url.standardizedFileURL { return node }
        for child in node.children {
            if let hit = findFolderNode(at: url, in: child) { return hit }
        }
        return nil
    }
}
