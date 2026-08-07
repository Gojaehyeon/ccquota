import CCQuotaCore
import SwiftUI
import WidgetKit

/// Reads only the App Group state file the menu bar app publishes. The widget
/// sandbox has no Keychain access and no network calls — by design.
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
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static var sample: SharedStateFile {
        var a = AccountSnapshot(label: "main", isActive: true)
        a.plan = "max"; a.fiveHourPercent = 42; a.weeklyPercent = 68
        a.fiveHourResetsAt = Date().addingTimeInterval(3600 * 2)
        var b = AccountSnapshot(label: "work", isActive: false)
        b.plan = "max"; b.fiveHourPercent = 8; b.weeklyPercent = 23
        return SharedStateFile(updatedAt: Date(), accounts: [a, b])
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
            VStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.title2).foregroundStyle(.secondary)
                Text("CCQuota를 실행하고\n계정을 등록하십시오")
                    .font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Small family has room for one thing, so it shows the account in use.
private struct SmallView: View {
    let accounts: [AccountSnapshot]

    private var focus: AccountSnapshot? {
        accounts.first { $0.isActive } ?? accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let account = focus {
                Text(account.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text("\(Int((account.headlinePercent ?? 0).rounded()))%")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(account.severity.color)
                    .opacity(account.isStale ? 0.5 : 1)

                Spacer(minLength: 0)

                Meter(title: "5시간", percent: account.fiveHourPercent)
                Meter(title: "주간", percent: account.weeklyPercent)

                if let resets = account.fiveHourResetsAt {
                    Text(Countdown.text(until: resets))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Medium family fits every account, which is the whole point of running three.
private struct MediumView: View {
    let accounts: [AccountSnapshot]
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Max 한도").font(.caption.weight(.semibold))
                Spacer()
                if let updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            ForEach(accounts.prefix(4)) { account in
                HStack(spacing: 6) {
                    Circle()
                        .fill(account.isActive ? Color.accentColor : .clear)
                        .frame(width: 5, height: 5)
                    Text(account.label)
                        .font(.caption2.weight(account.isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)

                    Meter(title: nil, percent: account.fiveHourPercent)
                    Meter(title: nil, percent: account.weeklyPercent)

                    // A stale value must not read as current, so dim it and
                    // mark it rather than showing it as freshly measured.
                    HStack(spacing: 1) {
                        if account.isStale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 7))
                        }
                        Text("\(Int((account.headlinePercent ?? 0).rounded()))%")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(account.severity.color)
                    .opacity(account.isStale ? 0.5 : 1)
                    .frame(width: 40, alignment: .trailing)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct Meter: View {
    let title: String?
    let percent: Double?

    var body: some View {
        if let percent {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                ProgressView(value: min(percent, 100), total: 100)
                    .tint(Severity(percent: percent).color)
            }
        }
    }
}

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
