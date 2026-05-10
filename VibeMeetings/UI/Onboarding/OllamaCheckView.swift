import SwiftUI
import VMCore
import VMSummarization

struct OllamaCheckView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var health: EngineHealth = .unreachable("checking…")
    @State private var checking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ollama (local LLM)", systemImage: "cpu").font(.title3.bold())

            switch health {
            case .ok(let v):
                Label("Running — \(v)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .notRunning:
                Label("Not running. Start it from the Ollama app or `ollama serve`.", systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
            case .unreachable(let reason):
                Label("Unreachable: \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .modelMissing(let id):
                Label("Model `\(id)` not pulled. Run `ollama pull \(id)`.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Re-check") { Task { await refresh() } }
                if checking { ProgressView().controlSize(.small) }
            }
        }
        .padding()
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        health = await env.summarizationEngine.isAvailable()
        checking = false
    }
}
