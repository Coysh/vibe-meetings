import Foundation

/// MCP over Streamable HTTP (stateless JSON responses, no SSE) behind OAuth, for
/// claude.ai custom connectors. Listens on 127.0.0.1; a tunnel such as cloudflared
/// makes it reachable at the public URL.
public final class RemoteMCPServer: Sendable {
    public let oauth: OAuthServer
    private let mcp: MCPServer
    private let publicBaseURL: String?
    private let http: HTTPServer

    /// `publicBaseURL` (e.g. `https://meetings.example.com`) is the address clients
    /// use. When nil it is taken from each request's forwarded host headers.
    public init(library: MeetingLibrary, serverVersion: String, port: UInt16, publicBaseURL: String?, oauth: OAuthServer) throws {
        let mcp = MCPServer(library: library, serverVersion: serverVersion)
        let base = publicBaseURL.flatMap(Self.normalizeBaseURL)
        self.mcp = mcp
        self.oauth = oauth
        self.publicBaseURL = base
        self.http = try HTTPServer(port: port) { request in
            await Self.route(request, mcp: mcp, oauth: oauth, configuredBase: base)
        }
    }

    public func start(onState: @escaping @Sendable (HTTPServer.State) -> Void) {
        http.start(onState: onState)
    }

    public func stop() {
        http.stop()
    }

    /// "https://host/" or "host" → "https://host"; nil if it isn't a usable URL.
    public static func normalizeBaseURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/mcp") { s.removeLast(4) }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return s
    }

    static func route(_ request: HTTPRequest, mcp: MCPServer, oauth: OAuthServer, configuredBase: String?) async -> HTTPResponse {
        let base = configuredBase ?? derivedBase(request)

        // Browsers only: claude.ai's backend calls without an Origin header.
        if let origin = request.headers["origin"], !isAllowedOrigin(origin, base: base) {
            return .text("Forbidden origin", status: 403)
        }

        if let response = await oauth.handle(request, baseURL: base) {
            return response
        }

        switch (request.method, request.path) {
        case ("POST", "/mcp"):
            guard await oauth.validate(authorization: request.headers["authorization"]) else {
                let error = request.headers["authorization"] == nil ? "" : "error=\"invalid_token\", "
                return HTTPResponse(status: 401, headers: [
                    ("WWW-Authenticate", "Bearer \(error)resource_metadata=\"\(base)/.well-known/oauth-protected-resource\""),
                    ("Content-Type", "application/json"),
                ], body: Data(#"{"error":"unauthorized"}"#.utf8))
            }
            guard let response = mcp.handle(request.body) else {
                return HTTPResponse(status: 202)  // notifications only
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: response)
        case (_, "/mcp"):
            // No server-initiated stream and no sessions to end.
            return HTTPResponse(status: 405, headers: [("Allow", "POST")])
        case ("GET", "/"):
            return .text("Vibe Meetings MCP server. Add \(base)/mcp as a custom connector in Claude.")
        default:
            return .text("Not found", status: 404)
        }
    }

    static func derivedBase(_ request: HTTPRequest) -> String {
        let host = request.headers["x-forwarded-host"]?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? request.headers["host"] ?? "127.0.0.1"
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
        let proto = request.headers["x-forwarded-proto"]?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? (local ? "http" : "https")
        return "\(proto)://\(host)"
    }

    static func isAllowedOrigin(_ origin: String, base: String) -> Bool {
        let allowed = ["https://claude.ai", "https://claude.com", "https://www.claude.ai", base.lowercased()]
        let o = origin.lowercased()
        return allowed.contains(o) || o.hasPrefix("http://localhost") || o.hasPrefix("http://127.0.0.1")
    }
}
