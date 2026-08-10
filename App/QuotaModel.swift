import CCQuotaCore
import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class QuotaModel {
    private(set) var state: SharedStateFile?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    /// The idle heartbeat. Quota figures only move when Claude is used, so this
    /// is the rate at which the app re-checks numbers that cannot have changed —
    /// it exists to catch window resets and usage from another machine, nothing
    /// more. Actual work triggers a poll far sooner, via `Activity`.
    var interval: TimeInterval = 900 {
        didSet {
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval, forKey: "pollInterval")
            reschedule()
        }
    }

    private let service = QuotaService()
    private var task: Task<Void, Never>?
    /// When the last completed poll finished. Drives "is the cached data still
    /// good enough" so the UI can open instantly instead of re-fetching.
    private var lastPollAt: Date?
    /// How soon a poll follows detected activity. Long enough to let a burst of
    /// tool calls settle, short enough that the number is current by the time
    /// you look at the menu bar.
    private let activeInterval: TimeInterval = 90

    init() {
        let saved = UserDefaults.standard.double(forKey: "pollInterval")
        if saved >= 60 { interval = saved }
        state = SharedState.read()
        // Poll from launch, not from first menu open: with `.menuBarExtraStyle(.window)`
        // the content view is not built until the user clicks, so anything
        // started from its `.task` would leave the menu bar reading stale.
        reschedule()
    }

    /// Called when the menu opens. Deliberately does NOT force a poll: a full
    /// sweep of three accounts takes 5-13s, so refetching on every open left the
    /// header spinning for as long as the menu was worth looking at — and spent
    /// three requests to redisplay numbers that were at most one interval old.
    func start() {
        Task { await refreshIfStale() }
    }

    private func refreshIfStale() async {
        guard secondsUntilNextPoll() <= 0 else { return }
        await refresh()
    }

    /// Two clocks. If Claude has been used since the last poll the figures have
    /// actually moved, so the short interval applies; otherwise the idle
    /// heartbeat does. This is what keeps the app responsive while you work
    /// without spending requests all night on numbers that cannot change.
    private func secondsUntilNextPoll() -> TimeInterval {
        guard let lastPollAt else { return 0 }
        let elapsed = Date().timeIntervalSince(lastPollAt)
        let due = Activity.usedSince(lastPollAt) ? activeInterval : interval
        return max(0, due - elapsed)
    }

    /// Sleeps first, then polls. Changing the interval therefore re-times the
    /// next poll rather than firing one immediately, and cancelling the timer
    /// can no longer abort a sweep that is already in flight — a cancelled task
    /// makes every remaining URLSession call throw, which used to turn one
    /// interval change into a screen full of errored accounts.
    private func reschedule() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-evaluated every 30s rather than slept through in one go:
                // activity can arrive at any point, and the wait has to shorten
                // when it does.
                let wait = await self.secondsUntilNextPoll()
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(min(wait, 30)))
                    continue
                }
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    /// `force` is for the explicit refresh button only — the timer must respect
    /// the 429 backoff or it will keep the rate limit alive indefinitely.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Stamped even when the poll fails, so a failing account cannot turn the
        // timer into a retry loop against the endpoint that just refused us.
        defer { isRefreshing = false; lastPollAt = Date() }
        do {
            state = try await service.poll(force: force)
            lastError = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func switchTo(_ label: String) async {
        do {
            try await service.switchTo(label: label)
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Browser authorisation, kept as two steps so the view can show the code
    /// field only once the browser has actually been sent somewhere.
    private(set) var pendingLogin: OAuthFlow.Pending?

    func beginBrowserLogin() {
        do {
            let pending = try OAuthFlow.begin()
            pendingLogin = pending
            lastError = nil
            try Shell.open(pending.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelBrowserLogin() { pendingLogin = nil }

    func completeBrowserLogin(pastedCode: String) async {
        guard let pending = pendingLogin else { return }
        do {
            let parsed = OAuthFlow.parsePasted(pastedCode)
            let oauth = try await OAuthFlow.exchange(code: parsed.code, pending: pending)
            // No name asked for: it comes from the account being authorised.
            try await service.addAccount(label: nil, oauth: oauth)
            pendingLogin = nil
            lastError = nil
            await refresh(force: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Captures whatever account `claude` is currently logged in as.
    func registerCurrent(as label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await service.addCurrentAccount(label: trimmed)
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ label: String) async {
        do {
            var store = try AccountStore.load()
            store[label] = nil
            if store.active == label { store.active = nil }
            try store.save()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var hasAccounts: Bool { !(state?.accounts.isEmpty ?? true) }
}
