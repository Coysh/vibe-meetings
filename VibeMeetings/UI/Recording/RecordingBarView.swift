import SwiftUI
import VMCalendar
import VMCore
import VMRecording

/// The recording controls that float at the bottom of every page while a
/// meeting is being recorded: status, timer, levels, notes and Stop — plus a
/// warning button for anything wrong (system audio not captured, no live
/// transcript) and what the transcription model is doing.
struct RecordingBarView: View {
    @Bindable var controller: RecordingController
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onNavigateToMeeting: (() -> Void)?
    @State private var showNotes = false
    @State private var showIssues = false
    @State private var pulse = false

    var body: some View {
        FloatingActionBar {
            statusDot

            switch controller.state {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Starting…").font(.callout).foregroundStyle(.secondary)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2)
            default:
                if let title = controller.meetingHandle?.meeting.title {
                    Button {
                        onNavigateToMeeting?()
                    } label: {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Show live transcript")
                }

                Text(controller.elapsed.formattedTimestamp)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                LevelMeterView(level: controller.micLevel, label: "You", detail: controller.micDeviceName)
                if controller.systemAudioIssue == nil {
                    LevelMeterView(level: controller.systemLevel, label: "Others", detail: "System audio")
                } else {
                    Label("Others: not captured", systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if hasStatusToShow {
                    statusButton
                }

                if controller.state == .recording {
                    notesButton
                    stopButton
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: hasStatusToShow)
    }

    // MARK: - Pieces

    /// Recording indicator that doesn't rely on colour alone (it pulses, and the
    /// state is also announced), and honours Reduce Motion.
    private var statusDot: some View {
        Circle()
            .fill(controller.state == .recording ? Tokens.record : Color.gray)
            .frame(width: 12, height: 12)
            .opacity(controller.state == .recording && pulse && !reduceMotion ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(controller.state == .recording ? "Recording" : "Not recording")
    }

    private var stopButton: some View {
        Button {
            Task { await env.recordingService.stop() }
        } label: {
            if controller.isFinishing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            } else {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .buttonStyle(.capsule(.record))
        .disabled(controller.isFinishing)
    }

    private var notesButton: some View {
        Button {
            showNotes.toggle()
        } label: {
            Label("Notes", systemImage: "note.text")
                .symbolVariant(showNotes ? .fill : .none)
        }
        .buttonStyle(.capsule(.secondary))
        .help(showNotes ? "Hide meeting notes" : "Take notes during the meeting")
        .popover(isPresented: $showNotes, arrowEdge: .top) { notesEditor }
    }

    /// Something to tell the user: a problem, or the transcription model loading.
    private var hasStatusToShow: Bool {
        if !controller.issues.isEmpty { return true }
        if case .loadingModel = controller.transcriptionStatus, controller.state == .recording { return true }
        return false
    }

    private var statusButton: some View {
        Button {
            showIssues.toggle()
        } label: {
            if controller.issues.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain)
        .help(controller.issues.first?.message ?? "Preparing live transcription — audio is already being recorded")
        .accessibilityLabel(controller.issues.first?.message ?? "Preparing live transcription")
        .popover(isPresented: $showIssues, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controller.issues) { issue in
                    RecordingIssueRow(issue: issue)
                }
                if case .loadingModel(let progress) = controller.transcriptionStatus, controller.state == .recording {
                    modelLoadingRow(progress: progress)
                }
            }
            .frame(width: 380)
        }
    }

    private func modelLoadingRow(progress: Double?) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress).frame(width: 90)
                Text("Downloading the transcription model… \(Int(progress * 100))%")
            } else {
                ProgressView().controlSize(.small)
                Text("Preparing live transcription…")
            }
            Text("Audio is already being recorded.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $controller.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
            if controller.notes.isEmpty {
                Text("Jot notes here. They're saved with the meeting and used when the summary is written.")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 340, height: 180)
        .padding(10)
    }
}

/// One thing wrong with the recording, with a fix button where there is one.
struct RecordingIssueRow: View {
    let issue: RecordingIssue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(issue.message)
                .font(.caption)
            Spacer()
            if let fix = issue.fix, let url = fix.settingsURL {
                Button("Open \(fix.title) settings…") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14))
        .help(issue.detail ?? issue.message)
        .accessibilityElement(children: .combine)
    }
}

struct LevelMeterView: View {
    let level: Float       // dBFS, -120…0
    let label: String
    /// What is being measured (device name), for tooltip and VoiceOver.
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let pct = Self.fraction(level)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(pct))
                        .frame(width: proxy.size.width * pct)
                }
            }
            .frame(width: 80, height: 6)
        }
        .help(detail.map { "\(label): \($0)" } ?? label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level\(detail.map { ", \($0)" } ?? "")")
        .accessibilityValue(Self.description(level))
    }

    /// −60 dBFS (silence) … 0 dBFS (full scale) → 0…1.
    static func fraction(_ level: Float) -> Double {
        max(0, min(1, (Double(level) + 60) / 60))
    }

    private static func description(_ level: Float) -> String {
        switch fraction(level) {
        case ..<0.05: "silent"
        case ..<0.4: "quiet"
        case ..<0.85: "good"
        default: "very loud"
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct > 0.85 { return .red }
        if pct > 0.6 { return .yellow }
        return .green
    }
}
