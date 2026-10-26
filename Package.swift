// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "MacShow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // LGPL build of libmpv + FFmpeg: MPVKit 1.1.0-n9.0.2, with MacShow's own FFmpeg
        // build (more decoders for old files); see Vendor/MPVKit.
        .package(path: "Vendor/MPVKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // Library index: database, metadata reading, scanning, folder watching. No UI.
        .target(
            name: "MacShowCore",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "MacShow",
            dependencies: ["MacShowCore", .product(name: "MPVKit", package: "MPVKit")]
        ),
        // Bridge for MCP apps that start a program: stdin/stdout ↔ MacShow's agent endpoint.
        .executableTarget(name: "macshow-mcp"),
        .testTarget(
            name: "MacShowCoreTests",
            dependencies: ["MacShowCore"],
            resources: [.copy("Fixtures"), .copy("ConvertFixtures")]
        ),
    ]
)
