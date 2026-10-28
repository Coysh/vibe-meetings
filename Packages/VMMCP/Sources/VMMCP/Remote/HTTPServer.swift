import Foundation
@preconcurrency import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Fields of an `application/x-www-form-urlencoded` body.
    public var formFields: [String: String] { Self.parseForm(String(decoding: body, as: UTF8.self)) }

    static func parseForm(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ x: Substring) -> String {
                x.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x)
            }
            guard let key = kv.first else { continue }
            out[decode(key)] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: value.encoded())
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    public static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"),
            ("X-Frame-Options", "DENY"),
            ("Referrer-Policy", "no-referrer"),
            ("Cache-Control", "no-store"),
        ], body: Data(html.utf8))
    }

    public static func redirect(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: [("Location", location), ("Cache-Control", "no-store")])
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}

/// A deliberately small HTTP/1.1 server on 127.0.0.1 only: one request per
/// connection, `Connection: close`. It sits behind a tunnel (cloudflared), never
/// directly on the network.
public final class HTTPServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vibe-meetings.mcp.http")
    private let handler: Handler

    public init(port: UInt16, handler: @escaping Handler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
        self.handler = handler
    }

    public func start(onState: @escaping @Sendable (State) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: onState(.ready(port: listener.port?.rawValue ?? 0))
            case .failed(let error): onState(.failed(error.localizedDescription))
            case .cancelled: onState(.stopped)
            case .waiting(let error): onState(.failed(error.localizedDescription))
            default: break
            }
        }
        listener.newConnectionHandler = { [queue, handler] connection in
            HTTPConnection(connection: connection, queue: queue, handler: handler).start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }
}

/// Reads one request, answers it, closes. All state is touched only on `queue`.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var finished = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        // A client that never finishes its request doesn't hold the connection forever.
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            if !finished { finish() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                respond(to: request)
            case .invalid(let status):
                send(HTTPResponse.text("Bad request", status: status))
            case .incomplete:
                if isComplete || error != nil { finish() } else { receive() }
            }
        }
    }

    private func respond(to request: HTTPRequest) {
        let handler = self.handler
        Task {
            let response = await handler(request)
            queue.async { self.send(response) }
        }
    }

    private func send(_ response: HTTPResponse) {
        guard !finished else { return }
        connection.send(content: response.serialized, completion: .contentProcessed { [self] _ in finish() })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
    }
}

enum HTTPParser {
    enum Result {
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int)
    }

    static func parse(_ data: Data) -> Result {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > HTTPServer.maxHeaderBytes ? .invalid(status: 431) : .incomplete
        }
        guard headerEnd.lowerBound <= HTTPServer.maxHeaderBytes else { return .invalid(status: 431) }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let rest = data[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(rest) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid(status: 400)
            case .tooLarge: return .invalid(status: 413)
            case .done(let decoded): body = decoded
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid(status: 400) }
            guard length <= HTTPServer.maxBodyBytes else { return .invalid(status: 413) }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.percentEncodedPath.removingPercentEncoding ?? target,
            query: query,
            headers: headers,
            body: body
        ))
    }

    private enum Chunked { case incomplete, invalid, tooLarge, done(Data) }

    private static func decodeChunked(_ data: Data) -> Chunked {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[index...].firstRange(of: crlf) else { return .incomplete }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .invalid }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return .done(out) }  // trailers, if any, are ignored
            guard out.count + size <= HTTPServer.maxBodyBytes else { return .tooLarge }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return .incomplete }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            out.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
