import SwiftUI

/// Shared between the menu bar app and the widget so a percentage never reads
/// as "fine" in one surface and "critical" in the other.
public enum Severity: Sendable {
    case normal, warning, critical

    public init(percent: Double) {
        switch percent {
        case ..<50: self = .normal
        case ..<80: self = .warning
        default: self = .critical
        }
    }

    public var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
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
}

public extension AccountSnapshot {
    var severity: Severity { Severity(percent: headlinePercent ?? 0) }

    /// What the menu bar shows when this account is the one in use.
    var compactLabel: String {
        guard let percent = headlinePercent else { return "—" }
        return "\(Int(percent.rounded()))%"
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
