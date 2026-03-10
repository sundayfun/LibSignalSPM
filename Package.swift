// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LibSignalSPM",
    platforms: [
        .iOS("18.0"),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LibSignalClient",
            targets: ["LibSignalClient"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "SignalFfi",
            path: "SignalFfi.xcframework"
        ),
        .target(
            name: "LibSignalClient",
            dependencies: ["SignalFfi"],
            path: "Sources/LibSignalClient"
        ),
    ]
)
