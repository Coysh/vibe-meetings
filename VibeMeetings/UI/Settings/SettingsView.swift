import SwiftUI
import VMCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }
            EngineSettingsView().tabItem { Label("Engines", systemImage: "cpu") }
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            LabeledContent("Meetings folder") {
                HStack {
                    Text(env.rootURL.path).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            try? env.setRoot(url)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

private struct EngineSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var engineKind: String = "whisperkit"

    var body: some View {
        Form {
            Picker("Transcription engine", selection: $engineKind) {
                ForEach(env.transcriptionEngines, id: \.displayName) { engine in
                    Text(engine.displayName).tag(type(of: engine).kind)
                }
            }
            .onChange(of: engineKind) { _, kind in
                if let match = env.transcriptionEngines.first(where: { type(of: $0).kind == kind }) {
                    env.activeTranscriptionEngine = match
                }
            }

            TextField("Default transcription model", text: Binding(
                get: { env.selectedModelId },
                set: { env.selectedModelId = $0; UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedTranscriptionModelId") }
            ))

            TextField("Default Ollama model", text: Binding(
                get: { env.selectedOllamaModelId },
                set: { env.selectedOllamaModelId = $0; UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedOllamaModelId") }
            ))
        }
        .padding()
        .onAppear {
            engineKind = type(of: env.activeTranscriptionEngine).kind
        }
    }
}

private struct PrivacySettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("All audio, transcripts, and summaries stay on this Mac.", systemImage: "lock.shield.fill")
                .font(.headline)
            Text("vibe-meetings makes exactly two kinds of network connections, and neither is automatic:")
                .foregroundStyle(.secondary)
            Label("Local Ollama at 127.0.0.1:11434 — only when summarizing.", systemImage: "network")
            Label("Hugging Face / argmax CDN — only when you click Download for a transcription model.", systemImage: "arrow.down.circle")
            Text("There is no telemetry, analytics, crash reporting, or auto-update phone-home.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
