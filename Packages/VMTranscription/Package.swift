// swift-tools-version: 6.1
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
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // FluidAudio (Apache-2.0): on-device speaker diarization (pyannote community-1 on
        // CoreML). `traits: []` drops its default NemoTextProcessing trait, a prebuilt
        // binary used only by its speech-to-text side, which we don't use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5", traits: []),
    ],
    targets: [
        .target(
            name: "VMTranscription",
            dependencies: [
                "VMCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // Offline evaluation harness (developer tool, not linked into the app):
        // runs speaker diarization over saved recordings and reports cluster counts.
        .executableTarget(name: "vm-diar-eval", dependencies: ["VMTranscription", "VMCore"]),
    ],
    swiftLanguageModes: [.v6]
)
