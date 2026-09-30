// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentUsage", targets: ["AgentUsage"]),
        .executable(name: "agent-usage", targets: ["AgentUsageCLI"]),
    ],
    targets: [
        .target(name: "AgentUsageCore"),
        .executableTarget(name: "AgentUsage", dependencies: ["AgentUsageCore"]),
        .executableTarget(name: "AgentUsageCLI", dependencies: ["AgentUsageCore"]),
        .testTarget(name: "AgentUsageCoreTests", dependencies: ["AgentUsageCore"]),
    ]
)
