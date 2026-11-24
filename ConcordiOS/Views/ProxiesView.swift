import SwiftUI

// MARK: - Proxies (FlClash: ProxiesView, lib/views/proxies/)
// FlClash proxies page, reproduced in SwiftUI:
// - Top bar: ONE capsule (FlClash TonalButtonGroup) holding search
//   (magnifier, presents the search field) + bolt. In tab style the
//   bolt tests the current group; in list / card style it tests ALL
//   groups (MuYu iOS build _delayTestAllGroups). The ⋯ opens a white
//   card menu (FlClash PopupMenu): 风格 expands inline (MuYu
//   video: the three style rows sit directly below it in the same
//   popup); 排序/布局/尺寸/图标样式 each open a submenu with a
//   checkmark on the current value, plus 隐藏超时代理. No test-all
//   and no refresh in the menu (FlClash
//   has neither there). 滚动到已选 is the menu's first row in tab
//   style (the MuYu video build shows it there); re-tapping the
//   active group pill scrolls to the selected node too. The page
//   title is the 24pt pageTitle (FlClash
//   scaffold: compactTitle is false on a tab page — only sheets and
//   pushed pages use the 17pt headline), rendered as a leading
//   toolbar item because SwiftUI's inline title is fixed at 17pt.
// - Style 标签页： group pills on top, one group's nodes as cards in
//   a grid. Style 列表 (v0.2.68, video f_040): every group an
//   independent rounded card (brand icon, name + selected node,
//   type + gray-circle chevron); tapping expands the group inline,
//   nodes inside the same card. Style 卡片
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
    /// folder, leafNodes → two overlapping rectangles.
    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .strategy: return "folder"
        case .nodes: return "folder"
        case .leafNodes: return "rectangle.on.rectangle"
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
    /// Picker mode (FlClash proxies.dart:14-18,157,165,174):
    /// as a dashboard sheet the page keeps only search + delay
    /// test — the ⋯ menu is stripped and the locate button hidden.
    /// v0.2.64: the dashboard's 策略组 card presents this in
    /// picker mode (upstream showProxiesSheet), forcing the card
    /// grid regardless of the tab's style, with a sheet header
    /// (✕ + 代理 + a standalone bolt circle, v0.2.68 video f_018:
    /// two separate white circles, no magnifier, no ⋯) instead of
    /// the 24pt tab title, and a bottom floating search bar.
    /// `onPickGroup`, when set, is called with the picked
    /// group's name instead of expanding it — the dashboard sheet
    /// uses it to select the group, dismiss, and switch to the
    /// Proxies tab. Default false / nil (the tab page).
    let picker: Bool
    let onPickGroup: ((String) -> Void)?

    init(picker: Bool = false, onPickGroup: ((String) -> Void)? = nil) {
        self.picker = picker
        self.onPickGroup = onPickGroup
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var styleStore: ProxyStyleStore
    /// Observed so the page re-renders when the outbound mode
    /// changes (v0.2.53 mode filtering): ProxyStore.displayGroups
    /// reads settingsStore.mode, but the store does not publish
    /// mode changes itself, so the view must observe the mode
    /// directly or the list would not refresh on a mode switch.
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var customStore = CustomProxyStore()
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showMoreMenu = false
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
    /// Focus for the page search field (v0.2.56): the field is a
    /// plain TextField shown only while isSearching, NOT SwiftUI's
    /// .searchable — see the searchField below.
    @FocusState private var searchFieldFocused: Bool
    /// Tab style: the overflow "More" picker (FlClash group_tabs.dart
    /// _OverflowMenuButton) and the pills strip measurement that
    /// decides whether it (and the 24pt right-edge fade) shows.
    @State private var showGroupPicker = false
    @State private var pillsContentWidth: CGFloat = 0

    private static let groupTypes: Set<String> = ["select", "url-test", "fallback", "load-balance", "relay", "smart"]
    /// Built-in adapters whose delay probe always fails, so a timeout
    /// says nothing (FlClash _unprobeableProxyTypes,
    /// common/compute.dart:60-64). DIRECT is deliberately absent:
    /// FlClash does not keep it. Spelling is FlClash's; the
    /// comparison below is case- and hyphen-insensitive because the
    /// Rust core spells these "REJECT-DROP"/"DIRECT" style.
    /// v0.2.68 verified: this set is used ONLY by
    /// keepWhenHidingTimeout (hide-timeout keeps these nodes, as
    /// FlClash's computeHideTimeout does) — it NEVER skips a delay
    /// test. DIRECT / REJECT are dial-tested like any other node
    /// (ProxyStore.testLatency / resolveDelayTarget have no type
    /// filter), so their real results render as latency / 超时 /
    /// 失败; no display mapping is needed.
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
        guard let raw = proxyStore.displayGroups.first(where: { $0.name == name }) else { return [] }
        return raw.nodes.filter(matchesSearch).map(\.name)
    }

    private var selectedGroup: ProxyGroup? {
        if let name = proxyStore.selectedGroupName {
            return proxyStore.displayGroups.first { $0.name == name }
        }
        return proxyStore.displayGroups.first
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
        // This set deliberately uses the FULL group list, not the
        // mode-filtered one: a member that is itself a group — even
        // a hidden one — is still a group, so hide-timeout keeps it
        // and the delay sort ranks it as a group.
        let groupNames = Set(proxyStore.groups.map(\.name))
        var out: [ProxyGroup] = []
        // The enumeration is the mode-filtered list (v0.2.53):
        // rule mode drops hidden groups, global mode keeps them,
        // direct mode shows none.
        for group in proxyStore.displayGroups {
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
        if let name = proxyStore.selectedGroupName,
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

    /// Folder counts, from the mode-filtered groups (MuYu counts
    /// from allGroups = groupsProvider, not the search-filtered
    /// list — "raw" here means before search filtering, and the
    /// provider itself is already mode-filtered).
    private func folderCount(_ folder: ProxyFolder) -> Int {
        switch folder {
        case .all: return proxyStore.displayGroups.count
        case .strategy: return proxyStore.displayGroups.filter { !isNodeOnlyGroup($0) }.count
        case .nodes: return proxyStore.displayGroups.filter { isNodeOnlyGroup($0) }.count
        case .leafNodes: return leafNodeEntries.count
        }
    }

    /// Visible groups after the folder filter (MuYu
    /// filterGroupsByFolder). `leafNodes` returns [] — the flat view
    /// replaces the group list entirely. Groups that are members
    /// of a currently-expanded group are excluded (v0.2.68): they
    /// are already visible as member cards inside the expanded
    /// parent, so listing them again as their own cards below
    /// duplicated them (顺畅网络 expanded showed 自动选择/故障转移
    /// twice). They reappear as cards when the parent collapses.
    /// An expanded group itself is never excluded.
    private var folderGroups: [ProxyGroup] {
        let base: [ProxyGroup]
        switch iconFolder {
        case .all: base = visibleGroups
        case .strategy: base = visibleGroups.filter { !isNodeOnlyGroup($0) }
        case .nodes: base = visibleGroups.filter { isNodeOnlyGroup($0) }
        case .leafNodes: return []
        }
        let hidden = expandedMemberNames
        return base.filter { !hidden.contains($0.name) || expandedGroups.contains($0.name) }
    }

    /// Names of groups that are members of a currently-expanded
    /// group (v0.2.68, item 6): read from the RAW groups, so a
    /// member hidden by the page search still counts — its card
    /// is hidden by the search anyway, and the exclusion must not
    /// depend on the filtered copy.
    private var expandedMemberNames: Set<String> {
        var out = Set<String>()
        for name in expandedGroups {
            if let parent = proxyStore.groups.first(where: { $0.name == name }) {
                for node in parent.nodes { out.insert(node.name) }
            }
        }
        return out
    }

    /// List style groups (v0.2.68, item 6): same de-duplication as
    /// folderGroups — a member of an expanded group is shown only
    /// inside its parent's card, not again as its own row below.
    private var listGroups: [ProxyGroup] {
        let hidden = expandedMemberNames
        return visibleGroups.filter { !hidden.contains($0.name) || expandedGroups.contains($0.name) }
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

    /// Raw groups keyed by name, built once per content pass and
    /// threaded to the per-row helpers below, so they stop
    /// re-scanning proxyStore.groups per row. First wins — the
    /// same group `groups.first(where: { $0.name == name })`
    /// would find.
    private var rawGroupsByName: [String: ProxyGroup] {
        var out: [String: ProxyGroup] = [:]
        out.reserveCapacity(proxyStore.groups.count)
        for group in proxyStore.groups where out[group.name] == nil {
            out[group.name] = group
        }
        return out
    }

    /// "n" of MuYu's "TYPE · n/m" subtitle (icon_card.dart
    /// _GroupAvailability, countAvailableProxies): members whose
    /// resolved delay is > 0. The store's latencyMs is already the
    /// resolved pick delay (applyLatencies), so a nested-group
    /// member counts through its current pick. "m" is the raw
    /// member count (group.all.length, unfiltered).
    private func availableCount(for group: ProxyGroup, groupsByName: [String: ProxyGroup]) -> Int {
        let raw = groupsByName[group.name]
        return (raw?.nodes ?? group.nodes).filter { ($0.latencyMs ?? 0) > 0 }.count
    }

    /// MuYu GroupType display name (enum.dart: the Dart enum case
    /// names): capitalized, NOT all-caps — URLTest, Selector,
    /// Fallback (video f_043 node cards; the list rows show the
    /// same capitalized word, f_040). Smart is the v0.2.60
    /// upstream group kind (c4bc31d): per-site picks like
    /// url-test, with a `fixed` pin as its default.
    private static func typeDisplayName(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "Selector"
        case "url-test": return "URLTest"
        case "fallback": return "Fallback"
        case "load-balance": return "LoadBalance"
        case "relay": return "Relay"
        case "smart": return "Smart"
        default:
            guard let first = type.first else { return type }
            return first.uppercased() + type.dropFirst()
        }
    }

    /// Node-card type text (video f_020/f_043): plain capitalized
    /// text, no icon. Group types use the same capitalized names
    /// as the card subtitle (URLTest / Selector / Fallback); leaf
    /// types capitalize their first letter (vless → Vless,
    /// shadowsocks → Shadowsocks, hysteria2 → Hysteria2).
    private static func nodeTypeDisplayName(_ type: String) -> String {
        switch type.lowercased() {
        case "select", "url-test", "fallback", "load-balance", "relay", "smart":
            return typeDisplayName(type)
        default:
            guard let first = type.first else { return type }
            return first.uppercased() + type.dropFirst()
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
    private func iconCardCollapsedHeight() -> CGFloat {
        let m = iconCardMetrics()
        let rowHeight = styleStore.iconStyle == .hidden ? 21 : m.brandSize
        return m.inset * 2 + rowHeight + m.metaGap + 16 + m.bottomGap + 24
    }

    /// The brand icon a node card shows before the name (MuYu
    /// card.dart _memberIconSize): only when the node is itself a
    /// group. The group's own profile icon wins; when it has none,
    /// the user-imported icon pack is checked by the subgroup's
    /// name (IconPackStore.iconURL) — the pack is the only other
    /// icon source (no built-in brand icons, v0.2.53). Leaf nodes
    /// have no icon source — the Concord core exposes no per-node
    /// icon (ConcordNodeInfo has name/type/provider only), so they
    /// show nothing, exactly as MuYu's `if (proxy.icon.isNotEmpty)`.
    /// A pack URL is returned as a string: GroupIconImageView loads
    /// http(s) icon strings directly.
    private func memberIcon(for node: ProxyNode, groupsByName: [String: ProxyGroup]) -> String? {
        guard Self.groupTypes.contains(node.type),
              let sub = groupsByName[node.name] else { return nil }
        if !sub.icon.isEmpty { return sub.icon }
        return IconPackStore.shared.iconURL(for: node.name)?.absoluteString
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
                    // The top inline search field is tab-page only:
                    // the picker sheet searches from its bottom
                    // floating bar (video f_018) and has no
                    // magnifier to open this field.
                    if !picker {
                        searchField
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
                                Button {
                                    Task { await proxyStore.prepareRuleSetRepair() }
                                } label: {
                                    if proxyStore.isRepairingRuleSet {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("修复")
                                    }
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
                    // Repair notice (v0.2.58): a repair attempt that
                    // could not build a plan (or found nothing
                    // missing) reports HERE, as its own dismissible
                    // notice — never by overwriting testError, so
                    // the TikTok error and its 修复 button stay
                    // visible above after a failed plan.
                    if let repairNotice = proxyStore.repairNotice {
                        HStack {
                            Text(repairNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { proxyStore.repairNotice = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭修复提示")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    if picker {
                        // The dashboard sheet always shows the card
                        // grid (video: 2-column group cards +
                        // filter pills), whatever the tab's style.
                        // The search is a BOTTOM floating bar
                        // overlaid on the grid (video f_018), not
                        // the top inline field — see pickerSearchBar.
                        ZStack(alignment: .bottom) {
                            iconsContent(width: geometry.size.width)
                            pickerSearchBar
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }
                    } else {
                        switch styleStore.style {
                        case .tab:
                            tabContent(width: geometry.size.width)
                        case .list:
                            listContent(width: geometry.size.width)
                        case .icons:
                            iconsContent(width: geometry.size.width)
                        }
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
            .toolbar {
                if picker {
                    // Sheet header (video f_018: TWO separate white
                    // circles — ✕ left, bolt right — NOT the
                    // magnifier+bolt capsule, and NO ⋯ menu; the
                    // old comment claimed the picker drops the ⋯
                    // but the code still showed moreButton).
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(.label))
                                .frame(width: 36, height: 36)
                                .background(ConcordTheme.cardBackground, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                    }
                    ToolbarItem(placement: .principal) {
                        Text("代理")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        pickerBoltButton
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("tab.proxies".l10n)
                            .font(.system(size: 24, weight: .bold))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        topBarPill
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        moreButton
                    }
                }
            }
            // The picker sheet's background follows the theme page
            // background (v0.2.68, video f_018: the sheet is the
            // same pink-tinted surface as the page, not the neutral
            // system sheet gray). Inert on the tab page, which is
            // never presented. DashboardView also sets a
            // presentationBackground on the .sheet itself; this
            // inner value is the one the sheet reads for its
            // content. In light mode pageBackground IS
            // systemGroupedBackground, so the visible change is in
            // dark / pure-black mode.
            .presentationBackground(ConcordTheme.pageBackground)
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
            .onChange(of: proxyStore.selectError) { _, new in
                // A node switch the core refused twice (v0.2.97
                // gap 4): the pick was rolled back — show why,
                // like the delay-test failure above. A nil error
                // (a later switch succeeded) dismisses the banner.
                if let new { notice = new } else { notice = nil }
            }
            .onChange(of: groupSearchFocus) { _, focused in
                if focused == nil {
                    for name in groupSearchOpen where (groupSearchKeywords[name] ?? "").isEmpty {
                        groupSearchOpen.remove(name)
                    }
                }
            }
            .onChange(of: proxyStore.testErrorNonce) { _, _ in
                // The same failure twice in a row does not change
                // testError, so the observer above never fires —
                // the nonce re-shows the banner for the repeat.
                if let current = proxyStore.testError { notice = current }
            }
            .onChange(of: proxyStore.selectErrorNonce) { _, _ in
                // The same switch failure twice in a row does not
                // change selectError, so the observer above never
                // fires — the nonce re-shows the banner for the
                // repeat (same reason as testErrorNonce).
                if let current = proxyStore.selectError { notice = current }
            }
            .onAppear {
                // Returning to this page with a failure already
                // recorded (e.g. the run finished while another tab
                // was frontmost) must still show it.
                if let current = proxyStore.testError { notice = current }
                if let current = proxyStore.selectError { notice = current }
            }
        }
        .toolbarBackground(ConcordTheme.pageBackground, for: .navigationBar)
        // ⋯ menu overlay (v0.2.72): a custom overlay, NOT a system
        // .popover — the popover's content never received taps
        // on-device (IMG_1212). The overlay is part of the normal
        // view hierarchy, so its rows hit-test normally. A nearly
        // invisible tap catcher dismisses on any tap outside the
        // card; the card sits just below the nav bar with an arrow
        // pointing up at the ⋯ button, like the MuYu popup.
        // v0.2.74: .ignoresSafeArea() must sit on the inner ZStack,
        // NOT on the GeometryReader — on the reader it zeroes
        // geo.safeAreaInsets.top, so the card's top padding was
        // 0 + 44 + 6 = 50pt and the menu started inside the nav bar,
        // covering the search/bolt/⋯ buttons (IMG_1219: card top
        // ~57pt). With the real inset (~59pt on a Dynamic Island
        // phone) the top is ~59 + 44 + 6 = 109pt, just below the
        // nav bar (~103pt). The ZStack still ignores the safe area
        // so the tap catcher covers the whole screen.
        .overlay {
            if showMoreMenu {
                GeometryReader { geo in
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001)
                            .onTapGesture { showMoreMenu = false }
                        VStack(alignment: .trailing, spacing: 0) {
                            menuArrow
                                .padding(.trailing, 18)
                                .padding(.bottom, -1)
                            ProxiesMoreMenuView(
                                isPresented: $showMoreMenu,
                                onScrollToSelected: styleStore.style == .tab ? { scrollToSelected(in: selectedGroup) } : nil
                            )
                            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
                        }
                        .padding(.top, geo.safeAreaInsets.top + 44 + 6)
                        .padding(.trailing, 12)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .onDisappear { showMoreMenu = false }
    }

    // MARK: - Top bar

    /// The page search field (v0.2.56): a plain TextField shown
    /// ONLY while isSearching, toggled by the top-bar magnifier.
    /// SwiftUI's .searchable was removed: with no .navigationTitle
    /// (the 24pt title is a leading toolbar item, per B16) it
    /// rendered a PERMANENT search row under the bar (IMG_1178 /
    /// IMG_1179), which MuYu does not have — MuYu's magnifier opens
    /// the AppBar search field on tap, and it is hidden otherwise.
    /// Closing clears the query, as MuYu's search does.
    @ViewBuilder
    private var searchField: some View {
        if isSearching {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索节点", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFieldFocused)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
                Button {
                    isSearching = false
                    searchText = ""
                } label: {
                    Text("取消")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onAppear {
                DispatchQueue.main.async { self.searchFieldFocused = true }
            }
        }
    }

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
    /// field (a plain TextField while isSearching — see
    /// searchField). Scroll-to-selected lives in the ⋯ menu as its
    /// first row in tab style (the MuYu video build shows it there;
    /// the checked-out MuYu code has it as a separate bar item
    /// instead — the video is the newer build and the user's live
    /// reference, so the video wins); re-tapping the active group
    /// pill scrolls to the selected node too.
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
        .disabled(proxyStore.displayGroups.isEmpty || testing)
        .accessibilityLabel("测速全部")
    }

    /// The picker header's bolt (v0.2.68, video f_018): a
    /// STANDALONE white circle, 36pt like the ✕ on the other side
    /// — not the magnifier+bolt capsule, and with no ⋯ menu next
    /// to it. Tests all groups, like the list / card bolt.
    private var pickerBoltButton: some View {
        let testing = !proxyStore.testingGroups.isEmpty
        return Button {
            Task { await proxyStore.testLatency() }
        } label: {
            Group {
                if testing {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(.label))
                }
            }
            .frame(width: 36, height: 36)
            .background(ConcordTheme.cardBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(proxyStore.displayGroups.isEmpty || testing)
        .accessibilityLabel("测速全部")
    }

    /// The picker sheet's search (v0.2.68, video f_018/f_021): a
    /// BOTTOM floating bar overlaid on the grid — a rounded bar
    /// with a magnifier + TextField "搜索" — NOT the top inline
    /// search box ("搜索节点" + "取消"). It binds the same
    /// searchText the page search uses, so typing filters the
    /// grid live. The grid's bottom clearance (tabBarClearance)
    /// leaves room for it; the bar floats above the last row.
    private var pickerSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
    }

    /// The ⋯ menu overlay's arrow: a small triangle at the card's
    /// top, pointing up at the ⋯ button (MuYu's popup has the
    /// same arrow). 16 wide, 12 tall, filled with the card colour.
    private var menuArrow: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 12))
            path.addLine(to: CGPoint(x: 8, y: 0))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.closeSubpath()
        }
        .fill(ConcordTheme.cardBackground)
        .frame(width: 16, height: 12)
    }

    /// The ⋯ button toggles the menu overlay (v0.2.72: a custom
    /// overlay, NOT a system .popover — the popover presented
    /// fine but its content never received taps on-device
    /// (IMG_1212: every row dead). The page lives in the sliding
    /// tab container's offset HStack, and the system popover's
    /// hit-testing does not survive that container; an overlay
    /// inside the normal view hierarchy hit-tests normally.
    /// The overlay itself lives on the NavigationStack below.
    private var moreButton: some View {
        Button { showMoreMenu.toggle() } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 19, weight: .semibold))
                .imageScale(.medium)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .background(ConcordTheme.cardBackground, in: Circle())
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

    /// The ⋯ menu is a white card, not a native context menu:
    /// 滚动到已选 (tab style only, first row), 风格， 排序， 布局，
    /// 尺寸， 图标样式 (not in tab style), and the hide-timeout
    /// toggle last. 风格 does NOT drill down: tapping it toggles
    /// the three style rows inline, directly below it in the same
    /// popup (MuYu video f_023/f_026 — an accordion, sibling rows
    /// stay visible; tapping a style applies it and closes the
    /// menu). The other rows open a drill-down submenu with a
    /// checkmark on the current value. No test-all and no refresh
    /// in the menu — FlClash has neither there (the bolt is the
    /// test; refresh is pull-to-refresh). Icon style shows in
    /// list AND card style, hidden only in tab style (MuYu changed
    /// FlClash's `type == list` to `type != tab` when it added the
    /// card style, proxies.dart).
    /// A plain VStack, NOT a NavigationStack: a NavigationStack
    /// inside a popover reports no usable ideal height, so the card
    /// rendered clipped to ~1 row (v0.2.27). Each row's expansion is
    /// state, and the card sizes itself to the VStack — the same as
    /// FlClash's PopupMenu sizing to its content.

    /// The ⋯ menu as its own View with its own state — NOT a
    /// computed property on ProxiesView. The menu's level and 风格
    /// expansion used to live in ProxiesView's @State, so every menu
    /// tap invalidated the whole page body (NavigationStack + the
    /// node grid + the toolbar) and re-invoked the .popover
    /// modifier whose anchor is the toolbar ⋯ button: the popover
    /// content churned under the tap and rows stopped responding
    /// (IMG_1209: laggy, taps not registering). As its own struct,
    /// a menu tap invalidates only the menu. Font color is FlClash
    /// PopupMenu onSurface (popup.dart: the label is
    /// AppTextStyle.subheadline, 15pt w400, in colorScheme.onSurface)
    /// — SwiftUI Color(.label) — not .secondary, which is what the
    /// menu rendered as with no explicit foreground.
    private struct ProxiesMoreMenuView: View {
        @EnvironmentObject private var styleStore: ProxyStyleStore
        @Binding var isPresented: Bool
        /// Scroll-to-selected, tab style only (nil otherwise): the
        /// ⋯ menu's first row. Supplied by the page because the
        /// scroll target lives in ProxiesView's @State.
        var onScrollToSelected: (() -> Void)?

        // v0.2.73: every submenu row expands INLINE (accordion)
        // below its own row inside this same card — no drill-down,
        // no separate pop-up. Each row owns one boolean; tapping
        // anywhere on the row toggles it (MuYu video behaviour).
        @State private var styleExpanded = false
        @State private var sortExpanded = false
        @State private var layoutExpanded = false
        @State private var sizeExpanded = false
        @State private var iconStyleExpanded = false

        var body: some View {
            VStack(spacing: 0) {
                // Scroll-to-selected (MuYu video build, f_044/f_045):
                // the ⋯ menu's first row in tab style. The
                // checked-out MuYu code has it as a separate bar
                // item instead (proxies.dart iconActions); the video
                // is the newer build and the user's live reference.
                // List / card style keep their per-header locate
                // buttons, so the row is tab-only.
                if let onScrollToSelected {
                    Button {
                        onScrollToSelected()
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 22)
                            Text("滚动到已选")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // 风格 expands INLINE (v0.2.57, MuYu video
                // f_023/f_026): the three style rows appear directly
                // below this row inside the same popup — 标签页 ✓ /
                // 列表 / 卡片 — while the sibling rows stay visible.
                // Chevron: > collapsed, ∨ expanded (MuYu IMG_1214
                // vs the expanded frames). Tapping a style applies
                // it and closes the menu (menuOptionRow); tapping
                // 风格 only toggles the expansion. Tapping anywhere
                // on the row toggles it — the chevron is only a
                // visual indicator (v0.2.73).
                expandableMenuRow(
                    icon: Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold)),
                    label: "风格",
                    expanded: styleExpanded
                ) {
                    withAnimation { styleExpanded.toggle() }
                }
                if styleExpanded {
                    ForEach(ProxyStyleStore.Style.allCases, id: \.self) { style in
                        menuOptionRow(label: style.label, selected: styleStore.style == style) {
                            styleStore.style = style
                        }
                    }
                }
                // 排序 (MuYu: three horizontal lines, decreasing —
                // SF line.3.horizontal.decrease; the old
                // arrow.up.arrow.down up/down arrows do not match).
                // v0.2.73: inline accordion like 风格 — the sort
                // options appear directly below this row; the whole
                // row toggles it.
                expandableMenuRow(
                    icon: Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 19, weight: .semibold)),
                    label: "排序",
                    expanded: sortExpanded
                ) {
                    withAnimation { sortExpanded.toggle() }
                }
                if sortExpanded {
                    ForEach(ProxySort.allCases) { option in
                        menuOptionRow(label: option.rawValue, selected: styleStore.sort == option) {
                            styleStore.sort = option
                        }
                    }
                }
                expandableMenuRow(
                    icon: Image(systemName: "square.grid.2x2")
                        .font(.system(size: 19, weight: .semibold)),
                    label: "布局",
                    expanded: layoutExpanded
                ) {
                    withAnimation { layoutExpanded.toggle() }
                }
                if layoutExpanded {
                    ForEach(ProxyStyleStore.Layout.allCases, id: \.self) { layout in
                        menuOptionRow(label: layout.rawValue, selected: styleStore.layout == layout) {
                            styleStore.layout = layout
                        }
                    }
                }
                // 尺寸 (MuYu: a "Tt" glyph — SF Symbols has none,
                // so the custom TtIcon in CustomGlyphs.swift).
                // v0.2.73: inline accordion like 风格.
                expandableMenuRow(
                    icon: TtIcon(size: 20),
                    label: "尺寸",
                    expanded: sizeExpanded
                ) {
                    withAnimation { sizeExpanded.toggle() }
                }
                if sizeExpanded {
                    ForEach(ProxyStyleStore.CardType.allCases, id: \.self) { type in
                        menuOptionRow(label: type.rawValue, selected: styleStore.cardType == type) {
                            styleStore.cardType = type
                        }
                    }
                }
                if styleStore.style != .tab {
                    expandableMenuRow(
                        icon: Image(systemName: "photo")
                            .font(.system(size: 19, weight: .semibold)),
                        label: "图标样式",
                        expanded: iconStyleExpanded
                    ) {
                        withAnimation { iconStyleExpanded.toggle() }
                    }
                    if iconStyleExpanded {
                        ForEach(ProxyStyleStore.IconStyle.allCases, id: \.self) { style in
                            menuOptionRow(label: style.rawValue, selected: styleStore.iconStyle == style) {
                                styleStore.iconStyle = style
                            }
                        }
                    }
                }
                Divider()
                    .padding(.vertical, 4)
                Button {
                    styleStore.hideTimeout.toggle()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 19, weight: .semibold))
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
            }
            // v0.2.74: maxWidth 200 (was 280) — the menu expanded
            // to the full 280pt and looked far wider than MuYu's
            // (~160pt, IMG_1214); the longest row needs ~163pt, so
            // 200pt gives it room without the bulk. Row height /
            // padding unchanged (the ~44pt pitch already matches
            // MuYu's ~43pt).
            .frame(minWidth: 160, maxWidth: 200)
            .font(.subheadline)
            .foregroundStyle(Color(.label))
            .onDisappear { styleExpanded = false; sortExpanded = false; layoutExpanded = false; sizeExpanded = false; iconStyleExpanded = false }
        }

        /// One expandable menu row (v0.2.73): the whole row is the tap
        /// target — icon, label, empty space and chevron all toggle the
        /// inline expansion (`.contentShape(Rectangle())` makes the
        /// Button cover the full row width). The chevron is only a
        /// visual indicator: > collapsed, ∨ expanded (MuYu). The icon
        /// is a generic View so the SF Symbol rows and the custom
        /// TtIcon row share this helper.
        private func expandableMenuRow<Icon: View>(
            icon: Icon,
            label: String,
            expanded: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    icon
                        .frame(width: 22)
                    Text(label)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func menuOptionRow(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button {
                action()
                isPresented = false
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
        // One group lookup for this pass (see rawGroupsByName).
        let groupsByName = rawGroupsByName
        return VStack(spacing: 0) {
            // FlClash group_tabs.dart: the strip auto-centers the
            // selected chip, fades its right edge over 24pt, and
            // shows an overflow "More" button (chevron.down) when
            // the chips overflow, listing all groups (max 7 visible)
            // with a checkmark on the current one. The chip label
            // is subheadline semibold; unselected labels use the
            // onSurfaceVariant colour (.secondary here). The label
            // is capped at PopupMenu.labelMaxWidth (240.0pt — see
            // the pill below); the tab is the capped label + padding.
            ScrollViewReader { pillReader in
                HStack(spacing: 8) {
                    ZStack(alignment: .trailing) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(visibleGroups) { group in
                                    Button {
                                        if selectedVisibleGroup?.id == group.id {
                                            scrollToSelected(in: group)
                                        } else {
                                            proxyStore.selectedGroupName = group.name
                                        }
                                    } label: {
                                        // MuYu group_tabs.dart _TabExtents:
                                        // the label width is
                                        // min(measured, labelMaxWidth);
                                        // labelMaxWidth = 240.0pt,
                                        // verified at the MuYu-pinned
                                        // prism_ui commit 6c47901c
                                        // lib/popup.dart:1864:
                                        // 280 - 2*8 - 24 = 240.
                                        Text(group.name)
                                            .lineLimit(1)
                                            .frame(maxWidth: 240)
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
                // No info line under the pills: MuYu's tab page
                // (IMG_1183, video f_044) shows the pills directly
                // above the grid — no "type · n 个节点 · 当前：…"
                // line and no offline note (MuYu has no offline
                // mode). Both were ours-only rows; removed v0.2.56.
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                            ForEach(group.nodes) { node in
                                nodeCard(node, in: group, groupsByName: groupsByName)
                                    .id(scrollID(nodeName: node.name, groupName: group.name))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, ConcordTheme.tabBarClearance)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            withAnimation { reader.scrollTo(target, anchor: .center) }
                        }
                    }
                    .refreshable { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                }
            } else if proxyStore.displayGroups.isEmpty && proxyStore.isLoading {
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
                        proxyStore.selectedGroupName = group.name
                        showGroupPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            // Same 240pt cap as the strip pills (MuYu:
                            // the overflow menu's labels are capped at
                            // PopupMenu.labelMaxWidth too).
                            Text(group.name)
                                .lineLimit(1)
                                .frame(maxWidth: 240)
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
        .frame(minWidth: 160, maxWidth: 280, maxHeight: 338)
        .font(.subheadline)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - List style

    /// List style (v0.2.68, video f_040): EVERY group is an
    /// independent rounded card (panelRadius 20, cardBackground)
    /// with the page background visible as gaps between cards.
    /// The old structure was one big white board — a header with
    /// top-only corners + a node grid with bottom-only corners
    /// sharing one continuous white surface — which the video does
    /// not have. Each card's row is the brand icon (~40pt), the
    /// name bold with the selected node in gray below, and on the
    /// right the capitalized type ("Selector") + a light-gray solid
    /// circle holding a black chevron (▼ collapsed, ▲ expanded).
    /// Tapping the row expands the group inline: its nodes appear
    /// inside the same card. No per-group bolt / locate / search
    /// in the row — the video has none (the top-bar bolt tests all
    /// groups; each node card still has its own delay chip).
    /// Members of an expanded group are not listed again as their
    /// own cards below (listGroups, item 6).
    private func listContent(width: CGFloat) -> some View {
        // One group lookup for this pass (see rawGroupsByName).
        let groupsByName = rawGroupsByName
        return Group {
            if proxyStore.displayGroups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGroups.isEmpty && searching {
                ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
            } else if visibleGroups.isEmpty {
                noGroupsView
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        // MuYu proxyGridSpacing = 8.0 (v0.2.81;
                        // was 12; the screenshot's gap is ~7.3pt).
                        LazyVStack(spacing: 8) {
                            ForEach(listGroups) { group in
                                listGroupCard(group, width: width, groupsByName: groupsByName)
                                    .id(groupHeaderID(group.name))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, ConcordTheme.tabBarClearance)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            // Group cards scroll to the top of the
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
        // One group lookup for this pass (see rawGroupsByName).
        let groupsByName = rawGroupsByName
        return VStack(spacing: 0) {
            folderBar
            Group {
                if proxyStore.displayGroups.isEmpty && proxyStore.isLoading {
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
                                    nodeCard(entry.node, in: entry.group, groupsByName: groupsByName)
                                        .id(scrollID(nodeName: entry.node.name, groupName: entry.group.name))
                                }
                            }
                            .padding(.horizontal, 15)
                            .padding(.top, 12)
                            .padding(.bottom, ConcordTheme.tabBarClearance)
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
                            LazyVStack(spacing: 8) {
                                ForEach(iconSegments) { segment in
                                    switch segment {
                                    case .pair(let first, let second):
                                        HStack(spacing: 8) {
                                            iconGroupCard(first, groupsByName: groupsByName)
                                                .equatable()
                                                .id(groupHeaderID(first.name))
                                            if let second {
                                                iconGroupCard(second, groupsByName: groupsByName)
                                                    .equatable()
                                                    .id(groupHeaderID(second.name))
                                            } else {
                                                Color.clear
                                                    .frame(maxWidth: .infinity)
                                            }
                                        }
                                    case .expanded(let group):
                                        VStack(spacing: 8) {
                                            iconGroupCard(group, groupsByName: groupsByName)
                                                .equatable()
                                                .id(groupHeaderID(group.name))
                                            LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                                                ForEach(displayNodes(for: group)) { node in
                                                    nodeCard(node, in: group, groupsByName: groupsByName)
                                                        .id(scrollID(nodeName: node.name, groupName: group.name))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 15)
                            .padding(.top, 12)
                            .padding(.bottom, ConcordTheme.tabBarClearance)
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
                    .background(selected ? ConcordTheme.accent : ConcordTheme.cardBackground, in: Capsule())
                    .foregroundStyle(selected ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// One row of the card-style grid (MuYu list.dart
    /// _buildIconSegments): collapsed groups pair side-by-side, an
    /// expanded group takes a full-width row alone with its nodes
    /// below its card. Rows are built EXPLICITLY (LazyVStack +
    /// HStack), not as a LazyVGrid with .gridCellColumns(2): the
    /// spanning did not take effect in the shipped v0.2.55 build —
    /// measured in IMG_1179, the expanded 顺畅网络 card was 181pt
    /// wide (one column, not two) and its inner 2-col node grid was
    /// squeezed into that column, so every node card was ~87pt wide
    /// and names wrapped ("自动/选择") and types truncated to
    /// "u…"/"vl…"/"D…". Explicit rows make the full width
    /// structural instead of relying on the spanning modifier.
    private enum IconSegment: Identifiable {
        case pair(ProxyGroup, ProxyGroup?)
        case expanded(ProxyGroup)

        var id: String {
            switch self {
            case .pair(let first, let second):
                return "pair:\(first.name)|\(second?.name ?? "")"
            case .expanded(let group):
                return "expanded:\(group.name)"
            }
        }
    }

    /// The card-style rows in order: walk the folder-filtered
    /// groups; an expanded group becomes its own row, otherwise
    /// pair two collapsed groups (a trailing single pairs with
    /// nothing). Same order as the group list — an expanded group
    /// never moves.
    private var iconSegments: [IconSegment] {
        var out: [IconSegment] = []
        var index = 0
        while index < folderGroups.count {
            let group = folderGroups[index]
            if expandedGroups.contains(group.name) {
                out.append(.expanded(group))
                index += 1
                continue
            }
            let next = index + 1
            if next < folderGroups.count, !expandedGroups.contains(folderGroups[next].name) {
                out.append(.pair(group, folderGroups[next]))
                index = next + 1
            } else {
                out.append(.pair(group, nil))
                index = next
            }
        }
        return out
    }

    /// Builds one card-style group card (MuYu icon_card.dart
    /// GroupIconCard) as an Equatable IconGroupCard: every value
    /// the card renders is precomputed here into plain values, so
    /// a delay-test result landing on another group leaves this
    /// card's == true and SwiftUI skips its body (same pattern as
    /// nodeCard / ProxyNodeCard). The per-group search state, the
    /// latency pill action and the tap action are passed as
    /// closures the parent owns; the struct only calls them.
    /// Call sites add .equatable() — without it SwiftUI does not
    /// consult the ==.
    private func iconGroupCard(_ group: ProxyGroup, groupsByName: [String: ProxyGroup]) -> IconGroupCard {
        let total = groupsByName[group.name]?.nodes.count ?? group.nodes.count
        return IconGroupCard(
            name: group.name,
            type: group.type,
            icon: group.icon,
            subtitle: "\(Self.typeDisplayName(group.type).uppercased()) · \(availableCount(for: group, groupsByName: groupsByName))/\(total)",
            selectedName: group.selectedNodeName,
            selectedIcon: selectedNodeIcon(for: group, groupsByName: groupsByName),
            latencyMs: selectedNodeLatency(for: group, groupsByName: groupsByName),
            testing: proxyStore.testingGroups.contains(group.name),
            expanded: expandedGroups.contains(group.name),
            cardType: styleStore.cardType,
            iconStyle: styleStore.iconStyle,
            collapsedHeight: iconCardCollapsedHeight(),
            running: proxyStore.isRunning,
            searchKeyword: groupSearchKeywords[group.name] ?? "",
            searchOpen: groupSearchOpen.contains(group.name),
            searchFocus: $groupSearchFocus,
            onSearchKeywordChange: { new in
                if new.isEmpty {
                    groupSearchKeywords.removeValue(forKey: group.name)
                } else {
                    groupSearchKeywords[group.name] = new
                }
            },
            onSearchOpen: { groupSearchOpen.insert(group.name) },
            onSearchClose: {
                groupSearchKeywords.removeValue(forKey: group.name)
                groupSearchOpen.remove(group.name)
                groupSearchFocus = nil
            },
            onSearchAppear: { groupSearchFocus = group.name },
            onTestLatency: {
                Task { await proxyStore.testLatency(group: group, nodeNames: searchMatchedNodeNames(forGroupNamed: group.name)) }
            },
            onTap: {
                // Picker (dashboard sheet): tapping a group picks it
                // instead of expanding — the caller selects the group,
                // dismisses the sheet, and switches to the Proxies tab.
                if picker {
                    onPickGroup?(group.name)
                    return
                }
                if expandedGroups.contains(group.name) {
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
        )
    }

/// The selected node's live up/down speeds (MuYu _SelectedSpeeds,
/// icon_card.dart:318-353): ↑/↓ bytes/s from TrafficStore's
/// per-node sampler, shown only while the card is unfolded with a
/// node selected; zeros while the VPN is off (MuYu shows the zero
/// Traffic then). A leaf view observing TrafficStore so the 1 s
/// publish re-renders only this row — ProxiesView itself must NOT
/// observe TrafficStore, or the whole page would re-render every
/// second (v0.2.51).
    /// The selected node's group icon for the card's bottom row
    /// (MuYu _SelectedProxy: groups.getGroup(proxyName)?.icon).
    /// The group's own profile icon wins; when it has none, the
    /// user-imported icon pack is checked by the selected node's
    /// name (IconPackStore.iconURL) — a node with no icon anywhere
    /// shows no monogram there. A pack URL is returned as a string:
    /// GroupIconImageView loads http(s) icon strings directly.
    private func selectedNodeIcon(for group: ProxyGroup, groupsByName: [String: ProxyGroup]) -> String? {
        guard let selected = group.selectedNodeName else { return nil }
        if let sub = groupsByName[selected],
           !sub.icon.isEmpty {
            return sub.icon
        }
        return IconPackStore.shared.iconURL(for: selected)?.absoluteString
    }

    /// The selected node's resolved delay for the latency pill
    /// (MuYu _SelectedDelay reads the delay map). Looked up in the
    /// RAW group: the visible copy may have filtered the selected
    /// node out while searching.
    private func selectedNodeLatency(for group: ProxyGroup, groupsByName: [String: ProxyGroup]) -> Int32? {
        guard let selected = group.selectedNodeName else { return nil }
        return groupsByName[group.name]?
            .nodes.first(where: { $0.name == selected })?.latencyMs
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

    /// One list-style group card (v0.2.68, video f_040): the
    /// whole group — header row plus, when expanded, its node
    /// grid — is ONE rounded card (panelRadius 20,
    /// cardBackground), so the page background shows as gaps
    /// between cards. The row is the brand icon (~40pt, groupIcon),
    /// the name bold with the selected node in gray below
    /// (FlClash ListHeader: the subtitle is the selected node
    /// name whenever there is one, hidden entirely when there is
    /// none; the minHeight keeps the two-line height stable when
    /// the subtitle is empty — upstream's header is a fixed 61pt),
    /// and on the right the capitalized type ("Selector", never
    /// the raw lowercase type) + a light-gray solid circle holding
    /// a black chevron (▼ collapsed, ▲ expanded). Tapping the row
    /// toggles expand/collapse; expanding scrolls the group into
    /// view once its rows are laid out (FlClash _handleChange,
    /// list.dart:45-60). The node grid is the same LazyVGrid the
    /// old section row drew, now inside the card.
    /// Built as an Equatable ListGroupCard (same pattern as
    /// iconGroupCard / IconGroupCard): the header's values are
    /// plain inputs, and the expanded grid arrives as a @ViewBuilder
    /// closure whose rendered data is shadowed by nodeFingerprints
    /// — see ListGroupNodeFingerprint. Collapsed cards pass []
    /// fingerprints (no grid rendered, no per-node lookups).
    private func listGroupCard(_ group: ProxyGroup, width: CGFloat, groupsByName: [String: ProxyGroup]) -> some View {
        let expanded = expandedGroups.contains(group.name)
        let nodes = displayNodes(for: group)
        let fingerprints: [ListGroupNodeFingerprint] = expanded ? nodes.map { node in
            ListGroupNodeFingerprint(
                name: node.name,
                typeDisplay: Self.nodeTypeDisplayName(node.type),
                description: nodeDescription(node, groupsByName: groupsByName),
                latencyMs: node.latencyMs,
                testing: proxyStore.testingNodes.contains(node.name),
                pinned: group.fixed == node.name,
                selected: group.selectedNodeName == node.name,
                memberIcon: memberIcon(for: node, groupsByName: groupsByName),
                addable: isAddable(node)
            )
        } : []
        return ListGroupCard(
            name: group.name,
            icon: group.icon,
            typeDisplay: Self.typeDisplayName(group.type),
            selectedName: group.selectedNodeName,
            expanded: expanded,
            iconStyle: styleStore.iconStyle,
            columnCount: ProxyStyleStore.columns(for: styleStore.layout, width: width),
            cardType: styleStore.cardType,
            cardHeight: cardHeight,
            groupType: group.type,
            nodeFingerprints: fingerprints,
            onToggleExpand: {
                if expandedGroups.contains(group.name) {
                    expandedGroups.remove(group.name)
                } else {
                    expandedGroups.insert(group.name)
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        scrollTargetName = groupHeaderID(group.name)
                        scrollNonce += 1
                    }
                }
            },
            onScrollToSelected: { scrollToSelected(in: group) },
            onTestAll: { Task { await proxyStore.testLatency(group: group) } },
            onSearch: { isSearching = true }
        ) {
            LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                ForEach(nodes) { node in
                    // v0.2.88: List-expanded nodes use the page
                    // fill (grey in light mode) so they read as
                    // rounded cards on the white group interior —
                    // MuYu's node is one level above its scope.
                    // Tab / Card / search keep the white default.
                    nodeCard(node, in: group, groupsByName: groupsByName, fill: ConcordTheme.pageBackground)
                        .id(scrollID(nodeName: node.name, groupName: group.name))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .equatable()
    }

    private func groupHeaderID(_ groupName: String) -> String {
        "groupHeader:\(groupName)"
    }

    // MARK: - Node card

    /// Loose cards show the node's description: for a node that is
    /// itself a group, its type plus the node it currently selects
    /// (FlClash _ProxyDesc); otherwise just the type. The type is
    /// the capitalized display name (URLTest / Selector / Vless),
    /// never the raw lowercase core spelling.
    private func nodeDescription(_ node: ProxyNode, groupsByName: [String: ProxyGroup]) -> String {
        guard Self.groupTypes.contains(node.type),
              let sub = groupsByName[node.name],
              let selected = sub.selectedNodeName, selected != node.name else {
            return Self.nodeTypeDisplayName(node.type)
        }
        return "\(Self.nodeTypeDisplayName(node.type))(\(selected))"
    }

    private func nodeCard(_ node: ProxyNode, in group: ProxyGroup, groupsByName: [String: ProxyGroup], fill: Color = ConcordTheme.cardBackground) -> some View {
        ProxyNodeCard(
            name: node.name,
            type: Self.nodeTypeDisplayName(node.type),
            description: nodeDescription(node, groupsByName: groupsByName),
            latencyMs: node.latencyMs,
            testing: proxyStore.testingNodes.contains(node.name),
            pinned: group.fixed == node.name,
            selected: group.selectedNodeName == node.name,
            cardType: styleStore.cardType,
            cardHeight: cardHeight,
            memberIcon: memberIcon(for: node, groupsByName: groupsByName),
            fill: fill,
            onTest: { Task { await proxyStore.testLatency(node: node, testURL: nodeTestURL(group)) } }
        )
        .equatable()
        .onTapGesture {
            Task {
                await selectNode(node, in: group)
                // Picker (dashboard sheet): picking a node also
                // closes the sheet at its group.
                if picker { onPickGroup?(group.name) }
            }
        }
        .contextMenu { nodeMenu(node, in: group) }
    }

    private func nodeMenu(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        Group {
            let pinned = group.fixed == node.name
            let selected = group.selectedNodeName == node.name
            // FlClash card.dart:120-145: a constant label ("选择" for
            // Selector, "首选" for url-test/fallback/smart) with a
            // checkmark on the current state — the label never
            // toggles. Smart pins like url-test (upstream
            // is_selectable includes Smart; the pin is its
            // per-site default).
            if group.type == "select" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    HStack {
                        Text("选择")
                        Spacer()
                        if selected { Image(systemName: "checkmark") }
                    }
                }
            } else if group.type == "url-test" || group.type == "fallback" || group.type == "smart" {
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
        // Smart groups pin like url-test/fallback (see
        // ProxyStore.selectSmart): ProxyStore.select is byte-frozen
        // for the v0.2.60 rebase, so smart taps route here instead
        // of through its switch.
        if group.type == "smart" {
            if let note = await proxyStore.selectSmart(node: node, in: group, profileID: profileStore.activeProfile?.id) {
                showNotice(note)
            }
            return
        }
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

/// A group's icon image, resolved in priority order: the profile's
/// own icon (a URL is loaded; a name is matched through the
/// user-imported icon pack, v0.2.57; other short text such as an
/// emoji or a letter is shown as-is), then the user-imported icon
/// pack (IconPackStore, matched by group name), else the group's
/// first character. There are NO bundled brand icons (v0.2.53,
/// user direction): the pack is the only icon source besides the
/// profile icon, and the monogram is the only fallback.
/// Observes the pack itself, so an import re-renders only this leaf
/// — ProxiesView never observes the store (v0.2.51 scroll fix).
/// A failed image load falls back to the monogram: the cached
/// image view shows the placeholder on failure as well as while
/// loading (v0.2.68: CachedIconImage, decoded once per URL).
private struct GroupIconImageView: View {
    @ObservedObject private var iconPack = IconPackStore.shared
    let icon: String
    let name: String

    var body: some View {
        let monogram = String(name.prefix(1))
        let isURL = icon.hasPrefix("http")
        Group {
            if isURL, let url = URL(string: icon) {
                CachedIconImage(url: url) {
                    Text(monogram)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if !icon.isEmpty {
                // A name-form icon (e.g. "YouTube" baked as the
                // group's `icon:`) is matched through the user's
                // icon pack first; only a pack miss falls back to
                // showing the text itself (an emoji or a single
                // letter). A URL never reaches here — it is handled
                // above.
                if let packURL = iconPack.iconURL(for: icon) {
                    CachedIconImage(url: packURL) {
                        Text(monogram)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                } else {
                    Text(icon)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if let packURL = iconPack.iconURL(for: name) {
                CachedIconImage(url: packURL) {
                    Text(monogram)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else {
                Text(monogram)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
    }
}

/// A group's icon at any size: the profile's icon URL (loaded) or
/// short text, else the user-imported icon pack (matched by group
/// name), else the group's first character. No bundled brand icons
/// (v0.2.53, user direction). Filled = rounded tile with 6pt inner
/// padding, plain = bare in the accent colour, hidden = nothing.
private struct GroupBrandIconView: View {
    let icon: String
    let name: String
    let size: CGFloat
    let iconStyle: ProxyStyleStore.IconStyle

    var body: some View {
        let content: some View = GroupIconImageView(icon: icon, name: name)
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
                // MuYu icon_card.dart: tile radius = AppCorner.xl
                // (24) − shrink (12) = 12pt (v0.2.81; was 8pt,
                // which made the tile look almost square).
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// One card-style group card (MuYu icon_card.dart GroupIconCard)
/// as its own Equatable view, fed only by plain values (same
/// pattern as ProxyNodeCard). The old iconCard(_:) was a function
/// on ProxiesView, so every @Published change in ProxyStore — each
/// delay-test result landing, each testing-flag flip — rebuilt
/// every visible card's body. As an Equatable struct with narrow
/// inputs, SwiftUI skips a card whose own values did not change,
/// so a latency landing on one group no longer re-renders the
/// other visible cards. Closures and the search FocusState binding
/// are ignored by == (actions only fire on tap; focus is not
/// rendered state). The metrics are derived from cardType with the
/// same switch as ProxiesView.iconCardMetrics; the collapsed
/// height is precomputed by the caller.
private struct IconGroupCard: View, Equatable {
    let name: String
    let type: String
    let icon: String
    /// Precomputed "TYPE · n/m" subtitle, uppercased (MuYu
    /// _GroupAvailability: type display name + available/total).
    let subtitle: String
    let selectedName: String?
    /// The selected node's group icon (profile icon or icon-pack
    /// URL as a string); nil shows no icon.
    let selectedIcon: String?
    let latencyMs: Int32?
    let testing: Bool
    let expanded: Bool
    let cardType: ProxyStyleStore.CardType
    let iconStyle: ProxyStyleStore.IconStyle
    /// Precomputed collapsed height (iconCardCollapsedHeight).
    let collapsedHeight: CGFloat
    /// Whether the VPN tunnel is running (drives the live speeds).
    let running: Bool
    /// Per-group search, rendered only while expanded.
    let searchKeyword: String
    let searchOpen: Bool
    let searchFocus: FocusState<String?>.Binding
    let onSearchKeywordChange: (String) -> Void
    let onSearchOpen: () -> Void
    let onSearchClose: () -> Void
    let onSearchAppear: () -> Void
    /// Tests this group (search-scoped while the page searches).
    let onTestLatency: () -> Void
    /// Card tap: pick in picker mode, else toggle expand.
    let onTap: () -> Void

    init(
        name: String,
        type: String,
        icon: String,
        subtitle: String,
        selectedName: String?,
        selectedIcon: String?,
        latencyMs: Int32?,
        testing: Bool,
        expanded: Bool,
        cardType: ProxyStyleStore.CardType,
        iconStyle: ProxyStyleStore.IconStyle,
        collapsedHeight: CGFloat,
        running: Bool,
        searchKeyword: String,
        searchOpen: Bool,
        searchFocus: FocusState<String?>.Binding,
        onSearchKeywordChange: @escaping (String) -> Void,
        onSearchOpen: @escaping () -> Void,
        onSearchClose: @escaping () -> Void,
        onSearchAppear: @escaping () -> Void,
        onTestLatency: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) {
        self.name = name
        self.type = type
        self.icon = icon
        self.subtitle = subtitle
        self.selectedName = selectedName
        self.selectedIcon = selectedIcon
        self.latencyMs = latencyMs
        self.testing = testing
        self.expanded = expanded
        self.cardType = cardType
        self.iconStyle = iconStyle
        self.collapsedHeight = collapsedHeight
        self.running = running
        self.searchKeyword = searchKeyword
        self.searchOpen = searchOpen
        self.searchFocus = searchFocus
        self.onSearchKeywordChange = onSearchKeywordChange
        self.onSearchOpen = onSearchOpen
        self.onSearchClose = onSearchClose
        self.onSearchAppear = onSearchAppear
        self.onTestLatency = onTestLatency
        self.onTap = onTap
    }

    // Closures and the FocusState binding are not Equatable:
    // compare everything else, and treat the actions as always
    // equal (they only fire on tap, like ProxyNodeCard.onTest).
    static func == (lhs: IconGroupCard, rhs: IconGroupCard) -> Bool {
        lhs.name == rhs.name
            && lhs.type == rhs.type
            && lhs.icon == rhs.icon
            && lhs.subtitle == rhs.subtitle
            && lhs.selectedName == rhs.selectedName
            && lhs.selectedIcon == rhs.selectedIcon
            && lhs.latencyMs == rhs.latencyMs
            && lhs.testing == rhs.testing
            && lhs.expanded == rhs.expanded
            && lhs.cardType == rhs.cardType
            && lhs.iconStyle == rhs.iconStyle
            && lhs.collapsedHeight == rhs.collapsedHeight
            && lhs.running == rhs.running
            && lhs.searchKeyword == rhs.searchKeyword
            && lhs.searchOpen == rhs.searchOpen
    }

    /// Card metrics (MuYu icon_card.dart _cardMetrics, lines 20–49):
    /// inset, name↔icon gap, meta gap, bottom gap, brand icon size.
    /// Same switch as ProxiesView.iconCardMetrics — the struct
    /// derives them from cardType instead of reading the store.
    private static func metrics(for cardType: ProxyStyleStore.CardType) -> (inset: CGFloat, nameIconGap: CGFloat, metaGap: CGFloat, bottomGap: CGFloat, brandSize: CGFloat) {
        switch cardType {
        case .compact: return (8, 6, 4, 8, 40)
        case .standard: return (12, 8, 6, 8, 48)
        case .loose: return (16, 8, 8, 10, 56)
        }
    }

    var body: some View {
        let m = Self.metrics(for: cardType)
        // A tap gesture, NOT a Button: the card holds the latency
        // pill Button and the search TextField, and a Button label
        // swallows their touches (tapping the field would collapse
        // the card instead of focusing it). The pill Button and the
        // field take priority over this gesture for their own taps.
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: m.nameIconGap) {
                Text(name)
                    .font(.callout)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Spacer()
                if iconStyle != .hidden {
                    GroupBrandIconView(icon: icon, name: name, size: m.brandSize, iconStyle: iconStyle)
                }
            }
            Spacer().frame(height: m.metaGap)
            HStack(spacing: 8) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if expanded {
                    groupSearchControl
                }
            }
            Spacer(minLength: m.bottomGap)
            HStack(spacing: m.nameIconGap) {
                // MuYu icon_card.dart _GroupBottomRow: the selected
                // node sits in an Expanded — it takes ALL remaining
                // width and truncates only when the row is genuinely
                // full. The old row gave the name its ideal width
                // next to a Spacer, so on a narrow card it was the
                // name that got squeezed ("故…"); with the
                // full-width rows above, the name now has the row to
                // itself apart from the speeds and the pill.
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
                    } else if type == "load-balance" {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("负载均衡")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // MuYu icon_card.dart:296-301: the speeds sit
                // between the selected node and the delay, only
                // while unfolded with a node selected.
                if let selectedName, expanded {
                    SelectedNodeSpeedsView(proxyName: selectedName, running: running)
                }
                if selectedName != nil {
                    latencyPill
                }
                // MuYu aligns the pill's right edge with the
                // brand icon above it (icon_card.dart:273-274).
                if iconStyle == .filled {
                    Spacer().frame(width: 6)
                }
            }
            .frame(height: 24)
        }
        .padding(m.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: expanded ? nil : collapsedHeight, alignment: .top)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .onTapGesture(perform: onTap)
    }

    /// Per-group search (MuYu GroupSearchControl, common.dart):
    /// a magnifier that opens a 128pt field filtering only this
    /// group's nodes. The clear button clears the keyword AND
    /// closes the field (MuYu _close). Autofocus on open; the
    /// keyword entry is removed when the text becomes empty.
    /// The keyword Binding is built here from the plain keyword
    /// value + the parent's change callback; focus is the parent's
    /// FocusState binding.
    private var groupSearchControl: some View {
        Group {
            if searchOpen {
                HStack(spacing: 4) {
                    TextField("搜索", text: Binding(
                        get: { searchKeyword },
                        set: { onSearchKeywordChange($0) }
                    ))
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(searchFocus, equals: name)
                    .frame(width: 128)
                    Button(action: onSearchClose) {
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
                .onAppear(perform: onSearchAppear)
            } else {
                Button(action: onSearchOpen) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索此组")
            }
        }
    }

    /// The latency pill (MuYu icon_card.dart _SelectedDelay): the
    /// bare number, no "ms" suffix; bolt when untested, spinner
    /// while testing. Tapping tests the group. While a test runs
    /// the pill is deliberately neutral instead of keeping the last
    /// delay's colour.
    private var latencyPill: some View {
        let color: Color = {
            if testing { return .secondary }
            guard let ms = latencyMs else { return .secondary }
            if ms > 0 { return ms < 600 ? .green : .orange }
            return .red
        }()
        return Button(action: onTestLatency) {
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
}

/// One rendered row of an expanded list-style group card, as plain
/// values: everything nodeCard reads to build one node card, so a
/// change in any of it flips the parent card's == and the grid is
/// rebuilt. The grid itself is NOT stored here — it arrives as a
/// @ViewBuilder closure from the caller, which reuses the existing
/// nodeCard wiring verbatim; the fingerprints are the ==-visible
/// shadow of that closure's data. INVARIANT: keep this struct in
/// sync with what the closure renders (nodeCard's inputs +
/// nodeMenu's inputs + the grid columns). A field rendered by the
/// grid but missing here would go stale when == says equal.
private struct ListGroupNodeFingerprint: Equatable {
    let name: String
    let typeDisplay: String
    let description: String
    let latencyMs: Int32?
    let testing: Bool
    let pinned: Bool
    let selected: Bool
    let memberIcon: String?
    /// nodeMenu's "添加到本地节点" row (FlClash _isAddableToLocal).
    let addable: Bool
}

/// One list-style group card (v0.2.68, video f_040) as its own
/// Equatable view, fed only by plain values plus the expanded node
/// grid as a @ViewBuilder closure (same scoping idea as
/// ProxyNodeCard: a latency landing on a node in another group
/// leaves this card's == true, so SwiftUI skips the whole card,
/// header and grid alike). The closure is ignored by ==; its data
/// is covered by nodeFingerprints (+ groupType, columnCount,
/// cardType, cardHeight — everything nodeCard / nodeMenu read).
/// Collapsed cards pass [] fingerprints: they render no grid, so
/// there is nothing to shadow, and the per-node lookups are
/// skipped entirely.
private struct ListGroupCard<ExpandedContent: View>: View, Equatable {
    let name: String
    let icon: String
    /// Capitalized type display name (Selector / URLTest / ...).
    let typeDisplay: String
    let selectedName: String?
    let expanded: Bool
    let iconStyle: ProxyStyleStore.IconStyle
    let columnCount: Int
    let cardType: ProxyStyleStore.CardType
    let cardHeight: CGFloat
    /// Raw group type: nodeMenu branches on it ("select" → 选择,
    /// url-test/fallback/smart → 首选）.
    let groupType: String
    let nodeFingerprints: [ListGroupNodeFingerprint]
    let expandedContent: () -> ExpandedContent
    /// Header tap: toggle expand/collapse (+ scroll into view).
    let onToggleExpand: () -> Void
    /// Expanded-header actions (MuYu list.dart, v0.2.88):
    /// scroll to the selected node, test this group, open the
    /// page search. Closures, so excluded from == like
    /// onToggleExpand.
    let onScrollToSelected: () -> Void
    let onTestAll: () -> Void
    let onSearch: () -> Void

    init(
        name: String,
        icon: String,
        typeDisplay: String,
        selectedName: String?,
        expanded: Bool,
        iconStyle: ProxyStyleStore.IconStyle,
        columnCount: Int,
        cardType: ProxyStyleStore.CardType,
        cardHeight: CGFloat,
        groupType: String,
        nodeFingerprints: [ListGroupNodeFingerprint],
        onToggleExpand: @escaping () -> Void,
        onScrollToSelected: @escaping () -> Void,
        onTestAll: @escaping () -> Void,
        onSearch: @escaping () -> Void,
        @ViewBuilder expandedContent: @escaping () -> ExpandedContent
    ) {
        self.name = name
        self.icon = icon
        self.typeDisplay = typeDisplay
        self.selectedName = selectedName
        self.expanded = expanded
        self.iconStyle = iconStyle
        self.columnCount = columnCount
        self.cardType = cardType
        self.cardHeight = cardHeight
        self.groupType = groupType
        self.nodeFingerprints = nodeFingerprints
        self.onToggleExpand = onToggleExpand
        self.onScrollToSelected = onScrollToSelected
        self.onTestAll = onTestAll
        self.onSearch = onSearch
        self.expandedContent = expandedContent
    }

    // The expanded-content closure is not Equatable: compare
    // everything else — the closure's rendered data is covered by
    // nodeFingerprints + groupType + columnCount + cardType +
    // cardHeight, so == false whenever the grid would look
    // different. The toggle action only fires on tap.
    static func == (lhs: ListGroupCard, rhs: ListGroupCard) -> Bool {
        lhs.name == rhs.name
            && lhs.icon == rhs.icon
            && lhs.typeDisplay == rhs.typeDisplay
            && lhs.selectedName == rhs.selectedName
            && lhs.expanded == rhs.expanded
            && lhs.iconStyle == rhs.iconStyle
            && lhs.columnCount == rhs.columnCount
            && lhs.cardType == rhs.cardType
            && lhs.cardHeight == rhs.cardHeight
            && lhs.groupType == rhs.groupType
            && lhs.nodeFingerprints == rhs.nodeFingerprints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Left cluster taps to toggle. The expanded
                // action pill is NOT inside a tap-to-toggle area:
                // a Button inside .onTapGesture would fire both,
                // so the toggle tap lives only on the left cluster
                // and on the collapsed trailing.
                HStack(spacing: 10) {
                    groupIconView(icon: icon, name: name, iconStyle: iconStyle)
                    VStack(alignment: .leading, spacing: 2) {
                        // MuYu ListHeader (v0.2.81): name = callout
                        // 16pt emphasized, subtitle + type = caption1
                        // 12pt emphasized grey. Was subheadline 15pt
                        // + caption2 11pt — visibly smaller than MuYu.
                        Text(name)
                            .font(.callout)
                            .fontWeight(.bold)
                            .lineLimit(1)
                        Text(selectedName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minHeight: 13, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)
                Spacer()
                if expanded {
                    expandedHeaderActions
                } else {
                    HStack(spacing: 10) {
                        Text(typeDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // MuYu ExpandIcon in a tonal compact IconButton
                        // (v0.2.81): the screenshot's light-grey circle is
                        // ~36pt with a ~14pt chevron (was 30pt / 12pt).
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemGray4), in: Circle())
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggleExpand)
                }
            }
            // MuYu card padding is 6pt all round (v0.2.81; was
            // 12 horizontal / 10 vertical). Row stays 60pt:
            // 48pt icon + 2×6pt padding.
            .padding(6)
            if expanded {
                expandedContent()
            }
        }
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    /// MuYu expanded header (list.dart, v0.2.88): a light pill
    /// with target / bolt / magnifier, plus a separate grey
    /// circle with a black up-triangle to collapse (IMG_1243 —
    /// the triangle sits in its own circle, like the collapsed
    /// chevron, not inside the pill). The pill fill is
    /// pageBackground — the same grey as the node cards, one
    /// level above the white group card. Icons use .primary so
    /// they stay visible in dark mode, where the pill fill is
    /// dark; the triangle circle keeps the existing black-on-
    /// systemGray4, which reads in both modes.
    private var expandedHeaderActions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                Button(action: onScrollToSelected) {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("滚动到已选")
                Button(action: onTestAll) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("测速本组")
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(ConcordTheme.pageBackground, in: RoundedRectangle(cornerRadius: 18))
            Button(action: onToggleExpand) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color(.systemGray4), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起")
        }
    }
}

/// Group icon (FlClash _GroupIcon): the profile's icon when it is
/// a URL (loaded) or short text (shown as-is), else the
/// user-imported icon pack (matched by group name), else the
/// group's first character. Filled puts it in a rounded tile,
/// plain shows it bare, hidden leaves a small gap so the title
/// lines up with the card names below.
// MuYu list.dart _GroupIcon (v0.2.81): the plain icon fills the
// header row height (listHeaderHeight − card padding = 48pt), and
// the filled tile is the same 48pt with 6pt inner padding (36pt
// icon) and a 14pt radius (AppCorner.xl 24 − _headerInset 10).
// The old 40pt icon + 8pt tile radius left the logo visibly
// smaller than MuYu's and the tile almost square ("有的都没有圆角").
private func groupIconView(icon: String, name: String, iconStyle: ProxyStyleStore.IconStyle) -> some View {
    let content: some View = GroupIconImageView(icon: icon, name: name)
    switch iconStyle {
    case .hidden:
        return AnyView(Color.clear.frame(width: 4, height: 48))
    case .plain:
        return AnyView(
            content
                .foregroundStyle(ConcordTheme.accent)
                .frame(width: 48, height: 48)
        )
    case .filled:
        return AnyView(
            content
                .frame(width: 36, height: 36)
                .frame(width: 48, height: 48)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
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
    /// Capitalized display type (ProxiesView.nodeTypeDisplayName:
    /// URLTest / Selector / Vless), NOT the raw core spelling.
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
    /// The nested group's profile icon, for nodes that are
    /// themselves groups (MuYu card.dart member icon, 16pt).
    /// Nil for leaf nodes — the core exposes no per-node icon.
    let memberIcon: String?
    /// Fill (v0.2.88): the card's background. Default is
    /// cardBackground (white in light mode) — Tab / Card / search
    /// keep it. List-expanded passes pageBackground so the node
    /// reads as a grey rounded card on the white group interior
    /// (MuYu: the node is one level above its scope, FlClash
    /// list.dart "Card fills one level above its scope"). In
    /// dark mode pageBackground is black + 8% accent vs the
    /// group's #1C1C1E + 8% — a subtle step, same order as
    /// MuYu's near-white-on-white in light mode.
    let fill: Color
    let onTest: () -> Void

    init(
        name: String,
        type: String,
        description: String,
        latencyMs: Int32?,
        testing: Bool,
        pinned: Bool,
        selected: Bool,
        cardType: ProxyStyleStore.CardType,
        cardHeight: CGFloat,
        memberIcon: String?,
        fill: Color = ConcordTheme.cardBackground,
        onTest: @escaping () -> Void
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.latencyMs = latencyMs
        self.testing = testing
        self.pinned = pinned
        self.selected = selected
        self.cardType = cardType
        self.cardHeight = cardHeight
        self.memberIcon = memberIcon
        self.fill = fill
        self.onTest = onTest
    }

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
            && lhs.memberIcon == rhs.memberIcon
            && lhs.fill == rhs.fill
    }

    var body: some View {
        // FlClash card.dart: name is subheadline (15pt), the
        // type/description line is footnote (13pt), the delay is
        // caption2 (11pt). The card's padding is horizontal 12 only;
        // the content is vertically centred in the fixed height
        // (the formula's 16pt vertical slack = 10pt top + 10pt
        // bottom at standard size). Name→details gap is 8pt;
        // loose cards add a 6pt gap before the delay row.
        // No type icon (v0.2.68, video f_020/f_043): the video shows
        // only the plain capitalized type text — the 10pt SF Symbol
        // (and the remote icon-set image) is ours-only and removed.
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
                    // FlClash SelectionBadge (card.dart:205-219,
                    // selection_mark.dart): a 22pt solid-primary
                    // circle + white ✓, INLINE in the name row —
                    // upstream has no corner overlay. (v0.2.79: the
                    // v0.2.68 corner overlay half-overlapped the
                    // card's top-right edge and floated in the gap
                    // between cards in the 2-column grid.)
                    ZStack {
                        Circle()
                            .fill(ConcordTheme.accent)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            if cardType == .loose {
                VStack(alignment: .leading, spacing: 6) {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(action: onTest) {
                        DelayText(latencyMs: latencyMs, testing: testing)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
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
        .background(fill, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}

/// Delay text, FlClash _DelayText (card.dart:258-400): plain text,
/// no capsule. <600ms success green, >=600ms warning orange, <0
/// error red; -1 is 超时, other negatives 失败 (video f_043 —
/// not "测速失败")
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
                    Text(ms == -1 ? "超时" : "失败")
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
                // After a confirmed repair, a remaining missing-set
                // error (v0.2.62, 150G: TikTok fixed, Netflix next
                // — the core only reports one missing set at a
                // time) offers the next repair right here, instead
                // of making the user close the sheet and tap 修复
                // again from the banner. The new plan replaces the
                // offer in place; prepareRuleSetRepair clears the
                // old outcome first.
                if plan.isRepairable, proxyStore.ruleSetRepairOutcome != nil, !proxyStore.ruleSetRepairOutcomeIsSuccess,
                   let next = proxyStore.missingRuleSetName,
                   !plan.items.map({ $0.missingName }).contains(next) {
                    ToolbarItem(placement: .confirmationAction) {
                        if proxyStore.isRepairingRuleSet {
                            ProgressView()
                        } else {
                            Button("继续修复「\(next)」") {
                                Task { await proxyStore.prepareRuleSetRepair() }
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

struct SelectedNodeSpeedsView: View {
    let proxyName: String
    let running: Bool
    @EnvironmentObject var trafficStore: TrafficStore

    var body: some View {
        let speed: NodeSpeed = running ? (trafficStore.nodeSpeeds[proxyName] ?? NodeSpeed.zero) : NodeSpeed.zero
        HStack(spacing: 4) {
            speedFigure(systemName: "arrow.up", bytesPerSecond: speed.up)
            speedFigure(systemName: "arrow.down", bytesPerSecond: speed.down)
        }
    }

    /// One figure (MuYu _SpeedFigure): 12pt glyph + rate text,
    /// 2pt apart, caption2 semibold in the muted colour. The rate
    /// text is "value unit/s" (MuYu _rateText), via the same
    /// ConcordBytes.split the Dashboard speed panels use.
    private func speedFigure(systemName: String, bytesPerSecond: Double) -> some View {
        let split = ConcordBytes.split(Int64(bytesPerSecond))
        return HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 12))
            Text("\(split.number) \(split.unit)/s")
                .lineLimit(1)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
    }
}
