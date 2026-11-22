import SwiftUI
import UIKit

// MARK: - Dashboard (reference screenshots IMG_1082 / IMG_1083)
// Layout, top to bottom: big title + edit button; status card (big
// blue play button); network speed; outbound mode pills; VPN card;
// intranet IP + LAN proxy; service status (probe.services); the
// active subscription card; proxy groups; stats row. The DATA wiring
// is unchanged from the previous dashboard: proxyStore (running +
// groups), trafficStore (speed + services + engine), connectionStore,
// profileStore, ruleStore (provider list for the subscription info),
// settingsStore, eventStore / dnsStore (stats), tunnelManager and
// client. Only the look and the navigation changed.

struct DashboardView: View {
    /// Switches the main tab (called with .proxies / .profiles from
    /// the card chevrons).
    var onSelectTab: (AppTab) -> Void = { _ in }

    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var trafficStore: TrafficStore
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
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("ConcordiOS.dashboard.show.status") private var showStatus = true
    @AppStorage("ConcordiOS.dashboard.show.speed") private var showSpeed = true
    @AppStorage("ConcordiOS.dashboard.show.mode") private var showMode = true
    @AppStorage("ConcordiOS.dashboard.show.vpn") private var showVpn = true
    @AppStorage("ConcordiOS.dashboard.show.intranet") private var showIntranet = true
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

    @State private var showEditSheet = false
    @State private var servicesExpanded = false
    /// IP quality sheet (D-M4): the status card's IP opens the
    /// IP-quality page for that exact IP.
    @State private var showIPQualitySheet = false
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
    @State private var tunnelStartedAt: Date?
    @State private var subscription: ConcordSubscriptionInfo?
    @State private var intranetIp: String?
    @State private var ipInfo: IPQualityInfo?
    @State private var morphProgress: CGFloat = 0
    @State private var ipChecking = false
    @State private var ipFetchFailed = false
    /// The ip-api.com `as` field ("AS15169 Google LLC"), parsed to
    /// the bare "AS<n>" token for the org fallback (FlClash
    /// current_outbound.dart: organization ?? "AS{asn}").
    /// IPQualityInfo maps no `as` key, so it is decoded separately.
    @State private var ipAsn: String?
    /// Intranet card (FlClash intranet_ip.dart): whether the first
    /// local-IP read has finished — nil before that is "not read
    /// yet", nil after it is "无网络".
    @State private var intranetLoaded = false
    @State private var intranetCopied = false
    /// Profile sync spinner (FlClash profiles.dart _SyncButton shows
    /// an activity indicator while the profile is updating).
    @State private var isSyncingProfile = false
    /// Memory card state (FlClash memory_info.dart): the app's own
    /// resident size (task_info) plus the core RSS (core.stats).
    @State private var appMemoryBytes: UInt64 = 0
    @State private var showMemoryDetail = false
    @State private var isReleasingMemory = false
    @State private var memoryReleaseMessage: String?
    /// Update card state (FlClash update_status.dart): reads the
    /// same UpdateChecker the About page uses; the last result is
    /// kept in AppStorage so the card shows something before the
    /// first check of the session.
    @State private var updateCheckResult: UpdateChecker.Result?
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

    private var uptimeText: String {
        guard let started = tunnelStartedAt else { return "—" }
        return ConcordFormat.duration(seconds: max(0, Int64(Date().timeIntervalSince(started))))
    }

    private func service(named name: String) -> ConcordServiceItem? {
        trafficStore.services.first { $0.name.lowercased() == name }
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

    private var groupInitials: [String] {
        proxyStore.nonHiddenGroups.prefix(4).map { group in
            group.name == "github" ? "GH" : String(group.name.prefix(1)).uppercased()
        }
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

    /// The app process's resident size (FlClash reads
    /// ProcessInfo.currentRss on its side; task_info is the iOS
    /// equivalent). The core runs in the extension process, so its
    /// RSS comes from core.stats instead.
    private func readAppMemory() {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            appMemoryBytes = UInt64(info.resident_size)
        }
    }

    private func refreshMemorySnapshot() async {
        readAppMemory()
        await trafficStore.refreshMemory()
    }

    private func checkForUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        if let result = await UpdateChecker.check() {
            updateCheckResult = result
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

    /// Public-IP lookup (same ip-api.com endpoint as IPQualityView).
    /// The lookup runs even while the VPN is off, but the status
    /// card does NOT show the result then: FlClash shows grey
    /// skeleton bars while the core is not running, the real IP
    /// only once it is running. When the VPN is on, URLSession
    /// follows the tunnel, so the answer is the proxy egress IP;
    /// when it is off, it is the phone's direct IP.
    private func fetchIPInfo() async {
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting") else { return }
        ipChecking = true
        defer { ipChecking = false }
        do {
            // Interface B3 (DashboardView part): a stalled ip-api.com
            // used to hang this lookup forever (URLSession.shared
            // defaults: 60 s request / 7 days resource). 10 s, then
            // the card shows "服务失败" instead of hanging.
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { ipFetchFailed = true; return }
            let decoded = try JSONDecoder().decode(IPQualityInfo.self, from: data)
            guard decoded.status == "success" else { ipFetchFailed = true; return }
            ipInfo = decoded
            ipAsn = (try? JSONDecoder().decode(IPApiAsField.self, from: data))?.asNumber
            ipFetchFailed = false
        } catch {
            // No network or API error: keep the previous (or empty)
            // values — the card shows "服务失败" while running, or
            // the skeleton bars while not running, instead of stale
            // numbers.
            ipFetchFailed = true
        }
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
            await trafficStore.noteTunnelStarted(at: extStarted)
        }
        await proxyStore.refresh()
        await connectionStore.refresh()
        await trafficStore.refresh()
        await trafficStore.refreshEngineStatus()
        await eventStore.refresh()
        await dnsStore.refresh()
        await refreshSubscription()
        await fetchIPInfo()
    }

    // MARK: - Body

    var body: some View {
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
                ForEach(orderedCards, id: \.self) { cardView(for: $0) }
                if let error = proxyStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .concordPageBackground()
        .refreshable { await refreshAll() }
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
            intranetIp = DeviceNetwork.localIPv4Address()
            intranetLoaded = true
            await fetchIPInfo()
            await trafficStore.refreshEngineStatus()
            await refreshSubscription()
            if trafficStore.services.isEmpty,
               let proxy = proxyStore.selectedOutbound,
               client.mode == .sample || tunnelManager.isRunning {
                await trafficStore.probeServices(proxy: proxy)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // C11: returning to the foreground while already on the
            // dashboard never re-ran the .task above, so the intranet
            // IP stayed stale after a network change. Re-read it on
            // every return to active (same read as on appear).
            if phase == .active {
                intranetIp = DeviceNetwork.localIPv4Address()
                intranetLoaded = true
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
                Task { await trafficStore.noteTunnelStopped() }
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
                if running {
                    await trafficStore.probe()
                    if let proxy = proxyStore.selectedOutbound,
                       client.mode == .sample || tunnelManager.isRunning {
                        await trafficStore.probeServices(proxy: proxy)
                    }
                }
            }
        }
        .onChange(of: settingsStore.mode) { _, _ in
            Task { await settingsStore.applyGeneralToCore() }
        }
        .sheet(isPresented: $showEditSheet) {
            DashboardEditSheet(
                showStatus: $showStatus,
                showSpeed: $showSpeed,
                showTraffic: $showTraffic,
                showMode: $showMode,
                showVpn: $showVpn,
                showIntranet: $showIntranet,
                showServices: $showServices,
                showProfile: $showProfile,
                showGroups: $showGroups,
                showStats: $showStats,
                showMemory: $showMemory,
                showUpdate: $showUpdate,
                densityCompact: $densityCompact,
                cardOrder: Binding(
                    get: { orderedCards },
                    set: { newOrder in
                        cardOrderString = newOrder.map(\.rawValue).joined(separator: ",")
                    }
                )
            )
        }
        .sheet(isPresented: $showMemoryDetail) {
            MemoryDetailSheet(
                appBytes: appMemoryBytes,
                coreBytes: trafficStore.coreMemoryBytes,
                isReleasing: $isReleasingMemory,
                releaseMessage: $memoryReleaseMessage,
                onRelease: {
                    do {
                        try await client.coreReleaseMemory()
                        await refreshMemorySnapshot()
                        memoryReleaseMessage = "已请求核心释放内存"
                    } catch {
                        memoryReleaseMessage = "释放失败：\(error.localizedDescription)"
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(Color(.systemGroupedBackground))
            .presentationCornerRadius(28)
        }
        // v0.2.56: the traffic card opens the MuYu traffic sheet
        // (日/周/月， date navigator, 流量概括， rankings) — it
        // reads TrafficStore directly, so its figures always
        // match the card's.
        .sheet(isPresented: $showTrafficDetail) {
            TrafficStatsSheet()
                .presentationDetents([.fraction(0.85), .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(.systemGroupedBackground))
                .presentationCornerRadius(28)
        }
        // v0.2.56: the status card opens the 出站 IP sheet
        // (MuYu key_3).
        .sheet(isPresented: $showOutboundIPSheet) {
            OutboundIPSheet(
                displayIp: displayIp,
                hideIp: settingsStore.hideIp,
                assessed: assessedIpInfo,
                ipAsn: ipAsn,
                isChecking: ipChecking,
                fetchFailed: ipFetchFailed,
                onRefresh: {
                    Task {
                        await fetchIPInfo()
                        await trafficStore.probe()
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(Color(.systemGroupedBackground))
            .presentationCornerRadius(28)
        }
        // v0.2.56: the services card opens the 服务状态 sheet
        // (MuYu key_7).
        .sheet(isPresented: $showServiceSheet) {
            ServiceStatusSheet()
                .presentationDetents([.fraction(0.85), .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(.systemGroupedBackground))
                .presentationCornerRadius(28)
        }
        // v0.2.56: the config card opens the rule-providers
        // sheet (MuYu key_25).
        .sheet(isPresented: $showProvidersSheet) {
            ProvidersSheet(profileName: profileStore.activeProfile?.name ?? "配置")
                .presentationDetents([.fraction(0.85), .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(.systemGroupedBackground))
                .presentationCornerRadius(28)
        }
        // D-M6: a stat cell opens its source page — live/recent
        // connections, or the DNS queries page for the DNS cell.
        // These are full pages (search + toolbars), so they keep
        // their NavigationStack; the sheet gets MuYu's drag
        // handle and a leading ✕ instead of the card chrome.
        .sheet(item: $statsDestination) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .live:
                        ConnectionsView(initialFeed: .live)
                            .navigationTitle("连接")
                            .navigationBarTitleDisplayMode(.inline)
                    case .recent:
                        ConnectionsView(initialFeed: .recent)
                            .navigationTitle("连接")
                            .navigationBarTitleDisplayMode(.inline)
                    case .dns:
                        DnsQueriesView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { statsDestination = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("关闭")
                    }
                }
            }
            .presentationDetents([.fraction(0.85), .large])
            .presentationDragIndicator(.visible)
        }
        // D-M4: the status card's IP opens the IP-quality page for
        // that exact IP (upstream showIpQualitySheet is always
        // opened for one IP).
        .sheet(isPresented: $showIPQualitySheet) {
            NavigationStack {
                if let ip = displayIp {
                    IPQualityView(ip: ip)
                } else {
                    IPQualityView()
                }
            }
            .presentationDragIndicator(.visible)
        }
        // D-M3: manage the probe-service targets (order + enabled).
        .sheet(isPresented: $showServiceManageSheet) {
            ServiceManageSheet()
                .presentationDragIndicator(.visible)
        }
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
        case .intranet: if showIntranet { intranetCard }
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
                .font(.system(size: 24, weight: .semibold))
            Spacer()
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
            Button { showEditSheet = true } label: {
                ThickPencilIcon(iconColor: editButtonIconColor, bandColor: editButtonBackground)
                    .frame(width: 44, height: 44)
                    .background(editButtonBackground, in: Circle())
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑仪表盘卡片")
        }
    }

    /// Top-right button state (user request): while the VPN/core is
    /// running the button turns light blue in light mode and dark
    /// blue in dark mode; when not running it keeps its default
    /// white circle. Tied to proxyStore.isRunning — the same state
    /// that drives the play button and the "运行中/未运行" pill.
    private var editButtonBackground: Color {
        guard proxyStore.isRunning else { return Color.white }
        return colorScheme == .dark
            ? Color(red: 0.10, green: 0.28, blue: 0.60)
            : Color(red: 0.83, green: 0.92, blue: 1.0)
    }

    private var editButtonIconColor: Color {
        guard proxyStore.isRunning else { return Color(.label) }
        return colorScheme == .dark ? .white : ConcordTheme.accent
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

    /// IP to show in the status card (audit D10): the core's own
    /// probe.outboundIp result first — it measures the egress
    /// through the selected proxy — ip-api.com only as fallback
    /// for the geo/org enrichment. TrafficStore.probe() runs when
    /// the tunnel connects (see the isRunning onChange below).
    private var displayIp: String? {
        if proxyStore.isRunning,
           let coreIp = trafficStore.outboundIp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !coreIp.isEmpty {
            return coreIp
        }
        return ipInfo?.query
    }

    /// IP slot (FlClash _ExitRow): a static grey bar while the core
    /// is not running, a pulsing skeleton while running and the
    /// probe has not answered, the real IP once it has, "服务失败"
    /// (red) if the probe failed.
    private var ipSlot: some View {
        Group {
            if !proxyStore.isRunning {
                SkeletonBar(width: 140, height: 18)
            } else if let ip = displayIp {
                // FlClash _IpText: hideIp masks the IP as "*****
                // (current_outbound.dart _ipMask).
                Text(settingsStore.hideIp ? "*****" : ip)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if ipFetchFailed {
                Text("服务失败")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                SkeletonBar(width: 140, height: 18, animated: true)
            }
        }
        .frame(height: 28, alignment: .leading)
    }

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
                    PillBadge(text: DeviceNetwork.currentNetworkType(), tint: .gray)
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
                            onRefresh: {
                                Task {
                                    await fetchIPInfo()
                                    await trafficStore.probe()
                                }
                            }
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            ipSlot
                            Spacer().frame(height: 4)
                            chipsSlot
                        }
                        // v0.2.56: the IP-quality page moved to the
                        // 出站 IP sheet ("查看完整 IP 质量"); the
                        // whole status card opens that sheet.
                        .contentShape(Rectangle())
                    }
                    Spacer().frame(height: 16)
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("运行时间")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(uptimeText)
                                    .font(.system(size: 14))
                                    .fontWeight(.semibold)
                            }
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
                            .fill(Color(red: 0, green: 0.478, blue: 1))
                            .rotationEffect(.degrees(Double(morphProgress) * 40))
                            .shadow(color: Color(red: 0, green: 0.478, blue: 1).opacity(0.35), radius: 9, x: 0, y: 6)
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

    /// Wave fill (_StatusWavePainter colours): not running #EFEDF0 /
    /// running #E4EBFB in light mode; white 6% / #262F3E in dark mode.
    private var waveColor: Color {
        if colorScheme == .dark {
            return proxyStore.isRunning
                ? Color(red: 0.149, green: 0.184, blue: 0.243)
                : Color.white.opacity(0.06)
        }
        return proxyStore.isRunning
            ? Color(red: 0.894, green: 0.922, blue: 0.984)
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
                speedPanel(isUp: true)
                speedPanel(isUp: false)
            }
            // D-M5: speed sparkline from the sampled history
            // (TrafficStore.history, one point per traffic poll) —
            // download in accent, upload in orange.
            if trafficStore.history.count > 1 {
                TrafficSparkline(history: trafficStore.history)
                    .frame(height: 44)
            }
        }
        .concordCard()
    }

    private func speedPanel(isUp: Bool) -> some View {
        let bytes = isUp ? trafficStore.current.up : trafficStore.current.down
        let total = isUp ? trafficStore.current.totalUp : trafficStore.current.totalDown
        let split = ConcordBytes.split(bytes)
        return VStack(alignment: .leading, spacing: 6) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
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
        let today = trafficStore.todayTotals
        return Button { showTrafficDetail = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    CardTitleRow(icon: "chart.bar", title: "流量统计")
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
                        HStack(spacing: 12) {
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
                    // The 1 s traffic tick re-renders the card
                    // while the core answers; the TimelineView
                    // keeps the uptime ticking through a transient
                    // probe failure too (same pattern as the status
                    // card's 运行时间).
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("累计运行 \(trafficStore.todayUptimeText)")
                            .font(.footnote)
                            .foregroundStyle(Color(.label))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .concordCard()
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

    // MARK: - Outbound mode card

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitleRow(icon: "arrow.triangle.branch", title: "出站模式")
            // FlClash outbound_mode.dart DashboardConnectedGroup: one
            // connected pill — outer radius 26, height 52, icon 18,
            // selected segment primary-filled, inner radius 12.
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
            // NAGRAM-style row (v0.2.46 ITEM 2): the switch is
            // iOS blue, matching the NAGRAM screenshot — not the
            // theme accent. Same start/stop path as the play
            // button (proxyStore.toggle()); start errors land in
            // proxyStore.startError.
            .tint(.blue)
        }
        .concordCard(padding: 12)
        // The Toggle keeps its own tap (the inner control wins the
        // gesture), so tapping the switch toggles once.
        .contentShape(Rectangle())
        .onTapGesture { Task { await proxyStore.toggle() } }
    }

    /// Intranet address (FlClash intranet_ip.dart: `IP:port` when
    /// allowLan, bare IP otherwise; nil while unread / no network).
    private var intranetAddress: String? {
        guard let ip = intranetIp, !ip.isEmpty else { return nil }
        return settingsStore.allowLan ? "\(ip):\(settingsStore.mixedPort)" : ip
    }

    private var intranetFigureText: String {
        if !intranetLoaded { return "—" }
        return intranetAddress ?? "无网络"
    }

    private func copyIntranetAddress() {
        guard let address = intranetAddress else { return }
        UIPasteboard.general.string = address
        intranetCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            intranetCopied = false
        }
    }

    // MARK: - Intranet IP card

    private var intranetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("内网 IP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                // FlClash intranet_ip.dart: header copy icon copies
                // the address (IP:port when LAN is on); disabled
                // with no address. The checkmark is the success
                // feedback (FlClash shows a "复制成功" banner).
                Button { copyIntranetAddress() } label: {
                    Image(systemName: intranetCopied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(intranetCopied ? .green : Color(.label))
                }
                .buttonStyle(.plain)
                .disabled(intranetAddress == nil)
                .accessibilityLabel("复制内网地址")
            }
            Text(intranetFigureText)
                .font(.system(size: bigNumberSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("局域网代理")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    // FlClash intranet_ip.dart: "端口 {port}" when on,
                    // "已禁用" when off.
                    Text(settingsStore.allowLan ? "端口 \(settingsStore.mixedPort)" : "已禁用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settingsStore.allowLan)
                    .labelsHidden()
                    .tint(ConcordTheme.accent)
            }
            .padding(10)
            .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        }
        .concordCard()
        // FlClash localIpProvider is live: re-read every 2s like the
        // memory poll so a network change shows without reopening.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                intranetIp = DeviceNetwork.localIPv4Address()
                intranetLoaded = true
            }
        }
    }

    // MARK: - Service status card

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // v0.2.56: the title + badge open the 服务状态
                // sheet (MuYu key_7); the chevron keeps the inline
                // expand (engine / TUN / DNS details).
                Button { showServiceSheet = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.checkmark")
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
                Button { withAnimation { servicesExpanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(servicesExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(servicesExpanded ? "收起服务详情" : "展开服务详情")
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
            if servicesExpanded {
                expandedServices
            }
        }
        .concordCard()
    }

    private func servicePill(for service: ConcordServiceItem?) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(serviceTileText(service?.name))
                    .font(.system(size: service?.name.lowercased() == "github" ? 14 : 20, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
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
                        Text(serviceStatusLabel(service.status))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(serviceStatusColor(service.status))
                    }
                }
            }
            HStack(spacing: 8) {
                Button("检测") {
                    Task {
                        if let proxy = proxyStore.selectedOutbound {
                            await trafficStore.probeServices(proxy: proxy)
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
                            await trafficStore.probeServices(proxy: proxy, names: trafficStore.orderedServiceNames)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(trafficStore.isProbingServices || proxyStore.selectedOutbound == nil)
                Spacer()
                Button("管理服务") { showServiceManageSheet = true }
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
                 ? "数据面：PacketTunnel 扩展内的 Concord 核心经 packet-channel 桥接转发流量；静态库构建与真机数据面尚未验证（见 README）。"
                 : "示例模式：VPN 开关只切换界面状态，不转发流量。切到实时核心并启动 VPN 后由扩展转发流量。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
            // FlClash profiles.dart _UsageMeter: warn colour at ≥90%
            // used (the M3 wavy painter is skipped as too costly).
            UsageMeterBar(fraction: usedFraction, warn: usedFraction >= 0.9)
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
            Button { onSelectTab(.proxies) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
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
                    ForEach(Array(groupInitials.enumerated()), id: \.offset) { _, letter in
                        Text(letter)
                            .font(.headline)
                            .foregroundStyle(Color(.label))
                            .frame(width: 40, height: 40)
                            .background(ConcordTheme.softFill, in: Circle())
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
            HStack(spacing: 8) {
                Text("连接统计")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            HStack(spacing: 0) {
                statCell(value: dashboardCount(connectionStore.connections.count), label: "实时连接", destination: .live)
                statCell(value: dashboardCount(eventStore.entries.count), label: "最近请求", destination: .recent)
                statCell(value: dashboardCount(dnsStore.entries.count), label: "DNS查询", destination: .dns)
            }
        }
        .concordCard()
    }

    /// FlClash style.dart dashboardCount: grouped digits below
    /// 100k, compact form at/above (123K, 1.5M).
    private func dashboardCount(_ count: Int) -> String {
        if count < 100_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
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
    private func statCell(value: String, label: String, destination: StatsDestination) -> some View {
        Button { statsDestination = destination } label: {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: statNumberSize, weight: .bold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
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

    private var memoryTotalBytes: UInt64 {
        appMemoryBytes + (trafficStore.coreMemoryBytes ?? 0)
    }

    private var memoryCard: some View {
        Button { showMemoryDetail = true } label: {
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
        }
        .buttonStyle(.plain)
        .concordCard()
        .task {
            await refreshMemorySnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // FlClash memory_info.dart pauses card polling while
                // the detail sheet is open (the sheet reads on its own).
                if !showMemoryDetail {
                    await refreshMemorySnapshot()
                }
            }
        }
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
                Text("新版本需在 GitHub Actions 重新构建 IPA 后手动安装，本应用内无法直接更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
    }
}

/// A dashboard stat cell's destination sheet (D-M6).
private enum StatsDestination: String, Identifiable {
    case live, recent, dns

    var id: String { rawValue }
}

/// Speed sparkline (D-M5): the sampled traffic history as two
/// polylines — download in accent, upload in orange — normalized
/// to the largest sample so a flat line still reads.
private struct TrafficSparkline: View {
    let history: [TrafficPoint]

    var body: some View {
        GeometryReader { geo in
            let points = history.suffix(120)
            let maxValue = max(1, points.map { max($0.up, $0.down) }.max() ?? 1)
            ZStack {
                sparkline(points: points, value: \.down, maxValue: maxValue, in: geo.size)
                    .stroke(ConcordTheme.accent, lineWidth: 1.5)
                sparkline(points: points, value: \.up, maxValue: maxValue, in: geo.size)
                    .stroke(Color.orange, lineWidth: 1.5)
            }
        }
        .accessibilityLabel("最近速度变化：下载蓝线，上传橙线")
    }

    private func sparkline(points: ArraySlice<TrafficPoint>, value: KeyPath<TrafficPoint, Int64>, maxValue: Int64, in size: CGSize) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let step = size.width / CGFloat(points.count - 1)
        for (index, point) in points.enumerated() {
            let x = CGFloat(index) * step
            let y = size.height - (CGFloat(point[keyPath: value]) / CGFloat(maxValue)) * size.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
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
                    .fill(Color.blue)
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

/// Subscription usage meter (FlClash profiles.dart _UsageMeter):
/// same capsule geometry as CapsuleProgressBar, but the fill turns
/// warn-orange at ≥90% used. The M3 wavy painter is skipped.
private struct UsageMeterBar: View {
    let fraction: Double
    let warn: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.898, green: 0.898, blue: 0.925))
                Capsule()
                    .fill(warn ? Color.orange : ConcordTheme.accent)
                    .frame(width: max(geometry.size.width * CGFloat(min(max(fraction, 0), 1)), 8))
                Circle()
                    .fill(warn ? Color.orange : ConcordTheme.accent)
                    .frame(width: 10, height: 10)
                    .offset(x: geometry.size.width - 5)
            }
        }
        .frame(height: 8)
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
    case status, speed, traffic, mode, vpn, intranet, services, profile, groups, stats, memory, update

    /// v0.2.56: the tail follows the MuYu iOS build (IMG_1181 /
    /// video): stats row, 策略组， 配置， 流量统计， 内存信息 — so
    /// the traffic card sits directly below 配置 and directly
    /// above 内存信息. A saved custom order (cardOrderString)
    /// is untouched by this: it only sets the default for
    /// installs that never reordered.
    static let defaultOrder: [DashboardCardID] = [
        .status, .speed, .mode, .vpn, .intranet, .services,
        .stats, .groups, .profile, .traffic, .memory, .update,
    ]

    var title: String {
        switch self {
        case .status: return "状态"
        case .speed: return "网络速度"
        case .traffic: return "流量统计"
        case .mode: return "出站模式"
        case .vpn: return "VPN"
        case .intranet: return "内网 IP"
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

private struct DashboardEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showStatus: Bool
    @Binding var showSpeed: Bool
    @Binding var showTraffic: Bool
    @Binding var showMode: Bool
    @Binding var showVpn: Bool
    @Binding var showIntranet: Bool
    @Binding var showServices: Bool
    @Binding var showProfile: Bool
    @Binding var showGroups: Bool
    @Binding var showStats: Bool
    @Binding var showMemory: Bool
    @Binding var showUpdate: Bool
    @Binding var densityCompact: Bool
    @Binding var cardOrder: [DashboardCardID]

    var body: some View {
        NavigationStack {
            List {
                Section("显示的卡片") {
                    // FlClash widget_registry.dart: the status card is
                    // non-removable ("含启动键，不可移除") — no toggle.
                    Text("状态卡片含启动键，不可移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("网络速度", isOn: $showSpeed)
                    Toggle("流量统计", isOn: $showTraffic)
                    Toggle("出站模式", isOn: $showMode)
                    Toggle("VPN", isOn: $showVpn)
                    Toggle("内网 IP", isOn: $showIntranet)
                    Toggle("服务状态", isOn: $showServices)
                    Toggle("配置", isOn: $showProfile)
                    Toggle("策略组", isOn: $showGroups)
                    Toggle("统计", isOn: $showStats)
                    Toggle("内存", isOn: $showMemory)
                    Toggle("更新状态", isOn: $showUpdate)
                }
                Section("密度") {
                    Toggle("紧凑密度", isOn: $densityCompact)
                    Text("紧凑模式缩小字号与启动按钮、收紧卡片间距，并隐藏部分副标题（FlClash DashboardDensity.compact）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("卡片顺序") {
                    ForEach(cardOrder, id: \.self) { id in
                        Text(id.title)
                    }
                    .onMove { from, to in
                        cardOrder.move(fromOffsets: from, toOffset: to)
                    }
                    Text("拖动右侧手柄调整顺序，关闭的卡片会从仪表盘隐藏，可随时再打开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("title.editDashboard".l10n)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
