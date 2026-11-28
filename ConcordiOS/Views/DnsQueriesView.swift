import SwiftUI

// DnsQueriesView — moved out of SettingsView.swift in v0.2.68 (no behaviour change).
// The Dashboard stats sheet and the Tools > DNS查询 page share this view; the sheet
// presents it in records-only mode, the Tools page with the filters + follow toggle.
// v0.2.139 (C19-c1 + Q5): the manual query, Fake-IP flush, refresh + sample badge,
// inline error surfaces and folding are gone (upstream has none of them); the
// filters live in the toolbar filter menu and the active ones show as removable
// chips above the list.

/// DNS capsule fill (v0.2.82): neutral grey measured from the MuYu
/// video DNS sheet (#B8B8B8, dominant fill tone in f_014). The video's
/// type ([A]/[AAAA]), initiator （其他/代理） and cache （缓存） capsules
/// are all this grey — not blue/orange, and NOT the theme accent (they
/// stay grey under the magenta theme). Fixed grey: dark text reads well
/// on it in both light and dark mode.
fileprivate let dnsCapsuleFill = Color(red: 184/255, green: 184/255, blue: 184/255)

// MARK: - DNS queries (FlClash: DnsQueriesView, lib/views/dns_queries.dart)

/// Record-list filter (upstream dns_queries.dart DnsStatus):
/// all / failed only / cache hits. No "live" option — upstream
/// has no such status (a non-cached record is simply a record).
private enum DnsRecordFilter: String, CaseIterable {
    case all, errors, cached

    var title: String {
        switch self {
        case .all: return "全部"
        case .errors: return "错误"
        case .cached: return "缓存命中"
        }
    }

    func matches(_ entry: ConcordDnsEntry) -> Bool {
        switch self {
        case .all: return true
        case .errors: return DnsErrorRow.isFailed(entry)
        case .cached: return entry.cached == true
        }
    }
}

struct DnsQueriesView: View {
    /// Presentation mode (v0.2.68): `.page` is the Tools /
    /// Settings pushed page (manual query + filters); `.sheet`
    /// is the Dashboard stats sheet (records only, own MuYu
    /// header + bottom floating search bar); `.segment` is the
    /// Requests page's DNS segment (v0.2.146, upstream
    /// RequestsSegment.dns): the records list with its filter
    /// row, no navigation chrome — the parent page owns the
    /// title, toolbar and search box.
    enum Mode {
        case page
        case sheet
        case segment
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
    /// (translation, release velocity pt/s, upward negative).
    /// Velocity comes from the UIKit list bridge; the header
    /// DragGesture passes 0 (its Value exposes no public
    /// velocity on this SDK) and relies on the translation
    /// branch of the overlay's snap rule.
    let onSheetDragEnded: ((CGFloat, CGFloat) -> Void)?

    init(mode: Mode = .page, onClose: (() -> Void)? = nil,
         onSheetDragChanged: ((CGFloat) -> Void)? = nil,
         onSheetDragEnded: ((CGFloat, CGFloat) -> Void)? = nil) {
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

    /// v0.2.119 (FIX 3): sheet list-drag coordination (MuYu
    /// parity). v0.2.118 forwarded the drag with a
    /// .simultaneousGesture(DragGesture) on the ScrollView,
    /// gated on an anchor row's minY (listAtTop) — that gesture
    /// never delivers on a scrolling container, so the mechanism
    /// is removed entirely (anchor, PreferenceKey, listAtTop,
    /// SheetListDragState, listDragGesture all gone; no dead
    /// mechanism left). The drag now comes from SheetListDragPan:
    /// a UIKit UIPanGestureRecognizer on the underlying
    /// UIScrollView, attached by the zero-height bridge row at
    /// the top of the LazyVStack below. It latches only on a
    /// drag that starts at the top, forwards translation +
    /// release velocity to onSheetDragChanged/onSheetDragEnded,
    /// and recognises simultaneously with the scroll view's own
    /// pan recognizer — the list still scrolls a little while
    /// the sheet grows (no .scrollDisabled). v0.2.139: the
    /// pull-to-refresh the mechanism used to coexist with is
    /// gone (Q5 — upstream has none here). It also works with
    /// zero rows, where a scroll-position-driven approach could
    /// never fire.

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

    /// Consecutive identical rows are NOT folded (v0.2.139, Q5):
    /// upstream shows every record. Rows identify by `seq` —
    /// assigned once at first sight by DnsStore and preserved
    /// across merges; `ConcordDnsEntry.id` alone
    /// ("\(time)-\(domain)-\(type)") is NOT unique (same-ms
    /// same-domain+type queries share it) and ForEach with
    /// duplicate ids is undefined behaviour in SwiftUI.
    /// One active filter shown as a removable chip above the
    /// list (upstream requests.dart: active filters as keyword
    /// chips under the bar).
    private struct ActiveDnsFilter: Identifiable {
        enum Kind { case status, type, initiator, rcode }
        let kind: Kind
        let label: String
        var id: String { "\(kind)-\(label)" }
    }

    /// The active filters, in menu order (status, type,
    /// initiator, rcode).
    private var activeFilters: [ActiveDnsFilter] {
        var filters: [ActiveDnsFilter] = []
        if recordFilter != .all {
            filters.append(ActiveDnsFilter(kind: .status, label: recordFilter.title))
        }
        if let type = selectedType {
            filters.append(ActiveDnsFilter(kind: .type, label: type))
        }
        if let initiator = selectedInitiator {
            filters.append(ActiveDnsFilter(kind: .initiator, label: initiator))
        }
        if let rcode = selectedRcode {
            filters.append(ActiveDnsFilter(kind: .rcode, label: rcode))
        }
        return filters
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
        guard mode != .sheet else { return }
        if let id = visibleEntries.first?.seq {
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
                // DragGesture.Value exposes no public velocity on
                // this SDK, so the header passes 0; the overlay's
                // snap rule settles a clear upward header drag on
                // translation alone, and the list bridge supplies
                // the real release velocity for list drags.
                .onEnded { if let onSheetDragEnded { onSheetDragEnded($0.translation.height, 0) } }
        )
    }

    /// The sheet's records-only list (v0.2.68; rebuilt v0.2.102):
    /// no manual query, no cache / Fake-IP buttons, no filter
    /// segment, no follow toggle + hint, no facet menus — just
    /// the records, with bottom clearance for the floating
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
                // v0.2.119 (FIX 3): zero-height bridge row for the
                // sheet list-drag — SheetListDragPan mounts here
                // and attaches its UIKit pan recognizer to this
                // ScrollView (see SheetListDragPan.swift). The
                // 12pt LazyVStack spacing after this row replaces
                // the .padding(.top, 12) below (now 0), so the
                // first row sits exactly where it did before.
                // In page mode this list is never rendered, and
                // the callbacks are nil there anyway.
                SheetListDragPan(
                    onChanged: { if let onSheetDragChanged { onSheetDragChanged($0) } },
                    onEnded: { translation, velocity in
                        if let onSheetDragEnded { onSheetDragEnded(translation, velocity) }
                    }
                )
                .frame(height: 0)
                if visibleEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dnsStore.filtered.isEmpty ? "暂无 DNS 查询记录" : "没有符合筛选的记录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if dnsStore.filtered.isEmpty, client.mode == .live, !TunnelManager.shared.isRunning {
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
                    ForEach(visibleEntries, id: \.seq) { entry in
                        dnsSheetRow(entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 76)
        }
    }

    /// One DNS row in the video's layout (v0.2.68): line 1 time +
    /// type capsule + latency at the right; line 2 domain bold;
    /// line 3 bare answer IPs; line 4 initiator capsule + 缓存
    /// capsule when cached + the bare upstream URL. No keyword
    /// chips in sheet mode.
    private func dnsSheetRow(_ entry: ConcordDnsEntry) -> some View {
        Button {
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
        // search + nested .sheet(item:), detents [9/16, 0.9] set
        // by the Dashboard) — NO ScrollViewReader, NO .task
        // refresh, NO .onChange, NO .onAppear timer, NO
        // .refreshable (v0.2.139, Q5: upstream has no
        // pull-to-refresh here). Those were the suspects in the
        // presentation-time layout/state feedback loop that froze
        // the app on the DNS tap (v0.2.102 watchdog proof:
        // main-thread stall starting at the tap). The sheet just
        // displays whatever dnsStore.entries holds (the Dashboard
        // refreshes it). Page mode (Tools → DNS) never froze and
        // keeps its .task appear-refresh (the data load).
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
                .sheet(item: $selectedEntry) { entry in
                    DnsEntryDetailView(entry: entry)
                        // Upstream _showDnsQueryDetail → showSheet, snap
                        // detents [9/16, 0.9], drag handle, scrim dismiss
                        // (dns_queries.dart:233; MuYu: showNestedSheet).
                        .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                        .presentationDragIndicator(.visible)
                }
            } else if mode == .segment {
                segmentList
            } else {
                ScrollViewReader { proxy in
                    pageList(proxy: proxy)
                        .background(ConcordTheme.pageBackground)
                        .listStyle(.insetGrouped)
                        .upstreamNavBar(title: "DNS 查询")
                        .searchable(text: $dnsStore.searchText, prompt: "搜索域名或上游")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                // Filter menu (v0.2.139, C19-c1 —
                                // upstream dns_queries.dart
                                // optionMenuItems): status + type +
                                // initiator + rcode facets. The
                                // active ones show as removable
                                // chips above the list.
                                Menu {
                                    dnsFilterMenuContent
                                } label: {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                }
                                .accessibilityLabel("筛选")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                // ⋯ menu (v0.2.139, Q5 — upstream
                                // requests.dart: the DNS segment's
                                // app-bar menu has exactly one
                                // item, clearDnsCache).
                                Menu {
                                    Button("清除 DNS 缓存") {
                                        Task { await dnsStore.clearCache() }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("更多操作")
                            }
                        }
                        .task {
                            // v0.2.82 (DNS freeze): with the VPN off in live mode
                            // the refresh can never succeed (dns.watch reads the
                            // extension snapshot only) — so skip it on appear and
                            // let the page open with zero store work. Sample mode
                            // always refreshes (built-in sample data, no tunnel
                            // needed). v0.2.139: this appear-refresh is now the
                            // page's only load — pull-to-refresh and the toolbar
                            // refresh button are gone (upstream has neither).
                            if dnsStore.entries.isEmpty
                                && (TunnelManager.shared.isRunning || client.mode == .sample) {
                                await dnsStore.refresh()
                            }
                        }
                        .onChange(of: visibleEntries.first?.seq) { old, _ in
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

    /// The filter menu, shared by the page toolbar and the
    /// segment's filter row (v0.2.139, C19-c1 — upstream
    /// dns_queries.dart optionMenuItems): status + type +
    /// initiator + rcode facets.
    @ViewBuilder
    private var dnsFilterMenuContent: some View {
        Picker("筛选", selection: $recordFilter) {
            ForEach(DnsRecordFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        Picker("记录类型", selection: $selectedType) {
            Text("全部").tag(nil as String?)
            ForEach(availableTypes, id: \.self) { type in
                Text(type).tag(type as String?)
            }
        }
        Picker("发起方", selection: $selectedInitiator) {
            Text("全部").tag(nil as String?)
            ForEach(availableInitiators, id: \.self) { initiator in
                Text(initiator).tag(initiator as String?)
            }
        }
        Picker("返回码", selection: $selectedRcode) {
            Text("全部").tag(nil as String?)
            ForEach(availableRcodes, id: \.self) { rcode in
                Text(rcode).tag(rcode as String?)
            }
        }
    }

    /// The Requests page's DNS segment (v0.2.146, upstream
    /// RequestsSegment.dns): the same records list as the page,
    /// with the filter menu in a row above it — no navigation
    /// title, toolbar, back button or own search box (the parent
    /// page drives dnsStore.searchText from its shared search).
    /// The ⋯ menu's clear-DNS-cache lives on the parent page.
    private var segmentList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        dnsFilterMenuContent
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(.label))
                            .frame(width: 30, height: 30)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .accessibilityLabel("筛选")
                    Spacer()
                    Text("\(visibleEntries.count) 条记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                pageList(proxy: proxy)
            }
            .background(ConcordTheme.pageBackground)
            .task {
                // Same gate as the page's appear-refresh (v0.2.82):
                // with the VPN off in live mode the refresh can
                // never succeed — the parent page's 1 s poll
                // refreshes while the segment is shown.
                if dnsStore.entries.isEmpty
                    && (TunnelManager.shared.isRunning || client.mode == .sample) {
                    await dnsStore.refresh()
                }
            }
            .onChange(of: visibleEntries.first?.seq) { old, _ in
                if old != nil, followEnd {
                    scrollToNewest(proxy)
                }
            }
            .sheet(item: $selectedEntry) { entry in
                DnsEntryDetailView(entry: entry)
                    .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// The pushed page's full list (records + follow toggle).
    /// v0.2.139 (C19-c1 + Q5): the manual query, Fake-IP flush,
    /// refresh + sample badge, inline error surfaces and folding
    /// are gone; the filters live in the toolbar filter menu and
    /// the active ones show as removable chips pinned above the
    /// list (upstream requests.dart: active filters as keyword
    /// chips under the bar).
    private func pageList(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if !activeFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeFilters) { filter in
                            Button {
                                switch filter.kind {
                                case .status: recordFilter = .all
                                case .type: selectedType = nil
                                case .initiator: selectedInitiator = nil
                                case .rcode: selectedRcode = nil
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(filter.label)
                                        .font(.caption.weight(.semibold))
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(ConcordTheme.cardBackground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            List {
                Section("查询记录（dns.watch）") {
                    Toggle("跟随最新", isOn: $followEnd)
                        .toggleStyle(UpstreamToggleStyle())
                        .onChange(of: followEnd) { _, on in
                            if on { scrollToNewest(proxy) }
                        }
                    Text("打开后新记录出现时回到顶部；向下翻看旧记录时请先关闭。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if visibleEntries.isEmpty {
                        Text(dnsStore.filtered.isEmpty ? "暂无 DNS 查询记录" : "没有符合筛选的记录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if dnsStore.filtered.isEmpty, client.mode == .live, !TunnelManager.shared.isRunning {
                            // v0.2.82: the appear refresh is skipped with
                            // the VPN off (see .task above), so lastError
                            // is never set — same reason, statically.
                            Text("VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    } else {
                        ForEach(visibleEntries, id: \.seq) { entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                // Upstream DnsQueryRow (dns_queries.dart):
                                // leading 40pt type well; title = domain,
                                // subheadline 15; subtitle = initiator ·
                                // summary (error / failure rcode / answers),
                                // caption1 12 tabular, red when failed;
                                // trailing = "N ms" footnote 13 + 缓存
                                // caption2 11 when cached. No upstream /
                                // timestamp / keyword chips in the row —
                                // those live in the detail sheet (or the
                                // search box), not the feed row.
                                HStack(alignment: .top, spacing: 12) {
                                    UpstreamLabelWell(label: entry.type)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.domain)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text(dnsQuerySubtitle(entry))
                                            .font(.caption)
                                            .foregroundStyle(DnsErrorRow.isFailed(entry) ? .red : .secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(entry.delay) ms")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                        if entry.cached == true {
                                            Text("缓存")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
            .contentMargins(.bottom, ConcordTheme.tabBarClearance)
            .contentMargins(.top, 40)
            .scrollContentBackground(.hidden)
        }
    }

    /// Upstream DnsQueryExt.summary (common.dart): the error, else the
    /// failure rcode, else the answers; the row subtitle prefixes the
    /// initiator when present.
    private func dnsQuerySubtitle(_ entry: ConcordDnsEntry) -> String {
        let summary: String
        if let error = entry.error, !error.isEmpty {
            summary = error
        } else if let rcode = entry.rcode, !rcode.isEmpty, rcode != "NOERROR", rcode != "NoError" {
            summary = rcode
        } else {
            summary = entry.answers.joined(separator: ", ")
        }
        return [entry.initiator, summary].filter { !$0.isEmpty }.joined(separator: " · ")
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
