import CryptoKit
import Foundation

/// Browser authorisation, so an account can be registered without routing
/// through `claude` at all.
///
/// The reason this matters is not convenience. Capturing the Keychain credential
/// means CCQuota and `claude` share one token pair, and refresh rotates it — so
/// whichever of the two refreshes second is holding a superseded token and gets
/// rejected. That is what killed two accounts and looked, for two days, like a
/// rate limit. A grant obtained here is CCQuota's own: `claude` can log in and
/// out as much as it likes without touching it.
public enum OAuthFlow {
    /// The subscription sign-in, which is what a Max account needs. The CLI
    /// carries both this and a `platform.claude.com/oauth/authorize` address and
    /// picks between them by login method — `claudeai` versus `console`. The
    /// console one opens the API-platform sign-in instead, which is the wrong
    /// door for a subscription and simply will not show the expected login.
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"

    /// Kept for the API-platform account type, not used by this tool.
    static let consoleAuthorizeURL = "https://platform.claude.com/oauth/authorize"
    public static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    /// The same scopes `claude` requests. Anything narrower would monitor fine
    /// but produce a credential that cannot be switched to, and switching is
    /// half the point of the tool.
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers"

    public struct Pending: Sendable {
        public let url: URL
        public let verifier: String
        public let state: String
        public let redirectURI: String
    }

    /// Builds the authorisation URL and the verifier that must survive until the
    /// code comes back. PKCE means the code alone is useless to anyone who
    /// intercepts it — only the holder of the verifier can redeem it.
    /// `redirectURI` defaults to the hosted page that shows a code to copy. Pass
    /// a loopback address to have the browser deliver the code straight back.
    public static func begin(redirectURI: String = OAuthFlow.redirectURI) throws -> Pending {
        let verifier = randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: ClaudeAPI.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        guard let url = components.url else {
            throw CCError("인증 URL을 만들지 못했습니다.")
        }
        return Pending(url: url, verifier: verifier, state: verifier, redirectURI: redirectURI)
    }

    /// The callback page presents the code as `code#state`. Accept either form,
    /// and trim what a paste from a browser tends to bring with it.
    public static func parsePasted(_ raw: String) -> (code: String, state: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        return (parts.first ?? trimmed, parts.count > 1 ? parts[1] : nil)
    }

    public static func exchange(code: String, pending: Pending) async throws -> ClaudeAiOAuth {
        var req = URLRequest(url: ClaudeAPI.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ClaudeAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": pending.redirectURI,
            "client_id": ClaudeAPI.clientID,
            "code_verifier": pending.verifier,
            "state": pending.state,
        ])
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CCError("인증 코드 교환에 실패했습니다 (HTTP \(status)). "
                          + "코드는 한 번만 쓸 수 있고 곧 만료되니 다시 시도하십시오. \(body.prefix(160))")
        }

        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return ClaudeAiOAuth(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
            refreshTokenExpiresAt: nil,
            subscriptionType: nil,
            rateLimitTier: nil
        )
    }

    /// The whole flow: open the browser, wait for the redirect, redeem the code.
    /// Falls back to the paste page when no loopback port can be opened, which is
    /// the only case where the user has to copy anything.
    public static func authorizeInBrowser() async throws -> ClaudeAiOAuth {
        guard let listener = try? CallbackListener() else {
            throw CCError("로컬 콜백 서버를 열지 못했습니다. 설정에서 코드 붙여넣기 방식을 사용하십시오.")
        }
        defer { listener.stop() }

        let pending = try begin(redirectURI: listener.redirectURI)
        try Shell.open(pending.url)

        let callback = try await listener.waitForCode()
        // PKCE already binds the code to this attempt; the state check catches a
        // redirect that belongs to some other authorisation entirely.
        if let returned = callback.state, returned != pending.state {
            throw CCError("승인 응답이 이 요청과 일치하지 않습니다. 다시 시도하십시오.")
        }
        return try await exchange(code: callback.code, pending: pending)
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URLEncoded()
    }
}

extension Data {
    /// base64url without padding, which is what PKCE requires.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Naming

public enum AccountNaming {
    /// Mail providers whose domain says nothing about the account. For these the
    /// local part is the distinguishing bit; for a domain the user owns, it is
    /// the domain. Applied to the accounts already registered here, this rule
    /// reproduces exactly the names that were chosen by hand:
    /// tntlabgo@gmail.com → tntlabgo, admin@limboart.com → limboart.
    static let genericProviders: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "yahoo.com", "proton.me",
        "protonmail.com", "naver.com", "daum.net", "hanmail.net", "kakao.com",
        "nate.com",
    ]

    /// Second-level suffixes that carry no identity, so `example.co.kr` names
    /// itself `example` rather than `co`.
    static let publicSecondLevels: Set<String> = ["co", "com", "ne", "or", "ac", "go"]

    public static func suggestedLabel(email: String?, uuid: String,
                                      taken: [String] = []) -> String {
        let base = derive(email: email, uuid: uuid)
        guard taken.contains(base) else { return base }
        // Collisions are rare but must not overwrite an existing account.
        for suffix in 2...99 where !taken.contains("\(base)-\(suffix)") {
            return "\(base)-\(suffix)"
        }
        return "\(base)-\(uuid.prefix(6))"
    }

    private static func derive(email: String?, uuid: String) -> String {
        guard let email, let at = email.firstIndex(of: "@") else {
            return "account-" + uuid.prefix(6)
        }
        let local = String(email[email.startIndex ..< at])
        let domain = String(email[email.index(after: at)...]).lowercased()

        let candidate: String
        if genericProviders.contains(domain) {
            candidate = local
        } else {
            var parts = domain.split(separator: ".").map(String.init)
            parts = Array(parts.dropLast())                       // drop the TLD
            if parts.count > 1, publicSecondLevels.contains(parts.last ?? "") {
                parts = Array(parts.dropLast())
            }
            candidate = parts.last ?? local
        }

        let cleaned = sanitize(candidate)
        return cleaned.isEmpty ? "account-" + uuid.prefix(6) : cleaned
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let lowered = raw.lowercased().map { allowed.contains($0) ? $0 : "-" }
        return String(lowered)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(24)
            .description
    }
}
