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
    @State private var detail: LiveConnection?
    @State private var detailIsLive = true
    /// The selected feed, persisted (upstream requests.dart persists
    /// it in appSetting.requestFeed; ours resets to live on every
    /// visit before this).
    @State private var feed: ConnectionFeed = ConnectionFeed(
        rawValue: UserDefaults.standard.string(forKey: "ConcordiOS.connections.feed.v1") ?? "live") ?? .live

    /// Opens the page on one feed (the dashboard's stat cells open
    /// it directly on live / recent); nil keeps the persisted feed.
    init(initialFeed: ConnectionFeed? = nil) {
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

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation bar.
        // (ConnectionDetailView keeps its own stack as a sheet.)
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
            .background(ConcordTheme.pageBackground)
            .navigationTitle("连接")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $connectionStore.searchText, prompt: "搜索域名、代理或规则")
            .toolbar {
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
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
        }
    }

    /// One connection row, shared by the live and recent feeds.
    /// Live rows show the per-second up/down speeds (upstream
    /// downloadSpeed/uploadSpeed); finished rows show the cumulative
    /// totals, like before.
    private func connectionRow(_ connection: LiveConnection, isLive: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(ConcordFormat.time(Int64(connection.start.timeIntervalSince1970 * 1000)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.host ?? connection.destination)
                    .font(.footnote)
                    .lineLimit(1)
                Text("\(connection.network.uppercased()) · \(connection.rule ?? "—") · \(connection.proxy ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isLive, connection.upSpeed > 0 || connection.downSpeed > 0 {
                    Text("持续 \(ConcordFormat.duration(seconds: connection.durationSeconds)) · ↑ \(ConcordFormat.rate(Int64(connection.upSpeed))) ↓ \(ConcordFormat.rate(Int64(connection.downSpeed)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("持续 \(ConcordFormat.duration(seconds: connection.durationSeconds)) · ↑ \(ConcordFormat.bytes(connection.upload)) ↓ \(ConcordFormat.bytes(connection.download))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
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
                LabeledContent("代理", value: connection.proxy ?? "—")
                LabeledContent("持续", value: ConcordFormat.duration(seconds: connection.durationSeconds))
                LabeledContent("上行", value: ConcordFormat.bytes(connection.upload))
                LabeledContent("下行", value: ConcordFormat.bytes(connection.download))
                if let dnsMode = connection.dnsMode, !dnsMode.isEmpty {
                    LabeledContent("DNS 模式", value: dnsMode)
                }
                if let specialProxy = connection.specialProxy, !specialProxy.isEmpty {
                    LabeledContent("特殊代理", value: specialProxy)
                }
                if let specialRules = connection.specialRules, !specialRules.isEmpty {
                    LabeledContent("特殊规则", value: specialRules)
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
                        ForEach(Array(connection.chains.reversed.enumerated()), id: \.offset) { index, chain in
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
}
