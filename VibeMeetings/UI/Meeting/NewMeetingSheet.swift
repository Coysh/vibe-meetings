import SwiftUI
import VMCore
import VMStorage
import VMCalendar

/// Calendar-aware "start a new meeting" sheet. Creating the meeting and
/// starting the recording is delegated to `RecordingSessionService`.
///
/// Lists today's events at the top with the current/next event preselected;
/// the user can also start a blank meeting by typing a title. When an event
/// with a `calendarSeriesID` is chosen, the meeting is routed into the same
/// parent folder as previous occurrences of the series (via
/// `MeetingStore.folderForSeries`), regardless of which `parentFolder` was
/// passed in.
struct NewMeetingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let parentFolder: FolderNode
    let preselectedEventID: String?
    let onCreated: (MeetingHandle) -> Void

    @State private var todaysEvents: [CalendarEvent] = []
    @State private var selection: Selection = .blank
    @State private var manualTitle: String = "New Meeting"
    @State private var creating = false
    @State private var error: String?

    enum Selection: Hashable {
        case blank
        case event(String)        // CalendarEvent.id
    }

    init(parentFolder: FolderNode, preselectedEventID: String? = nil, onCreated: @escaping (MeetingHandle) -> Void) {
        self.parentFolder = parentFolder
        self.preselectedEventID = preselectedEventID
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new meeting").font(.headline)

            calendarSection

            Divider()

            blankSection

            Text("Engine: \(env.activeTranscriptionEngine.displayName) · Model: \(env.selectedModelId)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("Start") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart || creating)
            }
        }
        .padding()
        .frame(width: 500)
        .task { await reloadEvents() }
    }

    @ViewBuilder
    private var calendarSection: some View {
        if todaysEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today's events").font(.subheadline.bold())
                Text("No upcoming events in the next 12 hours, or calendar access not granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today's events").font(.subheadline.bold())
                List(selection: $selection) {
                    ForEach(todaysEvents) { ev in
                        EventRow(event: ev)
                            .tag(Selection.event(ev.id))
                    }
                }
                .listStyle(.bordered)
                .frame(height: 140)
            }
        }
    }

    @ViewBuilder
    private var blankSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: selection == .blank ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                Text("Or start a blank meeting").font(.subheadline.bold())
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = .blank }

            TextField("Title", text: $manualTitle)
                .textFieldStyle(.roundedBorder)
                .disabled(selection != .blank)
        }
    }

    private var canStart: Bool {
        switch selection {
        case .blank:
            return !manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .event(let id):
            return todaysEvents.contains(where: { $0.id == id })
        }
    }

    private func reloadEvents() async {
        let events = await env.calendarService.upcomingEvents(within: 12 * 60 * 60)
        todaysEvents = events
        if let preselectedEventID, events.contains(where: { $0.id == preselectedEventID }) {
            selection = .event(preselectedEventID)
        } else if let next = events.first(where: { $0.endDate > Date() }) {
            selection = .event(next.id)
        } else {
            selection = .blank
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let request: MeetingStartRequest
            switch selection {
            case .blank:
                request = .blank(title: manualTitle)
            case .event(let id):
                guard let ev = todaysEvents.first(where: { $0.id == id }) else {
                    throw MeetingStoreError.invalidName(id)
                }
                request = .event(ev)
            }
            if let handle = try await env.recordingService.start(request, fallbackParent: parentFolder) {
                onCreated(handle)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).lineLimit(1)
                    PlatformBadge(event: event)
                }
                Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) · \(event.calendarTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
