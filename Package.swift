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
            url: "https://github.com/sundayfun/LibSignalSPM/releases/download/v0.76.3/SignalFfi.xcframework.zip",
            checksum: "2abf3e397bdbefa3034f467a3dff136f42997fc54ddefdbec68ac4429c781050"
        ),
        .target(
            name: "LibSignalClient",
            dependencies: ["SignalFfi"],
            path: "Sources/LibSignalClient"
        ),
    ]
)
