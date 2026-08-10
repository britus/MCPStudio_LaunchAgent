// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MCPStudioLaunchAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MCPStudioLaunchAgent", targets: ["MCPStudioLaunchAgent"])
    ],
    targets: [
        .executableTarget(
            name: "MCPStudioLaunchAgent"
        ),
        .testTarget(
            name: "MCPStudioLaunchAgentTests",
            dependencies: ["MCPStudioLaunchAgent"]
        )
    ]
)
