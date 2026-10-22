// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peeko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PeekoApp", targets: ["PeekoApp"]),
        .library(name: "PeekoCore", targets: ["PeekoCore"]),
    ],
    dependencies: [
        // Auto-updates. A prebuilt framework, so it builds without Xcode.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "PeekoCore"),
        .executableTarget(name: "PeekoApp", dependencies: [
            "PeekoCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // Stand-in for a test target: XCTest and Swift Testing need Xcode, not Command Line Tools.
        .executableTarget(name: "PeekoChecks", dependencies: ["PeekoCore"], path: "Checks"),
    ]
)
