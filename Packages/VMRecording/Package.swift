// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMRecording",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMRecording", targets: ["VMRecording"])
    ],
    dependencies: [
        .package(path: "../VMCore")
    ],
    targets: [
        .target(name: "VMRecording", dependencies: ["VMCore"])
    ],
    swiftLanguageModes: [.v6]
)
