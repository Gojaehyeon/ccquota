import CCQuotaCore
import Foundation

// The rule has to reproduce the names that were chosen by hand for the accounts
// already registered here, or it is not the rule the user actually uses.
let cases: [(email: String?, expected: String)] = [
    ("tntlabgo@gmail.com", "tntlabgo"),
    ("teamtntlabs@gmail.com", "teamtntlabs"),
    ("admin@limboart.com", "limboart"),
    ("go@example.co.kr", "example"),
    ("Some.Name+tag@icloud.com", "some-name-tag"),
    (nil, "account-dab5d7"),
]
var failures = 0
for c in cases {
    let got = AccountNaming.suggestedLabel(email: c.email, uuid: "dab5d7b6-91d9-4bc4")
    let ok = got == c.expected
    if !ok { failures += 1 }
    print("\(ok ? "✓" : "✗") \(c.email ?? "(이메일 없음)") → \(got)\(ok ? "" : "  기대: \(c.expected)")")
}
let dup = AccountNaming.suggestedLabel(email: "tntlabgo@gmail.com", uuid: "x",
                                       taken: ["tntlabgo"])
print(dup == "tntlabgo-2" ? "✓ 중복 회피 → \(dup)" : "✗ 중복 회피 → \(dup)")
if dup != "tntlabgo-2" { failures += 1 }
print(failures == 0 ? "\n전부 통과" : "\n실패 \(failures)건")
