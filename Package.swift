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
        .executable(
            name: "UsageHistoryBenchmark",
            targets: ["UsageHistoryBenchmark"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SimplyDanny/SwiftLintPlugins",
            exact: "0.65.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "UsageHistoryBenchmark",
            dependencies: ["CodexBarIOS"],
            path: "PerformanceBenchmarks",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
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
                "Services/UITestFixtures.swift",
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
