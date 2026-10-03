// swift-tools-version: 6.0
import PackageDescription

// Developer tool: transcript-level evaluation of the mic echo canceller.
// Not part of the app build.
let package = Package(
    name: "aec-transcribe-eval",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/VMCore"),
        .package(path: "../../Packages/VMRecording"),
        .package(path: "../../Packages/VMTranscription"),
    ],
    targets: [
        .executableTarget(
            name: "aec-transcribe-eval",
            dependencies: [
                .product(name: "VMCore", package: "VMCore"),
                .product(name: "VMRecording", package: "VMRecording"),
                .product(name: "VMTranscription", package: "VMTranscription"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
