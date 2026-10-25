import SwiftUI
import VMCore

/// The size the user picked for the floating indicator.
enum OverlaySizeMode: String, CaseIterable, Identifiable {
    case compact, standard, expanded

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Text size of the live transcript in the Expanded card.
enum OverlayTextSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var font: Font {
        switch self {
        case .small: .callout
        case .medium: .body
        case .large: .title3
        }
    }

    var next: OverlayTextSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .small
        }
    }
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

    private var layoutIsExpanded: Bool { env.overlayLayout == .expanded }

    @ViewBuilder
    private var contextMenu: some View {
        @Bindable var env = env
        Picker("Size", selection: $env.recordingOverlaySize) {
            ForEach(OverlaySizeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.inline)
        if layoutIsExpanded {
            Picker("Text Size", selection: $env.overlayTextSize) {
                ForEach(OverlayTextSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.menu)
        }
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

/// The big card — a live transcript window: a header to drag it by, the
/// scrolling transcript grouped by speaker, and a footer with the meters, what
/// the echo canceller is doing, and Stop. Resizable from its corner.
private struct ExpandedRecordingCard: View {
    @Environment(AppEnvironment.self) private var env
    let controller: RecordingController
    let actions: OverlayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
            Divider()
            LiveTranscriptPane(controller: controller, textSize: env.overlayTextSize)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(actions: actions).padding(5)
        }
    }

    /// Title, timer and the size controls. The transcript scrolls, so this (and the footer) is
    /// where the card is dragged by.
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
            .help("Open this meeting in Vibe Meetings")
            Spacer(minLength: 8)
            Text(controller.elapsed.formattedTimestamp)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                env.overlayTextSize = env.overlayTextSize.next
            } label: {
                Image(systemName: "textformat.size")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Text size: \(env.overlayTextSize.title). Click for \(env.overlayTextSize.next.title.lowercased())")
            .accessibilityLabel("Transcript text size, \(env.overlayTextSize.title)")
            OverlaySizeButton(layout: .expanded)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                LevelMeterView(level: controller.micLevel, label: "You", detail: controller.micDeviceName)
                if controller.systemAudioIssue == nil {
                    LevelMeterView(level: controller.systemLevel, label: "Others", detail: "System audio")
                } else {
                    Label("Others: not captured", systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let echo = controller.echoStatus {
                    Label(echo.text, systemImage: echo.text == "Echo cancelled" ? "waveform.badge.minus" : "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(echo.detail)
                }
            }
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
                .accessibilityLabel("Stop recording")
            }
            .padding(.trailing, 14) // clear of the resize grip
        }
    }
}

/// The scrolling live transcript: consecutive lines from one speaker under one
/// name, the in-progress line dimmed, following the newest words unless the
/// reader has scrolled up to re-read something — then a button brings them back.
private struct LiveTranscriptPane: View {
    let controller: RecordingController
    let textSize: OverlayTextSize
    @State private var isNearBottom = true

    /// Enough to scroll back through, not so many the card lags on every update.
    private static let maxLines = 200
    private static let bottomID = "live-transcript-bottom"

    /// A run of consecutive lines from one speaker.
    private struct Group: Identifiable {
        let id: String
        let name: String
        let color: Color
        let start: TimeInterval
        let segments: [TranscriptSegment]
    }

    /// Changes whenever something new was said or the in-progress line was rewritten.
    private struct LatestKey: Equatable {
        let id: UUID?
        let textLength: Int
    }

    var body: some View {
        let segments = Array(controller.liveSegments.suffix(Self.maxLines))
        let groups = grouped(segments)
        let latest = LatestKey(id: segments.last?.id, textLength: segments.last?.text.count ?? 0)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if segments.isEmpty {
                        Text(emptyMessage)
                            .font(textSize.font)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle().fill(group.color).frame(width: 6, height: 6)
                                Text(group.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(group.color)
                                Text(group.start.formattedTimestamp)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(group.segments) { segment in
                                Text(segment.text)
                                    .font(textSize.font)
                                    .opacity(segment.isPartial ? 0.5 : 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
            // Follow new words only while the reader is at the bottom; never yank them away from
            // something they scrolled up to read.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 48
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onChange(of: latest) {
                if isNearBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: textSize) {
                if isNearBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !isNearBottom && !segments.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 8)
                    .help("Jump back to the newest words")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch controller.transcriptionStatus {
        case .loadingModel: return "Preparing live transcription… audio is already being recorded."
        case .unavailable: return "No live transcript — audio is still being recorded."
        case .live: return "Listening… what's said appears here."
        }
    }

    private func grouped(_ segments: [TranscriptSegment]) -> [Group] {
        var groups: [Group] = []
        var bucket: [TranscriptSegment] = []
        func flush() {
            guard let first = bucket.first else { return }
            groups.append(Group(
                id: "grp-\(first.id.uuidString)",
                name: speakerName(for: first),
                color: TranscriptView.speakerColor(speakerId: first.speakerId, channel: first.channel),
                start: first.start,
                segments: bucket
            ))
            bucket.removeAll()
        }
        for segment in segments {
            if let last = bucket.last, last.speakerId != segment.speakerId { flush() }
            bucket.append(segment)
        }
        flush()
        return groups
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
