// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HubAgent",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "HubAgentApp", targets: ["HubAgentApp"]),
        .executable(name: "HubAgentDaemon", targets: ["HubAgentDaemon"])
    ],
    targets: [
        .target(name: "HubAgentShared"),
        .executableTarget(
            name: "HubAgentApp",
            dependencies: ["HubAgentShared"]
        ),
        .executableTarget(
            name: "HubAgentDaemon",
            dependencies: ["HubAgentShared"]
        ),
        .testTarget(
            name: "HubAgentSharedTests",
            dependencies: ["HubAgentShared"]
        ),
        .testTarget(
            name: "HubAgentAppTests",
            dependencies: ["HubAgentApp"]
        ),
        .testTarget(
            name: "HubAgentDaemonTests",
            dependencies: ["HubAgentDaemon"]
        )
    ]
)
