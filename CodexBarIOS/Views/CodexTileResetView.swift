import SwiftUI

struct CodexTileResetView: View {
    let bar: UsageBar
    let isCurrent: Bool
    @Environment(\.codexResetDate) private var now

    var body: some View {
        if let description = CodexTileResetContent.description(for: bar, isCurrent: isCurrent, at: now) {
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CodexResetTimeline<Content: View>: View {
    let deadline: Date?
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if let deadline {
            TimelineView(CodexResetTimelineSchedule(deadline: deadline)) { context in
                content(context.date).environment(\.codexResetDate, context.date)
            }
        } else {
            content(Date())
        }
    }
}

struct ProviderMetricResetContent<Content: View>: View {
    let bar: UsageBar
    let providerID: ProviderID
    let isCurrent: Bool
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        CodexResetTimeline(deadline: providerID == .codex ? bar.resetsAt : nil) { now in
            if let description = providerID == .codex
                ? CodexTileResetContent.description(for: bar, isCurrent: isCurrent, at: now)
                : bar.localizedResetDescription() {
                content(description)
            }
        }
    }
}

private struct CodexResetDateKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
    var codexResetDate: Date {
        get { self[CodexResetDateKey.self] }
        set { self[CodexResetDateKey.self] = newValue }
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
