// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMStorage",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMStorage", targets: ["VMStorage"])
    ],
    dependencies: [
        .package(path: "../VMCore")
    ],
    targets: [
        .target(name: "VMStorage", dependencies: ["VMCore"]),
        .testTarget(name: "VMStorageTests", dependencies: ["VMStorage"])
    ],
    swiftLanguageModes: [.v6]
)
