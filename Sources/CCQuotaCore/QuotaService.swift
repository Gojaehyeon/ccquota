import Foundation

/// Polls every registered account and produces the snapshots the CLI, the menu
/// bar app and the widget all render from.
public struct QuotaService: Sendable {
    public init() {}

    /// Pulls the live Keychain credential back into the active account's stored
    /// snapshot. Claude Code rotates its access token roughly hourly, so without
    /// this the stored copy for the account you are actually using goes stale
    /// and every poll pays for an unnecessary refresh.
    @discardableResult
    public func syncActiveFromKeychain(_ store: inout AccountStore) async -> Bool {
        guard let live = try? Keychain.readLiveCredential(),
              let liveOAuth = live.oauth else { return false }

        // Fast path: the tokens still match a stored entry. There is deliberately
        // no fallback to "whatever `active` points at" — after a /logout and a
        // login as a different account, that fallback overwrites the stored entry
        // with someone else's credential, binding one label to two accounts.
        var matched = store.accounts.first {
            $0.blob.oauth?.refreshToken == liveOAuth.refreshToken
                || $0.blob.oauth?.accessToken == liveOAuth.accessToken
        }

        // Slow path: `/login` issues a brand new token pair, so a legitimate
        // re-login of a registered account matches nothing above. Identity has to
        // come from the account UUID, which survives any number of logins.
        if matched == nil, !store.accounts.isEmpty,
           let profile = try? await ClaudeAPI.fetchProfile(accessToken: liveOAuth.accessToken) {
            matched = store.accounts.first { $0.accountUUID == profile.uuid }
        }

        guard let entry = matched else {
            // Genuinely unknown — an account that was never registered. Leave the
            // store alone rather than guess which label it belongs to.
            store.active = nil
            return false
        }

        store[entry.label] = AccountStore.Entry(
            label: entry.label, blob: live, tier: liveOAuth.rateLimitTier ?? entry.tier,
            accountUUID: entry.accountUUID, email: entry.email)
        store.active = entry.label
        return true
    }

    /// Refreshes the stored token when it is at or near expiry. Returns the
    /// usable access token plus the entry to persist if anything changed.
    private func freshToken(for entry: AccountStore.Entry, isActive: Bool) async throws
        -> (token: String, updated: AccountStore.Entry?) {
        guard var oauth = entry.blob.oauth else {
            throw CCError("'\(entry.label)' 계정에 claudeAiOauth 정보가 없습니다.")
        }
        guard oauth.isExpired() else { return (oauth.accessToken, nil) }

        if let refreshExpiry = oauth.refreshTokenExpiresAt,
           Date(timeIntervalSince1970: refreshExpiry / 1000) < Date() {
            throw CCError("리프레시 토큰이 만료되었습니다. `ccquota add \(entry.label)`로 다시 등록하십시오.")
        }

        let result = try await ClaudeAPI.refresh(refreshToken: oauth.refreshToken)
        oauth.accessToken = result.accessToken
        oauth.refreshToken = result.refreshToken
        oauth.expiresAt = result.expiresAtMillis

        var blob = entry.blob
        try blob.setOAuth(oauth)
        let updated = AccountStore.Entry(label: entry.label, blob: blob, tier: entry.tier,
                                         accountUUID: entry.accountUUID, email: entry.email)

        // Refreshing rotates the token pair. If this is the account `claude` is
        // logged in as, its Keychain copy is now the superseded one, so push the
        // new pair back or the next `claude` run fails to authenticate.
        if isActive {
            try? Keychain.writeLiveCredential(blob)
        }
        return (result.accessToken, updated)
    }

    private struct PollResult {
        var snapshot: AccountSnapshot
        var updatedEntry: AccountStore.Entry?
        var wasRateLimited: Bool
    }

    private func snapshot(for entry: AccountStore.Entry, isActive: Bool) async -> PollResult {
        var snap = AccountSnapshot(label: entry.label, isActive: isActive)
        snap.plan = entry.blob.oauth?.subscriptionType
        snap.tier = entry.tier ?? entry.blob.oauth?.rateLimitTier

        do {
            var (token, updated) = try await freshToken(for: entry, isActive: isActive)

            // Backfill identity for accounts registered before it was recorded,
            // so duplicate detection covers them too.
            if (updated ?? entry).accountUUID == nil {
                let profile = try await ClaudeAPI.fetchProfile(accessToken: token)
                var base = updated ?? entry
                base.accountUUID = profile.uuid
                base.email = profile.email
                updated = base
            }
            snap.email = (updated ?? entry).email

            let usage = try await ClaudeAPI.fetchUsage(accessToken: token)

            snap.fiveHourPercent = usage.fiveHour?.utilization
            snap.fiveHourResetsAt = usage.fiveHour?.resetsAt
            snap.weeklyPercent = usage.sevenDay?.utilization
            snap.weeklyResetsAt = usage.sevenDay?.resetsAt

            // Per-model weekly caps arrive either as dedicated fields or as
            // scoped rows in `limits`; merge both, preferring the named rows.
            var scoped: [String: AccountSnapshot.ScopedUsage] = [:]
            if let opus = usage.sevenDayOpus?.utilization {
                scoped["Opus"] = .init(model: "Opus", percent: opus, resetsAt: usage.sevenDayOpus?.resetsAt)
            }
            if let sonnet = usage.sevenDaySonnet?.utilization {
                scoped["Sonnet"] = .init(model: "Sonnet", percent: sonnet, resetsAt: usage.sevenDaySonnet?.resetsAt)
            }
            for limit in usage.limits ?? [] where limit.kind == "weekly_scoped" {
                guard let model = limit.modelName, let percent = limit.percent else { continue }
                scoped[model] = .init(model: model, percent: percent, resetsAt: limit.resetsAt)
            }
            snap.scopedWeekly = scoped.values.sorted { $0.model < $1.model }
            snap.dataAsOf = Date()

            return PollResult(snapshot: snap, updatedEntry: updated, wasRateLimited: false)
        } catch {
            snap.error = error.localizedDescription
            return PollResult(snapshot: snap, updatedEntry: nil,
                              wasRateLimited: error is RateLimited)
        }
    }

    /// Gap left between per-account requests. Three accounts polled at once is a
    /// burst of three; spacing them keeps the average request rate below what
    /// the usage endpoint starts refusing.
    private static let requestSpacing: Duration = .milliseconds(1500)

    /// Polls every account and persists any refreshed tokens.
    ///
    /// `force` bypasses the 429 backoff — used only for an explicit manual
    /// refresh, never for the timer.
    public func poll(force: Bool = false) async throws -> SharedStateFile {
        var store = try AccountStore.load()
        guard !store.accounts.isEmpty else {
            throw CCError("등록된 계정이 없습니다. `ccquota add <이름>`으로 먼저 등록하십시오.")
        }

        let previous = SharedState.read()
        if !force, let cached = previous, cached.isRateLimited {
            // Serving the cache is the whole point of the backoff: another
            // request now would extend the limit rather than resolve it.
            return cached
        }

        await syncActiveFromKeychain(&store)
        let active = store.active

        // Sequential, not concurrent: the spacing between requests matters more
        // than the few seconds saved, and three accounts still finish in ~5s.
        var results: [PollResult] = []
        var rateLimited = false
        for (index, entry) in store.accounts.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.requestSpacing) }
            let result = await snapshot(for: entry, isActive: entry.label == active)
            if result.wasRateLimited { rateLimited = true }
            results.append(result)
        }

        var dirty = false
        for result in results {
            if let updated = result.updatedEntry { store[updated.label] = updated; dirty = true }
        }
        if dirty { try? store.save() }

        // A failed poll — a 429, a dropped connection — must not blank the
        // account. Carry the last known numbers forward, keeping `dataAsOf` at
        // the time they were really fetched, so the display degrades to "this
        // old" rather than to "unknown". Carrying continues across consecutive
        // failures: values with a visible age beat no values at all.
        let merged = results.map { result -> AccountSnapshot in
            let snapshot = result.snapshot
            guard snapshot.error != nil,
                  let old = previous?.accounts.first(where: { $0.label == snapshot.label }),
                  old.headlinePercent != nil else { return snapshot }
            var carried = old
            carried.isActive = snapshot.isActive
            carried.error = snapshot.error
            carried.isStale = true
            return carried
        }

        // Back off geometrically while the limit persists, and clear it the
        // moment a poll gets through.
        var strikes = 0
        var retryAfter: Date?
        if rateLimited {
            strikes = (previous?.rateLimitStrikes ?? 0) + 1
            let delay = min(300.0 * pow(2, Double(strikes - 1)), 1800)
            retryAfter = Date().addingTimeInterval(delay)
        }

        let state = SharedStateFile(updatedAt: Date(), accounts: merged,
                                    retryAfter: retryAfter, rateLimitStrikes: strikes)
        try? SharedState.write(state)
        return state
    }

    // MARK: - Registration and switching

    /// Captures whatever account is logged in right now under `label`.
    ///
    /// Identity comes from the profile endpoint, not from the token: registering
    /// one account twice under two labels makes the two entries rotate each
    /// other's tokens until both return 401.
    public func addCurrentAccount(label: String) async throws {
        let blob = try Keychain.readLiveCredential()
        guard let oauth = blob.oauth else {
            throw CCError("현재 Keychain 자격증명에 claudeAiOauth 정보가 없습니다. `claude` 로그인 상태를 확인하십시오.")
        }
        let profile = try await ClaudeAPI.fetchProfile(accessToken: oauth.accessToken)

        var store = try AccountStore.load()
        if let clash = store.accounts.first(where: {
            $0.accountUUID == profile.uuid && $0.label != label
        }) {
            throw CCError("""
                이 계정(\(profile.email ?? profile.uuid))은 이미 '\(clash.label)'로 등록되어 있습니다.
                같은 계정을 두 번 등록하면 토큰이 서로 무효화되어 양쪽 모두 401이 납니다.
                """)
        }
        store[label] = AccountStore.Entry(label: label, blob: blob, tier: oauth.rateLimitTier,
                                          accountUUID: profile.uuid, email: profile.email)
        store.active = label
        try store.save()
    }

    /// Swaps the live Keychain credential to `label`, first saving the current
    /// live credential back into whichever account owns it — otherwise the
    /// rotated access token for the outgoing account would be lost.
    public func switchTo(label: String) async throws {
        var store = try AccountStore.load()
        guard let target = store[label] else {
            let known = store.accounts.map(\.label).joined(separator: ", ")
            throw CCError("'\(label)' 계정이 없습니다. 등록된 계정: \(known.isEmpty ? "(없음)" : known)")
        }
        await syncActiveFromKeychain(&store)
        try Keychain.writeLiveCredential(target.blob)
        store.active = label
        try store.save()
    }
}
