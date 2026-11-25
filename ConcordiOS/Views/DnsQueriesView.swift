import SwiftUI

// DnsQueriesView — moved out of SettingsView.swift in v0.2.68 (no behaviour change).
// The Dashboard stats sheet and the Tools > DNS查询 page share this view; the sheet
// presents it in records-only mode, the Tools page with the manual query + filters.

/// DNS capsule fill (v0.2.82): neutral grey measured from the MuYu
/// video DNS sheet (#B8B8B8, dominant fill tone in f_014). The video's
/// type ([A]/[AAAA]), initiator （其他/代理） and cache （缓存） capsules
/// are all this grey — not blue/orange, and NOT the theme accent (they
/// stay grey under the magenta theme). Fixed grey: dark text reads well
/// on it in both light and dark mode.
fileprivate let dnsCapsuleFill = Color(red: 184/255, green: 184/255, blue: 184/255)

// MARK: - DNS queries (FlClash: DnsQueriesView, lib/views/dns_queries.dart)

/// Record-list filter: all, failed only, cache hits, live lookups.
private enum DnsRecordFilter: String, CaseIterable {
    case all, errors, cached, live

    var title: String {
        switch self {
        case .all: return "全部"
        case .errors: return "错误"
        case .cached: return "缓存命中"
        case .live: return "实时查询"
        }
    }

    func matches(_ entry: ConcordDnsEntry) -> Bool {
        switch self {
        case .all: return true
        case .errors: return DnsErrorRow.isFailed(entry)
        case .cached: return entry.cached == true
        case .live: return entry.cached != true
        }
    }
}

/// One displayed DNS row after folding (C10): the newest entry of
/// a run of identical consecutive rows, plus how many it stands for.
/// v0.2.111: the identity is "\(entry.id)-\(entry.seq)" — entry.id
/// alone ("\(time)-\(domain)-\(type)") is NOT unique (same-ms
/// same-domain+type queries share it) and ForEach with duplicate
/// ids is undefined behaviour in SwiftUI. seq is assigned once at
/// first sight by DnsStore and preserved across merges, so the
/// identity is unique and stable for the same logical entry.
private struct FoldedDnsEntry: Identifiable {
    var id: String { "\(entry.id)-\(entry.seq)" }
    let entry: ConcordDnsEntry
    let count: Int
}

struct DnsQueriesView: View {
    /// Presentation mode (v0.2.68): `.page` is the Tools /
    /// Settings pushed page (manual query + filters); `.sheet`
    /// is the Dashboard stats sheet (records only, own MuYu
    /// header + bottom floating search bar).
    enum Mode {
        case page
        case sheet
    }

    let mode: Mode

    /// Dismiss action for sheet mode (v0.2.111): the DNS sheet is
    /// a custom overlay at the ContentView root, not a system
    /// sheet, so @Environment(\.dismiss) does nothing there — the
    /// overlay passes its own close action. Nil (default) keeps
    /// the old dismiss() behaviour.
    let onClose: (() -> Void)?

    /// Sheet-drag callbacks (v0.2.114): the ContentView overlay
    /// passes these so the sheet's drag gesture lives on the
    /// header only — never on the sheet container. A .gesture on
    /// the container (v0.2.111–113) captured every vertical drag
    /// and the list ScrollView never scrolled (the user's
    /// v0.2.113 video: swipe-up did nothing). The header and the
    /// list are siblings, so a gesture on the header can never
    /// block the list. Nil (default) = no sheet-drag gesture
    /// (page mode never renders the header).
    let onSheetDragChanged: ((CGFloat) -> Void)?
    let onSheetDragEnded: ((CGFloat) -> Void)?

    init(mode: Mode = .page, onClose: (() -> Void)? = nil,
         onSheetDragChanged: ((CGFloat) -> Void)? = nil,
         onSheetDragEnded: ((CGFloat) -> Void)? = nil) {
        self.mode = mode
        self.onClose = onClose
        self.onSheetDragChanged = onSheetDragChanged
        self.onSheetDragEnded = onSheetDragEnded
        // v0.2.103: follow starts ON in both modes. Sheet mode
        // no longer scrolls at all (no .onChange / ScrollViewReader
        // in the sheet branch — Connections parity), so there is
        // nothing to gate; page mode follows from the start, as
        // before.
        self._followEnd = State(initialValue: true)
    }

    @EnvironmentObject private var dnsStore: DnsStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: ConcordClient
    @State private var queryName = ""
    @State private var queryType = "A"
    @State private var selectedEntry: ConcordDnsEntry?
    @State private var recordFilter: DnsRecordFilter = .all
    /// Record-type facet (FlClash dns_queries.dart: the type facet
    /// of dnsQueryFacets): the types present in the current list.
    @State private var selectedType: String?
    /// Initiator + rcode facets (FlClash dnsQueryFacets,
    /// common.dart:368-383): the initiators / response codes present
    /// in the current list. Upstream offers type / initiator /
    /// cache / rcode; cache is already covered by the segmented
    /// filter above.
    @State private var selectedInitiator: String?
    @State private var selectedRcode: String?
    /// Follow mode (FlClash dns_queries.dart:57-59
    /// FollowEndScrollPhysics, autoScrollToEnd): while on, a new
    /// record scrolls the list back to the newest row. Our list is
    /// newest-first, so "end" here is the top. Turn it off before
    /// scrolling down to read older rows.
    /// Page mode only (v0.2.103): the sheet branch never scrolls.
    @State private var followEnd: Bool

    /// v0.2.103: the v0.2.101 sheet-presentation machinery is
    /// gone — sheetPresented (0.6s .onAppear gate), sheetAtTop
    /// (row .onAppear/.onDisappear tracking) and the follow
    /// switch-on after presentation were all suspects in the
    /// presentation-time layout/state feedback loop that froze
    /// the app on the DNS tap (v0.2.102 watchdog proof). The
    /// sheet branch now has no ScrollViewReader, no .task, no
    /// .onChange and no .onAppear timer — structurally identical
    /// to the Connections sheet, which never froze — and sheet
    /// mode never scrolls. followEnd is page-mode only now.

    /// Search text first (DnsStore.filtered), then the group filter,
    /// then the record-type / initiator / rcode facets.
    private var visibleEntries: [ConcordDnsEntry] {
        dnsStore.filtered.filter { recordFilter.matches($0) }
            .filter { selectedType == nil || $0.type == selectedType }
            .filter { selectedInitiator == nil || $0.initiator == selectedInitiator }
            .filter { selectedRcode == nil || $0.rcode == selectedRcode }
    }

    /// Consecutive identical rows folded for display only (C10):
    /// repeated queries flood the list. The stored entries are
    /// untouched — only the rows shown are grouped, newest first.
    /// One row + a ×N badge stands for N identical consecutive rows.
    private var foldedEntries: [FoldedDnsEntry] {
        var folded: [FoldedDnsEntry] = []
        for entry in visibleEntries {
            if let last = folded.last, Self.sameQuery(last.entry, entry) {
                folded[folded.count - 1] = FoldedDnsEntry(entry: last.entry, count: last.count + 1)
            } else {
                folded.append(FoldedDnsEntry(entry: entry, count: 1))
            }
        }
        return folded
    }

    /// Two rows are the same query when everything the row shows
    /// matches (time and delay excluded — each query has its own).
    private static func sameQuery(_ a: ConcordDnsEntry, _ b: ConcordDnsEntry) -> Bool {
        a.domain == b.domain && a.type == b.type && a.initiator == b.initiator
            && a.upstream == b.upstream && a.cached == b.cached
            && a.answers == b.answers && a.rcode == b.rcode && a.error == b.error
    }

    private var availableTypes: [String] {
        Array(NSOrderedSet(array: dnsStore.filtered.map { $0.type })) as? [String] ?? []
    }

    private var availableInitiators: [String] {
        Array(NSOrderedSet(array: dnsStore.filtered.map { $0.initiator }.filter { !$0.isEmpty })) as? [String] ?? []
    }

    private var availableRcodes: [String] {
        Array(NSOrderedSet(array: dnsStore.filtered.compactMap { $0.rcode }.filter { !$0.isEmpty })) as? [String] ?? []
    }

    /// Scrolls to the newest row (the top: the list is
    /// newest-first). Called when follow mode is on and a new
    /// record arrives, or when follow mode is just turned on.
    /// Page mode only — the sheet branch has no ScrollViewReader
    /// and never scrolls (v0.2.103, Connections parity).
    /// v0.2.82 (DNS freeze): the scroll must never run
    /// synchronously inside onChange/layout — on iOS 17 an animated
    /// scrollTo fired from onChange while the sheet is presenting
    /// can wedge the List's layout and freeze the app (tapping
    /// DNS查询 on the Dashboard, VPN off). Deferring to the next
    /// runloop lets the current update/layout pass finish first.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard mode == .page else { return }
        if let id = foldedEntries.first?.id {
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    /// The MuYu sheet header (v0.2.68): drag handle, ✕ circle on
    /// the left (the page's chevron.left back arrow is wrong here),
    /// centred "DNS查询" (no space, no chevron), broom + ⋯ each in
    /// its own cardBackground circle on the right. No refresh
    /// button (the video has none).
    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            ZStack {
                Text("DNS查询")
                    .font(.headline)
                HStack {
                    // v0.2.111: in the ContentView overlay there is
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
                        Button {
                            Task { await dnsStore.clearEntries() }
                        } label: {
                            BroomIcon(size: 18)
                                .frame(width: 36, height: 36)
                                .background(ConcordTheme.cardBackground, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除记录")
                        Menu {
                            Picker("记录", selection: $recordFilter) {
                                ForEach(DnsRecordFilter.allCases, id: \.self) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                            Button("清除记录", role: .destructive) {
                                Task { await dnsStore.clearEntries() }
                            }
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
        // (sheetList), not an ancestor, so it can never capture a
        // drag that starts on the list — the list scrolls freely.
        // Dragging up here expands the sheet toward the 0.9
        // detent; dragging down steps back / dismisses (the
        // overlay owns those rules via the callbacks). A tap
        // (<8pt) still reaches the ✕ / broom / ⋯ buttons.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { if let onSheetDragChanged { onSheetDragChanged($0.translation.height) } }
                .onEnded { if let onSheetDragEnded { onSheetDragEnded($0.translation.height) } }
        )
    }

    /// The sheet's records-only list (v0.2.68; rebuilt v0.2.102):
    /// no manual query, no cache / Fake-IP buttons, no filter
    /// segment, no follow toggle + hint, no facet menus — just
    /// the folded records, with bottom clearance for the floating
    /// search bar.
    ///
    /// v0.2.102: this was a List (.insetGrouped +
    /// .scrollContentBackground(.hidden) + .refreshable +
    /// ScrollViewReader + .onChange, presented from a just-scrolled
    /// ScrollView) — the iOS 17.6.1 List-in-sheet presentation
    /// layout hang. Tapping DNS froze the app with the sheet never
    /// appearing, on v0.2.82/0.2.83/0.2.101, and scrollTo was
    /// disproven as the cause (the 0.6s gate was wired correctly;
    /// entries were empty, so the scroll never fired). MuYu's sheet
    /// never hangs because Flutter's list is a plain ListView with
    /// no UITableView — so ours is now the same kind of plain
    /// scrolling stack: ScrollView + LazyVStack, one white rounded
    /// card per record, exactly MuYu's layout. Page mode keeps its
    /// List (it never froze).
    private var sheetList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("DNS 记录为示例数据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                }
                if foldedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dnsStore.filtered.isEmpty ? "暂无 DNS 查询记录" : "没有符合筛选的记录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let error = dnsStore.lastError, dnsStore.filtered.isEmpty {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        } else if dnsStore.filtered.isEmpty, client.mode == .live, !TunnelManager.shared.isRunning {
                            // v0.2.103: the sheet does no appear
                            // refresh at all (no .task in sheet
                            // mode), so lastError is never set here
                            // — show the same reason statically
                            // instead of a bare "暂无记录".
                            Text("VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据")
                                .font(.caption2).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    ForEach(foldedEntries) { folded in
                        dnsSheetRow(folded)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                            .id(folded.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 76)
        }
    }

    /// One DNS row in the video's layout (v0.2.68): line 1 time +
    /// type capsule + ×N fold badge after the capsule + latency
    /// at the right; line 2 domain bold; line 3 bare answer IPs;
    /// line 4 initiator capsule + 缓存 capsule when cached + the
    /// bare upstream URL. No keyword chips in sheet mode.
    private func dnsSheetRow(_ folded: FoldedDnsEntry) -> some View {
        let entry = folded.entry
        return Button {
            selectedEntry = entry
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.fullDateTime(entry.time))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.type)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(dnsCapsuleFill, in: Capsule())
                    if folded.count > 1 {
                        Text("×\(folded.count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(dnsCapsuleFill, in: Capsule())
                    }
                    Spacer()
                    Text("\(entry.delay) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.domain)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if !entry.answers.isEmpty {
                    Text(entry.answers.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !entry.initiator.isEmpty {
                        Text(entry.initiator)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(dnsCapsuleFill, in: Capsule())
                    }
                    if entry.cached == true {
                        Text("缓存")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(dnsCapsuleFill, in: Capsule())
                    }
                    if !entry.upstream.isEmpty {
                        Text(entry.upstream)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = entry.error {
                    DnsErrorRow(error: error)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Shared formatter for the sheet rows ("2026-11-20 19:16:48"):
    /// DateFormatter setup is expensive, so one instance serves
    /// every call (main thread only — all callers are view code).
    private static let fullDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Full date-time for the sheet rows ("2026-11-20 19:16:48").
    private static func fullDateTime(_ epochMillis: Int64) -> String {
        fullDateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
    }

    var body: some View {
        // v0.2.103: the sheet and page branches have SEPARATE
        // modifier stacks. The sheet branch is structurally
        // identical to the Connections sheet (ZStack + floating
        // search + nested .sheet(item:) + .refreshable, detents
        // [9/16, 0.9] set by the Dashboard) — NO ScrollViewReader,
        // NO .task refresh, NO .onChange, NO .onAppear timer.
        // Those were the suspects in the presentation-time
        // layout/state feedback loop that froze the app on the
        // DNS tap (v0.2.102 watchdog proof: main-thread stall
        // starting at the tap). The sheet just displays whatever
        // dnsStore.entries holds (the Dashboard refreshes it);
        // pull-to-refresh still loads. Page mode (Tools → DNS)
        // never froze and keeps everything exactly as-is.
        Group {
            if mode == .sheet {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        sheetHeader
                        sheetList
                    }
                    .background(ConcordTheme.pageBackground)
                    DnsFloatingSearchBar(text: $dnsStore.searchText, prompt: "搜索域名或上游")
                }
                // v0.2.111: pull-to-refresh inside the sheet is a
                // user-initiated refresh — force: true publishes
                // immediately instead of deferring to the publish
                // suspension that is on while the sheet is open.
                .refreshable { await dnsStore.refresh(force: true) }
                .sheet(item: $selectedEntry) { entry in
                    DnsEntryDetailView(entry: entry)
                        // Upstream _showDnsQueryDetail → showSheet, snap
                        // detents [9/16, 0.9], drag handle, scrim dismiss
                        // (dns_queries.dart:233; MuYu: showNestedSheet).
                        .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                        .presentationDragIndicator(.visible)
                }
            } else {
                ScrollViewReader { proxy in
                    pageList(proxy: proxy)
                        .background(ConcordTheme.pageBackground)
                        .listStyle(.insetGrouped)
                        .navigationTitle("DNS 查询")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarBackButtonHidden(true)
                        .searchable(text: $dnsStore.searchText, prompt: "搜索域名或上游")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { dismiss() } label: {
                                    Image(systemName: "chevron.left")
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { Task { await dnsStore.refresh() } } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                        }
                        .refreshable { await dnsStore.refresh() }
                        .task {
                            // v0.2.82 (DNS freeze): with the VPN off in live mode
                            // the refresh can never succeed (dns.watch reads the
                            // extension snapshot only) — so skip it on appear and
                            // let the sheet open with zero store work. Pull-to-
                            // refresh and the toolbar button still load when the
                            // tunnel is up. Sample mode always refreshes
                            // (built-in sample data, no tunnel needed).
                            if dnsStore.entries.isEmpty
                                && (TunnelManager.shared.isRunning || client.mode == .sample) {
                                await dnsStore.refresh()
                            }
                        }
                        .onChange(of: foldedEntries.first?.id) { old, _ in
                            // v0.2.82 (DNS freeze): skip the initial population
                            // (nil -> first id) — the list is already at the top;
                            // only follow when a genuinely newer record arrives
                            // while viewing (old id non-nil -> new id).
                            if old != nil, followEnd {
                                scrollToNewest(proxy)
                            }
                        }
                        .sheet(item: $selectedEntry) { entry in
                            DnsEntryDetailView(entry: entry)
                                // Upstream _showDnsQueryDetail → showSheet, snap
                                // detents [9/16, 0.9], drag handle, scrim dismiss
                                // (dns_queries.dart:233; MuYu: showNestedSheet).
                                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                                .presentationDragIndicator(.visible)
                        }
                }
            }
        }
    }

    /// The pushed page's full list (manual query, cache actions,
    /// filter segment, follow toggle, facet menus, records).
    private func pageList(proxy: ScrollViewProxy) -> some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("DNS 记录为示例数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            Section("手动查询（dns.query）") {
                HStack {
                    TextField("域名，如 www.google.com", text: $queryName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker("类型", selection: $queryType) {
                        Text("A").tag("A")
                        Text("AAAA").tag("AAAA")
                        Text("MX").tag("MX")
                        Text("TXT").tag("TXT")
                        Text("CNAME").tag("CNAME")
                    }
                    .pickerStyle(.menu)
                }
                Button("查询") {
                    Task { await dnsStore.query(name: queryName, qtype: queryType) }
                }
                .disabled(queryName.trimmingCharacters(in: .whitespaces).isEmpty)
                if let result = dnsStore.queriedResult {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("返回码 \(result.rcode) · 应答 \(result.answers.count) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(result.answers, id: \.data) { record in
                            Text("\(record.name) → \(record.data)（TTL \(record.ttl)）")
                                .font(.caption2)
                        }
                        if !result.authorities.isEmpty {
                            Text("权威记录 \(result.authorities.count) 条")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = dnsStore.queryError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Section {
                Button("清除 DNS 缓存（dns.clearCache）") {
                    Task { await dnsStore.clearCache() }
                }
                Button("清除 Fake-IP 映射（dns.flushFakeIp）") {
                    Task { await dnsStore.flushFakeIp() }
                }
                if let message = dnsStore.lastActionMessage {
                    Text(message).font(.caption2).foregroundStyle(.green)
                }
                // Failures of the actions above (clear cache /
                // clear Fake-IP, or a VPN-off attempt) only wrote
                // lastError — render it here so the failure is
                // visible with its real reason (audit B16).
                if let error = dnsStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Section("查询记录（dns.watch）") {
                Picker("筛选", selection: $recordFilter) {
                    ForEach(DnsRecordFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("跟随最新", isOn: $followEnd)
                    .onChange(of: followEnd) { _, on in
                        if on { scrollToNewest(proxy) }
                    }
                Text("打开后新记录出现时回到顶部；向下翻看旧记录时请先关闭。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("记录类型")
                    Spacer()
                    Picker("记录类型", selection: $selectedType) {
                        Text("全部").tag(nil as String?)
                        ForEach(availableTypes, id: \.self) { type in
                            Text(type).tag(type as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("发起方")
                    Spacer()
                    Picker("发起方", selection: $selectedInitiator) {
                        Text("全部").tag(nil as String?)
                        ForEach(availableInitiators, id: \.self) { initiator in
                            Text(initiator).tag(initiator as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("返回码")
                    Spacer()
                    Picker("返回码", selection: $selectedRcode) {
                        Text("全部").tag(nil as String?)
                        ForEach(availableRcodes, id: \.self) { rcode in
                            Text(rcode).tag(rcode as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if visibleEntries.isEmpty {
                    Text(dnsStore.filtered.isEmpty ? "暂无 DNS 查询记录" : "没有符合筛选的记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // A failed refresh (e.g. VPN off) only wrote
                    // lastError — show the real reason instead of a
                    // bare "暂无记录" (audit B16).
                    if let error = dnsStore.lastError, dnsStore.filtered.isEmpty {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    } else if dnsStore.filtered.isEmpty, client.mode == .live, !TunnelManager.shared.isRunning {
                        // v0.2.82: the appear refresh is skipped with
                        // the VPN off (see .task above), so lastError
                        // is never set — same reason, statically.
                        Text("VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据")
                            .font(.caption2).foregroundStyle(.red)
                    }
                } else {
                    ForEach(foldedEntries) { folded in
                        let entry = folded.entry
                        Button {
                            selectedEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.domain).font(.footnote)
                                    if folded.count > 1 {
                                        Text("×\(folded.count)")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(dnsCapsuleFill, in: Capsule())
                                    }
                                    Spacer()
                                    Text(entry.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(dnsCapsuleFill, in: Capsule())
                                }
                                Text("上游 \(entry.upstream) · \(entry.delay) ms · \(entry.cached == true ? "缓存命中" : "实时查询")\(entry.initiator.isEmpty ? "" : " · 发起方 \(entry.initiator)")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("应答：\(entry.answers.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                // Keyword chips (FlClash _DnsKeyword):
                                // tapping one filters the list by it.
                                HStack(spacing: 6) {
                                    DnsKeywordChip(label: entry.type, isError: false) {
                                        toggleSearch(entry.type)
                                    }
                                    if let rcode = entry.rcode, !rcode.isEmpty {
                                        DnsKeywordChip(label: rcode, isError: DnsErrorRow.isFailed(entry)) {
                                            toggleSearch(rcode)
                                        }
                                    }
                                }
                                if let error = entry.error {
                                    DnsErrorRow(error: error)
                                }
                                Text(ConcordFormat.time(entry.time))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
    }

    /// Tapping a keyword chip filters by it; tapping it again clears.
    private func toggleSearch(_ keyword: String) {
        dnsStore.searchText = dnsStore.searchText == keyword ? "" : keyword
    }
}

/// A tappable keyword chip (FlClash _DnsKeyword): type or rcode.
/// Tapping filters the record list by that keyword.
private struct DnsKeywordChip: View {
    let label: String
    let isError: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isError ? Color.red.opacity(0.12) : dnsCapsuleFill, in: Capsule())
                .foregroundStyle(isError ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// A failed query's error line (FlClash _ErrorRow): red text,
/// tapping copies the error.
private struct DnsErrorRow: View {
    let error: String

    @State private var copied = false

    static func isFailed(_ entry: ConcordDnsEntry) -> Bool {
        entry.error != nil
            || (entry.rcode != nil && entry.rcode != "NOERROR" && entry.rcode != "NoError")
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = error
            copied = true
        } label: {
            HStack(spacing: 4) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                if copied {
                    Text("已复制")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One DNS query's full detail (FlClash: DnsQueriesView detail
/// sheet): time, domain, type, initiator, upstream, cached,
/// rcode, delay, answers, error, plus a copy button.
private struct DnsEntryDetailView: View {
    let entry: ConcordDnsEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("查询") {
                    detailRow("时间", ConcordFormat.time(entry.time))
                    detailRow("域名", entry.domain)
                    detailRow("类型", entry.type)
                    detailRow("发起方", entry.initiator)
                    detailRow("上游", entry.upstream)
                    detailRow("缓存", entry.cached == true ? "命中" : "未命中")
                    detailRow("返回码", entry.rcode ?? "—")
                    detailRow("延迟", "\(entry.delay) ms")
                }
                Section("应答") {
                    if entry.answers.isEmpty {
                        Text("无应答记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.answers, id: \.self) { answer in
                            Text(answer)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                // v0.2.86 (Item 3): the connections that used this
                // query (upstream dns_query_detail.dart, shown only
                // when non-empty — the sub-view hides itself).
                DnsRelatedConnectionsView(dnsId: entry.dnsId)
                if let error = entry.error {
                    Section("错误") {
                        DnsErrorRow(error: error)
                    }
                }
                Section {
                    Button(copied ? "已复制" : "复制详情") {
                        UIPasteboard.general.string = """
                        \(entry.domain) \(entry.type)
                        上游：\(entry.upstream)
                        返回码：\(entry.rcode ?? "—")
                        延迟：\(entry.delay) ms
                        应答：\(entry.answers.joined(separator: ", "))
                        """
                        copied = true
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("DNS 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The connections that used this DNS query (FlClash:
/// dns_query_detail.dart `相关的连接`,
/// related_connections.dart `RelatedConnectionRow`): the
/// connections whose `dnsQueries` contains this entry's id,
/// newest first (upstream connection_log.dart `resolvedBy`).
/// Hidden when the id is 0 (the core never sends one) or when
/// nothing references it. Tapping a row opens that
/// connection's detail, same as the Requests page.
private struct DnsRelatedConnectionsView: View {
    let dnsId: UInt64

    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var selected: LiveConnection?
    @State private var selectedIsLive = true

    /// Live + recent connections referencing this query, newest
    /// first. Upstream scans its full 2000-entry log; we scan
    /// the live table + the 200-entry recent list, so a very old
    /// connection may not appear.
    private var related: [(connection: LiveConnection, isLive: Bool)] {
        guard dnsId != 0 else { return [] }
        let liveIds = Set(connectionStore.connections.map(\.id))
        return (connectionStore.connections + connectionStore.recentConnections)
            .filter { $0.dnsQueries.contains(dnsId) }
            .sorted { $0.start > $1.start }
            .map { ($0, liveIds.contains($0.id)) }
    }

    var body: some View {
        Group {
            if !related.isEmpty {
                Section("相关的连接 \(related.count)") {
                    ForEach(related, id: \.connection.id) { item in
                        Button {
                            selected = item.connection
                            selectedIsLive = item.isLive
                        } label: {
                            relatedRow(item.connection, isLive: item.isLive)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selected) { connection in
            ConnectionDetailView(connection: connection, isLive: selectedIsLive)
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
    }

    /// One related row (upstream RelatedConnectionRow, minus the
    /// app icon — we have no app-icon source): process name (or
    /// host), failure or route + live/closed + duration, chevron.
    private func relatedRow(_ connection: LiveConnection, isLive: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: connection))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                subtitle(for: connection, isLive: isLive)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private static func title(for connection: LiveConnection) -> String {
        if let process = connection.process, !process.isEmpty { return process }
        return connection.host ?? connection.destination
    }

    /// Upstream subtitle: on failure red "失败" + the failure-kind
    /// label; otherwise destination + first proxy + 活动/已关闭 +
    /// duration. Empty parts are dropped, as upstream does.
    @ViewBuilder
    private func subtitle(for connection: LiveConnection, isLive: Bool) -> some View {
        if let kind = connection.failureKind {
            // Upstream RelatedConnectionRow: the WHOLE failure
            // subtitle is error-red, not just the "失败" prefix.
            Text("失败 · \(ConcordConnectionFailure.label(for: kind))")
                .foregroundStyle(.red)
        } else {
            Text(Self.routeText(for: connection, isLive: isLive))
        }
    }

    private static func routeText(for connection: LiveConnection, isLive: Bool) -> String {
        let firstProxy = connection.chains.first ?? connection.proxy ?? ""
        let lifetime = "\(isLive ? "活动" : "已关闭") \(ConcordFormat.duration(seconds: connection.durationSeconds))"
        return [connection.destination, firstProxy, lifetime]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The MuYu bottom floating search bar (v0.2.68): a rounded bar
/// with a magnifier + TextField, overlaid at the bottom of the
/// sheet list. Drives the store's searchText, same as the page's
/// top .searchable did.
private struct DnsFloatingSearchBar: View {
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
