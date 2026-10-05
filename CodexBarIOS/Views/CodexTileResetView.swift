import SwiftUI

struct CodexTileResetView: View {
    let bar: UsageBar
    let isCurrent: Bool

    var body: some View {
        TimelineView(CodexResetTimelineSchedule(deadline: bar.resetsAt ?? Date())) { context in
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

private struct CodexResetTimelineSchedule: TimelineSchedule {
    let deadline: Date

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(nextDate: startDate, deadline: deadline)
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date?
        let deadline: Date

        mutating func next() -> Date? {
            guard let date = nextDate else { return nil }
            nextDate = date < deadline ? Swift.min(date.addingTimeInterval(60), deadline) : nil
            return date
        }
    }
}
