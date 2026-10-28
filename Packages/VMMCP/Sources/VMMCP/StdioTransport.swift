import Foundation

/// MCP over stdio: one JSON-RPC message per line in, one per line out. Returns
/// when stdin closes (the client quit). Nothing else may write to stdout while
/// this runs; diagnostics go to stderr.
public struct StdioTransport: Sendable {
    public let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func run() {
        let stdout = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard var response = server.handle(Data(line.utf8)) else { continue }
            response.append(0x0A)
            stdout.write(response)
        }
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("[vibe-meetings mcp] \(message)\n".utf8))
    }
}
