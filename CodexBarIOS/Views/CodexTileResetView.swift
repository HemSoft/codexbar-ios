import SwiftUI

struct CodexTileResetView: View {
    let bar: UsageBar
    let isCurrent: Bool

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            if let description = CodexTileResetContent.description(
                for: bar, isCurrent: isCurrent, at: context.date
            ) {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
