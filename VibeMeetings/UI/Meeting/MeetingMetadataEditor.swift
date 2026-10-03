import SwiftUI
import VMCore

/// A form for editing a meeting's title, type, organisation, attendees and labels.
struct MeetingMetadataEditor: View {
    @Binding var meeting: Meeting
    let knownOrgs: [String]
    let onSave: (Meeting) -> Void

    @State private var titleText: String
    @State private var selectedType: MeetingType
    @State private var selectedOrg: String
    @State private var customOrgText: String
    @State private var attendeesText: String
    @State private var labelsText: String

    @Environment(\.dismiss) private var dismiss

    private static let noOrgTag = "__none__"
    private static let customOrgTag = "__custom__"

    init(meeting: Binding<Meeting>, knownOrgs: [String], onSave: @escaping (Meeting) -> Void) {
        self._meeting = meeting
        self.knownOrgs = knownOrgs
        self.onSave = onSave
        let m = meeting.wrappedValue
        _titleText = State(initialValue: m.title)
        _selectedType = State(initialValue: m.resolvedType)

        // A meeting with no organisation must stay that way unless the user
        // picks one — opening Edit and pressing Save used to silently assign
        // the first configured organisation.
        let currentOrg = m.org ?? ""
        if currentOrg.isEmpty {
            _selectedOrg = State(initialValue: Self.noOrgTag)
            _customOrgText = State(initialValue: "")
        } else if let known = knownOrgs.first(where: { $0.caseInsensitiveCompare(currentOrg) == .orderedSame }) {
            _selectedOrg = State(initialValue: known)
            _customOrgText = State(initialValue: "")
        } else {
            _selectedOrg = State(initialValue: Self.customOrgTag)
            _customOrgText = State(initialValue: currentOrg)
        }

        _attendeesText = State(initialValue: (m.attendees ?? []).joined(separator: ", "))
        _labelsText = State(initialValue: (m.labels ?? []).joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $titleText)

                Picker("Type", selection: $selectedType) {
                    Text("1:1").tag(MeetingType.oneOnOne)
                    Text("Group").tag(MeetingType.group)
                }
                .pickerStyle(.segmented)

                Picker("Organisation", selection: $selectedOrg) {
                    Text("None").tag(Self.noOrgTag)
                    if !knownOrgs.isEmpty { Divider() }
                    ForEach(knownOrgs, id: \.self) { org in
                        Text(org).tag(org)
                    }
                    Divider()
                    Text("Other…").tag(Self.customOrgTag)
                }

                if selectedOrg == Self.customOrgTag {
                    TextField("Organisation name", text: $customOrgText)
                }

                TextField("Attendees", text: $attendeesText, prompt: Text("Comma-separated names"))
                TextField("Labels", text: $labelsText, prompt: Text("Comma-separated labels"))
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 360)
        .navigationTitle("Edit meeting")
    }

    private func save() {
        var updated = meeting
        updated.title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.meetingType = selectedType

        let org: String
        switch selectedOrg {
        case Self.noOrgTag: org = ""
        case Self.customOrgTag: org = customOrgText.trimmingCharacters(in: .whitespacesAndNewlines)
        default: org = selectedOrg
        }
        updated.org = org.isEmpty ? nil : org

        let attendees = attendeesText.commaSeparatedItems
        updated.attendees = attendees.isEmpty ? nil : attendees
        let labels = labelsText.commaSeparatedItems
        updated.labels = labels.isEmpty ? nil : labels

        meeting = updated
        onSave(updated)
        dismiss()
    }
}
