import XCTest
@testable import VMMCP

final class RemoteServerTests: XCTestCase {
    private let base = "https://meetings.example.com"
    private let claudeCallback = "https://claude.ai/api/mcp/auth_callback"
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-and-some-more-entropy"
    private var root: URL!
    private var mcp: MCPServer!
    private var clock: TestClock!
    private var oauth: OAuthServer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vmmcp-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mcp = MCPServer(library: MeetingLibrary(root: root), serverVersion: "test")
        clock = TestClock()
        let clock = self.clock!
        oauth = OAuthServer(stateURL: nil, now: { clock.now })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - discovery & 401

    func testDiscoveryMetadata() async throws {
        let pr = try json(await send("GET", "/.well-known/oauth-protected-resource"))
        XCTAssertEqual(pr["resource"], .string(base + "/mcp"))
        XCTAssertEqual(pr["authorization_servers"], [.string(base)])

        let asm = try json(await send("GET", "/.well-known/oauth-authorization-server"))
        XCTAssertEqual(asm["issuer"], .string(base))
        XCTAssertEqual(asm["token_endpoint"], .string(base + "/token"))
        XCTAssertEqual(asm["code_challenge_methods_supported"], ["S256"])
    }

    func testMCPWithoutTokenIs401WithResourceMetadata() async throws {
        let r = await send("POST", "/mcp", body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        XCTAssertEqual(r.status, 401)
        let header = r.headers.first { $0.0 == "WWW-Authenticate" }?.1
        XCTAssertEqual(header, "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource\"")

        let bad = await send("POST", "/mcp", headers: ["authorization": "Bearer nope"], body: Data("{}".utf8))
        XCTAssertEqual(bad.status, 401)
        XCTAssertTrue(bad.headers.first { $0.0 == "WWW-Authenticate" }?.1.contains("invalid_token") == true)
    }

    func testGetOnMCPIs405() async {
        let r = await send("GET", "/mcp", headers: ["authorization": "Bearer x"])
        XCTAssertEqual(r.status, 405)
    }

    func testForeignOriginRejected() async {
        let r = await send("GET", "/.well-known/oauth-authorization-server", headers: ["origin": "https://evil.example"])
        XCTAssertEqual(r.status, 403)
        let ok = await send("GET", "/.well-known/oauth-authorization-server", headers: ["origin": "https://claude.ai"])
        XCTAssertEqual(ok.status, 200)
    }

    func testDerivedBaseFromForwardedHeaders() {
        let req = HTTPRequest(method: "GET", path: "/", headers: ["host": "abc.trycloudflare.com", "x-forwarded-proto": "https"])
        XCTAssertEqual(RemoteMCPServer.derivedBase(req), "https://abc.trycloudflare.com")
        XCTAssertEqual(RemoteMCPServer.derivedBase(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:47821"])), "http://127.0.0.1:47821")
        XCTAssertEqual(RemoteMCPServer.normalizeBaseURL("meetings.example.com/mcp/"), "https://meetings.example.com")
        XCTAssertNil(RemoteMCPServer.normalizeBaseURL("  "))
    }

    // MARK: - full flow

    func testFullAuthorizationFlow() async throws {
        let clientID = try await register()

        // The consent page names the client and escapes it.
        let page = await send("GET", "/authorize?" + authorizeQuery(clientID: clientID))
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("Claude &lt;test&gt;"))

        // Wrong code: page again, no redirect.
        let wrong = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: "WRNG-CODE"))
        XCTAssertEqual(wrong.status, 200)
        XCTAssertTrue(String(decoding: wrong.body, as: UTF8.self).contains("That code isn&#39;t right"))

        // Right code (any case, with or without the dash) → redirect with code + state.
        let pairing = await oauth.pairingCode
        let ok = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: pairing.lowercased().replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(ok.status, 302)
        let location = try XCTUnwrap(URLComponents(string: try XCTUnwrap(ok.headers.first { $0.0 == "Location" }?.1)))
        XCTAssertEqual(location.host, "claude.ai")
        XCTAssertEqual(location.queryItems?.first { $0.name == "state" }?.value, "xyz+/=")
        let code = try XCTUnwrap(location.queryItems?.first { $0.name == "code" }?.value)

        // The pairing code is single-use.
        let rotated = await oauth.pairingCode
        XCTAssertNotEqual(rotated, pairing)

        // Exchange.
        let tokens = try json(await send("POST", "/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": claudeCallback, "code_verifier": verifier,
        ]))
        let access = try XCTUnwrap(tokens["access_token"]?.stringValue)
        let refresh = try XCTUnwrap(tokens["refresh_token"]?.stringValue)
        XCTAssertEqual(tokens["token_type"], "Bearer")

        // The code can't be used twice.
        let replay = await send("POST", "/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": claudeCallback, "code_verifier": verifier,
        ])
        XCTAssertEqual(replay.status, 400)

        // Authorised MCP call.
        let list = await send("POST", "/mcp", headers: ["authorization": "Bearer \(access)"],
                              body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        XCTAssertEqual(list.status, 200)
        XCTAssertTrue(String(decoding: list.body, as: UTF8.self).contains("list_meetings"))

        // A notification gets 202 and no body.
        let note = await send("POST", "/mcp", headers: ["authorization": "Bearer \(access)"],
                              body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertEqual(note.status, 202)

        let clients = await oauth.connectedClients()
        XCTAssertEqual(clients.map(\.name), ["Claude <test>"])

        // Refresh rotates: the old refresh token stops working.
        let refreshed = try json(await send("POST", "/token", form: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]))
        let access2 = try XCTUnwrap(refreshed["access_token"]?.stringValue)
        let again = await send("POST", "/token", form: ["grant_type": "refresh_token", "refresh_token": refresh])
        XCTAssertEqual(again.status, 400)

        // Access tokens expire after an hour.
        clock.advance(by: 3601)
        let expired = await oauth.validate(authorization: "Bearer \(access2)")
        XCTAssertFalse(expired)

        // Revoking the client cuts everything off.
        await oauth.revoke(clientID: clientID)
        let gone = await oauth.connectedClients()
        XCTAssertTrue(gone.isEmpty)
    }

    func testDenyRedirectsWithAccessDenied() async throws {
        let clientID = try await register()
        var form = authorizeForm(clientID: clientID, code: "")
        form["action"] = "deny"
        let r = await send("POST", "/authorize", form: form)
        XCTAssertEqual(r.status, 302)
        XCTAssertTrue(r.headers.first { $0.0 == "Location" }?.1.contains("error=access_denied") == true)
    }

    func testPKCEMismatchFails() async throws {
        let clientID = try await register()
        let code = try await authorize(clientID: clientID)
        let r = await send("POST", "/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": claudeCallback, "code_verifier": "wrong-verifier-wrong-verifier-wrong-verifier",
        ])
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(try json(r)["error"], "invalid_grant")
    }

    func testAuthCodeExpires() async throws {
        let clientID = try await register()
        let code = try await authorize(clientID: clientID)
        clock.advance(by: 301)
        let r = await send("POST", "/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": claudeCallback, "code_verifier": verifier,
        ])
        XCTAssertEqual(r.status, 400)
    }

    func testLockoutAfterFiveWrongCodes() async throws {
        let clientID = try await register()
        for _ in 0..<5 {
            _ = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: "AAAA-AAAA"))
        }
        let pairing = await oauth.pairingCode
        let locked = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: pairing))
        XCTAssertEqual(locked.status, 200)
        XCTAssertTrue(String(decoding: locked.body, as: UTF8.self).contains("Too many wrong codes"))

        clock.advance(by: 15 * 60 + 1)
        let unlocked = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: pairing))
        XCTAssertEqual(unlocked.status, 302)
    }

    func testRegistrationRejectsForeignRedirects() async throws {
        for uri in ["https://evil.example/cb", "https://claude.ai/other", "javascript:alert(1)", "http://claude.ai/api/mcp/auth_callback"] {
            let body: JSONValue = ["redirect_uris": [.string(uri)]]
            let r = await send("POST", "/register", body: body.encoded())
            XCTAssertEqual(r.status, 400, uri)
        }
        XCTAssertTrue(OAuthServer.isAllowedRedirect("http://localhost:6274/oauth/callback"))
        XCTAssertTrue(OAuthServer.isAllowedRedirect("https://claude.com/api/mcp/auth_callback"))
    }

    func testAuthorizeRejectsUnregisteredRedirectWithoutRedirecting() async throws {
        let clientID = try await register()
        let query = authorizeQuery(clientID: clientID).replacingOccurrences(of: "claude.ai", with: "claude.com")
        let r = await send("GET", "/authorize?" + query)
        XCTAssertEqual(r.status, 400)
        XCTAssertNil(r.headers.first { $0.0 == "Location" })
    }

    func testStateSurvivesRestartAndStoresOnlyHashes() async throws {
        let stateURL = root.appendingPathComponent("support/mcp-oauth.json")
        oauth = OAuthServer(stateURL: stateURL)
        let clientID = try await register()
        let code = try await authorize(clientID: clientID)
        let tokens = try json(await send("POST", "/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": claudeCallback, "code_verifier": verifier,
        ]))
        let access = try XCTUnwrap(tokens["access_token"]?.stringValue)

        let saved = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(saved.contains(access))
        let perms = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let reloaded = OAuthServer(stateURL: stateURL)
        let valid = await reloaded.validate(authorization: "Bearer \(access)")
        XCTAssertTrue(valid)
    }

    // MARK: - HTTP parsing and a real socket

    func testParserContentLengthAndChunked() throws {
        guard case .incomplete = HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) else { return XCTFail() }
        guard case .complete(let r) = HTTPParser.parse(Data("POST /mcp?a=b%20c HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.query["a"], "b c")
        XCTAssertEqual(r.headers["host"], "x")
        XCTAssertEqual(r.body, Data("hello".utf8))

        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        guard case .complete(let c) = HTTPParser.parse(Data(chunked.utf8)) else { return XCTFail() }
        XCTAssertEqual(String(decoding: c.body, as: UTF8.self), "hello world")

        guard case .invalid(413) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else { return XCTFail() }
    }

    func testLiveSocket() async throws {
        let server = try RemoteMCPServer(library: MeetingLibrary(root: root), serverVersion: "test", port: 0,
                                         publicBaseURL: nil, oauth: oauth)
        let port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            server.start { state in
                switch state {
                case .ready(let port): once.run { cont.resume(returning: port) }
                case .failed(let message): once.run { cont.resume(throwing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])) }
                default: break
                }
            }
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "WWW-Authenticate"),
                       "Bearer resource_metadata=\"http://127.0.0.1:\(port)/.well-known/oauth-protected-resource\"")

        let (meta, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/.well-known/oauth-authorization-server")!)
        XCTAssertEqual(try JSONValue.decode(meta)["issuer"], .string("http://127.0.0.1:\(port)"))
    }

    // MARK: - helpers

    private func send(_ method: String, _ target: String, headers: [String: String] = [:],
                      body: Data = Data(), form: [String: String]? = nil) async -> HTTPResponse {
        var bodyData = body
        if let form {
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            bodyData = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let components = URLComponents(string: target)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: method, path: components.path, query: query, headers: headers, body: bodyData)
        return await RemoteMCPServer.route(request, mcp: mcp, oauth: oauth, configuredBase: base)
    }

    private func json(_ r: HTTPResponse) throws -> JSONValue {
        try JSONValue.decode(r.body)
    }

    private func register() async throws -> String {
        let body: JSONValue = ["redirect_uris": [.string(claudeCallback)], "client_name": "Claude <test>", "token_endpoint_auth_method": "none"]
        let r = await send("POST", "/register", body: body.encoded())
        XCTAssertEqual(r.status, 201)
        return try XCTUnwrap(try json(r)["client_id"]?.stringValue)
    }

    private func authorizeForm(clientID: String, code: String) -> [String: String] {
        [
            "client_id": clientID, "redirect_uri": claudeCallback, "response_type": "code",
            "code_challenge": OAuthServer.pkceChallenge(verifier), "code_challenge_method": "S256",
            "state": "xyz+/=", "pairing_code": code, "action": "allow",
        ]
    }

    private func authorizeQuery(clientID: String) -> String {
        var c = URLComponents()
        c.queryItems = authorizeForm(clientID: clientID, code: "")
            .filter { !["pairing_code", "action"].contains($0.key) }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private func authorize(clientID: String) async throws -> String {
        let pairing = await oauth.pairingCode
        let r = await send("POST", "/authorize", form: authorizeForm(clientID: clientID, code: pairing))
        let location = try XCTUnwrap(URLComponents(string: try XCTUnwrap(r.headers.first { $0.0 == "Location" }?.1)))
        return try XCTUnwrap(location.queryItems?.first { $0.name == "code" }?.value)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.withLock {
            guard !done else { return }
            done = true
            body()
        }
    }
}
