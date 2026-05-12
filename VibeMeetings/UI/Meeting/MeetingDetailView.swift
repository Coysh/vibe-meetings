import SwiftUI
import VMCore
import VMStorage
import VMSummarization

struct MeetingDetailView: View {
    let meetingID: UUID
    @Environment(AppEnvironment.self) private var env
    @State private var handle: MeetingHandle?
    @State private var segments: [TranscriptSegment] = []
    @State private var summary: String = ""
    @State private var notes: String = ""
    @State private var selectedTab: Tab = .transcript
    @State private var showingMetadataEditor = false
    @State private var editableMeeting: Meeting?

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, notes, summary, audio
        var id: String { rawValue }
    }

    /// The background summary job for this meeting, if any.
    private var summaryJob: SummaryJob? {
        env.summaryService.job(for: meetingID)
    }

    /// Whether a summary is currently being generated.
    private var isSummarizing: Bool {
        env.summaryService.isRunning(for: meetingID)
    }

    /// When the active recording targets this meeting, show live segments
    /// instead of (empty) on-disk segments.
    private var displaySegments: [TranscriptSegment] {
        if let controller = env.activeRecordingController,
           controller.meetingHandle?.meeting.id == meetingID,
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
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch selectedTab {
                    case .transcript:
                        TranscriptView(segments: displaySegments, participants: handle.meeting.participants)
                    case .notes:
                        notesTab(meeting: handle.meeting)
                    case .summary:
                        summaryTab(meeting: handle.meeting)
                    case .audio:
                        AudioPlaybackView(audioURL: handle.audioURL)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: meetingID) {
            await load()
        }
        .onChange(of: env.activeRecordingController == nil) {
            // When recording stops the controller is nilled out; reload the
            // now-persisted transcript so it replaces the (stale) live view.
            Task { await load() }
        }
    }

    @ViewBuilder
    private func header(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(meeting.title).font(.title2).bold()
                        // Meeting type badge
                        Text(meeting.resolvedType == .oneOnOne ? "1:1" : "Group")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                meeting.resolvedType == .oneOnOne
                                    ? Color.blue.opacity(0.15)
                                    : Color.green.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(meeting.resolvedType == .oneOnOne ? .blue : .green)
                    }

                    HStack(spacing: 16) {
                        Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        if let dur = meeting.duration {
                            Label(dur.formattedDuration, systemImage: "clock")
                        }
                        Label(meeting.modelId, systemImage: "cpu")
                        Label(meeting.transcriptionEngine.kind, systemImage: "waveform")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Metadata row: org, attendees, labels
                    metadataRow(meeting: meeting)
                }
                Spacer()

                // Edit metadata button
                Button {
                    editableMeeting = meeting
                    showingMetadataEditor = true
                } label: {
                    Image(systemName: "pencil.circle")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingMetadataEditor) {
                    if var editable = editableMeeting {
                        MeetingMetadataEditor(
                            meeting: Binding(
                                get: { editable },
                                set: { editable = $0 }
                            ),
                            onSave: { updated in
                                Task {
                                    try? await env.meetingStore.updateMeeting(updated)
                                    await load()
                                }
                            }
                        )
                    }
                }

                // Show Resume button when meeting has ended and no other recording is active.
                if meeting.endedAt != nil && env.activeRecordingController == nil {
                    Button {
                        Task { await resumeRecording() }
                    } label: {
                        Label("Resume", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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
                .foregroundStyle(.tertiary)
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
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: notes) {
                        // Auto-save after editing.
                        let current = notes
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard current == notes else { return }
                            try? await env.meetingStore.writeNotes(notes, for: meetingID)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func summaryTab(meeting: Meeting) -> some View {
        let displaySummary = summaryJob?.partialSummary ?? summary
        let jobError = summaryJob?.error

        if displaySummary.isEmpty && !isSummarizing {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "text.document")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No summary yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let error = jobError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Button {
                    generateSummary(meeting: meeting)
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
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
                ProgressView()
                Text(summaryJob?.progressText ?? "Generating summary…")
                    .foregroundStyle(.secondary)
                if !displaySummary.isEmpty {
                    SummaryView(markdown: displaySummary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                SummaryView(markdown: displaySummary)
                Divider()
                HStack {
                    Spacer()
                    Button {
                        generateSummary(meeting: meeting)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .padding(8)
                }
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

    private func generateSummary(meeting: Meeting) {
        let segs = displaySegments
        guard !segs.isEmpty else { return }

        let modelId = env.activeSummarizationKind == OpenAIEngine.kind
            ? env.selectedOpenAIModelId
            : env.selectedOllamaModelId
        let meetingNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        let prompt = env.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : env.customSystemPrompt

        summary = "" // Clear local summary so the job's partial output takes over.

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

    private func resumeRecording() async {
        guard let handle else { return }
        let controller = RecordingController(env: env)
        env.activeRecordingController = controller
        env.bannerCoordinator.recordingDidStart()
        await controller.resume(handle: handle)
    }

    private func load() async {
        do {
            let h = try await env.meetingStore.openMeeting(id: meetingID)
            self.handle = h
            self.segments = (try? await env.meetingStore.loadTranscript(for: meetingID)) ?? []
            self.summary = (try? await env.meetingStore.loadSummary(for: meetingID)) ?? ""
            self.notes = (try? await env.meetingStore.loadNotes(for: meetingID)) ?? ""
        } catch {
            print("Could not load meeting \(meetingID): \(error)")
        }
    }
}
