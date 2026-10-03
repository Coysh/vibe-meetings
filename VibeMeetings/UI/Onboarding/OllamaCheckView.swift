import SwiftUI
import VMCore
import VMSummarization

/// Onboarding step: are meeting summaries available? Optional — recording and
/// transcripts work without it.
struct SummaryEngineStep: View {
    @Environment(AppEnvironment.self) private var env
    @State private var health: EngineHealth?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summaries are written by a language model. Vibe Meetings can use Ollama running on this Mac (private, free) or OpenAI with your own key. You can set this up later in Settings → Engines; recording and transcripts work without it.")
                .foregroundStyle(.secondary)

            switch health {
            case nil:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for Ollama…") }
            case .ok(let version):
                Label("Ollama is running (\(version))", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .notRunning:
                Label("Ollama isn't running", systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
                Text("Install it from ollama.com and open the app, or run `ollama serve`.")
                    .font(.callout).foregroundStyle(.secondary)
            case .unreachable(let reason):
                Label("Couldn't reach Ollama", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .modelMissing(let id):
                Label("Ollama is running but the model “\(id)” isn't installed", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                Text("Run `ollama pull \(id)` in Terminal.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button("Check again") { Task { await refresh() } }
                .controlSize(.small)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        health = nil
        health = await env.summarizationEngine.isAvailable()
    }
}
