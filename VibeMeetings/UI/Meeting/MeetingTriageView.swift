import SwiftUI
import VMCore
import VMStorage

/// Walks through meetings that still lack metadata (type, labels, a proper
/// folder) one at a time so they can be filled in quickly.
struct MeetingTriageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var queue: [(meeting: Meeting, folderURL: URL)] = []
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var skippedCount = 0

    /// Meeting IDs the user filed or explicitly asked never to be shown again.
    /// A plain "Skip" does NOT land here — it only moves on for this session.
    private static let triagedKey = "VibeMeetings.TriagedMeetingIDs"
    @State private var triagedIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: triagedKey) ?? [])
    }()

    // Per-meeting editing state
    @State private var selectedType: MeetingType = .group
    @State private var orgText = ""
    @State private var attendeesText = ""
    @State private var labelsText = ""
    @State private var titleText = ""
    @State private var folderChoice: FolderChoice = .automatic
    @State private var newFolderPath = ""
    @State private var suggestedFolderURL: URL?

    // Known values for one-tap suggestions
    @State private var knownAttendees: [String] = []
    @State private var knownLabels: [String] = []
    @State private var availableFolders: [FolderNode] = []

    private var filer: MeetingFiler { MeetingFiler(env: env) }

    private var currentMeeting: Meeting? {
        currentIndex < queue.count ? queue[currentIndex].meeting : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                ProgressView("Scanning meetings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let meeting = currentMeeting {
                triageForm(meeting: meeting)
            } else {
                doneView
            }
        }
        .frame(minWidth: 600, idealWidth: 600, minHeight: 520, idealHeight: 600)
        .task { await loadData() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Organise meetings")
                .font(.headline)
            Spacer()
            if !queue.isEmpty && currentMeeting != nil {
                Text("\(currentIndex + 1) of \(queue.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(queue.isEmpty ? "Nothing to organise" : "That's all of them")
                .font(.title3)
            if queue.isEmpty {
                Text("Every meeting already has a type, labels and a folder.")
                    .foregroundStyle(.secondary)
            } else if skippedCount > 0 {
                Text("You skipped \(skippedCount). They'll be here again next time you open Organise.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !triagedIDs.isEmpty {
                Button("Show meetings I dismissed again") {
                    triagedIDs.removeAll()
                    UserDefaults.standard.removeObject(forKey: Self.triagedKey)
                    currentIndex = 0
                    skippedCount = 0
                    Task { await loadData() }
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Form

    @ViewBuilder
    private func triageForm(meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                LabeledContent("Title") {
                    TextField("Meeting title", text: $titleText)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Type") {
                    Picker("Type", selection: $selectedType) {
                        Text("1:1").tag(MeetingType.oneOnOne)
                        Text("Group").tag(MeetingType.group)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                LabeledContent("Org") {
                    TextField("e.g. EA, Marketing", text: $orgText)
                        .textFieldStyle(.roundedBorder)
                }

                suggestionField("Attendees", placeholder: "Comma-separated names", text: $attendeesText, known: knownAttendees)
                suggestionField("Labels", placeholder: "Comma-separated labels", text: $labelsText, known: knownLabels)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Move to folder").font(.subheadline.bold())
                    FolderChoicePicker(
                        choice: $folderChoice,
                        newFolderPath: $newFolderPath,
                        folders: availableFolders,
                        rootURL: env.rootURL,
                        suggestedURL: suggestedFolderURL
                    )
                }
            }
            .padding()
        }

        Divider()

        HStack {
            Button("Back") { goBack() }
                .disabled(currentIndex == 0)
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Button("Skip") { skip() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Come back to this meeting next time")

            Button("Don't ask again") { dismissForever() }
                .help("Stop offering this meeting in Organise")

            Spacer()

            Button("Save & next") {
                Task { await saveAndAdvance() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSaving)
        }
        .padding()
    }

    /// A comma-separated text field with one-tap chips for values already used
    /// in other meetings.
    @ViewBuilder
    private func suggestionField(_ title: String, placeholder: String, text: Binding<String>, known: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            if !known.isEmpty {
                // Wraps instead of scrolling sideways, so every option is visible.
                FlowLayout(spacing: 4) {
                    ForEach(known, id: \.self) { value in
                        Button(value) { append(value, to: text) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let tree = await env.meetingStore.currentTree()
        availableFolders = tree.allFolders

        var pending: [(Meeting, URL)] = []
        for node in tree.allMeetingNodes {
            guard let m = node.meeting, !triagedIDs.contains(m.id.uuidString) else { continue }
            let needsTriage = m.meetingType == nil
                || (m.labels?.isEmpty ?? true)
                || node.url.deletingLastPathComponent().standardizedFileURL == env.rootURL.standardizedFileURL
            if needsTriage { pending.append((m, node.url)) }
        }
        // Chronological order: oldest first.
        pending.sort { $0.0.startedAt < $1.0.startedAt }
        queue = pending.map { (meeting: $0.0, folderURL: $0.1) }

        var attendeeSet = Set<String>(), labelSet = Set<String>()
        for m in tree.allMeetings {
            m.attendees?.forEach { attendeeSet.insert($0) }
            m.labels?.forEach { labelSet.insert($0) }
        }
        knownAttendees = attendeeSet.sorted()
        knownLabels = labelSet.sorted()

        if let first = queue.first { await populateForm(for: first.meeting) }
    }

    private func populateForm(for meeting: Meeting) async {
        titleText = meeting.title
        selectedType = meeting.resolvedType
        orgText = meeting.org ?? ""
        attendeesText = (meeting.attendees ?? []).joined(separator: ", ")
        labelsText = (meeting.labels ?? []).joined(separator: ", ")
        newFolderPath = ""
        suggestedFolderURL = await filer.suggestFolder(for: meeting, in: availableFolders)
        folderChoice = suggestedFolderURL.map { .folder($0) } ?? .automatic
    }

    // MARK: - Navigation

    private func show(index: Int) {
        currentIndex = index
        if index < queue.count {
            let m = queue[index].meeting
            Task { await populateForm(for: m) }
        }
    }

    /// Move on for now; the meeting comes back next time.
    private func skip() {
        skippedCount += 1
        show(index: currentIndex + 1)
    }

    private func goBack() {
        show(index: max(0, currentIndex - 1))
    }

    /// Persistently stop offering this meeting.
    private func dismissForever() {
        if let m = currentMeeting { markTriaged(m.id) }
        show(index: currentIndex + 1)
    }

    private func markTriaged(_ id: UUID) {
        triagedIDs.insert(id.uuidString)
        UserDefaults.standard.set(Array(triagedIDs), forKey: Self.triagedKey)
    }

    // MARK: - Save

    private func saveAndAdvance() async {
        guard currentIndex < queue.count else { return }
        isSaving = true
        defer { isSaving = false }

        let entry = queue[currentIndex]
        var meeting = entry.meeting
        meeting.title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.meetingType = selectedType
        let org = orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.org = org.isEmpty ? nil : org
        let attendees = attendeesText.commaSeparatedItems
        meeting.attendees = attendees.isEmpty ? nil : attendees
        let labels = labelsText.commaSeparatedItems
        meeting.labels = labels.isEmpty ? nil : labels

        // Stay on this meeting if saving fails, so nothing typed is lost.
        guard await env.attempt("save the meeting details", { try await env.meetingStore.updateMeeting(meeting) }) != nil else { return }

        await env.attempt("move the meeting") {
            if let target = try await filer.destination(
                for: folderChoice, newFolderPath: newFolderPath, meeting: meeting, folders: availableFolders
            ) {
                try await filer.move(meetingID: meeting.id, currentFolder: entry.folderURL, to: target)
            }
        }

        attendees.forEach { if !knownAttendees.contains($0) { knownAttendees.append($0) } }
        labels.forEach { if !knownLabels.contains($0) { knownLabels.append($0) } }

        await env.refreshFolderTree()
        if let tree = env.folderTree { availableFolders = tree.allFolders }

        markTriaged(meeting.id)
        show(index: currentIndex + 1)
    }

    private func append(_ value: String, to text: Binding<String>) {
        let existing = text.wrappedValue.commaSeparatedItems
        guard !existing.contains(value) else { return }
        text.wrappedValue = (existing + [value]).joined(separator: ", ")
    }
}
