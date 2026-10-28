import Foundation
import VMMCP

// vm-mcp — serve a meetings folder as an MCP server without the app.
//
//   swift run vm-mcp --root ~/MeetingNotes                       stdio
//   swift run vm-mcp --root ~/MeetingNotes --http 47821 \
//       [--public-url https://meetings.example.com] [--state oauth.json]
//                                                                 HTTP + OAuth on 127.0.0.1
//
// The shipped app does the same with `vibe-meetings --mcp` and Settings → Claude.

let arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }

guard let rootArg = value("--root") else {
    StdioTransport.log("usage: vm-mcp --root <meetings folder> [--http <port> [--public-url <url>] [--state <file>]]")
    exit(64)
}
let library = MeetingLibrary(root: path(rootArg))
StdioTransport.log("serving \(library.root.path)")

guard let portArg = value("--http") else {
    StdioTransport(server: MCPServer(library: library, serverVersion: "dev")).run()
    exit(0)
}

guard let port = UInt16(portArg) else { StdioTransport.log("bad port \(portArg)"); exit(64) }
let oauth = OAuthServer(stateURL: value("--state").map(path))
let server = try RemoteMCPServer(library: library, serverVersion: "dev", port: port,
                                 publicBaseURL: value("--public-url"), oauth: oauth)
server.start { state in StdioTransport.log("http: \(state)") }
StdioTransport.log("pairing code: \(await oauth.pairingCode)")
await oauth.setOnChange {
    Task { StdioTransport.log("pairing code: \(await oauth.pairingCode)") }
}
while true { try await Task.sleep(for: .seconds(3600)) }
