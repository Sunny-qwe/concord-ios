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
struct NodeSpeed: Equatable {
    let up: Double
    let down: Double

    static let zero = NodeSpeed(up: 0, down: 0)
}

/// The traffic sheet's range (MuYu TrafficStatisticsRange).
enum TrafficRange: String, CaseIterable {
    case day, week, month

    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    /// Navigator limit (MuYu maxTrafficStatisticsOffset).
    var maxOffset: Int {
        switch self {
        case .day: return 89
        case .week: return 12
        case .month: return 2
        }
    }
}

/// One range's summed traffic (traffic sheet): core totals plus
/// the observed proxy/direct split and ranking buckets.
struct DayTotals {
    var up: Int64 = 0
    var down: Int64 = 0
    var proxyUp: Int64 = 0
    var proxyDown: Int64 = 0
    var directUp: Int64 = 0
    var directDown: Int64 = 0
    var groups: [String: TrafficStore.DaySplit] = [:]
    var nodes: [String: TrafficStore.DaySplit] = [:]
    var domains: [String: TrafficStore.DaySplit] = [:]
    /// Rule-hit counts for the range (v0.2.57): connection
    /// count per `rule` value, from the 1 s connection feed.
    var ruleHits: [String: Int] = [:]
    /// Recorded tunnel uptime for the range, in seconds
    /// (v0.2.57 per-day uptime). `hasUptime` is false when no
    /// day in the range has a recorded value — the sheet then
    /// shows "—" instead of inventing a number.
    var uptimeSeconds: Int64 = 0
    var hasUptime: Bool = false
    var recordedDays: Int = 0

    var totalRuleHits: Int { ruleHits.values.reduce(0, +) }

    /// "18 小时 56 分钟" for the range, or nil when nothing
    /// was recorded (the sheet shows "—").
    var uptimeText: String? {
        guard hasUptime else { return nil }
        return formatCumulativeUptime(seconds: uptimeSeconds)
    }

    var total: Int64 { up + down }
    var proxyBytes: Int64 { proxyUp + proxyDown }
    var directBytes: Int64 { directUp + directDown }
    /// Proxy share of the REAL total (MuYu's ring: proxy / total).
    /// The split is observed, so proxy + direct can be less than
    /// the total; the remainder is unclassified, never invented.
    var proxyRatio: Double {
        guard total > 0 else { return 0 }
        return Double(proxyBytes) / Double(total)
    }
}

// v0.2.115: client-side parsing of the probe.outboundIp raw body,
// mirroring upstream FlClash lib/common/service_probe.dart
// (`parseOutboundIp` + `ipInfoSources`) and lib/models/common.dart
// (`IpInfo {ip, countryCode}`). The core returns the RAW response
// body (crates/engine/src/probe/outbound_ip.rs) — assigning it
// straight to outboundIp showed raw JSON/trace text on the status
// card. Returns nil on unknown URL, empty body, or any parse
// failure, exactly like upstream returning null.
struct ProbedIpInfo {
    let ip: String
    let countryCode: String
}

func parseOutboundIp(_ result: ConcordOutboundIp) -> ProbedIpInfo? {
    let body = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }

    func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    /// Trims whitespace; returns nil for a missing, non-string,
    /// or blank value — both fields must be non-empty.
    func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    func make(ip: String?, countryCode: String?) -> ProbedIpInfo? {
        guard let ip, let countryCode else { return nil }
        return ProbedIpInfo(ip: ip, countryCode: countryCode)
    }

    switch result.url {
    case "https://www.cloudflare.com/cdn-cgi/trace":
        // fromCloudflareTrace: line-split key=value; need ip + loc.
        var fields: [String: String] = [:]
        for line in body.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return make(ip: string(fields["ip"]), countryCode: string(fields["loc"]))
    case "https://api.ip.sb/geoip":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["country_code"]))
    case "https://ipinfo.io/json":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["country"]))
    case "https://ipwho.is":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["country_code"]))
    case "https://get.geojs.io/v1/ip/geo.json":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["country_code"]))
    case "https://api.country.is":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["country"]))
    case "https://api.ipquery.io/?format=json":
        guard let json = jsonObject(body),
              let location = json["location"] as? [String: Any] else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(location["country_code"]))
    case "https://ident.me/json":
        guard let json = jsonObject(body) else { return nil }
        return make(ip: string(json["ip"]), countryCode: string(json["cc"]))
    default:
        return nil
    }
}

final class TrafficStore: ObservableObject {
    @Published var current = ConcordTraffic(up: 0, down: 0, totalUp: 0, totalDown: 0)
    @Published var history: [TrafficPoint] = []
    @Published var outboundIp: String?
    /// v0.2.115: the parsed IP + country code from the egress-IP
    /// probe (see parseOutboundIp below) — the status card's IP and
    /// country come from here, mirroring MuYu's probe.outboundIp.
    @Published var outboundIpInfo: ProbedIpInfo?
    /// v0.2.125 (Part B): true when the displayed IP is the
    /// last-known value restored from UserDefaults, not a fresh
    /// probe result — upstream keepValue: a cold start shows the
    /// cached IP instantly while the retry loop re-probes in the
    /// background, instead of sitting on a skeleton.
    @Published var outboundIpIsStale = false
    /// v0.2.125 (Part B): the persisted last-known egress IP +
    /// country code (restored in init, written on probe() success).
    private static let lastKnownIpKey = "ConcordiOS.lastKnownOutboundIp.v1"
    private static let lastKnownIpCountryKey = "ConcordiOS.lastKnownOutboundIpCountry.v1"
    /// v0.2.115: true when the last egress-IP probe failed (RPC
    /// error or unparseable body); the status card shows its
    /// failure state from this instead of guessing from a nil IP.
    @Published var outboundIpProbeFailed: Bool = false
    /// v0.2.124 (IP "查询失败" flicker): the failure the status
    /// card / IP sheet actually show. The first probe on app
    /// entry fails fast while the in-app core session is still
    /// starting ("核心会话已关闭"), then a retry succeeds ~1 s
    /// later — a bare `outboundIpProbeFailed` flashes red before
    /// the IP lands. While a probe is in flight, or the fast 3 s
    /// retry phase (first 20 attempts, maybeRetryOutboundIpProbe)
    /// is still running, the card shows the probing skeleton
    /// instead; only once the fast retries are over does the
    /// failure settle and show.
    var outboundIpFailureSettled: Bool {
        outboundIpProbeFailed && !isProbingOutboundIp && outboundIpProbeAttempts >= 20
    }
    @Published var outboundChains: [String] = []
    /// In-flight guard for the egress-IP probe (probe()): the probe
    /// is a 6 s-timeout RPC to the extension core, so overlapping
    /// attempts must not pile up.
    private var isProbingOutboundIp = false
    /// Last egress-IP probe attempt, for the 1 s tick retry throttle
    /// (maybeRetryOutboundIpProbe).
    private var lastOutboundIpProbeAt: Date?
    /// Egress-IP retry count since the last successful probe
    /// (maybeRetryOutboundIpProbe): the first 20 attempts run every
    /// 3 s so the status card clears promptly once the core's RPC
    /// is ready, then it backs off to every 10 s. Reset to 0
    /// whenever probe() succeeds and sets outboundIp.
    private var outboundIpProbeAttempts = 0
    /// v0.2.118 (Job 5): consecutive failures of the EXTENSION-
    /// core probe only (error field set, unparseable body, or RPC
    /// throw). After 5 in a row the extension probe retries with
    /// a 15 s timeout instead of FlClash's 6 s — a first connect
    /// through the proxy can be slower than 6 s, and every
    /// attempt timing out looks exactly like the v0.2.117
    /// on-device report (tunnel up, traffic flowing, IP never
    /// appears). Reset on success and on route change
    /// (clearOutboundIp). The in-app core is NOT a fallback here:
    /// TunnelManager stops AppCore while the VPN is on (v0.2.101
    /// heating fix) and ensureStarted refuses while the tunnel
    /// runs, so there is no second core to ask while the tunnel
    /// is up — the extension probe itself is hardened instead.
    private var consecutiveExtensionProbeFailures = 0
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

    @MainActor
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

    @MainActor
    func setServiceOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: Self.serviceOrderKey)
        objectWillChange.send()
    }

    var disabledServices: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.disabledServicesKey) ?? [])
    }

    @MainActor
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
    // The core's totals are cumulative since the core started.
    // "Today" is the daily-history accumulator below
    // (accumUp/Down, todayTotals): per-tick deltas
    // added while the app runs, so a mid-day core restart or
    // traffic.reset does not restart the day from zero. The
    // v0.2.55 day-start baseline (todayUp/todayDown) was removed
    // in v0.2.56 — it measured the same day a second way and
    // restarted from zero after a core restart, so the card and
    // the sheet could disagree about "today".

    /// Shared "yyyy-MM-dd" formatter for the daily keys: a fresh
    /// DateFormatter per call ran on the 1 s tick path. One static
    /// instance serves every call (all callers run on the main
    /// thread — the tick timer is on .main and the store's
    /// publishers are main-thread confined).
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func todayString() -> String {
        todayFormatter.string(from: Date())
    }

    // MARK: - Daily traffic history (v0.2.55)
    //
    // Daily totals recorded from v0.2.55 on; days before the upgrade
    // have no entry and are never invented — the UI shows "暂无数据"
    // for ranges with no recorded day. "本周" is the rolling last 7
    // days including today (not the locale calendar week, so no
    // week-start rule is needed); "本月" is the current calendar
    // month. Both derive from the same cumulative core counters
    // (current.totalUp / totalDown) — there is no second source
    // of truth.
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
    //   total.
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
    //     calendar day (todayString()).
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

    /// One day's up/down split, also one ranking bucket (a group, a
    /// node or a domain) in the traffic sheet's rankings.
    struct DaySplit: Codable {
        var up: Int64 = 0
        var down: Int64 = 0
    }

    /// One recorded day: bytes moved that day. `partial` is true for
    /// a provisional snapshot of an in-progress day (written on
    /// backgrounding); a rollover writes the same date again with
    /// partial false, overwriting the provisional value.
    ///
    /// v0.2.56 adds the proxy/direct split and the per-group /
    /// per-node / per-domain rankings (traffic sheet, MuYu
    /// TrafficStatisticsData + rankBy). The new keys are all
    /// optional on decode — a v0.2.55 file without them still
    /// decodes, with the split/rankings reading as zero/empty
    /// instead of wiping the day's totals. The memberwise init
    /// keeps defaults for the new fields so existing call sites
    /// stay short; `init(from:)` is explicit for the same reason.
    struct DailyTraffic: Codable {
        let up: Int64
        let down: Int64
        let partial: Bool
        /// Proxy bytes (chains.first != "DIRECT") / direct bytes
        /// (chains.first == "DIRECT") — see the split notes below.
        let proxyUp: Int64
        let proxyDown: Int64
        let directUp: Int64
        let directDown: Int64
        /// Ranking buckets: group = connection chains.last, node =
        /// chains.first, domain = connection host. Each connection's
        /// bytes count once per bucket map (MuYu records proxy =
        /// chains.last and node = chains.first the same way).
        let groups: [String: DaySplit]
        let nodes: [String: DaySplit]
        let domains: [String: DaySplit]
        /// Rule-hit counts (v0.2.57): how many connections first
        /// seen that day carried each `rule` value. Optional on
        /// decode — a v0.2.55/56 file without it reads as empty.
        let ruleHits: [String: Int]

        init(up: Int64, down: Int64, partial: Bool,
             proxyUp: Int64 = 0, proxyDown: Int64 = 0,
             directUp: Int64 = 0, directDown: Int64 = 0,
             groups: [String: DaySplit] = [:],
             nodes: [String: DaySplit] = [:],
             domains: [String: DaySplit] = [:],
             ruleHits: [String: Int] = [:]) {
            self.up = up
            self.down = down
            self.partial = partial
            self.proxyUp = proxyUp
            self.proxyDown = proxyDown
            self.directUp = directUp
            self.directDown = directDown
            self.groups = groups
            self.nodes = nodes
            self.domains = domains
            self.ruleHits = ruleHits
        }

        enum CodingKeys: String, CodingKey {
            case up, down, partial
            case proxyUp, proxyDown, directUp, directDown
            case groups, nodes, domains
            case ruleHits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            up = try container.decode(Int64.self, forKey: .up)
            down = try container.decode(Int64.self, forKey: .down)
            partial = try container.decode(Bool.self, forKey: .partial)
            proxyUp = try container.decodeIfPresent(Int64.self, forKey: .proxyUp) ?? 0
            proxyDown = try container.decodeIfPresent(Int64.self, forKey: .proxyDown) ?? 0
            directUp = try container.decodeIfPresent(Int64.self, forKey: .directUp) ?? 0
            directDown = try container.decodeIfPresent(Int64.self, forKey: .directDown) ?? 0
            groups = try container.decodeIfPresent([String: DaySplit].self, forKey: .groups) ?? [:]
            nodes = try container.decodeIfPresent([String: DaySplit].self, forKey: .nodes) ?? [:]
            domains = try container.decodeIfPresent([String: DaySplit].self, forKey: .domains) ?? [:]
            ruleHits = try container.decodeIfPresent([String: Int].self, forKey: .ruleHits) ?? [:]
        }
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

    // MARK: - Proxy/direct split + rankings (v0.2.56, MuYu
    // TrafficStatisticsCard / TrafficStatisticsView)
    //
    // The core exposes NO proxy/direct totals: traffic.watch
    // carries only up/down/totalUp/totalDown, so the split is
    // built from the same 1 s connection.watch feed as the
    // per-node speeds (refreshNodeSpeeds), with MuYu's rule
    // (ExternalTrafficSampler.sampleProxyOnly + the recorder's
    // `direct: chains.firstOrNull == 'DIRECT'`): a connection
    // counts as DIRECT when its chain starts with DIRECT, and
    // as proxy otherwise — including an empty chain, and a
    // connection whose chain is missing but whose `proxy` is
    // DIRECT (the sample data carries no chains; live core data
    // does). The ranking buckets use the same per-connection
    // deltas: group = chains.last, node = chains.first, domain =
    // host (MuYu's recorder stores proxy = chains.last and node
    // = chains.first the same way).
    //
    // HONEST UNDERCOUNT — the split/rankings are observed, not
    // complete, and the card/sheet say so:
    // * a connection that opens AND closes between two 1 s polls
    //   is never seen and contributes nothing (MuYu's recorder
    //   also sees opens via core events, so it loses less);
    // * a connection already open when sampling starts is a
    //   baseline — its bytes so far are never attributed;
    // * only positive per-direction deltas count (a counter
    //   reset / reused id contributes nothing, never negative);
    // * traffic while the app is suspended is not observed;
    // * the split therefore sums to LESS than the day's core
    //   total (proxy + direct <= total); the ring is the proxy
    //   share of the real total, so the unclassified remainder
    //   reads as ring gap, not as proxy or direct traffic.
    //
    // The accumulators share the day accumulator's lifecycle
    // (seeded from today's provisional entry, finalised at
    // rollover, snapshotted on backgrounding) so a same-day
    // restart continues the split instead of restarting it.

    /// Today's proxy/direct byte totals (up + down are kept
    /// separate so the sheet can show each direction).
    private var splitProxyUp: Int64 = 0
    private var splitProxyDown: Int64 = 0
    private var splitDirectUp: Int64 = 0
    private var splitDirectDown: Int64 = 0
    /// Today's ranking buckets, keyed by group / node / domain.
    private var groupAccum: [String: DaySplit] = [:]
    private var nodeAccum: [String: DaySplit] = [:]
    private var domainAccum: [String: DaySplit] = [:]
    /// Today's rule-hit counts (v0.2.57, item 5), keyed by the
    /// connection feed's `rule` value. Shares the lifecycle
    /// below (seeded / finalised / snapshotted with the day).
    private var ruleHitAccum: [String: Int] = [:]

    // MARK: - Hourly traffic buckets (v0.2.57, item 4, MuYu
    // 流量趋势)
    //
    // No hourly source existed (the live history keeps only
    // 60 s of rates), so hourly buckets are collected from
    // v0.2.57 on — NO backfill, same policy as the v0.2.55
    // daily history: days recorded before the upgrade have a
    // daily total but no hourly buckets, and the chart says so
    // instead of inventing bars.
    //
    // SOURCE: the TOTAL up/down deltas from maintainDailyHistory
    // (the same deltas feeding the day accumulator) — not the
    // per-connection deltas behind the proxy/direct split. The
    // chart is total traffic per hour, so it uses the most
    // complete observed source: the 24 bars sum to the day's
    // recorded total. The per-connection deltas would undercount
    // the same way the split does (short-lived connections
    // between polls are never seen). The remaining limit is the
    // daily history's: traffic while the app is suspended is
    // not observed, so an hour's bar covers only the observed
    // part; an hour with no recorded bucket draws no bar.
    //
    // Keyed by local date + hour ("yyyy-MM-dd HH"), persisted
    // in the history file alongside the daily history (same
    // 62-day prune). Only the current hour is written on the
    // 1 s tick (in memory); the file is written on
    // backgrounding / rollover / uptime settle, like the day.

    /// All recorded hourly buckets. @Published so the trend
    /// chart re-renders when a bucket is written.
    @Published private(set) var hourlyHistory: [String: DaySplit] = [:]

    /// "yyyy-MM-dd HH" for a date's local hour.
    private static func hourKey(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return "\(string(for: date)) \(String(format: "%02d", hour))"
    }

    /// One hour's recorded up/down, or nil when that hour was
    /// never recorded (the chart draws no bar for it).
    func hourlyBucket(for key: String) -> DaySplit? {
        hourlyHistory[key]
    }

    /// "2026-11-20" -> "11/20" (week chart x-axis).
    static func shortDayLabel(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return dateString }
        return "\(month)/\(day)"
    }

    // MARK: - Cumulative uptime per day (v0.2.56 today-only,
    // v0.2.57 per-day, MuYu "累计运行": the traffic card/sheet
    // show the day's total tunnel time, not just the current
    // session — MuYu sums its tunnel_sessions rows for the day.
    // There is no session table here: finished tunnel time is
    // accumulated into `uptimeByDay`, keyed by local date, and
    // the live session adds its elapsed time on top.
    // DashboardView reports the session starts/stops it already
    // observes (isRunning transitions + the extension's start
    // time on launch). The per-day map is persisted in the same
    // history file as the daily traffic (same 62-day prune);
    // days with no entry show "—" in past ranges, never an
    // invented number.
    //
    // THE THREE CASES (reconciled in recordUptimeSegment +
    // checkpointUptime):
    // (a) The tunnel stops while the app is alive: settle
    //     (noteTunnelStopped / a new noteTunnelStarted) records
    //     the whole elapsed session into the day buckets,
    //     splitting at local midnight when the session spans
    //     midnight — the pre-midnight part stays with the old
    //     day, only the post-midnight part counts for the new
    //     day.
    // (b) A session that ends while the app is dead is LOST:
    //     its stop is never observed, so its time is not
    //     invented. What survives is only what was checkpointed
    //     while the app was alive (backgrounding/termination
    //     checkpoints the elapsed time so far and advances the
    //     session start, so that part is never counted twice).
    // (c) A midnight-spanning session: at rollover the live
    //     session is checkpointed up to midnight (the
    //     pre-midnight part goes to the old day, the session
    //     start advances to midnight), so the new day counts
    //     only its post-midnight part; a session that stops
    //     after midnight is split the same way by settle.
    //
    // MIGRATION: v0.2.56 kept today's finished sessions in
    // UserDefaults (uptimeToday.*.v1). On first load those keys
    // are read once into today's bucket and then removed; the
    // map is the only source after that.

    private static let uptimeTodayDateKey = "ConcordiOS.traffic.uptimeToday.date.v1"
    private static let uptimeTodaySecondsKey = "ConcordiOS.traffic.uptimeToday.seconds.v1"
    /// Finished-session seconds per local date ("yyyy-MM-dd").
    /// @Published so the sheet re-renders when a session is
    /// settled or checkpointed.
    @Published private(set) var uptimeByDay: [String: Int64] = [:]
    /// Start of the live tunnel session, if one is running.
    private var uptimeSessionStart: Date?

    /// Cumulative tunnel time today: finished sessions plus the
    /// live session's elapsed time so far (clipped to today).
    var todayUptimeSeconds: Int64 {
        var seconds = uptimeByDay[Self.todayString()] ?? 0
        if let start = uptimeSessionStart {
            let todayStart = Calendar.current.startOfDay(for: Date())
            seconds += Int64(max(0, Date().timeIntervalSince(max(start, todayStart))))
        }
        return seconds
    }

    /// "18 小时 56 分钟" / "56 分钟" (MuYu
    /// trafficStatisticsUptimeText: hours + minutes, minutes
    /// alone below one hour, "0 分钟" at zero).
    var todayUptimeText: String {
        formatCumulativeUptime(seconds: todayUptimeSeconds)
    }

    /// Records a tunnel session start. Idempotent for the same
    /// start time; a different start settles the previous
    /// session first (the extension restarted under the app).
    @MainActor
    func noteTunnelStarted(at date: Date) {
        if let current = uptimeSessionStart, current == date { return }
        settleUptimeSession()
        uptimeSessionStart = date
    }

    /// Records a tunnel session stop: its elapsed time is split
    /// across the days it spans (case (a) above).
    @MainActor
    func noteTunnelStopped() {
        settleUptimeSession()
    }

    private func settleUptimeSession(now: Date = Date()) {
        guard let start = uptimeSessionStart else { return }
        uptimeSessionStart = nil
        recordUptimeSegment(from: start, to: now)
        saveDailyHistory()
    }

    /// Records the live session's elapsed time up to `upTo`
    /// into the per-day buckets and advances the session start
    /// to `upTo`, so the recorded part is never counted twice.
    /// Called at day rollover (upTo = midnight: the
    // pre-midnight part stays with the old day, case (c)) and
    /// on backgrounding/termination (upTo = now: the time
    /// observed so far survives even if the app is then killed;
    /// the part after the checkpoint, ending while the app is
    /// dead, is still lost, case (b)).
    private func checkpointUptime(upTo: Date = Date()) {
        guard let start = uptimeSessionStart, upTo > start else { return }
        recordUptimeSegment(from: start, to: upTo)
        uptimeSessionStart = upTo
        saveDailyHistory()
    }

    /// Adds the seconds between `start` and `end` to the
    /// per-day buckets, splitting at each local midnight so a
    /// midnight-spanning session attributes only its
    /// post-midnight part to the new day.
    private func recordUptimeSegment(from start: Date, to end: Date) {
        guard end > start else { return }
        let calendar = Calendar.current
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextMidnight)
            let seconds = Int64(max(0, segmentEnd.timeIntervalSince(cursor)))
            if seconds > 0 {
                let key = Self.string(for: cursor)
                uptimeByDay[key, default: 0] += seconds
            }
            cursor = segmentEnd
        }
    }

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
        /// Hourly traffic buckets (v0.2.57, item 4), keyed by
        /// local date + hour ("yyyy-MM-dd HH").
        var hours: [String: DaySplit]
        /// Finished tunnel seconds per local date (v0.2.57,
        /// item 6), keyed by "yyyy-MM-dd".
        var uptimeSeconds: [String: Int64]

        init(days: [String: DailyTraffic], hours: [String: DaySplit] = [:],
             uptimeSeconds: [String: Int64] = [:]) {
            self.days = days
            self.hours = hours
            self.uptimeSeconds = uptimeSeconds
        }

        enum CodingKeys: String, CodingKey {
            case days, hours, uptimeSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            days = try container.decode([String: DailyTraffic].self, forKey: .days)
            hours = try container.decodeIfPresent([String: DaySplit].self, forKey: .hours) ?? [:]
            uptimeSeconds = try container.decodeIfPresent([String: Int64].self, forKey: .uptimeSeconds) ?? [:]
        }
    }

    private func loadDailyHistory() {
        var loadedDays: [String: DailyTraffic] = [:]
        var loadedHours: [String: DaySplit] = [:]
        var loadedUptime: [String: Int64] = [:]
        if let url = dailyHistoryFileURL,
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(DailyHistoryFile.self, from: data) {
            loadedDays = file.days
            loadedHours = file.hours
            loadedUptime = file.uptimeSeconds
        } else if let data = UserDefaults.standard.data(forKey: Self.dailyHistoryDefaultsKey),
                  let file = try? JSONDecoder().decode(DailyHistoryFile.self, from: data) {
            loadedDays = file.days
            loadedHours = file.hours
            loadedUptime = file.uptimeSeconds
        }
        dailyHistory = Self.pruned(loadedDays)
        hourlyHistory = Self.prunedHours(loadedHours)
        uptimeByDay = Self.prunedUptime(loadedUptime)
        // One-time migration of the v0.2.56 today-only uptime
        // keys: today's finished sessions move into today's
        // bucket, then the keys are removed.
        if uptimeByDay[Self.todayString()] == nil,
           let legacyDate = UserDefaults.standard.string(forKey: Self.uptimeTodayDateKey),
           legacyDate == Self.todayString() {
            let seconds = Int64(UserDefaults.standard.integer(forKey: Self.uptimeTodaySecondsKey))
            if seconds > 0 { uptimeByDay[legacyDate] = seconds }
        }
        UserDefaults.standard.removeObject(forKey: Self.uptimeTodayDateKey)
        UserDefaults.standard.removeObject(forKey: Self.uptimeTodaySecondsKey)
    }

    private func saveDailyHistory() {
        let pruned = Self.pruned(dailyHistory)
        dailyHistory = pruned
        hourlyHistory = Self.prunedHours(hourlyHistory)
        uptimeByDay = Self.prunedUptime(uptimeByDay)
        guard let data = try? JSONEncoder().encode(DailyHistoryFile(
            days: pruned, hours: hourlyHistory, uptimeSeconds: uptimeByDay)) else { return }
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

    /// Same 62-day window for the hourly buckets: the key's
    /// first 10 characters are its local date.
    private static func prunedHours(_ hours: [String: DaySplit]) -> [String: DaySplit] {
        let cutoff = Self.pruneCutoffString()
        return hours.filter { String($0.key.prefix(10)) >= cutoff }
    }

    /// Same 62-day window for the per-day uptime buckets.
    private static func prunedUptime(_ uptime: [String: Int64]) -> [String: Int64] {
        let cutoff = Self.pruneCutoffString()
        return uptime.filter { $0.key >= cutoff }
    }

    private static func pruneCutoffString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -dailyHistoryRetentionDays, to: Date()) ?? Date()
        return formatter.string(from: cutoff)
    }

    /// Advances the daily-history accumulator from the same
    /// cumulative counters (current.totalUp / totalDown). Runs on
    /// the 1 s tick, after `current` is refreshed.
    private func maintainDailyHistory() {
        let today = Self.todayString()
        // First tick of this process: seed the accumulator. A
        // provisional snapshot of today from an earlier backgrounding
        // carries the traffic recorded before a same-day restart, so
        // the day is continued, not restarted (case 1). The split
        // and ranking accumulators seed from the same entry.
        if !accumulatorSeeded {
            accumulatorSeeded = true
            accumDate = today
            accumUp = 0
            accumDown = 0
            resetDayAccumulators()
            if let partial = dailyHistory[today], partial.partial {
                accumUp = partial.up
                accumDown = partial.down
                seedDayAccumulators(from: partial)
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
            // A live tunnel session is checkpointed up to midnight
            // first, so its pre-midnight part stays with the old
            // day (uptime case (c)).
            checkpointUptime(upTo: Calendar.current.startOfDay(for: Date()))
            if dailyHistory[previousDate]?.partial != false {
                finalizeDay(previousDate)
            }
            accumDate = today
            accumUp = 0
            accumDown = 0
            resetDayAccumulators()
            if let partial = dailyHistory[today], partial.partial {
                accumUp = partial.up
                accumDown = partial.down
                seedDayAccumulators(from: partial)
            }
            lastSeenUp = current.totalUp
            lastSeenDown = current.totalDown
            return
        }
        // Same day: add the tick's deltas. A negative delta means the
        // core restarted or traffic.reset ran — the counters re-based,
        // so it is dropped and the new total becomes the base (case 3:
        // never a negative day, never the same bytes twice).
        var tickUp: Int64 = 0
        var tickDown: Int64 = 0
        if let seenUp = lastSeenUp {
            let deltaUp = current.totalUp - seenUp
            if deltaUp > 0 {
                accumUp += deltaUp
                tickUp = deltaUp
            }
        }
        if let seenDown = lastSeenDown {
            let deltaDown = current.totalDown - seenDown
            if deltaDown > 0 {
                accumDown += deltaDown
                tickDown = deltaDown
            }
        }
        // The same positive deltas feed the current hour's bucket
        // (item 4): the 24 hourly bars sum to the day's recorded
        // total. A re-based (negative) delta adds nothing.
        if tickUp > 0 || tickDown > 0 {
            let key = Self.hourKey(for: Date())
            var bucket = hourlyHistory[key] ?? DaySplit()
            bucket.up += tickUp
            bucket.down += tickDown
            hourlyHistory[key] = bucket
        }
        lastSeenUp = current.totalUp
        lastSeenDown = current.totalDown
    }

    /// Writes a day's final total, keyed by date, from the live
    /// accumulators (totals + split + rankings + rule hits).
    /// Idempotent: writing the same date again overwrites with
    /// the same value, never adds. A final entry is never
    /// overwritten by a provisional snapshot.
    private func finalizeDay(_ date: String) {
        if dailyHistory[date]?.partial == false { return }
        dailyHistory[date] = DailyTraffic(
            up: max(0, accumUp), down: max(0, accumDown), partial: false,
            proxyUp: splitProxyUp, proxyDown: splitProxyDown,
            directUp: splitDirectUp, directDown: splitDirectDown,
            groups: groupAccum, nodes: nodeAccum,
            domains: Self.cappedDomains(domainAccum),
            ruleHits: Self.cappedRuleHits(ruleHitAccum))
        saveDailyHistory()
    }

    /// Best-effort snapshot of the in-progress day, called when the
    /// app backgrounds (and on termination). The value is
    /// provisional: a later rollover or backgrounding overwrites
    /// the same date with the newer total, never adds to it. The
    /// live tunnel session is checkpointed too, so the uptime
    /// observed so far survives even if the app is then killed
    /// (uptime case (b): only the un-checkpointed remainder is
    /// lost).
    func snapshotCurrentDayPartial() {
        checkpointUptime()
        guard let date = accumDate, date == Self.todayString() else { return }
        if dailyHistory[date]?.partial == false { return }
        dailyHistory[date] = DailyTraffic(
            up: max(0, accumUp), down: max(0, accumDown), partial: true,
            proxyUp: splitProxyUp, proxyDown: splitProxyDown,
            directUp: splitDirectUp, directDown: splitDirectDown,
            groups: groupAccum, nodes: nodeAccum,
            domains: Self.cappedDomains(domainAccum),
            ruleHits: Self.cappedRuleHits(ruleHitAccum))
        saveDailyHistory()
    }

    /// Zeroes the split, ranking and rule-hit accumulators
    /// (rollover and totals reset); the caller seeds them from
    /// today's provisional entry when one exists.
    private func resetDayAccumulators() {
        splitProxyUp = 0
        splitProxyDown = 0
        splitDirectUp = 0
        splitDirectDown = 0
        groupAccum = [:]
        nodeAccum = [:]
        domainAccum = [:]
        ruleHitAccum = [:]
    }

    private func seedDayAccumulators(from day: DailyTraffic) {
        splitProxyUp = day.proxyUp
        splitProxyDown = day.proxyDown
        splitDirectUp = day.directUp
        splitDirectDown = day.directDown
        groupAccum = day.groups
        nodeAccum = day.nodes
        domainAccum = day.domains
        ruleHitAccum = day.ruleHits
    }

    /// Bounds the persisted per-domain map: hosts are unbounded
    /// in principle, so only the 100 heaviest survive a write.
    /// The live accumulator is uncapped (it only lives a day).
    private static func cappedDomains(_ domains: [String: DaySplit], limit: Int = 100) -> [String: DaySplit] {
        guard domains.count > limit else { return domains }
        let top = domains.sorted { ($0.value.up + $0.value.down) > ($1.value.up + $1.value.down) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
    }

    /// Bounds the persisted per-rule map the same way: only the
    /// 100 most-hit rules survive a write.
    private static func cappedRuleHits(_ hits: [String: Int], limit: Int = 100) -> [String: Int] {
        guard hits.count > limit else { return hits }
        let top = hits.sorted { $0.value > $1.value }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
    }

    /// Counts one rule hit (v0.2.57, item 5): a connection
    /// counts ONCE, when it is first seen in the 1 s feed, for
    /// its `rule` value (ConcordConnection.rule — the rule that
    /// matched the connection; the Connections page already
    /// reads the same field). A connection with no rule adds
    /// nothing; a long-lived connection is never counted again
    /// on later polls.
    ///
    /// SAME UNDERCOUNT AS THE SPLIT: a connection that opens
    /// AND closes between two 1 s polls is never seen and
    /// contributes nothing, and traffic while the app is
    /// suspended is not observed. The counts are therefore a
    /// lower bound, and the sheet says so.
    private func noteRuleHit(_ connection: ConcordConnection) {
        guard accumDate == Self.todayString(),
              let rule = connection.rule, !rule.isEmpty else { return }
        ruleHitAccum[rule, default: 0] += 1
    }

    /// Attributes one connection's positive per-direction deltas
    /// to the split and the ranking buckets (called from
    /// refreshNodeSpeeds, after the first-sighting baseline).
    /// Only positive deltas count per direction; a negative
    /// delta is a counter reset / reused id and adds nothing.
    private func attributeConnectionTraffic(_ connection: ConcordConnection, upDelta: Int64, downDelta: Int64) {
        guard accumDate == Self.todayString() else { return }
        let up = max(0, upDelta)
        let down = max(0, downDelta)
        guard up > 0 || down > 0 else { return }
        if Self.isDirectConnection(connection) {
            splitDirectUp += up
            splitDirectDown += down
        } else {
            splitProxyUp += up
            splitProxyDown += down
        }
        if let group = connection.chains?.last, !group.isEmpty {
            var bucket = groupAccum[group] ?? DaySplit()
            bucket.up += up
            bucket.down += down
            groupAccum[group] = bucket
        }
        if let node = connection.chains?.first, !node.isEmpty {
            var bucket = nodeAccum[node] ?? DaySplit()
            bucket.up += up
            bucket.down += down
            nodeAccum[node] = bucket
        }
        if let host = connection.host, !host.isEmpty {
            var bucket = domainAccum[host] ?? DaySplit()
            bucket.up += up
            bucket.down += down
            domainAccum[host] = bucket
        }
    }

    /// MuYu's direct rule: the chain starts with DIRECT. When
    /// the chain is missing entirely, the `proxy` field decides
    /// (the sample data carries no chains; live core data does).
    static func isDirectConnection(_ connection: ConcordConnection) -> Bool {
        if let first = connection.chains?.first { return first == "DIRECT" }
        return connection.proxy == "DIRECT"
    }

    /// Sums the given local dates. Today always contributes the live
    /// accumulators — never a stored entry for today, so a stale
    /// provisional snapshot can neither double-count nor go stale
    /// after a same-day restart or a totals reset. Past days
    /// contribute their stored final (or provisional) total; days
    /// with no entry contribute zero. Uptime: today contributes
    /// the live cumulative value (today is observed, so the range
    /// has an uptime even at 0); a past day contributes only when
    /// it has a recorded uptime entry — days without one add
    /// nothing and leave hasUptime false when no day at all was
    /// recorded.
    func totalsForDates(_ dates: [String]) -> DayTotals {
        var result = DayTotals()
        let today = Self.todayString()
        for date in dates {
            if date == today {
                result.up += accumUp
                result.down += accumDown
                result.proxyUp += splitProxyUp
                result.proxyDown += splitProxyDown
                result.directUp += splitDirectUp
                result.directDown += splitDirectDown
                mergeRankings(into: &result, groups: groupAccum, nodes: nodeAccum, domains: domainAccum)
                mergeRuleHits(into: &result, from: ruleHitAccum)
                result.uptimeSeconds += todayUptimeSeconds
                result.hasUptime = true
                if accumUp > 0 || accumDown > 0 || dailyHistory[today] != nil {
                    result.recordedDays += 1
                }
            } else if let day = dailyHistory[date] {
                result.up += day.up
                result.down += day.down
                result.proxyUp += day.proxyUp
                result.proxyDown += day.proxyDown
                result.directUp += day.directUp
                result.directDown += day.directDown
                mergeRankings(into: &result, groups: day.groups, nodes: day.nodes, domains: day.domains)
                mergeRuleHits(into: &result, from: day.ruleHits)
                result.recordedDays += 1
            }
            // Uptime merges independently of the traffic entry:
            // a day can have recorded tunnel time with zero
            // traffic (tunnel up, nothing moved).
            if date != today, let seconds = uptimeByDay[date] {
                result.uptimeSeconds += seconds
                result.hasUptime = true
            }
        }
        return result
    }

    private func mergeRuleHits(into result: inout DayTotals, from hits: [String: Int]) {
        for (rule, count) in hits {
            result.ruleHits[rule, default: 0] += count
        }
    }

    private func mergeRankings(
        into result: inout DayTotals,
        groups: [String: DaySplit],
        nodes: [String: DaySplit],
        domains: [String: DaySplit]
    ) {
        for (name, split) in groups {
            var bucket = result.groups[name] ?? DaySplit()
            bucket.up += split.up
            bucket.down += split.down
            result.groups[name] = bucket
        }
        for (name, split) in nodes {
            var bucket = result.nodes[name] ?? DaySplit()
            bucket.up += split.up
            bucket.down += split.down
            result.nodes[name] = bucket
        }
        for (name, split) in domains {
            var bucket = result.domains[name] ?? DaySplit()
            bucket.up += split.up
            bucket.down += split.down
            result.domains[name] = bucket
        }
    }

    /// Today's totals (live accumulators) — the traffic card and
    /// the traffic sheet's day view read this one source so the
    /// two can never disagree.
    var todayTotals: DayTotals { totalsForDates([Self.todayString()]) }

    /// Clears the recorded daily history (traffic sheet trash
    /// button, MuYu trafficStatisticsClear): stored days, hourly
    /// buckets and today's live accumulators — so today restarts
    /// from zero everywhere. The core counters are NOT reset (no
    /// traffic.reset call); traffic after the clear is recorded
    /// fresh. Recorded per-day uptime is NOT cleared: it is
    /// tunnel time, not traffic statistics.
    @MainActor
    func clearDailyHistory() {
        dailyHistory = [:]
        hourlyHistory = [:]
        saveDailyHistory()
        accumUp = 0
        accumDown = 0
        resetDayAccumulators()
        lastSeenUp = current.totalUp
        lastSeenDown = current.totalDown
    }

    /// The traffic sheet's range (MuYu TrafficStatisticsRange):
    /// day = one local date, week = the rolling 7 days ending on
    /// the selected date (our week has always been rolling, not
    /// the calendar week), month = the calendar month. `offset`
    /// counts back from today (0 = current).
    func rangeDates(range: TrafficRange, offset: Int) -> [String] {
        let calendar = Calendar.current
        switch range {
        case .day:
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            return [Self.string(for: date)]
        case .week:
            let end = calendar.date(byAdding: .day, value: -offset * 7, to: Date()) ?? Date()
            return (0..<7).compactMap { delta in
                calendar.date(byAdding: .day, value: -delta, to: end)
            }.map { Self.string(for: $0) }
        case .month:
            guard let monthStart = calendar.date(
                byAdding: .month, value: -offset,
                to: calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
            ) else { return [Self.todayString()] }
            var result: [String] = []
            var date = monthStart
            let today = Date()
            while date <= today {
                result.append(Self.string(for: date))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
                // A past month ends at its last day; the loop's
                // `date <= today` guard stops a current month at
                // today. A past month would run past its end
                // without this month check.
                if offset > 0, calendar.component(.month, from: date) != calendar.component(.month, from: monthStart) { break }
            }
            return result
        }
    }

    /// The navigator label for a range (MuYu
    /// trafficStatisticsRangeLabel): "2026-11-20" for a day,
    /// "11-14 ~ 11-20" for a week window, "2026-11" for a month.
    func rangeLabel(range: TrafficRange, offset: Int) -> String {
        let calendar = Calendar.current
        switch range {
        case .day:
            return rangeDates(range: range, offset: offset).first ?? Self.todayString()
        case .week:
            let dates = rangeDates(range: range, offset: offset)
            guard let first = dates.last, let last = dates.first else { return "" }
            return "\(String(first.dropFirst(5))) ~ \(String(last.dropFirst(5)))"
        case .month:
            guard let monthStart = calendar.date(
                byAdding: .month, value: -offset,
                to: calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
            ) else { return "" }
            return String(Self.string(for: monthStart).prefix(7))
        }
    }

    private static func string(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
    /// The dashboard reads the faults directly as
    /// `trafficStore.engineStatus?.faults` (v0.2.86 item 11:
    /// ConcordServiceFault = service, address?, reason, message).
    @Published var engineStatus: ConcordEngineStatus?
    @Published var engineStatusError: String?
    @Published var lastError: String?

    /// Config warnings (v0.2.86 item 10, upstream
    /// lib/providers/app.dart ConfigWarningsState +
    /// lib/providers/actions/setup.dart _loadConfigWarnings): the
    /// warnings of the config the core last set up, read via
    /// core.lastWarnings. Pulled after a config apply / engine
    /// start succeeds (see refreshWarnings) and cleared when the
    /// engine snapshot goes unreadable — the warnings end with
    /// the core, as upstream's state clears when coreStatus is
    /// not connected.
    @Published var lastWarnings: [ConcordWarning] = []

    /// v0.2.86 item 16: the service-probe retry/backoff machine.
    /// It calls back into this store's probeServices /
    /// probeService — the execution layer stays here. Owned here
    /// so the dashboard reads one object
    /// (`trafficStore.serviceProbeStore`) and ProxyStore's weak
    /// link (wired in ConcordiOSApp, next to profileStore) points
    /// at the same instance.
    lazy var serviceProbeStore: ServiceProbeStore = ServiceProbeStore(trafficStore: self)

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
        // v0.2.125 (Part B): restore the last-known egress IP so
        // a cold start shows it instantly (upstream keepValue)
        // while the retry loop re-probes in the background.
        if let ip = UserDefaults.standard.string(forKey: Self.lastKnownIpKey),
           let country = UserDefaults.standard.string(forKey: Self.lastKnownIpCountryKey),
           !ip.isEmpty, !country.isEmpty {
            outboundIp = ip
            outboundIpInfo = ProbedIpInfo(ip: ip, countryCode: country)
            outboundIpIsStale = true
        }
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

    /// v0.2.82 (stats freeze / Tools lag): when true, the 1 s
    /// live tick skips its Dashboard-only work (traffic snapshot
    /// + engine status). All four tabs stay mounted, so the tick
    /// re-rendered the Dashboard every second even on Tools /
    /// Profiles, loading the main thread under scrolling and
    /// sheet presentation. Per-node speeds keep ticking (the
    /// Proxies tab needs them). ContentView sets this from the
    /// selected tab; default false (Dashboard selected at launch).
    var liveTickPaused = false

    func start() {
        stop()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    if !(self?.liveTickPaused ?? false) {
                        await self?.refresh()
                        // D11: the engine row rides the same 1 s tick
                        // as the traffic snapshot, otherwise it freezes
                        // after the first read.
                        await self?.refreshEngineStatus()
                        // The egress-IP probe is single-shot and can
                        // miss once (see maybeRetryOutboundIpProbe);
                        // retry while the tunnel runs and it is empty.
                        await self?.maybeRetryOutboundIpProbe()
                    }
                    // The per-node speeds ride the same 1 s tick as
                    // the traffic snapshot (MuYu updateTraffic).
                    await self?.refreshNodeSpeeds()
                }
            }
        Task { await refresh() }
        Task { await probe() }
        Task { await refreshMemory() }
        // v0.2.86 item 10: the engine may already be running when
        // the dashboard appears — pull the warnings of the config
        // now in force (upstream _loadConfigWarnings runs after a
        // successful setupConfig).
        Task { await refreshWarnings() }
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
            // changesOnly (v0.2.119): the extension only forwards a
            // traffic event when the sample changed, and this 1 s
            // snapshot read returns the same value while idle —
            // publishing it every tick re-rendered the Dashboard
            // every second for nothing. Skip the publish + history
            // point when all four fields equal `current`. The timer
            // itself, refreshEngineStatus / probe / node-speed ticks
            // and the daily-history maintenance below still run
            // every tick (maintenance is delta-based, so an unchanged
            // sample adds nothing, but its seeding and day-rollover
            // paths must not be skipped while idle). Any change —
            // including a fall back to zero, which the core emits
            // once because the totals moved — still publishes
            // immediately.
            if traffic.up != current.up || traffic.down != current.down
                || traffic.totalUp != current.totalUp || traffic.totalDown != current.totalDown {
                current = traffic
                history.append(TrafficPoint(date: Date(), up: traffic.up, down: traffic.down))
                if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
            }
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
                    // First sighting: one rule hit for this
                    // connection (see noteRuleHit). Baselines
                    // count too — the connection did match its
                    // rule; its bytes so far are still never
                    // attributed (no speed, no split).
                    noteRuleHit(c)
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
                guard let previous else {
                    // First sighting of this connection id: one
                    // rule hit, then baseline (no deltas yet).
                    noteRuleHit(c)
                    continue
                }
                let upDelta = (c.upload ?? 0) - previous.upload
                let downDelta = (c.download ?? 0) - previous.download
                guard upDelta > 0 || downDelta > 0 else { continue }
                // Same deltas feed the proxy/direct split and the
                // traffic sheet's rankings (group/node/domain) —
                // the split is observed from this feed only, so it
                // shares the sampler's limits (see the split notes
                // above: short-lived connections between polls and
                // traffic while suspended are never attributed).
                attributeConnectionTraffic(c, upDelta: upDelta, downDelta: downDelta)
                let up = upDelta > 0 ? Double(upDelta) / elapsed : 0
                let down = downDelta > 0 ? Double(downDelta) / elapsed : 0
                for name in Set(c.chains ?? []) {
                    let current = speeds[name] ?? .zero
                    speeds[name] = NodeSpeed(up: current.up + up, down: current.down + down)
                }
            }
            nodeSeen = nodeSeen.filter { currentIds.contains($0.key) }
            // v0.2.68 perf fix: the 1 s tick reassigns nodeSpeeds
            // every second even when nothing is flowing (VPN off /
            // idle), and every @Published fire re-renders the
            // expanded cards' speed rows. Skip the publish when
            // the map is unchanged.
            if nodeSpeeds != speeds {
                nodeSpeeds = speeds
            }
        } catch {
            // Stale snapshot while the tunnel is down
            // (connection.watch throws past its 10 s max-age):
            // keep the last map.
        }
    }

    /// v0.2.115: clears the egress-IP state so the probe re-runs
    /// for the new route — upstream refreshes the probe when the
    /// route changes. The Dashboard calls this on tunnel start.
    /// v0.2.125: the displayed IP itself is KEPT (upstream
    /// keepValue) and marked stale — only the failure flag and
    /// counters reset, so the card keeps showing the last-known
    /// IP while the re-probe runs.
    @MainActor
    func clearOutboundIp() {
        // v0.2.125 (Part B): keep the displayed IP (upstream
        // keepValue) — mark it stale so the retry loop re-probes
        // in the background instead of flashing a skeleton.
        outboundIpIsStale = outboundIp != nil
        outboundIpProbeFailed = false
        consecutiveExtensionProbeFailures = 0
        // v0.2.124: a fresh route gets a fresh fast-retry window
        // before the failure settles and shows (see
        // outboundIpFailureSettled) — otherwise a stale attempt
        // count from the old route would flash the failure on the
        // first tunnel-start probe miss.
        outboundIpProbeAttempts = 0
    }

    @MainActor
    func probe() async {
        guard !isProbingOutboundIp else { return }
        isProbingOutboundIp = true
        defer { isProbingOutboundIp = false }
        lastOutboundIpProbeAt = Date()
        // v0.2.118 (Job 5): which core this attempt asks — mirrors
        // probeOutboundIpThroughCore's branch, so the consecutive-
        // failure count only tracks the extension path (the longer
        // timeout only applies there).
        let usedExtensionCore = client.mode == .sample || TunnelManager.shared.isRunning
        do {
            let result = try await probeOutboundIpThroughCore()
            // v0.2.118 (Job 5): the core's own error was decoded
            // (ConcordOutboundIp.error) but never read — a probe
            // whose fetch failed inside the core (all 8 sources
            // failing through the engine) returned "successfully"
            // with error set, and the only record was the generic
            // "could not parse body". Surface the core's reason
            // in the diagnostics and keep retrying.
            if let coreError = result.error, !coreError.isEmpty {
                if usedExtensionCore { consecutiveExtensionProbeFailures += 1 }
                outboundIpProbeFailed = true
                IPLookupDiagnostics.recordError(
                    source: "probe.outboundIp",
                    error: NSError(
                        domain: "ConcordiOS", code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "probe.outboundIp: core error from \(result.url): \(coreError)"]))
                return
            }
            // v0.2.115: the core returns the RAW response body, so
            // parse it client-side per upstream parseOutboundIp
            // before anything reaches the status card.
            guard let parsed = parseOutboundIp(result) else {
                if usedExtensionCore { consecutiveExtensionProbeFailures += 1 }
                outboundIpProbeFailed = true
                // Leave outboundIp / outboundIpInfo untouched (nil)
                // so the retry loop keeps trying.
                IPLookupDiagnostics.recordError(
                    source: "probe.outboundIp",
                    error: NSError(
                        domain: "ConcordiOS", code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "probe.outboundIp: could not parse body from \(result.url)"]))
                return
            }
            consecutiveExtensionProbeFailures = 0
            outboundIp = parsed.ip
            outboundIpInfo = parsed
            outboundIpProbeFailed = false
            // v0.2.125 (Part B): persist the fresh IP so the next
            // cold start shows it instantly (upstream keepValue).
            UserDefaults.standard.set(parsed.ip, forKey: Self.lastKnownIpKey)
            UserDefaults.standard.set(parsed.countryCode, forKey: Self.lastKnownIpCountryKey)
            outboundIpIsStale = false
            // v0.2.125 (Part A): the local-proxy fetch returns
            // chains: [] — only overwrite when the core actually
            // reported chains, so the value doesn't flap.
            if !result.chains.isEmpty { outboundChains = result.chains }
            outboundIpProbeAttempts = 0
        } catch {
            if usedExtensionCore { consecutiveExtensionProbeFailures += 1 }
            lastError = error.localizedDescription
            outboundIpProbeFailed = true
            IPLookupDiagnostics.recordError(source: "probe.outboundIp", error: error)
            // v0.2.122 diagnostic (not a fix): the extension
            // answered nothing to probe.outboundIp 5× in 12 s
            // (00:11 VPN-on test) although it had started OK —
            // and the extension's handleAppMessage always replies
            // within 15 s when reached, so a fast nil reply means
            // the message never reached it or the IPC channel is
            // down. Distinguish the two with one cheap unary IPC
            // control call (core.stats, same sendProviderMessage
            // path, side-effect-free): if it also fails with
            // noReply the IPC channel is broken for all unary
            // calls; if it succeeds the failure is specific to
            // probe.outboundIp. Once per failure streak, so the
            // 3 s retry loop does not spam it.
            if usedExtensionCore, consecutiveExtensionProbeFailures == 1,
               case TunnelError.noReply = error {
                do {
                    _ = try await client.coreStats()
                    IPLookupDiagnostics.record("probe.outboundIp: noReply, control core.stats: ok (IPC works, failure is probe-specific)")
                } catch {
                    IPLookupDiagnostics.record("probe.outboundIp: noReply, control core.stats: \(error.localizedDescription)")
                }
            }
        }
    }

    /// v0.2.125 (Part A): the egress-IP lookup done app-side
    /// through the core's local mixed proxy (127.0.0.1:17890) —
    /// the extension core listens there while the VPN is up (and
    /// the in-app core on the same fixed ports when it is off;
    /// the two never run simultaneously). This routes around the
    /// dead app→extension RPC channel (log-confirmed: every
    /// sendProviderMessage returns nil while connected) with the
    /// same egress lookup by another transport: race the first 3
    /// ip-info sources, 3 s each, return the first that parses.
    /// v0.2.131: the race is two transports, not one — the local
    /// proxy AND a direct fetch. When the tunnel is up the app's
    /// own traffic goes through it and exits via the node, so the
    /// direct fetch returns the same egress IP without waiting
    /// for the extension's local proxy to be ready (~20 s after
    /// tunnel start on-device, 16:32:27–46). The first parseable
    /// candidate wins, either transport; a later local-proxy
    /// success overwrites, so the proxy stays authoritative.
    /// The 3 s per-source timeout keeps a cold proxy from
    /// stalling the probe longer than the RPC path's 6 s.
    private func probeOutboundIpViaLocalProxy() async throws -> ConcordOutboundIp {
        let proxyConfig: [AnyHashable: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 17890,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890,
        ]
        let proxySessionConfig = URLSessionConfiguration.ephemeral
        proxySessionConfig.connectionProxyDictionary = proxyConfig
        proxySessionConfig.timeoutIntervalForRequest = 3
        proxySessionConfig.timeoutIntervalForResource = 3
        let proxySession = URLSession(configuration: proxySessionConfig)
        // Direct (no proxy): goes through the VPN tunnel, not
        // through the core's local proxy — see the header comment.
        let directSessionConfig = URLSessionConfiguration.ephemeral
        directSessionConfig.connectionProxyDictionary = [:]
        directSessionConfig.timeoutIntervalForRequest = 3
        directSessionConfig.timeoutIntervalForResource = 3
        let directSession = URLSession(configuration: directSessionConfig)
        let startedAt = Date()
        let winner = await withTaskGroup(of: (ConcordOutboundIp, String)?.self) { group -> (ConcordOutboundIp, String)? in
            for (session, label) in [(proxySession, "local-proxy"), (directSession, "direct")] {
                for urlString in concordOutboundIpUrls.prefix(3) {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return nil }
                        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 3)),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let body = String(data: data, encoding: .utf8), !body.isEmpty else { return nil }
                        let candidate = ConcordOutboundIp(url: urlString, body: body,
                            delay: Int64(Date().timeIntervalSince(startedAt) * 1000),
                            chains: [], error: nil, epoch: 0, version: 0)
                        if parseOutboundIp(candidate) == nil { return nil }
                        return (candidate, label)
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        guard let (winner, label) = winner else {
            throw NSError(domain: "ConcordiOS", code: -2, userInfo: [NSLocalizedDescriptionKey: "no ip-info source answered (local-proxy 127.0.0.1:17890 + direct through tunnel)"])
        }
        IPLookupDiagnostics.record("\(label): \(winner.url) ok (\(winner.delay) ms)")
        return winner
    }

    /// Asks the tunnel core for the exit IP when it is up, or the
    /// in-app core (booted on demand) when the VPN is off (v0.2.115
    /// — MuYu probes the outbound IP at launch through the in-app
    /// core, so the status card fills with the tunnel down; the
    /// tunnel core is gone then, so the in-app core is the
    /// fallback, like probeServicesThroughCore). If the tunnel
    /// starts while AppCore is booting, AppCore refuses to run
    /// alongside it (AppCoreError.tunnelRunning) — the tunnel core
    /// is used instead, not reported as a failure.
    private func probeOutboundIpThroughCore() async throws -> ConcordOutboundIp {
        if client.mode == .sample || TunnelManager.shared.isRunning {
            // v0.2.125 (Part A): the app→extension RPC channel is
            // dead while the tunnel is connected (log-confirmed:
            // probe.outboundIp 7x TunnelError code 4 + the zombie
            // probe's config.general also code 4, status=connected)
            // — ask the core's local proxy first and keep RPC only
            // as the fallback. Sample mode has no core on 17890,
            // so it goes straight to RPC.
            if client.mode != .sample {
                do {
                    return try await probeOutboundIpViaLocalProxy()
                } catch {
                    IPLookupDiagnostics.record("local-proxy fetch failed (\(error.localizedDescription)); falling back to extension RPC")
                }
            }
            // v0.2.118 (Job 5): after 5 consecutive extension-
            // probe failures the probe retries with a 15 s timeout
            // instead of FlClash's 6 s (see the counter's comment).
            // The happy path keeps the 6 s default.
            let timeout: UInt64 = consecutiveExtensionProbeFailures >= 5 ? 15000 : 6000
            return try await client.probeOutboundIp(timeout: timeout)
        }
        do {
            try await AppCore.shared.ensureStarted()
        } catch {
            if case AppCoreError.tunnelRunning = error {
                return try await client.probeOutboundIp()
            }
            throw error
        }
        return try await AppCore.shared.probeOutboundIp()
    }

    /// Retries the egress-IP probe while the IP is still unknown,
    /// regardless of tunnel state (v0.2.115 — MuYu's keepAlive
    /// probe retries with the tunnel down too, so the status card
    /// fills at launch; the gate on TunnelManager.isRunning used
    /// to leave the card red until the VPN started). probe() is
    /// single-shot — it fires once in start() and once when the
    /// tunnel connects — and if that one attempt lands before the
    /// extension core's RPC is ready, the IPC throws and outboundIp
    /// stays nil forever, so the status card shows "检测失败"
    /// even though the VPN proxies fine (v0.2.93 on-device: the
    /// core log proves traffic flows, yet outboundIp was empty and
    /// ip-api.com also failed). v0.2.94 throttled the retry to one
    /// attempt per 10 s, which still left the card red at 7 s
    /// uptime on-device (the first probe at connect had failed and
    /// the retry was not due yet), so v0.2.95 retries every 3 s
    /// for the first 20 attempts, then every 10 s. v0.2.131
    /// tightens the first phase to every 1 s: the probe itself
    /// now usually lands in ~1 s (direct-through-tunnel race),
    /// and a 1 s retry means the badge updates within ~1 s of
    /// the proxy/probe becoming ready instead of up to 3 s late.
    /// The in-flight guard in probe() keeps a 6 s timeout attempt from
    /// overlapping itself. Called from the 1 s tick (Dashboard-only
    /// work).
    @MainActor
    private func maybeRetryOutboundIpProbe() {
        // v0.2.125: the gate is now "unknown OR stale" — a cached
        // IP (outboundIpIsStale) keeps re-probing in the background
        // until a fresh result lands, instead of going quiet.
        guard outboundIp == nil || outboundIpIsStale,
              !isProbingOutboundIp else { return }
        let interval: TimeInterval = outboundIpProbeAttempts < 20 ? 1 : 10
        if let last = lastOutboundIpProbeAt,
           Date().timeIntervalSince(last) < interval { return }
        outboundIpProbeAttempts += 1
        Task { await probe() }
    }

    @MainActor
    func refreshMemory() async {
        // VPN on: the in-app core is stopped, so core.stats has
        // nothing to answer — the tunnel core's memory comes from
        // its HTTP controller's /memory stream instead (v0.2.133).
        // The stream's first frame is 0 by design; memoryRSS skips
        // it and returns the next frame. A failed read keeps the
        // previous value — a transient miss must not blank a number
        // the card is showing (the 2 s poll retries it anyway).
        if TunnelManager.shared.isRunning {
            if let rss = await TunnelController.memoryRSS() {
                coreMemoryBytes = rss
            }
            return
        }
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
            let previousState = engineStatus?.state
            engineStatus = try await client.engineSnapshot()
            engineStatusError = nil
            // v0.2.86 item 10: the engine newly reaching "running"
            // means a config apply / engine start just completed
            // (upstream setup.dart calls _loadConfigWarnings after
            // setupConfig succeeds) — pull the warnings of the
            // config now in force. A new "failed" state is the
            // other upstream call site: _loadConfigWarnings also
            // runs when the core rejects a config, so the rejection
            // warnings are shown instead of the previous config's.
            if let state = engineStatus?.state, state != previousState,
               state == "running" || state == "failed" {
                await refreshWarnings()
            }
        } catch {
            engineStatus = nil
            engineStatusError = error.localizedDescription
            // The warnings end with the core (upstream
            // ConfigWarningsState clears when coreStatus is not
            // connected): the snapshot is unreadable, so the core
            // is gone and its config's warnings are stale.
            lastWarnings = []
        }
    }

    /// Reads the warnings of the config the core last set up
    /// (upstream _loadConfigWarnings: called after a successful
    /// setupConfig, and again when the core rejects a config so
    /// the rejection warnings are shown). On error the previous
    /// value is kept — a failed read must not wipe warnings the
    /// dashboard is showing, and must not crash.
    @MainActor
    func refreshWarnings() async {
        do {
            lastWarnings = try await client.lastWarnings()
        } catch {
            // Keep the previous value.
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
            services = try await probeServicesThroughCore(proxy: proxy, names: names ?? enabledServiceNames)
            servicesError = nil
        } catch {
            // v0.2.130: a cancelled probe (sheet closed, tunnel
            // state changed mid-sweep) is not a failure — don't
            // surface it as a sheet error.
            if !(error is CancellationError) {
                servicesError = error.localizedDescription
            }
        }
    }

    /// Runs one service probe against the tunnel core when it is
    /// up, or the in-app core (booted on demand) when the VPN is
    /// off (v0.2.89 Dashboard auto-check — MuYu probes services
    /// on entry even with the VPN off). Both cores are probed
    /// through the same channel — the local mixed proxy
    /// 127.0.0.1:17890 (ServiceProbeLocal), which the tunnel core
    /// serves while the VPN is up and the in-app core serves
    /// while it is off (same fixed ports). The in-app core's own
    /// probe.services RPC is NOT used: log-confirmed 15:46:19-43
    /// it dials DIRECT for the checks, so foreign services time
    /// out from China and the sheet sticks at "检测中" (12
    /// services in video f_020); and a tunnel start mid-probe
    /// kills the AppCore session, surfacing "核心会话已关闭" in
    /// the sheet (video f_015). The local-proxy path routes by
    /// the core's rules through the selected node instead
    /// (log-confirmed 15:47:33: local-proxy checks went "using
    /// 良心云[🇸🇬新加坡高速05]"), the same path that worked
    /// on-device in 127. If the tunnel starts while AppCore is
    /// booting, AppCore refuses to run alongside it
    /// (AppCoreError.tunnelRunning) — the tunnel core is used
    /// instead, not reported as a failure.
    private func probeServicesThroughCore(proxy: String, names: [String]) async throws -> [ConcordServiceItem] {
        if client.mode == .sample || TunnelManager.shared.isRunning {
            return try await probeServicesViaTunnel(proxy: proxy, names: names)
        }
        do {
            try await AppCore.shared.ensureStarted()
        } catch {
            if case AppCoreError.tunnelRunning = error {
                return try await probeServicesViaTunnel(proxy: proxy, names: names)
            }
            throw error
        }
        return try await ServiceProbeLocal.probeServices(proxy: proxy, names: names)
    }

    /// The tunnel-up service probe (v0.2.127): the app→extension
    /// RPC channel is dead (log-confirmed: probe.services gets
    /// noReply, code 4), so the 13 checks run in-app through the
    /// core's local mixed proxy first (same pattern as the
    /// v0.2.125 IP probe) and the RPC stays only as the fallback
    /// for an unexpected local error. Sample mode has no core on
    /// 17890, so it goes straight to RPC. A failed check is an
    /// item, never an error, so a whole-sweep transport failure
    /// returns 13 failed items (and ServiceProbeStore's confirm
    /// machine re-probes in 1 s) instead of falling back — the
    /// RPC is dead anyway, and throwing would leave services
    /// empty with only a manual retry to recover. Cancellation
    /// must NOT fall through to a 6 s RPC attempt, so it is
    /// rethrown as-is.
    private func probeServicesViaTunnel(proxy: String, names: [String]) async throws -> [ConcordServiceItem] {
        if client.mode != .sample {
            do {
                return try await ServiceProbeLocal.probeServices(proxy: proxy, names: names)
            } catch {
                if error is CancellationError { throw error }
                ServiceProbeDiagnostics.record("service-probe: local-proxy failed (\(error.localizedDescription)); falling back to extension RPC")
            }
        }
        return try await client.probeServices(proxy: proxy, names: names)
    }

    /// Re-checks one service and merges the result into the current
    /// list by name (the service sheet's per-row check): the full
    /// list is not replaced by a single item.
    @MainActor
    func probeService(proxy: String, name: String) async {
        do {
            let fresh = try await probeServicesThroughCore(proxy: proxy, names: [name])
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
