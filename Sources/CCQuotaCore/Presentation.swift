import SwiftUI

/// Severity of a quota reading, shared by the menu bar app and the widget so a
/// percentage never reads as "fine" in one surface and "critical" in the other.
///
/// Three levels, not four. The reserved status palette's `warning` and `serious`
/// steps sit ΔE 13.6 apart in normal vision — below the 15 floor, so seating them
/// as adjacent grades would give two levels most people cannot tell apart. Three
/// well-separated hues carry the grade; the label carries the finer distinction
/// between "almost out" and "out".
public enum Severity: Sendable, CaseIterable, Equatable {
    case healthy    // < 50%
    case watch      // 50-84%
    case urgent     // >= 85%

    public init(percent: Double) {
        switch percent {
        case ..<50: self = .healthy
        case ..<85: self = .watch
        default: self = .urgent
        }
    }

    /// Fixed status tokens — never themed, never reused for identity.
    public var color: Color {
        switch self {
        case .healthy: Color(red: 0.047, green: 0.639, blue: 0.047)  // #0ca30c
        case .watch:   Color(red: 0.980, green: 0.698, blue: 0.098)  // #fab219
        case .urgent:  Color(red: 0.816, green: 0.231, blue: 0.231)  // #d03b3b
        }
    }

    /// Distinct shapes, so the grade survives grayscale, CVD and forced-colors.
    /// On the light surface `watch` measures 1.79:1 against the surface, so the
    /// icon and the printed number — not the hue — are what carry the reading.
    public var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .watch:   "exclamationmark.circle.fill"
        case .urgent:  "exclamationmark.triangle.fill"
        }
    }

    public var label: String {
        switch self {
        case .healthy: "여유"
        case .watch:   "주의"
        case .urgent:  "임박"
        }
    }

    /// "About to run out" and "out" need different words but not different hues:
    /// the grade count is capped at three by colour separation, so the wording
    /// carries the distinction the palette cannot.
    public static func label(for percent: Double) -> String {
        percent >= 100 ? "소진" : Severity(percent: percent).label
    }

    public static func symbol(for percent: Double) -> String {
        percent >= 100 ? "xmark.octagon.fill" : Severity(percent: percent).symbol
    }
}

public enum Countdown {
    /// "3시간 12분 후" — deliberately coarse, since the reset time only matters
    /// at the granularity of "can I keep working right now".
    public static func text(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "초기화됨" }
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)일 \(hours)시간 후" }
        if hours > 0 { return "\(hours)시간 \(minutes)분 후" }
        return "\(minutes)분 후"
    }

    /// Compact form for the widget, where the row has no space for two units.
    public static func short(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "초기화됨" }
        let minutes = Int(seconds) / 60
        if minutes >= 1440 { return "\(minutes / 1440)일 후" }
        if minutes >= 60 { return "\(minutes / 60)시간 후" }
        return "\(minutes)분 후"
    }
}

// MARK: - Meter

/// A single ratio against a limit. The fill carries severity and the track is the
/// same hue held back, so the grade reads across the whole bar rather than only
/// across the filled part.
public struct QuotaMeter: View {
    private let percent: Double
    private let height: CGFloat
    private let monochrome: Bool

    public init(percent: Double, height: CGFloat = 5, monochrome: Bool = false) {
        self.percent = percent
        self.height = height
        self.monochrome = monochrome
    }

    /// In a desaturating render mode the hue is gone, so the fill has to be the
    /// full-strength tint rather than a status colour: the system maps colours by
    /// luminance, and a mid-luminance green lands on the same grey as the 20%
    /// track — which is exactly how the bar came to read as one flat block.
    private var inkColor: Color {
        monochrome ? .primary : Severity(percent: percent).color
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(inkColor.opacity(monochrome ? 0.22 : 0.20))
                if percent > 0 {
                    // Floor the fill at its own height so a 1% reading is still a
                    // visible mark rather than a sliver that rounds away.
                    Capsule()
                        .fill(inkColor)
                        .frame(width: max(height, geo.size.width * min(percent, 100) / 100))
                }
            }
        }
        .frame(height: height)
    }
}

/// Icon + label + hue. The three always travel together: the status palette is
/// sub-3:1 on the light surface by design, and hue alone is never the encoding.
public struct StatusChip: View {
    private let percent: Double
    private let compact: Bool
    private let monochrome: Bool

    public init(percent: Double, compact: Bool = false, monochrome: Bool = false) {
        self.percent = percent
        self.compact = compact
        self.monochrome = monochrome
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Severity.symbol(for: percent))
                .font(.system(size: compact ? 8 : 10, weight: .semibold))
            if !compact {
                Text(Severity.label(for: percent))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(monochrome ? Color.primary : Severity(percent: percent).color)
    }
}

// MARK: - Snapshot helpers

public extension AccountSnapshot {
    var severity: Severity { Severity(percent: headlinePercent ?? 0) }

    /// What the menu bar shows when this account is the one in use.
    var compactLabel: String {
        guard let percent = headlinePercent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    /// Which window is driving the headline — worth naming, since "73%" means
    /// something very different for a 5-hour window than for a weekly one.
    var headlineWindowName: String? {
        guard let headline = headlinePercent else { return nil }
        if weeklyPercent == headline { return "주간" }
        if fiveHourPercent == headline { return "5시간" }
        return nil
    }
}

public extension SharedStateFile {
    /// The account to switch to when the current one runs dry: most headroom,
    /// excluding anything that failed to poll.
    var mostHeadroom: AccountSnapshot? {
        accounts
            .filter { $0.error == nil }
            .min { ($0.headlinePercent ?? 100) < ($1.headlinePercent ?? 100) }
    }

    var activeAccount: AccountSnapshot? {
        accounts.first { $0.isActive }
    }
}
