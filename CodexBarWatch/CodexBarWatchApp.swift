import SwiftUI

@main
struct CodexBarWatchApp: App {
    private let screenshotScene = WatchAppStoreScreenshotScene.current()

    var body: some Scene {
        WindowGroup {
            if let screenshotScene {
                WatchDashboardView(state: screenshotScene.state)
            } else {
                ProductionWatchDashboardRoot()
            }
        }
    }
}

private struct ProductionWatchDashboardRoot: View {
    @StateObject private var dashboardStore = WatchDashboardStore()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            WatchDashboardView(state: dashboardStore.state(at: context.date))
        }
    }
}
