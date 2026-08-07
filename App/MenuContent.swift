import CCQuotaCore
import SwiftUI

struct MenuContent: View {
    @Bindable var model: QuotaModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let accounts = model.state?.accounts, !accounts.isEmpty {
                VStack(spacing: 14) {
                    ForEach(accounts) { account in
                        AccountRow(account: account) {
                            Task { await model.switchTo(account.label) }
                        }
                    }
                }
                recommendation
            } else {
                emptyState
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task { model.start() }
    }

    private var header: some View {
        HStack {
            Text("Claude Max 한도").font(.headline)
            Spacer()
            // The button stays put while refreshing rather than being swapped
            // for a spinner: a control that vanishes for several seconds reads
            // as the app being stuck, and it left nothing to click.
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(model.isRefreshing ? 0 : 1)
                    .overlay {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(model.isRefreshing ? "갱신 중" : "지금 갱신")
        }
    }

    @ViewBuilder
    private var recommendation: some View {
        if let best = model.state?.mostHeadroom, !best.isActive,
           let percent = best.headlinePercent {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                Text("여유 최다: **\(best.label)** (\(Int(percent))%)")
                Spacer()
                Button("전환") { Task { await model.switchTo(best.label) } }
                    .controlSize(.small)
            }
            .font(.caption)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("등록된 계정이 없습니다.").font(.callout)
            Text("설정에서 계정을 등록하십시오.")
                .font(.caption).foregroundStyle(.secondary)
            Button("설정 열기", action: openSettings)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("설정…", action: openSettings)
                .controlSize(.small)

            Spacer()

            if let updated = model.state?.updatedAt {
                Text(updated, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button("종료") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }

    /// An accessory app has no Dock icon to click, so the window would open
    /// behind whatever is in front without an explicit activation.
    private func openSettings() {
        openWindow(id: SettingsWindowID.value)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AccountRow: View {
    let account: AccountSnapshot
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.isActive ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                Text(account.label).font(.system(.body, weight: .semibold))
                if let plan = account.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if account.isActive {
                    Text("사용 중").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("전환", action: onSwitch).controlSize(.small)
                }
            }

            if let error = account.error {
                Text(account.isStale ? "\(error) — 이전 값 표시 중" : error)
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if account.error == nil || account.isStale {
                MeterRow(title: "5시간", percent: account.fiveHourPercent, resets: account.fiveHourResetsAt)
                MeterRow(title: "주간", percent: account.weeklyPercent, resets: account.weeklyResetsAt)
                ForEach(account.scopedWeekly, id: \.model) { scoped in
                    MeterRow(title: scoped.model, percent: scoped.percent,
                             resets: scoped.resetsAt, indented: true)
                }
            }
        }
    }
}

private struct MeterRow: View {
    let title: String
    let percent: Double?
    let resets: Date?
    var indented = false

    var body: some View {
        if let percent {
            HStack(spacing: 8) {
                Text(indented ? "└ \(title)" : title)
                    .font(.caption)
                    .foregroundStyle(indented ? .secondary : .primary)
                    .frame(width: 62, alignment: .leading)

                ProgressView(value: min(percent, 100), total: 100)
                    .tint(Severity(percent: percent).color)
                    .frame(height: 4)

                Text("\(Int(percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)

                Text(Countdown.text(until: resets))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
        }
    }
}
