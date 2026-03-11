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
            url: "https://github.com/sundayfun/binary-assets/releases/download/libsignal-v0.76.3/SignalFfi.xcframework.zip",
            checksum: "214b00f4bf2d7d8c8def0d59428f4a4c5abd3f3d1bc8ba49e019fd596699e59f"
        ),
        .target(
            name: "LibSignalClient",
            dependencies: ["SignalFfi"],
            path: "Sources/LibSignalClient"
        ),
    ]
)
