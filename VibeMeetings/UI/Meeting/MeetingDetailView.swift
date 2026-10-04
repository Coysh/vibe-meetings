import SwiftUI
import VMCore
import VMStorage
import VMSummarization

struct MeetingDetailView: View {
    let meetingID: UUID
    var onOpenChat: ((UUID) -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
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

    private enum Confirmation: Identifiable {
        case regenerateSummary, resumeRecording, importOverTranscript
        var id: Self { self }
    }

    private enum AudioSource: String, CaseIterable, Identifiable {
        case full = "Full recording"
        case yourVoice = "Your voice only"
        var id: String { rawValue }
    }

    private enum NotesSaveState { case saved, saving }

    /// Order matches what people open a finished meeting for: the summary first.
    enum Tab: String, CaseIterable, Identifiable {
        case summary, transcript, notes, audio
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// The background summary job for this meeting, if any.
    private var summaryJob: SummaryJob? {
        env.summaryService.job(for: meetingID)
    }

    /// Whether a summary is currently being generated.
    private var isSummarizing: Bool {
        env.summaryService.isRunning(for: meetingID)
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
                header(meeting: handle.meeting)
                Divider()
                Picker("Section", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t.title).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding()

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
                                Divider()
                                HStack {
                                    speakerDetectionStatus(meeting: handle.meeting)
                                    Spacer()
                                    if handle.meeting.hasAudio {
                                        Button {
                                            Task { await detectSpeakers() }
                                        } label: {
                                            Label("Detect speakers…", systemImage: "person.2.wave.2")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
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
                                        Label("Import transcript…", systemImage: "square.and.arrow.down")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("Replace this transcript with text pasted from another tool")
                                    .padding(8)
                                }
                            }
                        }
                    case .notes:
                        notesTab(meeting: handle.meeting)
                    case .summary:
                        summaryTab(meeting: handle.meeting)
                    case .audio:
                        audioTab(handle: handle)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: meetingID) {
            await load()
        }
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
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { selectedTab = tab }
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
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(item))
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

    @ViewBuilder
    private func header(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(meeting.title).font(.title2).bold()
                        Badge(text: meeting.resolvedType.badgeLabel, color: meeting.resolvedType.badgeColor)
                    }

                    HStack(spacing: 16) {
                        Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        if let dur = meeting.duration {
                            Label(dur.formattedDuration, systemImage: "clock")
                        }
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("How this meeting was recorded")
                        .accessibilityLabel("Recording details")
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            recordingDetails(meeting: meeting)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Metadata row: org, attendees, labels
                    metadataRow(meeting: meeting)
                }
                Spacer()

                // Chat with this meeting
                Button {
                    onOpenChat?(meetingID)
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.bordered)
                .help("Ask questions about this meeting")

                // Edit metadata button
                Button {
                    editableMeeting = meeting
                } label: {
                    Label("Edit", systemImage: "pencil.circle")
                }
                .buttonStyle(.bordered)

                // Resume is rare and replaces the audio file, so it is a quiet,
                // confirmed action — not the most prominent button on every old meeting.
                if meeting.endedAt != nil && env.activeRecordingController == nil {
                    Button {
                        pendingConfirmation = .resumeRecording
                    } label: {
                        Label("Resume recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Continue recording into this meeting")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private func metadataRow(meeting: Meeting) -> some View {
        let parts: [String] = {
            var items: [String] = []
            if let org = meeting.org { items.append("Org: \(org)") }
            if let attendees = meeting.attendees, !attendees.isEmpty {
                items.append(attendees.joined(separator: ", "))
            }
            if let labels = meeting.labels, !labels.isEmpty {
                items.append(labels.map { "#\($0)" }.joined(separator: " "))
            }
            return items
        }()

        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
    }

    /// Notes taken by the user during or after the meeting. Editable and auto-saved.
    @ViewBuilder
    private func notesTab(meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            // If the meeting is actively recording, show the live notes from the controller.
            if let controller = env.activeRecordingController,
               controller.meetingHandle?.meeting.id == meetingID {
                TextEditor(text: Bindable(controller).notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // `.task(id:)` restarts on every keystroke, cancelling the previous
                // pending save — a proper debounce.
                .task(id: notes) { await saveNotesDebounced() }

                Divider()
                HStack {
                    Spacer()
                    Text(notesSaveState == .saving ? "Saving…" : "Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
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
        // While a job streams, show its partial text. Afterwards fall back to the
        // saved summary — so a failed regenerate leaves the old summary visible.
        let partial = summaryJob?.partialSummary ?? ""
        let displaySummary = isSummarizing ? partial : (partial.isEmpty ? summary : partial)
        let jobError = summaryJob?.error

        if displaySummary.isEmpty && !isSummarizing {
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
                .padding(.horizontal)
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
                    summaryErrorBanner(error)
                        .padding([.horizontal, .top])
                }
                SummaryView(markdown: displaySummary)
                Divider()
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displaySummary, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        pendingConfirmation = .regenerateSummary
                    } label: {
                        Label("Regenerate…", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(8)
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
        .padding(.horizontal)
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
        .padding()
    }

    private func generateSummary(meeting: Meeting) {
        let segs = displaySegments
        guard !segs.isEmpty else { return }

        let modelId = env.activeSummarizationKind == OpenAIEngine.kind
            ? env.selectedOpenAIModelId
            : env.selectedOllamaModelId
        let meetingNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        let prompt = env.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : env.customSystemPrompt

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
            customPrompt: prompt,
            store: env.meetingStore
        )
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
