// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RememBear",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RememBearCore", targets: ["RememBearCore"]), .executable(name: "remembear", targets: ["RememBear"])],
    targets: [
        .target(name: "RememBearCore"),
        // AppKit and Accessibility glue. Swift 5 mode keeps their non-Sendable C types workable.
        .executableTarget(name: "RememBear", dependencies: ["RememBearCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RememBearCoreTests", dependencies: ["RememBearCore"])
    ]
)
