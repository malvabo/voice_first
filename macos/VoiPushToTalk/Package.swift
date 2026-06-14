// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VoiPushToTalk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiPushToTalk", targets: ["VoiPushToTalk"]),
    ],
    targets: [
        .executableTarget(
            name: "VoiPushToTalk",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
