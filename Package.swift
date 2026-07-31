// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBarIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexBarIOS",
            targets: ["CodexBarIOS"]
        ),
        .executable(
            name: "CodexBarIOSSmokeTests",
            targets: ["CodexBarIOSSmokeTests"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SimplyDanny/SwiftLintPlugins",
            exact: "0.65.0"
        ),
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
                "Views",
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .executableTarget(
            name: "CodexBarIOSSmokeTests",
            dependencies: ["CodexBarIOS"],
            path: "SmokeTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
    ]
)
