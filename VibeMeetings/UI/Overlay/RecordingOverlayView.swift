import SwiftUI
import VMCore

/// The size the user picked for the floating indicator.
enum OverlaySizeMode: String, CaseIterable, Identifiable {
    case compact, standard, expanded

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the indicator actually renders. The picked size only applies while
/// recording (Expanded) or while recording / a call is detected (Compact);
/// "Starting…" and failures always use the Standard pill, which has room for
/// their message and buttons.
enum OverlayLayout: Equatable {
    case compact, standard, expanded
}

extension AppEnvironment {
    /// Read by both the panel controller (to size the window) and the view (to
    /// pick what to draw), so they can never disagree about which one is showing.
    var overlayLayout: OverlayLayout {
        let picked: OverlayLayout
        switch recordingOverlaySize {
        case .compact: picked = .compact
        case .standard: picked = .standard
        case .expanded: picked = .expanded
        }
        let service = recordingService
        if let controller = service.controller {
            switch controller.state {
            case .preparing, .idle, .error: return .standard
            default: return picked
            }
        }
        if service.isStarting || service.startFailure != nil { return .standard }
        if bannerCoordinator.unrecordedCall != nil { return picked == .compact ? .compact : .standard }
        return .standard
    }
}

/// Calls the overlay's view makes back into its panel controller (the window
/// frame isn't something SwiftUI can change).
struct OverlayActions: Sendable {
    /// Called repeatedly while the resize grip is dragged; `began` on the first call.
    var resize: @MainActor @Sendable (_ began: Bool) -> Void
    var endResize: @MainActor @Sendable () -> Void
}

/// Pill for Compact/Standard, rounded card for Expanded.
private struct OverlayShape: InsettableShape {
    var expanded: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        return expanded
            ? RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect)
            : Capsule().path(in: rect)
    }

    func inset(by amount: CGFloat) -> OverlayShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Content of the floating indicator (see `RecordingOverlayController`).
struct RecordingOverlayView: View {
    @Environment(AppEnvironment.self) private var env
    let actions: OverlayActions

    var body: some View {
        let layout = env.overlayLayout
        let shape = OverlayShape(expanded: layout == .expanded)

        Group {
            if layout == .expanded, let controller = env.recordingService.controller {
                ExpandedRecordingCard(controller: controller, actions: actions)
            } else {
                HStack(spacing: 10) {
                    content(layout: layout)
                }
                .font(.callout)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .frame(minHeight: 34)
                .fixedSize()
            }
        }
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(shape)
        // One drag gesture for the whole surface. Buttons (and AppKit-backed menus)
        // take the click first; everything else — text, padding, gaps — moves the
        // window. This is deliberately not `isMovableByWindowBackground`, which
        // doesn't reliably see through NSHostingView.
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .contextMenu { contextMenu }
        .preferredColorScheme(env.appearance.colorScheme)
    }

    @ViewBuilder
    private var contextMenu: some View {
        @Bindable var env = env
        Picker("Size", selection: $env.recordingOverlaySize) {
            ForEach(OverlaySizeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Reset Position") { env.resetRecordingOverlayPosition() }
        Button("Hide Floating Indicator") { env.showRecordingOverlay = false }
        Divider()
        Button("Open Vibe Meetings") { env.presenter.show() }
    }

    @ViewBuilder
    private func content(layout: OverlayLayout) -> some View {
        let service = env.recordingService
        if let controller = service.controller {
            switch controller.state {
            case .preparing, .idle:
                startingRow
            case .error(let message):
                errorRow(message)
            default:
                RecordingRow(controller: controller, compact: layout == .compact)
            }
        } else if service.isStarting {
            startingRow
        } else if let failure = service.startFailure {
            failureRow(failure)
        } else if let call = env.bannerCoordinator.unrecordedCall {
            unrecordedRow(call, compact: layout == .compact)
        }
    }

    private var startingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting recording…").foregroundStyle(.secondary)
        }
        .padding(.trailing, 8)
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

    private func unrecordedRow(_ call: CallSession, compact: Bool) -> some View {
        let snoozed = env.bannerCoordinator.isCallSnoozed
        let label = env.bannerCoordinator.matchedEvent?.title ?? call.client.appName ?? "Call in progress"
        return HStack(spacing: 8) {
            Image(systemName: snoozed ? "moon.zzz.fill" : "record.circle")
                .foregroundStyle(snoozed ? Color.secondary : Color.orange)
                .help(snoozed ? "Not recording · snoozed — \(label)" : "Not recording — \(label)")
            if !compact {
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

// MARK: - Recording

/// Opens the meeting being recorded in the main window.
@MainActor
private func showLiveTranscript(_ env: AppEnvironment, _ controller: RecordingController) {
    if let id = controller.meetingHandle?.meeting.id {
        env.appRouter.selectMeetingID = id
    }
    env.presenter.show()
}

/// The red "recording" dot, pulsing unless Reduce Motion is on.
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(pulse && !reduceMotion ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Recording")
    }
}

/// Steps the indicator between Compact, Standard and Expanded.
private struct OverlaySizeButton: View {
    @Environment(AppEnvironment.self) private var env
    let layout: OverlayLayout

    var body: some View {
        Button {
            switch layout {
            case .compact: env.recordingOverlaySize = .standard
            case .standard: env.recordingOverlaySize = .expanded
            case .expanded: env.recordingOverlaySize = .standard
            }
        } label: {
            Image(systemName: layout == .expanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(layout == .expanded ? "Smaller" : "Larger")
        .accessibilityLabel(layout == .expanded ? "Make indicator smaller" : "Make indicator larger")
    }
}

/// What's wrong, or what's loading, plus the "Meeting ended?" prompt — shared by
/// the Standard pill and the Expanded card. Used inline in an HStack, so it
/// contributes nothing (and no spacing) when there's nothing to show.
@MainActor @ViewBuilder
private func recordingAccessories(_ env: AppEnvironment, _ controller: RecordingController) -> some View {
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
}

/// Recording state: pulsing dot, title, timer, Stop. Split out so the 4 Hz
/// timer updates only re-render this row. Compact drops the title and meter.
private struct RecordingRow: View {
    @Environment(AppEnvironment.self) private var env
    let controller: RecordingController
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()

            if !compact {
                Button {
                    showLiveTranscript(env, controller)
                } label: {
                    Text(controller.meetingHandle?.meeting.title ?? "Recording")
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show live transcript")
            }

            Text(controller.elapsed.formattedTimestamp)
                .monospacedDigit()
                .foregroundStyle(compact ? .primary : .secondary)
                .help(compact ? (controller.meetingHandle?.meeting.title ?? "Recording") : "")

            if !compact {
                // A glance tells you the mic is live — and which mic.
                MiniMeter(level: controller.micLevel)
                    .help("Microphone: \(controller.micDeviceName)")
                    .accessibilityLabel("Microphone level, \(controller.micDeviceName)")
            }

            recordingAccessories(env, controller)

            Button {
                Task { await env.recordingService.stop() }
            } label: {
                if controller.isFinishing {
                    ProgressView().controlSize(.small)
                } else if compact {
                    Image(systemName: "stop.fill")
                } else {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(controller.isFinishing)
            .accessibilityLabel("Stop recording")

            OverlaySizeButton(layout: compact ? .compact : .standard)
        }
    }
}

/// The big card: live transcript tail and both meters. Resizable.
private struct ExpandedRecordingCard: View {
    @Environment(AppEnvironment.self) private var env
    let controller: RecordingController
    let actions: OverlayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            meters
            Divider()
            transcriptTail
            footer
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(actions: actions).padding(5)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Button {
                showLiveTranscript(env, controller)
            } label: {
                Text(controller.meetingHandle?.meeting.title ?? "Recording")
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Show live transcript")
            Spacer(minLength: 8)
            Text(controller.elapsed.formattedTimestamp)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            OverlaySizeButton(layout: .expanded)
        }
    }

    private var meters: some View {
        HStack(spacing: 16) {
            LevelMeterView(level: controller.micLevel, label: "You", detail: controller.micDeviceName)
            if controller.systemAudioIssue == nil {
                LevelMeterView(level: controller.systemLevel, label: "Others", detail: "System audio")
            } else {
                Label("Others: not captured", systemImage: "speaker.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The last few lines, pinned to the bottom. Deliberately not a ScrollView: a
    /// scroll view would swallow the window drag, and the full transcript is one
    /// click away on the title.
    private var transcriptTail: some View {
        let segments = Array(controller.liveSegments.suffix(10))
        return VStack(alignment: .leading, spacing: 6) {
            if segments.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            } else {
                ForEach(segments) { segment in
                    OverlayTranscriptLine(segment: segment, name: speakerName(for: segment))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
    }

    private var emptyMessage: String {
        switch controller.transcriptionStatus {
        case .loadingModel: return "Preparing live transcription…"
        case .unavailable: return "No live transcript — audio is still being recorded."
        case .live: return "Listening…"
        }
    }

    private func speakerName(for segment: TranscriptSegment) -> String {
        if let speaker = controller.meetingHandle?.meeting.participants.first(where: { $0.id == segment.speakerId }) {
            return speaker.displayName
        }
        switch segment.channel {
        case .mic: return "You"
        case .system: return "Others"
        case .mixed: return "Speaker"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            recordingAccessories(env, controller)
            Spacer(minLength: 8)
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
        .padding(.trailing, 14) // clear of the resize grip
    }
}

/// One caption: a speaker-coloured dot, the speaker, then what they said.
private struct OverlayTranscriptLine: View {
    let segment: TranscriptSegment
    let name: String

    var body: some View {
        let color = TranscriptView.speakerColor(speakerId: segment.speakerId, channel: segment.channel)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            (Text(name + "  ").fontWeight(.semibold).foregroundStyle(color) + Text(segment.text))
                .font(.callout)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(segment.isPartial ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// Bottom-right corner handle. Native edge resizing isn't dependable on a
/// borderless panel that never becomes key, so this drives the frame directly.
private struct ResizeGrip: View {
    let actions: OverlayActions
    @State private var isDragging = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for offset in [4.0, 8.0, 12.0] {
                path.move(to: CGPoint(x: size.width, y: size.height - offset))
                path.addLine(to: CGPoint(x: size.width - offset, y: size.height))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.7)), lineWidth: 1.2)
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle().inset(by: -4))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    actions.resize(!isDragging)
                    isDragging = true
                }
                .onEnded { _ in
                    isDragging = false
                    actions.endResize()
                }
        )
        .pointerStyle(.frameResize(position: .bottomTrailing))
        .help("Drag to resize")
        .accessibilityHidden(true)
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
