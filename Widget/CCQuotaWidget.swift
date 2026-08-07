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
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: QuotaEntry

    /// The macOS desktop draws widgets desaturated whenever it is not the focused
    /// surface, which is most of the time. Hue carries nothing there, so the views
    /// switch to full-strength ink and lean on shape and the printed number.
    private var monochrome: Bool { renderingMode != .fullColor }

    var body: some View {
        if let accounts = entry.state?.accounts, !accounts.isEmpty {
            switch family {
            case .systemSmall:
                SmallView(accounts: accounts, monochrome: monochrome)
            case .systemLarge:
                LargeView(accounts: accounts, updatedAt: entry.state?.updatedAt,
                          monochrome: monochrome)
            case .systemExtraLarge:
                ExtraLargeView(accounts: accounts, updatedAt: entry.state?.updatedAt,
                               monochrome: monochrome)
            default:
                MediumView(accounts: accounts, updatedAt: entry.state?.updatedAt,
                           monochrome: monochrome)
            }
        } else {
            EmptyStateView(reachedData: entry.state != nil)
        }
    }
}

/// Two different failures used to render the same blank card: no accounts
/// registered, and the widget being unable to reach the shared file at all.
/// They need different actions from the reader, so they say different things.
private struct EmptyStateView: View {
    let reachedData: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: reachedData ? "person.crop.circle.badge.plus"
                                          : "exclamationmark.triangle")
                .font(.title2).foregroundStyle(.secondary)
            Text(reachedData ? "설정에서 계정을 등록하십시오"
                             : "CCQuota 앱을 실행하십시오")
                .font(.caption).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
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
        .description("등록된 Claude 계정의 5시간·주간 잔여 한도를 표시합니다. 큰 크기는 초기화 시각을, 가장 큰 크기는 모델별 주간 한도까지 함께 보여줍니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
