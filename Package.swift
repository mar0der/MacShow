// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "MacShow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // LGPL build of libmpv + FFmpeg (the GPL product is "MPVKit-GPL").
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "MacShow",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")]
        ),
    ]
)
