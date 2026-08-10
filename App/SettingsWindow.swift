import CCQuotaCore
import SwiftUI

/// Account management lives in a real window rather than the menu bar popover:
/// registering an account is a multi-step flow (log out of Claude Code, log in
/// as the next account, come back and name it) and a popover that dismisses on
/// every click elsewhere is the wrong container for it.
struct SettingsWindow: View {
    @Bindable var model: QuotaModel
    @State private var newLabel = ""
    @State private var pastedCode = ""
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
            브라우저에서 승인하면 등록됩니다. 이름은 계정에서 가져오므로 정하실 필요가 없습니다.
            계정마다 한 번씩만 하면 됩니다.
            여기서 받은 토큰은 CCQuota 전용이라, 이후 claude에서 로그인하거나 로그아웃해도 영향받지 않습니다.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("브라우저에서 승인") { model.beginBrowserLogin() }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingLogin != nil)

            if model.pendingLogin != nil {
                HStack {
                    TextField("승인 후 표시되는 코드를 붙여넣으십시오", text: $pastedCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(completeLogin)
                    Button(registering ? "확인 중…" : "완료", action: completeLogin)
                        .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty || registering)
                    Button("취소") {
                        model.cancelBrowserLogin()
                        pastedCode = ""
                    }
                }
            }

            DisclosureGroup("claude 로그인에서 가져오기") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("현재 claude에 로그인된 계정의 자격증명을 복사합니다. 승인 절차가 없어 빠르지만, "
                         + "claude와 토큰 한 벌을 공유하므로 어느 한쪽이 갱신하면 다른 쪽이 무효화됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("이름", text: $newLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Button("현재 claude 로그인 계정 등록", action: register)
                            .controlSize(.small)
                            .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty || registering)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func completeLogin() {
        registering = true
        Task {
            await model.completeBrowserLogin(pastedCode: pastedCode)
            registering = false
            if model.lastError == nil { pastedCode = "" }
        }
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
                                // Value in text ink; the chip beside it carries
                                // the grade, with icon and word, never hue alone.
                                HStack(spacing: 5) {
                                    Text("\(Int(percent.rounded()))%")
                                        .font(.callout.monospacedDigit())
                                    StatusChip(percent: percent)
                                }
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
            Picker("유휴 시 갱신", selection: $model.interval) {
                Text("5분").tag(300.0)
                Text("15분").tag(900.0)
                Text("30분").tag(1800.0)
            }
            .frame(width: 200)
            .help("Claude를 쓰는 중에는 이 값과 무관하게 90초 안에 갱신됩니다")

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
