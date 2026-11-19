import SwiftUI

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
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("ConcordiOS.dashboard.show.status") private var showStatus = true
    @AppStorage("ConcordiOS.dashboard.show.speed") private var showSpeed = true
    @AppStorage("ConcordiOS.dashboard.show.mode") private var showMode = true
    @AppStorage("ConcordiOS.dashboard.show.vpn") private var showVpn = true
    @AppStorage("ConcordiOS.dashboard.show.intranet") private var showIntranet = true
    @AppStorage("ConcordiOS.dashboard.show.services") private var showServices = true
    @AppStorage("ConcordiOS.dashboard.show.profile") private var showProfile = true
    @AppStorage("ConcordiOS.dashboard.show.groups") private var showGroups = true
    @AppStorage("ConcordiOS.dashboard.show.stats") private var showStats = true

    @State private var showEditSheet = false
    @State private var servicesExpanded = false
    @State private var tunnelStartedAt: Date?
    @State private var subscription: ConcordSubscriptionInfo?
    @State private var intranetIp: String?
    @State private var ipInfo: IPQualityInfo?
    @State private var ipLatencyMs: Int?
    @State private var morphProgress: CGFloat = 0
    @State private var ipChecking = false
    @State private var ipFetchFailed = false
    /// The last probe fetch failed (no data): while running, the
    /// card shows "服务失败" instead of the loading skeletons.

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

    private var serviceBadge: (text: String, tint: Color) {
        guard !trafficStore.services.isEmpty else { return ("未检测", .gray) }
        let available = trafficStore.services.filter { $0.status == "available" }.count
        if available == trafficStore.services.count { return ("全部可用", .green) }
        return ("\(available)/\(trafficStore.services.count) 可用", .orange)
    }

    /// Nodes whose last latency test failed (delay.test / delay.run
    /// report a negative value). Shown as the orange "N 超时" badge;
    /// hidden until at least one test has run.
    private var timeoutCount: Int {
        proxyStore.latencies.values.filter { $0 < 0 }.count
    }

    private var groupInitials: [String] {
        proxyStore.groups.prefix(4).map { group in
            group.name == "github" ? "GH" : String(group.name.prefix(1)).uppercased()
        }
    }

    private var extraGroups: Int {
        max(0, proxyStore.groups.count - 4)
    }

    // MARK: - Subscription traffic (provider.get subscriptionInfo)

    private var usedFraction: Double {
        guard let info = subscription, info.total > 0 else { return 0 }
        return Double(info.upload + info.download) / Double(info.total)
    }

    private var usedPercentText: String {
        guard subscription != nil else { return "—" }
        return "\(Int(usedFraction * 100))%"
    }

    private var trafficText: String {
        guard let info = subscription else { return "— / —" }
        return "\(ConcordFormat.bytes(info.upload + info.download)) / \(ConcordFormat.bytes(info.total))"
    }

    private var remainingText: String {
        guard let info = subscription, info.expire > 0 else { return "剩余 — 天" }
        return "剩余 \(ConcordRelativeTime.daysUntil(epochSeconds: info.expire)) 天"
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
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon") else { return }
        ipChecking = true
        defer { ipChecking = false }
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { ipFetchFailed = true; return }
            let decoded = try JSONDecoder().decode(IPQualityInfo.self, from: data)
            guard decoded.status == "success" else { ipFetchFailed = true; return }
            ipLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            ipInfo = decoded
            ipFetchFailed = false
        } catch {
            // No network or API error: keep the previous (or empty)
            // values — the card shows "服务失败" while running, or
            // the skeleton bars while not running, instead of stale
            // numbers.
            ipFetchFailed = true
        }
    }

    /// Quality pill from the lookup latency (FlClash shows "质量 优"
    /// next to the IP; the thresholds are ours — the reference only
    /// shows the 优 state).
    private enum IPQualityLevel { case good, fair, poor }

    private var ipQuality: (text: String, level: IPQualityLevel)? {
        guard let ms = ipLatencyMs else { return nil }
        if ms <= 500 { return ("质量 优", .good) }
        if ms <= 1500 { return ("质量 良", .fair) }
        return ("质量 差", .poor)
    }

    private func refreshAll() async {
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
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("示例数据：所有数值均为内置示例，不是真实核心数据")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if showStatus { statusCard }
                if showSpeed { speedCard }
                if showMode { modeCard }
                if showVpn { vpnCard }
                if showIntranet { intranetCard }
                if showServices { servicesCard }
                if showProfile { profileCard }
                if showGroups { groupsCard }
                if showStats { statsCard }
                if let error = proxyStore.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
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
                tunnelStartedAt = Date()
            }
            intranetIp = DeviceNetwork.localIPv4Address()
            await fetchIPInfo()
            await trafficStore.refreshEngineStatus()
            await refreshSubscription()
            if trafficStore.services.isEmpty,
               let proxy = proxyStore.selectedOutbound,
               client.mode == .sample || tunnelManager.isRunning {
                await trafficStore.probeServices(proxy: proxy)
            }
        }
        .onChange(of: proxyStore.isRunning) { _, running in
            tunnelStartedAt = running ? (tunnelStartedAt ?? Date()) : nil
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
                ipLatencyMs = nil
                ipFetchFailed = false
            }
            Task { await fetchIPInfo() }
        }
        .onChange(of: settingsStore.mode) { _, _ in
            Task { await settingsStore.applyGeneralToCore() }
        }
        .sheet(isPresented: $showEditSheet) {
            DashboardEditSheet(
                showStatus: $showStatus,
                showSpeed: $showSpeed,
                showMode: $showMode,
                showVpn: $showVpn,
                showIntranet: $showIntranet,
                showServices: $showServices,
                showProfile: $showProfile,
                showGroups: $showGroups,
                showStats: $showStats
            )
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .center) {
            Text("仪表盘")
                .font(.system(size: 18, weight: .bold))
            Spacer()
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

    /// IP slot (FlClash _ExitRow): a static grey bar while the core
    /// is not running, a pulsing skeleton while running and the
    /// probe has not answered, the real IP once it has, "服务失败"
    /// (red) if the probe failed.
    private var ipSlot: some View {
        Group {
            if !proxyStore.isRunning {
                SkeletonBar(width: 140, height: 18)
            } else if let ip = ipInfo?.query {
                Text(ip)
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
                    if let quality = ipQuality {
                        qualityPill(text: quality.text, level: quality.level)
                    }
                }
            } else if ipFetchFailed {
                Text("点按图标重试")
                    .font(.system(size: 10))
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
    /// and loading, the real org once probed, "—" if the probe
    /// answered without an org or failed.
    private var orgValue: some View {
        Group {
            if !proxyStore.isRunning {
                SkeletonBar(width: 96, height: 12)
                    .padding(.top, 2)
            } else if let org = ipInfo?.org ?? ipInfo?.isp {
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
                            onRefresh: { Task { await fetchIPInfo() } }
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            ipSlot
                            Spacer().frame(height: 4)
                            chipsSlot
                        }
                    }
                    Spacer().frame(height: 16)
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("运行时间")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(uptimeText)
                                    .font(.system(size: 14))
                                    .fontWeight(.semibold)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("组织")
                                .font(.system(size: 10))
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
                    .frame(width: 88, height: 88)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(proxyStore.isRunning ? "停止 VPN" : "启动 VPN")
                .frame(width: 88)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16))
        }
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 34))
        .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
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
    private func qualityPill(text: String, level: IPQualityLevel) -> some View {
        let bg: Color
        let fg: Color
        if level == .good {
            bg = Color(red: 0.80, green: 0.95, blue: 0.74)
            fg = Color(red: 0.15, green: 0.45, blue: 0.15)
        } else if level == .fair {
            bg = Color(red: 1.0, green: 0.92, blue: 0.75)
            fg = Color(red: 0.72, green: 0.44, blue: 0.05)
        } else {
            bg = Color(red: 1.0, green: 0.85, blue: 0.82)
            fg = Color(red: 0.72, green: 0.15, blue: 0.12)
        }
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUp ? Color(.label) : ConcordTheme.accent)
                Text(isUp ? "上传" : "下载")
                    .font(.system(size: 10))
                    .fontWeight(.semibold)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(split.number)
                    .font(.system(size: 25, weight: .bold))
                Text("\(split.unit)/s")
                    .font(.system(size: 12))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            // Reference shows "累计 0 B" (no ".0"): ConcordFormat
            // formats 0 as "0.0 B", so special-case zero locally
            // (the shared formatter is used elsewhere and stays).
            Text("累计 \(total == 0 ? "0 B" : ConcordFormat.bytes(total))")
                .font(.system(size: 10))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    // MARK: - Outbound mode card

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitleRow(icon: "arrow.triangle.branch", title: "出站模式")
            HStack(spacing: 12) {
                ForEach(OutboundMode.allCases) { mode in
                    Button { settingsStore.mode = mode } label: {
                        VStack(spacing: 6) {
                            Image(systemName: modeIcon(mode))
                                .font(.system(size: 17, weight: .semibold))
                            Text(modeShortLabel(mode))
                                .font(.system(size: 10))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(settingsStore.mode == mode ? ConcordTheme.accent : ConcordTheme.softFill,
                                    in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
                        .foregroundStyle(settingsStore.mode == mode ? .white : Color(.label))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let message = settingsStore.generalApplyMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
    }

    // MARK: - VPN card (reference IMG_1110)
    //
    // Off state: a GREY circle with a dark-grey shield OUTLINE and
    // the text "已断开" (not "已关闭"). On state: the blue circle
    // with a white filled shield, text "已连接" (no on-state
    // reference exists — this wording is an inference).

    private var vpnCard: some View {
        HStack(spacing: 12) {
            if proxyStore.isRunning {
                BlobIcon(systemName: "shield.fill", iconColor: .white,
                         blobColor: ConcordTheme.accent, size: 52)
            } else {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.93, green: 0.93, blue: 0.95))
                        .frame(width: 52, height: 52)
                    Image(systemName: "shield")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.42))
                }
                .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("VPN")
                    .font(.system(size: 14, weight: .semibold))
                Text(proxyStore.isRunning ? "已连接" : "已断开")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { proxyStore.isRunning },
                set: { _ in Task { await proxyStore.toggle() } }
            ))
            .labelsHidden()
            .tint(ConcordTheme.accent)
        }
        .concordCard(padding: 12)
    }

    // MARK: - Intranet IP card

    private var intranetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("内网 IP")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(intranetIp ?? "—")
                .font(.system(size: 25, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("局域网代理")
                        .font(.system(size: 13))
                        .fontWeight(.semibold)
                    Text(settingsStore.allowLan ? "已开启" : "已关闭")
                        .font(.system(size: 10))
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
    }

    // MARK: - Service status card

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation { servicesExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkmark")
                        .font(.system(size: 16, weight: .semibold))
                    Text("服务状态")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    PillBadge(text: serviceBadge.text, tint: serviceBadge.tint)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(servicesExpanded ? 90 : 0))
                }
                .foregroundStyle(Color(.label))
            }
            .buttonStyle(.plain)
            HStack(spacing: 12) {
                servicePill(for: service(named: "google"))
                servicePill(for: service(named: "github"))
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
                .font(.system(size: 13))
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
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            if trafficStore.services.isEmpty {
                Text("通过当前出站检测 Google / GitHub / YouTube 等服务的可用性（probe.services）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trafficStore.services) { service in
                    HStack {
                        Text(service.name).font(.system(size: 13))
                        Spacer()
                        if let region = service.region, !region.isEmpty {
                            Text(region).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(service.delay.map { "\($0) ms" } ?? "—").font(.system(size: 10))
                        Text(serviceStatusLabel(service.status))
                            .font(.system(size: 10))
                            .fontWeight(.semibold)
                            .foregroundStyle(serviceStatusColor(service.status))
                    }
                }
            }
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
            Divider()
            LabeledContent("引擎", value: trafficStore.engineStatus.map { engineStateLabel($0.state) } ?? (proxyStore.isRunning ? "已启动" : "已停止"))
            if let engine = trafficStore.engineStatus,
               let faults = engine.faults, !faults.isEmpty {
                ForEach(faults, id: \.service) { fault in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动失败：\(fault.service)").font(.system(size: 13))
                        Text("\(fault.reason)：\(fault.message)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = trafficStore.engineStatusError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            LabeledContent("VPN 隧道", value: tunnelStatusText)
            LabeledContent("TUN", value: settingsStore.tunEnabled ? "已启用（\(settingsStore.tunStack)）" : "未启用")
            LabeledContent("DNS", value: settingsStore.dnsEnabled ? "已启用" : "未启用")
            Text(client.mode == .live
                 ? "数据面：PacketTunnel 扩展内的 Concord 核心经 packet-channel 桥接转发流量；静态库构建与真机数据面尚未验证（见 README）。"
                 : "示例模式：VPN 开关只切换界面状态，不转发流量。切到实时核心并启动 VPN 后由扩展转发流量。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Subscription card

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 16, weight: .semibold))
                Text("配置")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    Task {
                        if let profile = profileStore.activeProfile {
                            await profileStore.update(profile)
                        }
                        await refreshSubscription()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.label))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更新订阅")
                Button { onSelectTab(.profiles) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Text(profileStore.activeProfile?.name ?? "未选择订阅")
                    .font(.system(size: 18))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Button { onSelectTab(.profiles) } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.label))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换订阅")
            }
            HStack {
                Text("更新于 \(updatedText)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(remainingText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(usedPercentText)
                    .font(.system(size: 24, weight: .bold))
                Text("已用")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trafficText)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            CapsuleProgressBar(fraction: usedFraction)
            if subscription == nil {
                Text("订阅流量信息：核心未提供（需订阅支持 subscription-userinfo，或先启动 VPN）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .concordCard()
    }

    // MARK: - Proxy groups card

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { onSelectTab(.proxies) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 16, weight: .semibold))
                    Text("策略组")
                        .font(.system(size: 12, weight: .semibold))
                    if timeoutCount > 0 {
                        PillBadge(text: "\(timeoutCount) 超时", tint: .orange)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color(.label))
            }
            .buttonStyle(.plain)
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(proxyStore.groups.count)")
                        .font(.system(size: 25, weight: .bold))
                    Text("个")
                        .font(.system(size: 13))
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12))
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
                            .font(.system(size: 13))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(.label))
                            .frame(width: 40, height: 40)
                            .background(ConcordTheme.softFill, in: Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
            }
        }
        .concordCard()
    }

    // MARK: - Stats card

    private var statsCard: some View {
        HStack(spacing: 0) {
            statCell(value: "\(connectionStore.connections.count)", label: "实时连接")
            statCell(value: "\(eventStore.entries.count)", label: "最近请求")
            statCell(value: "\(dnsStore.entries.count)", label: "DNS查询")
        }
        .concordCard()
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                        .font(.system(size: 13, weight: .semibold))
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

// MARK: - Dashboard edit sheet (pencil button)

private struct DashboardEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showStatus: Bool
    @Binding var showSpeed: Bool
    @Binding var showMode: Bool
    @Binding var showVpn: Bool
    @Binding var showIntranet: Bool
    @Binding var showServices: Bool
    @Binding var showProfile: Bool
    @Binding var showGroups: Bool
    @Binding var showStats: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("显示的卡片") {
                    Toggle("状态", isOn: $showStatus)
                    Toggle("网络速度", isOn: $showSpeed)
                    Toggle("出站模式", isOn: $showMode)
                    Toggle("VPN", isOn: $showVpn)
                    Toggle("内网 IP", isOn: $showIntranet)
                    Toggle("服务状态", isOn: $showServices)
                    Toggle("配置", isOn: $showProfile)
                    Toggle("策略组", isOn: $showGroups)
                    Toggle("统计", isOn: $showStats)
                }
                Section {
                    Text("关闭的卡片会从仪表盘隐藏，可随时再打开。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("编辑仪表盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
