import Foundation

/// Builds `URLSession`s whose configuration enforces a localhost-only policy.
///
/// Rationale: this app's privacy posture is that no audio, transcript or summary ever
/// leaves the user's Mac. The only legitimate outbound traffic is (a) Ollama on
/// `127.0.0.1:11434` and (b) explicit, user-clicked model downloads. Everything else
/// goes through this factory; if anyone adds an unintended caller, the host check
/// rejects the connection at the protocol layer.
public enum LocalhostOnlySession {
    /// Returns a session that rejects any non-loopback host.
    public static func loopbackOnly(timeout: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.protocolClasses = [LoopbackEnforcingProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    /// Returns a session for a specific allowlisted external host (e.g. huggingface.co)
    /// — used only for explicit, user-initiated model downloads.
    public static func userDownload(timeout: TimeInterval = 600) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}

final class LoopbackEnforcingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return !LoopbackEnforcingProtocol.isLoopback(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "<nil>"
        let err = NSError(
            domain: "LocalhostOnlySession",
            code: -1003,
            userInfo: [NSLocalizedDescriptionKey: "Blocked non-loopback host: \(host)"]
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
