import Foundation

public protocol UsageProvider: Sendable {
    var providerID: ProviderID { get }

    func fetchUsage() async throws -> ProviderUsageResult
}
