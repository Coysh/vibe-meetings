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
        // Vendored SpeexDSP subset (BSD-3): acoustic echo canceller + preprocessor.
        // Floating-point build using SpeexDSP's built-in FFT. See README-vendored.md.
        .target(
            name: "CSpeexDSP",
            exclude: ["README-vendored.md", "COPYING"],
            publicHeadersPath: "include",
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_SMALLFT"),
                .define("EXPORT", to: ""),
            ]
        ),
        .target(name: "VMRecording", dependencies: ["VMCore", "CSpeexDSP"]),
        .testTarget(name: "VMRecordingTests", dependencies: ["VMRecording"]),
        // Offline evaluation harness (developer tool, not linked into the app):
        // runs the echo canceller over saved stereo recordings and reports ERLE etc.
        .executableTarget(name: "vm-aec-eval", dependencies: ["VMRecording", "VMCore"]),
    ],
    swiftLanguageModes: [.v6]
)
