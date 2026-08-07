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

    public init(accounts: [AccountSnapshot]) { self.accounts = accounts }

    private var focus: AccountSnapshot? {
        accounts.first { $0.isActive } ?? displayOrder(accounts).first
    }

    public var body: some View {
        if let account = focus {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)

                Spacer(minLength: 0)

                // Hero figure: same sans as everything else, proportional digits.
                // Ink stays primary — the meters and the chip carry the hue.
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((account.headlinePercent ?? 0).rounded()))")
                        .font(.system(size: 44, weight: .semibold))
                    Text("%").font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .opacity(account.isStale ? 0.55 : 1)

                HStack(spacing: 4) {
                    StatusChip(percent: account.headlinePercent ?? 0)
                    Text(account.headlineWindowName.map { "· \($0) 사용" } ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                MeterRow(title: "5시간", percent: account.fiveHourPercent)
                MeterRow(title: "주간", percent: account.weeklyPercent)
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

    var body: some View {
        if let percent {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                QuotaMeter(percent: percent, height: 5)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .frame(width: 32, alignment: .trailing)
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

    public init(accounts: [AccountSnapshot], updatedAt: Date?) {
        self.accounts = accounts
        self.updatedAt = updatedAt
    }

    /// Four rows is what fits before the type would have to shrink below
    /// legibility. Anything beyond is counted in the footer rather than dropped
    /// silently — a widget that hides an account is worse than useless when the
    /// hidden one is the account you still had room on.
    private var visible: [AccountSnapshot] { Array(displayOrder(accounts).prefix(4)) }
    private var hidden: Int { max(0, accounts.count - 4) }

    private let nameWidth: CGFloat = 88
    private let valueWidth: CGFloat = 34

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

            if hidden > 0 {
                Text("외 \(hidden)개 계정 — 앱에서 확인")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Claude Max 한도").font(.system(size: 11, weight: .semibold))
            Spacer()
            if let updatedAt {
                Text(updatedAt, style: .time)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
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
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.tertiary)
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
                    .font(.system(size: 10, weight: account.isActive ? .semibold : .regular))
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
            QuotaMeter(percent: percent, height: 5)
                .opacity(stale ? 0.45 : 1)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .lineLimit(1).fixedSize()
                .foregroundStyle(stale ? .secondary : .primary)
                .frame(width: valueWidth, alignment: .trailing)
        } else {
            Color.clear.frame(height: 5)
            Text("—")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}
