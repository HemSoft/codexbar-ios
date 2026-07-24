import SwiftUI

@main
struct CodexBarWatchApp: App {
    @StateObject private var dashboardStore = WatchDashboardStore()

    var body: some Scene {
        WindowGroup {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                WatchDashboardView(state: dashboardStore.state(at: context.date))
            }
        }
    }
}
