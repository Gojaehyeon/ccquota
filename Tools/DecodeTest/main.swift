import CCQuotaCore
import Foundation
if let s = SharedState.read() {
    print("✓ 디코딩 성공 — 계정 \(s.accounts.count)개, updatedAt=\(s.updatedAt)")
    for a in s.accounts { print("   \(a.label) 5h=\(a.fiveHourPercent ?? -1) wk=\(a.weeklyPercent ?? -1)") }
} else {
    print("✗ SharedState.read() 가 nil — 위젯이 비는 원인")
}
print("containerURL:", SharedState.containerURL?.path ?? "nil (엔타이틀먼트 없음)")
print("fallbackURL :", SharedState.fallbackURL.path)
