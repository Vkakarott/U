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
    dependencies: [
        // Pinned exactly: the daemon's screen restoration depends on this version's behavior.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0")
    ],
    targets: [
        .target(name: "HubAgentShared"),
        .target(
            name: "HubAgentTransport",
            dependencies: ["HubAgentShared"]
        ),
        .executableTarget(
            name: "HubAgentApp",
            dependencies: ["HubAgentShared", "HubAgentTransport"]
        ),
        .executableTarget(
            name: "HubAgentDaemon",
            dependencies: [
                "HubAgentShared",
                "HubAgentTransport",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "HubAgentSharedTests",
            dependencies: ["HubAgentShared"]
        ),
        .testTarget(
            name: "HubAgentTransportTests",
            dependencies: ["HubAgentTransport"]
        ),
        .testTarget(
            name: "HubAgentAppTests",
            dependencies: ["HubAgentApp", "HubAgentTransport"]
        ),
        .testTarget(
            name: "HubAgentDaemonTests",
            dependencies: [
                "HubAgentDaemon",
                "HubAgentTransport",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
