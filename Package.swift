// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyHub",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MyHub", targets: ["MyHub"])
    ],
    targets: [
        .executableTarget(
            name: "MyHub",
            path: "Sources/MyHub",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Pure logic only: stores, parsers, signers, the hover state machine.
        // The panel itself is verified by eye, not by tests.
        .testTarget(
            name: "MyHubTests",
            dependencies: ["MyHub"],
            path: "Tests/MyHubTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
