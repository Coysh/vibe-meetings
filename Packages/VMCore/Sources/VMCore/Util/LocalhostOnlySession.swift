import Foundation

/// Builds `URLSession`s whose configuration enforces a privacy policy: only
/// the loopback range, plus an optional single user-configured Ollama host,
/// is reachable. All other outbound traffic is rejected at the protocol layer.
///
/// Rationale: this app's privacy posture is that no audio, transcript or
/// summary ever leaves the user's Mac (or, when explicitly opted in, their
/// own LAN to a self-hosted Ollama). The model downloader is the one
/// deliberate external exception and uses a separate, vanilla session
/// (`userDownload`) so its lifetime is bounded to the user's click.
public enum LocalhostOnlySession {
    /// Returns a session that rejects any host not in the loopback range
    /// nor in the global "extra allowed Ollama host" allowlist (set via
    /// `setAllowedExtraHost`). This is what `OllamaClient` uses.
    public static func loopbackOnly(timeout: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.protocolClasses = [LoopbackEnforcingProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    /// Records the one host the user has explicitly opted into via Settings
    /// (e.g. `192.168.1.50` for a self-hosted Ollama on their LAN). Pass
    /// `nil` to revert to loopback-only.
    ///
    /// There is intentionally only one slot — the app has a single
    /// summarisation engine, configured from the main actor. Any other
    /// caller using a `LocalhostOnlySession` session will still be subject
    /// to loopback-only enforcement.
    public static func setAllowedExtraHost(_ host: String?) {
        LoopbackEnforcingProtocol.allowedExtraHost = host?.lowercased()
    }

    /// Returns a session for a specific allowlisted external host
    /// (e.g. `huggingface.co`) — used only for explicit, user-initiated model
    /// downloads.
    public static func userDownload(timeout: TimeInterval = 600) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    public static func isLoopback(_ host: String) -> Bool {
        LoopbackEnforcingProtocol.isLoopback(host)
    }

    /// True if `host` looks like it belongs to the user's own LAN: RFC1918
    /// private ranges (10/8, 172.16/12, 192.168/16), the Tailscale CGNAT
    /// range (100.64/10), `.local` (mDNS / Bonjour), or loopback. Used by
    /// the Settings UI to warn (not forbid) when a configured Ollama URL
    /// points outside these ranges.
    public static func isLikelyLAN(_ host: String) -> Bool {
        if isLoopback(host) { return true }
        if host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("100.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}

final class LoopbackEnforcingProtocol: URLProtocol {
    /// Set from `LocalhostOnlySession.setAllowedExtraHost`. Lower-cased.
    /// `nonisolated(unsafe)` because mutation is gated to the main actor
    /// (Settings UI is the only writer) and reads are atomic word-aligned.
    nonisolated(unsafe) static var allowedExtraHost: String?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        if isLoopback(host) { return false }
        if let extra = allowedExtraHost, host == extra { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "<nil>"
        let err = NSError(
            domain: "LocalhostOnlySession",
            code: -1003,
            userInfo: [NSLocalizedDescriptionKey: "Blocked non-allowlisted host: \(host)"]
        )
        client?.urlProtocol(self, didFailWithError: err)
    }

    override func stopLoading() {}

    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host == "::1" || host == "[::1]" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }
}
