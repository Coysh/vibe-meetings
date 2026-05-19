import SwiftUI
import VMCore
import VMStorage

/// Lists all meetings that lack metadata (type, labels, org) and lets the user
/// quickly assign them using a workflow similar to a CLI triage script.
/// Each meeting is presented one at a time; the user picks a type, destination
/// folder, attendees, and labels, then moves on.
struct MeetingTriageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var untaggedMeetings: [(meeting: Meeting, folderURL: URL)] = []
    @State private var currentIndex = 0
    @State private var isLoading = true

    /// Persisted set of meeting IDs that have already been triaged (via Save or Skip).
    private static let triagedKey = "VibeMeetings.TriagedMeetingIDs"
    @State private var triagedIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: triagedKey) ?? [])
    }()

    // Per-meeting editing state
    @State private var selectedType: MeetingType = .group
    @State private var orgText: String = ""
    @State private var attendeesText: String = ""
    @State private var labelsText: String = ""
    @State private var titleText: String = ""
    @State private var selectedFolderURL: URL?
    @State private var newFolderName: String = ""

    // Known values for suggestions
    @State private var knownAttendees: [String] = []
    @State private var knownLabels: [String] = []
    @State private var availableFolders: [FolderNode] = []

    private var currentMeeting: Meeting? {
        guard currentIndex < untaggedMeetings.count else { return nil }
        return untaggedMeetings[currentIndex].meeting
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                ProgressView("Scanning meetings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if untaggedMeetings.isEmpty {
                doneView
            } else if let meeting = currentMeeting {
                triageForm(meeting: meeting)
            } else {
                doneView
            }
        }
        .frame(width: 600, height: 580)
        .task { await loadData() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Organise Meetings")
                .font(.headline)
            Spacer()
            if !untaggedMeetings.isEmpty {
                Text("\(currentIndex + 1) of \(untaggedMeetings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding()
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All meetings are organised")
                .font(.title3)
            Text("Every meeting has a type and folder assigned.")
                .foregroundStyle(.secondary)
            Button("Re-check all meetings") {
                triagedIDs.removeAll()
                UserDefaults.standard.removeObject(forKey: Self.triagedKey)
                currentIndex = 0
                Task { await loadData() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Triage form

    @ViewBuilder
    private func triageForm(meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Meeting info
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.title3.bold())
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let dur = meeting.duration {
                        Text("Duration: \(dur.formattedDuration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Title (editable)
                LabeledContent("Title") {
                    TextField("Meeting title", text: $titleText)
                        .textFieldStyle(.roundedBorder)
                }

                // Type picker
                LabeledContent("Type") {
                    Picker("", selection: $selectedType) {
                        Text("1:1").tag(MeetingType.oneOnOne)
                        Text("Group Meeting").tag(MeetingType.group)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                // Org
                LabeledContent("Org") {
                    TextField("e.g. EA, Marketing", text: $orgText)
                        .textFieldStyle(.roundedBorder)
                }

                // Attendees
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Attendees") {
                        TextField("Comma-separated names", text: $attendeesText)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !knownAttendees.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(knownAttendees, id: \.self) { name in
                                    Button(name) {
                                        appendToField(&attendeesText, value: name)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // Labels
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Labels") {
                        TextField("Comma-separated labels", text: $labelsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !knownLabels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(knownLabels, id: \.self) { label in
                                    Button(label) {
                                        appendToField(&labelsText, value: label)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // Destination folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move to folder").font(.subheadline.bold())
                    Picker("Folder", selection: $selectedFolderURL) {
                        Text("(keep in current folder)").tag(nil as URL?)
                        ForEach(availableFolders, id: \.url) { folder in
                            Text(folderDisplayPath(folder))
                                .tag(folder.url as URL?)
                        }
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        TextField("Or create new folder", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        if !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Will be created in root")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if selectedFolderURL != nil {
                        Label("Auto-suggested based on meeting metadata", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding()
        }

        Divider()

        // Action buttons
        HStack {
            Button("Skip") {
                advanceToNext()
            }
            .keyboardShortcut("s", modifiers: [])

            Spacer()

            Button("Save & Next") {
                Task { await saveAndAdvance() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }

    // MARK: - Data loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let tree = await env.meetingStore.currentTree()

        // Collect all folders for the destination picker.
        availableFolders = collectAllFolders(in: tree)

        // Collect all meetings that are "untagged" — no meetingType explicitly set,
        // or no labels, or sitting in the root folder (not organized).
        var meetings: [(Meeting, URL)] = []
        collectUntaggedMeetings(in: tree, rootURL: env.rootURL, into: &meetings)

        // Sort by date (oldest first — triage in chronological order).
        meetings.sort { $0.0.startedAt < $1.0.startedAt }
        untaggedMeetings = meetings

        // Collect known attendees and labels from all meetings in the tree.
        var attendeeSet = Set<String>()
        var labelSet = Set<String>()
        collectKnownValues(in: tree, attendees: &attendeeSet, labels: &labelSet)
        knownAttendees = attendeeSet.sorted()
        knownLabels = labelSet.sorted()

        // Set up the first meeting's form state.
        if let first = untaggedMeetings.first {
            populateForm(for: first.meeting, folderURL: first.folderURL)
        }
    }

    private func collectUntaggedMeetings(
        in node: FolderNode,
        rootURL: URL,
        into result: inout [(Meeting, URL)]
    ) {
        if node.isMeeting, let m = node.meeting {
            // Skip meetings already triaged in a previous session.
            guard !triagedIDs.contains(m.id.uuidString) else { return }

            let needsTriage = m.meetingType == nil
                || (m.labels == nil || m.labels?.isEmpty == true)
                || node.url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL
            if needsTriage {
                result.append((m, node.url))
            }
        } else {
            for child in node.children {
                collectUntaggedMeetings(in: child, rootURL: rootURL, into: &result)
            }
        }
    }

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

    private func collectKnownValues(
        in node: FolderNode,
        attendees: inout Set<String>,
        labels: inout Set<String>
    ) {
        if let m = node.meeting {
            m.attendees?.forEach { attendees.insert($0) }
            m.labels?.forEach { labels.insert($0) }
        }
        for child in node.children {
            collectKnownValues(in: child, attendees: &attendees, labels: &labels)
        }
    }

    // MARK: - Form population

    private func populateForm(for meeting: Meeting, folderURL: URL) {
        titleText = meeting.title
        selectedType = meeting.resolvedType
        orgText = meeting.org ?? ""
        attendeesText = (meeting.attendees ?? []).joined(separator: ", ")
        labelsText = (meeting.labels ?? []).joined(separator: ", ")

        newFolderName = ""

        // Auto-suggest a destination folder based on type and attendees.
        selectedFolderURL = suggestFolder(for: meeting)
    }

    /// Finds the best folder for a meeting based on its type, attendees, and title.
    /// For 1:1s, looks for a "People/<person>" folder. For group meetings,
    /// looks for an org-named folder. Returns nil if no match found.
    private func suggestFolder(for meeting: Meeting) -> URL? {
        // For 1:1 meetings, look for the person's name in existing folders.
        if meeting.resolvedType == .oneOnOne {
            if let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" }) {
                if let match = findFolderByName(person) {
                    return match.url
                }
            }
        }

        // Try matching org name to an existing folder.
        if let org = meeting.org, !org.isEmpty {
            if let match = findFolderByName(org) {
                return match.url
            }
        }

        // Try matching keywords from the title to existing folder names.
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
        // Exact match first, then substring match.
        if let exact = availableFolders.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        return availableFolders.first(where: { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) })
    }

    // MARK: - Actions

    private func markTriaged(_ meetingID: UUID) {
        triagedIDs.insert(meetingID.uuidString)
        UserDefaults.standard.set(Array(triagedIDs), forKey: Self.triagedKey)
    }

    private func advanceToNext() {
        // Mark the current meeting as triaged before advancing.
        if currentIndex < untaggedMeetings.count {
            markTriaged(untaggedMeetings[currentIndex].meeting.id)
        }
        currentIndex += 1
        if currentIndex < untaggedMeetings.count {
            let next = untaggedMeetings[currentIndex]
            populateForm(for: next.meeting, folderURL: next.folderURL)
        }
    }

    private func saveAndAdvance() async {
        guard currentIndex < untaggedMeetings.count else { return }
        let entry = untaggedMeetings[currentIndex]
        var meeting = entry.meeting

        // Apply edits.
        meeting.title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.meetingType = selectedType

        let org = orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.org = org.isEmpty ? nil : org

        let attendees = attendeesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        meeting.attendees = attendees.isEmpty ? nil : attendees

        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        meeting.labels = labels.isEmpty ? nil : labels

        // Persist metadata.
        try? await env.meetingStore.updateMeeting(meeting)

        // Determine the target folder: new folder name takes priority, then picker, then auto-suggest.
        var targetURL = selectedFolderURL
        let trimmedNewFolder = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedNewFolder.isEmpty {
            // Create the new folder at root level.
            if let root = env.folderTree {
                let newFolder = try? await env.meetingStore.createFolder(at: root, name: trimmedNewFolder)
                targetURL = newFolder?.url
            }
        } else if targetURL == nil {
            // If no folder was picked or typed, auto-create based on meeting metadata.
            targetURL = await autoCreateFolder(for: meeting)
        }

        // Move to the target folder if different from current location.
        if let targetURL {
            let currentParent = entry.folderURL.deletingLastPathComponent()
            if targetURL.standardizedFileURL != currentParent.standardizedFileURL {
                let tree = await env.meetingStore.currentTree()
                if let targetNode = findFolderNode(at: targetURL, in: tree) {
                    try? await env.meetingStore.moveMeeting(id: meeting.id, to: targetNode)
                }
            }
        }

        // Update known values for the next iteration.
        attendees.forEach { knownAttendees.appendIfNew($0) }
        labels.forEach { knownLabels.appendIfNew($0) }

        await env.refreshFolderTree()

        // Refresh available folders for the next meeting (may have been created).
        if let tree = env.folderTree {
            availableFolders = collectAllFolders(in: tree)
        }

        advanceToNext()
    }

    /// Auto-creates a folder based on meeting metadata when no folder was selected.
    /// For 1:1s: creates "People/<PersonName>". For group meetings: creates "<Org>" if org is set.
    private func autoCreateFolder(for meeting: Meeting) async -> URL? {
        guard let root = env.folderTree else { return nil }

        if meeting.resolvedType == .oneOnOne {
            let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" })
            if let person, !person.isEmpty {
                // Look for or create a "People" parent folder.
                let peopleFolder: FolderNode
                if let existing = availableFolders.first(where: { $0.name.lowercased() == "people" }) {
                    peopleFolder = existing
                } else {
                    guard let created = try? await env.meetingStore.createFolder(at: root, name: "People") else { return nil }
                    peopleFolder = created
                }
                // Create the person subfolder.
                if let existing = availableFolders.first(where: { $0.name.lowercased() == person.lowercased() }) {
                    return existing.url
                }
                let personFolder = try? await env.meetingStore.createFolder(at: peopleFolder, name: person)
                return personFolder?.url
            }
        }

        // For group meetings with an org, create an org folder.
        let org = meeting.org ?? orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty {
            if let existing = availableFolders.first(where: { $0.name.lowercased() == org.lowercased() }) {
                return existing.url
            }
            let orgFolder = try? await env.meetingStore.createFolder(at: root, name: org)
            return orgFolder?.url
        }

        return nil
    }

    // MARK: - Helpers

    private func appendToField(_ field: inout String, value: String) {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            field = value
        } else {
            field = trimmed + ", " + value
        }
    }

    private func folderDisplayPath(_ node: FolderNode) -> String {
        // Show path relative to root.
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

private extension Array where Element == String {
    mutating func appendIfNew(_ value: String) {
        if !contains(value) {
            append(value)
        }
    }
}
