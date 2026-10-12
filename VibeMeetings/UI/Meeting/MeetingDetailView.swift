import SwiftUI
import UniformTypeIdentifiers
import VMCore
import VMStorage
import VMSummarization

struct MeetingDetailView: View {
    let meetingID: UUID
    var onOpenChat: ((UUID) -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryActions.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var handle: MeetingHandle?
    @State private var segments: [TranscriptSegment] = []
    @State private var summary: String = ""
    @State private var notes: String = ""
    @State private var selectedTab: Tab = .summary
    /// Ensures we only pick the initial tab once per opened meeting, so later
    /// reloads (e.g. when a recording stops) don't yank the user off their tab.
    @State private var didChooseInitialTab = false
    @State private var editableMeeting: Meeting?
    @State private var showImportTranscript = false
    @State private var importTranscriptText = ""
    @State private var isSearchingTranscript = false
    @State private var showInfo = false
    @State private var pendingConfirmation: Confirmation?
    @State private var audioSource: AudioSource = .full
    /// Last notes text known to be on disk, to show "Saved" and avoid redundant writes.
    @State private var savedNotes = ""
    @State private var notesSaveState: NotesSaveState = .saved
    /// Template write-ups saved in this meeting's folder: template id → Markdown.
    @State private var templateOutputs: [String: String] = [:]
    /// The template tabs open on this page, in the order they were added.
    @State private var openTemplateIDs: [String] = []
    @State private var showTemplatePicker = false
    /// Set once the transcript has been redone with the larger model.
    @State private var refinement: RefinementRecord?
    @State private var hasLiveBackup = false
    @State private var showComparison = false

    private enum Confirmation: Identifiable, Hashable {
        case regenerateSummary, resumeRecording, importOverTranscript
        case improveTranscript, restoreLiveTranscript
        case removeTemplate(String)
        var id: Self { self }
    }

    private enum AudioSource: String, CaseIterable, Identifiable {
        case full = "Full recording"
        case yourVoice = "Your voice only"
        var id: String { rawValue }
    }

    private enum NotesSaveState { case saved, saving }

    /// The four tabs every meeting has, in the order people open a finished meeting
    /// for (summary first), then one per template added with "+ Template".
    enum Tab: Hashable, Identifiable {
        case summary, transcript, notes, audio
        case template(String)

        var id: Self { self }
        static let base: [Tab] = [.summary, .transcript, .notes, .audio]
    }

    private var tabs: [Tab] {
        Tab.base + openTemplateIDs.map { Tab.template($0) }
    }

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .audio: "Audio"
        case .template(let id):
            env.summaryTemplates.template(id: id).map { "\($0.emoji) \($0.name)" } ?? "Template"
        }
    }

    /// The background summary job for this meeting, if any.
    private var summaryJob: SummaryJob? {
        env.summaryService.job(for: meetingID)
    }

    /// Whether a summary is currently being generated.
    private var isSummarizing: Bool {
        env.summaryService.isRunning(for: meetingID)
    }

    /// While a job streams, its partial text. Afterwards the saved summary — so a
    /// failed regenerate leaves the old summary visible.
    private var displaySummary: String {
        let partial = summaryJob?.partialSummary ?? ""
        return isSummarizing ? partial : (partial.isEmpty ? summary : partial)
    }

    /// Header, tabs and content share one centred column.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .readableWidth()
            .padding(.horizontal, Tokens.Space.xl)
    }

    /// Whether this meeting is currently being recorded live.
    private var isLiveRecording: Bool {
        if let controller = env.activeRecordingController,
           controller.meetingHandle?.meeting.id == meetingID {
            return true
        }
        return false
    }

    /// When the active recording targets this meeting, show live segments
    /// instead of (empty) on-disk segments.
    private var displaySegments: [TranscriptSegment] {
        if isLiveRecording,
           let controller = env.activeRecordingController,
           !controller.liveSegments.isEmpty {
            return controller.liveSegments
        }
        return segments
    }

    var body: some View {
        VStack(spacing: 0) {
            if let handle {
                column { header(meeting: handle.meeting) }
                column {
                    UnderlineTabBar(tabs: tabs, selection: $selectedTab, title: tabTitle) {
                        addTemplateButton
                    } trailing: {
                        tabAccessory(meeting: handle.meeting)
                    }
                }
                .padding(.top, Tokens.Space.l)

                refinementStrip

                Group {
                    switch selectedTab {
                    case .transcript:
                        VStack(spacing: 0) {
                            if isLiveRecording {
                                TranscriptView(
                                    segments: .constant(displaySegments),
                                    participants: handle.meeting.participants,
                                    meeting: handle.meeting,
                                    isSearching: $isSearchingTranscript
                                )
                            } else {
                                if env.diarizationService.job(for: meetingID) != nil {
                                    column {
                                        HStack {
                                            speakerDetectionStatus(meeting: handle.meeting)
                                            Spacer()
                                        }
                                        .padding(.top, Tokens.Space.s)
                                    }
                                }
                                TranscriptView(
                                    segments: $segments,
                                    participants: handle.meeting.participants,
                                    meeting: handle.meeting,
                                    isSearching: $isSearchingTranscript,
                                    isEditable: true,
                                    onSave: { updatedSegments in
                                        Task {
                                            await env.attempt("save the transcript edit") {
                                                try await env.meetingStore.replaceTranscript(updatedSegments, for: meetingID)
                                            }
                                        }
                                    },
                                    onRenameSpeaker: { speakerID, name in renameSpeaker(speakerID, to: name) }
                                )
                            }
                        }
                    case .notes:
                        notesTab(meeting: handle.meeting)
                    case .summary:
                        summaryTab(meeting: handle.meeting)
                    case .audio:
                        audioTab(handle: handle)
                    case .template(let id):
                        templateTab(id: id)
                    }
                }
                .onChange(of: env.summaryService.templateRevision) { reloadTemplateOutputs() }
                .onChange(of: env.summaryService.activeTemplateIDs(for: meetingID)) { openActiveTemplateTabs() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .floatingActionBar(showsIdle: handle?.meeting.endedAt != nil) {
            // Resume is rare and replaces the audio file, so it asks first.
            Button {
                pendingConfirmation = .resumeRecording
            } label: {
                Label("Resume Recording", systemImage: "mic.fill")
            }
            .buttonStyle(.capsule(.primary))
            .help("Continue recording into this meeting")
        }
        .task(id: meetingID) {
            await load()
        }
        .onChange(of: env.refinementService.status(for: meetingID)) { _, status in
            if status == .completed { Task { await load() } }
        }
        .onChange(of: env.refinementService.isImproved(meetingID)) { Task { await load() } }
        .onChange(of: env.diarizationService.job(for: meetingID)?.status) { _, status in
            if case .completed = status { Task { await load() } }
        }
        .onChange(of: env.activeRecordingController == nil) {
            // When recording stops the controller is nilled out; reload the
            // now-persisted transcript so it replaces the (stale) live view.
            Task { await load() }
        }
        .sheet(item: $editableMeeting) { meeting in
            MeetingMetadataEditor(
                meeting: Binding(
                    get: { editableMeeting ?? meeting },
                    set: { editableMeeting = $0 }
                ),
                knownOrgs: env.configuredOrgs,
                onSave: { edited in
                    Task {
                        var updated = edited
                        // Keep speakers found since the editor opened.
                        if let fresh = try? await env.meetingStore.openMeeting(id: meetingID).meeting {
                            updated.participants = fresh.participants
                        }
                        let titleChanged = updated.title != handle?.meeting.title
                        guard await env.attempt("save the meeting details", { try await env.meetingStore.updateMeeting(updated) }) != nil else { return }
                        if titleChanged {
                            await env.attempt("rename the meeting folder") {
                                try await env.meetingStore.renameMeeting(id: meetingID, to: updated.title)
                            }
                            await env.refreshFolderTree()
                        }
                        await load()
                    }
                }
            )
        }
        .background {
            // ⌘F finds in the transcript from any tab; ⌘1–4 switch tabs.
            Group {
                Button("Find in transcript") {
                    selectedTab = .transcript
                    isSearchingTranscript = true
                }
                .keyboardShortcut("f", modifiers: .command)
                ForEach(Array(Tab.base.enumerated()), id: \.element) { index, tab in
                    Button(tabTitle(tab)) { selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .hidden()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { item in
            switch item {
            case .regenerateSummary:
                Button("Replace summary", role: .destructive) { if let m = handle?.meeting { generateSummary(meeting: m) } }
            case .resumeRecording:
                Button("Resume recording") { Task { await resumeRecording() } }
            case .importOverTranscript:
                Button("Choose text to import…", role: .destructive) { showImportTranscript = true }
            case .improveTranscript:
                Button("Improve transcript") { startImprovingTranscript() }
            case .restoreLiveTranscript:
                Button("Restore live transcript", role: .destructive) { restoreLiveTranscript() }
            case .removeTemplate(let id):
                Button("Remove tab", role: .destructive) { removeTemplateTab(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(item))
        }
        .sheet(isPresented: $showComparison) {
            if let folder = handle?.folderURL {
                TranscriptComparisonSheet(meetingID: meetingID, folderURL: folder, record: refinement)
            }
        }
        .sheet(isPresented: $showImportTranscript) {
            ImportTranscriptSheet(text: $importTranscriptText) {
                Task {
                    await env.attempt("import the transcript") {
                        try await env.meetingStore.importRawTranscript(importTranscriptText, for: meetingID)
                    }
                    await load()
                }
            }
        }
    }

    // MARK: - Header

    private func header(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")

                Text(meeting.title)
                    .font(Tokens.detailTitle)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: Tokens.Space.m)

                let people = peopleNames(meeting)
                if !people.isEmpty { AvatarStack(names: people) }

                Button {
                    onOpenChat?(meetingID)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ask questions about this meeting")
                .accessibilityLabel("Chat about this meeting")

                shareMenu(meeting: meeting)
                moreMenu(meeting: meeting)
            }

            chips(meeting: meeting)
        }
        .padding(.top, Tokens.Space.xl)
    }

    /// Calendar attendees plus anyone who's been named in the transcript — not the stock "You" / "Others".
    private func peopleNames(_ meeting: Meeting) -> [String] {
        let stock: Set<String> = ["you", "others", "imported"]
        var seen = Set<String>()
        var names: [String] = []
        let candidates = (meeting.attendees ?? []) + meeting.participants.map(\.displayName)
        for name in candidates {
            let key = name.lowercased()
            guard !name.isEmpty, !stock.contains(key), !key.hasPrefix("others"), !key.hasPrefix("speaker"),
                  seen.insert(key).inserted else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: - Share

    /// Everything stays on this Mac, so "Share" is copy and export rather than a link.
    private func shareMenu(meeting: Meeting) -> some View {
        Menu {
            Button("Copy Summary", systemImage: "doc.on.doc") { copy(displaySummary) }
                .disabled(displaySummary.isEmpty)
            Button("Copy Transcript", systemImage: "text.alignleft") { copy(plainTranscript(meeting)) }
                .disabled(displaySegments.isEmpty)
            Button("Copy Everything as Markdown", systemImage: "doc.richtext") { copy(markdown(meeting)) }
            Divider()
            Button("Export as Markdown…", systemImage: "square.and.arrow.up") { exportMarkdown(meeting) }
            if let folder = handle?.folderURL {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.capsule(.secondary))
        .fixedSize()
        .help("Copy or export this meeting")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func plainTranscript(_ meeting: Meeting) -> String {
        let names = Dictionary(meeting.participants.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return displaySegments
            .map { "[\($0.start.formattedTimestamp)] \(names[$0.speakerId] ?? $0.speakerId.capitalized): \($0.text)" }
            .joined(separator: "\n")
    }

    private func markdown(_ meeting: Meeting) -> String {
        MarkdownTranscriptWriter.render(
            meeting: meeting,
            segments: displaySegments,
            summary: displaySummary.isEmpty ? nil : displaySummary,
            notes: notes.isEmpty ? nil : notes
        )
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = markdown(meeting)
        Task {
            await env.attempt("export the meeting") {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func moreMenu(meeting: Meeting) -> some View {
        Menu {
            Button("Edit details…", systemImage: "pencil") { editableMeeting = meeting }
            Button("Chat about this meeting", systemImage: "bubble.left.and.text.bubble.right") { onOpenChat?(meetingID) }
            // Resume is rare and replaces the audio file, so it is a confirmed action.
            if meeting.endedAt != nil && env.activeRecordingController == nil {
                Button("Resume recording…", systemImage: "record.circle") { pendingConfirmation = .resumeRecording }
            }
            if let folder = handle?.folderURL {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            if meeting.endedAt != nil, meeting.hasAudio {
                Divider()
                Button("Improve transcript…", systemImage: "sparkles") { pendingConfirmation = .improveTranscript }
                    .disabled(env.refinementService.isActive(meetingID) || cannotImproveReason != nil)
                    .help(cannotImproveReason ?? "Transcribe the recording again with a larger model")
                if refinement != nil, hasLiveBackup {
                    Button("Compare with live transcript…", systemImage: "rectangle.split.2x1") { showComparison = true }
                    Button("Restore live transcript…", systemImage: "arrow.uturn.backward") { pendingConfirmation = .restoreLiveTranscript }
                }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                library.deleteTarget = .meeting(id: meetingID, title: meeting.title, hasAudio: meeting.hasAudio)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    /// Where it's filed, when, how long, who, and the labels — each a chip.
    private func chips(meeting: Meeting) -> some View {
        FlowLayout(spacing: Tokens.Space.s) {
            MoveToFolderMenu(meetingID: meetingID, onMoved: { Task { await load() } }) {
                Chip(text: folderName, systemImage: "folder", showsChevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to another folder")

            Chip(text: meeting.startedAt.formatted(.dateTime.day().month(.wide).year().hour().minute()), systemImage: "calendar")
            if let duration = meeting.duration {
                Chip(text: duration.formattedDuration, systemImage: "clock")
            }
            Chip(text: meeting.resolvedType == .oneOnOne ? "1:1" : "Group", systemImage: "person.2", tint: meeting.resolvedType.badgeColor)
            if let org = meeting.org, !org.isEmpty {
                Chip(text: org, systemImage: "building.2")
            }
            if let refinement {
                let improvedChip = Chip(text: "Improved transcript", systemImage: "sparkles", tint: Color.accentColor)
                let detail = "Transcribed again from the recording with \(refinement.model) — \(refinement.words) words, against \(refinement.liveWords) in the live transcript"
                if hasLiveBackup {
                    Button { showComparison = true } label: { improvedChip }
                        .buttonStyle(.plain)
                        .help(detail + ". Click to compare the two.")
                } else {
                    improvedChip.help(detail)
                }
            } else if meeting.endedAt != nil, meeting.hasAudio, cannotImproveReason == nil, !env.refinementService.isActive(meetingID) {
                Button {
                    pendingConfirmation = .improveTranscript
                } label: {
                    Chip(text: "Live transcript", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
                .help("Made while recording, so it may have missed words. Click to transcribe the recording again with a larger model.")
            }
            let attendees = (meeting.attendees ?? []).filter { !$0.isEmpty }
            ForEach(attendees.prefix(3), id: \.self) { name in
                Chip(text: name, systemImage: "person")
            }
            if attendees.count > 3 {
                Chip(text: "+\(attendees.count - 3)")
                    .help(attendees.dropFirst(3).joined(separator: ", "))
            }
            ForEach(meeting.labels ?? [], id: \.self) { label in
                Chip(text: "#\(label)")
            }

            Button {
                showInfo.toggle()
            } label: {
                Chip(text: "Details", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            .help("How this meeting was recorded")
            .accessibilityLabel("Recording details")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                recordingDetails(meeting: meeting)
            }
        }
    }

    /// The folder this meeting is filed in (with its icon, if it has one); meetings at the top level are in the "Inbox".
    private var folderName: String {
        guard let folder = handle?.folderURL.deletingLastPathComponent() else { return "Inbox" }
        if folder.standardizedFileURL == env.rootURL.standardizedFileURL { return "Inbox" }
        return [FolderIcon.read(in: folder), folder.lastPathComponent].compactMap { $0 }.joined(separator: " ")
    }

    /// Buttons for the current tab, at the right of the tab bar.
    @ViewBuilder
    private func tabAccessory(meeting: Meeting) -> some View {
        switch selectedTab {
        case .summary:
            if !isSummarizing && !displaySummary.isEmpty {
                HStack(spacing: Tokens.Space.s) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displaySummary, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        pendingConfirmation = .regenerateSummary
                    } label: {
                        Label("Regenerate…", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .transcript:
            if !isLiveRecording {
                HStack(spacing: Tokens.Space.s) {
                    if meeting.hasAudio {
                        Button {
                            Task { await detectSpeakers() }
                        } label: {
                            Label("Detect speakers…", systemImage: "person.2.wave.2")
                        }
                        .disabled(env.diarizationService.isRunning(for: meetingID))
                        .help("Split “Others” into individual speakers using this meeting's audio")
                    }
                    Button {
                        importTranscriptText = ""
                        if segments.isEmpty {
                            showImportTranscript = true
                        } else {
                            pendingConfirmation = .importOverTranscript
                        }
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .help("Replace this transcript with text pasted from another tool")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .notes:
            if !isLiveRecording {
                Text(notesSaveState == .saving ? "Saving…" : "Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .audio:
            EmptyView()
        case .template(let id):
            templateAccessory(id: id)
        }
    }

    @ViewBuilder
    private func recordingDetails(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording details").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Transcribed with").foregroundStyle(.secondary); Text(meeting.transcriptionEngine.kind) }
                GridRow { Text("Model").foregroundStyle(.secondary); Text(meeting.modelId) }
                if let folder = handle?.folderURL {
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Text(folder.path).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            .font(.callout)
            Button("Show in Finder") {
                if let folder = handle?.folderURL { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            .controlSize(.small)
        }
        .padding()
        .frame(width: 340)
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .regenerateSummary: "Replace the current summary?"
        case .resumeRecording: "Resume recording this meeting?"
        case .importOverTranscript: "Replace the existing transcript?"
        case .improveTranscript: "Improve this transcript?"
        case .restoreLiveTranscript: "Restore the live transcript?"
        case .removeTemplate: "Remove this template tab?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .regenerateSummary:
            return "A new summary is written from the transcript. The current one is only replaced if the new one finishes."
        case .resumeRecording:
            return "Recording continues after the existing transcript. The earlier audio is kept in the meeting folder as a backup, but the Audio tab will play only the new recording."
        case .importOverTranscript:
            return "Importing replaces the whole transcript, including any edits you've made. The pasted text is stored as one block, not split by speaker."
        case .improveTranscript:
            return "The recording is transcribed again with a larger model, which usually finds a lot the live transcript missed. It replaces the current transcript, including any edits you've made; the live transcript is kept so you can restore it." + (env.speakerDetectionEnabled ? " Speakers are identified afterwards." : "") + " This takes a few minutes and runs in the background."
        case .restoreLiveTranscript:
            return "Goes back to the transcript made while recording. The improved one is replaced, including any edits made to it."
        case .removeTemplate:
            return "The write-up is deleted from this meeting. You can add the template again later."
        }
    }

    /// Notes taken by the user during or after the meeting. Editable and auto-saved
    /// (the "Saved" indicator is in the tab bar).
    @ViewBuilder
    private func notesTab(meeting: Meeting) -> some View {
        // If the meeting is actively recording, show the live notes from the controller.
        if let controller = env.activeRecordingController,
           controller.meetingHandle?.meeting.id == meetingID {
            column {
                TextEditor(text: Bindable(controller).notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            column {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $notes)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                    if notes.isEmpty {
                        Text("Jot notes here. They're kept with the meeting and used when the summary is written.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.task(id:)` restarts on every keystroke, cancelling the previous
            // pending save — a proper debounce.
            .task(id: notes) { await saveNotesDebounced() }
        }
    }

    private func saveNotesDebounced() async {
        guard notes != savedNotes else { notesSaveState = .saved; return }
        notesSaveState = .saving
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let text = notes
        if await env.attempt("save your notes", { try await env.meetingStore.writeNotes(text, for: meetingID) }) != nil {
            savedNotes = text
            if notes == text { notesSaveState = .saved }
        }
    }

    @ViewBuilder
    private func summaryTab(meeting: Meeting) -> some View {
        let jobError = summaryJob?.error

        if env.summaryService.isSummaryPending(meetingID) && displaySummary.isEmpty && !isSummarizing {
            pendingSummary
        } else if displaySummary.isEmpty && !isSummarizing {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "text.document")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No summary yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let error = jobError {
                    summaryErrorBanner(error)
                }
                Button {
                    generateSummary(meeting: meeting)
                } label: {
                    Label("Generate summary", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(displaySegments.isEmpty)
                if displaySegments.isEmpty {
                    Text("Record or import a transcript first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if isSummarizing {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(summaryJob?.progressText ?? "Generating summary…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { env.summaryService.cancel(for: meetingID) }
                        .controlSize(.small)
                }
                .readableWidth()
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.top, 8)
                if !displaySummary.isEmpty {
                    SummaryView(markdown: displaySummary)
                } else {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let error = jobError {
                    column { summaryErrorBanner(error).padding(.top, Tokens.Space.s) }
                }
                SummaryView(markdown: displaySummary)
            }
            .onAppear {
                // If the job completed while we were away, sync the persisted summary.
                if let job = summaryJob, case .completed = job.status, !job.partialSummary.isEmpty {
                    summary = job.partialSummary
                    env.summaryService.clearJob(for: meetingID)
                }
            }
        }
    }

    /// The summary is waiting for the improved transcript, which it's better written from.
    private var pendingSummary: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.regular)
            Text("The summary will be written once the transcript has been improved")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("It's more accurate that way. You'll find the progress above.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Write it now from the live transcript") {
                Task { await env.writeUps(for: meetingID, includeDefaults: true) }
            }
            .buttonStyle(.bordered)
            .disabled(displaySegments.isEmpty)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.Space.xl)
    }

    @ViewBuilder
    private func summaryErrorBanner(_ message: String) -> some View {
        Label {
            Text("Couldn't generate the summary: \(message)")
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.red)
    }

    @ViewBuilder
    private func audioTab(handle: MeetingHandle) -> some View {
        let fm = FileManager.default
        let folder = MeetingFolder(url: handle.folderURL)
        let cleanedExists = fm.fileExists(atPath: folder.cleanedAudioURL.path)
        let originalExists = fm.fileExists(atPath: folder.audioURL.path)
        let recoveredExists = fm.fileExists(atPath: folder.recoveredAudioURL.path)
        VStack(spacing: 12) {
            if cleanedExists && originalExists {
                // One player at a time (two could previously play over each other).
                Picker("Audio", selection: $audioSource) {
                    ForEach(AudioSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                AudioPlaybackView(audioURL: audioSource == .full ? (handle.audioURL ?? folder.audioURL) : folder.cleanedAudioURL)
                    .id(audioSource)
                Text(audioSource == .full
                     ? "Both sides of the call: you on the left, everyone else on the right."
                     : "Your microphone with the other people's voices reduced, for listening back to what you said.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if cleanedExists {
                AudioPlaybackView(audioURL: folder.cleanedAudioURL)
            } else if originalExists {
                AudioPlaybackView(audioURL: handle.audioURL ?? folder.audioURL)
            } else if recoveredExists {
                // Recording was interrupted; this is the salvaged crash-safe audio.
                Label("Recovered recording — salvaged after the app closed unexpectedly. Uncompressed and not echo-reduced.",
                      systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                AudioPlaybackView(audioURL: folder.recoveredAudioURL)
            } else {
                AudioPlaybackView(audioURL: nil)
            }
        }
        .padding(.vertical)
        .readableWidth()
        .padding(.horizontal, Tokens.Space.xl)
    }

    private func generateSummary(meeting: Meeting) {
        let segs = displaySegments
        guard !segs.isEmpty else { return }

        let modelId = env.summarizationModelId
        let meetingNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes

        // The saved summary stays in `summary`; the job's partial output is shown
        // while it runs, and the old text remains visible if the job fails.
        env.summaryService.generate(
            meetingID: meetingID,
            meetingTitle: meeting.title,
            segments: segs,
            meeting: meeting,
            engine: env.summarizationEngine,
            modelId: modelId,
            userNotes: meetingNotes,
            customPrompt: env.summaryPromptOverride,
            store: env.meetingStore
        )
    }

    // MARK: - Improving the transcript

    private var cannotImproveReason: String? {
        handle.flatMap { TranscriptRefinementService.unavailableReason(folder: $0.folderURL) }
    }

    /// Progress, outcome and the next step for the post-meeting transcript pass.
    @ViewBuilder
    private var refinementStrip: some View {
        if let status = env.refinementService.status(for: meetingID) {
            column {
                HStack(spacing: 10) {
                    switch status {
                    case .waiting(let reason):
                        ProgressView().controlSize(.small)
                        Text(reason).foregroundStyle(.secondary)
                    case .preparing(let progress):
                        ProgressView().controlSize(.small)
                        Text(progress.map { "Downloading the transcription model… \(Int($0 * 100))%" } ?? "Getting the transcription model ready…")
                            .foregroundStyle(.secondary)
                    case .running(let fraction):
                        ProgressView(value: fraction).frame(width: 120)
                        Text("Improving the transcript… \(Int(fraction * 100))%").foregroundStyle(.secondary)
                    case .identifyingSpeakers:
                        ProgressView().controlSize(.small)
                        Text("Transcript improved. Identifying speakers…").foregroundStyle(.secondary)
                    case .completed:
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        // The summary is rewritten from the new transcript on its own (see `startImprovingTranscript`).
                        Text(isSummarizing ? "Transcript improved. Updating the summary…" : "Transcript improved.")
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if status == .identifyingSpeakers {
                        // The transcript is already replaced; only the speaker labels are left.
                        EmptyView()
                    } else if env.refinementService.isActive(meetingID) {
                        Button("Cancel") { env.refinementService.cancel(meetingID) }.controlSize(.small)
                    } else {
                        Button {
                            env.refinementService.clear(meetingID)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                    }
                }
                .font(.callout)
                .padding(.top, Tokens.Space.s)
            }
        }
    }

    private func startImprovingTranscript() {
        guard let folder = handle?.folderURL else { return }
        // With no summary yet, say it's waiting for the improved transcript rather than offering to write one now.
        if summary.isEmpty { env.summaryService.setSummaryPending(true, for: meetingID) }
        Task {
            if await env.refinementService.refine(meetingID: meetingID, folderURL: folder, env: env) {
                await load()
                // The summary was written from the old transcript: write it again from the new one. The
                // template write-ups are left alone; each has its own Regenerate.
                await env.writeUps(for: meetingID, includeDefaults: false)
            } else {
                env.summaryService.setSummaryPending(false, for: meetingID)
            }
        }
    }

    private func restoreLiveTranscript() {
        guard let folder = handle?.folderURL else { return }
        Task {
            if await env.refinementService.restoreLiveTranscript(meetingID: meetingID, folderURL: folder, env: env) {
                await load()
            }
        }
    }

    // MARK: - Templates

    private func templateKey(_ id: String) -> SummaryGenerationService.TemplateKey {
        SummaryGenerationService.TemplateKey(meetingID: meetingID, templateID: id)
    }

    private func templateURL(_ id: String) -> URL? {
        handle.map { SummaryGenerationService.templateOutputURL(in: $0.folderURL, templateID: id) }
    }

    /// "+ Template", after the last tab.
    private var addTemplateButton: some View {
        Button {
            showTemplatePicker.toggle()
        } label: {
            Label("Template", systemImage: "plus")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Write this meeting up another way")
        .popover(isPresented: $showTemplatePicker, arrowEdge: .bottom) {
            TemplatePickerView(
                openIDs: Set(openTemplateIDs),
                onPick: { addTemplate($0) },
                onManage: {
                    showTemplatePicker = false
                    env.appRouter.showTemplatesPage = true
                }
            )
        }
    }

    @ViewBuilder
    private func templateTab(id: String) -> some View {
        let key = templateKey(id)
        let job = env.summaryService.templateJob(for: key)
        let running = env.summaryService.isRunning(key)
        let template = env.summaryTemplates.template(id: id)
        let failure = job?.error
        TemplateTabView(
            template: template,
            text: running ? (job?.partialSummary ?? "") : (templateOutputs[id] ?? ""),
            isRunning: running,
            isPending: env.summaryService.isTemplatePending(key),
            progress: job?.progressText ?? "Writing…",
            error: failure,
            canGenerate: !displaySegments.isEmpty,
            onGenerate: { if let template { runTemplate(template) } },
            onCancel: { env.summaryService.clearTemplateJob(key) },
            onRemove: { removeTemplateTab(id) }
        )
    }

    /// Copy / regenerate / remove, in the tab bar, for a template's write-up.
    @ViewBuilder
    private func templateAccessory(id: String) -> some View {
        let key = templateKey(id)
        let text = templateOutputs[id] ?? ""
        HStack(spacing: Tokens.Space.s) {
            if !text.isEmpty && !env.summaryService.isRunning(key) {
                Button {
                    copy(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let template = env.summaryTemplates.template(id: id) {
                    Button {
                        runTemplate(template)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(displaySegments.isEmpty)
                }
            }
            Button {
                pendingConfirmation = .removeTemplate(id)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Remove this tab")
            .accessibilityLabel("Remove tab")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Open a template's tab and, if there's a transcript and no write-up yet, write it.
    private func addTemplate(_ template: SummaryTemplate) {
        showTemplatePicker = false
        if !openTemplateIDs.contains(template.id) { openTemplateIDs.append(template.id) }
        selectedTab = .template(template.id)
        if templateOutputs[template.id] == nil, !displaySegments.isEmpty {
            runTemplate(template)
        }
    }

    private func runTemplate(_ template: SummaryTemplate) {
        guard let meeting = handle?.meeting, !displaySegments.isEmpty else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Running it by hand takes it off the queue of ones waiting to be written automatically.
        env.summaryService.dequeueTemplate(template.id, for: meetingID)
        env.summaryService.generateTemplate(
            key: templateKey(template.id),
            segments: displaySegments,
            meeting: meeting,
            engine: env.summarizationEngine,
            modelId: env.summarizationModelId,
            userNotes: trimmedNotes.isEmpty ? nil : notes,
            systemPrompt: template.systemPrompt,
            store: env.meetingStore
        )
    }

    private func removeTemplateTab(_ id: String) {
        env.summaryService.dequeueTemplate(id, for: meetingID)
        env.summaryService.clearTemplateJob(templateKey(id))
        if let url = templateURL(id) { try? FileManager.default.removeItem(at: url) }
        templateOutputs[id] = nil
        openTemplateIDs.removeAll { $0 == id }
        if selectedTab == .template(id) { selectedTab = .summary }
    }

    /// Read the write-ups saved in this meeting's `templates` folder. Tabs already
    /// open stay; saved ones not yet open are added in the order they were written.
    private func loadTemplateOutputs() {
        guard let folder = handle?.folderURL else { return }
        let directory = folder.appendingPathComponent("templates")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var outputs: [String: String] = [:]
        var written: [(id: String, date: Date)] = []
        for url in urls where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            outputs[id] = text
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            written.append((id, date))
        }
        templateOutputs = outputs
        let saved = written.sorted { $0.date < $1.date }.map(\.id)
        openTemplateIDs += saved.filter { !openTemplateIDs.contains($0) }
        openActiveTemplateTabs()
    }

    /// Default templates get a tab as soon as they're queued or running, not only once they've written something.
    private func openActiveTemplateTabs() {
        openTemplateIDs += env.summaryService.activeTemplateIDs(for: meetingID).filter { !openTemplateIDs.contains($0) }
    }

    /// A run finished: pick up what it wrote, and let go of runs that completed.
    private func reloadTemplateOutputs() {
        loadTemplateOutputs()
        for id in openTemplateIDs {
            let key = templateKey(id)
            if let job = env.summaryService.templateJob(for: key), case .completed = job.status {
                env.summaryService.clearTemplateJob(key)
            }
        }
    }

    // MARK: - Speakers

    @ViewBuilder
    private func speakerDetectionStatus(meeting: Meeting) -> some View {
        if let job = env.diarizationService.job(for: meetingID) {
            switch job.status {
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Identifying speakers…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            case .completed(let speakers):
                HStack(spacing: 8) {
                    Text(speakers > 0
                         ? "Found \(speakers) speakers. Right-click a name to rename."
                         : "Only one other person spoke, so there was nothing to split. Right-click “Others” to name them.")
                    if speakers > 0 && !summary.isEmpty {
                        Button("Update summary…") { pendingConfirmation = .regenerateSummary }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            case .failed(let message):
                Label("Couldn't identify speakers: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.leading, 8)
            }
        }
    }

    private func detectSpeakers() async {
        await env.diarizationService.diarize(meetingID: meetingID, store: env.meetingStore)
        await load()
    }

    /// Rename a speaker (e.g. "Others") for this meeting only.
    private func renameSpeaker(_ speakerID: String, to name: String) {
        guard var meeting = handle?.meeting else { return }
        meeting.participants = meeting.participants.map {
            $0.id == speakerID ? Speaker(id: $0.id, displayName: name, channel: $0.channel) : $0
        }
        let updated = meeting
        Task {
            await env.attempt("rename the speaker") { try await env.meetingStore.updateMeeting(updated) }
            await load()
        }
    }

    private func resumeRecording() async {
        guard let handle else { return }
        await env.recordingService.resume(handle: handle)
    }

    private func load() async {
        do {
            let h = try await env.meetingStore.openMeeting(id: meetingID)
            self.handle = h
            self.segments = (try? await env.meetingStore.loadTranscript(for: meetingID)) ?? []
            self.summary = (try? await env.meetingStore.loadSummary(for: meetingID)) ?? ""
            let loadedNotes = (try? await env.meetingStore.loadNotes(for: meetingID)) ?? ""
            self.notes = loadedNotes
            self.savedNotes = loadedNotes
            self.refinement = RefinementRecord.read(in: h.folderURL)
            self.hasLiveBackup = RefinementRecord.hasLiveBackup(in: h.folderURL)
            loadTemplateOutputs()

            // Default to Summary when opening a past meeting; while a meeting is
            // still recording live, Transcript is the useful view.
            if !didChooseInitialTab {
                didChooseInitialTab = true
                selectedTab = isLiveRecording ? .transcript : .summary
            }
        } catch {
            env.presentError(error, while: "open this meeting")
        }
    }
}

private struct ImportTranscriptSheet: View {
    @Binding var text: String
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Import transcript")
                    .font(.headline)
                Spacer()
            }

            Text("Paste a transcript from another tool. It replaces this meeting's transcript, so you can write a summary from it. Plain text works; it's stored as a single block rather than split by speaker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 300)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onImport()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 450)
    }
}
