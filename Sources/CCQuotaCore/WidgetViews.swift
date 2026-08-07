import SwiftUI

// Widget body views live in the shared module so the exact same code can be
// rendered to an image for review — a widget cannot otherwise be inspected
// without installing it and hunting for it on the desktop.

/// The order accounts are shown in, everywhere. The account in use comes first
/// because it is the one being spent; the rest follow by headroom, so the best
/// account to switch to is always the row directly beneath it.
public func displayOrder(_ accounts: [AccountSnapshot]) -> [AccountSnapshot] {
    accounts.sorted { a, b in
        if a.isActive != b.isActive { return a.isActive }
        return (a.headlinePercent ?? 101) < (b.headlinePercent ?? 101)
    }
}

// MARK: - Small: one account, one hero figure

/// Small has room for one thing, so it shows the account in use as a stat tile:
/// the headline number large, and the two windows beneath it as meters.
public struct SmallView: View {
    let accounts: [AccountSnapshot]
    /// True when the system is rendering the widget desaturated — the macOS
    /// desktop does this whenever it is not the focused surface, which is most
    /// of the time. Hue carries nothing in that mode.
    let monochrome: Bool

    public init(accounts: [AccountSnapshot], monochrome: Bool = false) {
        self.accounts = accounts
        self.monochrome = monochrome
    }

    private var focus: AccountSnapshot? {
        accounts.first { $0.isActive } ?? displayOrder(accounts).first
    }

    public var body: some View {
        if let account = focus {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)

                Spacer(minLength: 0)

                // Hero figure: same sans as everything else, proportional digits.
                // Ink stays primary — the meters and the chip carry the hue.
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((account.headlinePercent ?? 0).rounded()))")
                        .font(.system(size: 48, weight: .semibold))
                    Text("%").font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .opacity(account.isStale ? 0.55 : 1)

                HStack(spacing: 4) {
                    StatusChip(percent: account.headlinePercent ?? 0, monochrome: monochrome)
                    Text(account.headlineWindowName.map { "· \($0) 사용" } ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                MeterRow(title: "5시간", percent: account.fiveHourPercent, monochrome: monochrome)
                MeterRow(title: "주간", percent: account.weeklyPercent, monochrome: monochrome)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Label, meter, value. The number is always printed beside the bar: the status
/// palette sits below 3:1 on the light surface, and a visible label is the
/// documented relief for that.
struct MeterRow: View {
    let title: String
    let percent: Double?
    var monochrome = false

    var body: some View {
        if let percent {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                QuotaMeter(percent: percent, height: 6, monochrome: monochrome)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.top, 5)
        }
    }
}

// MARK: - Medium: every account, as a small table

/// Medium fits all the accounts, which is the whole point of running several.
/// Laid out as a table with column headers — the headers double as the legend,
/// so which bar is which never depends on remembering an order.
public struct MediumView: View {
    let accounts: [AccountSnapshot]
    let updatedAt: Date?
    let monochrome: Bool

    public init(accounts: [AccountSnapshot], updatedAt: Date?, monochrome: Bool = false) {
        self.accounts = accounts
        self.updatedAt = updatedAt
        self.monochrome = monochrome
    }

    /// Four rows is what fits before the type would have to shrink below
    /// legibility. Anything beyond is counted in the footer rather than dropped
    /// silently — a widget that hides an account is worse than useless when the
    /// hidden one is the account you still had room on.
    private var visible: [AccountSnapshot] { Array(displayOrder(accounts).prefix(4)) }
    private var hidden: Int { max(0, accounts.count - 4) }

    private let nameWidth: CGFloat = 92
    private let valueWidth: CGFloat = 50

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            columnHeaders.padding(.top, 5)
            Divider().padding(.top, 2)

            // Rows share the remaining height evenly, so the card is filled at
            // two accounts and still legible at four.
            VStack(spacing: 0) {
                ForEach(visible) { account in
                    row(for: account)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if hidden > 0 {
                Text("외 \(hidden)개 계정 — 앱에서 확인")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Claude Max 한도").font(.system(size: 12, weight: .semibold))
            Spacer()
            if let updatedAt {
                Text(updatedAt, style: .time)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 6) {
            Text("계정").frame(width: nameWidth, alignment: .leading)
            Text("5시간").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: valueWidth)
            Text("주간").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: valueWidth)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func row(for account: AccountSnapshot) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                // The active account is marked by a filled dot AND by weight, so
                // the marker is never the only thing distinguishing the row.
                Circle()
                    .fill(account.isActive ? Color.accentColor : .clear)
                    .frame(width: 4, height: 4)
                Text(account.label)
                    .font(.system(size: 11.5, weight: account.isActive ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                // Deliberately no row-level status chip here. One chip has to
                // summarise two windows, so it ends up sitting beside a green
                // 5-hour bar while reporting a red weekly one. Each meter states
                // its own grade, with the number printed next to it.
            }
            .frame(width: nameWidth, alignment: .leading)

            cell(account.fiveHourPercent, stale: account.isStale)
            cell(account.weeklyPercent, stale: account.isStale)
        }
    }

    @ViewBuilder
    private func cell(_ percent: Double?, stale: Bool) -> some View {
        if let percent {
            QuotaMeter(percent: percent, height: 6, monochrome: monochrome)
                .opacity(stale ? 0.45 : 1)
            HStack(spacing: 2) {
                // Per-window, so it never contradicts the bar beside it — and it
                // is the only thing that survives the desaturated render mode,
                // where every bar is the same grey whatever its grade.
                if Severity(percent: percent) != .healthy {
                    Image(systemName: Severity.symbol(for: percent))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(monochrome ? Color.primary
                                                    : Severity(percent: percent).color)
                }
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(stale ? .secondary : .primary)
            }
            .opacity(stale ? 0.6 : 1)
            .frame(width: valueWidth, alignment: .trailing)
        } else {
            Color.clear.frame(height: 5)
            Text("—")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}

// MARK: - Large: every account with the detail the other sizes cannot fit

/// Large is the only size with room for the reset times, which is the other half
/// of the decision: "73% used" and "resets in 4 days" mean very different things
/// from "73% used" and "resets in 40 minutes".
public struct LargeView: View {
    let accounts: [AccountSnapshot]
    let updatedAt: Date?
    let monochrome: Bool

    public init(accounts: [AccountSnapshot], updatedAt: Date?, monochrome: Bool = false) {
        self.accounts = accounts
        self.updatedAt = updatedAt
        self.monochrome = monochrome
    }

    private var visible: [AccountSnapshot] { Array(displayOrder(accounts).prefix(4)) }
    private var hidden: Int { max(0, accounts.count - 4) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Max 한도").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider() }
                    section(for: account).frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if hidden > 0 {
                Text("외 \(hidden)개 계정 — 앱에서 확인")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(for account: AccountSnapshot) -> some View {
        // The per-model caps are a separate limit from the overall weekly one, so
        // they are worth the space whenever there is space. At four accounts the
        // extra row per section would push the last one off the card.
        AccountSection(account: account, monochrome: monochrome,
                       showsScopedCaps: visible.count <= 3)
            .padding(.vertical, 6)
    }
}

/// One account with its windows spelled out. Shared by the large and extra-large
/// families, which differ only in whether the per-model weekly caps fit.
struct AccountSection: View {
    let account: AccountSnapshot
    let monochrome: Bool
    let showsScopedCaps: Bool
    /// Labels are chosen by the user and can be near-identical (`tntlabgo` and
    /// `teamtntlabs` are different accounts). Where the space exists, the email
    /// is what actually tells them apart.
    var showsEmail: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(account.isActive ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
                Text(account.label)
                    .font(.system(size: 13, weight: account.isActive ? .semibold : .medium))
                    .lineLimit(1).truncationMode(.tail)
                if account.isActive {
                    Text("사용 중")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let headline = account.headlinePercent {
                    StatusChip(percent: headline, monochrome: monochrome)
                }
            }

            if showsEmail, let email = account.email {
                Text(email)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 10)
            }

            if let error = account.error, !account.isStale {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                DetailMeterRow(title: "5시간", percent: account.fiveHourPercent,
                               resets: account.fiveHourResetsAt,
                               stale: account.isStale, monochrome: monochrome)
                DetailMeterRow(title: "주간", percent: account.weeklyPercent,
                               resets: account.weeklyResetsAt,
                               stale: account.isStale, monochrome: monochrome)
                if showsScopedCaps {
                    // The per-model weekly caps exist on every account but fit
                    // nowhere smaller. They are a separate limit from the overall
                    // weekly one, so an account can be fine on one and out on the other.
                    ForEach(account.scopedWeekly, id: \.model) { scoped in
                        DetailMeterRow(title: "└ \(scoped.model)", percent: scoped.percent,
                                       resets: scoped.resetsAt,
                                       stale: account.isStale, monochrome: monochrome,
                                       indented: true)
                    }
                }
            }
        }
    }
}

/// The large-size row: label, meter, value, and the reset time the smaller
/// families have to leave out.
private struct DetailMeterRow: View {
    let title: String
    let percent: Double?
    let resets: Date?
    let stale: Bool
    let monochrome: Bool
    var indented = false

    var body: some View {
        if let percent {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: indented ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                QuotaMeter(percent: percent, height: 6, monochrome: monochrome)
                    .opacity(stale ? 0.45 : 1)

                HStack(spacing: 2) {
                    if Severity(percent: percent) != .healthy {
                        Image(systemName: Severity.symbol(for: percent))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(monochrome ? Color.primary
                                                        : Severity(percent: percent).color)
                    }
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .lineLimit(1).fixedSize()
                }
                .frame(width: 52, alignment: .trailing)

                Text(Countdown.short(until: resets))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

// MARK: - Extra large: two columns, every limit spelled out

/// The widest family macOS offers (682×345). The extra width buys two columns
/// rather than bigger type, and the extra room finally fits the per-model weekly
/// caps — a separate limit that no other size could show, and one an account can
/// hit while its overall weekly figure still looks healthy.
public struct ExtraLargeView: View {
    let accounts: [AccountSnapshot]
    let updatedAt: Date?
    let monochrome: Bool

    public init(accounts: [AccountSnapshot], updatedAt: Date?, monochrome: Bool = false) {
        self.accounts = accounts
        self.updatedAt = updatedAt
        self.monochrome = monochrome
    }

    private var visible: [AccountSnapshot] { Array(displayOrder(accounts).prefix(6)) }
    private var hidden: Int { max(0, accounts.count - 6) }

    /// Rows of two. Built explicitly rather than with a grid so each row can
    /// stretch to share the height evenly whatever the account count.
    private var rows: [[AccountSnapshot]] {
        stride(from: 0, to: visible.count, by: 2).map {
            Array(visible[$0 ..< min($0 + 2, visible.count)])
        }
    }

    private var recommendation: AccountSnapshot? {
        let usable = visible.filter { $0.error == nil && ($0.headlinePercent ?? 100) < 100 }
        guard let best = usable.min(by: { ($0.headlinePercent ?? 100) < ($1.headlinePercent ?? 100) }),
              !best.isActive else { return nil }
        return best
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.top, 5)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, pair in
                    if index > 0 { Divider() }
                    HStack(alignment: .center, spacing: 22) {
                        ForEach(pair) { account in
                            AccountSection(account: account, monochrome: monochrome,
                                           showsScopedCaps: true,
                                           showsEmail: visible.count <= 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Keeps a lone account in the left column at the same
                        // width as the paired rows above it.
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .padding(.vertical, 8)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if hidden > 0 {
                Text("외 \(hidden)개 계정 — 앱에서 확인")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Max 한도").font(.system(size: 15, weight: .semibold))

            if let best = recommendation, let percent = best.headlinePercent {
                Text("여유 최다 \(best.label) · \(Int(percent.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let updatedAt {
                Text(updatedAt, style: .time)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
