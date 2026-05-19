import SwiftUI
import VMCore
import VMStorage
import VMSummarization

/// AI chat panel for asking questions about meetings.
/// Can be scoped to a specific meeting via `focusedMeetingID`.
struct MeetingChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var chatService = MeetingChatService()
    @State private var inputText = ""
    @State private var showSettings = false

    /// When set, the chat is scoped to this specific meeting.
    var focusedMeetingID: UUID? = nil

    /// Which engine to use for chat: "ollama" or "openai".
    @State private var chatEngineKind: String = ""
    /// When true, only selected meetings are included. When false, all meetings.
    @State private var filterMeetings = false
    /// IDs of meetings to include when filterMeetings is true.
    @State private var selectedMeetingIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                settingsPanel
                Divider()
            }
            messageList
            Divider()
            inputBar
        }
        .onAppear {
            chatEngineKind = env.activeSummarizationKind
            chatService.customChatPrompt = UserDefaults.standard.string(forKey: "VibeMeetings.ChatCustomPrompt") ?? ""
            // If focused on a specific meeting, auto-scope to it.
            if let focusedID = focusedMeetingID {
                filterMeetings = true
                selectedMeetingIDs = [focusedID]
                chatService.includedMeetingIDs = [focusedID]
            }
        }
    }

    // MARK: - Header

    /// Resolved title for the focused meeting, if any.
    private var focusedMeetingTitle: String? {
        guard let id = focusedMeetingID else { return nil }
        return collectAllMeetings(from: env.folderTree).first(where: { $0.id == id })?.title
            ?? env.activeRecordingController?.meetingHandle?.meeting.title
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(focusedMeetingID != nil ? "Chat" : "Chat to Meetings",
                      systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                if let title = focusedMeetingTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(showSettings ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Chat settings")
            if !chatService.messages.isEmpty {
                Button {
                    chatService.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear chat history")
            }
        }
        .padding(12)
    }

    // MARK: - Settings panel

    @ViewBuilder
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Engine picker
            Picker("Model", selection: $chatEngineKind) {
                Text("Ollama (local)").tag(OllamaEngine.kind)
                if !env.openAIApiKey.isEmpty {
                    Text("OpenAI").tag(OpenAIEngine.kind)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            // Meeting filter
            Toggle("Limit to selected meetings", isOn: $filterMeetings)
                .font(.caption)
                .onChange(of: filterMeetings) {
                    chatService.includedMeetingIDs = filterMeetings ? selectedMeetingIDs : nil
                }

            if filterMeetings {
                meetingPicker
            }

            // Custom prompt
            DisclosureGroup("Custom prompt") {
                TextEditor(text: Binding(
                    get: { chatService.customChatPrompt },
                    set: {
                        chatService.customChatPrompt = $0
                        UserDefaults.standard.set($0, forKey: "VibeMeetings.ChatCustomPrompt")
                    }
                ))
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 80)

                HStack {
                    Text("Leave blank for the default prompt.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if !chatService.customChatPrompt.isEmpty {
                        Button("Clear") {
                            chatService.customChatPrompt = ""
                            UserDefaults.standard.removeObject(forKey: "VibeMeetings.ChatCustomPrompt")
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var meetingPicker: some View {
        let allMeetings = collectAllMeetings(from: env.folderTree)
            .sorted { $0.startedAt > $1.startedAt }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(allMeetings, id: \.id) { meeting in
                    HStack(spacing: 6) {
                        Image(systemName: selectedMeetingIDs.contains(meeting.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedMeetingIDs.contains(meeting.id)
                                             ? Color.accentColor : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedMeetingIDs.contains(meeting.id) {
                            selectedMeetingIDs.remove(meeting.id)
                        } else {
                            selectedMeetingIDs.insert(meeting.id)
                        }
                        chatService.includedMeetingIDs = selectedMeetingIDs.isEmpty ? nil : selectedMeetingIDs
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 120)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))

        if !selectedMeetingIDs.isEmpty {
            Text("\(selectedMeetingIDs.count) meeting\(selectedMeetingIDs.count == 1 ? "" : "s") selected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Message list

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatService.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(chatService.messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: chatService.messages.count) {
                if let last = chatService.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatService.messages.last?.content) {
                if let last = chatService.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            if focusedMeetingID != nil {
                Text("Ask a question about this meeting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("e.g. \"What were the key decisions?\"")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Ask a question about your meetings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("e.g. \"What action items came from last week's standup?\"")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func chatBubble(_ message: MeetingChatService.ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.referencedMeetings.isEmpty {
                    HStack(spacing: 4) {
                        Text("Based on:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        ForEach(message.referencedMeetings) { ref in
                            Text(ref.title)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if message.content.isEmpty && chatService.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(LocalizedStringKey(message.content))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input bar

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(focusedMeetingID != nil ? "Ask about this meeting…" : "Ask about your meetings…", text: $inputText)
                .textFieldStyle(.plain)
                .onSubmit { sendMessage() }
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
        }
        .padding(12)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatService.isStreaming
    }

    private func sendMessage() {
        guard canSend else { return }
        let question = inputText
        inputText = ""

        // Resolve engine and model based on the chat-specific picker.
        let engine: any SummarizationEngine
        let modelId: String
        if chatEngineKind == OpenAIEngine.kind && !env.openAIApiKey.isEmpty {
            engine = OpenAIEngine(apiKey: env.openAIApiKey, promptBundle: .main)
            modelId = env.selectedOpenAIModelId
        } else {
            engine = OllamaEngine(baseURL: env.ollamaBaseURL, promptBundle: .main)
            modelId = env.selectedOllamaModelId
        }

        // Include live recording context if a meeting is currently being recorded.
        var liveRecording: (meeting: Meeting, segments: [TranscriptSegment])?
        if let controller = env.activeRecordingController,
           let handle = controller.meetingHandle,
           !controller.liveSegments.isEmpty {
            liveRecording = (meeting: handle.meeting, segments: controller.liveSegments)
        }

        chatService.send(
            question: question,
            engine: engine,
            modelId: modelId,
            store: env.meetingStore,
            folderTree: env.folderTree,
            liveRecording: liveRecording
        )
    }

    // MARK: - Helpers

    private func collectAllMeetings(from node: FolderNode?) -> [Meeting] {
        guard let node else { return [] }
        var result: [Meeting] = []
        if node.isMeeting, let m = node.meeting {
            result.append(m)
        }
        for child in node.children {
            result.append(contentsOf: collectAllMeetings(from: child))
        }
        return result
    }
}
