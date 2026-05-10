// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"])
    ],
    targets: [
        .target(name: "VMCore"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"])
    ],
    swiftLanguageModes: [.v6]
)
