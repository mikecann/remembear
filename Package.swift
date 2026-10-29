// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecallIt",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RecallItCore", targets: ["RecallItCore"]), .executable(name: "RecallIt", targets: ["RecallIt"])],
    targets: [
        .target(name: "RecallItCore"),
        // AppKit and Accessibility glue. Swift 5 mode keeps their non-Sendable C types workable.
        .executableTarget(name: "RecallIt", dependencies: ["RecallItCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RecallItCoreTests", dependencies: ["RecallItCore"])
    ]
)
