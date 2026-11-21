import Foundation
import Combine
import UIKit

// MARK: - Traffic store (FlClash: Dashboard network-speed card + traffic)
// Backed by Concord traffic.watch (stream) / traffic.reset and
// probe.outboundIp / core.stats. In `.sample` mode the rates come from
// the mock snapshot with a small amount of jitter so the chart moves;
// the totals are the mock totals. Sample values are labelled in the UI.

struct TrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let up: Int64
    let down: Int64
}

/// One node's live up/down rates in bytes/s (MuYu `Traffic` as
/// sampled by `ExternalTrafficSampler`: per-connection byte deltas
/// over the sample interval, attributed to every name in the
/// connection's chain).
struct NodeSpeed {
    let up: Double
    let down: Double

    static let zero = NodeSpeed(up: 0, down: 0)
}

final class TrafficStore: ObservableObject {
    @Published var current = ConcordTraffic(up: 0, down: 0, totalUp: 0, totalDown: 0)
    @Published var history: [TrafficPoint] = []
    @Published var outboundIp: String?
    @Published var outboundChains: [String] = []
    @Published var coreMemoryBytes: UInt64?
    @Published var services: [ConcordServiceItem] = []
    @Published var isProbingServices = false
    @Published var servicesError: String?
    /// Probe-start hold (upstream probe_start_hold.dart): a
    /// service/IP-probe result held through a start reads as
    /// still-checking, without showing the result it replaced. The
    /// dashboard sets this when the VPN starts; the next probe
    /// clears it when it lands, so a stale pre-start result never
    /// flashes after a restart.
    @Published var servicesHeld = false

    func holdServices() {
        servicesHeld = true
    }

    // MARK: - Service order + disabled (upstream
    // serviceOrder / disabledServices, providers/service_status.dart)
    //
    // The service targets are the core's registry
    // (concordProbeServiceNames). The order and the disabled set
    // are UI-side settings persisted here; an empty enabled list
    // means "all enabled" (upstream enabledServiceTargets falls
    // back to all targets when everything is disabled).

    private static let serviceOrderKey = "ConcordiOS.serviceOrder.v1"
    private static let disabledServicesKey = "ConcordiOS.serviceDisabled.v1"

    /// The stored order, repaired: unknown names dropped, names
    /// added by later versions appended at the end.
    var orderedServiceNames: [String] {
        var order = UserDefaults.standard.stringArray(forKey: Self.serviceOrderKey) ?? []
        if order.isEmpty { order = concordProbeServiceNames }
        order = order.filter { concordProbeServiceNames.contains($0) }
        for name in concordProbeServiceNames where !order.contains(name) {
            order.append(name)
        }
        return order
    }

    func setServiceOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: Self.serviceOrderKey)
        objectWillChange.send()
    }

    var disabledServices: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.disabledServicesKey) ?? [])
    }

    func setServiceDisabled(_ name: String, disabled: Bool) {
        var set = disabledServices
        if disabled { set.insert(name) } else { set.remove(name) }
        UserDefaults.standard.set(Array(set), forKey: Self.disabledServicesKey)
        objectWillChange.send()
    }

    var enabledServiceNames: [String] {
        let enabled = orderedServiceNames.filter { !disabledServices.contains($0) }
        return enabled.isEmpty ? orderedServiceNames : enabled
    }

    // MARK: - Today traffic (MuYu TrafficStatisticsCard)
    //
    // The core's totals are cumulative since the core started, so
    // "today" is current totals minus a day-start baseline kept in
    // UserDefaults. The baseline resets at midnight and whenever
    // the totals drop below it (core restart / traffic.reset).

    private static let todayDateKey = "ConcordiOS.traffic.today.date.v1"
    private static let todayUpKey = "ConcordiOS.traffic.today.up.v1"
    private static let todayDownKey = "ConcordiOS.traffic.today.down.v1"

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func maintainTodayBaseline() {
        let today = Self.todayString()
        let storedDate = UserDefaults.standard.string(forKey: Self.todayDateKey)
        let storedUp = Int64(UserDefaults.standard.integer(forKey: Self.todayUpKey))
        let storedDown = Int64(UserDefaults.standard.integer(forKey: Self.todayDownKey))
        if storedDate != today
            || current.totalUp < storedUp
            || current.totalDown < storedDown {
            UserDefaults.standard.set(today, forKey: Self.todayDateKey)
            UserDefaults.standard.set(current.totalUp, forKey: Self.todayUpKey)
            UserDefaults.standard.set(current.totalDown, forKey: Self.todayDownKey)
        }
    }

    var todayUp: Int64 {
        guard UserDefaults.standard.string(forKey: Self.todayDateKey) == Self.todayString() else { return 0 }
        return max(0, current.totalUp - Int64(UserDefaults.standard.integer(forKey: Self.todayUpKey)))
    }

    var todayDown: Int64 {
        guard UserDefaults.standard.string(forKey: Self.todayDateKey) == Self.todayString() else { return 0 }
        return max(0, current.totalDown - Int64(UserDefaults.standard.integer(forKey: Self.todayDownKey)))
    }

    // MARK: - Daily traffic history (v0.2.55)
    //
    // Daily totals recorded from v0.2.55 on; days before the upgrade
    // have no entry and are never invented — the UI shows "暂无数据"
    // for ranges with no recorded day. "本周" is the rolling last 7
    // days including today (not the locale calendar week, so no
    // week-start rule is needed); "本月" is the current calendar
    // month. Both derive from the same cumulative core counters
    // (current.totalUp / totalDown) as todayUp / todayDown — there
    // is no second source of truth.
    //
    // HOW A DAY IS RECORDED — one value per date, never a sum of
    // snapshots, so a second write of the same day can only
    // overwrite with the same total, never double-count:
    //
    // * While the app runs, the 1 s tick keeps an in-memory
    //   accumulator for the current day: each tick adds
    //   max(0, current total − last-seen total) to it. A negative
    //   delta means the core restarted or traffic.reset ran, so the
    //   counters re-based; the negative delta is dropped (never a
    //   negative day) and the new total becomes the base. Traffic
    //   before a mid-day core restart therefore stays in the day's
    //   total, unlike the day-start baseline behind todayUp, which
    //   re-calibrates and restarts from zero — after such a restart
    //   the week/month today figure is the more complete one,
    //   while 今日 keeps its existing baseline behaviour.
    //   (A baseline-difference snapshot at rollover was considered
    //   and rejected: at the first tick after midnight the current
    //   totals already include the new day's traffic so far, so
    //   when the app was backgrounded overnight that traffic would
    //   be wrongly attributed to yesterday.)
    // * At day rollover the accumulator for the finished day is
    //   written as the day's final total (partial: false) before
    //   the accumulator resets for the new day.
    // * On backgrounding (and best-effort on termination) the
    //   in-progress day is written as a provisional total
    //   (partial: true). A later rollover or backgrounding
    //   overwrites the same date with the newer total — never adds
    //   to it.
    // * On launch the accumulator is seeded once from today's
    //   provisional entry, if one exists, so a same-day restart
    //   continues the day instead of losing what was recorded
    //   before it.
    //
    // THE FOUR RESTART CASES:
    // (1) Restart on the same day: the accumulator is rebuilt from
    //     today's provisional snapshot (written at the last
    //     backgrounding) and keeps adding deltas on top of it; the
    //     day is finalised once, at rollover.
    // (2) Restart after midnight without having run at rollover:
    //     the finished day keeps only its last provisional
    //     snapshot (traffic between the last backgrounding and
    //     midnight was never observed, so it is not invented); the
    //     new day starts from zero. Days the app never ran on get
    //     no entry at all.
    // (3) Core restart / counters reset to zero mid-day: the
    //     negative delta is dropped, the accumulator keeps what it
    //     had, and the new (lower) total becomes the base — the day
    //     can never go negative or count the same bytes twice.
    // (4) Clock / timezone change: every day is the device's local
    //     calendar day (todayString(), same as the today baseline).
    //     A jump to a new date finalises the old day from the
    //     accumulator first; a final entry is never overwritten by
    //     a later snapshot, so a clock moved backwards cannot
    //     corrupt a finished day.
    //
    // LIMIT: the app can only observe traffic while it runs. Traffic
    // that flows while the app is suspended (VPN on, app
    // backgrounded) is not observed; the day's total then covers
    // only the observed part. That is honest under-counting, not
    // invented data.

    /// One recorded day: bytes moved that day. `partial` is true for
    /// a provisional snapshot of an in-progress day (written on
    /// backgrounding); a rollover writes the same date again with
    /// partial false, overwriting the provisional value.
    struct DailyTraffic: Codable {
        let up: Int64
        let down: Int64
        let partial: Bool
    }

    private static let dailyHistoryFileName = "daily-history-v1.json"
    private static let dailyHistoryDefaultsKey = "ConcordiOS.traffic.dailyHistory.v1"
    /// History is kept small and bounded: entries older than this
    /// are pruned on load and on every save.
    private static let dailyHistoryRetentionDays = 62

    /// Persisted daily history, keyed by local date ("yyyy-MM-dd").
    /// @Published so views reading week/month totals re-render when
    /// a day is finalised or snapshotted (the 1 s tick re-renders
    /// the dashboard anyway; this is the correct observation
    /// channel).
    @Published private(set) var dailyHistory: [String: DailyTraffic] = [:]

    /// Last-seen cumulative core totals behind the accumulator, and
    /// the current day's accumulated deltas. Nil until the first
    /// tick of this process (see maintainDailyHistory's seeding
    /// branch).
    private var lastSeenUp: Int64?
    private var lastSeenDown: Int64?
    private var accumUp: Int64 = 0
    private var accumDown: Int64 = 0
    private var accumDate: String?
    private var accumulatorSeeded = false

    /// The App Group file for the history (same container the
    /// engine snapshots live in). Falls back to a UserDefaults copy
    /// when the container is unavailable.
    private var dailyHistoryFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
            .appendingPathComponent("traffic")
            .appendingPathComponent(Self.dailyHistoryFileName)
    }

    private struct DailyHistoryFile: Codable {
        var days: [String: DailyTraffic]
    }

    private func loadDailyHistory() {
        var loaded: [String: DailyTraffic] = [:]
        if let url = dailyHistoryFileURL,
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(DailyHistoryFile.self, from: data) {
            loaded = file.days
        } else if let data = UserDefaults.standard.data(forKey: Self.dailyHistoryDefaultsKey),
                  let file = try? JSONDecoder().decode(DailyHistoryFile.self, from: data) {
            loaded = file.days
        }
        dailyHistory = Self.pruned(loaded)
    }

    private func saveDailyHistory() {
        let pruned = Self.pruned(dailyHistory)
        dailyHistory = pruned
        guard let data = try? JSONEncoder().encode(DailyHistoryFile(days: pruned)) else { return }
        if let url = dailyHistoryFileURL {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return
            } catch {
                // Fall through to the UserDefaults copy below.
            }
        }
        UserDefaults.standard.set(data, forKey: Self.dailyHistoryDefaultsKey)
    }

    private static func pruned(_ days: [String: DailyTraffic]) -> [String: DailyTraffic] {
        // "yyyy-MM-dd" sorts lexicographically, so a plain string
        // comparison against the cutoff date is a date comparison.
        let cutoff = Self.pruneCutoffString()
        return days.filter { $0.key >= cutoff }
    }

    private static func pruneCutoffString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -dailyHistoryRetentionDays, to: Date()) ?? Date()
        return formatter.string(from: cutoff)
    }

    /// Advances the daily-history accumulator from the same
    /// cumulative counters behind todayUp/todayDown. Runs on the
    /// 1 s tick, after `current` is refreshed.
    private func maintainDailyHistory() {
        let today = Self.todayString()
        // First tick of this process: seed the accumulator. A
        // provisional snapshot of today from an earlier backgrounding
        // carries the traffic recorded before a same-day restart, so
        // the day is continued, not restarted (case 1).
        if !accumulatorSeeded {
            accumulatorSeeded = true
            accumDate = today
            accumUp = 0
            accumDown = 0
            if let partial = dailyHistory[today], partial.partial {
                accumUp = partial.up
                accumDown = partial.down
            }
            lastSeenUp = current.totalUp
            lastSeenDown = current.totalDown
            return
        }
        guard let previousDate = accumDate else { return }
        if previousDate != today {
            // Day rollover (or a clock/timezone jump to a new local
            // date): finalise the finished day from the accumulator
            // before resetting it. A final entry is never overwritten
            // (case 4: the clock moved backwards onto a finished day).
            if dailyHistory[previousDate]?.partial != false {
                finalizeDay(previousDate, up: accumUp, down: accumDown)
            }
            accumDate = today
            accumUp = 0
            accumDown = 0
            if let partial = dailyHistory[today], partial.partial {
                accumUp = partial.up
                accumDown = partial.down
            }
            lastSeenUp = current.totalUp
            lastSeenDown = current.totalDown
            return
        }
        // Same day: add the tick's deltas. A negative delta means the
        // core restarted or traffic.reset ran — the counters re-based,
        // so it is dropped and the new total becomes the base (case 3:
        // never a negative day, never the same bytes twice).
        if let seenUp = lastSeenUp {
            let deltaUp = current.totalUp - seenUp
            if deltaUp > 0 { accumUp += deltaUp }
        }
        if let seenDown = lastSeenDown {
            let deltaDown = current.totalDown - seenDown
            if deltaDown > 0 { accumDown += deltaDown }
        }
        lastSeenUp = current.totalUp
        lastSeenDown = current.totalDown
    }

    /// Writes a day's final total, keyed by date. Idempotent:
    /// writing the same date again overwrites with the same value,
    /// never adds. A final entry is never overwritten by a
    /// provisional snapshot.
    private func finalizeDay(_ date: String, up: Int64, down: Int64) {
        if dailyHistory[date]?.partial == false { return }
        dailyHistory[date] = DailyTraffic(up: max(0, up), down: max(0, down), partial: false)
        saveDailyHistory()
    }

    /// Best-effort snapshot of the in-progress day, called when the
    /// app backgrounds (and on termination). The value is
    /// provisional: a later rollover or backgrounding overwrites
    /// the same date with the newer total, never adds to it.
    func snapshotCurrentDayPartial() {
        guard let date = accumDate, date == Self.todayString() else { return }
        if dailyHistory[date]?.partial == false { return }
        dailyHistory[date] = DailyTraffic(up: max(0, accumUp), down: max(0, accumDown), partial: true)
        saveDailyHistory()
    }

    /// Today's accumulated traffic so far (the live contribution of
    /// today to the week/month totals). Unlike todayUp/todayDown it
    /// survives a mid-day core restart — see the history notes above.
    var todayAccumulatedUp: Int64 { accumUp }
    var todayAccumulatedDown: Int64 { accumDown }

    /// Rolling last 7 days including today (see the history notes
    /// above for why rolling, not the calendar week).
    var weekUp: Int64 { totalsForLastDays(7).up }
    var weekDown: Int64 { totalsForLastDays(7).down }
    /// Days in the rolling 7-day window with a recorded total (a
    /// history entry, or today with traffic so far). Zero means
    /// nothing has been recorded yet — the UI shows "暂无数据".
    var weekRecordedDays: Int { totalsForLastDays(7).recordedDays }

    /// Current calendar month (1st through today).
    var monthUp: Int64 { totalsForCurrentMonth().up }
    var monthDown: Int64 { totalsForCurrentMonth().down }
    var monthRecordedDays: Int { totalsForCurrentMonth().recordedDays }

    private func totalsForLastDays(_ count: Int) -> (up: Int64, down: Int64, recordedDays: Int) {
        totals(for: Self.dayStrings(count: count))
    }

    private func totalsForCurrentMonth() -> (up: Int64, down: Int64, recordedDays: Int) {
        totals(for: Self.currentMonthDayStrings())
    }

    /// Sums the given local dates. Today always contributes the live
    /// accumulator — never a stored entry for today, so a stale
    /// provisional snapshot can neither double-count nor go stale
    /// after a same-day restart or a totals reset. Past days
    /// contribute their stored final (or provisional) total; days
    /// with no entry contribute zero.
    private func totals(for dates: [String]) -> (up: Int64, down: Int64, recordedDays: Int) {
        var up: Int64 = 0
        var down: Int64 = 0
        var recorded = 0
        let today = Self.todayString()
        for date in dates {
            if date == today {
                up += accumUp
                down += accumDown
                if accumUp > 0 || accumDown > 0 || dailyHistory[today] != nil {
                    recorded += 1
                }
            } else if let day = dailyHistory[date] {
                up += day.up
                down += day.down
                recorded += 1
            }
        }
        return (up, down, recorded)
    }

    private static func dayStrings(count: Int) -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var result: [String] = []
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            result.append(formatter.string(from: date))
        }
        return result
    }

    private static func currentMonthDayStrings() -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())) else {
            return [todayString()]
        }
        var result: [String] = []
        var date = startOfMonth
        let today = Date()
        while date <= today {
            result.append(formatter.string(from: date))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return result
    }
    /// Live up/down per proxy and group name (MuYu
    /// nodeSpeedsProvider), from the same snapshots as the
    /// dashboard speeds. A reader takes the selected node's entry,
    /// or zero when nothing flows through it; the map keeps its
    /// last values while the tunnel is down, so a reader checks
    /// `isRunning` itself.
    @Published var nodeSpeeds: [String: NodeSpeed] = [:]
    /// Per-connection last-seen byte counts behind the sampler
    /// (MuYu ExternalTrafficSampler._nodeSeen). A connection first
    /// seen here is only a baseline; its bytes so far would
    /// otherwise read as one second's spike.
    private var nodeSeen: [UInt64: (upload: Int64, download: Int64)] = [:]
    private var nodeSeenAt: Date?
    /// The live engine status (engine.state): created / initialized /
    /// configured / running / failed, plus any services that failed
    /// to start. Read from the extension's engine.json snapshot.
    @Published var engineStatus: ConcordEngineStatus?
    @Published var engineStatusError: String?
    @Published var lastError: String?

    let client: ConcordClient
    private var timer: AnyCancellable?
    private let maxHistory = 60

    /// Consecutive refresh() failures (audit D9): one failed
    /// snapshot keeps the last values (a transient), but after 3
    /// in a row the core is really gone, so the live rates are
    /// zeroed instead of showing stale numbers forever. Totals
    /// are kept — they are cumulative counters, not live rates.
    private var consecutiveRefreshFailures = 0

    /// Background/termination observers for the provisional
    /// end-of-day snapshot (same closure pattern as
    /// MobileConfigInstaller).
    private var backgroundObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        loadDailyHistory()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.snapshotCurrentDayPartial()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.snapshotCurrentDayPartial()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    var maxDown: Int64 { history.map { $0.down }.max() ?? 1 }
    var maxUp: Int64 { history.map { $0.up }.max() ?? 1 }

    func start() {
        stop()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                    // The per-node speeds ride the same 1 s tick as
                    // the traffic snapshot (MuYu updateTraffic).
                    await self?.refreshNodeSpeeds()
                    // D11: the engine row rides the same 1 s tick
                    // as the traffic snapshot, otherwise it freezes
                    // after the first read.
                    await self?.refreshEngineStatus()
                }
            }
        Task { await refresh() }
        Task { await probe() }
        Task { await refreshMemory() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    @MainActor
    func refresh() async {
        do {
            var traffic = try await client.trafficSnapshot()
            if client.mode == .sample {
                // Sample mode: jitter the snapshot so the live chart moves.
                // The underlying snapshot is still the mock's fixed value.
                traffic = ConcordTraffic(
                    up: max(0, traffic.up + Int64.random(in: -20_000...40_000)),
                    down: max(0, traffic.down + Int64.random(in: -200_000...400_000)),
                    totalUp: traffic.totalUp,
                    totalDown: traffic.totalDown
                )
            }
            current = traffic
            history.append(TrafficPoint(date: Date(), up: traffic.up, down: traffic.down))
            if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
            maintainTodayBaseline()
            maintainDailyHistory()
            consecutiveRefreshFailures = 0
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            consecutiveRefreshFailures += 1
            if consecutiveRefreshFailures >= 3 {
                // The core has been unreachable for 3 ticks: drop
                // the stale live rates (keep the cumulative totals).
                current = ConcordTraffic(up: 0, down: 0, totalUp: current.totalUp, totalDown: current.totalDown)
            }
        }
    }

    /// Samples the per-node live speeds (MuYu
    /// ExternalTrafficSampler._updateNodeSpeeds,
    /// lib/core/external_controller.dart:56-103, ported verbatim):
    /// each live connection's byte deltas since the last sample,
    /// divided by the elapsed seconds, attributed to every name in
    /// the connection's chain. The data source is the core's
    /// connection.watch snapshot — ConcordConnection carries the
    /// cumulative upload/download counters and the exit chain, so
    /// no new core API was needed. On the first sample the
    /// connections are baselines only (no speeds); a stale snapshot
    /// while the tunnel is down throws and the last map is kept —
    /// the UI shows zeros while not running anyway. This touches
    /// only the connections snapshot; the delay test uses
    /// test_delay / delay.run.poll and is unaffected.
    @MainActor
    func refreshNodeSpeeds() async {
        do {
            let snapshot = try await client.connectionSnapshot()
            let now = Date()
            let previousAt = nodeSeenAt
            nodeSeenAt = now
            guard let previousAt else {
                for c in snapshot.connections {
                    nodeSeen[c.connectionId] = (c.upload ?? 0, c.download ?? 0)
                }
                return
            }
            let elapsed = now.timeIntervalSince(previousAt)
            guard elapsed > 0 else { return }
            var speeds: [String: NodeSpeed] = [:]
            var currentIds = Set<UInt64>()
            for c in snapshot.connections {
                currentIds.insert(c.connectionId)
                let previous = nodeSeen[c.connectionId]
                nodeSeen[c.connectionId] = (c.upload ?? 0, c.download ?? 0)
                guard let previous else { continue }
                let upDelta = (c.upload ?? 0) - previous.upload
                let downDelta = (c.download ?? 0) - previous.download
                guard upDelta > 0 || downDelta > 0 else { continue }
                let up = upDelta > 0 ? Double(upDelta) / elapsed : 0
                let down = downDelta > 0 ? Double(downDelta) / elapsed : 0
                for name in Set(c.chains ?? []) {
                    let current = speeds[name] ?? .zero
                    speeds[name] = NodeSpeed(up: current.up + up, down: current.down + down)
                }
            }
            nodeSeen = nodeSeen.filter { currentIds.contains($0.key) }
            nodeSpeeds = speeds
        } catch {
            // Stale snapshot while the tunnel is down
            // (connection.watch throws past its 10 s max-age):
            // keep the last map.
        }
    }

    @MainActor
    func probe() async {
        do {
            let result = try await client.probeOutboundIp()
            outboundIp = result.body
            outboundChains = result.chains
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func refreshMemory() async {
        do {
            coreMemoryBytes = try await client.coreStats().rss
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reads the live engine status (engine.state). Latest-policy:
    /// the extension rewrites the snapshot whenever the state or
    /// its faults change.
    @MainActor
    func refreshEngineStatus() async {
        do {
            engineStatus = try await client.engineSnapshot()
            engineStatusError = nil
        } catch {
            engineStatus = nil
            engineStatusError = error.localizedDescription
        }
    }

    @MainActor
    func resetTotals() async {
        do {
            try await client.trafficReset()
            history.removeAll()
            current = ConcordTraffic(up: 0, down: 0, totalUp: 0, totalDown: 0)
            // A totals reset restarts today from zero: drop what the
            // accumulator holds for today, or the pre-reset bytes
            // would be counted again on top of the post-reset
            // traffic. The next background snapshot overwrites
            // today's provisional entry with the restarted total
            // (today's contribution to week/month always reads the
            // live accumulator, never the stored entry, so the stale
            // entry cannot leak into the totals meanwhile).
            accumUp = 0
            accumDown = 0
            lastSeenUp = 0
            lastSeenDown = 0
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Checks the known services (google, github, youtube, …) through
    /// one proxy (probe.services). The status strings are the core's
    /// contract ("available", "blocked", "restricted", "timeout",
    /// "failed", … — upstream crates/engine/src/probe/services.rs).
    /// `names` defaults to the enabled services in the user's order
    /// (TrafficStore.enabledServiceNames); pass an explicit list to
    /// check a subset. A finished probe clears the probe-start hold.
    @MainActor
    func probeServices(proxy: String, names: [String]? = nil) async {
        guard !isProbingServices else { return }
        isProbingServices = true
        defer {
            isProbingServices = false
            servicesHeld = false
        }
        do {
            services = try await client.probeServices(proxy: proxy, names: names ?? enabledServiceNames)
            servicesError = nil
        } catch {
            servicesError = error.localizedDescription
        }
    }

    /// Re-checks one service and merges the result into the current
    /// list by name (the service sheet's per-row check): the full
    /// list is not replaced by a single item.
    @MainActor
    func probeService(proxy: String, name: String) async {
        do {
            let fresh = try await client.probeServices(proxy: proxy, names: [name])
            guard let item = fresh.first else { return }
            if let index = services.firstIndex(where: { $0.name == name }) {
                services[index] = item
            } else {
                services.append(item)
            }
            servicesError = nil
        } catch {
            servicesError = error.localizedDescription
        }
    }
}
