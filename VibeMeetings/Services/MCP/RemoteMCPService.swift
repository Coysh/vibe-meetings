import Foundation
import Observation
import VMMCP

/// Remote access to the library for claude.ai: runs the MCP-over-HTTP server
/// (with its OAuth sign-in) on 127.0.0.1 while the app is open. Off by default;
/// the user puts a tunnel (cloudflared) in front of it to reach it from Claude.
@Observable
@MainActor
final class RemoteMCPService {
    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    static let defaultPort: UInt16 = 47821
    private static let enabledKey = "VibeMeetings.RemoteMCP.Enabled"
    private static let portKey = "VibeMeetings.RemoteMCP.Port"
    private static let publicURLKey = "VibeMeetings.RemoteMCP.PublicURL"

    private(set) var status: Status = .off
    private(set) var isEnabled: Bool
    private(set) var port: UInt16
    private(set) var publicURL: String
    private(set) var pairingCode = ""
    private(set) var clients: [OAuthServer.ConnectedClient] = []

    /// One for the app's lifetime, so the pairing code and sign-ins survive restarts of the listener.
    @ObservationIgnored let oauth: OAuthServer
    @ObservationIgnored private var server: RemoteMCPServer?
    @ObservationIgnored private var rootURL: URL
    /// Ignores state callbacks from a listener that has since been replaced.
    @ObservationIgnored private var generation = 0

    /// `<public URL>/mcp`, the address to add as a custom connector.
    var connectorURL: String? {
        RemoteMCPServer.normalizeBaseURL(publicURL).map { $0 + "/mcp" }
    }

    init(rootURL: URL) {
        let defaults = UserDefaults.standard
        self.rootURL = rootURL
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedPort = defaults.integer(forKey: Self.portKey)
        self.port = (1024...65535).contains(storedPort) ? UInt16(storedPort) : Self.defaultPort
        self.publicURL = defaults.string(forKey: Self.publicURLKey) ?? ""

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.oauth = OAuthServer(stateURL: support.appendingPathComponent("vibe-meetings/mcp-oauth.json"))
        Task { [weak self] in await self?.observeOAuth() }
    }

    /// Keeps the pairing code and the connected list current as people sign in.
    private func observeOAuth() async {
        await oauth.setOnChange { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        await refresh()
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort >= 1024 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        if isEnabled { start() }
    }

    func setPublicURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != publicURL else { return }
        publicURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.publicURLKey)
        if isEnabled { start() }
    }

    /// The library moved: serve the new folder.
    func setRoot(_ url: URL) {
        rootURL = url
        if isEnabled { start() }
    }

    func regeneratePairingCode() {
        Task { await oauth.regeneratePairingCode() }
    }

    func revoke(_ client: OAuthServer.ConnectedClient) {
        Task { await oauth.revoke(clientID: client.id) }
    }

    func revokeAll() {
        Task { await oauth.revokeAll() }
    }

    func refresh() async {
        pairingCode = await oauth.pairingCode
        clients = await oauth.connectedClients()
    }

    private func start() {
        server?.stop()
        server = nil
        generation += 1
        let current = generation
        status = .starting

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let base = RemoteMCPServer.normalizeBaseURL(publicURL)
        do {
            let server = try RemoteMCPServer(library: MeetingLibrary(root: rootURL), serverVersion: version,
                                             port: port, publicBaseURL: base, oauth: oauth)
            self.server = server
            server.start { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .starting: self.status = .starting
                    case .ready(let port): self.status = .running(port: port)
                    case .failed(let message): self.status = .failed(message)
                    case .stopped: self.status = .off
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        generation += 1
        server?.stop()
        server = nil
        status = .off
    }
}
