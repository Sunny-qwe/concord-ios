import SwiftUI

// MARK: - Connections (FlClash: RequestsView, lib/views/connection/)
// FlClash's "Requests" page is the live connection table: host, rule,
// proxy, up/down, duration, search, sort, kill a connection
// (connection.close) and kill all. DNS queries live on their own page
// under Settings (FlClash DnsQueriesView).

struct ConnectionsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LiveConnection?
    @State private var detailIsLive = true
    /// The selected feed, persisted (upstream requests.dart persists
    /// it in appSetting.requestFeed; ours resets to live on every
    /// visit before this).
    @State private var feed: ConnectionFeed = ConnectionFeed(
        rawValue: UserDefaults.standard.string(forKey: "ConcordiOS.connections.feed.v1") ?? "live") ?? .live

    /// v0.2.66: tab-bar clearance for pushed pages. True only when
    /// pushed from Tools; the Dashboard sheet keeps the default false.
    private let applyTabBarClearance: Bool

    /// v0.2.68: MuYu sheet mode (Dashboard stats sheet). The view
    /// renders its own sheet header (handle + ✕ + title + actions)
    /// and a bottom floating search bar, with no navigation title,
    /// toolbar or top .searchable. False = the pushed Tools page.
    private let sheetChrome: Bool

    /// Opens the page on one feed (the dashboard's stat cells open
    /// it directly on live / recent); nil keeps the persisted feed.
    init(initialFeed: ConnectionFeed? = nil, applyTabBarClearance: Bool = false, sheetChrome: Bool = false) {
        self.applyTabBarClearance = applyTabBarClearance
        self.sheetChrome = sheetChrome
        if let initialFeed {
            _feed = State(initialValue: initialFeed)
        }
    }

    /// The two feeds of FlClash's Requests page: live connections
    /// and recently finished ones (built locally by diffing
    /// snapshots — see ConnectionStore.recentConnections).
    enum ConnectionFeed: String, CaseIterable {
        case live
        case recent
    }

    private var feedLabel: String {
        feed == .live ? "正在运行" : "最近请求"
    }

    /// Sheet-mode title (v0.2.68): the video calls the live feed
    /// "运行中", not "正在运行".
    private var sheetFeedTitle: String {
        feed == .live ? "运行中" : "最近请求"
    }

    /// The MuYu sheet header (v0.2.68): drag handle, ✕ circle on
    /// the left, centred feed-switcher title with a single ⌄, and
    /// one action per own cardBackground circle on the right —
    /// never a shared capsule. Live: disconnect-all (delete-sweep)
    /// + ⋯ menu. Recent: ⋯ menu only. No refresh button (the video
    /// has none on any of the three sheets).
    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            ZStack {
                Menu {
                    Picker("请求", selection: $feed) {
                        Text("运行中").tag(ConnectionFeed.live)
                        Text("最近请求").tag(ConnectionFeed.recent)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sheetFeedTitle)
                            .font(.headline)
                            .foregroundStyle(Color(.label))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(.label))
                            .frame(width: 36, height: 36)
                            .background(ConcordTheme.cardBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                    Spacer()
                    HStack(spacing: 8) {
                        if feed == .live {
                            Button {
                                Task { await connectionStore.closeAll() }
                            } label: {
                                DeleteSweepIcon(size: 18)
                                    .frame(width: 36, height: 36)
                                    .background(ConcordTheme.cardBackground, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("断开全部连接")
                        }
                        Menu {
                            filterMenuContent
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(.label))
                                .frame(width: 36, height: 36)
                                .background(ConcordTheme.cardBackground, in: Circle())
                        }
                        .accessibilityLabel("更多操作")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    /// Relative start time for live rows ("刚刚", "5 分钟前").
    private static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int64(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }

    /// Rule with its matched payload (same shape as the detail
    /// page's ruleText: rule + " (payload)").
    private static func ruleText(_ connection: LiveConnection) -> String {
        guard let rule = connection.rule else { return "—" }
        if let payload = connection.rulePayload, !payload.isEmpty {
            return "\(rule) (\(payload))"
        }
        return rule
    }

    /// host:port for the bold row line (host when known, else the
    /// destination "ip:port" the store already built).
    private static func hostPort(_ connection: LiveConnection) -> String {
        if let host = connection.host, !host.isEmpty {
            return "\(host):\(connection.destinationPort)"
        }
        return connection.destination
    }

    /// Flag emoji for the node capsule (v0.2.68): the node name
    /// itself often already carries a flag — then nothing is added.
    /// Otherwise a leading region name ("香港") or 2-letter code
    /// ("HK-01") is converted with the existing flagEmoji helper.
    private static func flagPrefix(for nodeName: String) -> String {
        if nodeName.unicodeScalars.contains(where: { (0x1F1E6...0x1F1FF).contains($0.value) }) {
            return ""
        }
        let regions: [(String, String)] = [
            ("香港", "HK"), ("台湾", "TW"), ("日本", "JP"), ("美国", "US"),
            ("新加坡", "SG"), ("韩国", "KR"), ("英国", "GB"), ("德国", "DE"),
            ("法国", "FR"), ("加拿大", "CA"), ("澳大利亚", "AU"), ("澳洲", "AU"),
            ("荷兰", "NL"), ("俄罗斯", "RU"), ("印度", "IN"), ("巴西", "BR"),
            ("土耳其", "TR"), ("泰国", "TH"), ("越南", "VN"),
            ("马来西亚", "MY"), ("印尼", "ID"), ("菲律宾", "PH"),
        ]
        for (name, code) in regions where nodeName.hasPrefix(name) {
            return flagEmoji(countryCode: code) ?? ""
        }
        let letters = String(nodeName.prefix(while: { $0.isLetter }))
        if letters.count == 2, let flag = flagEmoji(countryCode: letters) {
            return flag
        }
        return ""
    }

    /// One chain capsule; the last (node) capsule carries the
    /// node's flag emoji in front of its name.
    private func chainCapsule(_ name: String, isLast: Bool) -> some View {
        let flag = isLast ? Self.flagPrefix(for: name) : ""
        let label = flag.isEmpty ? name : "\(flag) \(name)"
        return Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation bar.
        // (ConnectionDetailView keeps its own stack as a sheet.)
        // v0.2.68: sheet mode draws its own MuYu header + bottom
        // floating search bar; page mode keeps the nav bar.
        Group {
            if sheetChrome {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        sheetHeader
                        contentStack
                    }
                    .background(ConcordTheme.pageBackground)
                    ConnectionFloatingSearchBar(text: $connectionStore.searchText, prompt: "搜索域名、代理或规则")
                }
            } else {
                contentStack
                    .background(ConcordTheme.pageBackground)
                    .navigationTitle("连接")
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $connectionStore.searchText, prompt: "搜索域名、代理或规则")
                    .toolbar {
                        pageToolbar
                    }
            }
        }
        .sheet(item: $detail) { connection in
            ConnectionDetailView(connection: connection, isLive: detailIsLive)
        }
        .refreshable { await connectionStore.refresh() }
        .onChange(of: feed) { _, newFeed in
            UserDefaults.standard.set(newFeed.rawValue, forKey: "ConcordiOS.connections.feed.v1")
        }
        // Live feed (audit B30): poll every 1 s while this page
        // is visible, like FlClash's Requests page — rows appear
        // / disappear and durations tick. The task is cancelled
        // when the page disappears; upstream polls when the core
        // is connected, so the gate is the tunnel running OR the
        // app-side core running (a delay test boots it) — not
        // the tunnel alone.
        .task {
            if connectionStore.connections.isEmpty { await connectionStore.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard TunnelManager.shared.isRunning || AppCore.shared.isRunning else { continue }
                await connectionStore.refresh()
            }
        }
    }

    /// The shared list content (stats row, facet chips, feed list),
    /// used by both the pushed page and the MuYu sheet.
    private var contentStack: some View {
        VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("连接为示例数据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                HStack(spacing: 16) {
                    Text("\(connectionStore.connections.count) 个连接")
                    Text("上行 \(ConcordFormat.bytes(connectionStore.totalUpload))")
                    Text("下行 \(ConcordFormat.bytes(connectionStore.totalDownload))")
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
                if let message = connectionStore.networkUpdateMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if let error = connectionStore.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                // Active facet chips (upstream RecordFilterScope
                // keywords strip): one chip per active facet, tap x
                // to clear it.
                if connectionStore.hasActiveFacets {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if let network = connectionStore.facetNetwork {
                                facetChip("网络 \(network.uppercased())") { connectionStore.facetNetwork = nil }
                            }
                            if let rule = connectionStore.facetRule {
                                facetChip("规则 \(rule)") { connectionStore.facetRule = nil }
                            }
                            if let proxy = connectionStore.facetProxy {
                                facetChip("代理 \(proxy)") { connectionStore.facetProxy = nil }
                            }
                            if let process = connectionStore.facetProcess {
                                facetChip("进程 \(process)") { connectionStore.facetProcess = nil }
                            }
                            if connectionStore.facetMitmOnly {
                                facetChip("MITM") { connectionStore.facetMitmOnly = false }
                            }
                            Button("清除筛选") { connectionStore.clearFacets() }
                                .font(.caption2)
                                .foregroundStyle(ConcordTheme.accent)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 4)
                }
                if feed == .live {
                    if !connectionStore.loaded {
                        // First-load loading state (upstream
                        // requests.dart _loaded): a page activity
                        // indicator until the first read lands,
                        // instead of the empty state.
                        ProgressView("正在加载连接…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if connectionStore.filtered.isEmpty {
                        if proxyStore.isRunning {
                            ContentUnavailableView("暂无活动连接", systemImage: "arrow.left.arrow.right", description: Text("当前没有活动连接，产生流量后会在这里列出"))
                        } else {
                            ContentUnavailableView {
                                Label("暂无活动连接", systemImage: "arrow.left.arrow.right")
                            } description: {
                                Text("开启 VPN 后，这里的实时连接会按 host / 规则 / 代理列出")
                            } actions: {
                                Button("启动 VPN") {
                                    Task { await proxyStore.toggle() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        connectionList(connectionStore.filtered, isLive: true)
                    }
                } else {
                    if connectionStore.recentFiltered.isEmpty {
                        ContentUnavailableView("暂无最近请求", systemImage: "clock", description: Text("已结束的连接会在这里列出（本会话内，最多 200 条）"))
                    } else {
                        connectionList(connectionStore.recentFiltered, isLive: false)
                    }
                }
        }
    }

    /// The pushed page's navigation bar (feed switcher title,
    /// filter menu, disconnect-all, refresh). The sheet header
    /// reuses `filterMenuContent` below, not this toolbar.
    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        // The feed switch is the title itself with a popup
        // menu (upstream requests.dart: the title IS the feed
        // label, 正在运行/最近请求, with a title popup menu).
        ToolbarItem(placement: .principal) {
            Menu {
                Picker("请求", selection: $feed) {
                    Text("正在运行").tag(ConnectionFeed.live)
                    Text("最近请求").tag(ConnectionFeed.recent)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(feedLabel)
                        .font(.headline)
                        .foregroundStyle(Color(.label))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                filterMenuContent
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        // Close-all is an app-bar icon button, live feed only
        // (upstream requests.dart:105-117).
        if feed == .live {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await connectionStore.closeAll() }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("断开全部连接")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await connectionStore.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    /// The ⋯ filter menu, shared by the page toolbar and the MuYu
    /// sheet header (sort, grouping, record-filter facets, network
    /// actions, clear-recent).
    @ViewBuilder
    private var filterMenuContent: some View {
        Picker("排序", selection: $connectionStore.sort) {
            ForEach(ConnectionSort.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        Picker("分组", selection: $connectionStore.groupBy) {
            ForEach(ConnectionGroupBy.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        // Record-filter facets (upstream
        // trackerInfoFacets: network, rule, MITM,
        // app/process, proxy chains).
        Picker("网络", selection: Binding(
            get: { connectionStore.facetNetwork ?? "" },
            set: { connectionStore.facetNetwork = $0.isEmpty ? nil : $0 })) {
                Text("全部").tag("")
                ForEach(connectionStore.facetNetworks, id: \.self) { network in
                    Text(network.uppercased()).tag(network)
                }
            }
        Picker("规则", selection: Binding(
            get: { connectionStore.facetRule ?? "" },
            set: { connectionStore.facetRule = $0.isEmpty ? nil : $0 })) {
                Text("全部").tag("")
                ForEach(connectionStore.facetRules, id: \.self) { rule in
                    Text(rule).tag(rule)
                }
            }
        Picker("代理", selection: Binding(
            get: { connectionStore.facetProxy ?? "" },
            set: { connectionStore.facetProxy = $0.isEmpty ? nil : $0 })) {
                Text("全部").tag("")
                ForEach(connectionStore.facetProxies, id: \.self) { proxy in
                    Text(proxy).tag(proxy)
                }
            }
        Picker("进程", selection: Binding(
            get: { connectionStore.facetProcess ?? "" },
            set: { connectionStore.facetProcess = $0.isEmpty ? nil : $0 })) {
                Text("全部").tag("")
                ForEach(connectionStore.facetProcesses, id: \.self) { process in
                    Text(process).tag(process)
                }
            }
        Toggle("仅 MITM", isOn: $connectionStore.facetMitmOnly)
        if connectionStore.hasActiveFacets {
            Button("清除筛选") { connectionStore.clearFacets() }
        }
        Button("重置解析器连接（network.reset）") {
            Task { await connectionStore.resetNetwork() }
        }
        Button("通知核心网络已变化（network.update）") {
            Task { await connectionStore.networkUpdate(interfaceChanged: false) }
        }
        Button("通知核心网络接口已切换（network.update）") {
            Task { await connectionStore.networkUpdate(interfaceChanged: true) }
        }
        Button("清除最近请求记录", role: .destructive) {
            connectionStore.clearRecent()
        }
    }

    /// One active-facet chip with a clear button.
    private func facetChip(_ text: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    /// The connection list, flat or grouped into sections
    /// (upstream recordGroupings).
    @ViewBuilder
    private func connectionList(_ list: [LiveConnection], isLive: Bool) -> some View {
        if connectionStore.groupBy == .none {
            List(list) { connection in
                Button { detail = connection; detailIsLive = isLive } label: {
                    connectionRow(connection, isLive: isLive)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isLive {
                        Button("断开", role: .destructive) {
                            Task { await connectionStore.close(connection) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // v0.2.66: tab-bar clearance for pushed pages.
            .contentMargins(.bottom, sheetChrome ? 76 : (applyTabBarClearance ? ConcordTheme.tabBarClearance : 0))
        } else {
            List {
                ForEach(connectionStore.grouped(list, by: connectionStore.groupBy), id: \.key) { group in
                    Section("\(group.key)（\(group.rows.count)）") {
                        ForEach(group.rows) { connection in
                            Button { detail = connection; detailIsLive = isLive } label: {
                                connectionRow(connection, isLive: isLive)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if isLive {
                                    Button("断开", role: .destructive) {
                                        Task { await connectionStore.close(connection) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // v0.2.66: tab-bar clearance for pushed pages.
            .contentMargins(.bottom, sheetChrome ? 76 : (applyTabBarClearance ? ConcordTheme.tabBarClearance : 0))
        }
    }

    /// One connection row, rebuilt to the video's card style
    /// (v0.2.68): no 64pt time column, no "TCP · 规则 · 代理"
    /// single line, no duration/speeds third line, no trailing
    /// chevron. Live rows: relative time + network, speeds
    /// top-right; host:port bold; rule → chain capsules (flag on
    /// the node capsule); source ip:port. Recent rows: full
    /// datetime + network; host:port bold + resolved IP; rule →
    /// [final proxy capsule]; source ip:port.
    private func connectionRow(_ connection: LiveConnection, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if isLive {
                HStack {
                    Text("\(Self.relativeTime(connection.start)) \(connection.network.uppercased())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if connection.upSpeed > 0 || connection.downSpeed > 0 {
                        // Per-second live speeds (upstream
                        // downloadSpeed/uploadSpeed); each side
                        // shown only while it is actually moving.
                        HStack(spacing: 6) {
                            if connection.upSpeed > 0 {
                                Text("↑ \(ConcordFormat.rate(Int64(connection.upSpeed)))")
                            }
                            if connection.downSpeed > 0 {
                                Text("↓ \(ConcordFormat.rate(Int64(connection.downSpeed)))")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                Text(Self.hostPort(connection))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                chainLine(connection)
                Text(connection.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(connection.startFullText) \(connection.network.uppercased())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(Self.hostPort(connection))
                        .font(.footnote.weight(.semibold))
                    if let resolved = connection.destinationIp, !resolved.isEmpty {
                        Text(resolved)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.ruleText(connection))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("→")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    chainCapsule(connection.proxy ?? connection.chains.last ?? "—", isLast: true)
                }
                Text(connection.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Live chain line: rule name, arrow, then each chain element
    /// as a capsule (upstream shows the chains reversed, group →
    /// strategy group → node — same order as the detail page).
    /// With no chains, the proxy itself is the single capsule.
    private func chainLine(_ connection: LiveConnection) -> some View {
        // The chains arrive node-first (see the detail page), so
        // reverse them for display; the last capsule is the node.
        let chains = Array(connection.chains.reversed())
        return HStack(spacing: 6) {
            Text(Self.ruleText(connection))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("→")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if chains.isEmpty {
                chainCapsule(connection.proxy ?? "—", isLast: true)
            } else {
                ForEach(Array(chains.enumerated()), id: \.offset) { index, chain in
                    chainCapsule(chain, isLast: index == chains.count - 1)
                }
            }
        }
    }
}

struct ConnectionDetailView: View {
    let connection: LiveConnection
    /// False for a finished connection from 最近请求： there is
    /// nothing to close.
    var isLive: Bool = true
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var dnsStore: DnsStore
    @Environment(\.dismiss) private var dismiss

    private enum DetailTab: String, CaseIterable {
        case overview = "概览"
        case http = "HTTP 请求"
    }

    @State private var tab = DetailTab.overview

    /// The HTTP Requests tab exists only while MITM is capturing
    /// for this connection (upstream tracker_info_item.dart:
    /// capturing = metadata.mitm && mitm.enable && mitm.capture).
    private var showHttpTab: Bool {
        connection.mitm && settingsStore.mitmEnabled && settingsStore.mitmCapture
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showHttpTab {
                    Picker("详情", selection: $tab) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                if tab == .http && showHttpTab {
                    MitmView(initialConnectionId: connection.id)
                } else {
                    overviewList
                }
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle("连接详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // Load the DNS entries so the DNS 查询 row above can
            // resolve the connection's dnsQueries ids to domains.
            .task { await dnsStore.refresh() }
        }
    }

    /// Overview tab (upstream tracker_info_item.dart _buildOverview):
    /// basic info, address (GeoIP/ASN/remote destination), proxies
    /// (special proxy/rules, DNS mode, chains as chips).
    private var overviewList: some View {
        List {
            Section("连接") {
                LabeledContent("域名", value: connection.host ?? "—")
                LabeledContent("目标", value: connection.destination)
                LabeledContent("来源", value: connection.source)
                LabeledContent("网络", value: connection.network.uppercased())
                LabeledContent("入站", value: connection.inboundType)
                LabeledContent("创建时间", value: connection.startFullText)
                if let process = connection.process {
                    LabeledContent("进程", value: process)
                }
                if let processPath = connection.processPath {
                    LabeledContent("进程路径", value: processPath)
                }
                if connection.mitm || connection.mitmRefused {
                    LabeledContent("MITM", value: connection.mitmRefused ? "已拒绝" : "已拦截")
                }
            }
            Section("路由") {
                LabeledContent("规则", value: ruleText)
                if let ruleIndex = connection.ruleIndex {
                    // Upstream 0c9788f: the deciding rule's position,
                    // from 0, in the list `rule.list` gave.
                    LabeledContent("规则序号", value: "#\(ruleIndex)")
                }
                LabeledContent("代理", value: connection.proxy ?? "—")
                LabeledContent("持续", value: ConcordFormat.duration(seconds: connection.durationSeconds))
                LabeledContent("上行", value: ConcordFormat.bytes(connection.upload))
                LabeledContent("下行", value: ConcordFormat.bytes(connection.download))
                if let dnsMode = connection.dnsMode, !dnsMode.isEmpty {
                    LabeledContent("DNS 模式", value: dnsMode)
                }
                if !connection.dnsQueries.isEmpty {
                    // Upstream 0c9788f: the dns.watch entries that
                    // gave out the destination's address, by their
                    // numeric id; resolved to domain + type when the
                    // DNS page has loaded them, bare #id otherwise.
                    LabeledContent("DNS 查询", value: dnsQueryText)
                }
                if let specialProxy = connection.specialProxy, !specialProxy.isEmpty {
                    LabeledContent("特殊代理", value: specialProxy)
                }
                if let specialRules = connection.specialRules, !specialRules.isEmpty {
                    LabeledContent("特殊规则", value: specialRules)
                }
            }
            if let failureKind = connection.failureKind {
                // Upstream 0c9788f: a failed dial only ever arrives
                // via the `ended` list (opened + closed in the same
                // delta, zero traffic) — see ConnectionStore.
                Section("拨号失败") {
                    LabeledContent("原因", value: ConcordConnectionFailure.label(for: failureKind))
                    if let message = connection.failureMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let timing = connection.timing {
                // Upstream 0c9788f ConnectionTiming: each step in
                // microseconds after the core accepted the flow.
                Section("建立耗时") {
                    ForEach(timingRows(timing), id: \.0) { label, microseconds in
                        LabeledContent(label, value: Self.timingText(microseconds))
                    }
                }
            }
            if let endReason = connection.endReason {
                // Upstream 0c9788f ConnectionDelta.ended: why this
                // finished connection ended and when. The 上行/下行
                // above are already the core's final totals.
                Section("结束") {
                    LabeledContent("原因", value: ConcordEndedConnection.label(for: endReason))
                    if let endedAt = connection.endedAt {
                        LabeledContent("结束时间", value: Self.fullTime(endedAt))
                    }
                    LabeledContent("最终上行", value: ConcordFormat.bytes(connection.upload))
                    LabeledContent("最终下行", value: ConcordFormat.bytes(connection.download))
                    if let message = connection.endMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Section("地址") {
                if !connection.destinationGeoIp.isEmpty {
                    LabeledContent("目标 GeoIP", value: connection.destinationGeoIp.joined(separator: " "))
                }
                if let asn = connection.destinationAsn, !asn.isEmpty {
                    LabeledContent("目标 ASN", value: asn)
                }
                if let remote = connection.remoteDestination, !remote.isEmpty {
                    LabeledContent("远程目标", value: remote)
                }
                if !connection.sourceGeoIp.isEmpty {
                    LabeledContent("来源 GeoIP", value: connection.sourceGeoIp.joined(separator: " "))
                }
                if let asn = connection.sourceAsn, !asn.isEmpty {
                    LabeledContent("来源 ASN", value: asn)
                }
                if connection.destinationGeoIp.isEmpty && connection.destinationAsn == nil
                    && connection.remoteDestination == nil && connection.sourceGeoIp.isEmpty {
                    Text("核心未提供 GeoIP / ASN 信息。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !connection.chains.isEmpty {
                Section("代理链") {
                    // Upstream shows the chains reversed with arrows
                    // between them (tracker_info_item.dart _buildChains).
                    HStack(spacing: 6) {
                        ForEach(Array(connection.chains.reversed().enumerated()), id: \.offset) { index, chain in
                            if index > 0 {
                                Text("→")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(chain)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            Section {
                if isLive {
                    Button("断开此连接", role: .destructive) {
                        Task {
                            await connectionStore.close(connection)
                            dismiss()
                        }
                    }
                }
                NavigationLink("MITM 拦截记录（mitm.exchanges）") {
                    MitmView(initialConnectionId: connection.id)
                }
                Text("断开调用 connection.close；拦截记录调用 mitm.exchanges，需要 MITM 已开启并正在捕获。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
    }

    /// Rule with its matched payload (upstream TrackerRuleText:
    /// rule + rulePayload).
    private var ruleText: String {
        guard let rule = connection.rule else { return "—" }
        if let payload = connection.rulePayload, !payload.isEmpty {
            return "\(rule) (\(payload))"
        }
        return rule
    }

    /// The connection's DNS queries, resolved to domain + type
    /// against the DNS store when it has loaded them.
    private var dnsQueryText: String {
        connection.dnsQueries.map { id in
            if let entry = dnsStore.entries.first(where: { $0.dnsId == id }) {
                return "#\(id) \(entry.domain) \(entry.type)"
            }
            return "#\(id)"
        }.joined(separator: " · ")
    }

    /// The setup steps the connection actually took, in order
    /// (upstream ConnectionTiming: microseconds after `accepted`).
    private func timingRows(_ timing: ConcordConnectionTiming) -> [(String, UInt32)] {
        var rows: [(String, UInt32)] = []
        if let value = timing.dnsStart { rows.append(("DNS 查询开始", value)) }
        if let value = timing.dnsEnd { rows.append(("DNS 查询完成", value)) }
        if let value = timing.routed { rows.append(("路由决定", value)) }
        if let value = timing.dialStart { rows.append(("开始拨号", value)) }
        if let value = timing.connected { rows.append(("首跳接通", value)) }
        if let value = timing.tls { rows.append(("握手完成", value)) }
        if let value = timing.dialEnd { rows.append(("拨号完成", value)) }
        if let value = timing.targetTls { rows.append(("目标 TLS 完成", value)) }
        if let value = timing.decrypted { rows.append(("解密就绪", value)) }
        return rows
    }

    /// Microseconds after `accepted`, as milliseconds with one decimal.
    private static func timingText(_ microseconds: UInt32) -> String {
        String(format: "%.1f ms", Double(microseconds) / 1000)
    }

    /// Full date-time for the end timestamp (same shape as the
    /// start time above).
    private static func fullTime(_ epochMillis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
    }
}

/// The MuYu bottom floating search bar (v0.2.68): a rounded bar
/// with a magnifier + TextField, overlaid at the bottom of the
/// sheet list. Drives the store's searchText, same as the page's
/// top .searchable did.
private struct ConnectionFloatingSearchBar: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(.footnote)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
