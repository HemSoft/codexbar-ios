// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBarIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodexBarIOS",
            targets: ["CodexBarIOS"]
        ),
        .executable(
            name: "CodexBarIOSSmokeTests",
            targets: ["CodexBarIOSSmokeTests"]
        )
    ],
    targets: [
        .target(
            name: "CodexBarIOS",
            path: "CodexBarIOS",
            exclude: [
                "CodexBarIOSApp.swift",
                "CodexBarIOS.entitlements",
                "ContentView.swift",
                "Info.plist",
                "PrivacyInfo.xcprivacy",
                "Resources",
                "Views"
            ]
        ),
        .executableTarget(
            name: "CodexBarIOSSmokeTests",
            dependencies: ["CodexBarIOS"],
            path: "SmokeTests"
        )
    ]
)
