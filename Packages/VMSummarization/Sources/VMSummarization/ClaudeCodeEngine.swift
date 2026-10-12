import Foundation
import VMCore
import os

// MARK: - The CLI

/// Finding, checking and running the user's own Claude Code command-line tool.
///
/// Everything here is `claude -p` (print mode): a one-shot, non-interactive run
/// that streams JSON events. It uses whatever the user is already signed in with
/// (a Claude subscription or an API key), so Vibe Meetings never handles a key.
public enum ClaudeCodeCLI {
    public enum Status: Sendable, Equatable {
        /// Installed and signed in. `account` is a short description ("Claude Max").
        case ready(path: String, version: String, account: String)
        case notInstalled
        case notSignedIn(path: String)
        case failed(String)
    }

    // MARK: Locating

    /// A GUI app doesn't get the PATH from the user's shell, so look where the
    /// installer and the common package managers put it, then ask a login shell.
    public static func locate() -> URL? {
        let fileManager = FileManager.default
        if let cached = cachedLocation.withLock({ $0 }), fileManager.isExecutableFile(atPath: cached.path) {
            return cached
        }
        let found = candidatePaths().first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
            ?? loginShellLookup()
        cachedLocation.withLock { $0 = found }
        return found
    }

    /// Forget the remembered location (after the user installs or moves the CLI).
    public static func forgetLocation() {
        cachedLocation.withLock { $0 = nil }
    }

    private static let cachedLocation = OSAllocatedUnfairLock<URL?>(initialState: nil)

    private static func candidatePaths() -> [String] {
        let home = NSHomeDirectory()
        var paths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted(by: >).map { "\(nvm)/\($0)/bin/claude" }
        }
        return paths
    }

    /// `zsh -l -c 'command -v claude'`: the login shell reads the profile, where PATH tweaks usually live.
    private static func loginShellLookup() -> URL? {
        guard let output = capture("/bin/zsh", ["-l", "-c", "command -v claude"], timeout: 6),
              output.status == 0 else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Status

    /// Is the CLI installed and signed in? No model call is made (`claude auth status` is free).
    public static func status() async -> Status {
        await Task.detached(priority: .utility) { () -> Status in
            guard let executable = locate() else { return .notInstalled }
            guard let version = capture(executable.path, ["--version"], timeout: 15, environment: environment(for: executable)),
                  version.status == 0 else {
                return .failed("Found Claude Code at \(executable.path), but it didn't run.")
            }
            let versionText = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first ?? "unknown"

            guard let auth = capture(executable.path, ["auth", "status"], timeout: 15, environment: environment(for: executable)),
                  let data = auth.stdout.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failed("Couldn't read Claude Code's sign-in status.")
            }
            guard (json["loggedIn"] as? Bool) == true else { return .notSignedIn(path: executable.path) }
            return .ready(path: executable.path, version: versionText, account: describeAccount(json))
        }.value
    }

    private static func describeAccount(_ json: [String: Any]) -> String {
        if let method = json["authMethod"] as? String, method == "claude.ai" {
            let plan = (json["subscriptionType"] as? String).map { " " + $0.capitalized } ?? ""
            return "Claude" + plan
        }
        if let provider = json["apiProvider"] as? String, provider != "firstParty" { return provider.capitalized }
        return "Anthropic API"
    }

    // MARK: Environment

    /// The CLI's own folder first on PATH (an npm install's `claude` is a script that needs `node` beside it),
    /// then the usual places. Marks the run as non-interactive and drops variables that would make it
    /// think it's nested inside another Claude Code session.
    static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            executable.deletingLastPathComponent().path,
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// An empty folder to run summaries in, so the CLI never picks up a project's `CLAUDE.md` or files.
    static func scratchDirectory() -> URL {
        let url = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("VibeMeetings", isDirectory: true)
            .appendingPathComponent("claude-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Small synchronous runs

    struct Captured {
        let status: Int32
        let stdout: String
    }

    /// Run a short command to completion (version, auth status, shell lookup). Output is small, so reading
    /// after exit can't fill a pipe. Killed after `timeout` seconds.
    static func capture(_ path: String, _ arguments: [String], timeout: TimeInterval, environment: [String: String]? = nil) -> Captured? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.currentDirectoryURL = scratchDirectory()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        return Captured(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Events from the CLI

/// What `claude -p --output-format stream-json` tells us, reduced to what we use.
enum ClaudeCodeEvent: Sendable {
    case text(String)
    case toolUse(name: String, path: String?, pattern: String?)
    case result(isError: Bool, text: String)
}

enum ClaudeCodeParser {
    static func events(from line: String) -> [ClaudeCodeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "stream_event":
            // Only the main conversation's words (not a sub-agent's).
            guard !(object["parent_tool_use_id"] is String),
                  let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block -> ClaudeCodeEvent? in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                let path = (input["file_path"] as? String) ?? (input["path"] as? String)
                return .toolUse(name: name, path: path, pattern: input["pattern"] as? String)
            }

        case "result":
            return [.result(isError: (object["is_error"] as? Bool) ?? false, text: (object["result"] as? String) ?? "")]

        default:
            return []
        }
    }
}

// MARK: - Running it

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum ClaudeCodeRunner {
    /// Start `claude` with `arguments`, feed it `stdin`, and stream its events. Cancelling the consumer
    /// (or finishing early) stops the process. A non-zero exit with no `result` event throws the CLI's stderr.
    static func run(
        executable: URL,
        arguments: [String],
        stdin: Data,
        workingDirectory: URL
    ) -> AsyncThrowingStream<ClaudeCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let process = box.process
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = ClaudeCodeCLI.environment(for: executable)

            let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Keep the tail of stderr for error messages.
            let stderrTail = OSAllocatedUnfairLock(initialState: Data())
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                stderrTail.withLock { data in
                    data.append(chunk)
                    if data.count > 8192 { data.removeFirst(data.count - 8192) }
                }
            }

            let (exitCodes, exitContinuation) = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { finished in
                exitContinuation.yield(finished.terminationStatus)
                exitContinuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: SummarizationEngineError.requestFailed("Couldn't start Claude Code: \(error.localizedDescription)"))
                return
            }

            // The prompt goes in on stdin (a long transcript won't fit in an argument). Written off the
            // cooperative pool; a CLI that quits early can't crash us with SIGPIPE.
            let writer = stdinPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }

            let reader = stdoutPipe.fileHandleForReading
            let task = Task {
                var sawResult = false
                do {
                    for try await line in reader.bytes.lines {
                        for event in ClaudeCodeParser.events(from: line) {
                            if case .result = event { sawResult = true }
                            continuation.yield(event)
                        }
                    }
                    var status: Int32 = 0
                    for await code in exitCodes { status = code }
                    if status != 0 && !sawResult {
                        let tail = String(decoding: stderrTail.withLock { $0 }, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.finish(throwing: SummarizationEngineError.requestFailed(
                            tail.isEmpty ? "Claude Code stopped unexpectedly (exit \(status))." : tail
                        ))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.terminate()
            }
        }
    }
}

// MARK: - The engine

/// What Claude is doing while it answers a question about the whole library.
public enum ClaudeCodeChatEvent: Sendable {
    case text(String)
    /// A tool call: a short phrase for the UI ("Reading Acme/Kickoff/summary.md") and the file, if any.
    case activity(description: String, path: String?)
}

/// `SummarizationEngine` backed by the user's Claude Code CLI.
///
/// - `summarize` is a plain completion: no tools, no files, no session — the transcript goes in and the
///   write-up comes out, exactly like the Ollama and OpenAI engines.
/// - `ask` is for chat across the whole library: Claude can search and read the meeting files itself,
///   read-only and only inside the folder you give it.
public final class ClaudeCodeEngine: SummarizationEngine, @unchecked Sendable {
    public static let kind = "claude-code"
    public let displayName = "Claude Code (cloud)"

    public static let defaultModelId = "sonnet"
    /// Aliases the CLI resolves to the latest model of each kind.
    public static let models: [SummarizationModelInfo] = [
        SummarizationModelInfo(id: "sonnet", displayName: "Sonnet — balanced"),
        SummarizationModelInfo(id: "opus", displayName: "Opus — most capable"),
        SummarizationModelInfo(id: "fable", displayName: "Fable"),
        SummarizationModelInfo(id: "haiku", displayName: "Haiku — fastest"),
    ]

    private let promptBundle: Bundle?
    /// How hard the model thinks before answering ("low" … "max"); nil leaves the CLI's default.
    private let effort: String?

    public init(promptBundle: Bundle? = nil, effort: String? = "medium") {
        self.promptBundle = promptBundle
        self.effort = effort
    }

    public func isAvailable() async -> EngineHealth {
        switch await ClaudeCodeCLI.status() {
        case .ready(_, let version, _): return .ok(version: version)
        case .notInstalled: return .notRunning
        case .notSignedIn: return .unreachable("Claude Code isn't signed in. Run `claude auth login` in Terminal.")
        case .failed(let message): return .unreachable(message)
        }
    }

    public func availableModels() async throws -> [SummarizationModelInfo] {
        Self.models
    }

    // MARK: Summaries and templates

    public func summarize(
        transcript: [TranscriptSegment],
        meeting: Meeting,
        modelId: String,
        style: SummaryStyle,
        userNotes: String? = nil,
        customPrompt: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let executable = ClaudeCodeCLI.locate() else { throw Self.notInstalled }
                    let speakerNames = Dictionary(meeting.participants.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
                    let body = PromptLoader.renderTranscript(transcript, speakerNames: speakerNames, meeting: meeting, userNotes: userNotes)
                    let system = PromptLoader.systemPrompt(style: style, bundle: self.promptBundle, customPrompt: customPrompt)

                    let arguments = self.arguments(modelId: modelId, systemPrompt: system, tools: [], allowedTools: [], budgetUSD: nil)
                    var sawText = false
                    var failure: String?
                    for try await event in ClaudeCodeRunner.run(
                        executable: executable,
                        arguments: arguments,
                        stdin: Data(body.utf8),
                        workingDirectory: ClaudeCodeCLI.scratchDirectory()
                    ) {
                        switch event {
                        case .text(let text):
                            sawText = true
                            continuation.yield(text)
                        case .result(let isError, let text):
                            if isError { failure = text } else if !sawText, !text.isEmpty { continuation.yield(text) }
                        case .toolUse:
                            break
                        }
                    }
                    if let failure { throw SummarizationEngineError.requestFailed(failure) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Chat across the library

    /// Answer `prompt` using the meeting files under `folder`. Claude gets three read-only tools
    /// (Read, Grep, Glob), each limited to `folder`; it can't run commands, write, or reach the web.
    /// Pass a single meeting's folder to keep a conversation about just that meeting.
    public func ask(
        prompt: String,
        systemPrompt: String,
        modelId: String,
        folder: URL,
        budgetUSD: Double = 2
    ) -> AsyncThrowingStream<ClaudeCodeChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let executable = ClaudeCodeCLI.locate() else { throw Self.notInstalled }
                    let arguments = self.arguments(
                        modelId: modelId,
                        systemPrompt: systemPrompt,
                        tools: ["Read", "Grep", "Glob"],
                        // Relative to the working directory, which is `folder`: reads anywhere else are refused.
                        allowedTools: ["Read(./**)"],
                        budgetUSD: budgetUSD
                    )
                    var sawText = false
                    var failure: String?
                    for try await event in ClaudeCodeRunner.run(
                        executable: executable,
                        arguments: arguments,
                        stdin: Data(prompt.utf8),
                        workingDirectory: folder
                    ) {
                        switch event {
                        case .text(let text):
                            sawText = true
                            continuation.yield(.text(text))
                        case .toolUse(let name, let path, let pattern):
                            continuation.yield(.activity(description: Self.describe(tool: name, path: path, pattern: pattern, root: folder), path: path))
                        case .result(let isError, let text):
                            if isError { failure = text } else if !sawText, !text.isEmpty { continuation.yield(.text(text)) }
                        }
                    }
                    if let failure { throw SummarizationEngineError.requestFailed(failure) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    private static let notInstalled = SummarizationEngineError.requestFailed(
        "Claude Code isn't installed. Install it from claude.com/claude-code, then try again."
    )

    /// Print mode with everything optional turned off: no saved session, skills, MCP servers, hooks or
    /// settings from the user's setup; only the tools we name. (`--bare` would be tidier, but it also
    /// turns off the subscription sign-in.)
    private func arguments(modelId: String, systemPrompt: String, tools: [String], allowedTools: [String], budgetUSD: Double?) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
            "--setting-sources", "",
            "--system-prompt", systemPrompt,
            "--tools", tools.joined(separator: ","),
        ]
        if !modelId.isEmpty { arguments += ["--model", modelId] }
        if let effort { arguments += ["--effort", effort] }
        if !allowedTools.isEmpty {
            arguments += ["--allowedTools", allowedTools.joined(separator: ",")]
            arguments += ["--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"]
        }
        if let budgetUSD { arguments += ["--max-budget-usd", String(budgetUSD)] }
        return arguments
    }

    private static func describe(tool: String, path: String?, pattern: String?, root: URL) -> String {
        switch tool {
        case "Read":
            guard let path else { return "Reading a meeting" }
            return "Reading " + relative(path, to: root)
        case "Grep":
            return "Searching for “\(pattern ?? "")”"
        case "Glob":
            return "Looking through your meetings"
        default:
            return "Working…"
        }
    }

    /// "Acme/2026-10-01 Kickoff/summary.md" rather than the whole path.
    private static func relative(_ path: String, to root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved.hasPrefix(rootPath + "/") { return String(resolved.dropFirst(rootPath.count + 1)) }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
