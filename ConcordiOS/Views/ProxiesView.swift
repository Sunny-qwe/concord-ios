import SwiftUI

// MARK: - Proxies (FlClash: ProxiesView, lib/views/proxies/)
// FlClash proxies page, reproduced in SwiftUI:
// - Top bar: ONE capsule (FlClash TonalButtonGroup) holding search
//   (magnifier, presents the search field) + bolt. In tab style the
//   bolt tests the current group; in list / card style it tests ALL
//   groups (MuYu iOS build _delayTestAllGroups). The ⋯ opens a white
//   card menu (FlClash PopupMenu): 风格/排序/布局/尺寸/图标样式, each
//   opening a submenu with a checkmark on the current value, plus
//   隐藏超时代理. No test-all and no refresh in the menu (FlClash
//   has neither there). The locate button (tab style only, a
//   separate bar item after the pill — FlClash proxies.dart:164-172)
//   scrolls to the selected node; re-tapping the active group pill
//   does the same. The page title is the 24pt pageTitle (FlClash
//   scaffold: compactTitle is false on a tab page — only sheets and
//   pushed pages use the 17pt headline), rendered as a leading
//   toolbar item because SwiftUI's inline title is fixed at 17pt.
// - Style 标签页： group pills on top, one group's nodes as cards in
//   a grid. Style 列表： every group stacked with a collapsible
//   header (icon, name, selected node, per-group delay test +
//   scroll to selected), nodes as cards in a grid. Style 卡片
//   (MuYu-only, FlClash 0.9.3 does not have it): groups as a
//   two-column grid of brand-icon cards with a folder bar
//   （全部/策略组/节点组/节点） on top; an expanded card spans the
//   full width and shows its nodes below it.
// - Layout 紧凑/标准/宽松 sets the grid columns (3/2/1 on a phone);
//   size 紧凑/标准/宽松 sets the card content (1-line name / 2-line
//   name / + description row). Icon style applies to the list
//   headers and the card-style brand icons. Hide-timeout keeps the
//   selected node, group nodes and untested nodes, and never empties
//   a group.
// - Tap a card to select it (Selector) or pin/unpin it as 首选
//   (url-test / fallback); load-balance / relay cannot be chosen by
//   hand. Long-press opens the card menu: 选择/设为首选， 添加到本地
//   节点， 测速， 节点详情. Tapping the delay chip tests that node.

/// Card-style folder bar (MuYu-only, lib/enum/enum.dart
/// ProxyFolder + lib/views/proxies/list.dart _FolderBar): filters
/// the group grid. `leafNodes` replaces the grid with a flat list
/// of deduplicated leaf nodes. Labels are MuYu's arb strings
/// (全部/策略组/节点组/节点）.
private enum ProxyFolder: String, CaseIterable {
    case all, strategy, nodes, leafNodes
    var label: String {
        switch self {
        case .all: return "全部"
        case .strategy: return "策略组"
        case .nodes: return "节点组"
        case .leafNodes: return "节点"
        }
    }
    /// MuYu _FolderPill glyphs: all → dashboard, strategy/nodes →
    /// folder, leafNodes → devices.
    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .strategy: return "folder"
        case .nodes: return "folder"
        case .leafNodes: return "iphone"
        }
    }
}

/// One entry of the flat leaf-nodes view (MuYu compute.dart
/// flatLeafNodes): a real node with the first group that lists it,
/// so its test URL is that group's.
private struct LeafNodeEntry: Identifiable {
    var id: String { node.name }
    let node: ProxyNode
    let group: ProxyGroup
}

/// Preference key carrying the pills strip content width (for the
/// overflow More button / edge fade decision).
private struct PillsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ProxiesView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var styleStore: ProxyStyleStore
    @ObservedObject private var iconSetStore = IconSetStore.shared
    @StateObject private var customStore = CustomProxyStore()
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showMoreMenu = false
    @State private var menuLevel: MenuLevel = .root
    @State private var selectedGroupName: String?
    /// Groups the user expanded in list style. FlClash's unfoldSet
    /// (models/profile.dart:78) defaults to {} — groups start
    /// collapsed — so this set starts empty too.
    @State private var expandedGroups: Set<String> = []
    @State private var detailNode: ProxyNode?
    @State private var detailTestURL: String?
    @State private var notice: String?
    @State private var scrollTargetName: String?
    @State private var scrollNonce = 0
    /// Card style only (MuYu icon_card.dart / list.dart): the
    /// folder bar selection. Local state, NOT persisted — MuYu's
    /// `_folder` is the same (default all).
    @State private var iconFolder: ProxyFolder = .all
    /// Per-group search (MuYu GroupSearchControl, common.dart):
    /// a keyword filters only its own group's nodes, in list and
    /// card styles, only while that group is expanded. The open
    /// set tracks which headers show the field.
    @State private var groupSearchKeywords: [String: String] = [:]
    @State private var groupSearchOpen: Set<String> = []
    @FocusState private var groupSearchFocus: String?
    /// Tab style: the overflow "More" picker (FlClash group_tabs.dart
    /// _OverflowMenuButton) and the pills strip measurement that
    /// decides whether it (and the 24pt right-edge fade) shows.
    @State private var showGroupPicker = false
    @State private var pillsContentWidth: CGFloat = 0

    private static let groupTypes: Set<String> = ["select", "url-test", "fallback", "load-balance", "relay"]
    /// Built-in adapters whose delay probe always fails, so a timeout
    /// says nothing (FlClash _unprobeableProxyTypes,
    /// common/compute.dart:60-64). DIRECT is deliberately absent:
    /// FlClash does not keep it. Spelling is FlClash's; the
    /// comparison below is case- and hyphen-insensitive because the
    /// Rust core spells these "REJECT-DROP"/"DIRECT" style.
    private static let unprobeableTypes: Set<String> = ["Reject", "RejectDrop", "Pass", "PassRule", "Rematch", "Compatible", "Dns"]
    private static let unprobeableTypesNormalized: Set<String> = Set(unprobeableTypes.map { $0.lowercased().replacingOccurrences(of: "-", with: "") })
    /// Names the core registers before any proxy is parsed, so
    /// neither a proxy nor a group can take one (FlClash
    /// reservedCustomProxyNames, providers/state/custom.dart:110-121).
    private static let reservedNames: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL"]

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search terms (FlClash SearchQuery, common/search.dart:3-30):
    /// the query splits on whitespace and EVERY term must match.
    private var searchTerms: [String] {
        searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A node matches when every search term appears in its name or
    /// type (FlClash SearchQuery.matches over [name, type]).
    private func matchesSearch(_ node: ProxyNode) -> Bool {
        guard !searchTerms.isEmpty else { return true }
        let text = (node.name + "\n" + node.type).lowercased()
        return searchTerms.allSatisfy { text.contains($0) }
    }

    /// Search-matching node names of one group, from the RAW group
    /// (FlClash delayTestPageGroup matches against group.all, not
    /// the hide-timeout-filtered list). Nil while not searching, so
    /// the group test covers the whole group.
    private func searchMatchedNodeNames(forGroupNamed name: String) -> [String]? {
        guard searching else { return nil }
        guard let raw = proxyStore.groups.first(where: { $0.name == name }) else { return [] }
        return raw.nodes.filter(matchesSearch).map(\.name)
    }

    private var selectedGroup: ProxyGroup? {
        if let name = selectedGroupName {
            return proxyStore.groups.first { $0.name == name }
        }
        return proxyStore.groups.first
    }

    /// Groups after search + hide-timeout + sort (FlClash:
    /// filterGroupsState + computeHideTimeout). Search runs FIRST,
    /// then hide-timeout applies to the filtered groups (providers/
    /// state/proxies.dart:100-117), so a timed-out match is still
    /// hidden; a group left with no visible node keeps all its nodes.
    /// Group identity is preserved (copies keep the same id), so the
    /// expanded/collapsed state and scroll ids survive a refresh.
    private var visibleGroups: [ProxyGroup] {
        // Group names, once per pass: the hide-timeout filter and
        // the delay sort both used to scan proxyStore.groups per
        // node / per comparison (O(n) inside an O(n log n) sort).
        let groupNames = Set(proxyStore.groups.map(\.name))
        var out: [ProxyGroup] = []
        for group in proxyStore.groups {
            var nodes = group.nodes
            if searching {
                nodes = nodes.filter(matchesSearch)
                guard !nodes.isEmpty else { continue }
            }
            if styleStore.hideTimeout {
                let kept = nodes.filter { keepWhenHidingTimeout($0, in: group, groupNames: groupNames) }
                if !kept.isEmpty { nodes = kept }
            }
            var copy = group
            copy.nodes = sortNodes(nodes, groupNames: groupNames)
            out.append(copy)
        }
        return out
    }

    private func keepWhenHidingTimeout(_ node: ProxyNode, in group: ProxyGroup, groupNames: Set<String>) -> Bool {
        // The selected node, and nodes that are groups themselves,
        // are always kept — hiding them would take away the only way
        // to choose that group.
        if node.name == group.selectedNodeName { return true }
        if groupNames.contains(node.name) { return true }
        if Self.isUnprobeableType(node.type) { return true }
        guard let ms = node.latencyMs else { return true }
        return ms > 0
    }

    /// Case- and hyphen-insensitive match against the FlClash
    /// unprobeable set, so "REJECT-DROP" and "RejectDrop" both match.
    private static func isUnprobeableType(_ type: String) -> Bool {
        Self.unprobeableTypesNormalized.contains(type.lowercased().replacingOccurrences(of: "-", with: ""))
    }

    /// Delay-sort priority (FlClash DelayState, models/common.dart:
    /// 1046-1064): valid latency → untested (nil, FlClash delay ?? 0)
    /// → timeout (-1) → other failures.
    private static func delayPriority(_ node: ProxyNode) -> Int {
        guard let ms = node.latencyMs else { return 1 }
        if ms > 0 { return 0 }
        if ms == -1 { return 2 }
        return 3
    }

    private func sortNodes(_ nodes: [ProxyNode], groupNames: Set<String>) -> [ProxyNode] {
        switch styleStore.sort {
        case .default: return nodes
        case .delay: return nodes.sorted { a, b in
            let pa = Self.delayPriority(a), pb = Self.delayPriority(b)
            if pa != pb { return pa < pb }
            let da = a.latencyMs ?? 0, db = b.latencyMs ?? 0
            if da != db { return da < db }
            // Ties: nested groups first (FlClash DelayState.compareTo).
            let aIsGroup = groupNames.contains(a.name)
            let bIsGroup = groupNames.contains(b.name)
            if aIsGroup != bIsGroup { return aIsGroup }
            return false
        }
        case .name: return nodes.sorted { $0.name < $1.name }
        }
    }

    private var selectedVisibleGroup: ProxyGroup? {
        if let name = selectedGroupName,
           let found = visibleGroups.first(where: { $0.name == name }) {
            return found
        }
        return visibleGroups.first
    }

    // MARK: - Card style (MuYu-only) helpers

    /// All group names, once (the folder classification and the
    /// available-count both test "is this member a group?").
    private var allGroupNames: Set<String> {
        Set(proxyStore.groups.map(\.name))
    }

    /// MuYu compute.dart groupIsNodeOnly: a group is node-only when
    /// it is non-empty and every member is NOT a group name. An
    /// empty group counts as a strategy group (it holds no node).
    private func isNodeOnlyGroup(_ group: ProxyGroup) -> Bool {
        guard !group.nodes.isEmpty else { return false }
        return group.nodes.allSatisfy { !allGroupNames.contains($0.name) }
    }

    /// Folder counts, from the RAW groups (MuYu counts from
    /// allGroups = groupsProvider, not the search-filtered list).
    private func folderCount(_ folder: ProxyFolder) -> Int {
        switch folder {
        case .all: return proxyStore.groups.count
        case .strategy: return proxyStore.groups.filter { !isNodeOnlyGroup($0) }.count
        case .nodes: return proxyStore.groups.filter { isNodeOnlyGroup($0) }.count
        case .leafNodes: return leafNodeEntries.count
        }
    }

    /// Visible groups after the folder filter (MuYu
    /// filterGroupsByFolder). `leafNodes` returns [] — the flat view
    /// replaces the group list entirely.
    private var folderGroups: [ProxyGroup] {
        switch iconFolder {
        case .all: return visibleGroups
        case .strategy: return visibleGroups.filter { !isNodeOnlyGroup($0) }
        case .nodes: return visibleGroups.filter { isNodeOnlyGroup($0) }
        case .leafNodes: return []
        }
    }

    /// Flat leaf nodes (MuYu compute.dart flatLeafNodes): walk the
    /// visible groups in order, members in order; skip members that
    /// are themselves groups and the core's built-in outbounds
    /// (DIRECT / REJECT / REJECT-DROP / PASS — policies, not real
    /// nodes); dedupe by name, first occurrence wins. Then the
    /// page's hide-timeout filter and the page sort (none = insertion
    /// order, name = alphabetical, delay = by resolved delay).
    private var leafNodeEntries: [LeafNodeEntry] {
        let groupNames = allGroupNames
        var seen = Set<String>()
        var out: [LeafNodeEntry] = []
        for group in visibleGroups {
            for node in group.nodes {
                guard !groupNames.contains(node.name),
                      !Self.reservedNames.contains(node.name),
                      seen.insert(node.name).inserted else { continue }
                if styleStore.hideTimeout,
                   !keepWhenHidingTimeout(node, in: group, groupNames: groupNames) { continue }
                out.append(LeafNodeEntry(node: node, group: group))
            }
        }
        switch styleStore.sort {
        case .default: break
        case .name: out.sort { $0.node.name < $1.node.name }
        case .delay:
            out.sort { a, b in
                let pa = Self.delayPriority(a.node), pb = Self.delayPriority(b.node)
                if pa != pb { return pa < pb }
                let da = a.node.latencyMs ?? 0, db = b.node.latencyMs ?? 0
                return da < db
            }
        }
        return out
    }

    /// Nodes of a group as displayed in list / card style: the
    /// group's own search keyword (MuYu GroupSearchControl) filters
    /// only this group, on top of the page search / hide-timeout /
    /// sort already applied by visibleGroups.
    private func displayNodes(for group: ProxyGroup) -> [ProxyNode] {
        guard let keyword = groupSearchKeywords[group.name],
              !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            return group.nodes
        }
        let terms = keyword.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return group.nodes.filter { node in
            let text = (node.name + "\n" + node.type).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    /// "n" of MuYu's "TYPE · n/m" subtitle (icon_card.dart
    /// _GroupAvailability, countAvailableProxies): members whose
    /// resolved delay is > 0. The store's latencyMs is already the
    /// resolved pick delay (applyLatencies), so a nested-group
    /// member counts through its current pick. "m" is the raw
    /// member count (group.all.length, unfiltered).
    private func availableCount(for group: ProxyGroup) -> Int {
        let raw = proxyStore.groups.first(where: { $0.name == group.name })
        return (raw?.nodes ?? group.nodes).filter { ($0.latencyMs ?? 0) > 0 }.count
    }

    /// MuYu GroupType.displayName (enum.dart), uppercased for the
    /// card subtitle: URLTest has no hyphen, unlike the raw
    /// "url-test" the core reports.
    private static func typeDisplayName(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "SELECTOR"
        case "url-test": return "URLTEST"
        case "fallback": return "FALLBACK"
        case "load-balance": return "LOADBALANCE"
        case "relay": return "RELAY"
        default: return type.uppercased()
        }
    }

    /// Card metrics (MuYu icon_card.dart _cardMetrics, lines 20–49):
    /// inset, name↔icon gap, meta gap, bottom gap, brand icon size.
    private func iconCardMetrics() -> (inset: CGFloat, nameIconGap: CGFloat, metaGap: CGFloat, bottomGap: CGFloat, brandSize: CGFloat) {
        switch styleStore.cardType {
        case .compact: return (8, 6, 4, 8, 40)
        case .standard: return (12, 8, 6, 8, 48)
        case .loose: return (16, 8, 8, 10, 56)
        }
    }

    /// Collapsed icon-card height (MuYu icon_card.dart
    /// groupIconCardHeightOf): inset*2 + rowHeight + metaGap +
    /// caption1 leading (16) + bottomGap + bottom row (24).
    /// rowHeight is the brand icon size, or the callout leading
    /// (21) when icons are hidden.
    private func iconCardCollapsedHeight(for group: ProxyGroup) -> CGFloat {
        let m = iconCardMetrics()
        let rowHeight = styleStore.iconStyle == .hidden ? 21 : m.brandSize
        return m.inset * 2 + rowHeight + m.metaGap + 16 + m.bottomGap + 24
    }

    /// The brand icon a node card shows before the name (MuYu
    /// card.dart _memberIconSize): only when the node is itself a
    /// group with a non-empty profile icon. Leaf nodes have no icon
    /// source — the Concord core exposes no per-node icon
    /// (ConcordNodeInfo has name/type/provider only), so they show
    /// nothing, exactly as MuYu's `if (proxy.icon.isNotEmpty)`.
    private func memberIcon(for node: ProxyNode) -> String? {
        guard Self.groupTypes.contains(node.type),
              let sub = proxyStore.groups.first(where: { $0.name == node.name }),
              !sub.icon.isEmpty else { return nil }
        return sub.icon
    }

    private func gridColumns(width: CGFloat) -> [GridItem] {
        let count = ProxyStyleStore.columns(for: styleStore.layout, width: width)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    /// Card heights (FlClash common.dart getItemHeight, with the
    /// measured leadings subheadline 20 / footnote 18 / caption2 13):
    /// base = 16 + 2×20 + 18 + 8 + 4 = 86; loose adds caption2 + 6
    /// (105); compact drops one subheadline line (66). The v0.2.51
    /// values 68/88/112 were +2/+2/+7 off (the old formula used a
    /// wrong base).
    private var cardHeight: CGFloat {
        switch styleStore.cardType {
        case .compact: return 66
        case .standard: return 86
        case .loose: return 105
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if client.mode == .sample {
                        HStack {
                            SampleDataBadge()
                            Text("节点与延迟为示例数据")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                    if let notice {
                        HStack {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            // GeoIP-failure banner (v0.2.35): the
                            // seed failed, so the delay test could
                            // not run at all. Tapping 重试 re-seeds
                            // immediately — bundle copy first,
                            // network fallback — bypassing the
                            // 10-minute cool-down that used to trap
                            // the user, then re-runs the failed test.
                            // A retry that still fails keeps the
                            // honest reason in the banner.
                            if proxyStore.testErrorIsGeoSeed {
                                if proxyStore.isRetryingGeoSeed {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button("重试") {
                                        Task { await proxyStore.retryGeoSeedAndRetest() }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.semibold))
                                    .accessibilityLabel("重新下载 GeoIP 数据库并重试测速")
                                }
                            }
                            // Rule-set repair (v0.2.46 ITEM 1): the
                            // banner error names a rule-set the
                            // config references but never defines,
                            // so the core refused the whole config.
                            // Tapping 修复 only builds the plan and
                            // shows the exact lines; nothing is
                            // written without confirmation.
                            if let missing = proxyStore.missingRuleSetName {
                                Button("修复") {
                                    Task { await proxyStore.prepareRuleSetRepair() }
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold))
                                .accessibilityLabel("修复缺失的规则集 \(missing)")
                                .disabled(proxyStore.isRepairingRuleSet)
                            }
                            Button { self.notice = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    switch styleStore.style {
                    case .tab:
                        tabContent(width: geometry.size.width)
                    case .list:
                        listContent(width: geometry.size.width)
                    case .icons:
                        iconsContent(width: geometry.size.width)
                    }
                }
                .background(ConcordTheme.pageBackground)
            }
            // FlClash pageTitle is 24pt semibold on a tab page
            // (scaffold.dart:780: compactTitle is false — isCompact
            // is true only for bottom/form sheets, sheet.dart:42,
            // and pushed is false at a tab root). SwiftUI's inline
            // title is fixed at 17pt, so the title is a leading
            // toolbar item instead. Pushed pages keep their 17pt
            // inline title (compactTitle is true there).
            .searchable(text: $searchText, isPresented: $isSearching, prompt: "搜索节点")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("tab.proxies".l10n)
                        .font(.system(size: 24, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    topBarPill
                }
                if styleStore.style == .tab {
                    ToolbarItem(placement: .topBarTrailing) {
                        locateButton
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    moreButton
                }
            }
            .sheet(item: $detailNode) { node in
                NodeDetailView(node: node, testURL: detailTestURL)
            }
            .sheet(item: $proxyStore.ruleSetRepairOffer) { plan in
                RuleSetRepairSheet(plan: plan)
            }
            .task {
                // The refresh's VPN-off fallback scans the active
                // profile's YAML; the scan itself runs off the main
                // thread (ProxyStore.refresh falls back via
                // Task.detached). Deferring one runloop turn here
                // additionally guarantees the static title and the
                // loading state render before any of that starts.
                if proxyStore.groups.isEmpty {
                    DispatchQueue.main.async {
                        Task { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                    }
                }
            }
            .onChange(of: profileStore.activeProfile?.id) { _, _ in
                Task { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
            }
            .onChange(of: proxyStore.testError) { _, new in
                // A failed delay test used to be total silence
                // (lastError is never read on this page): show the
                // reason in the notice banner instead. A nil error
                // (a new test started, or a banner retry seeded
                // the files) dismisses the banner.
                if let new { notice = new } else { notice = nil }
            }
            .onChange(of: proxyStore.testErrorNonce) { _, _ in
                // The same failure twice in a row does not change
                // testError, so the observer above never fires —
                // the nonce re-shows the banner for the repeat.
                if let current = proxyStore.testError { notice = current }
            }
            .onAppear {
                // Returning to this page with a failure already
                // recorded (e.g. the run finished while another tab
                // was frontmost) must still show it.
                if let current = proxyStore.testError { notice = current }
            }
        }
    }

    // MARK: - Top bar

    /// FlClash's bar, 1:1 (lib/ui/scaffold/scaffold_actions.dart):
    /// the first two actions sit in ONE TonalButtonGroup pill, and
    /// the ⋯ is a separate standalone button. TonalButtonSize.bar =
    /// 44pt buttons; the Flutter glyphs are 24pt nominal but their
    /// ink measures ~19pt (58px @3x), so the SF glyphs use a 19pt
    /// font — and .imageScale(.medium), because the toolbar applies
    /// .large (1.25x), which blew the 24pt glyphs up to 30pt ink in
    /// v0.2.27. barButtonGap = 8pt between the pill and the ⋯ circle;
    /// the fill is the raised surface (white in light mode) — NOT
    /// secondarySystemBackground, which is the same colour as the
    /// page and renders invisible. No dividers between the grouped
    /// buttons. The bolt tests the current group in tab style and
    /// ALL groups in list / card style (MuYu _delayTestAllGroups);
    /// the search is a magnifier button that presents the search
    /// field. The locate button is a separate bar item (tab style
    /// only, FlClash proxies.dart:164-172) — it is NOT folded into
    /// the ⋯ menu; re-tapping the active group pill scrolls to the
    /// selected node too.
    /// The pill and the ⋯ are TWO toolbar items, not one HStack:
    /// with a single item SwiftUI anchors the ⋯ popover to the whole
    /// 140pt bar, so its arrow pointed at the bolt (v0.2.28). The
    /// ⋯ has its own item so the arrow points at the ⋯ circle.
    /// Declaration order is left-to-right for trailing items, so
    /// the pill is declared first and the ⋯ stays rightmost; the
    /// system spacing between trailing items is 8pt, matching
    /// barButtonGap.
    private var topBarPill: some View {
        HStack(spacing: 0) {
            Button { isSearching = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .imageScale(.medium)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
            // MuYu _buildPrimaryAction: the bolt is always present.
            // Tab style tests the current group (FlClash
            // delayTestCurrentGroup); list / card style tests ALL
            // groups (MuYu _delayTestAllGroups — the store's
            // testLatency() existed but had no UI caller).
            if styleStore.style == .tab {
                topBarBoltButton(for: selectedGroup)
            } else {
                topBarTestAllButton
            }
        }
        .background(ConcordTheme.cardBackground, in: Capsule())
    }

    /// The bolt in list / card style: tests every group (MuYu
    /// _delayTestAllGroups — Future.wait over delayTestPageGroup
    /// per group, each still restricted to the page-search matches).
    /// Loading while ANY group is testing (MuYu reads
    /// delayTestingGroupsProvider.isNotEmpty).
    private var topBarTestAllButton: some View {
        let testing = !proxyStore.testingGroups.isEmpty
        return Button {
            Task { await proxyStore.testLatency() }
        } label: {
            if testing {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .imageScale(.medium)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .disabled(proxyStore.groups.isEmpty || testing)
        .accessibilityLabel("测速全部")
    }

    /// The locate button: tab style only, a separate bar item after
    /// the pill (FlClash proxies.dart:164-172, `if (_isTab &&
    /// !picker)`). Scrolls to the current group's selected node;
    /// a no-op when nothing is selected, as in FlClash.
    private var locateButton: some View {
        Button { scrollToSelected(in: selectedGroup) } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 19, weight: .semibold))
                .imageScale(.medium)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("滚动到已选")
        .background(ConcordTheme.cardBackground, in: Circle())
    }

    private var moreButton: some View {
        Button { showMoreMenu = true } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 19, weight: .semibold))
                .imageScale(.medium)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .background(ConcordTheme.cardBackground, in: Circle())
        .popover(isPresented: $showMoreMenu, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
            moreMenuPopover
        }
    }

    /// The bolt: in tab style it tests the current group (FlClash
    /// delayTestCurrentGroup → delayTestPageGroup). In list / card
    /// style the pill shows the test-all bolt instead (MuYu
    /// _delayTestAllGroups). There is no test-all in the ⋯ menu —
    /// the bolt is the delay test, as in FlClash. While searching
    /// only the search-matching nodes are tested (FlClash
    /// delayTestPageGroup(matchSearch: true),
    /// providers/actions/proxies.dart:353-375).
    private func topBarBoltButton(for group: ProxyGroup?) -> some View {
        let testing = group.map { proxyStore.testingGroups.contains($0.name) } ?? false
        return Button {
            if let group { Task { await proxyStore.testLatency(group: group, nodeNames: searchMatchedNodeNames(forGroupNamed: group.name)) } }
        } label: {
            if testing {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .imageScale(.medium)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .disabled(group == nil || testing)
        .accessibilityLabel("测速")
    }

    // MARK: - ⋯ menu (FlClash PopupMenu, lib/views/proxies/proxies.dart)

    /// The ⋯ menu is a white card, not a native context menu: five
    /// option rows (each opens a submenu with a checkmark on the
    /// current value) and the hide-timeout toggle. No test-all and no
    /// refresh in the menu — FlClash has neither there (the bolt is
    /// the test; refresh is pull-to-refresh). Icon style shows in
    /// list AND card style, hidden only in tab style (MuYu changed
    /// FlClash's `type == list` to `type != tab` when it added the
    /// card style, proxies.dart).
    /// A plain VStack, NOT a NavigationStack: a NavigationStack
    /// inside a popover reports no usable ideal height, so the card
    /// rendered clipped to ~1 row (v0.2.27). The level is state, and
    /// the popover sizes itself to the VStack — the same as FlClash's
    /// PopupMenu sizing to its content.
    private enum MenuDestination: Hashable {
        case style, sort, layout, size, iconStyle
    }

    private enum MenuLevel: Hashable {
        case root
        case options(MenuDestination)
    }

    private var moreMenuPopover: some View {
        VStack(spacing: 0) {
            switch menuLevel {
            case .root:
                menuRow(icon: "list.bullet", label: "风格", destination: .style)
                menuRow(icon: "arrow.up.arrow.down", label: "排序", destination: .sort)
                menuRow(icon: "square.grid.2x2", label: "布局", destination: .layout)
                menuRow(icon: "textformat.size", label: "尺寸", destination: .size)
                if styleStore.style != .tab {
                    menuRow(icon: "photo", label: "图标样式", destination: .iconStyle)
                }
                Divider()
                    .padding(.vertical, 4)
                Button {
                    styleStore.hideTimeout.toggle()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .frame(width: 22)
                        Text("隐藏超时代理")
                        Spacer()
                        if styleStore.hideTimeout {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ConcordTheme.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .options(let dest):
                menuOptionsView(for: dest)
            }
        }
        .frame(minWidth: 160, maxWidth: 280)
        .font(.subheadline)
        .presentationCompactAdaptation(.popover)
        .onDisappear { menuLevel = .root }
    }

    private func menuRow(icon: String, label: String, destination: MenuDestination) -> some View {
        Button { menuLevel = .options(destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 22)
                Text(label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A submenu: a back header plus the options with a checkmark on
    /// the current value. Tapping one applies it and closes the menu,
    /// as FlClash's popup does on pick.
    private func menuOptionsView(for dest: MenuDestination) -> some View {
        VStack(spacing: 0) {
            Button { menuLevel = .root } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text(menuTitle(for: dest))
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            switch dest {
            case .style:
                ForEach(ProxyStyleStore.Style.allCases, id: \.self) { style in
                    menuOptionRow(label: style.label, selected: styleStore.style == style) {
                        styleStore.style = style
                    }
                }
            case .sort:
                ForEach(ProxySort.allCases) { option in
                    menuOptionRow(label: option.rawValue, selected: styleStore.sort == option) {
                        styleStore.sort = option
                    }
                }
            case .layout:
                ForEach(ProxyStyleStore.Layout.allCases, id: \.self) { layout in
                    menuOptionRow(label: layout.rawValue, selected: styleStore.layout == layout) {
                        styleStore.layout = layout
                    }
                }
            case .size:
                ForEach(ProxyStyleStore.CardType.allCases, id: \.self) { type in
                    menuOptionRow(label: type.rawValue, selected: styleStore.cardType == type) {
                        styleStore.cardType = type
                    }
                }
            case .iconStyle:
                ForEach(ProxyStyleStore.IconStyle.allCases, id: \.self) { style in
                    menuOptionRow(label: style.rawValue, selected: styleStore.iconStyle == style) {
                        styleStore.iconStyle = style
                    }
                }
            }
        }
    }

    private func menuTitle(for dest: MenuDestination) -> String {
        switch dest {
        case .style: return "风格"
        case .sort: return "排序"
        case .layout: return "布局"
        case .size: return "尺寸"
        case .iconStyle: return "图标样式"
        }
    }

    private func menuOptionRow(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showMoreMenu = false
        } label: {
            HStack(spacing: 12) {
                Text(label)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab style

    /// True while the pills strip overflows its viewport (FlClash
    /// group_tabs.dart shows the overflow button only when
    /// maxScrollExtent > 0). The strip's content width includes its
    /// 16pt side padding; the viewport is the page width.
    private func pillsOverflow(viewportWidth: CGFloat) -> Bool {
        pillsContentWidth > viewportWidth
    }

    private func tabContent(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // FlClash group_tabs.dart: the strip auto-centers the
            // selected chip, fades its right edge over 24pt, and
            // shows an overflow "More" button (chevron.down) when
            // the chips overflow, listing all groups (max 7 visible)
            // with a checkmark on the current one. The chip label
            // is subheadline semibold; unselected labels use the
            // onSurfaceVariant colour (.secondary here).
            ScrollViewReader { pillReader in
                HStack(spacing: 8) {
                    ZStack(alignment: .trailing) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(visibleGroups) { group in
                                    Button(group.name) {
                                        if selectedVisibleGroup?.id == group.id {
                                            scrollToSelected(in: group)
                                        } else {
                                            selectedGroupName = group.name
                                        }
                                    }
                                    .id("pill:\(group.name)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(selectedVisibleGroup?.id == group.id ? ConcordTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                                    .foregroundStyle(selectedVisibleGroup?.id == group.id ? .white : .secondary)
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: PillsWidthKey.self, value: proxy.size.width)
                                }
                            )
                        }
                        // Right-edge fade (group_tabs.dart: 24px
                        // ShaderMask), only while the strip
                        // overflows. It sits at the strip's right
                        // edge, where the fixed More button begins.
                        if pillsOverflow(viewportWidth: width) {
                            LinearGradient(
                                colors: [ConcordTheme.pageBackground.opacity(0), ConcordTheme.pageBackground],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 24)
                            .allowsHitTesting(false)
                        }
                    }
                    if pillsOverflow(viewportWidth: width) {
                        Button { showGroupPicker = true } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 19, weight: .semibold))
                                .imageScale(.medium)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("全部策略组")
                        .background(ConcordTheme.cardBackground, in: Circle())
                        .popover(isPresented: $showGroupPicker, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                            groupPickerPopover
                        }
                    }
                }
                .onPreferenceChange(PillsWidthKey.self) { pillsContentWidth = $0 }
                .onChange(of: selectedVisibleGroup?.id) { _, _ in
                    if let id = selectedVisibleGroup?.id {
                        withAnimation { pillReader.scrollTo("pill:\(id)", anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = selectedVisibleGroup?.id {
                        pillReader.scrollTo("pill:\(id)", anchor: .center)
                    }
                }
            }
            .padding(.vertical, 6)

            if let group = selectedVisibleGroup {
                Text("\(group.type) · \(group.nodes.count) 个节点 · 当前：\(group.selectedNodeName ?? "未选择")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                localFallbackNote
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                            ForEach(group.nodes) { node in
                                nodeCard(node, in: group)
                                    .id(scrollID(nodeName: node.name, groupName: group.name))
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            withAnimation { reader.scrollTo(target, anchor: .center) }
                        }
                    }
                    .refreshable { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                }
            } else if proxyStore.groups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searching {
                ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
            } else {
                noGroupsView
            }
        }
    }

    /// The overflow picker's list (FlClash group_tabs.dart
    /// _OverflowMenuButton: all groups, max 7 visible, checkmark on
    /// the current one). Tapping one selects it (the strip
    /// auto-centers it via the onChange above) and closes.
    private var groupPickerPopover: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(visibleGroups) { group in
                    Button {
                        selectedGroupName = group.name
                        showGroupPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            Text(group.name)
                            Spacer()
                            if selectedVisibleGroup?.id == group.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 160, maxWidth: 280, maxHeight: 308)
        .font(.subheadline)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - List style

    private func listContent(width: CGFloat) -> some View {
        Group {
            if proxyStore.groups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGroups.isEmpty && searching {
                ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
            } else if visibleGroups.isEmpty {
                noGroupsView
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            localFallbackNote
                            ForEach(visibleGroups) { group in
                                groupSection(group, width: width)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            // Group headers scroll to the top of the
                            // viewport; nodes scroll to the centre.
                            let anchor: UnitPoint = target.hasPrefix("groupHeader:") ? .top : .center
                            withAnimation { reader.scrollTo(target, anchor: anchor) }
                        }
                    }
                    .refreshable { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                }
            }
        }
    }

    // MARK: - Card style (MuYu-only, lib/views/proxies/list.dart icons mode + icon_card.dart)

    private func iconsContent(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            folderBar
            localFallbackNote
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            Group {
                if proxyStore.groups.isEmpty && proxyStore.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if iconFolder == .leafNodes && leafNodeEntries.isEmpty && searching {
                    ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
                } else if iconFolder == .leafNodes && leafNodeEntries.isEmpty {
                    noGroupsView
                } else if folderGroups.isEmpty && searching {
                    ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
                } else if folderGroups.isEmpty {
                    noGroupsView
                } else if iconFolder == .leafNodes {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                                ForEach(leafNodeEntries) { entry in
                                    nodeCard(entry.node, in: entry.group)
                                        .id(scrollID(nodeName: entry.node.name, groupName: entry.group.name))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: scrollNonce) { _, _ in
                            if let target = scrollTargetName {
                                withAnimation { reader.scrollTo(target, anchor: .center) }
                            }
                        }
                        .refreshable { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                    }
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                                ForEach(folderGroups) { group in
                                    iconGroupSection(group, width: width)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: scrollNonce) { _, _ in
                            if let target = scrollTargetName {
                                // Group cards scroll to the top of
                                // the viewport; nodes to the centre.
                                let anchor: UnitPoint = target.hasPrefix("groupHeader:") ? .top : .center
                                withAnimation { reader.scrollTo(target, anchor: anchor) }
                            }
                        }
                        .refreshable { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                    }
                }
            }
        }
    }

    /// The folder bar (MuYu list.dart _FolderBar): four pills with
    /// counts, 40pt high, fixed above the grid (MuYu pins it as a
    /// second PinnedHeaderSliver — same visible behaviour). Only in
    /// card style; the list style shows every group, as before.
    private var folderBar: some View {
        HStack(spacing: 8) {
            ForEach(ProxyFolder.allCases, id: \.self) { folder in
                let selected = iconFolder == folder
                Button { iconFolder = folder } label: {
                    HStack(spacing: 2) {
                        Image(systemName: folder.systemImage)
                            .font(.system(size: 14))
                        Text(folder.label)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("\(folderCount(folder))")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(selected ? ConcordTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                    .foregroundStyle(selected ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// One group in card style: the brand-icon card, and — when
    /// unfolded — its nodes in a full-width grid below it (MuYu
    /// _buildIconSegments: collapsed groups pair side-by-side,
    /// an expanded group takes the full width alone).
    private func iconGroupSection(_ group: ProxyGroup, width: CGFloat) -> some View {
        let expanded = expandedGroups.contains(group.name)
        return VStack(spacing: 8) {
            iconCard(group)
                .id(groupHeaderID(group.name))
            if expanded {
                LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                    ForEach(displayNodes(for: group)) { node in
                        nodeCard(node, in: group)
                            .id(scrollID(nodeName: node.name, groupName: group.name))
                    }
                }
            }
        }
        .gridCellColumns(expanded ? 2 : 1)
    }

    /// The brand-icon card (MuYu icon_card.dart GroupIconCard):
    /// name + brand icon, "TYPE · n/m" subtitle (+ the per-group
    /// search field when unfolded), then the bottom row with the
    /// selected node and the latency pill. Tapping the card toggles
    /// it; tapping the pill tests the group. Per-node up/down
    /// speeds (MuYu _SelectedSpeeds) are NOT shown: the Concord
    /// core exposes no per-node traffic (proxy.states has alive /
    /// UDP / history only).
    private func iconCard(_ group: ProxyGroup) -> some View {
        let m = iconCardMetrics()
        let expanded = expandedGroups.contains(group.name)
        let selectedName = group.selectedNodeName
        let selectedIcon = selectedNodeIcon(for: group)
        let latency = selectedNodeLatency(for: group)
        let testing = proxyStore.testingGroups.contains(group.name)
        let total = proxyStore.groups.first(where: { $0.name == group.name })?.nodes.count ?? group.nodes.count
        // A tap gesture, NOT a Button: the card holds the latency
        // pill Button and the search TextField, and a Button label
        // swallows their touches (tapping the field would collapse
        // the card instead of focusing it). The pill Button and the
        // field take priority over this gesture for their own taps.
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: m.nameIconGap) {
                Text(group.name)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if styleStore.iconStyle != .hidden {
                    GroupBrandIconView(icon: group.icon, name: group.name, size: m.brandSize, iconStyle: styleStore.iconStyle)
                }
            }
            Spacer().frame(height: m.metaGap)
            HStack(spacing: 8) {
                Text("\(Self.typeDisplayName(group.type)) · \(availableCount(for: group))/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if expanded {
                    groupSearchControl(for: group)
                }
            }
            Spacer(minLength: m.bottomGap)
            HStack(spacing: m.nameIconGap) {
                if let selectedName {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    if let selectedIcon {
                        GroupBrandIconView(icon: selectedIcon, name: selectedName, size: 16, iconStyle: .plain)
                    }
                    Text(selectedName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if group.type == "load-balance" {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("负载均衡")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer()
                }
                Spacer()
                if selectedName != nil {
                    iconCardLatencyPill(group: group, latencyMs: latency, testing: testing)
                }
                // MuYu aligns the pill's right edge with the
                // brand icon above it (icon_card.dart:273-274).
                if styleStore.iconStyle == .filled {
                    Spacer().frame(width: 6)
                }
            }
            .frame(height: 24)
        }
        .padding(m.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: expanded ? nil : iconCardCollapsedHeight(for: group), alignment: .top)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .onTapGesture {
            if expanded {
                expandedGroups.remove(group.name)
            } else {
                expandedGroups.insert(group.name)
                Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    scrollTargetName = groupHeaderID(group.name)
                    scrollNonce += 1
                }
            }
        }
    }

    /// The selected node's group icon for the card's bottom row
    /// (MuYu _SelectedProxy: groups.getGroup(proxyName)?.icon).
    /// Only when the selected node is itself a group with an icon;
    /// a node with no icon shows no monogram there.
    private func selectedNodeIcon(for group: ProxyGroup) -> String? {
        guard let selected = group.selectedNodeName,
              let sub = proxyStore.groups.first(where: { $0.name == selected }),
              !sub.icon.isEmpty else { return nil }
        return sub.icon
    }

    /// The selected node's resolved delay for the latency pill
    /// (MuYu _SelectedDelay reads the delay map). Looked up in the
    /// RAW group: the visible copy may have filtered the selected
    /// node out while searching.
    private func selectedNodeLatency(for group: ProxyGroup) -> Int32? {
        guard let selected = group.selectedNodeName else { return nil }
        return proxyStore.groups.first(where: { $0.name == group.name })?
            .nodes.first(where: { $0.name == selected })?.latencyMs
    }

    /// The latency pill (MuYu icon_card.dart _SelectedDelay): the
    /// bare number, no "ms" suffix; bolt when untested, spinner
    /// while testing. Tapping tests the group. While a test runs
    /// the pill is deliberately neutral instead of keeping the last
    /// delay's colour.
    private func iconCardLatencyPill(group: ProxyGroup, latencyMs: Int32?, testing: Bool) -> some View {
        let color: Color = {
            if testing { return .secondary }
            guard let ms = latencyMs else { return .secondary }
            if ms > 0 { return ms < 600 ? .green : .orange }
            return .red
        }()
        return Button {
            Task { await proxyStore.testLatency(group: group, nodeNames: searchMatchedNodeNames(forGroupNamed: group.name)) }
        } label: {
            Group {
                if testing {
                    ProgressView()
                        .frame(width: 14, height: 14)
                        .scaleEffect(0.7)
                } else if let ms = latencyMs {
                    if ms > 0 {
                        Text("\(ms)")
                    } else {
                        Text(ms == -1 ? "超时" : "失败")
                    }
                } else {
                    Image(systemName: "bolt")
                        .font(.system(size: 14))
                }
            }
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(testing)
    }

    /// The "no groups" empty state: the "import a subscription"
    /// wording only applies when there genuinely is no active
    /// profile. When a profile IS active but yields no groups (empty
    /// subscription, unparsable file), say so instead of telling the
    /// user to import one they already have.
    @ViewBuilder
    private var noGroupsView: some View {
        if profileStore.activeProfile == nil {
            ContentUnavailableView("暂无代理组", systemImage: "globe", description: Text("请先在“订阅”页导入并激活一个订阅"))
        } else {
            ContentUnavailableView("该订阅中没有代理组", systemImage: "globe", description: Text("当前订阅没有 proxies 或 proxy-groups，无法显示节点"))
        }
    }

    /// Shown while the list comes from the local YAML (VPN off).
    @ViewBuilder
    private var localFallbackNote: some View {
        if proxyStore.isLocalFallback {
            Text("本地配置 · 未连接 VPN — 点按节点会记住选择，启动后自动应用")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func groupSection(_ group: ProxyGroup, width: CGFloat) -> some View {
        let expanded = expandedGroups.contains(group.name)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                groupIcon(group)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    // FlClash ListHeader: the subtitle is the
                    // selected node name whenever there is one,
                    // hidden entirely when there is none — in both
                    // states. The old code showed the group type
                    // when collapsed (duplicating the trailing type
                    // text) and "未选择" when expanded. The minHeight
                    // keeps the two-line header height stable when
                    // the subtitle is empty (upstream's header is a
                    // fixed 61pt).
                    Text(group.selectedNodeName ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minHeight: 13, alignment: .leading)
                }
                Spacer()
                if expanded {
                    groupSearchControl(for: group)
                    RoundedBarButton(systemName: "location.fill", label: "滚动到已选", size: 28) {
                        scrollToSelectedInList(group)
                    }
                    let testing = proxyStore.testingGroups.contains(group.name)
                    Button {
                        Task { await proxyStore.testLatency(group: group, nodeNames: searchMatchedNodeNames(forGroupNamed: group.name)) }
                    } label: {
                        if testing {
                            ProgressView()
                                .frame(width: 28, height: 28)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "bolt.fill")
                                .frame(width: 28, height: 28)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(testing)
                } else {
                    Text(group.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded {
                    expandedGroups.remove(group.name)
                } else {
                    expandedGroups.insert(group.name)
                    // FlClash _handleChange (list.dart:45-60) scrolls
                    // the group into view on every toggle; collapsing
                    // needs none (the header stays put), but an
                    // expanding group does — once its rows are laid out.
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        scrollTargetName = groupHeaderID(group.name)
                        scrollNonce += 1
                    }
                }
            }
            if expanded {
                LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                    // The group's own search keyword filters only
                    // this group (MuYu GroupSearchControl); the
                    // page search / hide-timeout / sort already
                    // applied by visibleGroups.
                    ForEach(displayNodes(for: group)) { node in
                        nodeCard(node, in: group)
                            .id(scrollID(nodeName: node.name, groupName: group.name))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .id(groupHeaderID(group.name))
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private func groupHeaderID(_ groupName: String) -> String {
        "groupHeader:\(groupName)"
    }

    /// Per-group search (MuYu GroupSearchControl, common.dart):
    /// a magnifier that opens a 128pt field filtering only this
    /// group's nodes. The clear button clears the keyword AND
    /// closes the field (MuYu _close). Autofocus on open; the
    /// keyword entry is removed when the text becomes empty.
    @ViewBuilder
    private func groupSearchControl(for group: ProxyGroup) -> some View {
        if groupSearchOpen.contains(group.name) {
            HStack(spacing: 4) {
                TextField("搜索", text: Binding(
                    get: { groupSearchKeywords[group.name] ?? "" },
                    set: { new in
                        if new.isEmpty {
                            groupSearchKeywords.removeValue(forKey: group.name)
                        } else {
                            groupSearchKeywords[group.name] = new
                        }
                    }
                ))
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($groupSearchFocus, equals: group.name)
                .frame(width: 128)
                Button {
                    groupSearchKeywords.removeValue(forKey: group.name)
                    groupSearchOpen.remove(group.name)
                    groupSearchFocus = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { groupSearchFocus = group.name }
        } else {
            Button {
                groupSearchOpen.insert(group.name)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索此组")
        }
    }

    /// Group icon (FlClash _GroupIcon): the profile's icon when it
    /// is a URL (loaded) or short text (shown as-is), else the
    /// group's first character. Filled puts it in a rounded tile,
    /// plain shows it bare, hidden leaves a small gap so the title
    /// lines up with the card names below.
    private func groupIcon(_ group: ProxyGroup) -> some View {
        let monogram = String(group.name.prefix(1))
        let isURL = group.icon.hasPrefix("http")
        let text = group.icon.isEmpty ? monogram : (isURL ? monogram : group.icon)
        let content: some View = Group {
            if isURL, let url = URL(string: group.icon) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(monogram)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        switch styleStore.iconStyle {
        case .hidden:
            return AnyView(Color.clear.frame(width: 4, height: 28))
        case .plain:
            return AnyView(
                content
                    .foregroundStyle(ConcordTheme.accent)
                    .frame(width: 28, height: 28)
            )
        case .filled:
            return AnyView(
                content
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            )
        }
    }

    // MARK: - Node card

    /// Loose cards show the node's description: for a node that is
    /// itself a group, its type plus the node it currently selects
    /// (FlClash _ProxyDesc); otherwise just the type.
    private func nodeDescription(_ node: ProxyNode) -> String {
        guard Self.groupTypes.contains(node.type),
              let sub = proxyStore.groups.first(where: { $0.name == node.name }),
              let selected = sub.selectedNodeName, selected != node.name else {
            return node.type
        }
        return "\(node.type)(\(selected))"
    }

    private func nodeCard(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        ProxyNodeCard(
            name: node.name,
            type: node.type,
            description: nodeDescription(node),
            latencyMs: node.latencyMs,
            testing: proxyStore.testingNodes.contains(node.name),
            pinned: group.fixed == node.name,
            selected: group.selectedNodeName == node.name,
            cardType: styleStore.cardType,
            cardHeight: cardHeight,
            iconSymbol: iconSetStore.symbol(for: node.type),
            iconColor: iconSetStore.color(for: node.type),
            memberIcon: memberIcon(for: node),
            onTest: { Task { await proxyStore.testLatency(node: node, testURL: nodeTestURL(group)) } }
        )
        .equatable()
        .onTapGesture { Task { await selectNode(node, in: group) } }
        .contextMenu { nodeMenu(node, in: group) }
    }

    private func nodeMenu(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        Group {
            let pinned = group.fixed == node.name
            let selected = group.selectedNodeName == node.name
            // FlClash card.dart:120-145: a constant label ("选择" for
            // Selector, "首选" for url-test/fallback) with a checkmark
            // on the current state — the label never toggles.
            if group.type == "select" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    HStack {
                        Text("选择")
                        Spacer()
                        if selected { Image(systemName: "checkmark") }
                    }
                }
            } else if group.type == "url-test" || group.type == "fallback" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    HStack {
                        Text("首选")
                        Spacer()
                        if pinned { Image(systemName: "checkmark") }
                    }
                }
            }
            if isAddable(node) {
                Button { Task { await addToLocal(node: node) } } label: {
                    Label("添加到本地节点", systemImage: "plus.square.on.square")
                }
            }
            Button { Task { await proxyStore.testLatency(node: node, testURL: nodeTestURL(group)) } } label: {
                Label("测速", systemImage: "bolt")
            }
            Button {
                detailTestURL = nodeTestURL(group)
                detailNode = node
            } label: {
                Label("节点详情", systemImage: "info.circle")
            }
        }
    }

    /// The group's test URL for a single-node delay test (FlClash
    /// _handleTestCurrentDelay, card.dart:273-283); nil when the
    /// group has none — ProxyStore then falls back to the stored
    /// override test-url (audit B24), and the core default after
    /// that. Nested groups are resolved inside ProxyStore.
    private func nodeTestURL(_ group: ProxyGroup) -> String? {
        group.testUrl.isEmpty ? nil : group.testUrl
    }

    private func isAddable(_ node: ProxyNode) -> Bool {
        // FlClash _isAddableToLocal (card.dart:37-41): addable when
        // the node came from a provider or the profile is not
        // custom, and the name is not reserved and the node is not
        // itself a group. Our "本地文件" profile is the
        // custom-profile analogue: its own proxies are already local.
        let fromProviderOrNotCustom = node.provider != nil || profileStore.activeProfile?.kind != .file
        return fromProviderOrNotCustom
            && !Self.groupTypes.contains(node.type)
            && !Self.reservedNames.contains(node.name)
    }

    // MARK: - Actions

    private func selectNode(_ node: ProxyNode, in group: ProxyGroup) async {
        if let note = await proxyStore.select(node: node, in: group, profileID: profileStore.activeProfile?.id) {
            showNotice(note)
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if notice == text { notice = nil }
        }
    }

    private func scrollID(nodeName: String, groupName: String) -> String {
        "\(groupName).\(nodeName)"
    }

    private func scrollToSelected(in group: ProxyGroup?) {
        guard let group, let selected = group.selectedNodeName else { return }
        scrollTargetName = scrollID(nodeName: selected, groupName: group.name)
        scrollNonce += 1
    }

    /// List style: expand a collapsed group first, then scroll once
    /// its cards are laid out.
    private func scrollToSelectedInList(_ group: ProxyGroup) {
        if !expandedGroups.contains(group.name) {
            expandedGroups.insert(group.name)
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                scrollToSelected(in: group)
            }
        } else {
            scrollToSelected(in: group)
        }
    }

    /// Add a node to the local proxies (FlClash addToLocalProxies):
    /// the full definition is kept whole (rawProxies) so transport
    /// options survive, validated against the core first, then
    /// baked into the active profile.
    private func addToLocal(node: ProxyNode) async {
        do {
            let definition = try await client.proxyDefinition(name: node.name)
            guard case .object(let dict) = definition, dict["name"]?.stringValue == node.name else {
                showNotice("读取节点配置失败")
                return
            }
            let issues = try await client.validateProxies(proxies: [definition])
            if let first = issues.first {
                showNotice("节点校验未通过：\(first.message)")
                return
            }
            if customStore.proxies.contains(where: { $0.name == node.name })
                || customStore.rawProxies.contains(where: { $0.objectValue?["name"]?.stringValue == node.name }) {
                showNotice("已在本地节点中")
                return
            }
            customStore.rawProxies.append(definition)
            customStore.save()
            guard var text = profileStore.activeProfileYAML() else {
                showNotice("没有可写入的当前配置（先导入一个订阅）")
                return
            }
            text = CustomProxyStore.bakeCurrent(into: text)
            let saved = await profileStore.saveActiveProfileYAML(text)
            showNotice("已添加到本地节点：\(saved)")
        } catch {
            showNotice("加入失败：\(error.localizedDescription)")
        }
    }
}

/// A group's brand icon at any size (MuYu _GroupBrandIcon,
/// widgets/icon.dart): the profile's icon URL (loaded) or short
/// text, else the group's first character. Filled = rounded tile
/// with 6pt inner padding, plain = bare in the accent colour,
/// hidden = nothing. The MuYu brandIconFor(name) → SVG asset
/// fallback (Google/GitHub/Apple…) has no equivalent here: we
/// ship no SVG assets, so a group with no profile icon falls back
/// to its monogram, as the list header already does.
private struct GroupBrandIconView: View {
    let icon: String
    let name: String
    let size: CGFloat
    let iconStyle: ProxyStyleStore.IconStyle

    var body: some View {
        let monogram = String(name.prefix(1))
        let isURL = icon.hasPrefix("http")
        let text = icon.isEmpty ? monogram : (isURL ? monogram : icon)
        let content: some View = Group {
            if isURL, let url = URL(string: icon) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(monogram)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        switch iconStyle {
        case .hidden:
            EmptyView()
        case .plain:
            content
                .foregroundStyle(ConcordTheme.accent)
                .frame(width: size, height: size)
        case .filled:
            content
                .frame(width: max(size - 12, 4), height: max(size - 12, 4))
                .frame(width: size, height: size)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// One proxy card as its own view, fed only by plain values.
/// The old nodeCard(_:in:) was a function on ProxiesView, so every
/// @Published change in ProxyStore — each delay-test result landing,
/// each testing-flag flip — rebuilt every visible card's body while
/// the user scrolled. As an Equatable struct with narrow inputs,
/// SwiftUI skips a row whose own values did not change, so a
/// latency landing on one node no longer re-renders the other 40+
/// cards. The card also drops its .shadow: upstream FlClash's Card
/// has no drop shadow (prism_ui Card / PressSurface: fill + shape
/// only, elevation 0), and in SwiftUI a shadow costs an offscreen
/// render pass per card — the classic scrolling-jank source in a
/// grid of cards. The fill, corner radius, text and layout are
/// unchanged; the shadow was 5% black and is visually negligible.
private struct ProxyNodeCard: View, Equatable {
    let name: String
    let type: String
    /// Precomputed description: loose cards show "type(selected)",
    /// other sizes show the plain type (see nodeDescription).
    let description: String
    let latencyMs: Int32?
    let testing: Bool
    let pinned: Bool
    let selected: Bool
    let cardType: ProxyStyleStore.CardType
    let cardHeight: CGFloat
    let iconSymbol: String
    let iconColor: Color
    /// The nested group's profile icon, for nodes that are
    /// themselves groups (MuYu card.dart member icon, 16pt).
    /// Nil for leaf nodes — the core exposes no per-node icon.
    let memberIcon: String?
    let onTest: () -> Void

    // Closures are not Equatable: compare everything else, and
    // treat the test action as always equal (it only fires on tap).
    static func == (lhs: ProxyNodeCard, rhs: ProxyNodeCard) -> Bool {
        lhs.name == rhs.name
            && lhs.type == rhs.type
            && lhs.description == rhs.description
            && lhs.latencyMs == rhs.latencyMs
            && lhs.testing == rhs.testing
            && lhs.pinned == rhs.pinned
            && lhs.selected == rhs.selected
            && lhs.cardType == rhs.cardType
            && lhs.cardHeight == rhs.cardHeight
            && lhs.iconSymbol == rhs.iconSymbol
            && lhs.iconColor == rhs.iconColor
            && lhs.memberIcon == rhs.memberIcon
    }

    var body: some View {
        // FlClash card.dart: name is subheadline (15pt), the
        // type/description line is footnote (13pt), the delay is
        // caption2 (11pt). The card's padding is horizontal 12 only;
        // the content is vertically centred in the fixed height
        // (the formula's 16pt vertical slack = 10pt top + 10pt
        // bottom at standard size). Name→details gap is 8pt;
        // loose cards add a 6pt gap before the delay row.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                if let memberIcon {
                    GroupBrandIconView(icon: memberIcon, name: name, size: 16, iconStyle: .plain)
                }
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(cardType == .compact ? 1 : 2)
                Spacer()
                if pinned {
                    // FlClash SelectionBadge: a 22pt circle —
                    // solid primary + white pin when in use, tonal
                    // primary (14%) + primary pin when pinned but
                    // not in use.
                    ZStack {
                        Circle()
                            .fill(selected ? ConcordTheme.accent : ConcordTheme.accent.opacity(0.14))
                            .frame(width: 22, height: 22)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? .white : ConcordTheme.accent)
                    }
                } else if selected {
                    // FlClash SelectionBadge: 22pt primary circle
                    // + white check glyph (the old code hardcoded
                    // .blue and used the SF circle glyph).
                    ZStack {
                        Circle()
                            .fill(ConcordTheme.accent)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            if cardType == .loose {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: iconSymbol)
                            .font(.system(size: 10))
                            .foregroundStyle(iconColor)
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button(action: onTest) {
                        DelayText(latencyMs: latencyMs, testing: testing)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    Image(systemName: iconSymbol)
                        .font(.system(size: 10))
                        .foregroundStyle(iconColor)
                    Text(type)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: onTest) {
                        DelayText(latencyMs: latencyMs, testing: testing)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cardHeight, alignment: .center)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}

/// Delay text, FlClash _DelayText (card.dart:258-400): plain text,
/// no capsule. <600ms success green, >=600ms warning orange, <0
/// error red; -1 is 超时, other negatives 测速失败
/// (ui/delay_color.dart:5-10, common/app_localizations.dart:130-134).
/// Untested shows the bolt glyph, as in FlClash.
private struct DelayText: View {
    let latencyMs: Int32?
    /// While this node's test runs (FlClash shows an ActivityIndicator
    /// for DelayTestPhase.running); without it the tap shows nothing
    /// until the result lands.
    var testing: Bool = false

    var body: some View {
        Group {
            if testing {
                ProgressView()
                    .frame(width: 12, height: 12)
                    .scaleEffect(0.7)
            } else if let ms = latencyMs {
                if ms > 0 {
                    Text("\(ms) ms")
                        .foregroundStyle(ms < 600 ? Color.green : Color.orange)
                } else {
                    Text(ms == -1 ? "超时" : "测速失败")
                        .foregroundStyle(Color.red)
                }
            } else {
                Image(systemName: "bolt")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .fontWeight(.semibold)
    }
}

/// A top bar button as FlClash draws it: a rounded rect, not a bare
/// glyph (used for the bolt, the locate button and the ⋯ menu's
/// label via its own frame).
private struct RoundedBarButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: size, height: size)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: size == 32 ? 10 : 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// Node detail sheet (FlClash proxy card detail). Loads the node's
// configured definition (proxy.definition) and live state
// (proxy.states) from the core when it opens.
struct NodeDetailView: View {
    let node: ProxyNode
    /// The owning group's test URL, so the 测速 button here probes
    /// the same URL as the card's delay chip (FlClash
    /// _handleTestCurrentDelay).
    let testURL: String?
    @EnvironmentObject private var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ProxyStore.NodeDetail?

    var body: some View {
        NavigationStack {
            List {
                Section("节点") {
                    LabeledContent("名称", value: node.name)
                    LabeledContent("类型", value: node.type)
                    LabeledContent("提供方", value: node.provider ?? "—")
                    LabeledContent("延迟", value: ConcordFormat.latency(node.latencyMs))
                    if let state = detail?.state {
                        LabeledContent("存活", value: state.alive ? "是" : "否")
                        LabeledContent("UDP", value: state.udp ? "支持" : "不支持")
                        if let last = state.history.last {
                            LabeledContent("上次延迟", value: last.delay == 0 ? "失败" : "\(last.delay) ms")
                        }
                    }
                }
                Section {
                    Button("测速") {
                        Task { await proxyStore.testLatency(node: node, testURL: testURL) }
                    }
                }
                if let definition = detail?.definition {
                    Section("配置（proxy.definition）") {
                        JSONValueView(value: definition)
                            .frame(minHeight: 120)
                    }
                } else if let error = detail?.error {
                    Section {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        ProgressView()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("title.nodeDetail".l10n)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                detail = await proxyStore.fetchNodeDetail(name: node.name)
            }
        }
    }
}

/// Confirmation sheet for the rule-set repair (v0.2.46 ITEM 1):
/// shows the exact YAML lines the repair will add / remove and
/// requires an explicit tap — nothing is written from the banner
/// alone. Unrepairable plans show the reason with no confirm
/// button. While a confirmed repair is writing + re-applying,
/// the button becomes a spinner.
/// Repair-ALL confirmation sheet (v0.2.49): every rule set the
/// core reported missing, each with its action and exact lines,
/// one confirm for all of them. The sheet stays open after
/// confirm: the outcome (success or the remaining problem) is
/// shown INLINE here, never as a fresh banner pop.
private struct RuleSetRepairSheet: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    let plan: RuleSetRepairAllPlan

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.summary)
                        .font(.system(size: 14))
                    if let blockingIssue = plan.blockingIssue {
                        Text(blockingIssue)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("「\(item.missingName)」")
                                    .font(.footnote.weight(.semibold))
                                Text(item.actionTitle)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(itemActionColor(item.kind).opacity(0.15), in: Capsule())
                                    .foregroundStyle(itemActionColor(item.kind))
                            }
                            if !item.previewLines.isEmpty {
                                Text(item.previewTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text(item.previewLines.joined(separator: "\n"))
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(10)
                                }
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    if plan.isRepairable {
                        Text("确认后一次性写入当前订阅文件并重新应用配置，然后重测一次；若仍有问题，结果会直接显示在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let outcome = proxyStore.ruleSetRepairOutcome {
                        Text(outcome)
                            .font(.footnote)
                            .foregroundStyle(proxyStore.ruleSetRepairOutcomeIsSuccess ? .green : .red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((proxyStore.ruleSetRepairOutcomeIsSuccess ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
            .navigationTitle("修复缺失的规则集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(proxyStore.ruleSetRepairOutcome == nil ? "取消" : "完成") {
                        proxyStore.dismissRuleSetRepair()
                        dismiss()
                    }
                }
                if plan.isRepairable && proxyStore.ruleSetRepairOutcome == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if proxyStore.isRepairingRuleSet {
                            ProgressView()
                        } else {
                            Button(plan.confirmTitle) {
                                Task { await proxyStore.confirmRuleSetRepair() }
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private func itemActionColor(_ kind: RuleSetRepairPlan.Kind) -> Color {
        switch kind {
        case .complete: return .blue
        case .delete: return .orange
        case .unrepairable: return .red
        }
    }
}
