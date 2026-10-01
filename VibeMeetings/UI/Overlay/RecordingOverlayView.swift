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
        } else if let error = service.lastStartError {
            errorRow(error)
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
                Button("Open vibe-meetings") { env.presenter.show() }
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
    let controller: RecordingController
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

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
            }
            .gesture(WindowDragGesture())

            Button {
                Task { await env.recordingService.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
    }
}
