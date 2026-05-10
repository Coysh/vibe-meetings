// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMTranscription",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMTranscription", targets: ["VMTranscription"])
    ],
    dependencies: [
        .package(path: "../VMCore"),
        // WhisperKit is fetched from GitHub. Pin a tag once the project is opened in Xcode
        // — Xcode will resolve and cache it.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "VMTranscription",
            dependencies: [
                "VMCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
