import Foundation
import Combine

/// v0.2.86 item 16 (SUBSET): probe retry/backoff for the dashboard
/// service checks.
///
/// Mirrors upstream FlClash v0.9.5-rs.1:
/// - lib/providers/routed_probe.dart (the RoutedProbe mixin) as used by
/// - lib/providers/service_status.dart (ServiceStatus, recheckFailures: true)
/// - lib/common/constant.dart (probeConfirmDelay = 1s)
///
/// SUBSET ONLY — what this file does:
/// (1) backoff [1min, 2min, 5min] between re-probes of a displayed
///     failure (upstream _recheckDelays);
/// (2) a first failure is only SHOWN after a 1s confirm re-probe
///     (upstream _show step 0 + confirmDelay): a lone failure may be
///     the route settling or a connection something else closed, so
///     it waits for a second probe to agree before it is surfaced;
/// (3) re-probe immediately when the selected outbound changes
///     (upstream _onRoute picks change: forget failures, re-probe
///     now, past any throttle).
///
/// OUT OF SCOPE (upstream full behaviour, deliberately not built):
/// route-version tracking — upstream ServiceCheck carries coreEpoch /
/// routeVersion and only re-asks for answers whose exits moved, and
/// a confirm only counts when both probes agree on the exits. This
/// file has no route stamp: any second failure confirms, and a fresh
/// success always clears the failure.
///
/// The execution layer stays in TrafficStore (probeServices /
/// probeService); this file never calls ConcordClient directly and
/// never duplicates probe logic. Failure = upstream
/// ServiceStatus.isFailure: status "timeout" or "failed" only.
/// "blocked" / "restricted" / "unavailable" are verdicts the service
/// itself returned, shown as-is with no retry.
final class ServiceProbeStore: ObservableObject {
    /// Backoff between re-probes of a displayed failure (upstream
    /// _recheckDelays). Step n (1...3) waits recheckDelays[n - 1];
    /// the step caps at 3, so the longest gap is 5min.
    static let recheckDelays: [TimeInterval] = [60, 120, 300]
    /// The confirm delay (upstream probeConfirmDelay): a first
    /// failure is re-probed once after this long before it is shown.
    static let confirmDelay: TimeInterval = 1

    /// Services whose failure is CONFIRMED and may be shown as
    /// failed. The dashboard shows a service row as failed only
    /// when its name is in this set; a raw "failed" status in
    /// TrafficStore.services that is not here yet is still
    /// awaiting its confirm re-probe.
    @Published private(set) var confirmedFailures: Set<String> = []
    /// Services whose first failure is awaiting its 1s confirm
    /// re-probe (upstream step 0). The dashboard shows these as
    /// still-checking, not failed.
    @Published private(set) var pendingConfirmation: Set<String> = []
    /// Services with a displayed failure whose next re-probe is
    /// already scheduled (a backoff timer is running).
    @Published private(set) var scheduledRechecks: Set<String> = []

    private weak var trafficStore: TrafficStore?
    /// The outbound the last probe ran through. The confirm and
    /// recheck re-probes run through this same outbound; a selected
    /// outbound change replaces it (see outboundChanged).
    private var currentProxy: String?
    /// Backoff step per failed service: 0 = awaiting confirmation,
    /// 1...3 = displayed failure (next recheck delay is
    /// recheckDelays[step - 1]).
    private var failureSteps: [String: Int] = [:]
    /// One pending confirm/recheck per service. Scheduling replaces
    /// any pending work for that service, so a service is never
    /// double-scheduled; outbound change / disconnect cancels them
    /// all (see cancelAllPendingWork).
    private var pendingWork: [String: Task<Void, Never>] = [:]
    /// Services with a single-service re-probe in flight: a second
    /// probe for the same service never starts while one is out.
    private var inFlight: Set<String> = []
    /// Bumps on reset() / outboundChanged(): a probe that was in
    /// flight across the bump lands stale and its result is
    /// discarded instead of re-inserting failure state for a route
    /// that no longer exists.
    private var generation = 0

    init(trafficStore: TrafficStore) {
        self.trafficStore = trafficStore
    }

    /// A service-check failure in upstream's sense (ServiceStatus
    /// .isFailure): only "timeout" and "failed" count. Everything
    /// else — "available", "blocked", "restricted", "unavailable"
    /// — is a verdict, not a failure, and is shown as-is.
    static func isFailure(_ item: ConcordServiceItem) -> Bool {
        item.status == "timeout" || item.status == "failed"
    }

    /// The entry point for the dashboard's service probe: checks
    /// all enabled services through `proxy` (via TrafficStore),
    /// then feeds the results through the confirm/backoff machine.
    /// Pass `names` to probe a different set (e.g. every registry
    /// service for "全部检测"); nil probes the enabled services.
    /// A second call while one is in flight is a no-op inside
    /// TrafficStore.probeServices (its isProbingServices guard);
    /// the evaluation below is idempotent, so the early return
    /// cannot lose a failure or double-schedule a confirm.
    @MainActor
    func probeAll(proxy: String, names: [String]? = nil) async {
        currentProxy = proxy
        guard let trafficStore else { return }
        await trafficStore.probeServices(proxy: proxy, names: names)
        // A selected-outbound change during the probe makes this
        // result stale (it ran through the old outbound): skip the
        // evaluation — outboundChanged() probes again through the
        // new outbound.
        if proxy == currentProxy {
            evaluate(trafficStore.services)
        }
    }

    /// Feeds a fresh probe result through the machine (upstream
    /// _show): successes clear any failure state; a first failure
    /// waits for its confirm; an already-displayed failure keeps
    /// its recheck armed. Public so a direct probeServices call
    /// (e.g. a manual refresh) can feed its result in too.
    @MainActor
    func evaluate(_ items: [ConcordServiceItem]) {
        for item in items {
            if Self.isFailure(item) {
                if confirmedFailures.contains(item.name) {
                    // Already displayed: keep its recheck armed
                    // (re-arm only when nothing is scheduled — a
                    // re-probe in flight will evaluate on landing).
                    if pendingWork[item.name] == nil, failureSteps[item.name] != nil {
                        scheduleRecheck(for: item.name)
                    }
                } else if !pendingConfirmation.contains(item.name) {
                    scheduleConfirm(for: item.name)
                }
            } else {
                clearFailure(for: item.name)
            }
        }
    }

    /// The selected outbound changed (upstream _onRoute picks
    /// change): forget every failure, cancel every pending
    /// confirm/recheck, and re-probe all enabled services through
    /// the new outbound at once — the user's own switch is no
    /// churn, so it waits for neither the backoff nor any
    /// throttle. No-op when the outbound did not actually change.
    /// A first call before any probe simply records the outbound;
    /// the dashboard's normal probe path covers the first check.
    @MainActor
    func outboundChanged(proxy: String) async {
        guard proxy != currentProxy else { return }
        generation += 1
        cancelAllPendingWork()
        confirmedFailures = []
        pendingConfirmation = []
        scheduledRechecks = []
        failureSteps = [:]
        inFlight = []
        await probeAll(proxy: proxy)
    }

    /// Disconnect / teardown (upstream unwatch + onDispose):
    /// cancel every pending confirm/recheck and forget every
    /// failure, so no stale retry fires after the core is gone
    /// and no confirmed failure survives into the next session.
    /// The dashboard calls this when the tunnel goes down.
    @MainActor
    func reset() {
        generation += 1
        cancelAllPendingWork()
        confirmedFailures = []
        pendingConfirmation = []
        scheduledRechecks = []
        failureSteps = [:]
        inFlight = []
        currentProxy = nil
    }

    /// Arms the 1s confirm re-probe for a first failure (upstream
    /// _armRetry step 0 -> _Retry.confirm after confirmDelay).
    /// The failure is NOT shown until the confirm lands.
    @MainActor
    private func scheduleConfirm(for name: String) {
        cancelPendingWork(for: name)
        pendingConfirmation.insert(name)
        failureSteps[name] = 0
        let generationAtSchedule = generation
        pendingWork[name] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.confirmDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, generationAtSchedule == self.generation else { return }
            await self.confirmProbe(name: name)
        }
    }

    /// The 1s confirm re-probe (upstream _Retry.confirm): a first
    /// failure is only shown when a second probe agrees it failed
    /// — without route-version tracking (out of scope) any second
    /// failure counts as agreement. A passing confirm means the
    /// first failure was transient and is never shown.
    @MainActor
    private func confirmProbe(name: String) async {
        pendingWork[name] = nil
        let generationAtStart = generation
        guard let trafficStore, let proxy = currentProxy else {
            clearFailure(for: name)
            return
        }
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)
        await trafficStore.probeService(proxy: proxy, name: name)
        inFlight.remove(name)
        // A reset / outbound change during the probe: the result
        // belongs to a route that no longer exists — discard it.
        guard generationAtStart == generation else { return }
        guard let item = trafficStore.services.first(where: { $0.name == name }) else {
            clearFailure(for: name)
            return
        }
        if Self.isFailure(item) {
            // Confirmed: show the failure and arm the first
            // recheck (upstream _show: step 0 -> displayed,
            // step 1, delay _recheckDelays[0] = 1min).
            pendingConfirmation.remove(name)
            confirmedFailures.insert(name)
            failureSteps[name] = 1
            scheduleRecheck(for: name)
        } else {
            clearFailure(for: name)
        }
    }

    /// Arms the next re-probe of a displayed failure (upstream
    /// _armRetry step >= 1 -> _Retry.recheck after
    /// _recheckDelays[step - 1]).
    @MainActor
    private func scheduleRecheck(for name: String) {
        cancelPendingWork(for: name)
        guard let step = failureSteps[name], step >= 1 else { return }
        let delay = Self.recheckDelays[min(step, Self.recheckDelays.count) - 1]
        scheduledRechecks.insert(name)
        let generationAtSchedule = generation
        pendingWork[name] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, generationAtSchedule == self.generation else { return }
            await self.recheckProbe(name: name)
        }
    }

    /// A scheduled re-probe of a displayed failure. Still failing
    /// advances the backoff step (capped at 3, so the longest gap
    /// stays 5min) and arms the next recheck; a pass clears the
    /// failure entirely (upstream _show on a fresh answer).
    @MainActor
    private func recheckProbe(name: String) async {
        pendingWork[name] = nil
        scheduledRechecks.remove(name)
        let generationAtStart = generation
        guard let trafficStore, let proxy = currentProxy else {
            clearFailure(for: name)
            return
        }
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)
        await trafficStore.probeService(proxy: proxy, name: name)
        inFlight.remove(name)
        guard generationAtStart == generation else { return }
        guard let item = trafficStore.services.first(where: { $0.name == name }) else {
            clearFailure(for: name)
            return
        }
        if Self.isFailure(item) {
            let step = min((failureSteps[name] ?? 1) + 1, Self.recheckDelays.count)
            failureSteps[name] = step
            scheduleRecheck(for: name)
        } else {
            clearFailure(for: name)
        }
    }

    /// Forgets one service's failure entirely: cancels its pending
    /// confirm/recheck and drops it from every published set.
    @MainActor
    private func clearFailure(for name: String) {
        cancelPendingWork(for: name)
        confirmedFailures.remove(name)
        pendingConfirmation.remove(name)
        scheduledRechecks.remove(name)
        failureSteps.removeValue(forKey: name)
    }

    private func cancelPendingWork(for name: String) {
        pendingWork.removeValue(forKey: name)?.cancel()
    }

    private func cancelAllPendingWork() {
        for task in pendingWork.values { task.cancel() }
        pendingWork = [:]
    }
}
