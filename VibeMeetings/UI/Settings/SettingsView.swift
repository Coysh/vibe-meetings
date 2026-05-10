import SwiftUI
import VMCore
import VMSummarization

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }
            EngineSettingsView().tabItem { Label("Engines", systemImage: "cpu") }
            CalendarSettingsView().tabItem { Label("Calendar", systemImage: "calendar") }
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 540)
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
    @State private var ollamaURLString: String = ""
    @State private var ollamaTestResult: OllamaTestResult = .untested
    @State private var ollamaTesting: Bool = false

    enum OllamaTestResult: Equatable {
        case untested
        case ok(version: String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $engineKind) {
                    ForEach(env.transcriptionEngines, id: \.displayName) { engine in
                        Text(engine.displayName).tag(type(of: engine).kind)
                    }
                }
                .onChange(of: engineKind) { _, kind in
                    if let match = env.transcriptionEngines.first(where: { type(of: $0).kind == kind }) {
                        env.activeTranscriptionEngine = match
                    }
                }

                TextField("Default model", text: Binding(
                    get: { env.selectedModelId },
                    set: { env.selectedModelId = $0; UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedTranscriptionModelId") }
                ))
            }

            Section {
                TextField("Endpoint", text: $ollamaURLString, prompt: Text("http://127.0.0.1:11434"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                hostHint

                HStack {
                    Button("Test connection") { Task { await test() } }
                        .disabled(ollamaTesting || URL(string: ollamaURLString)?.host == nil)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(URL(string: ollamaURLString)?.host == nil
                                  || ollamaURLString == env.ollamaBaseURL.absoluteString)
                    if ollamaTesting { ProgressView().controlSize(.small) }
                    Spacer()
                }

                testResultRow

                TextField("Default Ollama model", text: Binding(
                    get: { env.selectedOllamaModelId },
                    set: { env.selectedOllamaModelId = $0; UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedOllamaModelId") }
                ))
            } header: {
                Text("Ollama (summaries)")
            } footer: {
                Text("Default is `http://127.0.0.1:11434`. Point this at a self-hosted Ollama on your LAN (e.g. `http://192.168.1.50:11434`) if you'd rather not run Ollama on this Mac. The configured host is the only non-loopback destination this app is allowed to reach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            engineKind = type(of: env.activeTranscriptionEngine).kind
            ollamaURLString = env.ollamaBaseURL.absoluteString
        }
    }

    @ViewBuilder
    private var hostHint: some View {
        if let host = URL(string: ollamaURLString)?.host {
            if LocalhostOnlySession.isLoopback(host) {
                Label("Loopback — runs on this Mac", systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if LocalhostOnlySession.isLikelyLAN(host) {
                Label("LAN host (\(host)) — appears to be on your local network",
                      systemImage: "wifi.circle.fill")
                    .font(.caption).foregroundStyle(.blue)
            } else {
                Label("\(host) does not look like a private LAN address — your meeting transcripts will be sent there. Use only if you trust this server.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var testResultRow: some View {
        switch ollamaTestResult {
        case .untested:
            EmptyView()
        case .ok(let v):
            Label("Reachable — Ollama \(v)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func test() async {
        guard let url = URL(string: ollamaURLString) else { return }
        ollamaTesting = true
        defer { ollamaTesting = false }
        // Apply the allowlist for the test, then restore the saved one.
        let savedHost = env.ollamaBaseURL.host
        if let host = url.host?.lowercased(), !LocalhostOnlySession.isLoopback(host) {
            LocalhostOnlySession.setAllowedExtraHost(host)
        }
        let probe = OllamaEngine(baseURL: url, promptBundle: .main)
        let health = await probe.isAvailable()
        switch health {
        case .ok(let v): ollamaTestResult = .ok(version: v)
        case .notRunning: ollamaTestResult = .failure("Ollama is not responding at \(url.absoluteString)")
        case .unreachable(let r): ollamaTestResult = .failure("Unreachable: \(r)")
        case .modelMissing(let id): ollamaTestResult = .failure("Model missing: \(id)")
        }
        // Restore host allowlist for the actually-saved URL.
        if let savedHost, !LocalhostOnlySession.isLoopback(savedHost) {
            LocalhostOnlySession.setAllowedExtraHost(savedHost.lowercased())
        } else {
            LocalhostOnlySession.setAllowedExtraHost(nil)
        }
    }

    private func save() {
        guard let url = URL(string: ollamaURLString), url.host != nil else { return }
        env.setOllamaBaseURL(url)
        ollamaTestResult = .untested
    }
}

private struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch env.privacyState {
            case .localOnly, .downloadingModel:
                Label("All audio, transcripts, and summaries stay on this Mac.", systemImage: "lock.shield.fill")
                    .font(.headline)
            case .lan(let host):
                Label("Audio + transcripts stay on this Mac. Summaries are generated by your LAN Ollama at \(host).", systemImage: "wifi.circle.fill")
                    .font(.headline)
            }

            Text("vibe-meetings makes only the following network connections:")
                .foregroundStyle(.secondary)

            Label("Ollama at \(env.ollamaBaseURL.absoluteString) — only when summarizing.",
                  systemImage: "network")
            Label("Hugging Face / argmax CDN — only when you click Download for a transcription model.",
                  systemImage: "arrow.down.circle")
            Text("Every other host is rejected by `LocalhostOnlySession` at the URL-protocol layer. There is no telemetry, analytics, crash reporting, or auto-update phone-home.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
