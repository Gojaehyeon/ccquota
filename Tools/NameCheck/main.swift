import CCQuotaCore
import Foundation

// Unbuffered, so a hang still shows everything printed up to the point it stuck.
setvbuf(stdout, nil, _IONBF, 0)

/// Counter lives in a final class so both the top-level checks and the detached
/// task that plays the browser can record into the same tally.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var failures = 0
    func check(_ ok: Bool, _ label: String) {
        lock.lock(); defer { lock.unlock() }
        print("\(ok ? "✓" : "✗") \(label)")
        if !ok { failures += 1 }
    }
}
let tally = Tally()
func check(_ ok: Bool, _ label: String) { tally.check(ok, label) }

// MARK: - Naming

let namingCases: [(email: String?, expected: String)] = [
    ("tntlabgo@gmail.com", "tntlabgo"),
    ("teamtntlabs@gmail.com", "teamtntlabs"),
    ("admin@limboart.com", "limboart"),
    ("go@example.co.kr", "example"),
    ("Some.Name+tag@icloud.com", "some-name-tag"),
    (nil, "account-dab5d7"),
]
print("== 이름 규칙 ==")
for c in namingCases {
    let got = AccountNaming.suggestedLabel(email: c.email, uuid: "dab5d7b6-91d9-4bc4")
    check(got == c.expected, "\(c.email ?? "(이메일 없음)") → \(got)")
}
check(AccountNaming.suggestedLabel(email: "tntlabgo@gmail.com", uuid: "x",
                                   taken: ["tntlabgo"]) == "tntlabgo-2", "중복 회피")

// MARK: - Loopback callback

print("\n== 로컬 콜백 ==")
let listener = try CallbackListener()
print("   redirect_uri = \(listener.redirectURI)")

// Drive the listener exactly as the browser would, so the whole path is covered:
// bind, receive the redirect, parse it, answer with a page, hand back the code.
Task.detached {
    try? await Task.sleep(for: .milliseconds(300))
    var request = URLRequest(url: URL(string: listener.redirectURI + "?code=TESTCODE&state=TESTSTATE")!)
    request.timeoutInterval = 5
    if let (data, _) = try? await URLSession.shared.data(for: request) {
        let page = String(data: data, encoding: .utf8) ?? ""
        check(page.contains("승인이 완료되었습니다"), "브라우저에 완료 페이지 반환")
    } else {
        check(false, "콜백 요청 전송")
    }
}

do {
    let result = try await listener.waitForCode(timeout: 10)
    check(result.code == "TESTCODE", "코드 수신 → \(result.code)")
    check(result.state == "TESTSTATE", "state 수신 → \(result.state ?? "nil")")
} catch {
    check(false, "콜백 대기: \(error.localizedDescription)")
}
listener.stop()

// MARK: - Authorize URL

print("\n== authorize URL ==")
let pending = try OAuthFlow.begin(redirectURI: "http://localhost:12345/callback")
let url = pending.url.absoluteString
check(url.contains("code_challenge_method=S256"), "PKCE S256 포함")
check(url.contains("localhost:12345"), "리다이렉트 반영")
check(!url.contains(pending.verifier.prefix(10) + "&code_challenge"), "verifier 는 URL 에 노출되지 않음")

print(tally.failures == 0 ? "\n전부 통과" : "\n실패 \(tally.failures)건")
exit(tally.failures == 0 ? 0 : 1)
