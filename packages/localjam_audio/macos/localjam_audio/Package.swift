// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "localjam_audio",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "localjam-audio", targets: ["localjam_audio"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "localjam_audio",
            dependencies: [
                "localjam_audio_objc",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            resources: [
                // Declares mach_absolute_time (System boot time, reason 35F9.1).
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        // Objective-C exception catcher for AVFAudio calls that raise
        // NSException. A Swift package target cannot mix languages, hence a
        // target of its own (CocoaPods compiles both into one module).
        .target(
            name: "localjam_audio_objc",
            path: "Sources/localjam_audio_objc"
        ),
    ]
)
