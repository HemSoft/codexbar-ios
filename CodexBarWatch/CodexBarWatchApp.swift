import SwiftUI

@main
struct CodexBarWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchDashboardView(state: .sample)
        }
    }
}
