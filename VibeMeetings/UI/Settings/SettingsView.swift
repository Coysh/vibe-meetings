import SwiftUI
import VMCore
import VMRecording
import VMSummarization

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }
            EngineSettingsView().tabItem { Label("Engines", systemImage: "cpu") }
            CalendarSettingsView().tabItem { Label("Calendar", systemImage: "calendar") }
            PromptSettingsView().tabItem { Label("Prompts", systemImage: "text.quote") }
        }
        .frame(width: 560, height: 540)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var inputDevices: [AudioInputDevice] = AudioDeviceEnumerator.inputDevices()

    /// Binding that maps `nil` (system default) ↔ empty string for the Picker.
    private var micSelection: Binding<String> {
        Binding(
            get: { env.selectedMicDeviceUID ?? "" },
            set: { env.setMicDevice(uid: $0.isEmpty ? nil : $0) }
        )
    }

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

            Picker("Microphone", selection: micSelection) {
                Text("System Default").tag("")
                ForEach(inputDevices) { device in
                    Text(device.name + (device.isDefault ? " (Default)" : ""))
                        .tag(device.uid)
                }
            }

            if let uid = env.selectedMicDeviceUID,
               !inputDevices.contains(where: { $0.uid == uid }) {
                Label("Selected microphone is not currently connected.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("Updates") {
                TextField("GitHub repo (owner/repo)", text: Binding(
                    get: { env.updateChecker.githubRepo },
                    set: { env.updateChecker.githubRepo = $0 }
                ), prompt: Text("e.g. timcoysh/vibe-meetings"))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Check now") {
                        Task { await env.updateChecker.checkForUpdates() }
                    }
                    .disabled(env.updateChecker.isChecking || env.updateChecker.githubRepo.isEmpty)

                    if env.updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                    }

                    if let update = env.updateChecker.availableUpdate {
                        Label("v\(update.version) available", systemImage: "arrow.down.app.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if let error = env.updateChecker.checkError {
                        Label(error, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
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
    @State private var models: [TranscriptionModelInfo] = []
    @State private var downloadingID: String? = nil
    @State private var downloadError: String? = nil
    @State private var ollamaURLString: String = ""
    @State private var ollamaTestResult: OllamaTestResult = .untested
    @State private var ollamaTesting: Bool = false
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var openAIModels: [SummarizationModelInfo] = []
    @State private var openAITestResult: String? = nil
    @State private var openAITesting: Bool = false

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
                    models = []
                    Task { await loadModels() }
                }

                if models.isEmpty {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                } else {
                    ForEach(models) { m in modelRow(m) }
                }

                if let err = downloadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
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

            Section {
                Picker("Summary engine", selection: Binding(
                    get: { env.activeSummarizationKind },
                    set: { kind in
                        if kind == "openai" && !openAIKey.isEmpty {
                            env.setOpenAI(apiKey: openAIKey, modelId: openAIModel.isEmpty ? "gpt-4o-mini" : openAIModel)
                        } else {
                            env.setOllamaAsSummarizer()
                        }
                    }
                )) {
                    Text("Ollama (local)").tag("ollama")
                    Text("OpenAI").tag("openai")
                }

                SecureField("API Key", text: $openAIKey, prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Test & Save") {
                        Task { await testAndSaveOpenAI() }
                    }
                    .disabled(openAITesting || openAIKey.isEmpty)
                    .buttonStyle(.borderedProminent)

                    if openAITesting { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let result = openAITestResult {
                    Label(result, systemImage: result.contains("OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(result.contains("OK") ? .green : .red)
                }

                if !openAIModels.isEmpty {
                    Picker("Model", selection: $openAIModel) {
                        ForEach(openAIModels) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    }
                    .onChange(of: openAIModel) { _, newModel in
                        if env.activeSummarizationKind == "openai" && !openAIKey.isEmpty {
                            env.setOpenAI(apiKey: openAIKey, modelId: newModel)
                        }
                    }
                } else if env.activeSummarizationKind == "openai" {
                    TextField("Model", text: $openAIModel, prompt: Text("gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("OpenAI (summaries)")
            } footer: {
                Text("Your API key is stored locally. Transcripts are sent to OpenAI's API for summarization when this engine is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            engineKind = type(of: env.activeTranscriptionEngine).kind
            ollamaURLString = env.ollamaBaseURL.absoluteString
            openAIKey = env.openAIApiKey
            openAIModel = env.selectedOpenAIModelId
            await loadModels()
            if !openAIKey.isEmpty { await loadOpenAIModels() }
        }
    }

    // MARK: - Model picker

    @ViewBuilder
    private func modelRow(_ m: TranscriptionModelInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: env.selectedModelId == m.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(env.selectedModelId == m.id ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayName)
                    if m.recommended {
                        Text("recommended")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(.capsule)
                    }
                }
                Text(ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if downloadingID == m.id {
                ProgressView().controlSize(.small)
                    .frame(width: 60)
            } else if m.isDownloaded {
                if env.selectedModelId == m.id {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use") { selectModel(m.id) }
                        .buttonStyle(.borderless)
                }
            } else {
                Button("Download") { Task { await downloadModel(m.id) } }
                    .disabled(downloadingID != nil)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if m.isDownloaded { selectModel(m.id) } }
    }

    private func selectModel(_ id: String) {
        env.selectedModelId = id
        UserDefaults.standard.set(id, forKey: "VibeMeetings.SelectedTranscriptionModelId")
    }

    private func loadModels() async {
        models = (try? await env.activeTranscriptionEngine.availableModels()) ?? []
    }

    private func downloadModel(_ id: String) async {
        downloadingID = id
        downloadError = nil
        defer { downloadingID = nil }
        do {
            try await env.activeTranscriptionEngine.loadModel(id: id) { _ in }
            await loadModels()
            // Auto-select if the user doesn't have a working model yet.
            let downloaded = models.filter(\.isDownloaded)
            if !downloaded.contains(where: { $0.id == env.selectedModelId }) {
                selectModel(id)
            }
        } catch {
            downloadError = error.localizedDescription
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

    // MARK: - OpenAI

    private func testAndSaveOpenAI() async {
        openAITesting = true
        openAITestResult = nil
        defer { openAITesting = false }

        let engine = OpenAIEngine(apiKey: openAIKey, promptBundle: .main)
        let health = await engine.isAvailable()
        switch health {
        case .ok:
            openAITestResult = "OK — connected to OpenAI"
            env.setOpenAI(apiKey: openAIKey, modelId: openAIModel.isEmpty ? "gpt-4o-mini" : openAIModel)
            await loadOpenAIModels()
        case .unreachable(let reason):
            openAITestResult = reason
        default:
            openAITestResult = "Connection failed"
        }
    }

    private func loadOpenAIModels() async {
        let engine = OpenAIEngine(apiKey: openAIKey, promptBundle: .main)
        openAIModels = (try? await engine.availableModels()) ?? []
        if !openAIModels.isEmpty && openAIModel.isEmpty {
            openAIModel = openAIModels.first(where: { $0.id.contains("gpt-4o-mini") })?.id
                          ?? openAIModels.first?.id ?? "gpt-4o-mini"
        }
    }
}

private struct PromptSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var promptText: String = ""
    @State private var showingDefault = false

    private static let defaultPrompt = PromptLoader.fallbackPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom System Prompt")
                .font(.headline)
            Text("Override the default instructions sent to the LLM when generating summaries. Leave blank to use the built-in prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $promptText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 240)

            HStack {
                Button("Reset to Default") {
                    promptText = ""
                    save()
                }
                .disabled(promptText.isEmpty)

                Button(showingDefault ? "Hide Default" : "Show Default") {
                    showingDefault.toggle()
                }

                Spacer()

                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(promptText == env.customSystemPrompt)
            }

            if showingDefault {
                GroupBox("Built-in prompt") {
                    ScrollView {
                        Text(Self.defaultPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .padding()
        .onAppear {
            promptText = env.customSystemPrompt
        }
    }

    private func save() {
        env.customSystemPrompt = promptText
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "VibeMeetings.CustomSystemPrompt")
        } else {
            UserDefaults.standard.set(promptText, forKey: "VibeMeetings.CustomSystemPrompt")
        }
    }
}


