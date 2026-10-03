import SwiftUI
import VMCore

/// Detail view for a selected folder: its meetings, newest first. (Selecting a
/// folder used to show the Dashboard, which looked like nothing had happened.)
struct FolderOverviewView: View {
    let folder: FolderNode
    let onOpenMeeting: (UUID) -> Void
    @Environment(AppEnvironment.self) private var env

    private var meetings: [Meeting] {
        folder.allMeetings.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.title2.bold())
                    Text("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    env.appRouter.requestNewMeeting()
                } label: {
                    Label("New meeting here", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()

            Divider()

            if meetings.isEmpty {
                ContentUnavailableView(
                    "This folder is empty",
                    systemImage: "folder",
                    description: Text("Meetings you record or move here will appear in this list.")
                )
            } else {
                List(meetings) { meeting in
                    Button {
                        onOpenMeeting(meeting.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).lineLimit(1)
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let duration = meeting.duration {
                                Text(duration.formattedDuration)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
