import CCQuotaCore
import SwiftUI

/// Account management lives in a real window rather than the menu bar popover:
/// registering an account is a multi-step flow (log out of Claude Code, log in
/// as the next account, come back and name it) and a popover that dismisses on
/// every click elsewhere is the wrong container for it.
struct SettingsWindow: View {
    @Bindable var model: QuotaModel
    @State private var newLabel = ""
    @State private var registering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            registration
            Divider()
            accountList
            Divider()
            preferences
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - Registration

    private var registration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("계정 등록").font(.headline)

            Text("""
            Claude Code에 로그인된 계정을 CCQuota에 등록합니다. 계정마다 한 번씩만 하면 됩니다.

            1. 터미널에서 `claude` 실행 후 `/logout`
            2. 등록할 계정으로 다시 로그인
            3. 아래에 이름을 적고 등록
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("계정 이름 (예: main, work, alt)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(register)
                Button(registering ? "등록 중…" : "현재 로그인 계정 등록", action: register)
                    .buttonStyle(.borderedProminent)
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty || registering)
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func register() {
        let label = newLabel
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        registering = true
        Task {
            await model.registerCurrent(as: label)
            registering = false
            if model.lastError == nil { newLabel = "" }
        }
    }

    // MARK: - Accounts

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("등록된 계정").font(.headline)

            if let accounts = model.state?.accounts, !accounts.isEmpty {
                List {
                    ForEach(accounts) { account in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(account.isActive ? Color.accentColor : .clear)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.label).font(.body.weight(.medium))
                                // The email, not the tier: every account here is
                                // the same tier, so it distinguishes nothing.
                                Text(account.email ?? account.tier ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let percent = account.headlinePercent {
                                Text("\(Int(percent.rounded()))%")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(account.severity.color)
                                    .opacity(account.isStale ? 0.5 : 1)
                            }
                            if account.isActive {
                                Text("사용 중").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("전환") { Task { await model.switchTo(account.label) } }
                                    .controlSize(.small)
                            }
                            Button {
                                Task { await model.remove(account.label) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("등록 해제 (Claude Code 로그인은 그대로입니다)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            } else {
                Text("아직 등록된 계정이 없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Preferences

    private var preferences: some View {
        HStack {
            Picker("갱신 주기", selection: $model.interval) {
                Text("1분").tag(60.0)
                Text("3분").tag(180.0)
                Text("10분").tag(600.0)
            }
            .frame(width: 180)

            Spacer()

            if let retry = model.state?.retryAfter, retry > Date() {
                Label("요청 제한 — \(Countdown.text(until: retry)) 재개",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
    }
}
