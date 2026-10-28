import SwiftUI
import VMMCP

/// "Claude" tab: connect Claude to the library through the app's read-only MCP
/// server — locally (`vibe-meetings --mcp`, for Claude Desktop / Claude Code) or
/// remotely over a tunnel (for claude.ai).
struct ConnectionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var copied: String?
    @State private var portText = ""
    @State private var publicURLText = ""

    /// The binary inside the installed bundle. A Debug build points at DerivedData,
    /// so connect from the copy in /Applications for anything long-lived.
    private var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/vibe-meetings.app/Contents/MacOS/vibe-meetings"
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user vibe-meetings -- \"\(executablePath)\" --mcp"
    }

    private var desktopConfig: String {
        """
        "vibe-meetings": {
          "command": "\(executablePath)",
          "args": ["--mcp"]
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Text("Vibe Meetings includes an MCP server that lets Claude list, search and read your meetings: titles, attendees, summaries, notes and transcripts. It is read-only: Claude can't change, delete or record anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Library") {
                    Text(env.rootURL.path).truncationMode(.middle)
                }
            } header: {
                Text("Connect Claude to your meetings")
            }

            Section {
                snippet(claudeCodeCommand, id: "code")
                Text("Run this in Terminal once. Claude Code can then use your meetings in every project. It reads the library folder directly, so it works whether or not this app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude Code")
            }

            Section {
                snippet(desktopConfig, id: "desktop")
                Text("In Claude Desktop, open Settings → Developer → Edit Config, add this inside \"mcpServers\" in claude_desktop_config.json, then restart Claude Desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude Desktop")
            }

            remoteSections
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(env.remoteMCP.port)
            publicURLText = env.remoteMCP.publicURL
            Task { await env.remoteMCP.refresh() }
        }
    }

    // MARK: - Remote (claude.ai)

    @ViewBuilder
    private var remoteSections: some View {
        let remote = env.remoteMCP
        Section {
            Toggle("Allow Claude on the web and mobile to connect", isOn: Binding(
                get: { remote.isEnabled },
                set: { remote.setEnabled($0) }
            ))
            LabeledContent("Status") { statusLabel(remote.status) }
            Text("claude.ai can't reach your Mac directly. Turning this on starts a server on this Mac only (127.0.0.1); you then run a Cloudflare Tunnel to give it a public https address. Anyone who reaches that address still has to sign in with a pairing code shown here. It only works while this app is open and your Mac is awake.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("claude.ai (remote)")
        }

        if remote.isEnabled {
            Section {
                LabeledContent("Local port") {
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { applyPort() }
                }
                snippet("cloudflared tunnel --url http://127.0.0.1:\(remote.port)", id: "tunnel")
                Text("Quickest: install cloudflared (`brew install cloudflared`) and run this. It prints a https://….trycloudflare.com address, which changes every time it runs. For an address that stays put, set up a named tunnel on your own domain pointing at the same local URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Public address", text: $publicURLText, prompt: Text("https://meetings.example.com"))
                    .onSubmit { remote.setPublicURL(publicURLText) }
                    .onChange(of: publicURLText) { _, value in
                        if value.isEmpty { remote.setPublicURL("") }
                    }
                if let connector = remote.connectorURL {
                    snippet(connector, id: "connector")
                    Text("In claude.ai, open Settings → Connectors → Add custom connector and paste this. Leave the advanced OAuth fields empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Paste the tunnel's address above (press Return) to get the connector URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tunnel")
            }

            Section {
                HStack {
                    Text(remote.pairingCode)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    Button("New Code") { remote.regeneratePairingCode() }
                }
                Text("When Claude opens the Vibe Meetings sign-in page, type this code there. Each code works once; five wrong guesses lock sign-in for 15 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pairing code")
            }

            Section {
                if remote.clients.isEmpty {
                    Text("Nothing is connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remote.clients) { client in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(client.name)
                                Text(clientDetail(client))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { remote.revoke(client) }
                        }
                    }
                    Button("Disconnect All", role: .destructive) { remote.revokeAll() }
                }
            } header: {
                Text("Connected")
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: RemoteMCPService.Status) -> some View {
        switch status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .running(let port): Text("Listening on 127.0.0.1:\(String(port))")
        case .failed(let message): Text("Couldn't start: \(message)").foregroundStyle(.red)
        }
    }

    private func clientDetail(_ client: OAuthServer.ConnectedClient) -> String {
        var text = "Connected \(client.connectedAt.formatted(date: .abbreviated, time: .shortened))"
        if let used = client.lastUsedAt {
            text += " · last used \(used.formatted(.relative(presentation: .named)))"
        }
        return text
    }

    private func applyPort() {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value >= 1024 else {
            portText = String(env.remoteMCP.port)
            return
        }
        env.remoteMCP.setPort(value)
    }

    private func snippet(_ text: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = id
            }
        }
    }
}
