import XCTest
@testable import CodexBarIOS

final class CodexBarIOSTests: XCTestCase {
    func testUsageSeverityThresholds() {
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.74), .normal)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.75), .warning)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.90), .critical)
    }

    func testProviderConfigurationDefaults() {
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openRouter).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod,
            .cliToken
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod,
            .browserSession
        )
    }

    @MainActor
    func testDemoRefreshReturnsSortedResults() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            service.results.map(\.providerID),
            [.codex, .copilot, .openRouter]
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }
}
