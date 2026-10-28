// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMMCP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMMCP", targets: ["VMMCP"])
    ],
    dependencies: [
        .package(path: "../VMCore"),
        .package(path: "../VMStorage"),
    ],
    targets: [
        .target(name: "VMMCP", dependencies: ["VMCore", "VMStorage"]),
        // Developer tool (not linked into the app): serves a meetings folder over stdio.
        .executableTarget(name: "vm-mcp", dependencies: ["VMMCP"]),
        .testTarget(name: "VMMCPTests", dependencies: ["VMMCP", "VMCore", "VMStorage"]),
    ],
    swiftLanguageModes: [.v6]
)
