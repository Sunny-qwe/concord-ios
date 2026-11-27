import SwiftUI
import UIKit

// MARK: - IP lookup diagnostics (v0.2.95 Bug 2)
//
// On-device v0.2.94 the Dashboard IP query still failed red, and
// nobody knew why: the app's URLSession requests never reached the
// core (no ip-api.com entry in the core log), so they died before
// TCP — most likely the app's DNS resolution — but every source
// swallowed its error (`catch { return false }`). These lines are
// the record of that: each failed source and each failed
// probe.outboundIp writes one timestamped line here (last 16 kept),
// and LogStore.fullExportText includes them, so the next on-device
// failure ships its cause in the log export instead of a bare red
// "检测失败".
struct IPLookupDiagnostics {
    private static let storageKey = "concord.ipLookupDiagnostics"
    private static let maxLines = 16

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

    /// The last recorded line only (v0.2.119 Fix 1): the status
    /// card shows one secondary line under "检测失败" instead
    /// of the whole 16-line history (the Diagnostics hub that
    /// would have shown it was deleted in v0.2.118, so the
    /// recorded reason was invisible in the UI).
    static func lastDiagnosticLine() -> String? {
        guard let text = lastDiagnosticText() else { return nil }
        return text.split(separator: "\n").map(String.init).last
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

// MARK: - Service status sheet open diagnostics (v0.2.123)
//
// On-device 2026-11-26 ~08:08 (v0.2.122, VPN off) the app froze
// right after the user tapped 服务状态 (the DNS sheet had opened
// fine just before and was dismissed first — the DNS path is
// exonerated). The watchdog proved a main-thread spin (CPU 100%,
// stall 08:08:33, ping sent 08:08:31) but its last action was the
// DNS tap (statsDestination set to .dns at 08:08:25): the 服务状态
// tap was never instrumented, so the stall line cannot tell the
// two taps apart. These lines are the four phases of opening the
// 服务状态 sheet — tap, sheet state set, sheet appeared,
// probeNodeIPs enter/exit (with per-node lines) — so the next
// freeze ships its exact phase in the log export: a freeze with
// only the tap line died in presentation; one with "正在探测节点
// X" and no completion died inside that node's probeOutboundIp.
// Same UserDefaults ring buffer as IPLookupDiagnostics (last 16
// lines — per-node lines can be several), synchronous write so it
// survives a force-quit. LogStore must surface it (parent wires
// one line: "== 服务状态打开诊断 ==" +
// ServiceSheetDiagnostics.lastDiagnosticText()). The static
// trace found NO deterministic cause (see the v0.2.123 report):
// probeNodeIPs returns immediately when services is empty, every
// await on the path is a true suspension, there is no semaphore /
// sync wait / busy loop anywhere in the app, and icon decoding
// runs off the main thread — so this is diagnosis, not a fix.
struct ServiceSheetDiagnostics {
    private static let storageKey = "concord.serviceSheetDiagnostics"
    private static let maxLines = 16

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
// (stats), tunnelManager and client. TrafficStore's speed /
// services / engine reads still live in narrow leaf views
// (v0.2.69, see the MARK at the end of this file), but v0.2.115
// adds three direct probe reads here (outboundIp,
// outboundIpInfo.countryCode, outboundIpProbeFailed) — the status
// card's IP comes only from the core probe now — so this body
// subscribes to TrafficStore and re-evaluates when the probe
// lands (and on the 1 s tick); the leaves still isolate their own
// re-renders. Only the look and the navigation changed.

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
    /// v0.2.115: the status card's IP comes ONLY from the core
    /// probe (TrafficStore.probe + parseOutboundIp), so this view
    /// reads the probe IP, its country and its failure flag
    /// directly. NOTE: this subscribes the dashboard body to
    /// TrafficStore — the v0.2.69 "parent stays unsubscribed"
    /// design no longer holds for these reads, so the body
    /// re-evaluates on the 1 s traffic tick too; the per-second
    /// numbers still live in leaf views, so the tick never
    /// re-renders the leaves themselves. (Also fixes the base:
    /// fetchIPInfo already referenced this store with no
    /// declaration in scope.)
    @EnvironmentObject private var trafficStore: TrafficStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @AppStorage("ConcordiOS.dashboard.show.speed") private var showSpeed = true
    @AppStorage("ConcordiOS.dashboard.show.mode") private var showMode = true
    @AppStorage("ConcordiOS.dashboard.show.vpn") private var showVpn = true
    @AppStorage("ConcordiOS.dashboard.show.services") private var showServices = true
    @AppStorage("ConcordiOS.dashboard.show.profile") private var showProfile = true
    @AppStorage("ConcordiOS.dashboard.show.groups") private var showGroups = true
    @AppStorage("ConcordiOS.dashboard.show.stats") private var showStats = true
    @AppStorage("ConcordiOS.dashboard.show.memory") private var showMemory = true
    /// Traffic statistics card (MuYu TrafficStatisticsCard, D-M8):
    /// today's up/down + uptime, plus week/month totals from the
    /// daily history TrafficStore records since v0.2.55.
    @AppStorage("ConcordiOS.dashboard.show.traffic") private var showTraffic = true
    /// Intranet IP card (v0.2.146, D-45, upstream
    /// intranet_ip.dart): the LAN IPv4 + allow-LAN switch.
    @AppStorage("ConcordiOS.dashboard.show.intranet") private var showIntranet = true
    /// Card order, comma-separated DashboardCardID raw values; empty
    /// means the default order (also used to append cards added by
    /// later versions).
    @AppStorage("ConcordiOS.dashboard.order") private var cardOrderString = ""

    /// Inline edit mode (v0.2.85, upstream dashboard.dart
    /// `_editing`): the pencil in the title row toggles editing
    /// on this page and becomes a check "done" — no sheet.
    @State private var isEditingDashboard = false
    /// TrafficStore action channel (v0.2.69): the
    /// DashboardTrafficEffects leaf observes the store and fills
    /// these closures on appear; the dashboard only *calls* them
    /// from user gestures (pull-to-refresh, the clover refresh),
    /// which never subscribe by themselves. v0.2.115: the view
    /// itself now observes TrafficStore for the probe IP/flag
    /// (status card), so the body does re-evaluate on probe
    /// changes and on the 1 s tick — the channel still avoids
    /// *extra* subscriptions from gestures.
    @State private var trafficActions = DashboardTrafficActions()
    /// Stat-cell destination sheet (D-M6): live / recent
    /// connections, or the DNS queries page. v0.2.111 / v0.2.113:
    /// owned by ContentView, not here — all three destinations
    /// render as custom overlays at the ContentView root (the
    /// system .sheet presentation path is a freeze suspect), so
    /// the state has to live above the tab bar. This binding is
    /// passed in from ContentView; there is no system .sheet for
    /// these destinations in this view anymore.
    @Binding var statsDestination: StatsDestination?
    /// Traffic statistics detail sheet (D-M8, v0.2.56 MuYu
    /// TrafficStatisticsView).
    @State private var showTrafficDetail = false
    /// IP-quality sheet target (v0.2.139, upstream
    /// current_outbound.dart:458): tapping the outbound IP text
    /// opens the per-IP quality sheet for that IP.
    @State private var ipQualitySelection: IpQualitySheetTarget?
    /// Rule-providers sheet (config card, MuYu key_25).
    @State private var showProfileDetailSheet = false
    /// Strategy-groups sheet (groups card, v0.2.64): upstream
    /// opens ProxiesView(picker: true) here instead of jumping
    /// to the Proxies tab.
    @State private var showGroupsSheet = false
    /// Profile picker sheet (v0.2.146, D-32): the profile card's
    /// tap (no active profile) and swap button open
    /// ProfilesView(picker: true) here instead of jumping to the
    /// Profiles tab. ProfilesView does not dismiss itself on
    /// selection, so the sheet watches the active profile id and
    /// closes when it changes (pickerProfileId records the id at
    /// presentation).
    @State private var showProfilesPicker = false
    @State private var pickerProfileId: UUID?
    @State private var tunnelStartedAt: Date?
    /// v0.2.118 (Job 6): when the app observed the current tunnel
    /// run start (the running=false→true transition in
    /// DashboardTrafficEffects). Later diagnostics-file reads only
    /// accept a record from this run (readTunnelStartedAt
    /// notBefore:); nil means no transition was observed this
    /// session (tunnel already up at launch) and the file is
    /// accepted as before (D4).
    @State private var tunnelStartObservedAt: Date?
    /// v0.2.128 item 6: the startupId of the tunnel run the
    /// uptime belongs to (the extension's per-run UUID in
    /// vpn-diagnostics.json). Deliberately NOT cleared on stop —
    /// a flap (brief disconnect/reconnect) keeps the same run id,
    /// so the periodic correction can match the file's record to
    /// this run and restore the true start time instead of the
    /// Date() reset. A genuine restart writes a new id, which
    /// the correction recognises as a different run.
    @State private var tunnelStartupId: String?
    @State private var subscription: ConcordSubscriptionInfo?
    /// Last-known IP lookup, restored on launch so the status card
    /// is never empty (v0.2.115, MuYu parity) and refreshed in the
    /// background at appear. Only ever the user's own last egress;
    /// a fresh probe overwrites it within seconds of launch.
    @State private var ipInfo: IPQualityInfo? = DashboardView.cachedIpInfo()
    /// Enrichment-failure flag (v0.2.121): the IP enrichment
    /// fan-out failed (every source failed). Without it the
    /// chips/org showed pulsing skeletons forever when the
    /// enrichment failed deterministically; with it they settle on
    /// the fallback chips / "—". Reset at the start of every
    /// fetchIPInfo() attempt; the probed IP itself is unaffected
    /// (it comes from the core probe, not the enrichment).
    @State private var ipEnrichmentFailed = false
    @State private var morphProgress: CGFloat = 0
    @State private var ipChecking = false
    /// v0.2.128 item 3: the clover's own refresh flag. fetchIPInfo
    /// sets ipChecking only during the enrichment — and returns
    /// early (without setting it) when there is no probed IP yet —
    /// so a tap whose probe is still running showed no spinner at
    /// all. This flag covers the whole tap (enrichment + probe),
    /// and the badge spins while either flag is set.
    @State private var cloverRefreshing = false
    /// In-flight guard for the egress-IP geo enrichment (v0.2.101
    /// issue 1b): .task, onChange(isRunning), pull-to-refresh and
    /// the manual re-fetch taps all funnel through fetchIPInfo();
    /// with no guard two of them can run the enrichment lookup
    /// concurrently (TrafficStore.probe has isProbingOutboundIp;
    /// this lookup had none). v0.2.115: the direct 3-source IP
    /// chain is gone — fetchIPInfo only enriches the probed IP,
    /// and the failure flag it used to set (ipFetchFailed) is
    /// deleted: the red failure is the probe's own flag now
    /// (trafficStore.outboundIpProbeFailed).
    @State private var ipFetchInFlight = false
    /// The bare "AS<n>" token for the org fallback (FlClash
    /// current_outbound.dart: organization ?? "AS{asn}"). The
    /// fan-out answers carry it in IPQualityInfo.asn — ip-api.com's
    /// `as` field is "AS15169 Google LLC", so only the first token
    /// is kept (see fetchIPEnrichment). Restored from the same
    /// last-known cache as ipInfo (above).
    @State private var ipAsn: String? = DashboardView.cachedIpAsn()
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
    /// Update state (v0.2.146, D-46/D-51): the standalone update
    /// card is deleted, but the check result still feeds the
    /// live-status deck's update entry — the same UpdateChecker
    /// the About page uses, the last result kept in AppStorage so
    /// the deck shows something before the first check of the
    /// session.
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

    /// v0.2.115: MuYu _vpnSubtitle parity — a failed start
    /// appends the reason (proxyStore.startError is set only
    /// when a start attempt fails and cleared on success/stop).
    private var tunnelStatusText: String {
        switch tunnelManager.status {
        case .connected: return "dashboard.status.connected".l10n
        case .connecting: return "dashboard.status.connecting".l10n
        case .disconnecting: return "dashboard.status.disconnecting".l10n
        case .disconnected:
            if let startError = proxyStore.startError, !startError.isEmpty {
                return "\("dashboard.status.disconnectedDetail".l10n): \(startError)"
            }
            return "dashboard.status.disconnected".l10n
        case .reasserting: return "dashboard.status.reasserting".l10n
        case .invalid: return "dashboard.status.invalid".l10n
        @unknown default: return "common.unknown".l10n
        }
    }

    private func modeShortLabel(_ mode: OutboundMode) -> String {
        switch mode {
        case .rule: return "common.rule".l10n
        case .global: return "common.global".l10n
        case .direct: return "common.direct".l10n
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

    // MARK: - Card order (FlClash dashboard/edit.dart)

    /// Card spacing and type sizes (v0.2.146, D-48): the compact
    /// density toggle was removed — upstream has no density
    /// switch on the dashboard — so these are the standard
    /// (non-compact) values, kept as named constants for the
    /// card layouts that read them.
    private var stackSpacing: CGFloat { 12 }
    private var playButtonSize: CGFloat { 88 }
    private var bigNumberSize: CGFloat { 25 }
    private var statNumberSize: CGFloat { 24 }

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

    private func checkForUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        if let result = await UpdateChecker.check() {
            lastUpdateSha = result.sha
            lastUpdateMessage = result.message
            lastUpdateDate = result.date
            lastUpdateIsNew = result.isNew
            lastUpdateChecked = true
        }
    }

    /// Restarts the core (v0.2.146, D-51): the live-status deck's
    /// core-running card offers this. The stop/wait/start pattern
    /// moved here from the deleted TUN-restart banner — stop()
    /// waits up to 5 s for .disconnected; make sure the tunnel
    /// really settled before toggling, or the toggle would stop
    /// again instead of starting. A start failure lands in
    /// proxyStore.startError, like the play button's.
    private func restartCore() {
        Task {
            await TunnelManager.shared.stop()
            let deadline = Date().addingTimeInterval(10)
            while TunnelManager.shared.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await proxyStore.toggle()
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
            return String(format: "dashboard.profile.daysLeft".l10n, "\(ConcordRelativeTime.daysUntil(epochSeconds: info.expire))")
        }
        return profile.kind == .url ? "common.remote".l10n : "common.local".l10n
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
        return String(format: "dashboard.profile.expiresIn".l10n, formatter.string(from: date), "\(days)")
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

    /// Last-known IP lookup cache (v0.2.115): the status card
    /// restores these on launch so it is never empty, then the
    /// appear probe refreshes them in the background.
    private static let cachedIpInfoKey = "ConcordiOS.dashboard.ipInfo.v1"
    private static let cachedIpAsnKey = "ConcordiOS.dashboard.ipAsn.v1"
    private static func cachedIpInfo() -> IPQualityInfo? {
        guard let data = UserDefaults.standard.data(forKey: cachedIpInfoKey) else { return nil }
        return try? JSONDecoder().decode(IPQualityInfo.self, from: data)
    }
    private static func cachedIpAsn() -> String? {
        UserDefaults.standard.string(forKey: cachedIpAsnKey)
    }

    /// Stores a fresh IP lookup and persists it (see above). The
    /// enrichment lookup funnels through here so the cache is
    /// always the newest answer.
    private func setIpInfo(_ info: IPQualityInfo?, asn: String?) {
        ipInfo = info
        ipAsn = asn
        if let info, let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: Self.cachedIpInfoKey)
        }
        if let asn {
            UserDefaults.standard.set(asn, forKey: Self.cachedIpAsnKey)
        }
    }

    /// Geo/quality enrichment for the already-probed egress IP
    /// (v0.2.115, MuYu parity). The IP itself comes ONLY from the
    /// core probe (TrafficStore.probe + parseOutboundIp) — this
    /// never discovers an IP via HTTP: the direct ip-api.com /
    /// ident.me / ipify chain is deleted, so the status card can
    /// no longer show the phone's direct IP as the egress. This
    /// only fetches geo/org/ASN/quality for the probed IP (the
    /// upstream ipQualityProvider equivalent — upstream also looks
    /// the quality up over HTTP for the known probed IP). A failed
    /// enrichment sets the failure flag and schedules no retry
    /// beyond the one below: the IP still shows from the probe,
    /// and the next probe / pull-to-refresh / manual re-fetch
    /// enriches again. The status card shows the result with the
    /// VPN off too — MuYu shows the full card with the tunnel
    /// down.
    ///
    /// v0.2.146 (D-60): the enrichment runs upstream's fan-out
    /// (IPQualityView.lookupWaves — 6 sources in 4 waves,
    /// ident.me / ip-api.com / ipquery.io / iplocate.io /
    /// ipapi.is / proxycheck.io, 1 s hedge, 8 s per source), not
    /// the old ip-api.com-only fetch. Each source is tried
    /// through the core's local mixed proxy first and directly
    /// second, like the old code.
    private func fetchIPInfo() async {
        // v0.2.115: the IP comes from the core probe only — no
        // probed IP yet means nothing to enrich.
        guard let ip = trafficStore.outboundIp, !ip.isEmpty else { return }
        // v0.2.121: a fresh attempt clears the failure flag; the
        // lookup below sets it again if it fails, so the chips/org
        // settle instead of skeletoning forever.
        ipEnrichmentFailed = false
        // v0.2.101 issue 1b: in-flight guard — .task and
        // onChange(isRunning) can fire at the same moment (appear
        // while the tunnel is connecting), and a manual re-fetch
        // tap can land mid-lookup; the second caller returns
        // instead of running a duplicate enrichment lookup.
        guard !ipFetchInFlight else { return }
        ipFetchInFlight = true
        defer { ipFetchInFlight = false }
        // v0.2.128 item 7: the first query after connect used to
        // run in the instant the tunnel came up, when the app
        // process's DNS/routing is not yet stable — the lookup
        // fast-fails and the card stays without geo until a manual
        // re-fetch. The lookup now goes through the core's local
        // proxy first (below), whose routing is stable as soon as
        // the tunnel is up, so only a 1 s settle remains
        // (was 4 s) — the proxy only needs the core to be listening
        // on 17890. No delay when the tunnel has been up for a
        // while, or its start time is unknown.
        if proxyStore.isRunning, let started = tunnelStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 1 {
                try? await Task.sleep(nanoseconds: UInt64((1 - elapsed) * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
        ipChecking = true
        defer { ipChecking = false }
        // v0.2.128 item 7: one automatic retry 2 s after a failure
        // (a transient proxy/DNS miss right after connect), so the
        // enrichment self-heals instead of skeletoning until a
        // manual re-fetch. The retry only runs for the same IP —
        // a fresh probe in between owns the enrichment.
        if await fetchIPEnrichment(for: ip) {
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return }
        guard trafficStore.outboundIp == ip else { return }
        _ = await fetchIPEnrichment(for: ip)
    }

    /// One fan-out enrichment for a KNOWN IP: the waves answer
    /// with the first stated type (an inferred residential answer
    /// is only a fallback). True when an answer landed and was
    /// stored; false when every source failed — then the failure
    /// flag is set and one diagnostics line records the
    /// per-source failures. When the VPN is off there is no core
    /// on 17890, so the proxy attempt fails fast and the direct
    /// lookup runs instead.
    private func fetchIPEnrichment(for ip: String) async -> Bool {
        let sessions = [ServiceProbeLocal.makeProxySession(timeoutSeconds: 8), URLSession.shared]
        let result = await IPQualityView.lookupWaves(targetIp: ip, sessions: sessions)
        if let (answer, _) = result.answer {
            // v0.2.128 item 7: a successful enrichment clears the
            // failure flag — the first attempt can fail (setting
            // the flag) and the retry succeed, and the flag must
            // not stay stale afterwards.
            ipEnrichmentFailed = false
            setIpInfo(answer, asn: answer.asn?.split(separator: " ").first.map(String.init))
            return true
        }
        ipEnrichmentFailed = true
        let failures = result.failures.map { "\($0.source): \($0.status.rawValue)" }.joined(separator: ", ")
        IPLookupDiagnostics.record("enrichment: all sources failed (\(failures))")
        return false
    }

    /// The ip-api.com answer assessed like upstream (D-D3): the
    /// type and level come from the real hosting/mobile/proxy
    /// flags — the old code derived "质量 优/良/差" from the
    /// lookup latency, which says nothing about the IP. The
    /// fan-out answers already carry a stated (or inferred) type
    /// via assessed() — that wins. Only a legacy cache entry
    /// from the ip-api.com-only days (qualityType == nil) falls
    /// back to deriving the type from the hosting/mobile flags
    /// (ip-api.com states no type, so silence about
    /// hosting/mobile reads as residential, flagged inferred —
    /// upstream _pickType fallback).
    private var assessedIpInfo: IPQualityInfo? {
        guard let info = ipInfo else { return nil }
        if info.qualityType != nil { return info }
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
        // v0.2.118 (Job 6): the read is gated to this run's record
        // (notBefore:), so a pull-to-refresh after a (re)start
        // cannot resurrect the previous run's startedAt.
        if proxyStore.isRunning, let extStarted = tunnelManager.readTunnelStartedAt(notBefore: tunnelStartObservedAt) {
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
        // v0.2.115: probe the egress IP first — fetchIPInfo prefers
        // the core-probed IP for the geo query (see the branch in
        // fetchIPInfo), so the card refreshes to the egress's
        // country/org, not the phone's direct IP.
        await trafficActions.probe()
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
        // v0.2.115: the geo/quality enrichment follows the core
        // probe (upstream ipQualityProvider watches the probe's
        // IpInfo) — whenever a fresh probed IP lands, enrich it.
        .onChange(of: trafficStore.outboundIp) { _, ip in
            if ip != nil {
                Task { await fetchIPInfo() }
            }
        }
        .sheet(isPresented: $showMemoryDetail) { memoryDetailSheet }
        .sheet(isPresented: $showTrafficDetail) { trafficDetailSheet }
        .sheet(item: $ipQualitySelection) { target in
            IPQualityView(ip: target.ip)
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
                .presentationBackground(ConcordTheme.pageBackground)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showProfileDetailSheet) { profileDetailSheetContent }
        .sheet(isPresented: $showGroupsSheet) { groupsSheetContent }
        .sheet(isPresented: $showProfilesPicker) { profilesPickerSheetContent }
        // v0.2.146 (D-32): ProfilesView(picker:) does not dismiss
        // itself on selection — the picker sheet closes when the
        // active profile changes, and the card's subscription info
        // refreshes for the new profile. Guarded by
        // showProfilesPicker so a switch from the Profiles tab
        // does not touch the dashboard.
        .onChange(of: profileStore.activeProfile?.id) { _, newId in
            guard showProfilesPicker, let newId, newId != pickerProfileId else { return }
            pickerProfileId = newId
            showProfilesPicker = false
            Task { await refreshSubscription() }
        }
        // The dashboard's consent prompt (fork 0a55a31): the same
        // prompt the modules page uses, asked over the dashboard
        // for each module that awaits an answer in turn; an answer
        // either way takes the module off the card.
        .alert(reviewAlertTitle, isPresented: $showReviewAlert, presenting: reviewModule) { module in
            Button("common.cancel".l10n, role: .cancel) {
                Task { await answerReview(module, agreed: false) }
            }
            Button("dashboard.module.enable".l10n) {
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

    /// The scrolling card list: title row, the inline edit panel,
    /// the ordered cards, and the start-error line.
    private var dashboardScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: stackSpacing) {
                titleRow
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
            tunnelStartObservedAt: $tunnelStartObservedAt,
            tunnelStartupId: $tunnelStartupId,
            morphProgress: $morphProgress,
            ipInfo: $ipInfo,
            ipAsn: $ipAsn,
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

    /// v0.2.56: the config card opens the rule-providers
    /// sheet (MuYu key_25).
    private var profileDetailSheetContent: some View {
        ProfileDetailSheet(profileName: profileStore.activeProfile?.name ?? "dashboard.profile.fallback".l10n, subscription: subscription)
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

    /// v0.2.146 (D-32): the profile card's tap (no active profile)
    /// and swap button open the picker sheet (upstream
    /// profiles.dart _openProfile → ProfilesView(picker: true))
    /// instead of jumping to the Profiles tab. The sheet closes
    /// when the active profile changes — see the onChange in
    /// dashboardScrollContent.
    private var profilesPickerSheetContent: some View {
        ProfilesView(picker: true)
            .presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }

    /// v0.2.113: the .live / .recent stats sheets no longer use
    /// the system .sheet either — like .dns since v0.2.111, they
    /// render as custom overlays at the ContentView root
    /// (ConnectionsSheetOverlay). The content is unchanged:
    /// ConnectionsView sheetChrome on the tapped feed, with the
    /// same 0.5625 / 0.9 detents, 28pt corners and dim. The old
    /// connectionsSheetDestination binding and statsSheetContent
    /// builder were removed with the system sheet.
    /// D-M6: a stat cell opens its source page — live/recent
    /// connections, or the DNS queries page for the DNS cell.
    /// v0.2.68: MuYu sheet chrome — no NavigationStack, no
    /// system nav bar; each content view renders its own
    /// MuYu header (handle + ✕ + title + actions) and a
    /// bottom floating search bar.

    // MARK: - Modules awaiting consent (fork 2d31f10 + 0a55a31)

    /// v0.2.146 (D-51): the pinned pending-modules card is gone —
    /// MITM consent is a live-status deck entry now (see
    /// LiveStatusDeck in ConfigWarningsDeck.swift, reached from
    /// the title-row live-status pill). The review state machine
    /// below stays: the deck's MITM action calls reviewNext(),
    /// and the same consent alert asks about each module in turn.

    /// The prompt title for the module the dashboard is asking about.
    private var reviewAlertTitle: String {
        reviewModule.flatMap { mitmModuleStore.consentPrompt(for: $0)?.title } ?? "dashboard.module.consentFallback".l10n
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
                        Text("\("dashboard.vpn.startFailed".l10n)\(startError)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 4)
                }
            }
        case .speed: if showSpeed { speedCard }
        case .traffic: if showTraffic { trafficCard }
        case .mode: if showMode { modeCard }
        case .vpn: if showVpn { vpnCard }
        case .intranet: if showIntranet { intranetCard }
        case .services: if showServices { servicesCard }
        case .profile: if showProfile { profileCard }
        case .groups: if showGroups { groupsCard }
        case .stats: if showStats { statsCard }
        case .memory: if showMemory { memoryCard }
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
            // the faults badge first, then the live-status pill
            // (core / update / MITM / warnings deck); both hidden
            // while editing. Both are TrafficStore leaves, so the
            // 1 s tick never re-evaluates this view (v0.2.69).
            if !isEditingDashboard {
                DashboardServiceFaultsBadge()
                DashboardLiveStatusPill(
                    isCheckingUpdate: isCheckingUpdate,
                    onStartCore: { Task { await proxyStore.toggle() } },
                    onRestartCore: restartCore,
                    onReviewMitm: { reviewNext() },
                    onOpenReleases: {
                        if let url = URL(string: "https://github.com/Sunny-qwe/concord-ios/releases/latest") {
                            openURL(url)
                        }
                    },
                    onCheckUpdate: { Task { await checkForUpdate() } }
                )
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
            .accessibilityLabel(isEditingDashboard ? "dashboard.edit.done".l10n : "dashboard.edit.editCards".l10n)
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
            Text("dashboard.edit.title".l10n)
                .font(.headline)
            Text("dashboard.edit.unremovableNote".l10n)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("dashboard.card.speed".l10n, isOn: $showSpeed)
            Toggle("dashboard.card.traffic".l10n, isOn: $showTraffic)
            Toggle("dashboard.card.mode".l10n, isOn: $showMode)
            Toggle("VPN", isOn: $showVpn)
            Toggle("局域网 IP", isOn: $showIntranet)
            Toggle("dashboard.card.services".l10n, isOn: $showServices)
            Toggle("dashboard.card.profile".l10n, isOn: $showProfile)
            Toggle("dashboard.card.groups".l10n, isOn: $showGroups)
            Toggle("dashboard.card.stats".l10n, isOn: $showStats)
            Toggle("dashboard.card.memory".l10n, isOn: $showMemory)
            Divider()
            Text("dashboard.edit.cardOrder".l10n)
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
            Text("dashboard.edit.orderHint".l10n)
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

    /// Chips slot (FlClash _IpChips): two pulsing pills while the
    /// lookup is loading, the real network-type + quality pills
    /// once probed, a retry hint if the probe failed. v0.2.115:
    /// the pills show whenever ipInfo is present — the old
    /// `!isRunning` branch showed static grey bars with the VPN
    /// off, but MuYu shows the real chips with the tunnel down
    /// (the values come from the in-app core's probe at launch);
    /// the skeleton is only the transient pre-probe state now.
    private var chipsSlot: some View {
        Group {
            if ipInfo != nil {
                HStack(spacing: 8) {
                    // v0.2.126: upstream _IpChips shows the EXIT IP's
                    // type (机房/住宅/… from the assessed lookup)
                    // only when known; when quality is null and not
                    // loading it shows only the "类型未知" chip —
                    // never the device network type.
                    if let ipType = assessedIpInfo?.qualityType?.label {
                        PillBadge(text: ipType, tint: .gray)
                    }
                    if let assessed = assessedIpInfo, let level = assessed.qualityLevel {
                        // D-D3: the quality pill comes from the real
                        // IP type/level (hosting → 普通, else 优),
                        // not from the lookup latency.
                        qualityPill(text: "\("dashboard.outbound.qualityPrefix".l10n) \(level.label)", level: level)
                    } else {
                        // FlClash _IpChips: quality null and not
                        // loading shows a "类型未知" chip.
                        PillBadge(text: "dashboard.outbound.unknownType".l10n, tint: .gray)
                    }
                }
            // v0.2.115: the retry hint is driven by the PROBE
            // failure now, not the deleted HTTP chain.
            // v0.2.124: settled failure only (see
            // outboundIpFailureSettled) — while the fast retries
            // are still running, the chips below show the probing
            // skeletons instead of this hint.
            } else if trafficStore.outboundIpFailureSettled {
                Text("dashboard.outbound.retryHint".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if ipEnrichmentFailed {
                // v0.2.121: the enrichment failed (e.g. a foreign
                // body from ip-api.com) — settle on the single
                // "类型未知" chip instead of pulsing skeletons
                // forever (upstream _IpChips: quality null and not
                // loading shows only that chip).
                PillBadge(text: "dashboard.outbound.unknownType".l10n, tint: .gray)
            } else {
                HStack(spacing: 6) {
                    SkeletonBar(width: 48, height: 28, animated: true)
                    SkeletonBar(width: 72, height: 28, animated: true)
                }
            }
        }
        .frame(height: 28, alignment: .leading)
    }

    /// Org cell (FlClash _Cells): a pulsing skeleton while the
    /// lookup is loading, the real org once probed (falling back to
    /// the "AS<n>" token, FlClash: organization ?? "AS{asn}"), "—"
    /// if the probe answered without an org or failed. v0.2.115:
    /// shows whenever ipInfo is present, tunnel up or down (MuYu
    /// shows the org with the VPN off); the skeleton is only the
    /// transient pre-probe state now.
    private var orgValue: some View {
        Group {
            if let org = ipInfo?.org ?? ipInfo?.isp ?? ipAsn {
                Text(org)
                    .font(.system(size: 14))
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else if ipInfo == nil && !trafficStore.outboundIpFailureSettled && !ipEnrichmentFailed {
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
                        CardTitleRow(icon: "waveform.path.ecg", title: "dashboard.status.title".l10n)
                        PillBadge(text: proxyStore.isRunning ? "dashboard.status.running".l10n : "dashboard.status.notRunning".l10n,
                                  tint: proxyStore.isRunning ? .green : .gray,
                                  dot: proxyStore.isRunning)
                    }
                    .frame(height: 26)
                    Spacer().frame(height: 12)
                    HStack(spacing: 12) {
                        CloverBadge(
                            // v0.2.115: the probe's country is
                            // authoritative; the cached/quality
                            // ipInfo stays as the instant-on-launch
                            // fallback.
                            countryCode: trafficStore.outboundIpInfo?.countryCode ?? ipInfo?.countryCode,
                            checking: ipChecking || cloverRefreshing,
                            // D-D9: the clover refresh re-probes the
                            // egress IP through the core as well as
                            // the ip-api.com lookup, so the status
                            // card's IP and the core probe agree.
                            // v0.2.69: the probe goes through the
                            // non-subscribing action channel.
                            onRefresh: {
                                Task {
                                    cloverRefreshing = true
                                    defer { cloverRefreshing = false }
                                    await fetchIPInfo()
                                    await trafficActions.probe()
                                }
                            }
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            // v0.2.69: the IP slot observes
                            // TrafficStore itself, so the 1 s tick
                            // re-renders only the slot.
                            // v0.2.139 (Q-D3/Q-M5, upstream
                            // current_outbound.dart:458): ONLY the
                            // IP text is tappable, and it opens the
                            // per-IP quality sheet for that IP. The
                            // rest of the card has no tap (upstream
                            // has none either). Disabled while no IP
                            // is known (failure/skeleton show no IP).
                            Button {
                                if let ip = dashboardDisplayIp(coreIp: trafficStore.outboundIp) {
                                    ipQualitySelection = IpQualitySheetTarget(ip: ip)
                                }
                            } label: {
                                StatusIpSlotView()
                            }
                            .buttonStyle(.plain)
                            .disabled(dashboardDisplayIp(coreIp: trafficStore.outboundIp) == nil)
                            Spacer().frame(height: 4)
                            chipsSlot
                        }
                    }
                    Spacer().frame(height: 16)
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("dashboard.status.uptime".l10n)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // v0.2.69: the uptime text is its own leaf
                            // with its own 1 s tick — it no longer
                            // forces the status card (or the whole
                            // dashboard) to rebuild every second.
                            StatusUptimeText(startedAt: tunnelStartedAt)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("dashboard.status.org".l10n)
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
                // v0.2.146 (D-9): the start is gated on having a
                // profile (MuYu _StartToggle enabled: hasProfile)
                // — proxyStore.toggle() does NOT no-op without one,
                // it starts the tunnel and lands the failure in
                // startError. The gate is start-only: a running
                // tunnel can always be stopped, even if the profile
                // was deleted mid-run. Dimmed while gated so the
                // disabled state is visible.
                .disabled(!proxyStore.isRunning && profileStore.activeProfile == nil)
                .opacity(proxyStore.isRunning || profileStore.activeProfile != nil ? 1 : 0.4)
                .accessibilityLabel(proxyStore.isRunning ? "dashboard.stopVpn".l10n : "dashboard.startVpn".l10n)
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
        .accessibilityLabel("dashboard.status.title".l10n)
        .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
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
            CardTitleRow(icon: "gauge.with.dots.needle.33percent", title: "dashboard.card.speed".l10n)
            HStack(spacing: 12) {
                // v0.2.69: each panel observes TrafficStore
                // itself — the 1 s tick re-renders only the two
                // panels, not the card or the dashboard.
                SpeedPanelView(isUp: true, bigNumberSize: bigNumberSize)
                SpeedPanelView(isUp: false, bigNumberSize: bigNumberSize)
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
            CardTitleRow(icon: "arrow.triangle.branch", title: "dashboard.card.outbound".l10n)
            // FlClash outbound_mode.dart DashboardConnectedGroup: one
            // connected pill — outer radius 26, height 52, icon 18,
            // selected segment primary-filled, inner radius 12.
            // FlClash outbound_mode.dart noProfileDirect: with no
            // active profile there are no rules/proxies, so every
            // mode goes direct — show the notice instead of the
            // mode buttons.
            if profileStore.activeProfile == nil {
                Text("dashboard.outbound.noProfileDirect".l10n)
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
                get: { proxyStore.vpnEnabled },
                set: { newValue in Task { await proxyStore.setVpnEnabled(newValue) } }
            ))
            .labelsHidden()
            // MuYu video: the switch follows the theme accent
            // (magenta under the magenta theme, blue under the
            // default blue theme). v0.2.115: the switch binds to
            // the PERSISTENT vpnEnabled flag (upstream
            // network_takeover.dart `tun.enable`), NOT to the live
            // tunnel state — it stays on across tunnel stops and
            // app restarts, and the status card's play button is
            // the start/stop control. Flipping it only flips the
            // persisted setting — setVpnEnabled is setting-only
            // (MuYu _setVpn literal) and does NOT start/stop the
            // tunnel; a failed start still lands in
            // proxyStore.startError via the play button.
            .tint(ConcordTheme.accent)
        }
        .concordCard(padding: 12)
        // The Toggle keeps its own tap (the inner control wins the
        // gesture), so tapping the switch toggles once. Tapping the
        // card elsewhere flips the same enable flag.
        .contentShape(Rectangle())
        .onTapGesture { Task { await proxyStore.setVpnEnabled(!proxyStore.vpnEnabled) } }
    }

    /// Intranet IP card (v0.2.146, D-45, upstream
    /// intranet_ip.dart): the LAN IPv4 + allow-LAN switch, 6th in
    /// the mobile default order. The leaf reads the address
    /// itself (getifaddrs) and the switch from SettingsStore.
    private var intranetCard: some View {
        IntranetIpCardView(bigNumberSize: bigNumberSize)
    }

    // MARK: - Service status card

    // v0.2.69: the whole card lives in ServicesCardView, which
    // observes TrafficStore itself. Its data changes on probe,
    // not every second — but any read here would subscribe this
    // view to the store and re-render the dashboard on the 1 s
    // tick, so the card had to move out with the rest.
    private var servicesCard: some View {
        ServicesCardView(
            onOpenServiceSheet: {
                // v0.2.124: the 服务状态 sheet is now a custom
                // overlay at the ContentView root (statsDestination
                // .services), like .dns / .live / .recent since
                // v0.2.111 / v0.2.113 — the system .sheet path
                // froze on 123 (main-thread CPU 100% after the
                // sheet appeared, probe skipped). The tap
                // diagnostic stays: it records the tap phase and
                // the overlay-target phase for the next stall line.
                MainThreadWatchdog.noteAction("service sheet tap")
                ServiceSheetDiagnostics.record("点按服务状态 (services=\(trafficStore.services.count) 个, 出站=\(proxyStore.selectedOutbound ?? "无"), VPN=\(tunnelManager.isRunning ? "开" : "关"))")
                MainThreadWatchdog.noteAction("statsDestination set to .services")
                statsDestination = .services
                ServiceSheetDiagnostics.record("服务状态 overlay 目标已置 .services")
            }
        )
    }

    // MARK: - Subscription card

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.callout.weight(.semibold))
                Text("dashboard.card.profile".l10n)
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
                        .accessibilityLabel("dashboard.profile.updateSubscription".l10n)
                    }
                }
                Button { openProfileCard() } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Text(profileStore.activeProfile?.name ?? "dashboard.profile.noSelection".l10n)
                    .font(.system(size: 18))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                // FlClash profiles.dart: the swap button shows only
                // when more than one profile exists. v0.2.146
                // (D-34): it opens the picker sheet, not the
                // Profiles tab.
                if profileStore.profiles.count > 1 {
                    Button { openProfilesPicker() } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.footnote)
                            .foregroundStyle(Color(.label))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("dashboard.profile.switchSubscription".l10n)
                }
            }
            HStack {
                Text("\("common.updatedAt".l10n) \(updatedText)")
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
            if subscription != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text(usedPercentText)
                        .font(.system(size: statNumberSize, weight: .bold))
                    Text("dashboard.profile.used".l10n)
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
            } else {
                // v0.2.146 (D-33): upstream profiles.dart
                // _ConfigStats — with no subscription info the card
                // shows the config counts (groups / proxies /
                // rules) instead of an empty usage block. The
                // counts use the detail sheet's exact expressions
                // (DashboardSheets.swift:890-906); "—" when the
                // source is empty.
                HStack(spacing: 24) {
                    configStatCell(label: "策略组", value: proxyStore.groups.count)
                    configStatCell(label: "代理", value: Set(proxyStore.allNodes.map { $0.name }).count)
                    configStatCell(label: "规则", value: ruleStore.rules.count)
                }
            }
        }
        .concordCard()
        // v0.2.145: tapping the card opens the profile-detail
        // sheet (upstream profiles.dart:53 showProfileDetailSheet),
        // with the stats, subscription and providers sliver — the
        // MuYu rule-providers sheet it replaces showed rule
        // providers only. v0.2.146 (D-32): a null profile opens
        // the picker sheet instead — see openProfileCard.
        .contentShape(Rectangle())
        .onTapGesture { openProfileCard() }
    }

    /// v0.2.146 (D-32): upstream profiles.dart _openProfile — a
    /// null profile opens the picker sheet; a profile opens its
    /// detail sheet. The card tap and the chevron both use it.
    private func openProfileCard() {
        if profileStore.activeProfile == nil {
            openProfilesPicker()
        } else {
            showProfileDetailSheet = true
        }
    }

    /// Opens the profile picker sheet (D-32/D-34): the swap button
    /// and the no-profile card tap. Records the current active id
    /// so the onChange dismisses the sheet only on a real switch.
    private func openProfilesPicker() {
        pickerProfileId = profileStore.activeProfile?.id
        showProfilesPicker = true
    }

    /// One _ConfigStats cell (D-33): bold count over a secondary
    /// label, the dashboard's stat-cell language.
    private func configStatCell(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value > 0 ? "\(value)" : "—")
                .font(.system(size: statNumberSize, weight: .bold))
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
                    Text("dashboard.card.groups".l10n)
                        .font(.caption.weight(.semibold))
                    if timeoutCount > 0 {
                        PillBadge(text: String(format: "dashboard.stats.timeoutCount".l10n, "\(timeoutCount)"), tint: .orange)
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
                    Text("dashboard.groups.unit".l10n)
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
            Text(proxyStore.isRunning ? "dashboard.groups.empty".l10n : "dashboard.groups.coreNotRunning".l10n)
                .font(.subheadline.weight(.semibold))
            if !proxyStore.isRunning {
                Text("dashboard.groups.startHint".l10n)
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
                statCell(value: dashboardCount(connectionStore.connections.count), label: "dashboard.stats.live".l10n, destination: .live)
                // v0.2.146 (D-39): the unbounded opened-connection
                // total since core setup (upstream
                // requestCountProvider), not the 200-capped
                // recentConnections the sheet renders. A leaf, so
                // the 1 s tick re-renders only this cell.
                TotalRequestStatCell(statNumberSize: statNumberSize, statsDestination: $statsDestination)
                statCell(value: dashboardCount(dnsStore.entries.count), label: "dashboard.stats.dns".l10n, destination: .dns)
            }
        }
        .concordCard()
    }

    /// D-M6: a stat cell opens its source page — live/recent
    /// connections, or the DNS queries page for the DNS cell.
    /// v0.2.64: the contentShape makes the full cell column
    /// tappable, not just the number/label glyphs.
    private func statCell(value: String, label: String, destination: StatsDestination) -> some View {
        Button {
            // v0.2.111: the DNS publish suspension is now real —
            // ContentView sets it on DnsStore when this becomes
            // .dns (setPublishSuspended), and refresh() defers the
            // publish at publish time, so even a refresh already
            // in flight when the user taps cannot land
            // mid-presentation. Note the action for the watchdog.
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

}

/// Shared grouped-digits formatter for dashboardCount below
/// 100k: NumberFormatter setup is expensive, so one instance
/// serves every render (main thread only — all callers are
/// view code). File scope (v0.2.146): TotalRequestStatCell is a
/// leaf outside DashboardView and needs the same formatter.
private let groupedCountFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US")
    return formatter
}()

/// FlClash style.dart dashboardCount: grouped digits below
/// 100k, compact form at/above (123K, 1.5M). File scope
/// (v0.2.146): TotalRequestStatCell is a leaf outside
/// DashboardView.
private func dashboardCount(_ count: Int) -> String {
    if count < 100_000 {
        return groupedCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
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

/// The "最近请求" stat cell (v0.2.146, D-39): a TrafficStore leaf,
/// so the 1 s tick re-renders only this cell — the dashboard body
/// must not read trafficStore directly (v0.2.69 leaf rule). The
/// count is the unbounded opened-connection total since core
/// setup (TrafficStore.totalRequestCount), NOT the 200-capped
/// recentConnections the sheet renders — upstream's
/// requestCountProvider is cumulative too. Tapping opens the
/// recent-connections sheet, like before.
private struct TotalRequestStatCell: View {
    @EnvironmentObject private var trafficStore: TrafficStore

    let statNumberSize: CGFloat
    @Binding var statsDestination: StatsDestination?

    var body: some View {
        Button {
            MainThreadWatchdog.noteAction("statsDestination set to .recent")
            statsDestination = .recent
        } label: {
            VStack(spacing: 4) {
                Text(dashboardCount(trafficStore.totalRequestCount))
                    .font(.system(size: statNumberSize, weight: .bold))
                Text("dashboard.stats.recent".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A dashboard stat cell's destination sheet (D-M6).
/// v0.2.111: internal, not private — ContentView owns the state
/// and presents the .dns destination as a root overlay.
enum StatsDestination: String, Identifiable {
    case live, recent, dns, services

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
        .accessibilityLabel("dashboard.outbound.recheckIp".l10n)
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
    case status, speed, traffic, mode, vpn, intranet, services, profile, groups, stats, memory

    /// v0.2.146 (D-1/D-2): the default order follows upstream
    /// FlClash v0.9.5-rs.1 mobile default — status, speed, mode,
    /// vpn, intranet, services, profiles, groups, stats — with
    /// traffic kept in its MuYu position (below 配置， above
    /// 内存信息） and memory last. The update card is deleted
    /// (D-46); a saved order containing "update" is repaired by
    /// orderedCards dropping unknown ids. A saved custom order
    /// is untouched by this: it only sets the default for
    /// installs that never reordered.
    static let defaultOrder: [DashboardCardID] = [
        .status, .speed, .mode, .vpn, .intranet, .services,
        .profile, .groups, .stats, .traffic, .memory,
    ]

    var title: String {
        switch self {
        case .status: return "dashboard.status.title".l10n
        case .speed: return "dashboard.card.speed".l10n
        case .traffic: return "dashboard.card.traffic".l10n
        case .mode: return "dashboard.card.mode".l10n
        case .vpn: return "VPN"
        case .intranet: return "局域网 IP"
        case .services: return "dashboard.card.services".l10n
        case .profile: return "dashboard.card.profile".l10n
        case .groups: return "dashboard.card.groups".l10n
        case .stats: return "dashboard.stats.title".l10n
        case .memory: return "dashboard.card.memoryTitle".l10n
        }
    }
}

/// Three-segment memory bar (v0.2.146, D-42 — FlClash
/// _MemoryBar / MuYu MemorySnapshot): app share in accent, core
/// share in the series2 tone (accent 45% over the card), and the
/// extension-process share in series3 (tertiary 45% over the
/// card), on a soft track. The extension leg is zero (and its
/// legend row hidden) whenever the tunnel is down.
private struct MemoryBar: View {
    let appBytes: UInt64
    let coreBytes: UInt64
    let extensionBytes: UInt64

    var body: some View {
        GeometryReader { geo in
            let total = max(1, appBytes + coreBytes + extensionBytes)
            let appWidth = geo.size.width * CGFloat(appBytes) / CGFloat(total)
            let coreWidth = geo.size.width * CGFloat(coreBytes) / CGFloat(total)
            ZStack(alignment: .leading) {
                Capsule().fill(ConcordTheme.softFill)
                HStack(spacing: 2) {
                    Capsule().fill(ConcordTheme.accent).frame(width: max(0, appWidth - 1))
                    Capsule().fill(ConcordTheme.accent.opacity(0.45)).frame(width: max(0, coreWidth - 1))
                    Capsule().fill(ConcordTheme.series3).frame(width: max(0, geo.size.width - appWidth - coreWidth - 1))
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
            .accessibilityLabel("dashboard.services.faults".l10n)
            .alert("dashboard.services.faults".l10n, isPresented: $showFaultsAlert) {
                Button("common.okay".l10n, role: .cancel) {}
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
        case "mixed": name = "dashboard.ports.mixed".l10n
        case "http": name = "dashboard.ports.http".l10n
        case "socks": name = "dashboard.ports.socks".l10n
        case "redir": name = "dashboard.ports.redir".l10n
        case "tproxy": name = "dashboard.ports.tproxy".l10n
        case "tun": name = "dashboard.ports.tun".l10n
        case "dns": name = "dashboard.ports.dns".l10n
        default: name = "dashboard.ports.other".l10n
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
        case "address_in_use": return "dashboard.ports.addressInUse".l10n
        case "address_not_available": return "dashboard.ports.addressNotAvailable".l10n
        case "permission_denied": return "dashboard.ports.permissionDenied".l10n
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
/// Live-status pill (v0.2.146, D-51 — upstream live_status.dart
/// LiveStatusButton): the title row's single entry into the
/// live-status deck (core / update / MITM consent / warnings).
/// No statuses → hidden... except only-the-core-running, which
/// shrinks to a small green check button (the deck would hold
/// only the core card). Otherwise the pill wears the most
/// important status (core stopped/starting > update > MITM >
/// warnings) with its tint, plus the count when more than one
/// status is present (the warnings count when warnings are the
/// only status, else the icon alone). Tapping opens the deck
/// sheet; the MITM action dismisses the deck first, then starts
/// the consent review after a short delay (sheet-dismiss /
/// animation safety).
private struct DashboardLiveStatusPill: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore

    @AppStorage("ConcordiOS.update.lastIsNew") private var lastUpdateIsNew = false
    @AppStorage("ConcordiOS.update.lastMessage") private var lastUpdateMessage = ""

    let isCheckingUpdate: Bool
    let onStartCore: () -> Void
    let onRestartCore: () -> Void
    let onReviewMitm: () -> Void
    let onOpenReleases: () -> Void
    let onCheckUpdate: () -> Void

    @State private var showDeck = false

    private var corePhase: LiveStatusDeck.CorePhase {
        switch tunnelManager.status {
        case .connected: return .running
        case .connecting, .reasserting: return .starting
        default: return .stopped
        }
    }

    private var hasCoreStatus: Bool { corePhase != .running }
    private var hasUpdateStatus: Bool { lastUpdateIsNew || isCheckingUpdate }
    private var mitmPending: [String] { mitmModuleStore.modulesAwaitingConsent.map { $0.name } }
    private var hasMitmStatus: Bool { !mitmPending.isEmpty }
    private var hasWarningsStatus: Bool { !trafficStore.lastWarnings.isEmpty }

    private var statusCount: Int {
        (hasCoreStatus ? 1 : 0) + (hasUpdateStatus ? 1 : 0) + (hasMitmStatus ? 1 : 0) + (hasWarningsStatus ? 1 : 0)
    }

    /// The top status (upstream order): core first, then update,
    /// MITM, warnings.
    private var topStatus: (icon: String, tint: Color)? {
        if hasCoreStatus {
            return corePhase == .starting
                ? ("arrow.triangle.2.circlepath", .blue)
                : ("power", .secondary)
        }
        if hasUpdateStatus { return ("arrow.down.circle.fill", .blue) }
        if hasMitmStatus { return ("shield.fill", .purple) }
        if hasWarningsStatus { return ("exclamationmark.triangle.fill", .orange) }
        return nil
    }

    var body: some View {
        if statusCount == 0 {
            // Only the core running: the small green check button.
            Button { showDeck = true } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("实时状态")
            .sheet(isPresented: $showDeck) { deckSheet }
        } else if let top = topStatus {
            Button { showDeck = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: top.icon)
                        .font(.system(size: 13, weight: .semibold))
                    // The count when more than one status is
                    // present; the warnings count when warnings are
                    // the only status; otherwise the icon alone.
                    if statusCount > 1 {
                        Text("\(statusCount)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    } else if hasWarningsStatus {
                        Text("\(trafficStore.lastWarnings.count)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(top.tint.opacity(0.14), in: Capsule())
                .foregroundStyle(top.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("实时状态")
            .sheet(isPresented: $showDeck) { deckSheet }
        }
    }

    private var deckSheet: some View {
        NavigationStack {
            LiveStatusDeck(
                corePhase: corePhase,
                coreError: tunnelManager.lastError,
                warnings: trafficStore.lastWarnings,
                update: hasUpdateStatus ? LiveStatusUpdateInfo(
                    isNew: lastUpdateIsNew,
                    isChecking: isCheckingUpdate,
                    message: lastUpdateMessage.isEmpty ? nil : lastUpdateMessage
                ) : nil,
                mitmPending: mitmPending,
                onStartCore: onStartCore,
                onRestartCore: { showDeck = false; onRestartCore() },
                onReviewMitm: {
                    showDeck = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        onReviewMitm()
                    }
                },
                onOpenReleases: onOpenReleases,
                onCheckUpdate: onCheckUpdate
            )
            .navigationTitle("实时状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDeck = false } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.5625), .fraction(0.9)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(ConcordTheme.pageBackground)
        .presentationCornerRadius(28)
    }
}

/// IP to show in the status card and the IP sheets (audit D10):
/// ONLY the core's own probe.outboundIp result — it measures the
/// egress through the selected proxy. There is no HTTP fallback
/// anymore (v0.2.115): the direct ip-api.com / ident.me / ipify
/// chain is deleted, so the card can never show the phone's
/// direct IP as the egress. TrafficStore.probe() runs when the
/// tunnel connects (see DashboardTrafficEffects) and refreshes
/// when the route changes; ip-api.com is only the geo/org
/// enrichment for the probed IP (fetchIPInfo). The core IP is
/// used whenever present, tunnel up or down — with the VPN off
/// the in-app core still probes the egress through the selected
/// outbound, so it IS the outbound IP then too (MuYu shows it
/// with the tunnel down).
private func dashboardDisplayIp(coreIp: String?) -> String? {
    guard let coreIp = coreIp?.trimmingCharacters(in: .whitespacesAndNewlines),
          !coreIp.isEmpty else {
        return nil
    }
    return coreIp
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
/// the .task it replaces. The closures it receives touch
/// DashboardView's own @State; fetchIPInfo reads
/// TrafficStore.outboundIp, but only inside Tasks, which does not
/// subscribe the parent (v0.2.115: the parent's own subscription
/// comes from its status-card reads — see the header comment).
private struct DashboardTrafficEffects: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var client: ConcordClient

    @Binding var tunnelStartedAt: Date?
    /// v0.2.118 (Job 6): when the app observed the current tunnel
    /// run start — see the DashboardView state comment. Written on
    /// the running=false→true transition, cleared on stop.
    @Binding var tunnelStartObservedAt: Date?
    /// v0.2.128 item 6: the startupId of the tunnel run the
    /// uptime belongs to — see the DashboardView state comment.
    /// Deliberately not cleared on stop (a flap keeps the same
    /// run id, so the correction below can match the file's
    /// record to this run).
    @Binding var tunnelStartupId: String?
    @Binding var morphProgress: CGFloat
    @Binding var ipInfo: IPQualityInfo?
    @Binding var ipAsn: String?
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
                    // v0.2.118 (Job 6): gated to this run's record
                    // (notBefore:) — an ungated read here could pick
                    // up the previous run's startedAt.
                    tunnelStartedAt = tunnelManager.readTunnelStartedAt(notBefore: tunnelStartObservedAt) ?? Date()
                }
                // v0.2.56: the traffic card's cumulative uptime counts
                // the live session from its start (the extension's
                // start time, so it survives an app restart).
                if proxyStore.isRunning, let started = tunnelStartedAt {
                    await trafficStore.noteTunnelStarted(at: started)
                }
                tunnelManager.checkTunRestartNeeded()
                // v0.2.115: the stats row (实时连接/最近请求/DNS查询）
                // refreshes CONCURRENTLY with the IP lookup, in its
                // own Task — it used to run after fetchIPInfo (up to
                // 26 s), so the three numbers sat at 0 on launch.
                // The refreshes now read the in-app core's live
                // feeds when the tunnel is down (ConnectionStore /
                // EventStore fall back to AppCore like DnsStore), so
                // the row fills as soon as the core is up, like
                // MuYu's startCore + _openFeeds at launch. The core
                // boot is driven by the first store refresh (runX
                // calls ensureStarted when the core is not running
                // yet). Unstructured on purpose: nothing later in
                // this sequence depends on the stats, and the
                // stores serialize on the MainActor anyway.
                // v0.2.89: the row refreshes on entry, like
                // pull-to-refresh — it used to show the previous
                // session's values (or zeros) until the user
                // pulled. With the VPN on (or just stopped) the
                // fresh snapshots fill the row at once.
                Task {
                    await connectionStore.refresh()
                    await eventStore.refresh()
                    // v0.2.101 issue 2 / v0.2.111: skip the DNS
                    // refresh while a stats sheet is open — a
                    // publish landing mid-presentation is a freeze
                    // suspect. This gate is only an optimisation
                    // now; the authoritative guard is DnsStore's
                    // publish suspension (setPublishSuspended,
                    // checked at publish time inside refresh()).
                    if statsDestination == nil {
                        await dnsStore.refresh()
                    }
                    // v0.2.115 (status card): probe the egress IP
                    // through the in-app core (TrafficStore.probe
                    // falls back to AppCore with the tunnel down)
                    // and fetch its geo — the status card fills on
                    // launch like MuYu, instead of waiting on the
                    // slow direct lookup. fetchIPInfo prefers the
                    // core-probed IP for the geo query, so it runs
                    // AFTER the probe here; the main sequence no
                    // longer calls it (the in-flight guard would
                    // dedup a concurrent call anyway).
                    await trafficActions.probe()
                    await fetchIPInfo()
                }
                await trafficStore.refreshEngineStatus()
                await refreshSubscription()
                // v0.2.89: probe on entry even with the VPN off, like
                // MuYu — the old `client.mode == .sample ||
                // tunnelManager.isRunning` gate skipped the probe in
                // live mode with the VPN off, so the services card
                // showed stale values. The probe itself now routes
                // through the in-app core when the tunnel is down
                // (TrafficStore.probeServices), so no gate is needed
                // here.
                // v0.2.124 (services=0): the probe used to gate on
                // selectedOutbound != nil, and this user never
                // picked a node (出站=无), so it never ran and
                // services stayed empty forever. DIRECT is the
                // core's own default probe proxy (upstream
                // probe/testing.rs: None => "DIRECT") — the route
                // the traffic actually takes with nothing selected.
                if trafficStore.services.isEmpty {
                    await trafficStore.serviceProbeStore.probeAll(proxy: proxyStore.selectedOutbound ?? "DIRECT")
                }
            }
            // v0.2.121: keep the 最近请求 stat live — ConnectionStore
            // .refresh() used to run only on appear / pull-to-refresh
            // / while the Requests sheet was open, so the Dashboard
            // number froze at its appear-time count while connections
            // kept finishing (and the sheet's appear-refresh backfill
            // then showed more rows than the stat). Poll every second
            // like ConnectionsView's own poll, so the stat and the
            // sheet read the same up-to-date collection. Gated like
            // that poll: skip while neither the tunnel nor the in-app
            // core is running (refresh() would boot the core, but
            // there is nothing to snapshot yet).
            // v0.2.122: the DNS stat had the identical appear-time
            // freeze — dnsStore.refresh() ran once on appear (before
            // any resolution had accumulated in the fresh session's
            // dns.watch buffer, so a fresh launch read 0) and
            // nothing re-read it afterwards, so the Dashboard showed
            // 0 and the sheet "暂无 DNS 查询记录" even as the core
            // kept resolving (00:11 VPN-on test). Poll it here too.
            // The v0.2.111 publish suspension still defers the
            // publish while the DNS sheet is open, so the freeze
            // guard is unaffected.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    guard TunnelManager.shared.isRunning || AppCore.shared.isRunning else { continue }
                    // v0.2.129: correct the uptime FIRST. The two
                    // refresh() calls below travel over the
                    // app<->extension RPC, which is dead (XPC
                    // delivery fails), so a hung transport call must
                    // never stall this loop and freeze uptime/speed/
                    // services — v0.2.132 runs them fire-and-forget
                    // for exactly that reason. Uptime must not wait
                    // on the refreshes.
                    correctUptimeFromFile()
                    guard !Task.isCancelled else { break }
                    // v0.2.132: the refreshes run in their own tasks
                    // and this loop NEVER awaits them. v0.2.129 put
                    // each refresh in a withTaskGroup child with a
                    // 5 s sleep racing it — but withTaskGroup waits
                    // for ALL children before its scope exits, and
                    // cancelAll only requests cancellation, so a
                    // refresh hung on the dead app<->extension RPC
                    // still parked this loop (and the uptime
                    // correction above) for the RPC's whole 10–60 s
                    // timeout. A hung refresh now lives out its own
                    // timeout in the background while this loop keeps
                    // ticking every second; the stores serialize on
                    // the MainActor and each refresh is a read, so
                    // overlapping runs are harmless.
                    Task { await connectionStore.refresh() }
                    Task { await dnsStore.refresh() }
                    // v0.2.146 (D-39): feed the unbounded request
                    // counter from the last refreshed snapshot —
                    // the refreshes above are fire-and-forget
                    // (never awaited, see v0.2.132), so the counter
                    // reads the lists as they stand and picks new
                    // ids up on the next tick, at most one second
                    // behind. Ids that left both lists are dropped
                    // from the seen set, so it stays bounded.
                    // Awaited (not called direct): noteSeen is a
                    // @MainActor function and this loop must not
                    // assume its own isolation.
                    await trafficStore.noteSeenConnectionIds(
                        live: connectionStore.connections.map { $0.id },
                        recent: connectionStore.recentConnections.map { $0.id }
                    )
                }
            }
            .onChange(of: proxyStore.isRunning) { _, running in
                // v0.2.118 (Job 6): on a (re)start, reset the uptime
                // to now IMMEDIATELY and do not read the diagnostics
                // file here at all — it can still hold the previous
                // run's startedAt (fresh within its 180 s window),
                // which is what showed the old ~2 min uptime instead
                // of 0 on v0.2.117 (the old `tunnelStartedAt ?? ...`
                // also kept any value picked up earlier). The
                // transition time is recorded so later reads
                // (refreshAll, appear) only accept a file record
                // from THIS run (readTunnelStartedAt notBefore:);
                // the extension's own start time then corrects the
                // ~1 s observation lag. D4 is kept for the
                // no-transition case (tunnel already up at launch):
                // tunnelStartObservedAt stays nil and the file is
                // accepted as before.
                if running {
                    tunnelStartObservedAt = Date()
                    tunnelStartedAt = Date()
                    // v0.2.146 (D-39): upstream resets the request
                    // count on setup — a new tunnel run starts the
                    // count at 0.
                    Task { await trafficStore.resetRequestCount() }
                } else {
                    tunnelStartObservedAt = nil
                    tunnelStartedAt = nil
                }
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
                        // v0.2.124: DIRECT fallback (see the
                        // appear auto-check above) — with no node
                        // selected the probe would otherwise never
                        // run and services would stay empty.
                        await trafficStore.serviceProbeStore.probeAll(proxy: proxyStore.selectedOutbound ?? "DIRECT")
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
                // stale probe result so the card shows the loading
                // skeletons (FlClash re-probes on start), then re-fetch
                // so the status card shows the current proxy egress IP.
                // v0.2.115: clear the probe FIRST — the core probe
                // re-runs for the new egress (upstream refreshes the
                // probe when the route changes) and the geo
                // enrichment follows the fresh probed IP.
                if running {
                    trafficStore.clearOutboundIp()
                    ipInfo = nil
                    ipAsn = nil
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

    /// v0.2.128 item 6: corrects the uptime from the extension's
    /// diagnostics file. The running=false→true transition sets
    /// tunnelStartedAt to Date() (the app-observed time), which is
    /// ~1 s late and resets to 0 on every isRunning flap (a brief
    /// disconnect/reconnect) — the 00:00:16 → 00:00:09 → 00:00:01
    /// jumps in the video. The file's startedAt is the TRUE start
    /// time (set once by the extension, never moves). This adopts
    /// it when it is EARLIER than the app-observed value (a flap
    /// reset or the observation lag) — never later (a later value
    /// would shrink the uptime). The startupId disambiguates a
    /// stale previous-run record from the current run's, closing
    /// the residual 30 s edge the v0.2.118 comment noted: a record
    /// from a DIFFERENT run is adopted outright (the tunnel
    /// genuinely restarted), while a same-run record is only
    /// adopted when earlier.
    private func correctUptimeFromFile() {
        guard proxyStore.isRunning, let current = tunnelStartedAt else { return }
        guard let run = tunnelManager.readTunnelRun(notBefore: tunnelStartObservedAt) else { return }
        // A record from a DIFFERENT run (the extension restarted
        // without the app observing a transition): adopt it
        // outright — the tunnel genuinely restarted, so the uptime
        // resets to the new run's start.
        if let currentId = tunnelStartupId,
           let runId = run.startupId, runId != currentId {
            tunnelStartupId = runId
            tunnelStartedAt = run.startedAt
            return
        }
        // Same run (or no id to match): the file's startedAt is the
        // TRUE start. Adopt it when EARLIER than the app-observed
        // value. Record the run id so a later restart is recognised
        // as a different run.
        tunnelStartupId = run.startupId ?? tunnelStartupId
        if run.startedAt < current {
            tunnelStartedAt = run.startedAt
        }
    }
}

/// IP slot (FlClash _ExitRow): a pulsing skeleton while the probe
/// has not answered, the real IP once it has, "检测失败" (red)
/// if the probe failed. Reads TrafficStore directly, so this slot
/// — not the status card — re-renders when the probe lands.
/// v0.2.115: the IP comes ONLY from the core probe
/// (dashboardDisplayIp has no fallback anymore) and the red
/// failure is driven by the PROBE failure
/// (trafficStore.outboundIpProbeFailed), not the old HTTP chain.
/// Shows the IP whenever it is known, tunnel up or down — MuYu
/// shows the egress IP with the tunnel down (the in-app core
/// probes it at launch). The skeleton is only the transient
/// pre-probe state now.
private struct StatusIpSlotView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var settingsStore: SettingsStore

    /// v0.2.119 (Fix 1): the failure state grows to fit the
    /// one-line recorded reason under the red error; the
    /// success / loading states keep the 30 pt slot.
    /// v0.2.124: settled failure only (see
    /// outboundIpFailureSettled) — the first probe on entry fails
    /// fast while the core session is still starting, and a bare
    /// probeFailed here flashed "检测失败" for ~1 s before the
    /// retry landed the IP. While retries are still running, the
    /// skeleton below shows instead.
    private var isFailed: Bool {
        trafficStore.outboundIp == nil && trafficStore.outboundIpFailureSettled
    }

    var body: some View {
        Group {
            if let ip = dashboardDisplayIp(coreIp: trafficStore.outboundIp) {
                // FlClash _IpText: hideIp masks the IP as "*****
                // (current_outbound.dart _ipMask).
                // v0.2.68: 24pt bold, like the video (was 18pt semibold).
                Text(settingsStore.hideIp ? "*****" : ip)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if isFailed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("dashboard.outbound.probeFailed".l10n)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    // v0.2.119 (Fix 1): the recorded reason was
                    // invisible in the UI — one secondary line
                    // under the error, the last diagnostics line
                    // (e.g. the core's error or the RPC timeout),
                    // so a failed probe ships its cause.
                    if let reason = IPLookupDiagnostics.lastDiagnosticLine() {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                SkeletonBar(width: 140, height: 18, animated: true)
            }
        }
        .frame(height: isFailed ? 48 : 30, alignment: .leading)
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

    var body: some View {
        let bytes = isUp ? trafficStore.current.up : trafficStore.current.down
        let total = isUp ? trafficStore.current.totalUp : trafficStore.current.totalDown
        let split = ConcordBytes.split(bytes)
        // v0.2.146 (D-18): upstream series2 — upload is the
        // primary at 45% in EVERY theme, default blue included.
        // Both rs.1 and MuYu traffic.dart use series2 for upload
        // (TrafficDirection.colorOf); the old orange-under-
        // default-blue cited the MuYu video, but the code wins
        // over the comment. The waveform itself applies its own
        // opacity on top, so 45% here renders upload at 45% of
        // download's strength, matching upstream.
        let uploadColor = ConcordTheme.accent.opacity(0.45)
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
                    Text(isUp ? "dashboard.traffic.upload".l10n : "dashboard.traffic.download".l10n)
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
                // Reference shows "累计 0 B" (no ".0"): ConcordFormat
                // formats 0 as "0.0 B", so special-case zero locally
                // (the shared formatter is used elsewhere and stays).
                Text("\("dashboard.traffic.totalPrefix".l10n) \(total == 0 ? "0 B" : ConcordFormat.bytes(total))")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
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
                CardTitleRow(icon: "chart.pie", title: "dashboard.card.traffic".l10n)
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
                        trafficSplitRow(dot: ConcordTheme.accent, label: "dashboard.traffic.proxy".l10n, value: dashboardBytesNoSpace(today.proxyBytes))
                        trafficSplitRow(dot: ConcordTheme.accent.opacity(0.45), label: "common.direct".l10n, value: dashboardBytesNoSpace(today.directBytes))
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
                    Text("\("dashboard.traffic.uptimePrefix".l10n) \(trafficStore.todayUptimeText)")
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

/// Service status card (summary only): the title + verdict badge
/// and the whole card open the 服务状态 bottom sheet (MuYu
/// key_7), like DNS 查询 — v0.2.130 removed the chevron's inline
/// expand (the full service list + 检测/全部检测/管理服务 +
/// engine / TUN / DNS details lived inline on the Dashboard;
/// video f_020). The list and buttons already live in the bottom
/// sheet (ServiceStatusSheet); the engine / TUN / DNS rows are
/// dropped — the tunnel state is on the VPN card, engine faults
/// have their own badge, and TUN / DNS are settings. Its data
/// changes on probe, not every second — but any read in
/// DashboardView would subscribe that view to the store and
/// re-render the dashboard on the 1 s tick, so the whole card
/// lives here.
/// The device's LAN IPv4 address (v0.2.146, D-45, upstream
/// lib/utils/network.dart): prefer the Wi-Fi interface (en0)
/// IPv4, else any up non-loopback interface's IPv4, else "" (no
/// network). nil means not read yet — the card skeletons while
/// loading, shows "无网络" for "", and the raw IP otherwise.
/// getifaddrs is the only way to read the address in-app; there
/// is no NetworkExtension or core API for it.
private func readLocalIPv4Address() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
    defer { freeifaddrs(ifaddr) }
    var fallback: String?
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let iface = current {
        defer { current = iface.pointee.ifa_next }
        guard let addr = iface.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = iface.pointee.ifa_flags
        // Up + running, not loopback.
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
        guard result == 0 else { continue }
        let ip = String(cString: host)
        let name = String(cString: iface.pointee.ifa_name)
        if name == "en0" { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback ?? ""
}

/// Intranet IP card (v0.2.146, D-45, upstream
/// intranet_ip.dart): header (devices glyph + title + copy
/// button, disabled with no address), figure (120-wide skeleton
/// while loading / "无网络" grey text when "" / the raw IP), and
/// the switch row (wifi glyph, "允许局域网", subtitle = port or
/// "已停用", toggle). The copy value is `ip:port` when allow-LAN
/// is on, the bare IP otherwise; the figure always shows the raw
/// IP. The address is re-read on appear and on foregrounding —
/// the interface changes when the phone joins/leaves Wi-Fi.
private struct IntranetIpCardView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    let bigNumberSize: CGFloat

    @State private var localIp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitleRow(icon: "network", title: "局域网 IP")
                Spacer()
                Button {
                    if let text = copyText {
                        UIPasteboard.general.string = text
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(copyText == nil)
            }
            if let ip = localIp {
                if ip.isEmpty {
                    Text("无网络")
                        .font(.system(size: bigNumberSize, weight: .bold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(ip)
                        .font(.system(size: bigNumberSize, weight: .bold))
                        .lineLimit(1)
                }
            } else {
                SkeletonBar(width: 120, height: 25, animated: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许局域网")
                        .font(.subheadline.weight(.semibold))
                    Text(settingsStore.allowLan ? "端口 \(settingsStore.mixedPort)" : "已停用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settingsStore.allowLan },
                    set: { newValue in
                        settingsStore.allowLan = newValue
                        settingsStore.save()
                        Task { await settingsStore.applyGeneralToCore() }
                    }
                ))
                .labelsHidden()
            }
        }
        .concordCard()
        .task { refreshIp() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshIp()
        }
    }

    private var copyText: String? {
        guard let ip = localIp, !ip.isEmpty else { return nil }
        return settingsStore.allowLan ? "\(ip):\(settingsStore.mixedPort)" : ip
    }

    private func refreshIp() {
        localIp = readLocalIPv4Address()
    }
}

private struct ServicesCardView: View {
    @EnvironmentObject private var trafficStore: TrafficStore

    let onOpenServiceSheet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // v0.2.56: the title + badge open the 服务状态
                // sheet (MuYu key_7). v0.2.130: the chevron no
                // longer expands inline — it is just the "opens a
                // sheet" indicator, like the other cards.
                Button { onOpenServiceSheet() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.callout.weight(.semibold))
                        Text("dashboard.card.services".l10n)
                            .font(.caption.weight(.semibold))
                        if let badge = serviceBadge {
                            PillBadge(text: badge.text, tint: badge.tint)
                        }
                    }
                    .foregroundStyle(Color(.label))
                }
                .buttonStyle(.plain)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
                Text("dashboard.services.pausedNote".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
        // v0.2.64: the whole card opens the 服务状态 sheet —
        // tapping anywhere on the card shows the drawer, not
        // just the title/chevron.
        .contentShape(Rectangle())
        .onTapGesture { onOpenServiceSheet() }
    }

    private func service(named name: String) -> ConcordServiceItem? {
        trafficStore.services.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Service-status verdict (FlClash service_status.dart:184-195
    /// — problems = services where abnormal, i.e. status !=
    /// available; chip is "N 项异常" warn / "全部可用" ok). The
    /// verdict covers ONLY the shown services (the first two
    /// enabled names): a shown service with no probe item — e.g.
    /// enabled in the manage sheet after the last probe — used to
    /// read as available while the badge counted abnormal over
    /// ALL services, so the two could contradict each other. The
    /// verdict is null while any shown service is unchecked (no
    /// item, or the pre-start results are held — held reads as
    /// still-checking per upstream probe_start_hold), so the chip
    /// hides instead of claiming a verdict nobody has.
    private var serviceBadge: (text: String, tint: Color)? {
        let shown = Array(trafficStore.enabledServiceNames.prefix(2))
        guard !shown.isEmpty else { return nil }
        let items = shown.map { service(named: $0) }
        if trafficStore.servicesHeld || items.contains(where: { $0 == nil }) { return nil }
        let abnormal = items.compactMap { $0 }.filter { $0.status != "available" }.count
        if abnormal == 0 { return ("dashboard.services.allOk".l10n, .green) }
        return (String(format: "dashboard.services.abnormalCount".l10n, "\(abnormal)"), .orange)
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
                // Status dot in the status colour while checked
                // (green only when available); no dot while the
                // service is unchecked.
                if let service, !trafficStore.servicesHeld {
                    Circle()
                        .fill(dashboardServiceStatusColor(service.status))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            // Status text (D-26), not delay only: available with a
            // delay shows the delay, available without one shows
            // "可用", anything else its status label. Unchecked
            // (no item, or held) shows a skeleton while probing,
            // else "—".
            if let service, !trafficStore.servicesHeld {
                if service.status == "available", let delay = service.delay {
                    Text("\(delay) ms")
                        .font(.footnote)
                        .fontWeight(.semibold)
                } else {
                    Text(dashboardServiceStatusLabel(service.status))
                        .font(.footnote)
                        .fontWeight(.semibold)
                }
            } else if trafficStore.isProbingServices {
                SkeletonBar(width: 48, height: 14, animated: true)
            } else {
                Text("—")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
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

    /// v0.2.146 (D-42): the three legs — app RSS (task_info),
    /// the active core's RSS, and the extension process's RSS
    /// (MuYu MemorySnapshot: app / coreTotal / extensionTotal).
    /// VPN-on the core runs in the extension process, so the core
    /// leg is 0 and the extension leg carries the GET /memory
    /// number; VPN-off the in-app core is the core leg (nil →
    /// 0 while it is not running) and there is no extension
    /// process. The total is unchanged in both states — the same
    /// bytes, only split differently.
    private var coreLegBytes: UInt64 {
        proxyStore.isRunning ? 0 : (trafficStore.coreMemoryBytes ?? 0)
    }

    private var extensionLegBytes: UInt64 {
        proxyStore.isRunning ? (trafficStore.extensionMemoryBytes ?? 0) : 0
    }

    private var memoryTotalBytes: UInt64 {
        appMemoryBytes + coreLegBytes + extensionLegBytes
    }

    var body: some View {
        Button { onOpenDetail() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    CardTitleRow(icon: "memorychip", title: "dashboard.card.memoryTitle".l10n)
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
                MemoryBar(appBytes: appMemoryBytes, coreBytes: coreLegBytes, extensionBytes: extensionLegBytes)
                HStack(spacing: 16) {
                    memoryLegend(dot: ConcordTheme.accent, label: "dashboard.memory.app".l10n, bytes: appMemoryBytes)
                    memoryLegend(dot: memoryCoreColor, label: "dashboard.memory.core".l10n, bytes: coreLegBytes)
                    // MuYu shows the extension leg only when it is
                    // > 0 — with the tunnel down there is no
                    // extension process, so no third row.
                    if extensionLegBytes > 0 {
                        memoryLegend(dot: ConcordTheme.series3, label: "扩展", bytes: extensionLegBytes)
                    }
                }
                if !proxyStore.isRunning {
                    Text("dashboard.memory.coreNotRunning".l10n)
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
            extensionBytes: trafficStore.extensionMemoryBytes,
            isReleasing: $isReleasing,
            releaseMessage: $releaseMessage,
            onRelease: {
                do {
                    try await client.coreReleaseMemory()
                    if let bytes = readAppMemoryBytes() {
                        appMemoryBytes = bytes
                    }
                    await trafficStore.refreshMemory()
                    releaseMessage = "dashboard.memory.releaseRequested".l10n
                } catch {
                    releaseMessage = "\("dashboard.memory.releaseFailed".l10n)\(error.localizedDescription)"
                }
            },
            // v0.2.146 (D-43): release is enabled exactly where a
            // route exists. VPN-on the tunnel core answers
            // core.releaseMemory over the existing JSON-RPC route
            // — ConcordClient sends it via
            // TunnelManager.sendProviderMessage and
            // PacketTunnelProvider forwards any method to the core
            // session (only config.apply/delay.run are
            // special-cased), so no core patch was needed and the
            // old gate (disabled while the tunnel runs) was simply
            // inverted. Sample mode keeps its mock answer. VPN-off
            // live stays DISABLED: the in-app core exposes no
            // release RPC (AppCore has probeServices /
            // configGeneral / delayTest only), and the client talks
            // to the tunnel core, not the in-app one — enabling it
            // would need an AppCore change, out of scope here.
            canRelease: TunnelManager.shared.isRunning || client.mode == .sample
        )
        .task {
            if let bytes = readAppMemoryBytes() {
                appMemoryBytes = bytes
            }
        }
    }
}

/// Brand tile from the user's imported icon pack (v0.2.68),
/// then the bundled brands (v0.2.141 — the icons revert restores
/// MuYu's map; the pack wins when both match): IconPackStore
/// matched by service/group name, else a BrandIcons mark, else
/// the letter. Internal so DashboardSheets' service rows can use
/// it too.
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
            } else if let brand = BrandIcons.icon(for: name) {
                BrandIcons.view(for: brand)
            } else {
                Text(fallback)
                    .font(.system(size: fontSize, weight: .bold))
            }
        }
    }
}
