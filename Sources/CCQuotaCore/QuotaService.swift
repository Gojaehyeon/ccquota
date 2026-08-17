import Foundation

/// Polls every registered account and produces the snapshots the CLI, the menu
/// bar app and the widget all render from.
public struct QuotaService: Sendable {
    public init() {}

    /// Works out which registered account `claude` is currently logged in as.
    ///
    /// It used to also copy the live credential into that account's entry, which
    /// quietly undid the whole point of browser authorisation: within one poll a
    /// browser-granted account was sharing `claude`'s token pair again, and the
    /// two sides resumed rotating each other's tokens out from under one another.
    /// Identification is all that is wanted here. Only an account that was copied
    /// from the Keychain in the first place has anything to re-adopt.
    @discardableResult
    public func syncActiveFromKeychain(_ store: inout AccountStore) async -> Bool {
        guard let live = try? Keychain.readLiveCredential(),
              let liveOAuth = live.oauth else { return false }

        // Tokens rotate, so a fingerprint match only ever confirms; it never
        // rules out. What it does buy is skipping the profile request while the
        // live credential is unchanged, which is most of the time.
        let fingerprint = liveOAuth.refreshToken
        let unchanged = store.lastSeenKeychainToken == fingerprint

        var matched = store.accounts.first {
            $0.blob.oauth?.refreshToken == fingerprint
                || $0.blob.oauth?.accessToken == liveOAuth.accessToken
        }
        if matched == nil, unchanged, let active = store.active {
            matched = store[active]
        }
        if matched == nil, !store.accounts.isEmpty,
           let profile = try? await ClaudeAPI.fetchProfile(accessToken: liveOAuth.accessToken) {
            matched = store.accounts.first { $0.accountUUID == profile.uuid }
        }

        guard let entry = matched else {
            store.active = nil
            store.lastSeenKeychainToken = fingerprint
            return false
        }

        // Re-adopt only for an account that is a copy of the live login anyway.
        // Doing it for a browser grant would replace a credential this tool owns
        // with one it must share.
        if entry.credentialSource == .keychain {
            store[entry.label] = AccountStore.Entry(
                label: entry.label, blob: live, tier: liveOAuth.rateLimitTier ?? entry.tier,
                accountUUID: entry.accountUUID, email: entry.email,
                refreshBlockedUntil: nil, source: .keychain)
        }
        store.active = entry.label
        store.lastSeenKeychainToken = fingerprint
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

        // Never ask the auth endpoint again while a rejection stands. Only a
        // re-registration can fix it, and hammering it is what made a dead
        // credential look like a two-day rate limit.
        if let blocked = entry.refreshBlockedUntil, blocked > Date() {
            throw CredentialRejected(label: entry.label)
        }

        if let refreshExpiry = oauth.refreshTokenExpiresAt,
           Date(timeIntervalSince1970: refreshExpiry / 1000) < Date() {
            throw CCError("리프레시 토큰이 만료되었습니다. `ccquota add \(entry.label)`로 다시 등록하십시오.")
        }

        let result = try await ClaudeAPI.refresh(refreshToken: oauth.refreshToken, label: entry.label)
        oauth.accessToken = result.accessToken
        oauth.refreshToken = result.refreshToken
        oauth.expiresAt = result.expiresAtMillis

        var blob = entry.blob
        try blob.setOAuth(oauth)
        // Carrying `source` forward matters: losing it would silently reclassify
        // a browser grant as a Keychain copy on its first refresh, and the next
        // poll would go back to overwriting it with the live login.
        let updated = AccountStore.Entry(label: entry.label, blob: blob, tier: entry.tier,
                                         accountUUID: entry.accountUUID, email: entry.email,
                                         refreshBlockedUntil: nil,
                                         source: entry.credentialSource)

        // Only a Keychain-copied account shares its pair with `claude`, so only
        // that one needs the rotated pair pushed back. Writing a browser grant
        // into the live login would hand `claude` a credential it never asked
        // for and does not track.
        if isActive, entry.credentialSource == .keychain,
           let live = try? Keychain.readLiveCredential(),
           let merged = try? live.replacingOAuth(from: blob) {
            try? Keychain.writeLiveCredential(merged)
        }
        return (result.accessToken, updated)
    }

    private struct PollResult {
        var snapshot: AccountSnapshot
        var updatedEntry: AccountStore.Entry?
        var wasRateLimited: Bool
        /// Seconds the server itself asked us to wait, when it said so.
        var retryAfterHint: Double?
        var limitScope: RateLimited.Scope?
    }

    private func snapshot(for entry: AccountStore.Entry, isActive: Bool) async -> PollResult {
        var snap = AccountSnapshot(label: entry.label, isActive: isActive)
        snap.plan = entry.blob.oauth?.subscriptionType
        snap.tier = entry.tier ?? entry.blob.oauth?.rateLimitTier

        do {
            var (token, updated) = try await freshToken(for: entry, isActive: isActive)

            // Backfill anything an older registration is missing: the account
            // identity that duplicate detection needs, and the plan and tier
            // that `claude` reads back out of a switched-in credential. Without
            // the latter a switch reads as a logout, so repairing here saves the
            // user re-authorising every account by hand.
            let current = updated ?? entry
            let needsIdentity = current.accountUUID == nil
            let needsPlan = current.blob.oauth?.subscriptionType == nil
                || current.blob.oauth?.refreshTokenExpiresAt == nil
            if needsIdentity || needsPlan {
                let profile = try await ClaudeAPI.fetchProfile(accessToken: token)
                var base = current
                base.accountUUID = profile.uuid
                base.email = profile.email
                base.tier = profile.rateLimitTier ?? base.tier
                base.source = base.credentialSource
                if needsPlan, var oauth = base.blob.oauth {
                    oauth.subscriptionType = profile.subscriptionType
                    oauth.rateLimitTier = profile.rateLimitTier
                    if oauth.scopes?.isEmpty ?? true {
                        oauth.scopes = OAuthFlow.grantedScopes
                    }
                    if oauth.refreshTokenExpiresAt == nil {
                        // The issue time is not recoverable for an older entry, so
                        // this takes `claude`'s own lifetime from now. Overshooting
                        // only risks one refusal that already reports itself
                        // clearly; undershooting would block a working token.
                        oauth.refreshTokenExpiresAt = Date()
                            .addingTimeInterval(60 * 60 * 24 * 27).timeIntervalSince1970 * 1000
                    }
                    var blob = base.blob
                    try blob.setOAuth(oauth)
                    base.blob = blob
                }
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
            let limited = error as? RateLimited

            // Record the rejection so the next poll skips the request entirely.
            var blocked: AccountStore.Entry?
            if error is CredentialRejected, entry.refreshBlockedUntil == nil {
                var marked = entry
                marked.refreshBlockedUntil = Date().addingTimeInterval(3600)
                blocked = marked
            }

            return PollResult(snapshot: snap, updatedEntry: blocked,
                              wasRateLimited: limited != nil,
                              retryAfterHint: limited?.retryAfterSeconds,
                              limitScope: limited?.scope)
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
            // Clear the published figures before bailing out. Throwing without
            // doing so left the widget rendering percentages for accounts that
            // no longer exist, with nothing that would ever overwrite them.
            try? SharedState.write(SharedStateFile(updatedAt: Date(), accounts: []))
            throw CCError("등록된 계정이 없습니다. 설정에서 브라우저 승인으로 등록하십시오.")
        }

        // Repair what can be repaired locally, before anything else. `claude`
        // reads `scopes` back out of a credential to decide it is a usable
        // login, so an entry without it switches in as "not logged in" — and
        // the value needs no request, since it is the set we asked for.
        var repaired = false
        for entry in store.accounts {
            guard var oauth = entry.blob.oauth, oauth.scopes?.isEmpty ?? true else { continue }
            oauth.scopes = OAuthFlow.grantedScopes
            var fixed = entry
            var blob = entry.blob
            try? blob.setOAuth(oauth)
            fixed.blob = blob
            store[entry.label] = fixed
            repaired = true
        }
        if repaired { try? store.save() }

        let previous = SharedState.read()
        if !force, let cached = previous, cached.isRateLimited {
            // Serving the cache is the whole point of the backoff: another
            // request now would extend the limit rather than resolve it.
            return cached
        }

        // Persisting this is what keeps the active account off the refresh
        // endpoint entirely: `claude` already keeps that token fresh, so adopting
        // it means zero refreshes for whichever account is in use.
        let synced = await syncActiveFromKeychain(&store)
        if synced { try? store.save() }
        let active = store.active

        // Sequential, not concurrent: the spacing between requests matters more
        // than the few seconds saved, and three accounts still finish in ~5s.
        var results: [PollResult] = []
        var rateLimited = false
        var serverHint: Double?
        var limitScope: RateLimited.Scope = .usage
        for (index, entry) in store.accounts.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.requestSpacing) }
            let result = await snapshot(for: entry, isActive: entry.label == active)
            // Only a genuine usage-endpoint rate limit stops the sweep. A
            // rejected credential belongs to one account, and cutting the sweep
            // short for it meant a single dead token hid every healthy account
            // behind it — including the one that would have worked.
            if result.wasRateLimited {
                rateLimited = true
                if let hint = result.retryAfterHint {
                    serverHint = max(serverHint ?? 0, hint)
                }
                limitScope = result.limitScope ?? .usage
                results.append(result)
                for remaining in store.accounts.dropFirst(index + 1) {
                    var skipped = AccountSnapshot(label: remaining.label,
                                                  isActive: remaining.label == active)
                    skipped.plan = remaining.blob.oauth?.subscriptionType
                    skipped.tier = remaining.tier
                    skipped.email = remaining.email
                    skipped.isStale = true
                    results.append(PollResult(snapshot: skipped, updatedEntry: nil,
                                              wasRateLimited: false, retryAfterHint: nil,
                                              limitScope: nil))
                }
                break
            }
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
            let failed = snapshot.error != nil || snapshot.isStale
            guard failed,
                  let old = previous?.accounts.first(where: { $0.label == snapshot.label }),
                  old.headlinePercent != nil else { return snapshot }
            var carried = old
            carried.isActive = snapshot.isActive
            // A rate limit is reported once, by `retryAfter` on the file. Only a
            // fault specific to this account — an expired login, a missing
            // credential — earns a message on its own row.
            // A rate limit is reported once, by `retryAfter` on the file. A
            // rejected credential is this account's own problem and needs to be
            // said on its row, because only the user can fix it.
            carried.error = result.wasRateLimited ? nil : snapshot.error
            carried.isStale = true
            return carried
        }

        // Back off geometrically while the limit persists, and clear it the
        // moment a poll gets through.
        var strikes = 0
        var retryAfter: Date?
        if rateLimited {
            strikes = (previous?.rateLimitStrikes ?? 0) + 1
            let schedule = RateLimited(scope: limitScope, retryAfterSeconds: nil).backoffSchedule
            let backoff = min(schedule.first * pow(2, Double(strikes - 1)), schedule.cap)
            retryAfter = Date().addingTimeInterval(max(backoff, serverHint ?? 0))
        }

        let state = SharedStateFile(updatedAt: Date(), accounts: merged,
                                    retryAfter: retryAfter, rateLimitStrikes: strikes)
        try? SharedState.write(state)
        return state
    }

    // MARK: - Registration and switching

    /// Registers an account from a browser authorisation instead of from the
    /// Keychain. The resulting grant is CCQuota's own, so `claude` logging in or
    /// out later cannot invalidate it — which is the failure the Keychain route
    /// cannot avoid, since both sides then share and rotate one token pair.
    /// `label` is optional: with nothing given the name comes from the account
    /// itself, which is one less thing to invent and one less way to end up with
    /// two labels that mean the same account.
    @discardableResult
    public func addAccount(label: String?, oauth: ClaudeAiOAuth) async throws -> String {
        let profile = try await ClaudeAPI.fetchProfile(accessToken: oauth.accessToken)

        var store = try AccountStore.load()
        if let clash = store.accounts.first(where: { $0.accountUUID == profile.uuid }) {
            throw CCError("이 계정(\(profile.email ?? profile.uuid))은 이미 '\(clash.label)'로 등록되어 있습니다.")
        }
        let label = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? AccountNaming.suggestedLabel(email: profile.email, uuid: profile.uuid,
                                            taken: store.accounts.map(\.label))

        // `claude` reads the plan and tier back out of the stored credential, so
        // a blob without them is one it treats as not signed in — the switch
        // appeared to log the user out rather than change accounts.
        var complete = oauth
        complete.subscriptionType = profile.subscriptionType
        complete.rateLimitTier = profile.rateLimitTier

        var blob = try Keychain.emptyBlob()
        try blob.setOAuth(complete)
        store[label] = AccountStore.Entry(label: label, blob: blob,
                                          tier: profile.rateLimitTier,
                                          accountUUID: profile.uuid, email: profile.email,
                                          refreshBlockedUntil: nil, source: .browser)
        try store.save()
        return label
    }

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
                                          accountUUID: profile.uuid, email: profile.email,
                                          refreshBlockedUntil: nil, source: .keychain)
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

        // Graft the target credential onto the live blob instead of replacing it.
        // A wholesale write dropped the `mcpOAuth` section, losing every MCP
        // server `claude` had authorised.
        let merged = (try? Keychain.readLiveCredential().replacingOAuth(from: target.blob))
            ?? target.blob
        try Keychain.writeLiveCredential(merged)
        store.active = label
        try store.save()
    }
}
