import CCQuotaCore
import Foundation

let usageText = """
ccquota — Claude Max 다중 계정 한도 모니터

  ccquota                     등록된 모든 계정의 잔여 한도 표시
  ccquota status              위와 동일
  ccquota json                기계 판독용 JSON 출력
  ccquota watch [초]          주기적 갱신 (기본 180초, 최소 60초)
  ccquota login [이름]        브라우저로 승인해 등록 (권장). 이름은 생략하면 계정에서 가져옵니다
  ccquota add <이름>          현재 claude 로그인 계정을 <이름>으로 등록
  ccquota list                등록된 계정 목록
  ccquota switch <이름>       로그인 계정 전환
  ccquota remove <이름>       등록 해제

전형적인 사용 흐름:
  ccquota login  →  ccquota login  →  ccquota login   (계정마다 한 번)

`login`은 계정마다 브라우저 승인을 한 번 받습니다. 받은 토큰은 CCQuota 전용이라
claude 로그인/로그아웃과 무관하게 유지됩니다. `add`는 claude의 자격증명을 복사하므로
양쪽이 한 벌을 공유하게 되고, 어느 한쪽이 갱신하면 다른 쪽이 무효화됩니다.
"""

// MARK: - Rendering

let ansi = isatty(fileno(stdout)) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

func color(_ text: String, _ code: String) -> String {
    ansi ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
}

/// Green under 50%, yellow to 80%, red past that — the point at which you want
/// to be switching accounts rather than discovering the wall mid-task.
func severityCode(_ percent: Double) -> String {
    switch percent {
    case ..<50: "32"
    case ..<80: "33"
    default: "31"
    }
}

func bar(_ percent: Double, width: Int = 20) -> String {
    let clamped = min(max(percent, 0), 100)
    let filled = Int((clamped / 100 * Double(width)).rounded())
    let body = String(repeating: "█", count: filled)
        + String(repeating: "░", count: width - filled)
    return color(body, severityCode(clamped))
}

func relative(_ date: Date?) -> String {
    guard let date else { return "—" }
    let seconds = date.timeIntervalSinceNow
    if seconds <= 0 { return "곧 초기화" }
    let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
    if hours >= 24 { return "\(hours / 24)일 \(hours % 24)시간 후" }
    if hours > 0 { return "\(hours)시간 \(minutes)분 후" }
    return "\(minutes)분 후"
}

func render(_ state: SharedStateFile) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    print(color("Claude Max 계정 한도  ", "1") + color("(\(stamp.string(from: state.updatedAt)) 기준)", "90"))
    print("")

    for account in state.accounts {
        let marker = account.isActive ? color("●", "36") : " "
        var title = "\(marker) \(color(account.label, "1"))"
        if let plan = account.plan { title += color("  \(plan)", "90") }
        if account.isActive { title += color("  ← 현재 로그인", "36") }
        print(title)

        // An account-specific fault is loud; staleness is a quiet footnote. But
        // it must still be said — without it there is no way to tell a figure
        // measured seconds ago from one measured three hours ago.
        if let error = account.error {
            print("    " + color("조회 실패: \(error)", "31"))
            if !account.isStale { print(""); continue }
        }
        if account.isStale {
            let age = account.dataAsOf.map { "\(max(1, Int(-$0.timeIntervalSinceNow) / 60))분 전 값" }
                ?? "이전 값"
            print("    " + color(age, "90"))
        }

        func row(_ name: String, _ percent: Double?, _ resets: Date?) {
            guard let percent else { return }
            let pct = String(format: "%5.1f%%", percent)
            print("    \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                  + "\(bar(percent)) \(color(pct, severityCode(percent)))"
                  + color("   \(relative(resets)) 초기화", "90"))
        }

        row("5시간", account.fiveHourPercent, account.fiveHourResetsAt)
        row("주간", account.weeklyPercent, account.weeklyResetsAt)
        for scoped in account.scopedWeekly {
            row("└ \(scoped.model)", scoped.percent, scoped.resetsAt)
        }
        print("")
    }

    // "한도 도달"과 "조회 실패"는 다른 상황이므로 구분해서 보고합니다.
    if let retry = state.retryAfter, retry > Date() {
        print(color("요청 제한으로 조회를 멈춘 상태입니다. \(relative(retry)) 재개 (`ccquota status --force`로 강제 조회).", "33"))
        print("")
    }

    let known = state.accounts.filter { $0.headlinePercent != nil }
    let usable = known.filter { !$0.isExhausted }
    if known.isEmpty {
        print(color("한도를 조회하지 못했습니다. 잠시 후 다시 시도하십시오.", "31"))
    } else if usable.isEmpty {
        print(color("조회된 계정이 모두 한도에 도달했습니다.", "31"))
    } else if let best = usable.min(by: { ($0.headlinePercent ?? 0) < ($1.headlinePercent ?? 0) }),
              !best.isActive {
        print(color("여유 최다: ", "90") + color(best.label, "1")
              + color(String(format: " (%.0f%%)", best.headlinePercent ?? 0), "90")
              + color("  →  ccquota switch \(best.label)", "36"))
    }
}

// MARK: - Commands

let service = QuotaService()
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((color("오류: ", "31") + message + "\n").data(using: .utf8)!)
    exit(1)
}

@MainActor
func requireLabel(_ verb: String) -> String {
    guard args.count >= 2, !args[1].isEmpty else { fail("계정 이름이 필요합니다: ccquota \(verb) <이름>") }
    return args[1]
}

do {
    switch command {
    case "-h", "--help", "help":
        print(usageText)

    case "login":
        // Name is optional — omitted, it comes from the account itself.
        let label = args.count >= 2 ? args[1] : nil
        print("브라우저에서 승인하십시오. 승인이 끝나면 자동으로 이어집니다…")
        let oauth = try await OAuthFlow.authorizeInBrowser()
        let registered = try await service.addAccount(label: label, oauth: oauth)
        print(color("✓", "32") + " '\(registered)' 계정을 등록했습니다. (CCQuota 전용 토큰)")

    case "add":
        let label = requireLabel("add")
        try await service.addCurrentAccount(label: label)
        print(color("✓", "32") + " 현재 로그인 계정을 '\(label)'로 등록했습니다.")

    case "list":
        // Reconcile against the Keychain first: the stored `active` label is
        // whatever was true at the last poll, and a `/login` since then would
        // leave it pointing at the wrong account.
        var store = try AccountStore.load()
        if await service.syncActiveFromKeychain(&store) { try? store.save() }
        if store.accounts.isEmpty {
            print("등록된 계정이 없습니다. `ccquota add <이름>`을 먼저 실행하십시오.")
        }
        for entry in store.accounts {
            let marker = entry.label == store.active ? color("●", "36") : " "
            let expiry = entry.blob.oauth.map {
                "토큰 만료 " + relative($0.expiryDate)
            } ?? "자격증명 없음"
            print("\(marker) \(entry.label.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                  + color("\(entry.email ?? "이메일 미확인")  \(expiry)", "90"))
        }
        for group in store.duplicateGroups {
            print("")
            print(color("경고: \(group.joined(separator: ", "))는 같은 계정입니다.", "31"))
            print(color("      중복 등록은 서로의 토큰을 무효화해 양쪽 다 401이 납니다. "
                        + "`ccquota remove \(group.dropFirst().joined(separator: " ")).`으로 정리하십시오.", "90"))
        }

    case "remove":
        let label = requireLabel("remove")
        var store = try AccountStore.load()
        guard store[label] != nil else { fail("'\(label)' 계정이 없습니다.") }
        store[label] = nil
        if store.active == label { store.active = nil }
        try store.save()
        print(color("✓", "32") + " '\(label)' 등록을 해제했습니다. (Keychain의 현재 로그인은 그대로입니다)")

    case "switch":
        let label = requireLabel("switch")
        try await service.switchTo(label: label)
        print(color("✓", "32") + " '\(label)' 계정으로 전환했습니다. 실행 중인 claude 세션은 재시작해야 적용됩니다.")

    case "json":
        let state = try await service.poll()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(state), encoding: .utf8) ?? "{}")

    case "watch":
        // 60s floor: the usage endpoint rate-limits aggressively and there is
        // nothing to see faster than that anyway.
        let interval = max(60.0, Double(args.count > 1 ? args[1] : "") ?? 180)
        while true {
            let state = try await service.poll()
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            render(state)
            print(color("\(Int(interval))초마다 갱신 · Ctrl-C 종료", "90"))
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

    case "status":
        render(try await service.poll(force: args.contains("--force")))

    default:
        // Bare `ccquota` lands here only if an unknown verb was passed.
        fail("알 수 없는 명령 '\(command)'\n\n\(usageText)")
    }
} catch {
    fail(error.localizedDescription)
}
