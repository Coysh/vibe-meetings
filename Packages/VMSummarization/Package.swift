// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMSummarization",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMSummarization", targets: ["VMSummarization"])
    ],
    dependencies: [
        .package(path: "../VMCore")
    ],
    targets: [
        .target(name: "VMSummarization", dependencies: ["VMCore"]),
        // Developer tool (not linked into the app): exercises the Claude Code engine from Terminal.
        .executableTarget(name: "vm-claude-check", dependencies: ["VMSummarization", "VMCore"]),
    ],
    swiftLanguageModes: [.v6]
)
