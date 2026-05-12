import SwiftUI
import VMCore

/// A popover form for editing meeting metadata (type, org, attendees, labels).
struct MeetingMetadataEditor: View {
    @Binding var meeting: Meeting
    let onSave: (Meeting) -> Void

    @State private var selectedType: MeetingType
    @State private var orgText: String
    @State private var attendeesText: String
    @State private var labelsText: String

    @Environment(\.dismiss) private var dismiss

    init(meeting: Binding<Meeting>, onSave: @escaping (Meeting) -> Void) {
        self._meeting = meeting
        self.onSave = onSave
        let m = meeting.wrappedValue
        _selectedType = State(initialValue: m.resolvedType)
        _orgText = State(initialValue: m.org ?? "")
        _attendeesText = State(initialValue: (m.attendees ?? []).joined(separator: ", "))
        _labelsText = State(initialValue: (m.labels ?? []).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Metadata").font(.headline)

            // Type picker
            HStack {
                Text("Type")
                    .frame(width: 80, alignment: .trailing)
                Picker("", selection: $selectedType) {
                    Text("1:1").tag(MeetingType.oneOnOne)
                    Text("Group").tag(MeetingType.group)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Org
            HStack {
                Text("Org")
                    .frame(width: 80, alignment: .trailing)
                TextField("e.g. EA, Marketing", text: $orgText)
                    .textFieldStyle(.roundedBorder)
            }

            // Attendees
            HStack(alignment: .top) {
                Text("Attendees")
                    .frame(width: 80, alignment: .trailing)
                TextField("Comma-separated names", text: $attendeesText)
                    .textFieldStyle(.roundedBorder)
            }

            // Labels
            HStack(alignment: .top) {
                Text("Labels")
                    .frame(width: 80, alignment: .trailing)
                TextField("Comma-separated labels", text: $labelsText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func save() {
        var updated = meeting
        updated.meetingType = selectedType

        let org = orgText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.org = org.isEmpty ? nil : org

        let attendees = attendeesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.attendees = attendees.isEmpty ? nil : attendees

        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.labels = labels.isEmpty ? nil : labels

        meeting = updated
        onSave(updated)
        dismiss()
    }
}
