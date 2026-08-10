import Foundation

// MARK: - Claude Code credential blob
//
// On macOS the whole blob lives in the login Keychain as a generic password
// under service "Claude Code-credentials". It holds `claudeAiOauth` (the
// subscription tokens) plus any `mcpOAuth` entries, so we treat it as opaque
// JSON and swap it wholesale when switching accounts.

public struct ClaudeAiOAuth: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double            // epoch milliseconds
    public var refreshTokenExpiresAt: Double?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public var expiryDate: Date { Date(timeIntervalSince1970: expiresAt / 1000) }

    /// Refresh a couple of minutes early so a poll never races the expiry.
    public func isExpired(slack: TimeInterval = 120) -> Bool {
        expiryDate.timeIntervalSinceNow < slack
    }
}

/// A Claude Code credential blob. Held as canonical JSON `Data` rather than a
/// dictionary so the value stays `Sendable` and so unknown keys (`mcpOAuth`
/// entries, future fields) survive a read/modify/write round trip untouched.
public struct CredentialBlob: Sendable, Codable {
    public private(set) var json: Data

    public init(json: Data) throws {
        guard (try JSONSerialization.jsonObject(with: json)) is [String: Any] else {
            throw CCError("자격증명이 JSON 객체가 아닙니다.")
        }
        self.json = json
    }

    private func object() throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CCError("자격증명이 JSON 객체가 아닙니다.")
        }
        return obj
    }

    public var oauth: ClaudeAiOAuth? {
        guard let obj = try? object(),
              let sub = obj["claudeAiOauth"],
              let data = try? JSONSerialization.data(withJSONObject: sub) else { return nil }
        return try? JSONDecoder().decode(ClaudeAiOAuth.self, from: data)
    }

    public mutating func setOAuth(_ value: ClaudeAiOAuth) throws {
        var obj = try object()
        let data = try JSONEncoder().encode(value)
        obj["claudeAiOauth"] = try JSONSerialization.jsonObject(with: data)
        json = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    public func serialized() -> Data { json }
}

// MARK: - Usage API response

public struct UsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        resetsAt = DateParse.iso(try c.decodeIfPresent(String.self, forKey: .resetsAt))
    }

    public init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// One row of the `limits` array — this is where per-model weekly caps show up
/// (e.g. a `weekly_scoped` entry whose scope is Opus or Fable).
public struct UsageLimit: Decodable, Sendable {
    public let kind: String
    public let group: String?
    public let percent: Double?
    public let severity: String?
    public let resetsAt: Date?
    public let isActive: Bool?
    public let modelName: String?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
    private enum ScopeKeys: String, CodingKey { case model }
    private enum ModelKeys: String, CodingKey { case displayName = "display_name" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        resetsAt = DateParse.iso(try c.decodeIfPresent(String.self, forKey: .resetsAt))

        if let scope = try? c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope),
           let model = try? scope.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) {
            modelName = try? model.decodeIfPresent(String.self, forKey: .displayName)
        } else {
            modelName = nil
        }
    }
}

public struct UsageResponse: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }
}

// MARK: - What the UI layers consume

public struct AccountSnapshot: Codable, Sendable, Identifiable {
    public var id: String { label }

    public var label: String
    public var isActive: Bool
    public var plan: String?              // e.g. "max"
    public var tier: String?              // e.g. "default_claude_max_20x"
    /// Shown so two labels can be told apart by the account they really point at.
    public var email: String?

    public var fiveHourPercent: Double?
    public var fiveHourResetsAt: Date?
    public var weeklyPercent: Double?
    public var weeklyResetsAt: Date?
    /// Per-model weekly caps, keyed by model display name (Opus, Fable, ...).
    public var scopedWeekly: [ScopedUsage]
    /// Set when the last poll failed. Percentages may still be present, carried
    /// over from the previous successful poll — see `isStale`.
    public var error: String?
    /// True when the percentages shown are from an earlier poll than `updatedAt`.
    public var isStale: Bool = false
    /// When the displayed percentages were actually fetched. Stays put while a
    /// stale snapshot is carried forward, so the age of the data is always visible.
    public var dataAsOf: Date?

    public struct ScopedUsage: Codable, Sendable, Hashable {
        public var model: String
        public var percent: Double
        public var resetsAt: Date?
        public init(model: String, percent: Double, resetsAt: Date?) {
            self.model = model; self.percent = percent; self.resetsAt = resetsAt
        }
    }

    public init(label: String, isActive: Bool) {
        self.label = label
        self.isActive = isActive
        self.scopedWeekly = []
    }

    /// The number that actually decides whether you can keep working: whichever
    /// window is closest to its cap.
    public var headlinePercent: Double? {
        [fiveHourPercent, weeklyPercent].compactMap { $0 }.max()
    }

    public var isExhausted: Bool { (headlinePercent ?? 0) >= 100 }
}

/// The file the menu bar app writes and the widget reads. Percentages only —
/// no tokens ever cross into the widget's sandbox.
public struct SharedStateFile: Codable, Sendable {
    public var updatedAt: Date
    public var accounts: [AccountSnapshot]
    /// Set after a 429. Polls before this time reuse the cached snapshot instead
    /// of issuing requests, so a rate limit does not feed itself.
    public var retryAfter: Date?
    /// Consecutive rate-limited polls, used to lengthen the backoff.
    public var rateLimitStrikes: Int = 0

    public init(updatedAt: Date, accounts: [AccountSnapshot],
                retryAfter: Date? = nil, rateLimitStrikes: Int = 0) {
        self.updatedAt = updatedAt
        self.accounts = accounts
        self.retryAfter = retryAfter
        self.rateLimitStrikes = rateLimitStrikes
    }

    public var isRateLimited: Bool {
        (retryAfter.map { $0 > Date() }) ?? false
    }
}

// MARK: - Support

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct CCError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The stored refresh token no longer works. Waiting does not help: a login
/// elsewhere supersedes earlier tokens for that account, and the endpoint
/// reports the dead token as `rate_limit_error` rather than as an auth failure —
/// which is what made this look like a rate limit for two days.
public struct CredentialRejected: LocalizedError, Sendable {
    public let label: String
    public init(label: String) { self.label = label }
    public var errorDescription: String? {
        "저장된 토큰이 만료되었습니다 — 이 계정으로 로그인한 뒤 `ccquota add \(label)`로 재등록하십시오."
    }
}

/// Distinguished from a generic failure because it drives the backoff: polling
/// through a 429 is what keeps a rate limit alive.
public struct RateLimited: LocalizedError, Sendable {
    /// Which endpoint refused us. They behave very differently: the usage
    /// endpoint clears in minutes, while the OAuth token endpoint applies a
    /// block that has been observed to last most of a day. Backing off from the
    /// second on a minutes-long schedule keeps poking a door that stays shut.
    public enum Scope: Sendable { case usage, auth }

    public let scope: Scope
    public let retryAfterSeconds: Double?

    public init(scope: Scope, retryAfterSeconds: Double?) {
        self.scope = scope
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? {
        switch scope {
        case .usage: "요청 제한 (429) — 잠시 조회를 멈춥니다"
        case .auth:  "토큰 갱신이 요청 제한에 걸렸습니다 — 길게 물러섭니다"
        }
    }

    /// The token endpoint refuses even an invalid token, so the limit sits ahead
    /// of credential checks — it is scoped to the caller, not the account, and
    /// it is the same endpoint `claude` itself refreshes through. Retrying it
    /// briskly risks the user's own login, so this schedule is deliberately slow.
    public var backoffSchedule: (first: TimeInterval, cap: TimeInterval) {
        switch scope {
        case .usage: (300, 1800)          // 5분 → 30분
        case .auth:  (1800, 6 * 3600)     // 30분 → 6시간
        }
    }
}

enum DateParse {
    /// The API emits 6-digit fractional seconds, which the fractional-seconds
    /// option accepts; the plain pass covers responses without them.
    ///
    /// Formatters are built per call rather than cached: `ISO8601DateFormatter`
    /// is not `Sendable`, and a poll only parses a handful of timestamps.
    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: s) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
