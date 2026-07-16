import ServiceManagement
import SwiftUI
import UserNotifications
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
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
            PromptSettingsView().tabItem { Label("Prompts", systemImage: "text.quote") }
        }
        .frame(width: 560, height: 540)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var inputDevices: [AudioInputDevice] = AudioDeviceEnumerator.inputDevices()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var newOrgName: String = ""

    /// Binding that maps `nil` (system default) ↔ empty string for the Picker.
    private var micSelection: Binding<String> {
        Binding(
            get: { env.selectedMicDeviceUID ?? "" },
            set: { env.setMicDevice(uid: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("[Settings] Launch at login error: \(error)")
                        // Revert toggle on failure.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

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

            Section("Auto-End Detection") {
                Toggle("Enable auto-end detection", isOn: Binding(
                    get: { env.meetingEndDetector.autoEndEnabled },
                    set: { env.meetingEndDetector.autoEndEnabled = $0 }
                ))

                if env.meetingEndDetector.autoEndEnabled {
                    LabeledContent("Silence threshold") {
                        Picker("", selection: Binding(
                            get: { env.meetingEndDetector.silenceThresholdSeconds },
                            set: { env.meetingEndDetector.silenceThresholdSeconds = $0 }
                        )) {
                            Text("1 minute").tag(TimeInterval(60))
                            Text("2 minutes").tag(TimeInterval(120))
                            Text("3 minutes").tag(TimeInterval(180))
                            Text("5 minutes").tag(TimeInterval(300))
                        }
                        .frame(width: 150)
                    }

                    Toggle("Monitor meeting apps (Teams, Zoom)", isOn: Binding(
                        get: { env.meetingEndDetector.appMonitoringEnabled },
                        set: { env.meetingEndDetector.appMonitoringEnabled = $0 }
                    ))

                    Text("Suggests stopping the recording when the scheduled end time passes, audio goes silent, or the meeting app exits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Notify if microphone picks up no audio", isOn: Binding(
                    get: { env.meetingEndDetector.micSilenceNotificationEnabled },
                    set: { env.meetingEndDetector.micSilenceNotificationEnabled = $0 }
                ))

                Text("Sends a system notification if your mic appears dead (muted, wrong device, permission issue) even while the rest of the call is still audible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Organizations") {
                ForEach(env.configuredOrgs, id: \.self) { org in
                    HStack {
                        Text(org)
                        Spacer()
                        Button {
                            var orgs = env.configuredOrgs
                            orgs.removeAll { $0 == org }
                            env.setConfiguredOrgs(orgs)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("New organization", text: $newOrgName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let name = newOrgName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        var orgs = env.configuredOrgs
                        if !orgs.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                            orgs.append(name)
                            env.setConfiguredOrgs(orgs)
                        }
                        newOrgName = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newOrgName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Organizations available in the meeting metadata picker. The first org is used as the default for new meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack {
                    Button("Check for Updates") {
                        env.sparkleUpdater.checkForUpdates()
                    }
                    .disabled(!env.sparkleUpdater.canCheckForUpdates)
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { env.sparkleUpdater.automaticallyChecksForUpdates },
                    set: { env.sparkleUpdater.automaticallyChecksForUpdates = $0 }
                ))

                Text("Updates are delivered via Sparkle and checked securely against the appcast feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @State private var ollamaModels: [SummarizationModelInfo] = []
    @State private var ollamaModelsLoading: Bool = false

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

                if ollamaModelsLoading {
                    HStack {
                        Text("Default model")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                } else if !ollamaModels.isEmpty {
                    Picker("Default model", selection: Binding(
                        get: { env.selectedOllamaModelId },
                        set: {
                            env.selectedOllamaModelId = $0
                            UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedOllamaModelId")
                        }
                    )) {
                        ForEach(ollamaModels) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    }
                    .help("Used for both summaries and chat")
                } else {
                    TextField("Default model", text: Binding(
                        get: { env.selectedOllamaModelId },
                        set: {
                            env.selectedOllamaModelId = $0
                            UserDefaults.standard.set($0, forKey: "VibeMeetings.SelectedOllamaModelId")
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Enter model name (e.g. llama3.1:8b-instruct-q4_K_M)")
                }
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
            await loadOllamaModels()
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

    private func loadOllamaModels() async {
        ollamaModelsLoading = true
        defer { ollamaModelsLoading = false }
        let engine = OllamaEngine(baseURL: env.ollamaBaseURL, promptBundle: .main)
        ollamaModels = (try? await engine.availableModels()) ?? []
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
        Task { await loadOllamaModels() }
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

private struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var env = env
        Form {
            Section {
                if authorizationStatus == .denied {
                    Label("Notifications are disabled in System Settings. Enable them to receive alerts from vibe-meetings.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else if authorizationStatus == .notDetermined {
                    Button("Enable Notifications") {
                        Task {
                            let center = UNUserNotificationCenter.current()
                            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                            await refreshAuthStatus()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Grant notification permission so vibe-meetings can alert you about meetings and completed summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Notifications are enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Permission")
            }

            Section {
                Toggle("Meeting / call detected", isOn: $env.notifyMeetingDetected)
                Text("Alert when a meeting app and microphone are active together, or a calendar event is starting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Pre-meeting reminder", isOn: $env.notifyPreMeetingReminder)

                if env.notifyPreMeetingReminder {
                    Picker("Remind me", selection: $env.notifyReminderMinutes) {
                        Text("1 minute before").tag(1)
                        Text("3 minutes before").tag(3)
                        Text("5 minutes before").tag(5)
                        Text("10 minutes before").tag(10)
                    }
                }

                Text("Sends a reminder before calendar events with an option to start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Summary ready", isOn: $env.notifySummaryReady)
                Text("Alert when an AI summary finishes generating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Notification Types")
            }

            Section {
                Button("Send Test Notification") {
                    Task { await sendTestNotification() }
                }
                .disabled(authorizationStatus != .authorized)

                Text("Sends a sample notification so you can verify your system notification settings are working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Test")
            }
        }
        .padding()
        .task { await refreshAuthStatus() }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    private func sendTestNotification() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            await refreshAuthStatus()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "vibe-meetings"
        content.body = "Notifications are working! You'll see alerts for meetings and summaries."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "test-notification-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

private struct PromptSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var promptText: String = ""
    @State private var chatPromptText: String = ""
    @State private var showingDefault = false
    @State private var selectedTab = 0

    private static let defaultPrompt = PromptLoader.fallbackPrompt

    private static let defaultChatPrompt: String = {
        if let url = Bundle.main.url(forResource: "chat.system", withExtension: "md", subdirectory: "Prompts"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return "You are a meeting assistant. Answer the user's question based ONLY on the meeting context provided. Reference which meeting(s) your answer comes from by name. Use Markdown formatting."
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedTab) {
                Text("Summary Prompt").tag(0)
                Text("Chat Prompt").tag(1)
            }
            .pickerStyle(.segmented)

            if selectedTab == 0 {
                summaryPromptEditor
            } else {
                chatPromptEditor
            }
        }
        .padding()
        .onAppear {
            promptText = env.customSystemPrompt
            chatPromptText = UserDefaults.standard.string(forKey: "VibeMeetings.ChatCustomPrompt") ?? ""
        }
    }

    @ViewBuilder
    private var summaryPromptEditor: some View {
        Text("Override the default instructions sent to the LLM when generating summaries. Leave blank to use the built-in prompt.")
            .font(.caption)
            .foregroundStyle(.secondary)

        TextEditor(text: $promptText)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 200)

        HStack {
            Button("Reset to Default") {
                promptText = ""
                saveSummaryPrompt()
            }
            .disabled(promptText.isEmpty)

            Button(showingDefault ? "Hide Default" : "Show Default") {
                showingDefault.toggle()
            }

            Spacer()

            Button("Save") { saveSummaryPrompt() }
                .buttonStyle(.borderedProminent)
                .disabled(promptText == env.customSystemPrompt)
        }

        if showingDefault {
            GroupBox("Built-in summary prompt") {
                ScrollView {
                    Text(Self.defaultPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    @ViewBuilder
    private var chatPromptEditor: some View {
        Text("Override the system prompt used in the Chat to Meetings panel. Leave blank to use the built-in prompt.")
            .font(.caption)
            .foregroundStyle(.secondary)

        TextEditor(text: $chatPromptText)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 200)

        HStack {
            Button("Reset to Default") {
                chatPromptText = ""
                saveChatPrompt()
            }
            .disabled(chatPromptText.isEmpty)

            Button(showingDefault ? "Hide Default" : "Show Default") {
                showingDefault.toggle()
            }

            Spacer()

            Button("Save") { saveChatPrompt() }
                .buttonStyle(.borderedProminent)
                .disabled(chatPromptText == (UserDefaults.standard.string(forKey: "VibeMeetings.ChatCustomPrompt") ?? ""))
        }

        if showingDefault {
            GroupBox("Built-in chat prompt") {
                ScrollView {
                    Text(Self.defaultChatPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func saveSummaryPrompt() {
        env.customSystemPrompt = promptText
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "VibeMeetings.CustomSystemPrompt")
        } else {
            UserDefaults.standard.set(promptText, forKey: "VibeMeetings.CustomSystemPrompt")
        }
    }

    private func saveChatPrompt() {
        let trimmed = chatPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "VibeMeetings.ChatCustomPrompt")
        } else {
            UserDefaults.standard.set(chatPromptText, forKey: "VibeMeetings.ChatCustomPrompt")
        }
    }
}


