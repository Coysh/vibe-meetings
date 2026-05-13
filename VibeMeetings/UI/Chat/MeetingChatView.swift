import SwiftUI
import VMCore
import VMSummarization

/// Global AI chat panel for asking questions across all meetings.
struct MeetingChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var chatService = MeetingChatService()
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Label("Chat to Meetings", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Spacer()
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
            Text("Ask a question about your meetings")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("e.g. \"What action items came from last week's standup?\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your meetings…", text: $inputText)
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

        let modelId = env.activeSummarizationKind == OpenAIEngine.kind
            ? env.selectedOpenAIModelId
            : env.selectedOllamaModelId

        chatService.send(
            question: question,
            engine: env.summarizationEngine,
            modelId: modelId,
            store: env.meetingStore,
            folderTree: env.folderTree
        )
    }
}
