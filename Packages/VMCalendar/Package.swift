// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMCalendar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMCalendar", targets: ["VMCalendar"])
    ],
    dependencies: [
        .package(path: "../VMCore")
    ],
    targets: [
        .target(name: "VMCalendar", dependencies: ["VMCore"]),
        .testTarget(name: "VMCalendarTests", dependencies: ["VMCalendar"])
    ],
    swiftLanguageModes: [.v6]
)
