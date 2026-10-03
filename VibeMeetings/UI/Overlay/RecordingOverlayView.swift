import SwiftUI
import VMCore

/// Content of the floating pill (see `RecordingOverlayController`).
struct RecordingOverlayView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .padding(10) // room for the shadow inside the transparent panel
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        let service = env.recordingService
        if let controller = service.controller {
            switch controller.state {
            case .preparing, .idle:
                startingRow
            case .error(let message):
                errorRow(message)
            default:
                RecordingRow(controller: controller)
            }
        } else if service.isStarting {
            startingRow
        } else if let failure = service.startFailure {
            failureRow(failure)
        } else if let call = env.bannerCoordinator.unrecordedCall {
            unrecordedRow(call)
        }
    }

    private var startingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting recording…").foregroundStyle(.secondary)
        }
        .padding(.trailing, 8)
        .gesture(WindowDragGesture())
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Recording failed").fontWeight(.medium)
            Button("Open") { env.presenter.show() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .help(message)
    }

    /// A start that failed, kept on screen with what to do about it.
    private func failureRow(_ failure: RecordingSessionService.StartFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Couldn't start recording").fontWeight(.medium)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            if let permission = failure.permission, let url = permission.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if failure.retry != nil {
                Button("Try again") { Task { await env.recordingService.retryFailedStart() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button {
                env.recordingService.dismissStartFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .help(failure.message)
    }

    private func unrecordedRow(_ call: CallSession) -> some View {
        let snoozed = env.bannerCoordinator.isCallSnoozed
        let label = env.bannerCoordinator.matchedEvent?.title ?? call.client.appName ?? "Call in progress"
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: snoozed ? "moon.zzz.fill" : "record.circle")
                    .foregroundStyle(snoozed ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(snoozed ? "Not recording · snoozed" : "Not recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            Button {
                Task { await env.recordingService.startDetectedCall() }
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)

            Menu {
                if !snoozed {
                    Button("Snooze 10 Minutes") { env.bannerCoordinator.snooze(sessionID: call.id) }
                }
                Button("Not a Meeting") { env.bannerCoordinator.notAMeeting(sessionID: call.id) }
                Divider()
                Button("Open Vibe Meetings") { env.presenter.show() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
        }
    }
}

/// Recording state: pulsing dot, title, timer, Stop. Split out so the 4 Hz
/// timer updates only re-render this row.
private struct RecordingRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let controller: RecordingController
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .accessibilityLabel("Recording")

                Button {
                    if let id = controller.meetingHandle?.meeting.id {
                        env.appRouter.selectMeetingID = id
                    }
                    env.presenter.show()
                } label: {
                    Text(controller.meetingHandle?.meeting.title ?? "Recording")
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show live transcript")

                Text(controller.elapsed.formattedTimestamp)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // A glance tells you the mic is live — and which mic.
                MiniMeter(level: controller.micLevel)
                    .help("Microphone: \(controller.micDeviceName)")
                    .accessibilityLabel("Microphone level, \(controller.micDeviceName)")
            }
            .gesture(WindowDragGesture())

            if let issue = controller.issues.first {
                Button {
                    if let url = issue.fix?.settingsURL { NSWorkspace.shared.open(url) } else { env.presenter.show() }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(issue.message + (issue.fix != nil ? " Click to open settings." : ""))
                .accessibilityLabel(issue.message)
            } else if case .loadingModel = controller.transcriptionStatus {
                ProgressView().controlSize(.small)
                    .help("Preparing live transcription — audio is already being recorded")
            }

            // The end-of-meeting prompt used to appear only inside the main window
            // (or a notification) — invisible during a call with the window closed.
            if env.bannerCoordinator.meetingEndSuggestion {
                Text("Meeting ended?")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(env.bannerCoordinator.meetingEndReason)
                Button("Keep recording") { env.bannerCoordinator.dismissMeetingEnd() }
                    .controlSize(.small)
            }

            Button {
                Task { await env.recordingService.stop() }
            } label: {
                if controller.isFinishing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(controller.isFinishing)
        }
    }
}

/// A tiny level bar for the floating pill.
private struct MiniMeter: View {
    let level: Float

    var body: some View {
        let pct = LevelMeterView.fraction(level)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule().fill(pct > 0.85 ? Color.red : Color.green).frame(width: 36 * pct)
        }
        .frame(width: 36, height: 5)
    }
}
