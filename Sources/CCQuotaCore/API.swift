import Foundation

public enum ClaudeAPI {
    /// Claude Code's own OAuth client id — the refresh grant is rejected without it.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let betaHeader = "oauth-2025-04-20"

    /// A 401 here is not transient — the stored token has been superseded, and
    /// only a fresh login can replace it. Say what to do, not just what failed.
    static let reauthMessage =
        "인증 만료 — 이 계정으로 다시 로그인한 뒤 같은 이름으로 재등록하십시오."

    /// Sent on every usage call. Without a `claude-code/<version>` user agent the
    /// endpoint drops requests into an aggressively rate-limited bucket and
    /// returns persistent 429s.
    public static var userAgent: String {
        "claude-code/" + (installedClaudeCodeVersion ?? "2.1.223")
    }

    static let installedClaudeCodeVersion: String? = {
        guard let out = try? Shell.run("/bin/sh", ["-lc", "claude --version 2>/dev/null"]) else { return nil }
        // e.g. "2.1.223 (Claude Code)"
        return out.split(separator: " ").first.map(String.init)
    }()

    // MARK: - Usage

    public static func fetchUsage(accessToken: String) async throws -> UsageResponse {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CCError("usage 응답이 HTTP가 아닙니다.")
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        case 401:
            throw CCError(Self.reauthMessage)
        case 429:
            throw RateLimited(retryAfterSeconds: http.value(forHTTPHeaderField: "retry-after")
                .flatMap(Double.init))
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CCError("usage 요청 실패 (HTTP \(http.statusCode)): \(body.prefix(200))")
        }
    }

    // MARK: - Account identity

    public struct Profile: Sendable {
        public let uuid: String
        public let email: String?
    }

    /// The only reliable way to tell two registered accounts apart: tokens
    /// rotate, so a refresh token fingerprint says nothing about identity.
    public static func fetchProfile(accessToken: String) async throws -> Profile {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 429 { throw RateLimited(retryAfterSeconds: nil) }
        if code == 401 { throw CCError(Self.reauthMessage) }
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? [String: Any],
              let uuid = account["uuid"] as? String else {
            throw CCError("계정 정보를 확인하지 못했습니다 (HTTP \(code)).")
        }
        return Profile(uuid: uuid, email: account["email"] as? String)
    }

    // MARK: - Token refresh

    public struct RefreshResult: Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAtMillis: Double
    }

    public static func refresh(refreshToken: String) async throws -> RefreshResult {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anthropic", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CCError("토큰 갱신 실패 (HTTP \(code)): \(body.prefix(200))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw CCError("토큰 갱신 응답에 access_token이 없습니다.")
        }
        let newRefresh = (obj["refresh_token"] as? String) ?? refreshToken
        let expiresAt: Double
        if let ms = obj["expires_at"] as? Double {
            // Some responses report seconds, others milliseconds.
            expiresAt = ms > 1_000_000_000_000 ? ms : ms * 1000
        } else if let inSeconds = obj["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(inSeconds).timeIntervalSince1970 * 1000
        } else {
            expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        }
        return RefreshResult(accessToken: access, refreshToken: newRefresh, expiresAtMillis: expiresAt)
    }
}
