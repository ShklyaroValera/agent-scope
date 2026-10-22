// swift-tools-version: 6.0
import PackageDescription

// The app target is `AgentScopeApp`, not `AgentScope`: on case-insensitive APFS its binary would
// collide with the `agentscope` CLI in `.build/<config>/`. `scripts/build-app.sh` renames it inside the bundle.
let package = Package(
    name: "AgentScope",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentScopeKit", targets: ["AgentScopeKit"]),
        .executable(name: "AgentScopeApp", targets: ["AgentScopeApp"]),
        .executable(name: "agentscope", targets: ["agentscope"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AgentScopeKit"),
        .executableTarget(
            name: "AgentScopeApp",
            dependencies: ["AgentScopeKit"]
        ),
        .executableTarget(
            name: "agentscope",
            dependencies: [
                "AgentScopeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AgentScopeCLI"
        ),
        .testTarget(name: "AgentScopeKitTests", dependencies: ["AgentScopeKit"]),
    ]
)
