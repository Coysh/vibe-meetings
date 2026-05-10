import SwiftUI
import VMCore
import VMStorage

/// Sheet shown when the user invokes ⌘N (or "New Meeting…").
/// Creates the meeting in the chosen folder and hands a `MeetingHandle`
/// back to the caller, which starts the `RecordingController`.
struct NewMeetingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let parentFolder: FolderNode

    @State private var title: String = "New Meeting"
    @State private var creating = false
    @State private var error: String?

    let onCreated: (MeetingHandle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new meeting in \(parentFolder.name)").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let draft = MeetingDraft(
                title: title,
                transcriptionEngine: EngineRef(kind: type(of: env.activeTranscriptionEngine).kind, version: "1"),
                summarizationEngine: EngineRef(kind: "ollama", version: "1"),
                modelId: env.selectedModelId
            )
            let handle = try await env.meetingStore.createMeeting(in: parentFolder, draft: draft)
            onCreated(handle)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
