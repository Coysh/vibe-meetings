import SwiftUI
import VMCalendar
import VMCore
import VMRecording
import VMSummarization
import VMTranscription
import VMStorage

/// Floating recording controller. Bound to a single in-progress meeting;
/// owns the `AudioCaptureCoordinator` and the live transcription pipeline.
@MainActor
@Observable
final class RecordingController {
    var state: CaptureState = .idle
    var elapsed: TimeInterval = 0
    var micLevel: Float = -120
    var systemLevel: Float = -120
    var liveSegments: [TranscriptSegment] = []
    var meetingHandle: MeetingHandle?

    /// The calendar event linked to this recording, if any. Used for auto-end detection.
    var linkedCalendarEvent: CalendarEvent?

    /// User's free-form notes taken during the meeting.
    var notes: String = ""

    private let env: AppEnvironment
    private let coordinator = AudioCaptureCoordinator()
    private let merger = SegmentMerger()
    private var streamTasks: [Task<Void, Never>] = []
    private var clockTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
    }

    deinit {
        print("[RecordingController] DEINIT — RecordingController is being deallocated!")
    }

    /// Resume recording for an existing meeting. Loads the previously saved
    /// segments so they appear in the live view, then starts a new audio
    /// capture session. The new audio replaces the old audio file.
    func resume(handle: MeetingHandle) async {
        // Load existing segments so the live view shows the full history.
        if let existing = try? await env.meetingStore.loadTranscript(for: handle.meeting.id) {
            for seg in existing {
                merger.ingest(seg)
            }
            liveSegments = merger.snapshot()
        }
        // Load existing notes.
        if let existingNotes = try? await env.meetingStore.loadNotes(for: handle.meeting.id) {
            notes = existingNotes
        }
        // Clear the endedAt so the meeting appears as in-progress again.
        var updated = handle.meeting
        updated.endedAt = nil
        try? FolderTreeScanner.writeMeeting(updated, to: MeetingFolder(url: handle.folderURL).metadataURL)

        await start(handle: handle)
    }

    func start(handle: MeetingHandle) async {
        self.meetingHandle = handle
        // Look up the linked calendar event for auto-end detection.
        if let eventID = handle.meeting.calendarEventID {
            let events = await env.calendarService.upcomingEvents(within: 24 * 60 * 60)
            self.linkedCalendarEvent = events.first(where: { $0.id == eventID })
        }
        let audioURL = handle.folderURL.appendingPathComponent(MeetingFolder.audioFilename)

        // 1. Make sure the transcription model is loaded before audio capture
        //    starts. loadModel is idempotent — instant on second+ runs, but on
        //    the very first run this is the model download (medium ≈ 1.5 GB).
        //    The privacy badge flips to yellow during the download.
        state = .preparing
        let modelId = env.selectedModelId
        env.privacyState = .downloadingModel(progress: 0)
        do {
            try await env.activeTranscriptionEngine.loadModel(id: modelId) { p in
                Task { @MainActor in
                    self.env.privacyState = .downloadingModel(progress: p)
                }
            }
        } catch {
            state = .error("Could not load model \(modelId): \(error.localizedDescription)")
            env.privacyState = .localOnly
            return
        }
        // Reset privacy badge to reflect the active summarization engine.
        if env.activeSummarizationKind == OpenAIEngine.kind {
            env.privacyState = .cloud(provider: "OpenAI")
        } else if let host = env.ollamaBaseURL.host,
                  !LocalhostOnlySession.isLoopback(host) {
            env.privacyState = .lan(host: host)
        } else {
            env.privacyState = .localOnly
        }

        // 2. Start audio capture.
        let micID = env.selectedMicDeviceID
        print("[RecordingController] selectedMicDeviceUID=\(env.selectedMicDeviceUID ?? "nil"), resolved deviceID=\(String(describing: micID))")
        do {
            try await coordinator.start(writingAudioTo: audioURL, micDeviceID: micID)
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        state = .recording

        // Live transcription pumps — one per channel.
        let micStream = env.activeTranscriptionEngine.transcribeStream(
            input: coordinator.micPCM,
            channel: .mic,
            speakerId: Speaker.you.id,
            options: .default
        )
        let sysStream = env.activeTranscriptionEngine.transcribeStream(
            input: coordinator.systemPCM,
            channel: .system,
            speakerId: Speaker.others.id,
            options: .default
        )
        // NOTE: These tasks capture `self` strongly so the RecordingController
        // stays alive while recording. The retain cycle is broken in stop() which
        // cancels all tasks and clears the arrays.
        streamTasks.append(Task {
            do {
                for try await seg in micStream { self.ingest(seg) }
            } catch { print("mic stream error: \(error)") }
        })
        streamTasks.append(Task {
            do {
                for try await seg in sysStream { self.ingest(seg) }
            } catch { print("sys stream error: \(error)") }
        })

        // Levels
        let levelStream = coordinator.levels
        streamTasks.append(Task {
            for await snap in levelStream {
                self.micLevel = snap.mic
                self.systemLevel = snap.system
            }
        })

        clockTask = Task {
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func ingest(_ seg: TranscriptSegment) {
        merger.ingest(seg)
        liveSegments = merger.snapshot()
    }

    func stop() async -> CaptureResult? {
        guard state == .recording || state == .paused else { return nil }
        let result = try? await coordinator.stop()

        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        clockTask?.cancel(); clockTask = nil

        if let handle = meetingHandle {
            // Persist transcript. In streaming mode every segment is marked
            // partial (there's no explicit finalization step), so we promote
            // all partials to finals before saving.
            let allSegments = merger.snapshot().map { seg in
                var s = seg
                s.isPartial = false
                return s
            }
            try? await env.meetingStore.replaceTranscript(allSegments, for: handle.meeting.id)

            // Persist user notes if any were taken.
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await env.meetingStore.writeNotes(notes, for: handle.meeting.id)
            }

            var updated = handle.meeting
            updated.endedAt = Date()
            updated.hasAudio = result?.audioFileURL != nil
            try? FolderTreeScanner.writeMeeting(updated, to: MeetingFolder(url: handle.folderURL).metadataURL)
        }
        state = .idle
        if env.activeRecordingController === self {
            env.activeRecordingController = nil
            env.bannerCoordinator.recordingDidStop()
        }
        return result
    }
}

struct RecordingBarView: View {
    @Bindable var controller: RecordingController
    @State private var showNotes = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(controller.state == .recording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)

                if case .preparing = controller.state {
                    ProgressView().controlSize(.small)
                    Text("Loading model…").font(.caption).foregroundStyle(.secondary)
                } else if case .error(let msg) = controller.state {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(controller.elapsed.formattedTimestamp)
                        .font(.title3.monospacedDigit())
                    LevelMeterView(level: controller.micLevel, label: "You")
                    LevelMeterView(level: controller.systemLevel, label: "Others")
                }

                Spacer()

                if controller.state == .recording {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showNotes.toggle() }
                    } label: {
                        Image(systemName: showNotes ? "note.text.badge.plus" : "note.text")
                    }
                    .help("Meeting notes")

                    Button("Stop") {
                        Task { await controller.stop() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showNotes && controller.state == .recording {
                Divider()
                TextEditor(text: Bindable(controller).notes)
                    .font(.body)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .background(.ultraThinMaterial)
    }
}

struct LevelMeterView: View {
    let level: Float       // dBFS, -120…0
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let pct = max(0, min(1, (Double(level) + 60) / 60))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(pct))
                        .frame(width: proxy.size.width * pct)
                }
            }
            .frame(width: 80, height: 6)
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct > 0.85 { return .red }
        if pct > 0.6 { return .yellow }
        return .green
    }
}
