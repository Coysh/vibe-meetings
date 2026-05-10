import SwiftUI
import VMCore
import VMRecording
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

    private let env: AppEnvironment
    private let coordinator = AudioCaptureCoordinator()
    private let merger = SegmentMerger()
    private var streamTasks: [Task<Void, Never>] = []
    private var clockTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
    }

    func start(handle: MeetingHandle) async {
        self.meetingHandle = handle
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
        // Reset privacy badge to whatever Ollama state we resolved at boot.
        env.privacyState = (env.ollamaBaseURL.host.flatMap { LocalhostOnlySession.isLoopback($0) } == false
                            && env.ollamaBaseURL.host != nil)
            ? .lan(host: env.ollamaBaseURL.host!)
            : .localOnly

        // 2. Start audio capture.
        do {
            try await coordinator.start(writingAudioTo: audioURL)
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
        streamTasks.append(Task { [weak self] in
            do {
                for try await seg in micStream { await self?.ingest(seg) }
            } catch { print("mic stream error: \(error)") }
        })
        streamTasks.append(Task { [weak self] in
            do {
                for try await seg in sysStream { await self?.ingest(seg) }
            } catch { print("sys stream error: \(error)") }
        })

        // Levels
        let levelStream = coordinator.levels
        streamTasks.append(Task { [weak self] in
            for await snap in levelStream {
                await MainActor.run {
                    self?.micLevel = snap.mic
                    self?.systemLevel = snap.system
                }
            }
        })

        clockTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.elapsed = Date().timeIntervalSince(started)
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
            // Persist finals and update meeting metadata.
            let finals = merger.finals()
            try? await env.meetingStore.replaceTranscript(finals, for: handle.meeting.id)

            var updated = handle.meeting
            updated.endedAt = Date()
            updated.hasAudio = result?.audioFileURL != nil
            try? FolderTreeScanner.writeMeeting(updated, to: MeetingFolder(url: handle.folderURL).metadataURL)
        }
        state = .idle
        if env.activeRecordingController === self {
            env.activeRecordingController = nil
        }
        return result
    }
}

struct RecordingBarView: View {
    @Bindable var controller: RecordingController

    var body: some View {
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
                Button("Stop") {
                    Task { await controller.stop() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
