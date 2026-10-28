import CryptoKit
import Foundation
import Security

/// A minimal OAuth 2.1 authorization server for the remote MCP endpoint, as
/// claude.ai's custom connectors expect: discovery metadata, dynamic client
/// registration, authorization code + PKCE (S256 only), refresh-token rotation.
///
/// Consent is a pairing code shown in the app: whoever completes the sign-in page
/// must be able to see the user's Mac. Only SHA-256 hashes of tokens are stored.
public actor OAuthServer {
    public struct ConnectedClient: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let connectedAt: Date
        public let lastUsedAt: Date?
    }

    static let scope = "meetings:read"
    static let accessTokenLifetime: TimeInterval = 60 * 60
    static let refreshTokenLifetime: TimeInterval = 90 * 24 * 60 * 60
    static let authCodeLifetime: TimeInterval = 5 * 60
    static let maxFailedAttempts = 5
    static let lockoutDuration: TimeInterval = 15 * 60
    /// Registered-but-never-authorised clients are dropped after this, so the
    /// public registration endpoint can't grow the state file without bound.
    static let unusedClientLifetime: TimeInterval = 24 * 60 * 60
    static let maxClients = 50

    private struct Client: Codable {
        var name: String
        var redirectURIs: [String]
        var createdAt: Date
        var authorizedAt: Date?
        var lastUsedAt: Date?
    }

    private enum TokenKind: String, Codable { case access, refresh }

    private struct Token: Codable {
        var clientID: String
        var kind: TokenKind
        var expiresAt: Date
    }

    private struct Persisted: Codable {
        var clients: [String: Client] = [:]
        /// Keyed by SHA-256 hex of the token.
        var tokens: [String: Token] = [:]
    }

    private struct AuthCode {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let expiresAt: Date
    }

    private let stateURL: URL?
    private let now: @Sendable () -> Date
    private var state = Persisted()
    private var authCodes: [String: AuthCode] = [:]  // keyed by hash
    private var failedAttempts = 0
    private var lockedUntil: Date?
    private var lastPersistedUse: [String: Date] = [:]
    private var onChange: (@Sendable () -> Void)?
    public private(set) var pairingCode: String

    /// `stateURL` nil keeps everything in memory (tests).
    public init(stateURL: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.stateURL = stateURL
        self.now = now
        self.pairingCode = Self.makePairingCode()
        if let stateURL, let data = try? Data(contentsOf: stateURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode(Persisted.self, from: data) { state = loaded }
        }
    }

    public func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange = handler
    }

    // MARK: - App-facing

    public func regeneratePairingCode() {
        pairingCode = Self.makePairingCode()
        failedAttempts = 0
        lockedUntil = nil
        onChange?()
    }

    public func connectedClients() -> [ConnectedClient] {
        let t = now()
        let live = Set(state.tokens.values.filter { $0.kind == .refresh && $0.expiresAt > t }.map(\.clientID))
        return state.clients
            .filter { live.contains($0.key) }
            .map { ConnectedClient(id: $0.key, name: $0.value.name, connectedAt: $0.value.authorizedAt ?? $0.value.createdAt, lastUsedAt: $0.value.lastUsedAt) }
            .sorted { $0.connectedAt > $1.connectedAt }
    }

    public func revoke(clientID: String) {
        state.clients[clientID] = nil
        state.tokens = state.tokens.filter { $0.value.clientID != clientID }
        persist()
    }

    public func revokeAll() {
        state = Persisted()
        authCodes = [:]
        persist()
    }

    // MARK: - Bearer check

    /// True if `authorization` is `Bearer <live access token>`.
    public func validate(authorization: String?) -> Bool {
        guard let authorization, authorization.lowercased().hasPrefix("bearer ") else { return false }
        let token = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        let t = now()
        guard let record = state.tokens[Self.hash(token)], record.kind == .access, record.expiresAt > t,
              state.clients[record.clientID] != nil else { return false }
        // Note use, but don't rewrite the file on every request.
        state.clients[record.clientID]?.lastUsedAt = t
        if (lastPersistedUse[record.clientID].map { t.timeIntervalSince($0) > 300 }) ?? true {
            lastPersistedUse[record.clientID] = t
            persist()
        }
        return true
    }

    // MARK: - HTTP

    /// Handles the OAuth endpoints; nil for any other path.
    public func handle(_ request: HTTPRequest, baseURL: String) -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"),
             ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return .json([
                "resource": .string(baseURL + "/mcp"),
                "authorization_servers": [.string(baseURL)],
                "scopes_supported": [.string(Self.scope)],
                "bearer_methods_supported": ["header"],
                "resource_name": "Vibe Meetings",
            ])
        case ("GET", "/.well-known/oauth-authorization-server"),
             ("GET", "/.well-known/oauth-authorization-server/mcp"):
            return .json([
                "issuer": .string(baseURL),
                "authorization_endpoint": .string(baseURL + "/authorize"),
                "token_endpoint": .string(baseURL + "/token"),
                "registration_endpoint": .string(baseURL + "/register"),
                "revocation_endpoint": .string(baseURL + "/revoke"),
                "scopes_supported": [.string(Self.scope)],
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
            ])
        case ("POST", "/register"):
            return register(request)
        case ("GET", "/authorize"):
            return authorizePage(request.query)
        case ("POST", "/authorize"):
            return authorizeSubmit(request.formFields)
        case ("POST", "/token"):
            return token(request.formFields)
        case ("POST", "/revoke"):
            if let token = request.formFields["token"] { state.tokens[Self.hash(token)] = nil; persist() }
            return HTTPResponse(status: 200)
        default:
            return nil
        }
    }

    // MARK: - Registration

    private func register(_ request: HTTPRequest) -> HTTPResponse {
        pruneStaleClients()
        guard let body = try? JSONValue.decode(request.body), case .array(let uris)? = body["redirect_uris"] else {
            return Self.oauthError("invalid_client_metadata", "redirect_uris is required.")
        }
        let redirectURIs = uris.compactMap(\.stringValue)
        guard !redirectURIs.isEmpty, redirectURIs.count == uris.count, redirectURIs.allSatisfy(Self.isAllowedRedirect) else {
            return Self.oauthError("invalid_redirect_uri", "Only Claude's callback and localhost redirect URIs are accepted.")
        }
        guard state.clients.count < Self.maxClients else {
            return Self.oauthError("invalid_client_metadata", "Too many registered clients. Disconnect some in Vibe Meetings → Settings → Claude.")
        }
        let name = String((body["client_name"]?.stringValue ?? "MCP client").prefix(80))
        let clientID = Self.randomToken(bytes: 16)
        state.clients[clientID] = Client(name: name, redirectURIs: redirectURIs, createdAt: now())
        persist()
        return .json([
            "client_id": .string(clientID),
            "client_id_issued_at": .int(Int(now().timeIntervalSince1970)),
            "client_name": .string(name),
            "redirect_uris": .array(redirectURIs.map { .string($0) }),
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": .string(Self.scope),
        ], status: 201)
    }

    static func isAllowedRedirect(_ uri: String) -> Bool {
        guard let url = URL(string: uri), let host = url.host?.lowercased(), url.fragment == nil else { return false }
        switch url.scheme?.lowercased() {
        case "https":
            return ["claude.ai", "claude.com"].contains(host) && url.path == "/api/mcp/auth_callback"
        case "http":
            return host == "localhost" || host == "127.0.0.1"
        default:
            return false
        }
    }

    // MARK: - Authorization

    private struct AuthorizeParams {
        let clientID: String
        let client: Client
        let redirectURI: String
        let codeChallenge: String
        let state: String?
    }

    /// Errors that can't safely go back to the redirect URI (unknown client or
    /// redirect) are shown on the page instead.
    private enum Validated {
        case ok(AuthorizeParams)
        case reject(HTTPResponse)
    }

    private func validateAuthorize(_ p: [String: String]) -> Validated {
        guard let clientID = p["client_id"], let client = state.clients[clientID] else {
            return .reject(Self.page(title: "Unknown app", body: "<p>This sign-in link isn't from an app registered with Vibe Meetings. Start connecting again from the app you're adding it to.</p>", status: 400))
        }
        guard let redirectURI = p["redirect_uri"], client.redirectURIs.contains(redirectURI) else {
            return .reject(Self.page(title: "Invalid sign-in link", body: "<p>The redirect address doesn't match the one this app registered.</p>", status: 400))
        }
        guard p["response_type"] == "code" else {
            return .reject(Self.redirect(redirectURI, ["error": "unsupported_response_type", "state": p["state"]]))
        }
        guard let challenge = p["code_challenge"], !challenge.isEmpty, p["code_challenge_method"] == "S256" else {
            return .reject(Self.redirect(redirectURI, ["error": "invalid_request", "error_description": "PKCE with S256 is required.", "state": p["state"]]))
        }
        return .ok(AuthorizeParams(clientID: clientID, client: client, redirectURI: redirectURI, codeChallenge: challenge, state: p["state"]))
    }

    private func authorizePage(_ query: [String: String], error: String? = nil) -> HTTPResponse {
        let params: AuthorizeParams
        switch validateAuthorize(query) {
        case .reject(let response): return response
        case .ok(let p): params = p
        }
        let host = URL(string: params.redirectURI)?.host ?? params.redirectURI
        let hidden = ["client_id", "redirect_uri", "response_type", "code_challenge", "code_challenge_method", "state", "scope", "resource"]
            .compactMap { key in query[key].map { "<input type=\"hidden\" name=\"\(key)\" value=\"\(Self.escape($0))\">" } }
            .joined(separator: "\n")
        var body = """
            <p><strong>\(Self.escape(params.client.name))</strong> is asking for <strong>read-only</strong> access to your meetings: titles, attendees, summaries, notes and transcripts. It can't change or delete anything.</p>
            <p class="muted">After you allow it, you'll be sent back to \(Self.escape(host)).</p>
            """
        if let error { body += "<p class=\"error\">\(Self.escape(error))</p>" }
        body += """
            <form method="post" action="/authorize">
            \(hidden)
            <label for="code">Pairing code from Vibe Meetings → Settings → Claude</label>
            <input id="code" name="pairing_code" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX" autofocus>
            <div class="buttons">
            <button type="submit" name="action" value="deny" class="secondary">Deny</button>
            <button type="submit" name="action" value="allow">Allow</button>
            </div>
            </form>
            """
        return Self.page(title: "Connect to Vibe Meetings", body: body)
    }

    private func authorizeSubmit(_ form: [String: String]) -> HTTPResponse {
        let params: AuthorizeParams
        switch validateAuthorize(form) {
        case .reject(let response): return response
        case .ok(let p): params = p
        }
        if form["action"] != "allow" {
            return Self.redirect(params.redirectURI, ["error": "access_denied", "state": params.state])
        }
        let t = now()
        if let lockedUntil, lockedUntil > t {
            let minutes = Int((lockedUntil.timeIntervalSince(t) / 60).rounded(.up))
            return authorizePage(form, error: "Too many wrong codes. Try again in \(minutes) minute\(minutes == 1 ? "" : "s"), or make a new code in the app.")
        }
        guard Self.constantTimeEqual(Self.normalize(form["pairing_code"] ?? ""), Self.normalize(pairingCode)) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts {
                lockedUntil = t.addingTimeInterval(Self.lockoutDuration)
                failedAttempts = 0
            }
            return authorizePage(form, error: "That code isn't right. Check Vibe Meetings → Settings → Claude.")
        }

        // A code works once: the next connection needs a fresh one.
        failedAttempts = 0
        pairingCode = Self.makePairingCode()
        let code = Self.randomToken(bytes: 32)
        authCodes = authCodes.filter { $0.value.expiresAt > t }
        authCodes[Self.hash(code)] = AuthCode(clientID: params.clientID, redirectURI: params.redirectURI,
                                              codeChallenge: params.codeChallenge, expiresAt: t.addingTimeInterval(Self.authCodeLifetime))
        onChange?()
        return Self.redirect(params.redirectURI, ["code": code, "state": params.state])
    }

    // MARK: - Token

    private func token(_ form: [String: String]) -> HTTPResponse {
        let t = now()
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let record = authCodes.removeValue(forKey: Self.hash(code)), record.expiresAt > t else {
                return Self.oauthError("invalid_grant", "The authorization code is invalid or expired.")
            }
            guard form["client_id"] == record.clientID, form["redirect_uri"] == record.redirectURI else {
                return Self.oauthError("invalid_grant", "client_id or redirect_uri doesn't match the authorization request.")
            }
            guard let verifier = form["code_verifier"], Self.pkceChallenge(verifier) == record.codeChallenge else {
                return Self.oauthError("invalid_grant", "PKCE verification failed.")
            }
            state.clients[record.clientID]?.authorizedAt = t
            return issueTokens(clientID: record.clientID)

        case "refresh_token":
            guard let refresh = form["refresh_token"], let record = state.tokens[Self.hash(refresh)],
                  record.kind == .refresh, record.expiresAt > t, state.clients[record.clientID] != nil else {
                return Self.oauthError("invalid_grant", "The refresh token is invalid or expired.")
            }
            if let clientID = form["client_id"], clientID != record.clientID {
                return Self.oauthError("invalid_grant", "client_id doesn't match the refresh token.")
            }
            state.tokens[Self.hash(refresh)] = nil  // rotate
            return issueTokens(clientID: record.clientID)

        default:
            return Self.oauthError("unsupported_grant_type", "Use authorization_code or refresh_token.")
        }
    }

    private func issueTokens(clientID: String) -> HTTPResponse {
        let t = now()
        state.tokens = state.tokens.filter { $0.value.expiresAt > t }
        let access = Self.randomToken(bytes: 32)
        let refresh = Self.randomToken(bytes: 32)
        state.tokens[Self.hash(access)] = Token(clientID: clientID, kind: .access, expiresAt: t.addingTimeInterval(Self.accessTokenLifetime))
        state.tokens[Self.hash(refresh)] = Token(clientID: clientID, kind: .refresh, expiresAt: t.addingTimeInterval(Self.refreshTokenLifetime))
        persist()
        return .json([
            "access_token": .string(access),
            "token_type": "Bearer",
            "expires_in": .int(Int(Self.accessTokenLifetime)),
            "refresh_token": .string(refresh),
            "scope": .string(Self.scope),
        ], headers: [("Cache-Control", "no-store"), ("Pragma", "no-cache")])
    }

    // MARK: - Persistence

    private func pruneStaleClients() {
        let t = now()
        let live = Set(state.tokens.values.filter { $0.expiresAt > t }.map(\.clientID))
        state.clients = state.clients.filter { id, client in
            live.contains(id) || t.timeIntervalSince(client.createdAt) < Self.unusedClientLifetime
        }
    }

    private func persist() {
        defer { onChange?() }
        guard let stateURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: stateURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    // MARK: - Helpers

    static func makePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")  // no 0/O, 1/I/L
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 256 % 31 bias is negligible next to the 5-attempt lockout.
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func pkceChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func oauthError(_ code: String, _ description: String, status: Int = 400) -> HTTPResponse {
        .json(["error": .string(code), "error_description": .string(description)], status: status,
              headers: [("Cache-Control", "no-store")])
    }

    static func redirect(_ base: String, _ params: [String: String?]) -> HTTPResponse {
        guard var components = URLComponents(string: base) else { return .text("Bad redirect", status: 400) }
        var items = components.queryItems ?? []
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            if let v { items.append(URLQueryItem(name: k, value: v)) }
        }
        components.queryItems = items
        // `+` survives URLComponents unencoded and would be read back as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return .redirect(components.string ?? base)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func page(title: String, body: String, status: Int = 200) -> HTTPResponse {
        .html("""
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(title))</title>
            <style>
            :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --accent: #d63a3a; --border: #d2d2d7; }
            @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #a1a1a6; --border: #48484a; } }
            body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
            main { max-width: 420px; margin: 10vh auto; padding: 28px; background: var(--card); border-radius: 14px; border: 1px solid var(--border); }
            @media (max-width: 480px) { main { margin: 16px; } }
            h1 { font-size: 21px; margin: 0 0 12px; }
            .muted { color: var(--muted); font-size: 14px; }
            .error { color: var(--accent); font-weight: 600; }
            label { display: block; margin: 20px 0 6px; font-size: 14px; color: var(--muted); }
            input[name=pairing_code] { width: 100%; box-sizing: border-box; padding: 10px 12px; font: 600 22px ui-monospace, Menlo, monospace; letter-spacing: 2px; text-align: center; border: 1px solid var(--border); border-radius: 8px; background: transparent; color: inherit; }
            .buttons { display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px; }
            button { font: inherit; padding: 8px 18px; border-radius: 8px; border: 0; background: var(--accent); color: #fff; cursor: pointer; }
            button.secondary { background: transparent; color: var(--text); border: 1px solid var(--border); }
            </style></head>
            <body><main><h1>\(escape(title))</h1>
            \(body)
            </main></body></html>
            """, status: status)
    }
}
