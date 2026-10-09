// swift-tools-version: 6.2

import PackageDescription

// Throwaway phase 1 prototype. Deleting this folder must not affect the main package.
let package = Package(
    name: "TerminalPathPrototype",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0")
    ],
    targets: [
        .target(
            name: "ProtoCore",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "proto-daemon",
            dependencies: ["ProtoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "proto-probe",
            dependencies: ["ProtoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "proto-app",
            dependencies: ["ProtoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
