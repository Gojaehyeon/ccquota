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

    /// 180s matches the interval the usage endpoint tolerates comfortably; going
    /// faster buys nothing and risks a 429 that blanks every account at once.
    var interval: TimeInterval = 180 {
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

    private func secondsUntilNextPoll() -> TimeInterval {
        guard let lastPollAt else { return 0 }
        return max(0, interval - Date().timeIntervalSince(lastPollAt))
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
                let wait = await self.secondsUntilNextPoll()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
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
