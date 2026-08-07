import CCQuotaCore
import SwiftUI
import WidgetKit

/// Reads only the App Group state file the menu bar app publishes. The widget
/// sandbox has no Keychain access and makes no network calls — by design.
struct QuotaEntry: TimelineEntry {
    let date: Date
    let state: SharedStateFile?
}

struct QuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), state: QuotaProvider.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), state: SharedState.read() ?? QuotaProvider.sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: Date(), state: SharedState.read())
        // The app refreshes the file every few minutes; reloading the widget
        // more often than every 15 would just burn its refresh budget.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    static var sample: SharedStateFile {
        var a = AccountSnapshot(label: "limboart", isActive: true)
        a.plan = "max"; a.fiveHourPercent = 2; a.weeklyPercent = 0
        a.fiveHourResetsAt = Date().addingTimeInterval(3600 * 4)
        a.weeklyResetsAt = Date().addingTimeInterval(86400 * 5)
        var b = AccountSnapshot(label: "tntlabgo", isActive: false)
        b.plan = "max"; b.fiveHourPercent = 9; b.weeklyPercent = 14
        var c = AccountSnapshot(label: "teamtntlabs", isActive: false)
        c.plan = "max"; c.fiveHourPercent = 4; c.weeklyPercent = 73
        return SharedStateFile(updatedAt: Date(), accounts: [a, b, c])
    }
}

struct CCQuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let accounts = entry.state?.accounts, !accounts.isEmpty {
            switch family {
            case .systemSmall: SmallView(accounts: accounts)
            default: MediumView(accounts: accounts, updatedAt: entry.state?.updatedAt)
            }
        } else {
            EmptyStateView()
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.title2).foregroundStyle(.tertiary)
            Text("CCQuota를 실행하고\n계정을 등록하십시오")
                .font(.caption2).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

@main
struct CCQuotaWidgetBundle: WidgetBundle {
    var body: some Widget { CCQuotaWidget() }
}

struct CCQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.tntlabs.ccquota.widget", provider: QuotaProvider()) { entry in
            CCQuotaWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Max 한도")
        .description("등록된 Claude 계정의 5시간·주간 잔여 한도를 표시합니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
