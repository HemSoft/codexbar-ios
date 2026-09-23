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
            name: "GitHubBillingFixtureTests",
            targets: ["GitHubBillingFixtureTests"]
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
        // Local-only auth regressions; automatic CI continues running its existing smoke executable.
        .testTarget(
            name: "OpenCodeAuthTests",
            dependencies: ["CodexBarIOS"],
            path: "OpenCodeAuthTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
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
        .executableTarget(
            name: "GitHubBillingFixtureTests",
            dependencies: ["CodexBarIOS"],
            path: "GitHubBillingFixtureTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
    ]
)
