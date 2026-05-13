import SwiftUI
import VMCore

/// A form for editing meeting metadata (type, org, attendees, labels).
struct MeetingMetadataEditor: View {
    @Binding var meeting: Meeting
    let knownOrgs: [String]
    let onSave: (Meeting) -> Void

    @State private var selectedType: MeetingType
    @State private var selectedOrg: String
    @State private var customOrgText: String
    @State private var attendeesText: String
    @State private var labelsText: String

    @Environment(\.dismiss) private var dismiss

    private static let customOrgTag = "__custom__"

    init(meeting: Binding<Meeting>, knownOrgs: [String], onSave: @escaping (Meeting) -> Void) {
        self._meeting = meeting
        self.knownOrgs = knownOrgs
        self.onSave = onSave
        let m = meeting.wrappedValue
        _selectedType = State(initialValue: m.resolvedType)

        // Determine if the current org matches a known value or is custom.
        let currentOrg = m.org ?? ""
        if currentOrg.isEmpty {
            _selectedOrg = State(initialValue: knownOrgs.first ?? "")
            _customOrgText = State(initialValue: "")
        } else if knownOrgs.contains(where: { $0.caseInsensitiveCompare(currentOrg) == .orderedSame }) {
            _selectedOrg = State(initialValue: knownOrgs.first(where: { $0.caseInsensitiveCompare(currentOrg) == .orderedSame }) ?? currentOrg)
            _customOrgText = State(initialValue: "")
        } else {
            _selectedOrg = State(initialValue: Self.customOrgTag)
            _customOrgText = State(initialValue: currentOrg)
        }

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

            // Org picker
            HStack {
                Text("Org")
                    .frame(width: 80, alignment: .trailing)
                Picker("", selection: $selectedOrg) {
                    ForEach(knownOrgs, id: \.self) { org in
                        Text(org).tag(org)
                    }
                    Divider()
                    Text("Other…").tag(Self.customOrgTag)
                }
                .frame(width: 220)
            }

            if selectedOrg == Self.customOrgTag {
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .trailing)
                    TextField("Custom org name", text: $customOrgText)
                        .textFieldStyle(.roundedBorder)
                }
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

        let org: String
        if selectedOrg == Self.customOrgTag {
            org = customOrgText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            org = selectedOrg
        }
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
