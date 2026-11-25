import SwiftUI

// MARK: - IP lookup diagnostics (v0.2.95 Bug 2)
//
// On-device v0.2.94 the Dashboard IP query still failed red, and
// nobody knew why: the app's URLSession requests never reached the
// core (no ip-api.com entry in the core log), so they died before
// TCP — most likely the app's DNS resolution — but every source
// swallowed its error (`catch { return false }`). These lines are
// the record of that: each failed source and each failed
// probe.outboundIp writes one timestamped line here (last 8 kept),
// and LogStore.fullExportText includes them, so the next on-device
// failure ships its cause in the log export instead of a bare red
// "IP 查询失败".
struct IPLookupDiagnostics {
    private static let storageKey = "concord.ipLookupDiagnostics"
    private static let maxLines = 8

    static func record(_ line: String) {
        var lines = UserDefaults.standard.string(forKey: storageKey)
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        lines.append("[\(timestamp())] \(line)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: storageKey)
    }

    static func lastDiagnosticText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
              !text.isEmpty else { return nil }
        return text
    }

    /// "source: <localizedDescription> (<domain> code <code>)" —
    /// the (domain, code) is what tells a DNS failure
    /// (NSURLErrorCannotFindHost, -1003) apart from a timeout
    /// (-1001) or a refused connection (-1004).
    static func recordError(source: String, error: Error) {
        let nsError = error as NSError
        record("\(source): \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Dashboard (reference screenshots IMG_1082 / IMG_1083)
// Layout, top to bottom: big title + edit button; status card (big
// blue play button); network speed; outbound mode pills; VPN card;
// service status (probe.services); the
// active subscription card; proxy groups; stats row. The DATA wiring
// is unchanged from the previous dashboard: proxyStore (running +
// groups), connectionStore, profileStore, ruleStore (provider list
// for the subscription info), settingsStore, eventStore / dnsStore
// (stats), tunnelManager and client. TrafficStore (speed + services
// + engine) is NOT observed here — v0.2.69 moved every read into
// narrow leaf views (see the MARK at the end of this file), so the
// 1 s traffic tick no longer re-evaluates this body. Only the look
// and the navigation changed.

struct DashboardView: View {
    /// Switches the main tab (called with .proxies / .profiles from
    /// the card chevrons).
    var onSelectTab: (AppTab) -> Void = { _ in }

    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var client: ConcordClient
    /// MITM modules awaiting consent (fork 2d31f10): the dashboard
    /// surfaces them in a card and asks about each in turn (fork
    /// 0a55a31) instead of only showing them in the modules list.
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    /// On-Demand state (Batch F): the VPN card shows whether
    /// auto-reconnect is on, and the unexpected-disconnect banner
    /// reads tunnelManager.unexpectedDisconnect.
    @ObservedObject private var onDemandStore = OnDemandStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @AppStorage("ConcordiOS.dashboard.show.status") private var showStatus = true
    @AppStorage("ConcordiOS.dashboard.show.speed") private var showSpeed = true
    @AppStorage("ConcordiOS.dashboard.show.mode") private var showMode = true
    @AppStorage("ConcordiOS.dashboard.show.vpn") private var showVpn = true
    @AppStorage("ConcordiOS.dashboard.show.services") private var showServices = true
    @AppStorage("ConcordiOS.dashboard.show.profile") private var showProfile = true
    @AppStorage("ConcordiOS.dashboard.show.groups") private var showGroups = true
    @AppStorage("ConcordiOS.dashboard.show.stats") private var showStats = true
    @AppStorage("ConcordiOS.dashboard.show.memory") private var showMemory = true
    @AppStorage("ConcordiOS.dashboard.show.update") private var showUpdate = true
    /// Traffic statistics card (MuYu TrafficStatisticsCard, D-M8):
    /// today's up/down + uptime, plus week/month totals from the
    /// daily history TrafficStore records since v0.2.55.
    @AppStorage("ConcordiOS.dashboard.show.traffic") private var showTraffic = true
    /// Compact density (FlClash layout.dart DashboardDensity.compact):
    /// smaller type, smaller start button and tiles, subtitles dropped.
    @AppStorage("ConcordiOS.dashboard.densityCompact") private var densityCompact = false
    /// Card order, comma-separated DashboardCardID raw values; empty
    /// means the default order (also used to append cards added by
    /// later versions).
    @AppStorage("ConcordiOS.dashboard.order") private var cardOrderString = ""

    /// Inline edit mode (v0.2.85, upstream dashboard.dart
    /// `_editing`): the pencil in the title row toggles editing
    /// on this page and becomes a check "done" — no sheet.
    @State private var isEditingDashboard = false
    /// Non-subscribing TrafficStore action channel (v0.2.69): this
    /// view no longer observes TrafficStore, so its body does not
    /// re-evaluate on the 1 s traffic tick. The DashboardTrafficEffects
    /// leaf observes the store and fills these closures on appear;
    /// the dashboard only *calls* them from user gestures
    /// (pull-to-refresh, the clover refresh), which never subscribe
    /// and never re-render the body.
    @State private var trafficActions = DashboardTrafficActions()
    @State private var servicesExpanded = false
    /// Service management sheet (D-M3): reorder + enable/disable
    /// the probe-service targets.
    @State private var showServiceManageSheet = false
    /// Stat-cell destination sheet (D-M6): live / recent
    /// connections, or the DNS queries page.
    @State private var statsDestination: StatsDestination?
    /// Traffic statistics detail sheet (D-M8, v0.2.56 MuYu
    /// TrafficStatisticsView).
    @State private var showTrafficDetail = false
    /// Outbound-IP sheet (status card, MuYu key_3).
    @State private var showOutboundIPSheet = false
    /// Service-status sheet (services card, MuYu key_7).
    @State private var showServiceSheet = false
    /// Rule-providers sheet (config card, MuYu key_25).
    @State private var showProvidersSheet = false
    /// Strategy-groups sheet (groups card, v0.2.64): upstream
    /// opens ProxiesView(picker: true) here instead of jumping
    /// to the Proxies tab.
    @State private var showGroupsSheet = false
    @State private var tunnelStartedAt: Date?
    @State private var subscription: ConcordSubscriptionInfo?
    @State private var ipInfo: IPQualityInfo?
    @State private var morphProgress: CGFloat = 0
    @State private var ipChecking = false
    @State private var ipFetchFailed = false
    /// In-flight guard for the egress-IP lookup (v0.2.101 issue
    /// 1b): .task, onChange(isRunning), pull-to-refresh and the
    /// manual re-fetch taps all funnel through fetchIPInfo(); with
    /// no guard two of them can run the 3-source sequence
    /// concurrently (TrafficStore.probe has isProbingOutboundIp;
    /// this lookup had none).
    @State private var ipFetchInFlight = false
    /// Backoff retry loop for a failed lookup (v0.2.101 issue 1b):
    /// at most one may exist. It sleeps 3 s / 5 s / 10 s (capped
    /// at 10 s) and re-calls fetchIPInfo while the tunnel runs and
    /// ipFetchFailed is set, mirroring
    /// TrafficStore.maybeRetryOutboundIpProbe (3 s for the first
    /// 20 attempts, then 10 s). A success, or the tunnel going
    /// down, ends the loop at its next wake.
    @State private var ipFetchRetryTask: Task<Void, Never>?
    /// The ip-api.com `as` field ("AS15169 Google LLC"), parsed to
    /// the bare "AS<n>" token for the org fallback (FlClash
    /// current_outbound.dart: organization ?? "AS{asn}").
    /// IPQualityInfo maps no `as` key, so it is decoded separately.
    @State private var ipAsn: String?
    /// Profile sync spinner (FlClash profiles.dart _SyncButton shows
    /// an activity indicator while the profile is updating).
    @State private var isSyncingProfile = false
    /// Memory detail sheet state (FlClash memory_info.dart).
    /// The app's own resident size (task_info) and the core RSS
    /// (core.stats) are read by the MemoryCardView leaf and the
    /// MemoryDetailSheetHost, not here.
    @State private var showMemoryDetail = false
    @State private var isReleasingMemory = false
    @State private var memoryReleaseMessage: String?
    /// Update card state (FlClash update_status.dart): reads the
    /// same UpdateChecker the About page uses; the last result is
    /// kept in AppStorage so the card shows something before the
    /// first check of the session.
    @State private var updateCheckMessage: String?
    @State private var isCheckingUpdate = false
    @AppStorage("ConcordiOS.update.lastSha") private var lastUpdateSha = ""
    @AppStorage("ConcordiOS.update.lastMessage") private var lastUpdateMessage = ""
    @AppStorage("ConcordiOS.update.lastDate") private var lastUpdateDate = ""
    @AppStorage("ConcordiOS.update.lastIsNew") private var lastUpdateIsNew = false
    @AppStorage("ConcordiOS.update.lastChecked") private var lastUpdateChecked = false
    /// The last probe fetch failed (no data): while running, the
    /// card shows "服务失败" instead of the loading skeletons.
    /// The module the dashboard is asking about (fork 0a55a31
    /// `reviewModules`), and whether its consent prompt is up.
    @State private var reviewModule: MitmModule?
    @State private var showReviewAlert = false

    // MARK: - Derived data

    private var tunnelStatusText: String {
        switch tunnelManager.status {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnecting: return "断开中"
        case .disconnected: return "已断开"
        case .reasserting: return "重新协商"
        case .invalid: return "未配置"
        @unknown default: return "未知"
        }
    }

    private func modeShortLabel(_ mode: OutboundMode) -> String {
        switch mode {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }

    private func modeIcon(_ mode: OutboundMode) -> String {
        switch mode {
        case .rule: return "list.bullet.rectangle"
        case .global: return "globe"
        case .direct: return "record.circle"
        }
    }

    /// Groups whose delay test failed (FlClash proxy_groups.dart
    /// _TimeoutChip: per group, delay < 0). Our client runs
    /// delay.test per node, never per group name, so a group's delay
    /// is derived from its nodes: a select group times out when its
    /// selected node's latency is negative; a group with no selected
    /// node (url-test/fallback) only when every tested node failed.
    private var timeoutCount: Int {
        proxyStore.nonHiddenGroups.filter { group in
            if let selected = group.selectedNodeName,
               let delay = proxyStore.latency(forNodeNamed: selected, inGroup: group) {
                return delay < 0
            }
            let tested = group.nodes.compactMap { proxyStore.latency(forNodeNamed: $0.name, inGroup: group) }
            return !tested.isEmpty && tested.allSatisfy { $0 < 0 }
        }.count
    }

    private var extraGroups: Int {
        max(0, proxyStore.nonHiddenGroups.count - 4)
    }

    // MARK: - Card order + density (FlClash dashboard/edit.dart)

    /// Card spacing and the big-number type shrink in compact density.
    private var stackSpacing: CGFloat { densityCompact ? 8 : 12 }
    private var playButtonSize: CGFloat { densityCompact ? 72 : 88 }
    private var bigNumberSize: CGFloat { densityCompact ? 20 : 25 }
    private var statNumberSize: CGFloat { densityCompact ? 19 : 24 }

    /// The stored order, repaired: unknown ids are dropped, cards
    /// added by later versions are appended at the end.
    private var orderedCards: [DashboardCardID] {
        var order = cardOrderString
            .split(separator: ",")
            .compactMap { DashboardCardID(rawValue: String($0)) }
        if order.isEmpty { order = DashboardCardID.defaultOrder }
        for id in DashboardCardID.allCases where !order.contains(id) {
            order.append(id)
        }
        return order
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.25"
    }

    private func checkForUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        if let result = await UpdateChecker.check() {
            updateCheckMessage = result.isNew ? "发现新提交" : "已是最新提交"
            lastUpdateSha = result.sha
            lastUpdateMessage = result.message
            lastUpdateDate = result.date
            lastUpdateIsNew = result.isNew
            lastUpdateChecked = true
        } else {
            updateCheckMessage = "检查更新失败（网络或 GitHub API 不可用）"
        }
    }

    // MARK: - Subscription traffic (provider.get subscriptionInfo)

    private var usedFraction: Double {
        guard let info = subscription, info.total > 0 else { return 0 }
        return Double(info.upload + info.download) / Double(info.total)
    }

    private var usedPercentText: String {
        guard subscription != nil else { return "—" }
        // FlClash profiles.dart _percentOf rounds the percent.
        return "\(Int((usedFraction * 100).rounded()))%"
    }

    private var trafficText: String {
        guard let info = subscription else { return "— / —" }
        return "\(ConcordFormat.bytes(info.upload + info.download)) / \(ConcordFormat.bytes(info.total))"
    }

    /// Profile-card end text (FlClash profiles.dart: expiry →
    /// "剩余 N 天", warn-coloured at ≤7 days with a tooltip giving
    /// the full date; no expiry → the source label 远程/本地/自定义).
    /// Our ProfileKind has only url/file, so 自定义 never occurs.
    private var profileEndText: String {
        guard let profile = profileStore.activeProfile else { return "—" }
        if let info = subscription, info.expire > 0 {
            return "剩余 \(ConcordRelativeTime.daysUntil(epochSeconds: info.expire)) 天"
        }
        return profile.kind == .url ? "远程" : "本地"
    }

    private var profileEndIsWarn: Bool {
        guard let info = subscription, info.expire > 0 else { return false }
        return ConcordRelativeTime.daysUntil(epochSeconds: info.expire) <= 7
    }

    /// Full expiry date for the tooltip (FlClash profileExpiresIn:
    /// "{date} 到期，剩余 N 天").
    private var profileEndTooltip: String? {
        guard let info = subscription, info.expire > 0 else { return nil }
        let days = ConcordRelativeTime.daysUntil(epochSeconds: info.expire)
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return "\(formatter.string(from: date)) 到期，剩余 \(days) 天"
    }

    private var updatedText: String {
        guard let date = profileStore.activeProfile?.updatedAt else { return "—" }
        return ConcordRelativeTime.string(since: date)
    }

    /// Reads the active profile's subscription info (provider.get).
    /// The provider whose name matches the active profile is tried
    /// first, then the first proxy provider. provider.list does not
    /// carry subscriptionInfo — only provider.get does — and the
    /// result is kept in local state (not in RuleStore, whose
    /// providerDetail also drives the Rules page sheets).
    private func refreshSubscription() async {
        await ruleStore.refresh()
        guard let profile = profileStore.activeProfile else {
            subscription = nil
            return
        }
        // Audit B37: the profile already carries its subscription
        // info (parsed from subscription-userinfo at download time,
        // Profile.subscriptionInfo) — use it first. It works with
        // the VPN off and does not depend on a provider whose name
        // happens to match the profile. provider.get is only the
        // fallback when the profile has no usable stored info (e.g.
        // imported before this field existed).
        if let stored = profile.subscriptionInfo, stored.total > 0 || stored.expire > 0 {
            subscription = ConcordSubscriptionInfo(upload: stored.upload, download: stored.download, total: stored.total, expire: stored.expire)
            return
        }
        let candidates = ruleStore.providers
        guard let provider = candidates.first(where: { $0.name == profile.name })
            ?? candidates.first(where: { $0.type == "proxy" }) else {
            subscription = nil
            return
        }
        do {
            subscription = try await client.providerGet(name: provider.name).subscriptionInfo
        } catch {
            subscription = nil
        }
    }

    /// Public-IP lookup. ip-api.com first (full geo/org/ASN answer,
    /// 10 s) — but on-device 0.2.93 the ip-api.com request died
    /// before TCP (the core never saw it: most likely the app's DNS
    /// resolution of ip-api.com), so a single source leaves the
    /// status card red even though the VPN proxies fine. Fall back
    /// to ident.me/json (8 s) and then api.ipify.org?format=json
    /// (8 s, IP only): first success wins and clears ipFetchFailed;
    /// only an all-sources failure sets it. v0.2.101 issue 1b: an
    /// all-sources failure now schedules a backoff retry (3 s /
    /// 5 s / 10 s, capped) while the tunnel runs, and concurrent
    /// callers are held off by an in-flight guard; the first query
    /// after connect waits until 4 s after the tunnel started, so
    /// it does not run while the app's DNS/routing is still
    /// settling. The fallbacks carry
    /// only the IP (ident.me also fills country + code / city /
    /// ASN when present) — enough for the status card's fallbackQuery; the
    /// geo/org enrichment stays ip-api.com-only. The lookup runs
    /// even while the VPN is off, but the status card does NOT show
    /// the result then: FlClash shows grey skeleton bars while the
    /// core is not running, the real IP only once it is running.
    /// When the VPN is on, URLSession follows the tunnel, so the
    /// answer is the proxy egress IP; when it is off, it is the
    /// phone's direct IP.
    private func fetchIPInfo() async {
        // v0.2.101 issue 1b: in-flight guard — .task and
        // onChange(isRunning) can fire at the same moment (appear
        // while the tunnel is connecting), and a manual re-fetch
        // tap can land mid-sequence; the second caller returns
        // instead of running a duplicate 3-source lookup.
        guard !ipFetchInFlight else { return }
        ipFetchInFlight = true
        defer { ipFetchInFlight = false }
        // v0.2.101 issue 1b: the first query after connect used to
        // run in the instant the tunnel came up, when the app
        // process's DNS/routing is not yet stable — all three
        // sources fast-fail and the card stays red until a manual
        // re-fetch. Wait until 4 s after the tunnel started
        // before querying (no delay when the tunnel has been up
        // for a while, or its start time is unknown).
        if proxyStore.isRunning, let started = tunnelStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 4 {
                try? await Task.sleep(nanoseconds: UInt64((4 - elapsed) * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
        ipChecking = true
        defer { ipChecking = false }
        // Interface B3 (DashboardView part): a stalled ip-api.com
        // used to hang this lookup forever (URLSession.shared
        // defaults: 60 s request / 7 days resource). 10 s, then
        // the next source is tried instead of hanging.
        if await fetchIPInfoFromIpApi() { return }
        if await fetchIPInfoFromIdentMe() { return }
        if await fetchIPInfoFromIpify() { return }
        // No source answered: keep the previous (or empty) values —
        // the card shows "服务失败" while running, or the skeleton
        // bars while not running, instead of stale numbers.
        IPLookupDiagnostics.record("all IP sources failed")
        ipFetchFailed = true
        // v0.2.101 issue 1b: no auto-retry used to leave the card
        // red until the user tapped re-fetch (which just calls
        // this same function later, when the tunnel DNS is
        // stable). Schedule the backoff retry loop instead.
        scheduleIPFetchRetry()
    }

    /// Backoff retry loop for a failed egress-IP lookup (v0.2.101
    /// issue 1b): 3 s, then 5 s, then 10 s, capped at 10 s. The
    /// loop re-checks before every attempt and stops as soon as
    /// the tunnel is down or a fetch succeeds; scheduleIPFetchRetry
    /// is a no-op while a loop already exists, so concurrent
    /// failures never start a second one.
    private func scheduleIPFetchRetry() {
        guard ipFetchRetryTask == nil else { return }
        ipFetchRetryTask = Task {
            let delays: [TimeInterval] = [3, 5, 10]
            var attempt = 0
            while proxyStore.isRunning && ipFetchFailed {
                let delay = delays[min(attempt, delays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard proxyStore.isRunning && ipFetchFailed else { break }
                attempt += 1
                await fetchIPInfo()
            }
            ipFetchRetryTask = nil
        }
    }

    /// ip-api.com (primary): the only source returning the full
    /// geo/org/ASN answer in one shape. True when it answered.
    private func fetchIPInfoFromIpApi() async -> Bool {
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting") else { return false }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                IPLookupDiagnostics.record("ip-api.com: HTTP \(status)")
                return false
            }
            let decoded: IPQualityInfo
            do {
                decoded = try JSONDecoder().decode(IPQualityInfo.self, from: data)
            } catch {
                IPLookupDiagnostics.record("ip-api.com: decode failed: \(error.localizedDescription)")
                return false
            }
            guard decoded.status == "success" else {
                IPLookupDiagnostics.record("ip-api.com: status \(decoded.status ?? "?")")
                return false
            }
            ipInfo = decoded
            ipAsn = (try? JSONDecoder().decode(IPApiAsField.self, from: data))?.asNumber
            ipFetchFailed = false
            return true
        } catch {
            IPLookupDiagnostics.recordError(source: "ip-api.com", error: error)
            return false
        }
    }

    /// ident.me/json (fallback): {"ip","country","cc","city","aso",
    /// "asn","timezone",...} — the IP plus geo/ASN when present.
    /// Its "asn" is a string ("AS13335") or a number; ipAsn keeps
    /// the bare "AS<n>" token like the ip-api.com path. Its country
    /// code is the "cc" field ("HK") — "country" is the full name
    /// ("Hong Kong"), so reading only "country" leaves the clover
    /// badge on the globe while upstream/MuYu shows the code.
    private func fetchIPInfoFromIdentMe() async -> Bool {
        guard let url = URL(string: "https://ident.me/json") else { return false }
        do {
            let request = URLRequest(url: url, timeoutInterval: 8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                IPLookupDiagnostics.record("ident.me: HTTP \(status)")
                return false
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = json["ip"] as? String, !ip.isEmpty else {
                IPLookupDiagnostics.record("ident.me: decode failed")
                return false
            }
            ipInfo = IPQualityInfo(
                status: "success", message: nil,
                country: json["country"] as? String, countryCode: json["cc"] as? String,
                city: json["city"] as? String, regionName: nil,
                isp: json["aso"] as? String, org: json["aso"] as? String,
                asn: identMeAsn(json["asn"]), timezone: json["timezone"] as? String,
                query: ip, lat: nil, lon: nil)
            ipAsn = identMeAsn(json["asn"])
            ipFetchFailed = false
            return true
        } catch {
            IPLookupDiagnostics.recordError(source: "ident.me", error: error)
            return false
        }
    }

    /// api.ipify.org (last resort): {"ip": "..."} — IP only.
    /// Enough for the status card's fallbackQuery so the red error
    /// clears; it carries no ASN, so ipAsn is cleared with it.
    private func fetchIPInfoFromIpify() async -> Bool {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return false }
        do {
            let request = URLRequest(url: url, timeoutInterval: 8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                IPLookupDiagnostics.record("api.ipify.org: HTTP \(status)")
                return false
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = json["ip"] as? String, !ip.isEmpty else {
                IPLookupDiagnostics.record("api.ipify.org: decode failed")
                return false
            }
            ipInfo = IPQualityInfo(
                status: "success", message: nil, country: nil, countryCode: nil,
                city: nil, regionName: nil, isp: nil, org: nil, asn: nil,
                timezone: nil, query: ip, lat: nil, lon: nil)
            ipAsn = nil
            ipFetchFailed = false
            return true
        } catch {
            IPLookupDiagnostics.recordError(source: "api.ipify.org", error: error)
            return false
        }
    }

    /// ident.me's "asn" is a string ("AS13335") or a number — both
    /// become the bare "AS<n>" token ipAsn keeps.
    private func identMeAsn(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return "AS\(n.intValue)" }
        return nil
    }

    /// The ip-api.com answer assessed like upstream (D-D3): the
    /// type and level come from the real hosting/mobile/proxy
    /// flags — the old code derived "质量 优/良/差" from the
    /// lookup latency, which says nothing about the IP. ip-api.com
    /// states no type, so silence about hosting/mobile reads as
    /// residential, flagged inferred (upstream _pickType fallback).
    private var assessedIpInfo: IPQualityInfo? {
        guard let info = ipInfo else { return nil }
        let type: IpQualityType = info.hosting == true ? .hosting
            : (info.mobile == true ? .mobile : .residential)
        let inferred = info.hosting != true && info.mobile != true
        return info.assessed(type: type, inferred: inferred, isProxy: info.proxyFlag == true)
    }

    private func refreshAll() async {
        tunnelManager.checkTunRestartNeeded()
        // D4: correct the uptime from the extension's start time
        // when the tunnel is up (the local clock started when the
        // app observed .connected, which is later — and resets to
        // zero on every app restart while the VPN keeps running).
        if proxyStore.isRunning, let extStarted = tunnelManager.readTunnelStartedAt() {
            tunnelStartedAt = extStarted
            // The traffic card's cumulative uptime counts this
            // session from the extension's start time.
            await trafficActions.noteTunnelStarted(extStarted)
        }
        await proxyStore.refresh()
        await connectionStore.refresh()
        await trafficActions.refresh()
        await trafficActions.refreshEngineStatus()
        // v0.2.86 item 10: a transient snapshot failure clears the
        // warnings (TrafficStore.refreshEngineStatus); a manual
        // refresh re-pulls them so the pill does not stay empty.
        await trafficActions.refreshWarnings()
        await eventStore.refresh()
        await dnsStore.refresh()
        await refreshSubscription()
        await fetchIPInfo()
    }

    // MARK: - Body

    var body: some View {
        dashboardScrollContent
            .concordPageBackground()
            .refreshable { await refreshAll() }
        // v0.2.69: the tunnel bookkeeping, engine refresh and
        // service probing that used to live in this view's .task /
        // .onChange now live in DashboardTrafficEffects (below),
        // a leaf that observes TrafficStore. Its body is clear
        // colour, so the 1 s traffic tick re-evaluates almost
        // nothing; this view stays unsubscribed.
        .background { dashboardTrafficEffects }
        .onChange(of: settingsStore.mode) { _, _ in
            Task { await settingsStore.applyGeneralToCore() }
        }
        .sheet(isPresented: $showMemoryDetail) { memoryDetailSheet }
        .sheet(isPresented: $showTrafficDetail) { trafficDetailSheet }
        .sheet(isPresented: $showOutboundIPSheet) { outboundIPSheet }
        .sheet(isPresented: $showServiceSheet) { serviceStatusSheet }
        .sheet(isPresented: $showProvidersSheet) { providersSheetContent }
        .sheet(isPresented: $showGroupsSheet) { groupsSheetContent }
        .sheet(item: $statsDestination) { statsSheetContent(for: $0) }
        .sheet(isPresented: $showServiceManageSheet) { serviceManageSheet }
        // The dashboard's consent prompt (fork 0a55a31): the same
        // prompt the modules page uses, asked over the dashboard
        // for each module that awaits an answer in turn; an answer
        // either way takes the module off the card.
        .alert(reviewAlertTitle, isPresented: $showReviewAlert, presenting: reviewModule) { module in
            Button("取消", role: .cancel) {
                Task { await answerReview(module, agreed: false) }
            }
            Button("启用") {
                Task { await answerReview(module, agreed: true) }
            }
        } message: { module in
            Text(mitmModuleStore.consentPrompt(for: module)?.message ?? "")
        }
    }

    // MARK: - Body sections (v0.2.86)
    //
    // body was ~275 lines — past the type-check risk line, and a
    // timeout can mask real errors in the same file. Each section
    // below is one small property or helper; behaviour is
    // unchanged, only the grouping moved.

    /// The scrolling card list: title row, sample badge, pending
    /// modules, the inline edit panel, the ordered cards, and the
    /// start-error line.
    private var dashboardScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: stackSpacing) {
                titleRow
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("示例数据：所有数值均为内置示例，不是真实核心数据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                pendingModulesCard
                // v0.2.85: inline edit panel (upstream `_editing`)
                // sits above the cards, which stay visible below
                // so toggles and reordering apply live.
                if isEditingDashboard { dashboardEditPanel }
                ForEach(orderedCards, id: \.self) { cardView(for: $0) }
                if let error = proxyStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
    }

    /// The TrafficStore-observing leaf (v0.2.69): tunnel
    /// bookkeeping, engine refresh and service probing. A
    /// property so the .background modifier in body stays one line.
    private var dashboardTrafficEffects: some View {
        DashboardTrafficEffects(
            tunnelStartedAt: $tunnelStartedAt,
            morphProgress: $morphProgress,
            ipInfo: $ipInfo,
            ipAsn: $ipAsn,
            ipFetchFailed: $ipFetchFailed,
            trafficActions: $trafficActions,
            statsDestination: $statsDestination,
            fetchIPInfo: fetchIPInfo,
            refreshSubscription: refreshSubscription
        )
    }

    /// Memory detail sheet. v0.2.69: the sheet's core-bytes read
    /// lives in the host leaf, which observes TrafficStore; this
    /// view no longer reads the store.
    private var memoryDetailSheet: some View {
        MemoryDetailSheetHost(
            isReleasing: $isReleasingMemory,
            releaseMessage: $memoryReleaseMessage
        )
        .presentationDetents([.fraction(0.5625), .fraction(0.9)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(ConcordTheme.pageBackground)
        .presentationCornerRadius(28)
    }

    /// v0.2.56: the traffic card opens the MuYu traffic sheet
    /// (日/周/月， date navigator, 流量概括， rankings) — it
    /// reads TrafficStore directly, so its figures always
    /// match the card's.
    private var trafficDetailSheet: some View {
        TrafficStatsSheet()
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    /// v0.2.56: the status card opens the 出站 IP sheet
    /// (MuYu key_3). v0.2.69: the egress-IP read and the core
    /// probe live in the host leaf, which observes TrafficStore.
    private var outboundIPSheet: some View {
        OutboundIPSheetHost(
            hideIp: $settingsStore.hideIp,
            ipInfo: ipInfo,
            assessed: assessedIpInfo,
            ipAsn: ipAsn,
            isChecking: ipChecking,
            fetchFailed: ipFetchFailed,
            fetchIPInfo: fetchIPInfo
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(ConcordTheme.pageBackground)
        .presentationCornerRadius(28)
    }

    /// v0.2.56: the services card opens the 服务状态 sheet
    /// (MuYu key_7).
    private var serviceStatusSheet: some View {
        ServiceStatusSheet()
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    /// v0.2.56: the config card opens the rule-providers
    /// sheet (MuYu key_25).
    private var providersSheetContent: some View {
        ProvidersSheet(profileName: profileStore.activeProfile?.name ?? "配置", subscription: subscription)
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    /// v0.2.64: the 策略组 card opens this sheet (upstream
    /// FlClash proxy_groups.dart showProxiesSheet) instead of
    /// jumping straight to the Proxies tab.
    private var groupsSheetContent: some View {
        groupsSheet
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    /// D-M6: a stat cell opens its source page — live/recent
    /// connections, or the DNS queries page for the DNS cell.
    /// v0.2.68: MuYu sheet chrome — no NavigationStack, no
    /// system nav bar; each content view renders its own
    /// MuYu header (handle + ✕ + title + actions) and a
    /// bottom floating search bar.
    /// v0.2.84: upstream FlClash openDashboardFeed passes the
    /// feed straight to the sheet builder (showSnapSheet +
    /// NestedPagedSheet) — one item, no separate Bool. The
    /// v0.2.83 two-state pattern (statsDestination + a
    /// showStatsSheet Bool, content behind `if let`) presented
    /// a blank sheet: the content read a nil destination and
    /// rendered nothing, and a blank sheet with a hidden drag
    /// indicator and no ✕ cannot be dismissed, so the app
    /// looked frozen. .sheet(item:) hands the destination to
    /// the content directly, so it cannot be nil. Detents
    /// match upstream snapSheetDetents [9/16, 0.9]: opens at
    /// the short detent, drags to 90%.
    private func statsSheetContent(for destination: StatsDestination) -> some View {
        Group {
            switch destination {
            case .live:
                ConnectionsView(initialFeed: .live, sheetChrome: true)
            case .recent:
                ConnectionsView(initialFeed: .recent, sheetChrome: true)
            case .dns:
                DnsQueriesView(mode: .sheet)
            }
        }
        .presentationDetents([.fraction(0.5625), .fraction(0.9)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(ConcordTheme.pageBackground)
        .presentationCornerRadius(28)
    }

    /// D-M3: manage the probe-service targets (order + enabled).
    private var serviceManageSheet: some View {
        ServiceManageSheet()
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.visible)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    // MARK: - Modules awaiting consent (fork 2d31f10 + 0a55a31)

    /// The pending-modules card (fork live_status_deck
    /// `MitmConsentStatus`): shown only while a module awaits
    /// consent. It is a status card, not a user-ordered dashboard
    /// card, so it sits above the ordered cards and cannot be
    /// hidden in the edit sheet.
    @ViewBuilder
    private var pendingModulesCard: some View {
        let pending = mitmModuleStore.modulesAwaitingConsent
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    CardTitleRow(icon: "puzzlepiece.extension", title: "模块已关闭")
                    Spacer()
                    PillBadge(text: "\(pending.count) 个待确认", tint: .orange)
                }
                Text(pending.count == 1
                     ? "\(pending[0].name) 的更新带来了你未同意过的脚本或网络改动"
                     : "\(pending.count) 个模块的更新带来了你未同意过的脚本或网络改动")
                    .font(.footnote)
                    .foregroundStyle(Color(.label))
                Button("查看") { reviewNext() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
            .concordCard()
        }
    }

    /// The prompt title for the module the dashboard is asking about.
    private var reviewAlertTitle: String {
        reviewModule.flatMap { mitmModuleStore.consentPrompt(for: $0)?.title } ?? "启用此模块？"
    }

    /// Starts the review: the first module awaiting consent.
    private func reviewNext() {
        reviewModule = mitmModuleStore.firstAwaitingConsent()
        showReviewAlert = reviewModule != nil
    }

    /// Records the answer and moves on to the next module awaiting
    /// consent, or closes the prompt when none is left.
    private func answerReview(_ module: MitmModule, agreed: Bool) async {
        await mitmModuleStore.answerConsent(module, agreed: agreed)
        if let next = mitmModuleStore.firstAwaitingConsent() {
            reviewModule = next
            showReviewAlert = true
        } else {
            reviewModule = nil
        }
    }

    // MARK: - Card dispatch (order + visibility)

    @ViewBuilder
    private func cardView(for id: DashboardCardID) -> some View {
        switch id {
        case .status:
            // FlClash widget_registry.dart: the status card is
            // non-removable ("含启动键，不可移除") — it always renders,
            // even if an older install saved showStatus = false.
            VStack(alignment: .leading, spacing: 8) {
                statusCard
                // Start failure (v0.2.31): start() can throw in
                // prepare()/startVPNTunnel() before the status
                // ever leaves .disconnected, so without this the
                // play button shows no spinner and no banner —
                // just silence. Show the reason under the card.
                if let startError = proxyStore.startError, !proxyStore.isRunning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("启动失败：\(startError)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 4)
                }
            }
        case .speed: if showSpeed { speedCard }
        case .traffic: if showTraffic { trafficCard }
        case .mode: if showMode { modeCard }
        case .vpn: if showVpn { vpnCardSection }
        case .services: if showServices { servicesCard }
        case .profile: if showProfile { profileCard }
        case .groups: if showGroups { groupsCard }
        case .stats: if showStats { statsCard }
        case .memory: if showMemory { memoryCard }
        // D-D1: the update card only shows while a check is running
        // or a newer commit was found — a quiet "已是最新" card is
        // noise on every dashboard open. Checking is still offered
        // from the About page when the card is hidden.
        case .update: if showUpdate && (isCheckingUpdate || lastUpdateIsNew) { updateCard }
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .center) {
            // FlClash pageTitle is 24pt semibold on a tab page
            // (scaffold.dart:780); the 18pt bold here was the
            // v0.2.50-era guess. Pushed pages keep 17pt inline.
            Text("tab.dashboard".l10n)
                .font(.system(size: 24, weight: .bold))
            Spacer()
            // v0.2.86: upstream dashboard.dart statusActions —
            // the faults badge first, then the live-status
            // (warnings) pill; both hidden while editing. Both
            // are TrafficStore leaves, so the 1 s tick never
            // re-evaluates this view (v0.2.69).
            if !isEditingDashboard {
                DashboardServiceFaultsBadge()
                DashboardWarningsPill()
            }
            // D-M2: core-status button — shown only while the VPN
            // is off, one tap starts it (the same path as the play
            // button). There is no separate core-restart API: the
            // core lives in the extension and starts with the VPN.
            if !proxyStore.isRunning {
                Button {
                    Task { await proxyStore.toggle() }
                } label: {
                    Label("启动", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(ConcordTheme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("启动 VPN")
            }
            // v0.2.85: inline edit mode (upstream dashboard.dart
            // `_editing`) — the pencil toggles editing on this
            // page and becomes the check "done"; no sheet.
            Button { isEditingDashboard.toggle() } label: {
                if isEditingDashboard {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(editButtonIconColor)
                        .frame(width: 44, height: 44)
                        .background(editButtonBackground, in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                } else {
                    ThickPencilIcon(iconColor: editButtonIconColor, bandColor: editButtonBackground)
                        .frame(width: 44, height: 44)
                        .background(editButtonBackground, in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditingDashboard ? "完成编辑" : "编辑仪表盘卡片")
        }
    }

    /// Top-right button state (user request): while the VPN/core is
    /// running the button turns light blue in light mode and dark
    /// blue in dark mode; when not running it keeps its default
    /// white circle. Tied to proxyStore.isRunning — the same state
    /// that drives the play button and the "运行中/未运行" pill.
    private var editButtonBackground: Color {
        guard proxyStore.isRunning else { return ConcordTheme.cardBackground }
        return colorScheme == .dark
            ? Color(red: 0.10, green: 0.28, blue: 0.60)
            : Color(red: 0.83, green: 0.92, blue: 1.0)
    }

    private var editButtonIconColor: Color {
        guard proxyStore.isRunning else { return Color(.label) }
        return colorScheme == .dark ? .white : ConcordTheme.accent
    }

    // MARK: - Inline edit panel (v0.2.85, upstream `_editing`)
    //
    // The old DashboardEditSheet (a List with .onMove drag
    // handles) cannot live inside this page's ScrollView — a
    // List nested in a ScrollView breaks scrolling — so the
    // order rows reorder with ↑/↓ buttons instead of drag
    // handles. Same toggles, same order, same persistence
    // (cardOrderString); the cards stay visible below the
    // panel, so every change applies live.

    private var dashboardEditPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑仪表盘")
                .font(.headline)
            Text("状态卡片含启动键，不可移除。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("网络速度", isOn: $showSpeed)
            Toggle("流量统计", isOn: $showTraffic)
            Toggle("出站模式", isOn: $showMode)
            Toggle("VPN", isOn: $showVpn)
            Toggle("服务状态", isOn: $showServices)
            Toggle("配置", isOn: $showProfile)
            Toggle("策略组", isOn: $showGroups)
            Toggle("统计", isOn: $showStats)
            Toggle("内存", isOn: $showMemory)
            Toggle("更新状态", isOn: $showUpdate)
            Divider()
            Toggle("紧凑密度", isOn: $densityCompact)
            Text("紧凑模式缩小字号与启动按钮、收紧卡片间距，并隐藏部分副标题（FlClash DashboardDensity.compact）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            Text("卡片顺序")
                .font(.subheadline.weight(.semibold))
            ForEach(orderedCards, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(id.title)
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Button { moveCard(id, by: -1) } label: {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(orderedCards.first == id)
                    Button { moveCard(id, by: 1) } label: {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(orderedCards.last == id)
                }
            }
            Text("点上下箭头调整顺序，关闭的卡片会从仪表盘隐藏，可随时再打开。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.semibold))
        .concordCard()
    }

    /// Moves one card one slot up (-1) or down (+1) in the
    /// stored order (same cardOrderString write the old edit
    /// sheet's .onMove used).
    private func moveCard(_ id: DashboardCardID, by offset: Int) {
        var order = orderedCards
        guard let index = order.firstIndex(of: id) else { return }
        let newIndex = index + offset
        guard order.indices.contains(newIndex) else { return }
        order.swapAt(index, newIndex)
        cardOrderString = order.map(\.rawValue).joined(separator: ",")
    }

    // Content states (FlClash _ExitRow / _IpChips / _Cells): while
    // the core is not running the IP slot is a static grey bar, the
    // chips slot two static grey bars and the org slot one static
    // grey bar; while running, the probe loading shows pulsing
    // skeletons, and answered data shows the real IP / chips / org.
    // The middle row is [country badge] [IP + pills] [play button];
    // the bottom row is 运行时间 / 组织 (org from the same lookup).

    // MARK: - Status card (FlClash CurrentOutboundCard, mobile metrics)
    //
    // Layout transcribed from the FlClash source: a Row of the left
    // column (header, ipTop 12, exit row, 16, cells) and the 88pt
    // button slot, the button vertically centred on the whole row;
    // padding 20/18/16/18, gap 10, cellGap 24. The card height comes
    // out of these metrics (~181pt) — no spacer. The grey wave is
    // _StatusWavePainter, painted behind the content and clipped to
    // the card's rounded rect (34pt, the FlClash mobile card radius).

    /// Chips slot (FlClash _IpChips): two static grey bars while
    /// not running, two pulsing pills while running and loading,
    /// the real network-type + quality pills once probed, a retry
    /// hint if the probe failed.
    private var chipsSlot: some View {
        Group {
            if !proxyStore.isRunning {
                HStack(spacing: 6) {
                    SkeletonBar(width: 48, height: 28)
                    SkeletonBar(width: 72, height: 28)
                }
            } else if ipInfo != nil {
                HStack(spacing: 8) {
                    // v0.2.68: the first chip is the EXIT IP's type
                    // (机房/住宅/… from the assessed lookup) when
                    // known; the device network type is only the
                    // fallback when there is no lookup yet.
                    if let ipType = assessedIpInfo?.qualityType?.label {
                        PillBadge(text: ipType, tint: .gray)
                    } else {
                        PillBadge(text: DeviceNetwork.currentNetworkType(), tint: .gray)
                    }
                    if let assessed = assessedIpInfo, let level = assessed.qualityLevel {
                        // D-D3: the quality pill comes from the real
                        // IP type/level (hosting → 普通, else 优),
                        // not from the lookup latency.
                        qualityPill(text: "质量 \(level.label)", level: level)
                    } else {
                        // FlClash _IpChips: quality null and not
                        // loading shows a "类型未知" chip.
                        PillBadge(text: "类型未知", tint: .gray)
                    }
                }
            } else if ipFetchFailed {
                Text("点击图标重试")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    SkeletonBar(width: 48, height: 28, animated: true)
                    SkeletonBar(width: 72, height: 28, animated: true)
                }
            }
        }
        .frame(height: 28, alignment: .leading)
    }

    /// Org cell (FlClash _Cells): a static grey bar (full-opacity
    /// #ECE9EB) while not running, a pulsing skeleton while running
    /// and loading, the real org once probed (falling back to the
    /// "AS<n>" token, FlClash: organization ?? "AS{asn}"), "—" if
    /// the probe answered without an org or failed.
    private var orgValue: some View {
        Group {
            if !proxyStore.isRunning {
                SkeletonBar(width: 96, height: 12)
                    .padding(.top, 2)
            } else if let org = ipInfo?.org ?? ipInfo?.isp ?? ipAsn {
                Text(org)
                    .font(.system(size: 14))
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else if ipInfo == nil && !ipFetchFailed {
                SkeletonBar(width: 96, height: 14, animated: true)
            } else {
                Text("—")
                    .font(.system(size: 14))
                    .fontWeight(.semibold)
            }
        }
    }

    private var statusCard: some View {
        ZStack {
            StatusWaveShape()
                .fill(waveColor)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        CardTitleRow(icon: "waveform.path.ecg", title: "状态")
                        PillBadge(text: proxyStore.isRunning ? "运行中" : "未运行",
                                  tint: proxyStore.isRunning ? .green : .gray,
                                  dot: proxyStore.isRunning)
                    }
                    .frame(height: 26)
                    Spacer().frame(height: 12)
                    HStack(spacing: 12) {
                        CloverBadge(
                            countryCode: proxyStore.isRunning ? ipInfo?.countryCode : nil,
                            checking: ipChecking,
                            // D-D9: the clover refresh re-probes the
                            // egress IP through the core as well as
                            // the ip-api.com lookup, so the status
                            // card's IP and the core probe agree.
                            // v0.2.69: the probe goes through the
                            // non-subscribing action channel.
                            onRefresh: {
                                Task {
                                    await fetchIPInfo()
                                    await trafficActions.probe()
                                }
                            }
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            // v0.2.69: the IP slot observes
                            // TrafficStore itself, so the 1 s tick
                            // re-renders only the slot.
                            StatusIpSlotView(ipInfo: ipInfo, ipFetchFailed: ipFetchFailed)
                            Spacer().frame(height: 4)
                            chipsSlot
                        }
                        // v0.2.68: the whole status card opens the
                        // 出站 IP sheet (the in-sheet "查看完整 IP 质量"
                        // button is gone — the video's sheet has none).
                        .contentShape(Rectangle())
                    }
                    Spacer().frame(height: 16)
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("运行时间")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // v0.2.69: the uptime text is its own leaf
                            // with its own 1 s tick — it no longer
                            // forces the status card (or the whole
                            // dashboard) to rebuild every second.
                            StatusUptimeText(startedAt: tunnelStartedAt)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("组织")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            orgValue
                        }
                        Spacer()
                    }
                }
                Button {
                    Task { await proxyStore.toggle() }
                } label: {
                    ZStack {
                        StartToggleMorphShape(progress: morphProgress)
                            .fill(ConcordTheme.accent)
                            .rotationEffect(.degrees(Double(morphProgress) * 40))
                            .shadow(color: ConcordTheme.accent.opacity(0.35), radius: 9, x: 0, y: 6)
                        Image(systemName: proxyStore.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: playButtonSize, height: playButtonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(proxyStore.isRunning ? "停止 VPN" : "启动 VPN")
                .frame(width: playButtonSize)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16))
        }
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 34))
        // v0.2.37 A组:去掉状态卡片的蓝色描边。之前这里按 FlClash
        // current_outbound.dart 的 "root" 概念画了一圈主色描边
        // (MITM 开关开时 lineWidth 1.5),但 iOS 没有 root 概念,
        // FlClash 的卡片本身也没有这圈边框;其余卡片用的
        // .concordCard() 本来就没有描边,此处应与之一致。
        .accessibilityLabel("状态")
        .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
        // v0.2.56: tapping the card (outside the play button and
        // the clover refresh, which keep their own taps) opens
        // the 出站 IP sheet (MuYu key_3).
        .contentShape(Rectangle())
        .onTapGesture { showOutboundIPSheet = true }
    }

    /// Wave fill (_StatusWavePainter colours): v0.2.68 running is
    /// the theme accent at low opacity (was blue-gray #E4EBFB);
    /// not running #EFEDF0 in light mode; white 6% / #262F3E dark.
    private var waveColor: Color {
        if colorScheme == .dark {
            return proxyStore.isRunning
                ? Color(red: 0.149, green: 0.184, blue: 0.243)
                : Color.white.opacity(0.06)
        }
        return proxyStore.isRunning
            ? ConcordTheme.accent.opacity(0.14)
            : Color(red: 0.937, green: 0.929, blue: 0.941)
    }

    /// Quality pill with the reference's solid pastel colours (the
    /// shared PillBadge is paler); 13pt like the other pills.
    /// Levels are the IP-quality ones (IPQualityView): 优 green,
    /// 普通 amber, 风险 red.
    private func qualityPill(text: String, level: IpQualityLevel) -> some View {
        let bg: Color
        let fg: Color
        if level == .good {
            bg = Color(red: 0.80, green: 0.95, blue: 0.74)
            fg = Color(red: 0.15, green: 0.45, blue: 0.15)
        } else if level == .normal {
            bg = Color(red: 1.0, green: 0.92, blue: 0.75)
            fg = Color(red: 0.72, green: 0.44, blue: 0.05)
        } else {
            bg = Color(red: 1.0, green: 0.85, blue: 0.82)
            fg = Color(red: 0.72, green: 0.15, blue: 0.12)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }

    // MARK: - Network speed card

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitleRow(icon: "gauge.with.dots.needle.33percent", title: "网络速度")
            HStack(spacing: 12) {
                // v0.2.69: each panel observes TrafficStore
                // itself — the 1 s tick re-renders only the two
                // panels, not the card or the dashboard.
                SpeedPanelView(isUp: true, bigNumberSize: bigNumberSize, densityCompact: densityCompact)
                SpeedPanelView(isUp: false, bigNumberSize: bigNumberSize, densityCompact: densityCompact)
            }
            // v0.2.68: the waveform moved INSIDE each speed panel
            // (SpeedPanelAreaWaveform) — no separate sparkline here.
        }
        .concordCard()
    }

    // MARK: - Traffic statistics card (MuYu TrafficStatisticsCard, D-M8)
    //
    // v0.2.56 rework to MuYu IMG_1181 / video key_28: total, down/up
    // pills, 代理/直连 split rows, a 64pt proxy-share ring, and the
    // 累计运行 row. All figures are TODAY's, from one source —
    // TrafficStore.todayTotals (the daily-history accumulator):
    // total = up + down, the split is the observed connection-feed
    // split (proxy + direct can be less than the total — see
    // TrafficStore's split notes), the ring is proxy / total, and
    // uptime is the day's cumulative tunnel time. The v0.2.55
    // 本周/本月 row is GONE from the card — MuYu's card has no
    // week/month row; those totals live in the detail sheet's
    // 日/周/月 segmented view instead. The persisted daily history
    // is unchanged (the sheet still reads it).

    private var trafficCard: some View {
        // v0.2.69: the changing figures live in TrafficCardContent,
        // which observes TrafficStore itself — the 1 s tick
        // re-renders only that leaf. The Button chrome stays here.
        Button { showTrafficDetail = true } label: {
            TrafficCardContent(bigNumberSize: bigNumberSize)
        }
        .buttonStyle(.plain)
        .concordCard()
    }

    // MARK: - Outbound mode card

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitleRow(icon: "arrow.triangle.branch", title: "出站")
            // FlClash outbound_mode.dart DashboardConnectedGroup: one
            // connected pill — outer radius 26, height 52, icon 18,
            // selected segment primary-filled, inner radius 12.
            // FlClash outbound_mode.dart noProfileDirect: with no
            // active profile there are no rules/proxies, so every
            // mode goes direct — show the notice instead of the
            // mode buttons.
            if profileStore.activeProfile == nil {
                Text("未使用配置，全部直连")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(OutboundMode.allCases.enumerated()), id: \.element) { index, mode in
                        let selected = settingsStore.mode == mode
                        Button { settingsStore.mode = mode } label: {
                            VStack(spacing: 2) {
                                Image(systemName: modeIcon(mode))
                                    .font(.system(size: 18, weight: .semibold))
                                Text(modeShortLabel(mode))
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                selected ? ConcordTheme.accent : Color.clear,
                                in: connectedSegmentShape(index: index, count: OutboundMode.allCases.count)
                            )
                            .foregroundStyle(selected ? .white : Color(.label))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 26))
            }
            if let message = settingsStore.generalApplyMessage, !densityCompact {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
    }

    /// Corner radii for one segment of the connected mode pill:
    /// outer 26 on the card's outer ends, inner 12 where segments meet.
    private func connectedSegmentShape(index: Int, count: Int) -> UnevenRoundedRectangle {
        let outer: CGFloat = 26
        let inner: CGFloat = 12
        if count == 1 {
            return UnevenRoundedRectangle(topLeadingRadius: outer, bottomLeadingRadius: outer, bottomTrailingRadius: outer, topTrailingRadius: outer)
        }
        if index == 0 {
            return UnevenRoundedRectangle(topLeadingRadius: outer, bottomLeadingRadius: outer, bottomTrailingRadius: inner, topTrailingRadius: inner)
        }
        if index == count - 1 {
            return UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner, bottomTrailingRadius: outer, topTrailingRadius: outer)
        }
        return UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner, bottomTrailingRadius: inner, topTrailingRadius: inner)
    }

    // MARK: - VPN card (FlClash network_takeover.dart VpnCard)
    //
    // Badge: AppGlyphs.vpn — a shield outline with a keyhole — drawn
    // 22pt inside a 48pt badge. NAGRAM-style (v0.2.46 ITEM 2):
    // solid blue circle + white glyph while the VPN is running,
    // the previous grey circle + grey glyph while it is off.
    // Whole-card tap toggles (FlClash onTap); the switch keeps
    // working (see V3 in the audit: ours actually toggles the
    // tunnel, FlClash's iOS switch is a no-op). The switch is
    // tinted iOS blue, like NAGRAM.

    /// The VPN card plus its banners (D5): the disconnect / crash-loop
    /// / TUN-restart banners live HERE, on the main VPN card, where
    /// they are always visible — not inside the Services card's
    /// collapsed "expanded" section, where the disconnect banner used
    /// to hide and the crash-loop banner had no reader at all.
    private var vpnCardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            vpnCard
            // Unexpected disconnect (moved from expandedServices):
            // the tunnel dropped without the user asking (system
            // kill, core stall, failed start). One tap reconnects
            // via the same path as the play button; the flag clears
            // on the next successful connect. A watchdog-triggered
            // restart under On-Demand clears it by itself when the
            // tunnel comes back.
            if tunnelManager.unexpectedDisconnect {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN 意外断开")
                            .font(.footnote.weight(.semibold))
                        // The extension's startup diagnostic (if any)
                        // names the exact stage where the start died;
                        // otherwise fall back to the app-side error.
                        Text(tunnelManager.lastStartupDiagnostic() ?? tunnelManager.lastError ?? "隧道被系统关闭或核心停止响应。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新连接") {
                        Task { await proxyStore.toggle() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            // Crash loop (D5): 3 rapid drops in 5 minutes — the
            // tunnel is crash-looping and On-Demand auto-reconnect
            // has been suspended, so this must be visible, not
            // hidden in a collapsed card. The reason is the
            // lastError the crash-loop detector set.
            if tunnelManager.crashLoopActive {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN 反复掉线，已暂停自动重连")
                            .font(.footnote.weight(.semibold))
                        Text(tunnelManager.lastError ?? "隧道在短时间内多次掉线，系统已暂停自动重连，请检查配置后手动重新启动。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新连接") {
                        Task { await proxyStore.toggle() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            // Zombie tunnel (v0.2.96): the system reports .connected
            // but the extension core does not answer. The manager
            // probes once after start and auto-restarts at most once;
            // this banner shows the in-progress / final state.
            if let zombieNotice = tunnelManager.zombieNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN 核心无响应")
                            .font(.footnote.weight(.semibold))
                        Text(zombieNotice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新连接") {
                        Task { await proxyStore.toggle() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            // TUN restart needed (config B1): a live config change
            // killed the TUN runner and the extension could not
            // restart it — the config applied, but traffic no longer
            // goes through the proxy until the VPN restarts. The
            // flag is TunnelManager.tunRestartNeeded, read from the
            // extension's tun-restart-needed.json.
            if let tunRestartNeeded = tunnelManager.tunRestartNeeded {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TUN 数据面需要重启 VPN")
                            .font(.footnote.weight(.semibold))
                        Text(tunRestartNeeded)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重启 VPN") {
                        Task {
                            await TunnelManager.shared.stop()
                            // stop() waits up to 5 s for
                            // .disconnected; make sure the tunnel
                            // really settled before toggling, or the
                            // toggle would stop again instead of
                            // starting. A start failure lands in
                            // proxyStore.startError, like the play
                            // button's.
                            let deadline = Date().addingTimeInterval(10)
                            while TunnelManager.shared.isRunning && Date() < deadline {
                                try? await Task.sleep(for: .milliseconds(200))
                            }
                            await proxyStore.toggle()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var vpnCard: some View {
        HStack(spacing: 12) {
            VpnBadge(enabled: proxyStore.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text("VPN")
                    .font(.system(size: 14, weight: .semibold))
                // D3: the subtitle follows the real tunnel status
                // ("连接中" while connecting), not the isRunning
                // boolean — isRunning is only true once connected,
                // so the old text claimed "已连接" during connecting.
                Text(tunnelStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { proxyStore.isRunning },
                set: { _ in Task { await proxyStore.toggle() } }
            ))
            .labelsHidden()
            // MuYu video: the switch follows the theme accent
            // (magenta under the magenta theme, blue under the
            // default blue theme). Same start/stop path as the
            // play button (proxyStore.toggle()); start errors
            // land in proxyStore.startError.
            .tint(ConcordTheme.accent)
        }
        .concordCard(padding: 12)
        // The Toggle keeps its own tap (the inner control wins the
        // gesture), so tapping the switch toggles once.
        .contentShape(Rectangle())
        .onTapGesture { Task { await proxyStore.toggle() } }
    }

    // MARK: - Service status card

    // v0.2.69: the whole card lives in ServicesCardView, which
    // observes TrafficStore itself. Its data changes on probe,
    // not every second — but any read here would subscribe this
    // view to the store and re-render the dashboard on the 1 s
    // tick, so the card had to move out with the rest.
    private var servicesCard: some View {
        ServicesCardView(
            expanded: $servicesExpanded,
            onOpenServiceSheet: { showServiceSheet = true },
            onManageServices: { showServiceManageSheet = true }
        )
    }

    // MARK: - Subscription card

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.callout.weight(.semibold))
                Text("配置")
                    .font(.caption.weight(.semibold))
                Spacer()
                // FlClash profiles.dart _SyncButton: only for URL
                // profiles, replaced by a spinner while updating.
                if profileStore.activeProfile?.kind == .url {
                    if isSyncingProfile {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Button {
                            isSyncingProfile = true
                            Task {
                                defer { isSyncingProfile = false }
                                if let profile = profileStore.activeProfile {
                                    await profileStore.update(profile)
                                }
                                await refreshSubscription()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                                .foregroundStyle(Color(.label))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("更新订阅")
                    }
                }
                Button { onSelectTab(.profiles) } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Text(profileStore.activeProfile?.name ?? "未选择订阅")
                    .font(.system(size: 18))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                // FlClash profiles.dart: the swap button shows only
                // when more than one profile exists.
                if profileStore.profiles.count > 1 {
                    Button { onSelectTab(.profiles) } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.footnote)
                            .foregroundStyle(Color(.label))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换订阅")
                }
            }
            HStack {
                Text("更新于 \(updatedText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(profileEndText)
                    .font(.footnote)
                    .foregroundStyle(profileEndIsWarn ? .orange : .secondary)
                    // FlClash tooltip: the full expiry date. .help
                    // has no visible effect on iOS; the date is also
                    // the accessibility label for VoiceOver.
                    .help(profileEndTooltip ?? "")
                    .accessibilityLabel(profileEndTooltip ?? profileEndText)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(usedPercentText)
                    .font(.system(size: statNumberSize, weight: .bold))
                Text("已用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trafficText)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            // v0.2.68: the usage bar is the video's wavy line
            // (WavyProgressBar); warn colour at ≥90% used.
            WavyProgressBar(progress: usedFraction, color: usedFraction >= 0.9 ? Color.orange : ConcordTheme.accent)
            if subscription == nil {
                Text("订阅流量信息：核心未提供（需订阅支持 subscription-userinfo，或先启动 VPN）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
        // v0.2.56: tapping the card (outside the sync and
        // chevron buttons, which keep their own taps) opens the
        // rule-providers sheet (MuYu key_25).
        .contentShape(Rectangle())
        .onTapGesture { showProvidersSheet = true }
    }

    // MARK: - Proxy groups card

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // v0.2.64: upstream opens the groups sheet here
            // (FlClash proxy_groups.dart showProxiesSheet), it does
            // NOT jump to the Proxies tab. Empty = no tap (upstream
            // onTap is null when there are no groups).
            Button { if !proxyStore.nonHiddenGroups.isEmpty { showGroupsSheet = true } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.semibold))
                    Text("策略组")
                        .font(.caption.weight(.semibold))
                    if timeoutCount > 0 {
                        PillBadge(text: "\(timeoutCount) 超时", tint: .orange)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color(.label))
            }
            .buttonStyle(.plain)
            if proxyStore.nonHiddenGroups.isEmpty {
                groupsEmptyView
            } else {
                HStack {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(proxyStore.nonHiddenGroups.count)")
                        .font(.system(size: bigNumberSize, weight: .bold))
                    Text("个")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: -10) {
                    ForEach(proxyStore.nonHiddenGroups.prefix(4)) { group in
                        PackTileImage(
                            name: group.name,
                            fallback: group.name == "github" ? "GH" : String(group.name.prefix(1)).uppercased(),
                            fontSize: 17
                        )
                        .foregroundStyle(Color(.label))
                        .frame(width: 40, height: 40)
                        .background(ConcordTheme.softFill, in: Circle())
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                    if extraGroups > 0 {
                        Text("+\(extraGroups)")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(.label))
                            .frame(width: 40, height: 40)
                            .background(ConcordTheme.softFill, in: Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
                }
            }
        }
        .concordCard()
        // v0.2.64: the whole card opens the sheet — the header
        // Button alone left the count figure and group circles
        // dead, which is exactly the "only the chevron works"
        // report. Empty = no tap (upstream onTap is null when
        // there are no groups).
        .contentShape(Rectangle())
        .onTapGesture { if !proxyStore.nonHiddenGroups.isEmpty { showGroupsSheet = true } }
    }

    /// The strategy-groups sheet (v0.2.64, upstream FlClash
    /// proxy_groups.dart showProxiesSheet: ProxiesView in picker
    /// mode). Lists every visible group with its type and current
    /// pick; tapping one selects that group on the Proxies tab
    /// (via proxyStore.selectedGroupName, which the tab's pills
    /// read), dismisses the sheet, and switches tabs.
    /// The dashboard's 策略组 sheet (v0.2.64, video): upstream
    /// FlClash proxy_groups.dart showProxiesSheet presents the
    /// ProxiesView itself in picker mode — title 代理， filter
    /// pills (全部/策略组/节点组/节点 with counts), a 2-column
    /// grid of group cards (name, TYPE · n/m, selected node,
    /// latency pill), and search. Tapping a group selects it,
    /// dismisses the sheet, and switches to the Proxies tab.
    private var groupsSheet: some View {
        ProxiesView(picker: true) { name in
            proxyStore.selectedGroupName = name
            showGroupsSheet = false
            onSelectTab(.proxies)
        }
    }

    /// Empty proxy-groups state (FlClash proxy_groups.dart
    /// _GroupsEmpty: cookie9 illustration + "暂无策略组" when the
    /// core is connected, "内核未运行" + "启动后显示策略组" when not;
    /// connected here means the VPN is running).
    private var groupsEmptyView: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(ConcordTheme.softFill)
                    .frame(width: 64, height: 64)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            Text(proxyStore.isRunning ? "暂无策略组" : "内核未运行")
                .font(.subheadline.weight(.semibold))
            if !proxyStore.isRunning {
                Text("启动后显示策略组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Stats card

    /// FlClash connection_stats.dart: card label "连接统计", counts
    /// formatted with dashboardCount (grouped digits, compact ≥100k).
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // v0.2.68: no title row — the video shows just the
            // three numbers. The cells below still open their
            // destination sheets.
            HStack(spacing: 0) {
                statCell(value: dashboardCount(connectionStore.connections.count), label: "实时连接", destination: .live)
                statCell(value: dashboardCount(eventStore.totalEventCount), label: "最近请求", destination: .recent)
                statCell(value: dashboardCount(dnsStore.entries.count), label: "DNS查询", destination: .dns)
            }
        }
        .concordCard()
    }

    /// Shared grouped-digits formatter for dashboardCount below
    /// 100k: NumberFormatter setup is expensive, so one instance
    /// serves every render (main thread only — all callers are
    /// view code).
    private static let groupedCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// FlClash style.dart dashboardCount: grouped digits below
    /// 100k, compact form at/above (123K, 1.5M).
    private func dashboardCount(_ count: Int) -> String {
        if count < 100_000 {
            return Self.groupedCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
        if count < 1_000_000 {
            return "\(Int((Double(count) / 1_000).rounded()))K"
        }
        let millions = Double(count) / 1_000_000
        if millions.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(millions))M"
        }
        return "\(String(format: "%.1f", millions))M"
    }

    /// D-M6: a stat cell opens its source page — live/recent
    /// connections, or the DNS queries page for the DNS cell.
    /// v0.2.64: the contentShape makes the full cell column
    /// tappable, not just the number/label glyphs.
    private func statCell(value: String, label: String, destination: StatsDestination) -> some View {
        Button {
            // v0.2.103: no DNS publish suspension on tap — the
            // DNS sheet is now structurally identical to the
            // Connections sheet (no ScrollViewReader / .task /
            // .onChange / .onAppear timer), so a mid-presentation
            // publish is a normal state update, not a freeze
            // trigger. Note the action for the watchdog.
            MainThreadWatchdog.noteAction("statsDestination set to .\(destination.rawValue)")
            statsDestination = destination
        } label: {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: statNumberSize, weight: .bold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Memory card (FlClash memory_info.dart)
    //
    // App RSS (this process, task_info) + core RSS (core.stats via
    // TrafficStore). The core runs in the NetworkExtension process,
    // so the two numbers are separate processes, not one total to
    // be carved up. Polls every 2s like FlClash; tapping opens the
    // detail sheet with the release-memory action.
    //
    // v0.2.69: the whole card lives in MemoryCardView, which
    // observes TrafficStore itself — its core-bytes read here
    // would subscribe this view and re-render the dashboard on
    // the 1 s tick.

    private var memoryCard: some View {
        MemoryCardView(
            isDetailOpen: $showMemoryDetail,
            bigNumberSize: bigNumberSize,
            onOpenDetail: { showMemoryDetail = true }
        )
    }

    // MARK: - Update card (FlClash update_status.dart)
    //
    // The app has no in-app update download (self-signed IPA): the
    // card shows the current version, the latest commit on main
    // from the same UpdateChecker the About page uses, and whether
    // it is newer. Checking writes the result to AppStorage so the
    // card keeps its last answer across launches.

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitleRow(icon: "arrow.down.circle", title: "更新状态")
                Spacer()
                if lastUpdateChecked {
                    PillBadge(
                        text: lastUpdateIsNew ? "发现新提交" : "已是最新",
                        tint: lastUpdateIsNew ? .orange : .green
                    )
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("v\(appVersion)")
                    .font(.system(size: bigNumberSize, weight: .bold))
                Text("当前版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if lastUpdateChecked {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最新提交 \(String(lastUpdateSha.prefix(7)))")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    Text(lastUpdateMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !lastUpdateDate.isEmpty {
                        Text(lastUpdateDate)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("尚未检查过更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = updateCheckMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(isCheckingUpdate ? "检查中…" : "检查更新") {
                Task { await checkForUpdate() }
            }
            .buttonStyle(.borderedProminent)
            .tint(ConcordTheme.accent)
            .controlSize(.small)
            .disabled(isCheckingUpdate)
            if lastUpdateIsNew {
                Text("点击卡片前往 GitHub Releases 下载新版本安装，本应用内无法直接更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
        // v0.2.85: upstream update_status.dart installs directly
        // from the update row with no dialog — tapping the card
        // while an update is known opens the Releases page
        // straight away (the app cannot install an IPA itself).
        // The inner 检查更新 button keeps its own tap.
        .contentShape(Rectangle())
        .onTapGesture {
            guard lastUpdateIsNew,
                  let url = URL(string: "https://github.com/Sunny-qwe/concord-ios/releases/latest") else { return }
            openURL(url)
        }
    }
}

/// A dashboard stat cell's destination sheet (D-M6).
private enum StatsDestination: String, Identifiable {
    case live, recent, dns

    var id: String { rawValue }
}

/// Area waveform inside a speed panel (v0.2.68): the sampled
/// history (TrafficStore.history, one point per traffic poll) as
/// a filled area in the theme tint with a thin stroke, drawn
/// behind the panel's numbers.
private struct SpeedPanelAreaWaveform: View {
    let history: [TrafficPoint]
    let value: KeyPath<TrafficPoint, Int64>
    let color: Color

    var body: some View {
        GeometryReader { geo in
            waveformView(size: geo.size)
        }
        .accessibilityHidden(true)
    }

    /// Builds the area + line paths imperatively. A plain function, not a
    /// ViewBuilder, so the `if`/`for` that mutate the Paths are legal
    /// (a GeometryReader content closure cannot contain them).
    private func waveformView(size: CGSize) -> some View {
        let points = Array(history.suffix(120))
        let maxValue = max(1, points.map { $0[keyPath: value] }.max() ?? 1)
        let step = size.width / CGFloat(max(points.count - 1, 1))
        var area = Path()
        var line = Path()
        if points.count > 1 {
            for (index, point) in points.enumerated() {
                let x = CGFloat(index) * step
                let y = size.height - (CGFloat(point[keyPath: value]) / CGFloat(maxValue)) * size.height
                if index == 0 {
                    area.move(to: CGPoint(x: x, y: size.height))
                    area.addLine(to: CGPoint(x: x, y: y))
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    area.addLine(to: CGPoint(x: x, y: y))
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }
            area.addLine(to: CGPoint(x: CGFloat(points.count - 1) * step, y: size.height))
            area.closeSubpath()
        }
        return ZStack {
            area.fill(color.opacity(0.14))
            line.stroke(color.opacity(0.45), lineWidth: 1.5)
        }
    }
}

/// FlClash AppGlyphs.vpn (app_glyphs.dart:1427-1444): a shield outline
/// (polyline) with a keyhole — solid dot + stem — drawn on a 24pt
/// grid and scaled to 22pt. No SF Symbol matches.
private struct VpnGlyphIcon: View {
    let color: Color

    var body: some View {
        let scale: CGFloat = 22.0 / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale, y: y * scale)
        }
        return ZStack {
            Path { p in
                p.move(to: pt(12, 2.9))
                p.addLine(to: pt(19.6, 5.5))
                p.addLine(to: pt(19.6, 12.5))
                p.addLine(to: pt(12, 21.1))
                p.addLine(to: pt(4.4, 12.5))
                p.addLine(to: pt(4.4, 5.5))
                p.closeSubpath()
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(color)
                .frame(width: 1.6 * 2 * scale, height: 1.6 * 2 * scale)
                .position(x: 12 * scale, y: 10.2 * scale)
            Path { p in
                p.move(to: pt(12, 11))
                p.addLine(to: pt(12, 14.6))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

/// Scalloped flower badge (NAGRAM-style, v0.2.46 refinement):
/// a circle whose radius is modulated by a cosine with 8 rounded
/// lobes — the blue badge behind the shield glyph once the VPN is
/// running (the NAGRAM reference uses the same flower for its VPN
/// row badge and its pause button). Lobe depth is modest (6% of
/// the radius) so it reads as a flower, not a gear. The path is
/// scaled so the lobe TIPS touch the rect's edges — the badge's
/// outer extent equals the frame, same as the circle it replaces.
/// Internal (not private): ThemePickerView's preview row uses it
/// too.
struct FlowerBadgeShape: Shape {
    /// Number of rounded lobes around the badge.
    var lobes: Int = 8
    /// Lobe depth as a fraction of the mean radius.
    var depth: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Tips must reach the rect's edges, so the mean radius is
        // the half-size divided by (1 + depth).
        let meanRadius = min(rect.width, rect.height) / 2 / (1 + depth)
        let stepsPerLobe = 16
        let totalSteps = lobes * stepsPerLobe
        var path = Path()
        for step in 0...totalSteps {
            let angle = CGFloat(step) / CGFloat(totalSteps) * 2 * .pi
            let radius = meanRadius * (1 + depth * cos(CGFloat(lobes) * angle))
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// The VPN badge (FlClash network_takeover.dart VpnCard): 48pt.
/// NAGRAM-style (v0.2.46 ITEM 2, user-confirmed 2026-11-21):
/// the blue shield appears ONLY while the VPN is running — a
/// solid blue flower badge (FlowerBadgeShape) + white glyph.
/// When the VPN is off the badge is exactly as before: a
/// light-grey circle + grey glyph (AppGlyphs.vpn shield outline
/// with keyhole, unchanged).
private struct VpnBadge: View {
    let enabled: Bool

    var body: some View {
        ZStack {
            if enabled {
                FlowerBadgeShape()
                    .fill(ConcordTheme.accent)
                    .frame(width: 48, height: 48)
                VpnGlyphIcon(color: .white)
            } else {
                Circle()
                    .fill(Color(red: 0.93, green: 0.93, blue: 0.95))
                    .frame(width: 48, height: 48)
                VpnGlyphIcon(color: Color(red: 0.38, green: 0.38, blue: 0.42))
            }
        }
        .frame(width: 48, height: 48)
    }
}

/// The ip-api.com `as` field ("AS15169 Google LLC") — decoded
/// separately because IPQualityInfo maps no `as` key.
private struct IPApiAsField: Decodable {
    let asNumber: String?

    enum CodingKeys: String, CodingKey {
        case asNumber = "as"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .asNumber)
        // Keep the bare "AS<n>" token: "AS15169 Google LLC" -> "AS15169".
        asNumber = raw?.split(separator: " ").first.map(String.init)
    }
}

/// The top-right edit button's glyph: the reference is a thick, bold
/// pencil (17x17pt bbox, ~24pt diagonal, ~7pt body), not the thin SF
/// Symbol pencil. Drawn as a filled pentagon (tip bottom-left, flat
/// top top-right) with a background-coloured band near the top end,
/// inside the same 44pt circle. Numbers are the measured reference
/// geometry: axis 20.5pt at 45 degrees, body 7pt wide, tip 5.5pt.
private struct ThickPencilIcon: View {
    let iconColor: Color
    let bandColor: Color

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 17))
                p.addLine(to: CGPoint(x: 6.36, y: 15.59))
                p.addLine(to: CGPoint(x: 16.97, y: 4.98))
                p.addLine(to: CGPoint(x: 12.02, y: 0.03))
                p.addLine(to: CGPoint(x: 1.41, y: 10.64))
                p.closeSubpath()
            }
            .fill(iconColor)
            Path { p in
                p.move(to: CGPoint(x: 9.76, y: 2.29))
                p.addLine(to: CGPoint(x: 14.71, y: 7.24))
                p.addLine(to: CGPoint(x: 13.58, y: 8.37))
                p.addLine(to: CGPoint(x: 8.63, y: 3.42))
                p.closeSubpath()
            }
            .fill(bandColor)
        }
        .frame(width: 17, height: 17)
    }
}

/// Country badge (_CountryBadge): clover4Leaf, #E4E2E4, 48pt, rotated
/// 45 degrees (the clover shape only — the glyph/code stays upright).
/// Shows the country code whenever the lookup has one (our scope: the
/// IP stays visible while not running); the globe shows only before
/// the first lookup. Tapping re-runs the lookup; while checking, the
/// clover spins (1500ms period, stops on the next quarter turn).
private struct CloverBadge: View {
    let countryCode: String?
    let checking: Bool
    let onRefresh: () -> Void

    @State private var spin: Double = 0

    var body: some View {
        Button(action: onRefresh) {
            ZStack {
                CloverShape()
                    .fill(Color(red: 0.894, green: 0.886, blue: 0.894))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(45 + spin))
                if let code = countryCode, !code.isEmpty {
                    Text(code.uppercased())
                        .font(.footnote.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color(.label))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 21))
                        .foregroundStyle(Color(.label))
                }
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("重新查询出口 IP")
        .onChange(of: checking) { _, isChecking in
            if isChecking {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    spin = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.35)) {
                    spin = 0
                }
            }
        }
    }
}

/// Dashboard card identities (FlClash DashboardWidget): the order
/// is user-editable, the visibility is the show/hide toggles.
private enum DashboardCardID: String, CaseIterable {
    case status, speed, traffic, mode, vpn, services, profile, groups, stats, memory, update

    /// v0.2.56: the tail follows the MuYu iOS build (IMG_1181 /
    /// video): stats row, 策略组， 配置， 流量统计， 内存信息 — so
    /// the traffic card sits directly below 配置 and directly
    /// above 内存信息. A saved custom order (cardOrderString)
    /// is untouched by this: it only sets the default for
    /// installs that never reordered.
    static let defaultOrder: [DashboardCardID] = [
        .status, .speed, .vpn, .mode, .services,
        .stats, .groups, .profile, .traffic, .memory, .update,
    ]

    var title: String {
        switch self {
        case .status: return "状态"
        case .speed: return "网络速度"
        case .traffic: return "流量统计"
        case .mode: return "出站模式"
        case .vpn: return "VPN"
        case .services: return "服务状态"
        case .profile: return "配置"
        case .groups: return "策略组"
        case .stats: return "连接统计"
        case .memory: return "内存信息"
        case .update: return "更新状态"
        }
    }
}

/// Two-segment memory bar (FlClash _MemoryBar): app share in accent
/// blue, core share in the series2 blue tone (accent 45% over the
/// card), on a soft track.
private struct MemoryBar: View {
    let appBytes: UInt64
    let coreBytes: UInt64

    var body: some View {
        GeometryReader { geo in
            let total = max(1, appBytes + coreBytes)
            let appWidth = geo.size.width * CGFloat(appBytes) / CGFloat(total)
            ZStack(alignment: .leading) {
                Capsule().fill(ConcordTheme.softFill)
                HStack(spacing: 2) {
                    Capsule().fill(ConcordTheme.accent).frame(width: max(0, appWidth - 1))
                    Capsule().fill(ConcordTheme.accent.opacity(0.45)).frame(width: max(0, geo.size.width - appWidth - 1))
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Dashboard edit sheet (pencil button)

// MARK: - TrafficStore leaf views (v0.2.69)
//
// DashboardView used to observe TrafficStore directly, so every
// 1 s traffic tick (current + history) re-evaluated its whole
// body — ScrollView and every card. The store reads now live in
// these narrow leaf views, each observing only the store; the
// dashboard itself stays unsubscribed and only re-renders when
// its own state or another store changes. No text, icon, colour
// or layout changed in the move — the leaf bodies are verbatim
// copies of the card code they replace.

/// Non-subscribing TrafficStore action channel: the dashboard
/// cannot call the store directly any more, so the
/// DashboardTrafficEffects leaf observes the store and fills
/// these closures on appear. The dashboard only *calls* them
/// from user gestures (pull-to-refresh, the clover refresh),
/// which never subscribe and never re-render the body.
private struct DashboardTrafficActions {
    var refresh: () async -> Void = {}
    var refreshEngineStatus: () async -> Void = {}
    var refreshWarnings: () async -> Void = {}
    var noteTunnelStarted: (Date) async -> Void = { _ in }
    var probe: () async -> Void = {}
}

/// Dashboard bar badge for services that did not start (v0.2.86,
/// upstream dashboard.dart statusActions + service_faults.dart
/// ServiceFaultsButton): an error-tinted count badge, left out
/// while there are none; a tap lists each service and its reason.
/// A TrafficStore leaf, so the 1 s tick re-renders only this badge.
private struct DashboardServiceFaultsBadge: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @State private var showFaultsAlert = false

    var body: some View {
        if let faults = trafficStore.engineStatus?.faults, !faults.isEmpty {
            Button { showFaultsAlert = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(faults.count)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.14), in: Capsule())
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("未能启动的服务")
            .alert("未能启动的服务", isPresented: $showFaultsAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(faults.map { faultLine($0) }.joined(separator: "\n\n"))
            }
        }
    }

    /// One fault as upstream shows it (service_faults.dart):
    /// the service label, then the reason, on two lines.
    private func faultLine(_ fault: ConcordServiceFault) -> String {
        "\(faultServiceLabel(fault))\n\(faultReasonLabel(fault))"
    }

    /// Upstream l10n_labels.dart ServiceFaultL10n.serviceLabel:
    /// the localized service name, plus the address when the core
    /// reports one. The wire names are the FaultService enum
    /// cases (dto.dart); anything else is "其他".
    private func faultServiceLabel(_ fault: ConcordServiceFault) -> String {
        let name: String
        switch fault.service {
        case "mixed": name = "混合端口"
        case "http": name = "HTTP端口"
        case "socks": name = "Socks端口"
        case "redir": name = "Redir端口"
        case "tproxy": name = "Tproxy端口"
        case "tun": name = "虚拟网卡"
        case "dns": name = "DNS 服务器"
        default: name = "其他"
        }
        if let address = fault.address, !address.isEmpty {
            return "\(name) \(address)"
        }
        return name
    }

    /// Upstream l10n_labels.dart ServiceFaultL10n.reasonLabel:
    /// the three known reasons are localized; anything else shows
    /// the core's own message.
    private func faultReasonLabel(_ fault: ConcordServiceFault) -> String {
        switch fault.reason {
        case "address_in_use": return "地址已被占用。"
        case "address_not_available": return "本机没有这个地址。"
        case "permission_denied": return "没有权限。"
        default: return fault.message
        }
    }
}

/// Dashboard bar pill for config warnings (v0.2.86, upstream
/// live_status.dart LiveStatusButton / _LiveStatusPill, the
/// WarningsStatus case): a warning-tinted pill with the warning
/// glyph and the warning count, left out while there are none; a
/// tap opens the warnings deck. A TrafficStore leaf, so the 1 s
/// tick re-renders only this pill. The deck is ConfigWarningsDeck
/// (Views/ConfigWarningsDeck.swift); the sheet chrome matches the
/// other dashboard sheets.
private struct DashboardWarningsPill: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @State private var showWarningsDeck = false

    var body: some View {
        if !trafficStore.lastWarnings.isEmpty {
            Button { showWarningsDeck = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(trafficStore.lastWarnings.count)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.14), in: Capsule())
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("配置警告")
            .sheet(isPresented: $showWarningsDeck) {
                ConfigWarningsDeck(warnings: trafficStore.lastWarnings)
                    .concordCard()
                    .padding()
                    .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(ConcordTheme.pageBackground)
                    .presentationCornerRadius(28)
            }
        }
    }
}

/// IP to show in the status card and the IP sheets (audit D10):
/// the core's own probe.outboundIp result first — it measures
/// the egress through the selected proxy — ip-api.com only as
/// fallback for the geo/org enrichment. TrafficStore.probe()
/// runs when the tunnel connects (see DashboardTrafficEffects).
private func dashboardDisplayIp(isRunning: Bool, coreIp: String?, fallbackQuery: String?) -> String? {
    if isRunning,
       let coreIp = coreIp?.trimmingCharacters(in: .whitespacesAndNewlines),
       !coreIp.isEmpty {
        return coreIp
    }
    return fallbackQuery
}

/// The app process's resident size (FlClash reads
/// ProcessInfo.currentRss on its side; task_info is the iOS
/// equivalent). The core runs in the extension process, so its
/// RSS comes from core.stats instead. Nil when task_info fails,
/// so callers keep their previous value.
private func readAppMemoryBytes() -> UInt64? {
    var info = task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}

/// Side-effect bridge for the dashboard: the tunnel-start/stop
/// bookkeeping, engine refresh and service probing that used to
/// live in DashboardView's .task / .onChange, verbatim. Its body
/// is clear colour, so the 1 s traffic tick re-evaluates almost
/// nothing. It is placed in the ScrollView's background, so its
/// .task fires exactly when the dashboard first appears, like
/// the .task it replaces. The closures it receives only touch
/// DashboardView's own @State and other stores — never
/// TrafficStore — so the parent stays unsubscribed.
private struct DashboardTrafficEffects: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var client: ConcordClient

    @Binding var tunnelStartedAt: Date?
    @Binding var morphProgress: CGFloat
    @Binding var ipInfo: IPQualityInfo?
    @Binding var ipAsn: String?
    @Binding var ipFetchFailed: Bool
    @Binding var trafficActions: DashboardTrafficActions
    /// v0.2.101 issue 2: whether a stats sheet is open — the
    /// appear task skips its dnsStore.refresh() while one is, so
    /// the fresh entries cannot land mid-presentation.
    @Binding var statsDestination: StatsDestination?
    let fetchIPInfo: () async -> Void
    let refreshSubscription: () async -> Void

    var body: some View {
        Color.clear
            .onAppear {
                trafficActions = DashboardTrafficActions(
                    refresh: { await trafficStore.refresh() },
                    refreshEngineStatus: { await trafficStore.refreshEngineStatus() },
                    refreshWarnings: { await trafficStore.refreshWarnings() },
                    noteTunnelStarted: { await trafficStore.noteTunnelStarted(at: $0) },
                    probe: { await trafficStore.probe() }
                )
            }
            .task {
                morphProgress = proxyStore.isRunning ? 1 : 0
                if proxyStore.isRunning && tunnelStartedAt == nil {
                    tunnelStartedAt = tunnelManager.readTunnelStartedAt() ?? Date()
                }
                // v0.2.56: the traffic card's cumulative uptime counts
                // the live session from its start (the extension's
                // start time, so it survives an app restart).
                if proxyStore.isRunning, let started = tunnelStartedAt {
                    await trafficStore.noteTunnelStarted(at: started)
                }
                tunnelManager.checkTunRestartNeeded()
                await fetchIPInfo()
                await trafficStore.refreshEngineStatus()
                await refreshSubscription()
                // v0.2.89: the stats row (实时连接/最近请求/DNS查询）
                // refreshes on entry, like pull-to-refresh — it used
                // to show the previous session's values (or zeros)
                // until the user pulled. The refreshes throw while
                // the tunnel is down (stale snapshots) and the stores
                // keep their values then; with the VPN on (or just
                // stopped) the fresh snapshots fill the row at once.
                await connectionStore.refresh()
                await eventStore.refresh()
                // v0.2.101 issue 2: this refresh lands last in the
                // appear sequence — after fetchIPInfo (up to 26 s)
                // and the engine / subscription refreshes — so a
                // user tapping a stats cell mid-sequence can have
                // the sheet still presenting when the fresh DNS
                // entries publish, which fires DnsQueriesView's
                // .onChange scrollTo mid-presentation and freezes
                // the main thread. Skip it while a stats sheet is
                // open; the row refreshes on the next
                // pull-to-refresh / appear instead.
                if statsDestination == nil {
                    await dnsStore.refresh()
                }
                // v0.2.89: probe on entry even with the VPN off, like
                // MuYu — the old `client.mode == .sample ||
                // tunnelManager.isRunning` gate skipped the probe in
                // live mode with the VPN off, so the services card
                // showed stale values. The probe itself now routes
                // through the in-app core when the tunnel is down
                // (TrafficStore.probeServices), so no gate is needed
                // here.
                if trafficStore.services.isEmpty,
                   let proxy = proxyStore.selectedOutbound {
                    await trafficStore.serviceProbeStore.probeAll(proxy: proxy)
                }
            }
            .onChange(of: proxyStore.isRunning) { _, running in
                // D4: prefer the extension's own start time
                // (vpn-diagnostics.json) so the uptime survives an app
                // restart while the VPN is running; the local clock is
                // only the fallback when the extension has not written
                // the file yet.
                tunnelStartedAt = running ? (tunnelStartedAt ?? tunnelManager.readTunnelStartedAt() ?? Date()) : nil
                // v0.2.56: the traffic card's cumulative uptime counts
                // finished sessions; settle the session that just
                // ended (or start the one that just began).
                if running {
                    if let started = tunnelStartedAt {
                        Task { await trafficStore.noteTunnelStarted(at: started) }
                    }
                } else {
                    // v0.2.86 item 16: the tunnel going down forgets
                    // every confirmed failure and cancels every
                    // pending confirm/recheck, so no stale retry
                    // fires after the core is gone.
                    Task {
                        await trafficStore.noteTunnelStopped()
                        await trafficStore.serviceProbeStore.reset()
                        // v0.2.89: the tunnel going down used to
                        // leave the services card on the last
                        // tunnel-probe values; re-probe through the
                        // in-app core so the card stays live with
                        // the VPN off, like MuYu.
                        if let proxy = proxyStore.selectedOutbound {
                            await trafficStore.serviceProbeStore.probeAll(proxy: proxy)
                        }
                    }
                }
                // D-M7: hold the service/IP-probe results through the
                // start — a stale pre-start result must not flash as
                // current. The next services probe clears the hold
                // (TrafficStore.probeServices), and the services card
                // shows the held state until then.
                if running { trafficStore.holdServices() }
                // Morph circle -> cookie9 over 450ms (easeOutBack, the
                // forward curve of FlClash's _StartToggle).
                withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.45)) {
                    morphProgress = running ? 1 : 0
                }
                // The egress IP changes when the VPN toggles: drop the
                // stale direct-IP result so the card shows the loading
                // skeletons (FlClash re-probes on start), then re-fetch
                // so the status card shows the current proxy egress IP.
                if running {
                    ipInfo = nil
                    ipAsn = nil
                    ipFetchFailed = false
                }
                Task { await fetchIPInfo() }
                // D8/D10: the tunnel flip also refreshes the engine /
                // services / connections snapshots and re-probes the
                // egress IP through the core, otherwise the dashboard
                // keeps showing pre-connect values (or nothing) until
                // the next pull-to-refresh.
                Task {
                    await trafficStore.refreshEngineStatus()
                    await connectionStore.refresh()
                    // v0.2.102 (MuYu parity): the DNS row flips
                    // source with the tunnel too — extension
                    // snapshot while it is up, the in-app core's
                    // dns.watch buffer while it is down. Refreshing
                    // here also (re)starts the in-app core on a
                    // disconnect through DnsStore.refresh()'s
                    // routing, so DNS keeps accumulating after the
                    // tunnel goes down without waiting for the next
                    // appear / pull-to-refresh.
                    await dnsStore.refresh()
                    if running {
                        await trafficStore.probe()
                        if let proxy = proxyStore.selectedOutbound,
                           client.mode == .sample || tunnelManager.isRunning {
                            await trafficStore.serviceProbeStore.probeAll(proxy: proxy)
                        }
                    }
                }
            }
    }
}

/// IP slot (FlClash _ExitRow): a static grey bar while the core
/// is not running, a pulsing skeleton while running and the
/// probe has not answered, the real IP once it has, "服务失败"
/// (red) if the probe failed. The only TrafficStore read is
/// outboundIp, so this slot — not the status card — re-renders
/// when the probe lands.
private struct StatusIpSlotView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var settingsStore: SettingsStore
    let ipInfo: IPQualityInfo?
    let ipFetchFailed: Bool

    var body: some View {
        Group {
            if !proxyStore.isRunning {
                SkeletonBar(width: 140, height: 18)
            } else if let ip = dashboardDisplayIp(isRunning: proxyStore.isRunning, coreIp: trafficStore.outboundIp, fallbackQuery: ipInfo?.query) {
                // FlClash _IpText: hideIp masks the IP as "*****
                // (current_outbound.dart _ipMask).
                // v0.2.68: 24pt bold, like the video (was 18pt semibold).
                Text(settingsStore.hideIp ? "*****" : ip)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if ipFetchFailed {
                Text("IP 查询失败")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                SkeletonBar(width: 140, height: 18, animated: true)
            }
        }
        .frame(height: 30, alignment: .leading)
    }
}

/// Status card uptime (HH:MM:SS): its own leaf with its own 1 s
/// tick, so the running clock re-renders only this text — never
/// the status card, and never the dashboard.
private struct StatusUptimeText: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(startedAt.map { ConcordFormat.uptimeHMS(seconds: max(0, Int64(Date().timeIntervalSince($0)))) } ?? "—")
                .font(.system(size: 14))
                .fontWeight(.semibold)
        }
    }
}

/// One network-speed panel: the only view that reads
/// TrafficStore.current / .history on the dashboard. The card
/// keeps its title and HStack; the per-second numbers and the
/// area waveform live here.
private struct SpeedPanelView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    let isUp: Bool
    let bigNumberSize: CGFloat
    let densityCompact: Bool

    var body: some View {
        let bytes = isUp ? trafficStore.current.up : trafficStore.current.down
        let total = isUp ? trafficStore.current.totalUp : trafficStore.current.totalDown
        let split = ConcordBytes.split(bytes)
        // v0.2.82: upstream series2 — upload is the primary at 45%
        // (a light tint under any accent; the video's upload area
        // is light pink, not orange). Applies to every accent
        // EXCEPT the default blue theme, which keeps the orange
        // upload. The waveform itself applies its own opacity on
        // top, so 45% here renders upload at 45% of download's
        // strength, matching upstream.
        let uploadColor = ConcordTheme.isDefaultBlueTheme ? Color.orange : ConcordTheme.accent.opacity(0.45)
        // v0.2.68: the area waveform is the panel's BACKGROUND
        // (theme-tinted, numbers overlaid), like the video.
        return ZStack(alignment: .leading) {
            SpeedPanelAreaWaveform(
                history: trafficStore.history,
                value: isUp ? \.up : \.down,
                color: isUp ? uploadColor : ConcordTheme.accent
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isUp ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isUp ? Color(.label) : ConcordTheme.accent)
                    Text(isUp ? "上传" : "下载")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(split.number)
                        .font(.system(size: bigNumberSize, weight: .bold))
                    Text("\(split.unit)/s")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                // Compact density drops the subtitle (FlClash
                // DashboardDensity.compact drops subtitles).
                if !densityCompact {
                    // Reference shows "累计 0 B" (no ".0"): ConcordFormat
                    // formats 0 as "0.0 B", so special-case zero locally
                    // (the shared formatter is used elsewhere and stays).
                    Text("累计 \(total == 0 ? "0 B" : ConcordFormat.bytes(total))")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .clipShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}

/// Traffic statistics card content (MuYu TrafficStatisticsCard,
/// D-M8): today's totals from TrafficStore.todayTotals, the
/// 代理/直连 split, the proxy-share ring, and the 累计运行 row.
/// All figures are TODAY's, from one source — the daily-history
/// accumulator. The 1 s tick re-renders only this leaf.
private struct TrafficCardContent: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    let bigNumberSize: CGFloat

    var body: some View {
        let today = trafficStore.todayTotals
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitleRow(icon: "chart.pie", title: "流量统计")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(dashboardBytesNoSpace(today.total))
                        .font(.system(size: bigNumberSize, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 8) {
                        trafficCardPill("↓ \(dashboardBytesNoSpace(today.down))")
                        trafficCardPill("↑ \(dashboardBytesNoSpace(today.up))")
                    }
                    // v0.2.68: 代理/直连 are TWO LINES in the
                    // video, not side-by-side in one row.
                    VStack(alignment: .leading, spacing: 4) {
                        trafficSplitRow(dot: ConcordTheme.accent, label: "代理", value: dashboardBytesNoSpace(today.proxyBytes))
                        trafficSplitRow(dot: ConcordTheme.accent.opacity(0.45), label: "直连", value: dashboardBytesNoSpace(today.directBytes))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProxyRatioRing(ratio: today.proxyRatio)
            }
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // The TimelineView keeps the uptime ticking through
                // a transient probe failure too (same pattern as
                // the status card's 运行时间).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("累计运行 \(trafficStore.todayUptimeText)")
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v0.2.64: belt-and-braces — the whole card is already
        // a Button, but the contentShape makes taps on any
        // transparent part of the card register too.
        .contentShape(Rectangle())
    }

    private func trafficCardPill(_ label: String) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ConcordTheme.softFill, in: Capsule())
    }

    private func trafficSplitRow(dot: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.footnote)
            Text(value)
                .font(.footnote)
        }
        .foregroundStyle(Color(.label))
    }
}

/// Service status card: the title + verdict badge open the 服务状态
/// sheet (MuYu key_7); the chevron keeps the inline expand
/// (engine / TUN / DNS details). Its data changes on probe, not
/// every second — but any read in DashboardView would subscribe
/// that view to the store and re-render the dashboard on the 1 s
/// tick, so the whole card lives here. The expanded section's
/// tunnel-status row duplicates DashboardView.tunnelStatusText
/// (same switch, same strings) because this leaf owns its own
/// TunnelManager observation.
private struct ServicesCardView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var client: ConcordClient
    @ObservedObject private var onDemandStore = OnDemandStore.shared

    @Binding var expanded: Bool
    let onOpenServiceSheet: () -> Void
    let onManageServices: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // v0.2.56: the title + badge open the 服务状态
                // sheet (MuYu key_7); the chevron keeps the inline
                // expand (engine / TUN / DNS details).
                Button { onOpenServiceSheet() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.callout.weight(.semibold))
                        Text("服务状态")
                            .font(.caption.weight(.semibold))
                        if let badge = serviceBadge {
                            PillBadge(text: badge.text, tint: badge.tint)
                        }
                    }
                    .foregroundStyle(Color(.label))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起服务详情" : "展开服务详情")
            }
            // D-M3: the card shows the first two *enabled* services
            // (TrafficStore.enabledServiceNames), not a hardcoded
            // google/github pair.
            HStack(spacing: 12) {
                ForEach(Array(trafficStore.enabledServiceNames.prefix(2)), id: \.self) { name in
                    servicePill(for: service(named: name))
                }
            }
            // D-M7: the held state after a VPN start — the pre-start
            // results are held, not shown as current, until the
            // next probe lands.
            if trafficStore.servicesHeld {
                Text("检测结果已暂停：VPN 刚启动，等待下次检测刷新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if expanded {
                expandedServices
            }
        }
        .concordCard()
        // v0.2.64: the whole card opens the 服务状态 sheet —
        // tapping anywhere in the row must show the drawer, not
        // just the title/chevron. When expanded, taps stay
        // inside the expanded details (the chevron collapses);
        // the title Button keeps opening the sheet too.
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { onOpenServiceSheet() } }
    }

    private func service(named name: String) -> ConcordServiceItem? {
        trafficStore.services.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Service-status verdict (FlClash service_status.dart: problems
    /// = services where abnormal, i.e. status != available; chip is
    /// "N 项异常" warn / "全部可用" ok, hidden while nothing has been
    /// checked — FlClash has no grey "未检测" state).
    private var serviceBadge: (text: String, tint: Color)? {
        guard !trafficStore.services.isEmpty else { return nil }
        let abnormal = trafficStore.services.filter { $0.status != "available" }.count
        if abnormal == 0 { return ("全部可用", .green) }
        return ("\(abnormal) 项异常", .orange)
    }

    private func servicePill(for service: ConcordServiceItem?) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PackTileImage(
                    name: service?.name ?? "",
                    fallback: serviceTileText(service?.name),
                    fontSize: service?.name.lowercased() == "github" ? 14 : 20
                )
                .foregroundStyle(Color(.label))
                .frame(width: 40, height: 40)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if service?.status == "available" {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            Text(service?.delay.map { "\($0) ms" } ?? "—")
                .font(.footnote)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private func serviceTileText(_ name: String?) -> String {
        guard let name else { return "?" }
        if name.lowercased() == "github" { return "GH" }
        return String(name.prefix(1)).uppercased()
    }

    /// probe.services status strings are part of the core's contract
    /// (upstream crates/engine/src/probe/services.rs).
    private func serviceStatusLabel(_ status: String) -> String {
        switch status {
        case "available": return "可用"
        case "unavailable": return "不可用"
        case "restricted": return "受限"
        case "disallowed-isp": return "运营商限制"
        case "blocked": return "被墙"
        case "unsupported-region": return "地区不支持"
        case "originals-only": return "仅自制剧"
        case "coming-soon": return "即将推出"
        case "timeout": return "超时"
        case "failed": return "失败"
        case "": return "未判断"
        default: return status
        }
    }

    private func serviceStatusColor(_ status: String) -> Color {
        switch status {
        case "available": return .green
        case "blocked", "failed", "timeout", "unavailable": return .red
        default: return .orange
        }
    }

    /// v0.2.86 item 16: a failed/timeout status is only shown as
    /// failed once ServiceProbeStore confirms it (1 s confirm
    /// re-probe); until then the row reads "检测中" in secondary
    /// grey. Verdicts (blocked/restricted/…) are shown as-is.
    private func serviceRowStatusLabel(_ service: ConcordServiceItem) -> String {
        if ServiceProbeStore.isFailure(service),
           !trafficStore.serviceProbeStore.confirmedFailures.contains(service.name) {
            return "检测中"
        }
        return serviceStatusLabel(service.status)
    }

    private func serviceRowStatusColor(_ service: ConcordServiceItem) -> Color {
        if ServiceProbeStore.isFailure(service),
           !trafficStore.serviceProbeStore.confirmedFailures.contains(service.name) {
            return .secondary
        }
        return serviceStatusColor(service.status)
    }

    /// engine.state values (upstream crates/proto EngineStatus):
    /// created / initialized / configured / running / failed.
    private func engineStateLabel(_ state: String) -> String {
        switch state {
        case "created": return "已创建"
        case "initialized": return "已初始化"
        case "configured": return "已配置"
        case "running": return "运行中"
        case "failed": return "启动失败"
        default: return state
        }
    }

    private var tunnelStatusText: String {
        switch tunnelManager.status {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnecting: return "断开中"
        case .disconnected: return "已断开"
        case .reasserting: return "重新协商"
        case .invalid: return "未配置"
        @unknown default: return "未知"
        }
    }

    private var expandedServices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if trafficStore.isProbingServices {
                ProgressView()
            }
            if let error = trafficStore.servicesError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            if trafficStore.services.isEmpty {
                Text("通过当前出站检测 Google / GitHub / YouTube 等服务的可用性（probe.services）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                // D-M3: each row shows region + proxy chains + status
                // + delay (ConcordServiceItem carries all four).
                ForEach(trafficStore.services) { service in
                    HStack {
                        Text(service.name).font(.footnote)
                        Spacer()
                        if let chains = service.chains, !chains.isEmpty {
                            Text(chains.joined(separator: " → "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let region = service.region, !region.isEmpty {
                            Text(region).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(service.delay.map { "\($0) ms" } ?? "—").font(.caption2)
                        Text(serviceRowStatusLabel(service))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(serviceRowStatusColor(service))
                    }
                }
            }
            HStack(spacing: 8) {
                Button("检测") {
                    Task {
                        if let proxy = proxyStore.selectedOutbound {
                            await trafficStore.serviceProbeStore.probeAll(proxy: proxy)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ConcordTheme.accent)
                .controlSize(.small)
                .disabled(trafficStore.isProbingServices || proxyStore.selectedOutbound == nil)
                // D-M3: 全部检测 probes every registry service,
                // including ones disabled in 管理服务 (检测 only
                // probes the enabled ones).
                Button("全部检测") {
                    Task {
                        if let proxy = proxyStore.selectedOutbound {
                            await trafficStore.serviceProbeStore.probeAll(proxy: proxy, names: trafficStore.orderedServiceNames)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(trafficStore.isProbingServices || proxyStore.selectedOutbound == nil)
                Spacer()
                Button("管理服务") { onManageServices() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Divider()
            LabeledContent("引擎", value: trafficStore.engineStatus.map { engineStateLabel($0.state) } ?? (proxyStore.isRunning ? "已启动" : "已停止"))
                .font(.footnote.weight(.semibold))
            if let engine = trafficStore.engineStatus,
               let faults = engine.faults, !faults.isEmpty {
                ForEach(faults, id: \.service) { fault in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动失败：\(fault.service)").font(.footnote)
                        Text("\(fault.reason)：\(fault.message)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = trafficStore.engineStatusError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            LabeledContent("VPN 隧道", value: tunnelStatusText)
                .font(.footnote.weight(.semibold))
            // D5: the unexpected-disconnect banner used to live here,
            // inside this collapsed section — it now lives on the main
            // VPN card (vpnCardSection), always visible.
            if onDemandStore.enabled {
                Text("按需连接已开启：断网或切换网络后系统会自动重连。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("TUN", value: settingsStore.tunEnabled ? "已启用（\(settingsStore.tunStack)）" : "未启用")
                .font(.footnote.weight(.semibold))
            LabeledContent("DNS", value: settingsStore.dnsEnabled ? "已启用" : "未启用")
                .font(.footnote.weight(.semibold))
            Text(client.mode == .live
                 ? "数据面：PacketTunnel 扩展内的 Lumen 核心经 packet-channel 桥接转发流量；静态库构建与真机数据面尚未验证（见 README）。"
                 : "示例模式：VPN 开关只切换界面状态，不转发流量。切到实时核心并启动 VPN 后由扩展转发流量。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Memory card (FlClash memory_info.dart): app RSS (this process,
/// task_info) + core RSS (core.stats via TrafficStore). The core
/// runs in the NetworkExtension process, so the two numbers are
/// separate processes, not one total to be carved up. Polls every
/// 2s like FlClash; tapping opens the detail sheet with the
/// release-memory action. The app-bytes state lives here now —
/// DashboardView no longer holds it — and the 2 s poll pauses
/// while the detail sheet is open, exactly as before.
private struct MemoryCardView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore

    @State private var appMemoryBytes: UInt64 = 0
    @Binding var isDetailOpen: Bool
    let bigNumberSize: CGFloat
    let onOpenDetail: () -> Void

    private var memoryTotalBytes: UInt64 {
        appMemoryBytes + (trafficStore.coreMemoryBytes ?? 0)
    }

    var body: some View {
        Button { onOpenDetail() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    CardTitleRow(icon: "memorychip", title: "内存信息")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(ConcordFormat.bytes(Int64(memoryTotalBytes)))
                        .font(.system(size: bigNumberSize, weight: .bold))
                        .foregroundStyle(Color(.label))
                }
                MemoryBar(appBytes: appMemoryBytes, coreBytes: trafficStore.coreMemoryBytes ?? 0)
                HStack(spacing: 16) {
                    memoryLegend(dot: ConcordTheme.accent, label: "应用", bytes: appMemoryBytes)
                    memoryLegend(dot: memoryCoreColor, label: "核心", bytes: trafficStore.coreMemoryBytes ?? 0)
                }
                if !proxyStore.isRunning {
                    Text("核心未运行：仅应用内存为实测值，核心为 0。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // v0.2.64: belt-and-braces — the whole card is already
            // a Button, but the contentShape makes taps on any
            // transparent part of the card register too.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .concordCard()
        .task {
            await refreshMemorySnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // FlClash memory_info.dart pauses card polling while
                // the detail sheet is open (the sheet reads on its own).
                if !isDetailOpen {
                    await refreshMemorySnapshot()
                }
            }
        }
    }

    private func refreshMemorySnapshot() async {
        if let bytes = readAppMemoryBytes() {
            appMemoryBytes = bytes
        }
        await trafficStore.refreshMemory()
    }

    /// Core segment colour (FlClash style.dart series2: primary
    /// blended 45% over the card — a blue tone, not green).
    private var memoryCoreColor: Color { ConcordTheme.accent.opacity(0.45) }

    private func memoryLegend(dot: Color, label: String, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(Color(.label))
            Text(ConcordFormat.bytes(Int64(bytes)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(.label))
        }
    }
}

/// Host for the memory detail sheet: the sheet's core-bytes read
/// lives here, in a view that observes TrafficStore, so the
/// dashboard never reads the store. The app-bytes snapshot is
/// taken when the sheet opens and re-taken after a release —
/// exactly the values the dashboard used to pass in (the card's
/// 2 s poll pauses while this sheet is open, so the number was
/// frozen while open before too).
private struct MemoryDetailSheetHost: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var client: ConcordClient

    @State private var appMemoryBytes: UInt64 = 0
    @Binding var isReleasing: Bool
    @Binding var releaseMessage: String?

    var body: some View {
        MemoryDetailSheet(
            appBytes: appMemoryBytes,
            coreBytes: trafficStore.coreMemoryBytes,
            isReleasing: $isReleasing,
            releaseMessage: $releaseMessage,
            onRelease: {
                do {
                    try await client.coreReleaseMemory()
                    if let bytes = readAppMemoryBytes() {
                        appMemoryBytes = bytes
                    }
                    await trafficStore.refreshMemory()
                    releaseMessage = "已请求核心释放内存"
                } catch {
                    releaseMessage = "释放失败：\(error.localizedDescription)"
                }
            }
        )
        .task {
            if let bytes = readAppMemoryBytes() {
                appMemoryBytes = bytes
            }
        }
    }
}

/// Host for the 出站 IP sheet (MuYu key_3): the egress-IP read
/// and the core probe live here, in a view that observes
/// TrafficStore. The ip-api.com lookup still runs in
/// DashboardView (fetchIPInfo) and arrives as plain values.
private struct OutboundIPSheetHost: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore

    @Binding var hideIp: Bool
    let ipInfo: IPQualityInfo?
    let assessed: IPQualityInfo?
    let ipAsn: String?
    let isChecking: Bool
    let fetchFailed: Bool
    let fetchIPInfo: () async -> Void

    var body: some View {
        OutboundIPSheet(
            displayIp: dashboardDisplayIp(isRunning: proxyStore.isRunning, coreIp: trafficStore.outboundIp, fallbackQuery: ipInfo?.query),
            hideIp: $hideIp,
            assessed: assessed,
            ipAsn: ipAsn,
            isChecking: isChecking,
            fetchFailed: fetchFailed,
            onRefresh: {
                Task {
                    await fetchIPInfo()
                    await trafficStore.probe()
                }
            }
        )
        // v0.2.95 Bug 2: opening the sheet used to show a stale
        // failure even though the core's outboundIp had never been
        // (re-)probed since the tunnel connected — probe fresh on
        // appear while the tunnel runs and the IP is still unknown,
        // so the sheet can show the core IP instead.
        .onAppear {
            if TunnelManager.shared.isRunning, trafficStore.outboundIp == nil {
                Task { await trafficStore.probe() }
            }
        }
    }
}

/// Brand tile from the user's imported icon pack (v0.2.68):
/// IconPackStore matched by service/group name; the letter is
/// the only fallback. No built-in brand icons, by standing rule.
/// Internal so DashboardSheets' service rows can use it too.
struct PackTileImage: View {
    @ObservedObject private var iconPack = IconPackStore.shared
    let name: String
    let fallback: String
    let fontSize: CGFloat

    var body: some View {
        Group {
            if let url = iconPack.iconURL(for: name) {
                CachedIconImage(url: url) {
                    Text(fallback)
                        .font(.system(size: fontSize, weight: .bold))
                }
            } else {
                Text(fallback)
                    .font(.system(size: fontSize, weight: .bold))
            }
        }
    }
}
