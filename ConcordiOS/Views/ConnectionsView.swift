import SwiftUI

// MARK: - Connections (FlClash: RequestsView, lib/views/connection/)
// FlClash's "Requests" page is one page with three segments —
// 连接 / HTTP / DNS — sharing one search box (requests.dart).
// The 连接 segment is a single list, newest first, live + recently
// finished together (the core's event log, rebuilt locally here by
// diffing snapshots — see ConnectionStore.recentConnections). The
// HTTP segment is the all-connections MITM exchange list
// (mitm.query); the DNS segment is the dns.watch list. There is no
// sort control and no grouping upstream (log order, newest first).

struct ConnectionsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var mitmStore: MitmStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var moduleStore: MitmModuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LiveConnection?
    @State private var detailIsLive = true
    @State private var detailOpensRequests = false
    /// The segment shown (upstream RequestsSegment).
    @State private var segment: RequestsSegment = .connections
    /// The `+` condition editor (upstream
    /// connection_condition_form.dart).
    @State private var showConditionEditor = false
    /// Kill-all confirmation (upstream _closeActiveConnections).
    @State private var showKillAllConfirm = false
    /// The HTTP segment's tapped exchange (opens its detail sheet).
    @State private var httpDetail: MitmExchangeSummary?

    /// v0.2.119 (FIX 3): sheet list-drag coordination (MuYu
    /// parity) — same mechanism as DnsQueriesView. v0.2.118
    /// forwarded the drag with a .simultaneousGesture(DragGesture)
    /// on the List, gated on an anchor row's minY (listAtTop) —
    /// that gesture never delivers on a UITableView-backed List,
    /// so the mechanism is removed entirely (anchor,
    /// PreferenceKey, listAtTop, SheetListDragState,
    /// listDragGesture all gone; no dead mechanism left). The
    /// drag now comes from SheetListDragPan: a UIKit
    /// UIPanGestureRecognizer on the underlying UITableView,
    /// attached by the zero-height bridge row at the top of each
    /// List branch below. It latches only on a drag that starts
    /// at the top, forwards translation + release velocity to
    /// onSheetDragChanged/onSheetDragEnded, and recognises
    /// simultaneously with the table view's own pan recognizer —
    /// the list still scrolls a little while the sheet grows,
    /// and pull-to-refresh still works (no .scrollDisabled). It
    /// also works with zero rows, where a scroll-position-driven
    /// approach could never fire. In page mode the callbacks are
    /// nil and the bridge is a no-op.

    /// The zero-height bridge row for the list-drag coordination
    /// above (one per List branch — a List's rows cannot share a
    /// single bridge view). SheetListDragPan mounts here and
    /// attaches its UIKit pan recognizer to the underlying
    /// UITableView (see SheetListDragPan.swift).
    private var sheetListDragBridge: some View {
        SheetListDragPan(
            onChanged: { if let onSheetDragChanged { onSheetDragChanged($0) } },
            onEnded: { translation, velocity in
                if let onSheetDragEnded { onSheetDragEnded(translation, velocity) }
            }
        )
        .frame(height: 0)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    /// v0.2.66: tab-bar clearance for pushed pages. True only when
    /// pushed from Tools; the Dashboard sheet keeps the default false.
    private let applyTabBarClearance: Bool

    /// v0.2.68: MuYu sheet mode (Dashboard stats sheet). The view
    /// renders its own sheet header (handle + ✕ + title + actions)
    /// and a bottom floating search bar, with no navigation title,
    /// toolbar or top .searchable. False = the pushed Tools page.
    private let sheetChrome: Bool

    /// Dismiss action for sheet mode (v0.2.113): the Connections
    /// sheet is a custom overlay at the ContentView root, not a
    /// system sheet, so @Environment(\.dismiss) does nothing
    /// there — the overlay passes its own close action. Nil
    /// (default) keeps the old dismiss() behaviour.
    let onClose: (() -> Void)?

    /// Sheet-drag callbacks (v0.2.114): same as DnsQueriesView —
    /// the overlay passes these so the drag gesture lives on the
    /// header only, never on the sheet container (which captured
    /// every vertical drag and left the list unscrollable on
    /// v0.2.113). Nil (default) = no sheet-drag gesture.
    /// onSheetDragEnded takes (translation, release velocity
    /// pt/s, upward negative) — see DnsQueriesView.
    let onSheetDragChanged: ((CGFloat) -> Void)?
    let onSheetDragEnded: ((CGFloat, CGFloat) -> Void)?

    /// Where the page was opened from (the dashboard's stat cells
    /// open it directly on live / recent). Upstream has no feeds —
    /// the list is one log — so this only seeds the status filter
    /// on appear: live → 活动， recent → 全部 (the default).
    private let initialFeed: ConnectionFeed?

    /// Opens the page on one feed (the dashboard's stat cells open
    /// it directly on live / recent); nil keeps the default filter.
    /// `initialSegment` opens the page on a Requests segment (the
    /// Dashboard DNS stat opens it on .dns); nil keeps .connections.
    init(initialFeed: ConnectionFeed? = nil, initialSegment: RequestsSegment? = nil, applyTabBarClearance: Bool = false, sheetChrome: Bool = false, onClose: (() -> Void)? = nil, onSheetDragChanged: ((CGFloat) -> Void)? = nil, onSheetDragEnded: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.initialFeed = initialFeed
        self._segment = State(initialValue: initialSegment ?? .connections)
        self.applyTabBarClearance = applyTabBarClearance
        self.sheetChrome = sheetChrome
        self.onClose = onClose
        self.onSheetDragChanged = onSheetDragChanged
        self.onSheetDragEnded = onSheetDragEnded
    }

    /// The two feeds the page used to switch between (kept for the
    /// Dashboard deep-links: ContentView passes one in). Upstream
    /// v0.9.5 has NO live/recent feeds — the connections segment
    /// is a single list (see ConnectionStore.displayedConnections).
    enum ConnectionFeed: String, CaseIterable {
        case live
        case recent
    }

    /// The page's segments (upstream RequestsSegment,
    /// requests.dart:27-50): connections, HTTP (only while MITM
    /// captures), DNS.
    enum RequestsSegment: String, CaseIterable {
        case connections = "连接"
        case http = "HTTP"
        case dns = "DNS"
    }

    /// Whether MITM capture is on (upstream httpCapturing):
    /// the HTTP segment only exists while this is true.
    private var capturing: Bool {
        settingsStore.mitmEnabled && settingsStore.mitmCapture
    }

    /// The segments the bar offers right now.
    private var visibleSegments: [RequestsSegment] {
        capturing ? RequestsSegment.allCases : [.connections, .dns]
    }

    /// Upstream httpCaptureHasNoHost (http_capture.dart:10-12):
    /// no listed host and no enabled module — capture records
    /// nothing. Same computation as MitmView.
    private var httpCaptureNoHosts: Bool {
        guard !moduleStore.modules.contains(where: { $0.enabled }) else { return false }
        let hosts = settingsStore.mitmHostnames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hosts.allSatisfy { $0.hasPrefix("-") }
    }

    /// The MuYu sheet header (v0.2.68): drag handle, ✕ circle on
    /// the left, centred "连接" title, and one action per own
    /// cardBackground circle on the right — never a shared capsule.
    /// Disconnect-all (delete-sweep) + ⋯ menu on the connections
    /// segment; ⋯ menu only elsewhere. No refresh button (the video
    /// has none on any of the three sheets).
    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            ZStack {
                Text("连接")
                    .font(.headline)
                    .foregroundStyle(Color(.label))
                HStack {
                    // v0.2.113: in the ContentView overlay there is
                    // no system presentation to dismiss, so the
                    // overlay's onClose runs instead of dismiss().
                    Button { if let onClose { onClose() } else { dismiss() } } label: {
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
                        if segment == .connections {
                            Button {
                                showKillAllConfirm = true
                            } label: {
                                DeleteSweepIcon(size: 18)
                                    .frame(width: 36, height: 36)
                                    .background(ConcordTheme.cardBackground, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("断开全部连接")
                            .disabled(connectionStore.connections.isEmpty)
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
        // v0.2.114: the sheet-drag gesture lives HERE, on the
        // header only. The header is a sibling of the list
        // (contentStack), not an ancestor, so it can never
        // capture a drag that starts on the list — the list
        // scrolls freely. Dragging up here expands the sheet
        // toward the 0.9 detent; dragging down steps back /
        // dismisses (the overlay owns those rules via the
        // callbacks). A tap (<8pt) still reaches the ✕ / action
        // buttons and the feed-switcher menu.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { if let onSheetDragChanged { onSheetDragChanged($0.translation.height) } }
                // DragGesture.Value exposes no public velocity on
                // this SDK, so the header passes 0; the overlay's
                // snap rule settles a clear upward header drag on
                // translation alone, and the list bridge supplies
                // the real release velocity for list drags.
                .onEnded { if let onSheetDragEnded { onSheetDragEnded($0.translation.height, 0) } }
        )
    }

    /// host:port for the bold row line (host when known, else the
    /// destination "ip:port" the store already built).
    private static func hostPort(_ connection: LiveConnection) -> String {
        if let host = connection.host, !host.isEmpty {
            return "\(host):\(connection.destinationPort)"
        }
        return connection.destination
    }

    /// The detail header / summary title (upstream TrackerInfo.title):
    /// the host, else the destination IP, else the destination.
    /// Internal (not private): ConnectionDetailView uses it too.
    static func detailTitle(_ connection: LiveConnection) -> String {
        if let host = connection.host, !host.isEmpty {
            return host
        }
        if let ip = connection.destinationIp, !ip.isEmpty {
            return ip
        }
        return connection.destination
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
                    ConnectionFloatingSearchBar(text: $connectionStore.searchText, prompt: "搜索域名、规则、进程或 field:值") {
                        searchSubmitted()
                    }
                }
            } else {
                contentStack
                    .padding(.top, 40)
                    .background(ConcordTheme.pageBackground)
                    .upstreamNavBar(title: "连接")
                    .searchable(text: $connectionStore.searchText, prompt: "搜索域名、规则、进程或 field:值")
                    .onSubmit(of: .search) { searchSubmitted() }
                    .toolbar {
                        pageToolbar
                    }
            }
        }
        .sheet(item: $detail) { connection in
            ConnectionDetailView(connection: connection, isLive: detailIsLive, opensRequests: detailOpensRequests)
                // Upstream showTrackerInfoDetail → showSheet(props:
                // nestedPagedSheetProps) + NestedPagedSheet, [9/16,
                // 0.9], transparent bg (tracker_info_item.dart:27).
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showConditionEditor) {
            ConnectionConditionEditor(store: connectionStore)
        }
        .sheet(item: $httpDetail) { summary in
            MitmExchangeDetailView(summary: summary)
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
        .alert("断开全部活动连接", isPresented: $showKillAllConfirm) {
            Button("断开", role: .destructive) {
                Task { await connectionStore.closeAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // Upstream _closeActiveConnections shows the count.
            Text("将断开全部 \(connectionStore.connections.count) 个活动连接。")
        }
        .refreshable {
            switch segment {
            case .connections:
                await connectionStore.refresh()
            case .http:
                mitmStore.queryText = connectionStore.searchText
                await mitmStore.runQuery()
            case .dns:
                await dnsStore.refresh()
            }
        }
        .onAppear {
            // The Dashboard's live stat opens on 活动； recent
            // opens on the default 全部.
            if initialFeed == .live {
                connectionStore.statusFilter = .active
            }
        }
        .onChange(of: segment) { _, newSegment in
            segmentChanged(newSegment)
        }
        .onChange(of: capturing) { _, isCapturing in
            // The HTTP segment vanishes when capture stops.
            if !isCapturing && segment == .http {
                segment = .connections
            }
        }
        .onChange(of: connectionStore.searchText) { _, newText in
            // The search box is shared across segments (upstream
            // AppBarSearchState): the DNS segment filters live as
            // you type; the HTTP segment re-queries on submit and
            // on the 1 s poll below.
            if segment == .dns {
                dnsStore.searchText = newText
            }
        }
        // Live feed (audit B30): poll every 1 s while this page
        // is visible, like FlClash's Requests page — rows appear
        // / disappear and durations tick. The task is cancelled
        // when the page disappears; upstream polls when the core
        // is connected, so the gate is the tunnel running OR the
        // app-side core running (a delay test boots it) — not
        // the tunnel alone.
        .task {
            // v0.2.82 (stats freeze): the appear refresh runs
            // only when a core can actually serve it (tunnel up,
            // app core up, or sample mode) — the live/recent
            // sheets refreshed unconditionally on appear, the one
            // unguarded store call left on the shared stats tap
            // path (DNS got the same gate in the first v0.2.82
            // fix). The 1 s poll below already uses this gate.
            if connectionStore.connections.isEmpty
                && (TunnelManager.shared.isRunning || AppCore.shared.isRunning || client.mode == .sample) {
                await connectionStore.refresh()
            }
            segmentChanged(segment)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard TunnelManager.shared.isRunning || AppCore.shared.isRunning else { continue }
                await connectionStore.refresh()
                if segment == .dns {
                    await dnsStore.refresh()
                }
                if segment == .http && capturing && !mitmStore.isQuerying
                    && mitmStore.queryNext == nil {
                    // Upstream polls the HTTP feed every second
                    // too; skip while the user paged deeper, so a
                    // poll never wipes the appended pages.
                    mitmStore.queryText = connectionStore.searchText
                    await mitmStore.runQuery()
                }
            }
        }
    }

    /// A segment change takes the shared search with it (upstream
    /// _searchShown): the DNS list filters on the text, the HTTP
    /// list re-queries, the connections list re-filters. Leaving a
    /// segment clears its store's copy, so the standalone DNS page
    /// and the MITM search do not inherit this page's text.
    private func segmentChanged(_ newSegment: RequestsSegment) {
        switch newSegment {
        case .connections:
            dnsStore.searchText = ""
            mitmStore.queryText = ""
        case .http:
            dnsStore.searchText = ""
            mitmStore.queryText = connectionStore.searchText
            Task { await mitmStore.runQuery() }
        case .dns:
            mitmStore.queryText = ""
            dnsStore.searchText = connectionStore.searchText
            if TunnelManager.shared.isRunning || AppCore.shared.isRunning || client.mode == .sample {
                Task { await dnsStore.refresh() }
            }
        }
    }

    /// The search was submitted (return key / floating-bar submit):
    /// the HTTP segment re-queries now instead of waiting for the
    /// next poll tick.
    private func searchSubmitted() {
        if segment == .http {
            mitmStore.queryText = connectionStore.searchText
            Task { await mitmStore.runQuery() }
        }
    }

    /// The shared list content (segment bar, filter row, segment
    /// list), used by both the pushed page and the MuYu sheet.
    /// Upstream Requests has no totals card and fails silently
    /// (log only) — no stats card, no red error text, no VPN
    /// button here.
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
                // The segment bar (upstream ConnectedButtonBar):
                // 连接 / HTTP (only while capturing) / DNS.
                Picker("请求", selection: $segment) {
                    ForEach(visibleSegments, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)
                switch segment {
                case .connections:
                    statusFilterBar
                    activeFilterChips
                    connectionsSegment
                case .http:
                    httpSegment
                case .dns:
                    DnsQueriesView(mode: .segment)
                }
        }
    }

    /// The connections segment: loading / empty states, else the
    /// single newest-first list. The empty text distinguishes a
    /// search with no matches (upstream NullStatusSwitcher).
    private var connectionsSegment: some View {
        Group {
            if !connectionStore.loaded {
                // First-load loading state (upstream requests.dart
                // _loaded): a page activity indicator until the
                // first read lands, instead of the empty state.
                ProgressView("正在加载连接…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connectionStore.displayedConnections.isEmpty {
                if isSearching {
                    ContentUnavailableView("没有符合筛选的连接", systemImage: "magnifyingglass", description: Text("换个搜索词或清除筛选条件再试"))
                } else {
                    ContentUnavailableView("暂无连接", systemImage: "arrow.left.arrow.right", description: Text("当前没有活动或最近的连接，产生流量后会在这里列出"))
                }
            } else {
                connectionList(connectionStore.displayedConnections)
            }
        }
    }

    /// Whether a search, facet, condition or non-default status
    /// filter is narrowing the connections list.
    private var isSearching: Bool {
        !connectionStore.searchText.isEmpty
            || connectionStore.hasActiveFacets
            || connectionStore.statusFilter != .all
    }

    /// The HTTP segment (upstream HttpRequestList): the
    /// all-connections MITM exchange list, newest first, with the
    /// httpCaptureNoHosts empty hint. Tapping a row opens its
    /// exchange detail.
    private var httpSegment: some View {
        Group {
            if mitmStore.isQuerying && mitmStore.queryResults.isEmpty {
                ProgressView("正在加载拦截记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mitmStore.queryResults.isEmpty {
                ContentUnavailableView("暂无拦截记录", systemImage: "eye.slash", description: Text(httpCaptureNoHosts ? "在“主机名”中添加主机后才会记录。" : (mitmStore.queryMessage ?? "开启抓包后，这里列出全部连接的拦截记录")))
            } else {
                VStack(spacing: 0) {
                    if let matched = mitmStore.queryMatched, let held = mitmStore.queryHeld {
                        Text("共 \(matched) 条匹配（已保留 \(held) 条）· 已加载 \(mitmStore.queryResults.count) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    List {
                        ForEach(mitmStore.queryResults) { exchange in
                            Button { httpDetail = exchange } label: {
                                httpExchangeRow(exchange)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(ConcordTheme.cardBackground)
                        }
                        if mitmStore.queryNext != nil {
                            Button("加载更多") {
                                Task { await mitmStore.runQuery(loadMore: true) }
                            }
                            .disabled(mitmStore.isQuerying)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.bottom, sheetChrome ? 76 : (applyTabBarClearance ? ConcordTheme.tabBarClearance : 0))
                }
            }
        }
    }

    /// One HTTP-segment row (upstream http_requests.dart): leading
    /// 40pt method well (LabelWell: ≤3 chars subheadline 15 semibold
    /// mono, 4 chars caption1 12, longer caption2 11); title = path
    /// (else url), subheadline 15; subtitle = host · process,
    /// caption1 12 secondary; trailing = status footnote 13 semibold
    /// (≥400 red, 2xx green, pending 进行中， failed 失败） + size ·
    /// duration caption2 11 secondary. No separate error line —
    /// upstream shows the failure in the status text; the detail
    /// page carries the message. (MitmView's exchangeRow is
    /// per-connection; this list is cross-connection, so it shows
    /// the host too.)
    private func httpExchangeRow(_ exchange: MitmExchangeSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            UpstreamLabelWell(label: exchange.method)
            VStack(alignment: .leading, spacing: 3) {
                Text((exchange.path?.isEmpty == false ? exchange.path : exchange.url) ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(httpExchangeSubtitle(exchange))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(httpStatusText(exchange))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(httpStatusColor(exchange))
                    .monospacedDigit()
                Text("\(ConcordFormat.bytes(exchange.responseSize)) · \(httpMillisText(exchange.duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Upstream http_requests.dart subtitle: host · process.
    private func httpExchangeSubtitle(_ exchange: MitmExchangeSummary) -> String {
        [exchange.host, exchange.app?.process]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Upstream http_requests.dart / mitm_texts.dart: the status
    /// number when answered, 进行中 while pending, 失败 otherwise.
    private func httpStatusText(_ exchange: MitmExchangeSummary) -> String {
        if exchange.status > 0 { return "\(exchange.status)" }
        if exchange.pending == true { return "进行中" }
        return "失败"
    }

    /// Upstream httpStatusColor (mitm_texts.dart): ≥400 error red,
    /// 2xx success green, anything else secondary — except a failed
    /// (unanswered, not pending) exchange, whose 失败 reads red.
    private func httpStatusColor(_ exchange: MitmExchangeSummary) -> Color {
        if exchange.status >= 400 { return .red }
        if exchange.status >= 200 && exchange.status < 300 { return .green }
        if exchange.pending == true { return .secondary }
        return exchange.status > 0 ? .secondary : .red
    }

    /// Upstream httpMillisText (mitm_texts.dart): "123 ms" under a
    /// second, "1.2 s" at and above it.
    private func httpMillisText(_ milliseconds: Int64) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }

    /// Active facet + condition chips (upstream RecordFilterScope
    /// keywords strip): one chip per active facet value and per
    /// condition, tap x to clear it. Multi-value facets get one
    /// chip per value.
    private var activeFilterChips: some View {
        Group {
            if connectionStore.hasActiveFacets {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(connectionStore.facetNetworks).sorted(), id: \.self) { network in
                            facetChip("网络 \(network.uppercased())") { connectionStore.facetNetworks.remove(network) }
                        }
                        ForEach(Array(connectionStore.facetRules).sorted(), id: \.self) { rule in
                            facetChip("规则 \(rule)") { connectionStore.facetRules.remove(rule) }
                        }
                        ForEach(Array(connectionStore.facetProxies).sorted(), id: \.self) { proxy in
                            facetChip("代理 \(proxy)") { connectionStore.facetProxies.remove(proxy) }
                        }
                        ForEach(Array(connectionStore.facetProcesses).sorted(), id: \.self) { process in
                            facetChip("进程 \(process)") { connectionStore.facetProcesses.remove(process) }
                        }
                        if connectionStore.facetMitmOnly {
                            facetChip("MITM") { connectionStore.facetMitmOnly = false }
                        }
                        ForEach(connectionStore.conditions) { condition in
                            facetChip("\(condition.excludes ? "-" : "")\(condition.field.rawValue):\(condition.isEquals ? "=" : "")\(condition.value)") {
                                connectionStore.conditions.removeAll { $0.id == condition.id }
                            }
                        }
                        Button("清除筛选") { connectionStore.clearFacets() }
                            .font(.caption2)
                            .foregroundStyle(ConcordTheme.accent)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// The pushed page's navigation bar (⋯ menu, disconnect-all,
    /// refresh). The sheet header reuses `filterMenuContent`
    /// below, not this toolbar.
    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                filterMenuContent
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        // Close-all is an app-bar icon button on the connections
        // segment (upstream requests.dart:105-117); it asks for
        // confirmation and is disabled with nothing active.
        if segment == .connections {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showKillAllConfirm = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("断开全部连接")
                .disabled(connectionStore.connections.isEmpty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    switch segment {
                    case .connections: await connectionStore.refresh()
                    case .http:
                        mitmStore.queryText = connectionStore.searchText
                        await mitmStore.runQuery()
                    case .dns: await dnsStore.refresh()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    /// The ⋯ filter menu, shared by the page toolbar and the MuYu
    /// sheet header (upstream requests.dart _buildMenuItems):
    /// multi-value record-filter facets, HTTP-capture items while
    /// MITM is enabled, close-active on the connections segment,
    /// clear-DNS-cache on the DNS segment.
    @ViewBuilder
    private var filterMenuContent: some View {
        // Record-filter facets (upstream trackerInfoFacets:
        // network, rule, MITM, app/process, proxy chains) —
        // multi-value: tapping toggles one value, values on one
        // field widen each other.
        facetMultiMenu(title: "网络", values: connectionStore.offeredNetworks, selected: connectionStore.facetNetworks) { value in
            if connectionStore.facetNetworks.contains(value) {
                connectionStore.facetNetworks.remove(value)
            } else {
                connectionStore.facetNetworks.insert(value)
            }
        }
        facetMultiMenu(title: "规则", values: connectionStore.offeredRules, selected: connectionStore.facetRules) { value in
            if connectionStore.facetRules.contains(value) {
                connectionStore.facetRules.remove(value)
            } else {
                connectionStore.facetRules.insert(value)
            }
        }
        facetMultiMenu(title: "代理", values: connectionStore.offeredProxies, selected: connectionStore.facetProxies) { value in
            if connectionStore.facetProxies.contains(value) {
                connectionStore.facetProxies.remove(value)
            } else {
                connectionStore.facetProxies.insert(value)
            }
        }
        facetMultiMenu(title: "进程", values: connectionStore.offeredProcesses, selected: connectionStore.facetProcesses) { value in
            if connectionStore.facetProcesses.contains(value) {
                connectionStore.facetProcesses.remove(value)
            } else {
                connectionStore.facetProcesses.insert(value)
            }
        }
        Toggle("仅 MITM", isOn: $connectionStore.facetMitmOnly)
            .toggleStyle(UpstreamToggleStyle())
        if connectionStore.hasActiveFacets {
            Button("清除筛选") { connectionStore.clearFacets() }
        }
        if settingsStore.mitmEnabled {
            // HTTP capture (upstream http_capture.dart): on/off
            // ("仅保留在内存中") + the capture-limit picker.
            // The toggle saves like the MITM options page's 抓包
            // row; it takes effect on the next apply / VPN restart.
            Section("HTTP 抓包") {
                Button {
                    settingsStore.mitmCapture = true
                    settingsStore.save()
                } label: {
                    HStack {
                        Text("开启")
                        Spacer()
                        if settingsStore.mitmCapture {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    settingsStore.mitmCapture = false
                    settingsStore.save()
                } label: {
                    HStack {
                        Text("关闭")
                        Spacer()
                        if !settingsStore.mitmCapture {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Picker("保留条数", selection: $settingsStore.mitmCaptureEntries) {
                    ForEach(captureLimitOptions, id: \.self) { value in
                        Text("\(value) 条").tag(value)
                    }
                }
                .onChange(of: settingsStore.mitmCaptureEntries) { _, _ in settingsStore.save() }
            }
        }
        if segment == .connections {
            Button("断开全部活动连接", role: .destructive) {
                showKillAllConfirm = true
            }
            .disabled(connectionStore.connections.isEmpty)
        }
        if segment == .dns {
            Button("清除 DNS 缓存") {
                Task { await dnsStore.clearCache() }
            }
        }
    }

    /// The capture-limit options (upstream mitmCaptureOptions,
    /// desktop — iOS is not Android: 500…20000, default 2000).
    /// The current value is listed even when it is not one of
    /// the options, as upstream does.
    private var captureLimitOptions: [Int] {
        let options = [500, 1000, 2000, 5000, 10000, 20000]
        let current = settingsStore.mitmCaptureEntries
        if options.contains(current) { return options }
        return (options + [current]).sorted()
    }

    /// One multi-value facet submenu: each value toggles with a
    /// checkmark. Empty facets offer nothing to pick.
    @ViewBuilder
    private func facetMultiMenu(
        title: String,
        values: [String],
        selected: Set<String>,
        onToggle: @escaping (String) -> Void
    ) -> some View {
        Menu(title) {
            if values.isEmpty {
                Text("无")
            }
            ForEach(values, id: \.self) { value in
                Button {
                    onToggle(value)
                } label: {
                    HStack {
                        Text(title == "网络" ? value.uppercased() : value)
                        Spacer()
                        if selected.contains(value) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
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

    /// Status segment bar (upstream ConditionFilterRow,
    /// connection_filter_row.dart): a horizontally scrollable row
    /// of compact segment buttons `全部 N` / `活动 N` / `失败 N`
    /// with the unfiltered held totals, tapping filters the list;
    /// the `+` button opens the add-condition editor (upstream
    /// connection_condition_form.dart: field picker, value
    /// suggestions with counts, exclude toggle).
    private var statusFilterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ConnectionStatusFilter.allCases) { status in
                        statusSegmentButton(status)
                    }
                }
            }
            Button {
                showConditionEditor = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 30, height: 30)
                    .background(Color.secondary.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("添加筛选条件")
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    /// One status segment: label + thousands-formatted count
    /// (upstream NumberFormat.decimalPattern('en')). Selected
    /// segments are accent-tinted, like the facet chips.
    private func statusSegmentButton(_ status: ConnectionStatusFilter) -> some View {
        let selected = connectionStore.statusFilter == status
        return Button { connectionStore.statusFilter = status } label: {
            Text("\(status.rawValue) \(Self.groupedCount(connectionStore.statusCount(for: status)))")
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ConcordTheme.accent : Color(.label))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? ConcordTheme.accent.opacity(0.15) : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    /// Thousands-grouped count (upstream `_grouped`).
    private static let groupedNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static func groupedCount(_ count: Int) -> String {
        groupedNumberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// The connection list: one flat list with per-minute
    /// separator rows (upstream RecordMinuteList). Upstream has
    /// no sort and no grouping — the list is log order, newest
    /// first (see ConnectionStore.displayedConnections).
    @ViewBuilder
    private func connectionList(_ list: [LiveConnection]) -> some View {
        if sheetChrome {
            // v0.2.128 item 1: the sheet's list was a SwiftUI List
            // (.insetGrouped), whose section top inset left a large
            // blank area between the filter pills and the first row
            // (IMG_1356). The DNS sheet was converted to ScrollView
            // + LazyVStack for exactly this class of List-in-sheet
            // layout problem (v0.2.102) — this mirrors it: no top
            // padding, one rounded card per row, the zero-height
            // drag bridge first. Live rows lose swipe-to-disconnect
            // here (a List feature); the detail header's close
            // button keeps the function.
            ScrollView {
                LazyVStack(spacing: 12) {
                    SheetListDragPan(
                        onChanged: { if let onSheetDragChanged { onSheetDragChanged($0) } },
                        onEnded: { translation, velocity in
                            if let onSheetDragEnded { onSheetDragEnded(translation, velocity) }
                        }
                    )
                    .frame(height: 0)
                    // Flat list with per-minute separator rows
                    // (upstream RecordMinuteList): after each
                    // minute's records, a footnote row `HH:mm  N`
                    // (today) or `MM-DD HH:mm  N`.
                    ForEach(Array(connectionStore.minuteGroups(list).enumerated()), id: \.offset) { item in
                        ForEach(item.element.rows) { connection in
                            connectionCardButton(connection, isLive: connectionStore.isLive(connection.id))
                        }
                        minuteSeparatorRow(item.element)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 76)
            }
        } else {
            // Flat list with per-minute separator rows (upstream
            // RecordMinuteList): after each minute's records, a
            // footnote row `HH:mm  N` (today) or `MM-DD HH:mm  N`.
            List {
                sheetListDragBridge
                ForEach(Array(connectionStore.minuteGroups(list).enumerated()), id: \.offset) { item in
                    ForEach(item.element.rows) { connection in
                        connectionRowButton(connection, isLive: connectionStore.isLive(connection.id))
                    }
                    minuteSeparatorRow(item.element)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // v0.2.66: tab-bar clearance for pushed pages.
            .contentMargins(.bottom, sheetChrome ? 76 : (applyTabBarClearance ? ConcordTheme.tabBarClearance : 0))
        }
    }

    /// One row's Button: opens the detail sheet, swipe-to-
    /// disconnect on live rows, context menu (upstream
    /// trackerInfoMenuItems).
    private func connectionRowButton(_ connection: LiveConnection, isLive: Bool) -> some View {
        Button { openDetail(connection, isLive: isLive) } label: {
            connectionRow(connection, isLive: isLive)
        }
        .buttonStyle(.plain)
        .listRowBackground(ConcordTheme.cardBackground)
        .contextMenu { rowContextMenu(connection, isLive: isLive) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isLive {
                Button("断开", role: .destructive) {
                    Task { await connectionStore.close(connection) }
                }
            }
        }
    }

    /// One row as a rounded card (sheet mode, v0.2.128 item 1):
    /// the same Button (tap → detail) as connectionRowButton,
    /// but the row is a card (cardBackground, radius 16 — the DNS
    /// sheet's row radius) and there are no swipe actions (a List
    /// feature). The detail header's close button keeps the
    /// disconnect function for live rows.
    private func connectionCardButton(_ connection: LiveConnection, isLive: Bool) -> some View {
        Button { openDetail(connection, isLive: isLive) } label: {
            connectionRow(connection, isLive: isLive)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu { rowContextMenu(connection, isLive: isLive) }
    }

    /// Opens the detail on the 时间线 tab (the row menu's "查看
    /// HTTP" opens it on the HTTP tab instead — see rowContextMenu).
    private func openDetail(_ connection: LiveConnection, isLive: Bool) {
        detail = connection
        detailIsLive = isLive
        detailOpensRequests = false
    }

    /// The row context menu (upstream tracker_info_item.dart
    /// trackerInfoMenuItems): close (active only), copy host /
    /// copy destination, only-this-app, hide-this-host, view-HTTP
    /// (when MITM — the detail then opens on the HTTP tab).
    @ViewBuilder
    private func rowContextMenu(_ connection: LiveConnection, isLive: Bool) -> some View {
        if isLive {
            Button("断开连接", role: .destructive) {
                Task { await connectionStore.close(connection) }
            }
        }
        if let host = connection.host, !host.isEmpty {
            Button("复制主机") {
                UIPasteboard.general.string = host
            }
        }
        Button("复制目标") {
            UIPasteboard.general.string = connection.destination
        }
        if let process = connection.process, !process.isEmpty {
            Button("仅看此应用") {
                connectionStore.facetProcesses = [process]
            }
        }
        Button("隐藏此主机") {
            let title = connection.host ?? connection.destinationIp ?? connection.destination
            connectionStore.conditions.append(
                ConnectionCondition(field: .host, value: title, op: .notContains))
        }
        if connection.mitm {
            Button("查看 HTTP") {
                detail = connection
                detailIsLive = isLive
                detailOpensRequests = true
            }
        }
    }

    /// Per-minute separator row (upstream RecordMinuteHeader,
    /// record_minute_list.dart): the minute label, emphasized,
    /// followed by the count in that minute.
    private func minuteSeparatorRow(_ group: ConnectionMinuteGroup) -> some View {
        Text("\(ConnectionStore.minuteLabel(group.minute))  \(group.rows.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .listRowBackground(ConcordTheme.cardBackground)
    }

    /// One connection row (upstream tracker_info_item.dart):
    /// 40pt app well leading; title host (else destination
    /// ip:port); subtitle `process · chains.last · lifetime`,
    /// ticking every second on the 1 s poll (failed dials show
    /// `process · failure-kind`, error-red, with no lifetime);
    /// failure chip, `×N` repeats and MITM label after the
    /// subtitle; trailing ONE combined (up+down)/s line + total
    /// below while active, the total as the only line when closed.
    /// No rule, no chain capsules, no source line on the mobile
    /// row — those live in the detail / timeline.
    private func connectionRow(_ connection: LiveConnection, isLive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ConnectionAppWell(connection: connection, isLive: isLive)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.hostPort(connection))
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(rowSubtitle(connection, isLive: isLive))
                        .font(.caption)
                        .foregroundStyle(connection.failureKind != nil ? .red : .secondary)
                        .lineLimit(1)
                    rowLabels(connection)
                }
            }
            Spacer(minLength: 8)
            rowTraffic(connection, isLive: isLive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// The row subtitle (upstream tracker_info_item.dart:105-150
    /// + tracker_texts.dart trackerLifetimeText). The lifetime
    /// ticks because the 1 s poll re-publishes the store and this
    /// row re-renders.
    private func rowSubtitle(_ connection: LiveConnection, isLive: Bool) -> String {
        if let failureKind = connection.failureKind {
            return [connection.process, ConcordConnectionFailure.label(for: failureKind)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let lifetime: String
        if isLive {
            lifetime = timelineLiveLifetime(start: connection.start, now: Date())
        } else {
            let endedAt = connection.endedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            lifetime = timelineLifetimeText(start: connection.start, endedAt: endedAt, now: Date())
        }
        return [connection.process, connection.chains.last, lifetime]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The row labels (upstream tracker_texts.dart trackerLabels):
    /// failure-kind chip, `×N` repeat count, MITM label.
    @ViewBuilder
    private func rowLabels(_ connection: LiveConnection) -> some View {
        if let failureKind = connection.failureKind {
            rowLabelChip(ConcordConnectionFailure.label(for: failureKind), tone: .red)
        }
        if connection.repeatCount > 1 {
            rowLabelChip("×\(connection.repeatCount)", tone: .secondary)
        }
        if connection.mitm {
            rowLabelChip("MITM", tone: .secondary)
        }
    }

    private func rowLabelChip(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.opacity(0.12), in: Capsule())
            .foregroundStyle(tone)
    }

    /// The trailing traffic (upstream tracker_info_item.dart
    /// TrackerTraffic): active → ONE combined `(up+down)/s` line
    /// (emphasized) + total below; closed → the total as the
    /// only line.
    @ViewBuilder
    private func rowTraffic(_ connection: LiveConnection, isLive: Bool) -> some View {
        let total = connection.upload + connection.download
        if isLive {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ConcordFormat.rate(Int64(connection.upSpeed + connection.downSpeed)))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .monospacedDigit()
                Text(ConcordFormat.bytes(total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text(ConcordFormat.bytes(total))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The row's / detail header's app well (upstream
/// tracker_app_well.dart TrackerAppWell, size 40): the process's
/// bundled brand mark when the compacted process name matches one
/// (BrandIcons, the resolution already in the tree), else a letter
/// tile with the process's (or host's) first character. A green dot
/// marks an active connection.
private struct ConnectionAppWell: View {
    let connection: LiveConnection
    let isLive: Bool

    var body: some View {
        let process = connection.process ?? ""
        let fallback = process.isEmpty ? (connection.host ?? connection.destination) : process
        let initial = String(fallback.prefix(1)).uppercased()
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                if let brand = !process.isEmpty ? BrandIcons.icon(for: process) : nil {
                    BrandIcons.view(for: brand)
                        .padding(9)
                        .foregroundStyle(Color(.label))
                } else {
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            if isLive {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// The add-condition editor (upstream
/// connection_condition_form.dart): field picker, value field with
/// suggestions (value + how many rows hold it), match picker
/// (包含 / 不包含 / 等于 / 不等于）, and a live "将匹配 N 条" count.
private struct ConnectionConditionEditor: View {
    @ObservedObject var store: ConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var field: ConnectionCondition.Field = .host
    @State private var op: ConnectionCondition.Op = .contains
    @State private var value = ""

    private var draft: ConnectionCondition {
        ConnectionCondition(field: field, value: value.trimmingCharacters(in: .whitespaces), op: op)
    }

    private var suggestions: [(value: String, count: Int)] {
        store.suggestedValues(for: field, matching: value)
    }

    /// Rows the draft would keep (upstream FieldDraft.countWith):
    /// an excluding draft keeps everything it does not hold.
    private var matchCount: Int {
        let total = store.connections.count + store.recentConnections.count
        let held = store.countMatching(draft)
        return draft.excludes ? total - held : held
    }

    var body: some View {
        NavigationStack {
            List {
                Section("字段") {
                    Picker("字段", selection: $field) {
                        ForEach(ConnectionCondition.Field.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                }
                Section("匹配") {
                    Picker("方式", selection: $op) {
                        ForEach(ConnectionCondition.Op.allCases) { op in
                            Text(op.rawValue).tag(op)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("值") {
                    TextField("值", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !suggestions.isEmpty {
                    Section("建议") {
                        ForEach(suggestions, id: \.value) { suggestion in
                            Button {
                                value = suggestion.value
                            } label: {
                                HStack {
                                    Text(suggestion.value)
                                        .foregroundStyle(Color(.label))
                                    Spacer()
                                    Text("\(suggestion.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("将匹配 \(matchCount) 条连接")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("添加筛选条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        store.conditions.append(draft)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct ConnectionDetailView: View {
    /// The connection as opened. The detail is LIVE, not a frozen
    /// snapshot (upstream TrackerSelectedDetail watches the log):
    /// `liveConnection` below re-reads the id from the store on
    /// every poll, so totals/speeds refresh, and the sheet drops
    /// itself when the id leaves the log (upstream _dropGone).
    let connection: LiveConnection
    /// False for a finished connection: there is nothing to close.
    /// Only the opening value — liveness is re-read from the store.
    var isLive: Bool = true
    /// Open on the HTTP tab (upstream opensRequests): the row
    /// menu's "查看 HTTP" sets it; the tab flips once the detail
    /// knows MITM is capturing (see the .task below).
    var opensRequests: Bool = false
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var client: ConcordClient
    @Environment(\.dismiss) private var dismiss

    /// The MITM host change awaiting confirmation (upstream
    /// applyMitmHostChange shows a confirm dialog first).
    @State private var pendingMitmHostChange: MitmHostChange?
    @State private var showMitmHostConfirm = false

    /// The connection as the store holds it now: the live table,
    /// else the recent list, else the opening snapshot (a
    /// connection cleared from the log keeps the state it was last
    /// seen in — upstream showTrackerInfoDetail).
    private var liveConnection: LiveConnection {
        connectionStore.connections.first { $0.id == connection.id }
            ?? connectionStore.recentConnections.first { $0.id == connection.id }
            ?? connection
    }

    /// Whether the id is still open (upstream TrackerInfo.isActive).
    private var liveIsLive: Bool {
        connectionStore.connections.contains { $0.id == connection.id }
    }

    /// Whether the id left the log entirely (upstream _dropGone).
    private var isGone: Bool {
        !liveIsLive
            && !connectionStore.recentConnections.contains { $0.id == connection.id }
    }

    /// A MITM host change (upstream tracker_mitm_host.dart
    /// MitmHostChange): decrypt this host, or exclude it from
    /// decryption. `exclude` puts `-host` first in the hostname
    /// list; decrypt puts `host` first (first match decides).
    private struct MitmHostChange {
        let title: String
        let tip: String
        let exclude: Bool
    }

    /// Whether decrypting / excluding this connection's host can
    /// be done from here (upstream mitmHostChangeOf): MITM
    /// enabled + a host + TCP. A decrypted host (or one already
    /// listed) offers exclusion; anything else offers decryption.
    private func mitmHostChange(for c: LiveConnection) -> MitmHostChange? {
        guard settingsStore.mitmEnabled,
              let host = c.host, !host.isEmpty,
              c.network.lowercased() == "tcp" else { return nil }
        let hostnames = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let decrypted = c.mitm || c.mitmRefused
        if !hostnames.contains("-\(host)") && (decrypted || hostnames.contains(host)) {
            return MitmHostChange(
                title: "排除此域名",
                tip: "将 \(host) 加入排除列表，之后不再解密此域名的流量。",
                exclude: true)
        }
        return MitmHostChange(
            title: "解密此域名",
            tip: "将 \(host) 加入解密列表，之后会解密此域名的流量。",
            exclude: false)
    }

    /// Applies a confirmed host change (upstream applyMitmHostChange):
    /// the host goes first in the hostname list, as `host` or
    /// `-host`, and the settings save like the MITM page's own
    /// hostname edits (takes effect on the next apply / VPN restart).
    private func applyMitmHostChange(_ change: MitmHostChange, host: String) {
        var hostnames = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        hostnames.removeAll { $0 == host || $0 == "-\(host)" }
        hostnames.insert(change.exclude ? "-\(host)" : host, at: 0)
        settingsStore.mitmHostnames = hostnames.joined(separator: ", ")
        settingsStore.save()
    }

    /// Upstream tracker_info_detail.dart: the detail page has
    /// three tabs in order — 时间线, HTTP 请求 (only while MITM
    /// captures), 信息. "概览" maps to upstream's "信息".
    private enum DetailTab: String, CaseIterable {
        case timeline = "时间线"
        case http = "HTTP 请求"
        case info = "信息"
    }

    @State private var tab = DetailTab.timeline

    /// The timeline's once-per-open inputs: the rule-list check
    /// and the MITM exchanges (see loadTimelineSupport).
    @State private var standingRuleIndex: Int?
    @State private var httpExchanges: [MitmExchangeSummary] = []
    @State private var timelineSupportLoaded = false

    /// The tabs the picker offers: all three while MITM captures,
    /// otherwise 时间线 + 信息 (upstream always shows the tab bar
    /// when there are 2+ tabs).
    private var visibleTabs: [DetailTab] {
        showHttpTab ? DetailTab.allCases : [.timeline, .info]
    }

    /// The HTTP Requests tab exists only while MITM is capturing
    /// for this connection (upstream tracker_info_item.dart:
    /// capturing = metadata.mitm && mitm.enable && mitm.capture).
    private var showHttpTab: Bool {
        liveConnection.mitm && settingsStore.mitmEnabled && settingsStore.mitmCapture
    }

    /// The detail header (upstream tracker_selection.dart
    /// TrackerInfoHeader): app well, headline (host; subtitle
    /// process · exit · lifetime), close button (active only, on
    /// every tab) + ⋯ menu.
    private var detailHeader: some View {
        HStack(spacing: 12) {
            ConnectionAppWell(connection: liveConnection, isLive: liveIsLive)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectionsView.detailTitle(liveConnection))
                    .font(.headline)
                    .lineLimit(1)
                headlineText(liveConnection)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            if liveIsLive {
                Button {
                    Task {
                        await connectionStore.close(liveConnection)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("断开连接")
            }
            Menu {
                detailMenuItems(liveConnection)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// The headline (upstream tracker_texts.dart
    /// trackerHeadlineParts): process, exit node, then 活动 +
    /// ticking lifetime while open, 连接失败 (red) + lifetime on a
    /// failed dial, 已关闭 once closed. The lifetime ticks on the
    /// detail's 1 s poll below.
    private func headlineText(_ c: LiveConnection) -> Text {
        var parts: [(String, Bool)] = []
        if let process = c.process, !process.isEmpty {
            parts.append((process, false))
        }
        if let exit = c.chains.first, !exit.isEmpty {
            parts.append((exit, false))
        }
        if c.failureKind != nil {
            parts.append(("连接失败", true))
            let endedAt = c.endedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            parts.append((timelineLifetimeText(start: c.start, endedAt: endedAt, now: Date()), false))
        } else if liveIsLive {
            parts.append(("活动 \(timelineLiveLifetime(start: c.start, now: Date()))", false))
        } else {
            parts.append(("已关闭", false))
        }
        var text = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text = text + Text(" · ").foregroundStyle(.secondary)
            }
            text = text + Text(part.0).foregroundStyle(part.1 ? .red : .secondary)
        }
        return text
    }

    /// The detail ⋯ menu (upstream tracker_menu.dart
    /// trackerDetailMenuItems): copy host / destination / summary,
    /// MITM decrypt-or-exclude host (with confirm).
    @ViewBuilder
    private func detailMenuItems(_ c: LiveConnection) -> some View {
        if let host = c.host, !host.isEmpty {
            Button("复制主机") {
                UIPasteboard.general.string = host
            }
        }
        Button("复制目标") {
            UIPasteboard.general.string = c.destination
        }
        Button("复制摘要") {
            UIPasteboard.general.string = summaryText(c)
        }
        if let change = mitmHostChange(for: c) {
            Button(change.title) {
                pendingMitmHostChange = change
                showMitmHostConfirm = true
            }
        }
    }

    /// The copyable summary (upstream tracker_texts.dart
    /// trackerSummaryText): title, headline, source, destination,
    /// process path, rule, path, failure.
    private func summaryText(_ c: LiveConnection) -> String {
        var lines = [ConnectionsView.detailTitle(c)]
        var headlineParts: [String] = []
        if let process = c.process, !process.isEmpty {
            headlineParts.append(process)
        }
        if let exit = c.chains.first, !exit.isEmpty {
            headlineParts.append(exit)
        }
        if c.failureKind != nil {
            headlineParts.append("连接失败")
        } else if liveIsLive {
            headlineParts.append("活动 \(timelineLiveLifetime(start: c.start, now: Date()))")
        } else {
            headlineParts.append("已关闭")
        }
        lines.append(headlineParts.joined(separator: " · "))
        for (label, value) in [
            ("来源", "\(c.sourceIp):\(c.sourcePort)"),
            ("目标", c.destination),
            ("进程路径", c.processPath ?? ""),
            ("规则", ruleText(c)),
            ("路径", Array(c.chains.reversed()).joined(separator: " → ")),
        ] where !value.isEmpty {
            lines.append("\(label)：\(value)")
        }
        if let kind = c.failureKind {
            lines.append("\(ConcordConnectionFailure.label(for: kind))：\(c.failureMessage ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                detailHeader
                Picker("详情", selection: $tab) {
                    ForEach(visibleTabs, id: \.self) { tab in
                        Text(tabLabel(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)
                if tab == .http && showHttpTab {
                    MitmView(connectionId: liveConnection.id)
                } else if tab == .timeline {
                    ConnectionTimelineView(
                        connection: liveConnection,
                        isLive: liveIsLive,
                        dnsEntries: resolvedDnsEntries,
                        exchanges: httpExchanges,
                        nodeDelayMs: nodeDelayMs,
                        pickedGroupType: pickedGroup?.type,
                        standingRuleIndex: standingRuleIndex,
                        // Upstream disables the HTTP step once the
                        // connection ended (capturing && !ended).
                        onOpenRequests: showHttpTab && liveIsLive ? { self.tab = .http } : nil
                    )
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
            .alert("\(pendingMitmHostChange?.title ?? "确认")", isPresented: $showMitmHostConfirm) {
                Button("确定") {
                    if let change = pendingMitmHostChange,
                       let host = liveConnection.host {
                        applyMitmHostChange(change, host: host)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pendingMitmHostChange?.tip ?? "")
            }
            .onChange(of: isGone) { _, gone in
                if gone { dismiss() }
            }
            .onChange(of: tab) { _, newTab in
                // Re-read the exchange count when the HTTP tab is
                // shown, so its label stays current (upstream
                // watches mitmExchangesProvider).
                if newTab == .http && showHttpTab {
                    Task {
                        if let list = try? await client.mitmExchanges(connection: connection.id) {
                            httpExchanges = list.result.exchanges
                        }
                    }
                }
            }
            // Load the DNS entries so the DNS 查询 row above can
            // resolve the connection's dnsQueries ids to domains,
            // plus the timeline's once-per-open inputs. Then keep
            // the detail live on the same 1 s poll as the page
            // (upstream TrackerSelectedDetail watches the log);
            // the poll stops when the sheet drops or closes.
            .task {
                await dnsStore.refresh()
                await loadTimelineSupport()
                if opensRequests && showHttpTab {
                    tab = .http
                }
                guard !isGone else { dismiss(); return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    guard TunnelManager.shared.isRunning || AppCore.shared.isRunning else { continue }
                    await connectionStore.refresh()
                    if isGone { break }
                }
            }
        }
    }

    /// A tab's label: the HTTP tab shows the exchange count when
    /// above zero (upstream tracker_info_detail.dart:288-293).
    private func tabLabel(_ tab: DetailTab) -> String {
        if tab == .http && !httpExchanges.isEmpty {
            return "HTTP 请求 \(httpExchanges.count)"
        }
        return tab.rawValue
    }

    /// The connection's DNS queries, newest first (upstream
    /// `_LinkedQueries.of`: the dns.watch log, newest first;
    /// DnsStore.entries is already newest-first).
    private var resolvedDnsEntries: [ConcordDnsEntry] {
        let ids = Set(liveConnection.dnsQueries)
        return dnsStore.entries.filter { ids.contains($0.dnsId) }
    }

    /// The group that picked this connection's node (upstream
    /// `groupsProvider.getGroup(chains[1])`).
    private var pickedGroup: ProxyGroup? {
        guard liveConnection.chains.count > 1 else { return nil }
        return proxyStore.groups.first { $0.name == liveConnection.chains[1] }
    }

    /// The picked node's last tested delay (upstream
    /// `delayProvider(proxyName: chains.first, testUrl:
    /// pickedBy?.testUrl)`), via the store's existing lookup.
    private var nodeDelayMs: Int32? {
        guard let group = pickedGroup, let node = liveConnection.chains.first else { return nil }
        return proxyStore.latency(forNodeNamed: node, inGroup: group)
    }

    /// Once when the detail opens (upstream `_standingRuleIndex`):
    /// verify the rule at `ruleIndex` is still the same rule
    /// (type + payload) against the current rule table, and fetch
    /// the MITM exchanges for the timeline's HTTP step. When the
    /// rule list cannot be read at all, the raw index is shown
    /// instead of hiding the number.
    private func loadTimelineSupport() async {
        guard !timelineSupportLoaded else { return }
        timelineSupportLoaded = true
        if let index = connection.ruleIndex {
            if let list = try? await client.ruleList() {
                let idx = Int(index)
                if idx >= 0, idx < list.rules.count,
                   list.rules[idx].type == (connection.rule ?? ""),
                   list.rules[idx].payload == (connection.rulePayload ?? "") {
                    standingRuleIndex = idx
                } else {
                    standingRuleIndex = nil
                }
            } else {
                standingRuleIndex = Int(index)
            }
        }
        if showHttpTab {
            if let list = try? await client.mitmExchanges(connection: connection.id) {
                httpExchanges = list.result.exchanges
            }
        }
    }

    /// Overview tab (upstream tracker_info_item.dart _buildOverview):
    /// path section (process / rule / per-hop chain), traffic
    /// summary with live speeds, MITM host action, address
    /// (GeoIP/ASN/remote destination).
    private var overviewList: some View {
        // The live connection, not the opening snapshot.
        let connection = liveConnection
        return List {
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
                LabeledContent("规则", value: ruleText(connection))
                LabeledContent("代理", value: connection.proxy ?? "—")
                LabeledContent("持续", value: ConcordFormat.duration(seconds: connection.durationSeconds))
                if liveIsLive {
                    // Upstream TrackerTrafficSummary shows live
                    // speeds while the connection is open.
                    LabeledContent("实时速度", value: ConcordFormat.rate(Int64(connection.upSpeed + connection.downSpeed)))
                }
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
            // Upstream shows no timing or end sections in the
            // overview (the timing lives in the timeline; the end
            // reason lives in the timeline's status note).
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
            // The path (upstream tracker_info_detail.dart
            // TrackerPathSection): process row, rule row, then one
            // row per hop — group hops "代理组 · 类型", node hops
            // "代理节点 · 类型" + trailing delay ms.
            Section("路径") {
                if connection.process != nil || (connection.uid ?? 0) != 0 {
                    let processTitle: String = {
                        if let process = connection.process, !process.isEmpty { return process }
                        return "\(connection.uid ?? 0)"
                    }()
                    let uidSuffix: String = {
                        if let uid = connection.uid, uid != 0 { return " · UID \(uid)" }
                        return ""
                    }()
                    pathRow(title: processTitle, subtitle: "进程\(uidSuffix)")
                }
                pathRow(title: ruleText(connection), subtitle: "规则")
                ForEach(Array(connection.chains.reversed().enumerated()), id: \.offset) { _, name in
                    if let group = proxyStore.groups.first(where: { $0.name == name }) {
                        pathRow(title: name, subtitle: "代理组 · \(group.type)")
                    } else {
                        let type = proxyStore.groups.flatMap { $0.nodes }.first(where: { $0.name == name })?.type
                        let delay = name == connection.chains.first ? nodeDelayMs : nil
                        pathRow(title: name, subtitle: type.map { "代理节点 · \($0)" } ?? "代理节点", delayMs: delay)
                    }
                }
            }
            if let change = mitmHostChange(for: connection) {
                // Upstream tracker_mitm_host.dart MitmHostSection:
                // decrypt / exclude this host (confirm first) +
                // the refused-certificate footer.
                Section("HTTPS 解密") {
                    Button(change.title) {
                        pendingMitmHostChange = change
                        showMitmHostConfirm = true
                    }
                    if connection.mitmRefused {
                        Text("客户端拒绝了证书")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showHttpTab {
                Section {
                    NavigationLink("MITM 拦截记录（mitm.exchanges）") {
                        MitmView(connectionId: connection.id)
                    }
                    Text("断开调用 connection.close；拦截记录调用 mitm.exchanges，需要 MITM 已开启并正在捕获。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// One path row: title + subtitle, optional trailing delay.
    private func pathRow(title: String, subtitle: String, delayMs: Int32? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let delayMs, delayMs > 0 {
                Text("\(delayMs) ms")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Rule with its matched payload (upstream TrackerRuleText:
    /// rule + rulePayload).
    private func ruleText(_ connection: LiveConnection) -> String {
        guard let rule = connection.rule else { return "—" }
        if let payload = connection.rulePayload, !payload.isEmpty {
            return "\(rule) (\(payload))"
        }
        return rule
    }

    /// The connection's DNS queries, resolved to domain + type
    /// against the DNS store when it has loaded them.
    private var dnsQueryText: String {
        liveConnection.dnsQueries.map { id in
            if let entry = dnsStore.entries.first(where: { $0.dnsId == id }) {
                return "#\(id) \(entry.domain) \(entry.type)"
            }
            return "#\(id)"
        }.joined(separator: " · ")
    }
}

/// The MuYu bottom floating search bar (v0.2.68): a rounded bar
/// with a magnifier + TextField, overlaid at the bottom of the
/// sheet list. Drives the store's searchText, same as the page's
/// top .searchable did.
private struct ConnectionFloatingSearchBar: View {
    @Binding var text: String
    let prompt: String
    /// Runs on submit (return key): the HTTP segment re-queries.
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(.footnote)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { onSubmit?() }
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
