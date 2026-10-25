import SwiftUI
import VMCalendar
import VMCore

/// The record control in the main window's toolbar. It's on every page, so a
/// recording can be started — or stopped — from wherever you are, without going
/// Home or filling in a sheet first.
///
/// One click records now: linked to the calendar event that's on (its title
/// becomes the meeting's), or to the call app holding the microphone, else as
/// "Call 14:05". The chevron offers the longer routes: join a meeting link
/// first, or the New Meeting sheet to pick an event or type a title.
struct RecordToolbarButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let service = env.recordingService
        if let controller = service.controller {
            recordingControl(controller)
        } else if service.isStarting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        } else {
            idleControl
        }
    }

    // MARK: - Idle

    private var idleControl: some View {
        HStack(spacing: 2) {
            Button {
                Task { await env.recordingService.startDetectedCall() }
            } label: {
                Label(recordTitle, systemImage: "record.circle.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.capsule(.record))
            .help(recordHelp)

            Menu {
                Button("Record Now") {
                    Task { await env.recordingService.startDetectedCall() }
                }
                if let event = env.bannerCoordinator.joinableEvent, env.bannerCoordinator.currentCall == nil {
                    Button("Join & Record “\(event.title)”") {
                        Task { await env.recordingService.joinAndRecord(event: event) }
                    }
                }
                Divider()
                Button("New Meeting…") {
                    env.appRouter.requestNewMeeting()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More ways to start")
            .accessibilityLabel("More ways to start recording")
        }
    }

    /// The calendar event happening now, if there is one to record under.
    private var currentEvent: CalendarEvent? {
        let banner = env.bannerCoordinator
        return banner.matchedEvent ?? CurrentEventMatcher.bestMatch(events: banner.cachedEvents, now: Date())
    }

    private var recordTitle: String {
        guard let event = currentEvent else { return "Record" }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Record" }
        return "Record “\(title.count > 22 ? String(title.prefix(21)) + "…" : title)”"
    }

    private var recordHelp: String {
        if let event = currentEvent { return "Start recording now, as “\(event.title)” (⇧⌘R)" }
        if let app = env.bannerCoordinator.currentCall?.client.appName { return "Start recording the \(app) call now (⇧⌘R)" }
        return "Start recording now (⇧⌘R). Use the chevron to pick a calendar event or type a title first."
    }

    // MARK: - Recording

    private func recordingControl(_ controller: RecordingController) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.state == .recording ? Tokens.record : Color.gray)
                .frame(width: 9, height: 9)
                .opacity(controller.state == .recording && pulse && !reduceMotion ? 0.35 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .accessibilityHidden(true)

            Text(controller.elapsed.formattedTimestamp)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(controller.meetingHandle?.meeting.title ?? "Recording")

            if controller.state == .recording || controller.state == .paused {
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
                .help("Stop recording (⇧⌘R)")
            } else if case .error = controller.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Recording failed")
            } else {
                ProgressView().controlSize(.small)
                    .help("Starting…")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording, \(controller.elapsed.formattedTimestamp)")
    }
}
