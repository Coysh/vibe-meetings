import SwiftUI
import VMCore
import VMStorage

/// Shown after a recording stops. The user confirms or adjusts the title, type,
/// people and destination folder; everything is pre-filled from the calendar
/// event and the meeting's details where possible.
struct PostRecordingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let meetingID: UUID
    let meetingFolderURL: URL

    @State private var meeting: Meeting?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isSaving = false

    // Editable fields
    @State private var titleText = ""
    @State private var selectedType: MeetingType = .group
    @State private var orgText = ""
    @State private var attendeesText = ""
    @State private var labelsText = ""

    // Folder routing
    @State private var folderChoice: FolderChoice = .automatic
    @State private var newFolderPath = ""
    @State private var availableFolders: [FolderNode] = []
    @State private var suggestedFolderURL: URL?

    private var filer: MeetingFiler { MeetingFiler(env: env) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text("Recording complete")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            content

            Divider()

            // The way out is always available — even if the meeting failed to
            // load, so the sheet can never trap the user.
            HStack {
                Button("Skip") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Leave it unfiled — you can organise it later from Organise")
                Spacer()
                Button("Save & file") {
                    Task { await saveAndFile() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || meeting == nil)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 460, idealHeight: 520)
        .task { await loadMeeting() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            ContentUnavailableView(
                "Couldn't open this recording",
                systemImage: "exclamationmark.triangle",
                description: Text("The recording is saved. You can find it in the sidebar and organise it from there.")
            )
        } else if let meeting {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let dur = meeting.duration {
                        Text("Duration: \(dur.formattedDuration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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

                    LabeledContent("Attendees") {
                        TextField("Comma-separated names", text: $attendeesText)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Labels") {
                        TextField("Comma-separated labels", text: $labelsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("File to folder").font(.subheadline.bold())
                        FolderChoicePicker(
                            choice: $folderChoice,
                            newFolderPath: $newFolderPath,
                            folders: availableFolders,
                            rootURL: env.rootURL,
                            suggestedURL: suggestedFolderURL
                        )
                        Text("The meeting's folder is also renamed to match its title.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Load

    private func loadMeeting() async {
        isLoading = true
        defer { isLoading = false }

        guard let handle = try? await env.meetingStore.openMeeting(id: meetingID) else {
            loadFailed = true
            return
        }
        let m = handle.meeting
        meeting = m

        titleText = m.title
        selectedType = m.resolvedType
        orgText = m.org ?? ""
        attendeesText = (m.attendees ?? []).joined(separator: ", ")
        labelsText = (m.labels ?? []).joined(separator: ", ")

        let tree = await env.meetingStore.currentTree()
        availableFolders = tree.allFolders

        // Pre-select the suggestion; with none, default to automatic filing.
        suggestedFolderURL = await filer.suggestFolder(for: m, in: availableFolders)
        folderChoice = suggestedFolderURL.map { .folder($0) } ?? .automatic
    }

    // MARK: - Save

    private func saveAndFile() async {
        guard var m = meeting else { return }
        isSaving = true
        defer { isSaving = false }

        m.title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        m.meetingType = selectedType
        let org = orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        m.org = org.isEmpty ? nil : org
        let attendees = attendeesText.commaSeparatedItems
        m.attendees = attendees.isEmpty ? nil : attendees
        let labels = labelsText.commaSeparatedItems
        m.labels = labels.isEmpty ? nil : labels

        // If the details can't be saved, stay open so nothing is lost.
        guard await env.attempt("save the meeting details", { try await env.meetingStore.updateMeeting(m) }) != nil else { return }

        // Filing problems shouldn't discard the details we just saved: report them and close.
        await env.attempt("file the meeting") {
            if let target = try await filer.destination(
                for: folderChoice, newFolderPath: newFolderPath, meeting: m, folders: availableFolders
            ) {
                try await filer.move(meetingID: m.id, currentFolder: meetingFolderURL, to: target)
            }
        }

        // The folder on disk follows the (possibly edited) title.
        await env.attempt("rename the meeting folder") {
            try await env.meetingStore.renameMeeting(id: m.id, to: m.title)
        }

        await env.refreshFolderTree()
        dismiss()
    }
}

extension String {
    /// "a, b ,, c" → ["a", "b", "c"].
    var commaSeparatedItems: [String] {
        split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
