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
        .target(name: "VMSummarization", dependencies: ["VMCore"])
    ],
    swiftLanguageModes: [.v6]
)
