// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TaterTunnel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TaterTunnel", targets: ["TaterTunnel"])
    ],
    targets: [
        .executableTarget(
            name: "TaterTunnel",
            path: "Sources/TaterTunnel",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
