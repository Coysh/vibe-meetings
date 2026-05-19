import Foundation
import Observation
import VMCore
import VMStorage
import VMSummarization

/// RAG-style chat service that queries across all meetings.
@Observable
@MainActor
final class MeetingChatService {

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        var content: String
        var referencedMeetings: [MeetingReference]
        let timestamp = Date()

        enum Role { case user, assistant }
    }

    struct MeetingReference: Identifiable, Hashable {
        let id: UUID
        let title: String
    }

    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private var streamTask: Task<Void, Never>?

    /// When non-nil, only these meeting IDs are searched. When nil, all meetings are included.
    var includedMeetingIDs: Set<UUID>?

    /// Custom system prompt override for chat. When empty, uses the bundled prompt.
    var customChatPrompt: String = ""

    func send(
        question: String,
        engine: any SummarizationEngine,
        modelId: String,
        store: FilesystemMeetingStore,
        folderTree: FolderNode?,
        liveRecording: (meeting: Meeting, segments: [TranscriptSegment])? = nil
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: trimmed, referencedMeetings: []))

        isStreaming = true
        streamTask = Task {
            await generateResponse(
                question: trimmed,
                engine: engine,
                modelId: modelId,
                store: store,
                folderTree: folderTree,
                liveRecording: liveRecording
            )
            isStreaming = false
        }
    }

    func clearHistory() {
        streamTask?.cancel()
        streamTask = nil
        messages.removeAll()
        isStreaming = false
    }

    // MARK: - Private

    private func generateResponse(
        question: String,
        engine: any SummarizationEngine,
        modelId: String,
        store: FilesystemMeetingStore,
        folderTree: FolderNode?,
        liveRecording: (meeting: Meeting, segments: [TranscriptSegment])? = nil
    ) async {
        // 1. Collect meetings from the folder tree, filtered by includedMeetingIDs if set.
        var allMeetings = collectAllMeetings(from: folderTree)
        if let filter = includedMeetingIDs {
            allMeetings = allMeetings.filter { filter.contains($0.id) }
        }

        // 2. Search for relevant meetings by keyword matching.
        let keywords = question.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 }

        var scored: [(meeting: Meeting, score: Int)] = []
        for meeting in allMeetings {
            var score = 0
            for keyword in keywords {
                if meeting.title.lowercased().contains(keyword) { score += 3 }
                if meeting.org?.lowercased().contains(keyword) == true { score += 2 }
                if meeting.attendees?.contains(where: { $0.lowercased().contains(keyword) }) == true { score += 2 }
            }
            // Also check summary/transcript on disk.
            if let summary = try? await store.loadSummary(for: meeting.id), !summary.isEmpty {
                for keyword in keywords {
                    if summary.lowercased().contains(keyword) { score += 2 }
                }
            }
            if score > 0 {
                scored.append((meeting, score))
            }
        }

        // If no keyword matches found, include the most recent meetings as context.
        if scored.isEmpty {
            let recent = allMeetings
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(5)
            scored = recent.map { ($0, 1) }
        }

        // Top 5 by relevance score.
        let topMeetings = scored
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map(\.meeting)

        // 3. Build context from matched meetings.
        var contextParts: [String] = []
        var references: [MeetingReference] = []

        for meeting in topMeetings {
            var meetingContext = "## \(meeting.title)\n"
            meetingContext += "Date: \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
            if let org = meeting.org { meetingContext += "Org: \(org)\n" }
            if let attendees = meeting.attendees, !attendees.isEmpty {
                meetingContext += "Attendees: \(attendees.joined(separator: ", "))\n"
            }

            // Prefer summary over transcript (more concise).
            if let summary = try? await store.loadSummary(for: meeting.id), !summary.isEmpty {
                let truncated = String(summary.prefix(4000))
                meetingContext += "\nSummary:\n\(truncated)\n"
            } else if let segments = try? await store.loadTranscript(for: meeting.id), !segments.isEmpty {
                let transcript = segments.map { $0.text }.joined(separator: " ")
                let truncated = String(transcript.prefix(4000))
                meetingContext += "\nTranscript:\n\(truncated)\n"
            }

            contextParts.append(meetingContext)
            references.append(MeetingReference(id: meeting.id, title: meeting.title))
        }

        // Include live recording context if available and relevant.
        if let live = liveRecording, !live.segments.isEmpty {
            let alreadyIncluded = references.contains(where: { $0.id == live.meeting.id })
            if !alreadyIncluded {
                var liveContext = "## \(live.meeting.title) (LIVE — currently recording)\n"
                liveContext += "Date: \(live.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
                if let org = live.meeting.org { liveContext += "Org: \(org)\n" }
                if let attendees = live.meeting.attendees, !attendees.isEmpty {
                    liveContext += "Attendees: \(attendees.joined(separator: ", "))\n"
                }
                let transcript = live.segments
                    .filter { !$0.isPartial }
                    .map { $0.text }
                    .joined(separator: " ")
                let truncated = String(transcript.prefix(4000))
                liveContext += "\nLive transcript:\n\(truncated)\n"
                contextParts.insert(liveContext, at: 0)
                references.insert(MeetingReference(id: live.meeting.id, title: "\(live.meeting.title) (live)"), at: 0)
            }
        }

        let fullContext = contextParts.joined(separator: "\n---\n\n")

        // 4. Load chat system prompt (prefer custom override if set).
        let trimmedCustom = customChatPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = trimmedCustom.isEmpty ? loadChatPrompt() : trimmedCustom

        // 5. Build a pseudo-transcript to feed to the summarization engine.
        // We reuse the engine's `summarize()` by wrapping the question + context
        // as a single segment with the chat system prompt as customPrompt.
        let combinedText = """
        User question: \(question)

        Meeting context:
        \(fullContext)
        """

        let segment = TranscriptSegment(
            speakerId: "user",
            channel: .mic,
            start: 0,
            end: 1,
            text: combinedText,
            isPartial: false
        )

        let placeholderMeeting = Meeting(
            id: UUID(),
            title: "Chat Query",
            startedAt: Date(),
            folderRelativePath: "",
            transcriptionEngine: EngineRef(kind: "chat", version: "1"),
            summarizationEngine: EngineRef(kind: "chat", version: "1"),
            modelId: modelId
        )

        // Append an empty assistant message to fill in progressively.
        let assistantMsg = ChatMessage(role: .assistant, content: "", referencedMeetings: references)
        messages.append(assistantMsg)
        let msgIndex = messages.count - 1

        do {
            let stream = engine.summarize(
                transcript: [segment],
                meeting: placeholderMeeting,
                modelId: modelId,
                style: .standard,
                userNotes: nil,
                customPrompt: systemPrompt
            )
            for try await chunk in stream {
                guard !Task.isCancelled else { break }
                messages[msgIndex].content += chunk
            }
        } catch {
            if messages[msgIndex].content.isEmpty {
                messages[msgIndex].content = "Sorry, I couldn't generate a response. Error: \(error.localizedDescription)"
            }
        }
    }

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

    private func loadChatPrompt() -> String {
        if let url = Bundle.main.url(forResource: "chat.system", withExtension: "md", subdirectory: "Prompts"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        // Fallback inline prompt.
        return """
        You are a meeting assistant. Answer the user's question based ONLY on the meeting context provided. \
        Reference which meeting(s) your answer comes from by name. Use Markdown formatting.
        """
    }
}
