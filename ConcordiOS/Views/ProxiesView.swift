import SwiftUI

// MARK: - Proxies (FlClash: ProxiesView, lib/views/proxies/)
// FlClash proxies page, reproduced in SwiftUI:
// - Top bar: ONE capsule (FlClash TonalButtonGroup) holding search
//   (magnifier, presents the search field) + bolt. In tab style the
//   bolt tests the current group; in list / card style it tests ALL
//   groups (MuYu iOS build _delayTestAllGroups). The ⋯ opens a white
//   card menu (FlClash PopupMenu, lib/views/proxies/proxies.dart:
//   40-110): 风格/排序/布局/尺寸/图标样式 each open a SUBMENU with
//   a checkmark on the current value, plus 隐藏超时代理 as a direct
//   toggle row. No test-all and no refresh in the menu (FlClash
//   has neither there). 滚动到已选 is a top-bar button in tab
//   style (upstream iconActions, v0.2.123); re-tapping the
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
//   hand. Long-press opens the card menu: 选择/设为首选 + 添加到本地
//   节点 only (v0.2.146 P-D11 — the ours-only 测速 / 节点详情 rows
//   are gone). Tapping the delay chip tests that node.

/// Card-style folder bar (MuYu-only, lib/enum/enum.dart
/// ProxyFolder + lib/views/proxies/list.dart _FolderBar): filters
/// the group grid. `leafNodes` replaces the grid with a flat list
/// of deduplicated leaf nodes. Labels are MuYu's arb strings
/// (全部/策略组/节点组/节点）.
private enum ProxyFolder: String, CaseIterable {
    case all, strategy, nodes, leafNodes
    var label: String {
        switch self {
        case .all: return "common.all".l10n
        case .strategy: return "proxies.filter.strategy".l10n
        case .nodes: return "proxies.filter.nodeGroups".l10n
        case .leafNodes: return "proxies.filter.nodes".l10n
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

// MARK: - Proxies nav bar appearance (v0.2.108, rebuilt v0.2.123)
// The bar is a SOLID page background (opaque, no translucent
// material, no hairline), matching upstream FlClash's Scaffold
// bar, which sits on the page surface with no separate bar
// background. v0.2.108–122 did this with ProxiesNavBarAppearance,
// a UIViewControllerRepresentable attached as a full-page
// .background on the NavigationStack — the only UIKit view in
// this page's hierarchy, and the prime suspect for the dead
// Proxies taps (introduced v0.2.108, first complaint ~1 h later
// on v0.2.109; five card/Button fixes failed, the log's
// "代理组点按诊断" stayed empty). v0.2.122 set its view
// non-interactive and the taps STILL stayed dead, so the shield
// theory is closed — but the layer is removed anyway: upstream's
// page is a plain Scaffold + scroll view with no full-page
// overlay, and this page now has no representable at all. The
// same opaque UINavigationBarAppearance is applied by plain code
// instead — ProxiesView.applyNavBarAppearance(), called from
// .onAppear and on theme change — via the appearance proxy (bars
// created later) plus a window walk (the live bar). No view, no
// view controller, nothing that can sit above the page and
// swallow a touch. iOS 13+ API throughout; the
// toolbarBackgroundVisibility(.visible) alternative is iOS 18+
// and the deployment target is iOS 17.

struct ProxiesView: View {
    /// Picker mode (FlClash proxies.dart:14-18,157,165,174):
    /// as a dashboard sheet the page keeps only search + delay
    /// test — the ⋯ menu is stripped and the locate button hidden.
    /// v0.2.146 P-D1 (rs.1 wins over the MuYu-video picker): the
    /// sheet keeps the USER'S style (tab or list) instead of
    /// forcing the card grid, and has no bottom floating search
    /// bar — the top inline search field opens from a magnifier
    /// button in the sheet header, like the tab page. v0.2.64:
    /// the dashboard's 策略组 card presents this in picker mode
    /// (upstream showProxiesSheet), with a sheet header (✕ + 代理
    /// + a standalone bolt circle, v0.2.68 video f_018: two
    /// separate white circles, no ⋯) instead of the 24pt tab
    /// title. `onPickGroup`, when set, is called with the picked
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
    /// Observed so the nav bar appearance follows the theme:
    /// pageBackground is theme-dependent (magenta keeps a pink
    /// tint, dark mode tints), so a theme change must re-run
    /// applyNavBarAppearance below with the new colour.
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var customStore = CustomProxyStore()
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showMoreMenu = false
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

    /// Search-matching node names across ALL groups (v0.2.146
    /// P-F2): the union the top bolt / picker bolt test while
    /// searching (FlClash delayTestPageGroup(matchSearch: true)
    /// tests only search matches). Nil while not searching, so
    /// the test-all covers every node.
    private var searchMatchedAllNodeNames: [String]? {
        guard searching else { return nil }
        var out: [String] = []
        for group in proxyStore.displayGroups {
            out.append(contentsOf: group.nodes.filter(matchesSearch).map(\.name))
        }
        return Array(Set(out))
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
        // P-D13 (rs.1 delaysAtLastTestBatch): the delay is read from
        // the map frozen at the last test batch's start (or end),
        // not the live latency — otherwise nodes drop out one by
        // one mid-test. Before the first test the frozen map is
        // empty and the live value is the fallback (rs.1's initial
        // state, where the frozen map IS the live map).
        let ms = proxyStore.latencyAtLastTestBatch(for: node.name, inGroup: group.name) ?? node.latencyMs
        guard let ms else { return true }
        return ms > 0
    }

    /// Case- and hyphen-insensitive match against the FlClash
    /// unprobeable set, so "REJECT-DROP" and "RejectDrop" both match.
    private static func isUnprobeableType(_ type: String) -> Bool {
        Self.unprobeableTypesNormalized.contains(type.lowercased().replacingOccurrences(of: "-", with: ""))
    }

    /// Delay-sort priority (FlClash DelayState.priority, models/
    /// common.dart:1089-1112): delay > 0 → 0; == 0 → 1 (untested —
    /// a 0 ms result is not a failure, v0.2.146 P-D14); nil →
    /// 1 as well (FlClash delay ?? 0); == -1 (timeout) → 2;
    /// anything else (-2 and below) → 3.
    private static func delayPriority(_ node: ProxyNode) -> Int {
        guard let ms = node.latencyMs else { return 1 }
        if ms > 0 { return 0 }
        if ms == 0 { return 1 }
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

    /// Folder counts, from the RAW group list (v0.2.146 P-D9 —
    /// MuYu list.dart:460-470 counts from allGroups =
    /// groupsProvider, the raw provider list INCLUDING hidden
    /// groups; rs.1 has no folder bar at all, so this one follows
    /// MuYu). The old comment claimed "raw means before search
    /// filtering, provider already mode-filtered" — wrong: the
    /// counts must not depend on the mode filter either.
    private func folderCount(_ folder: ProxyFolder) -> Int {
        let raw = proxyStore.groups
        switch folder {
        case .all: return raw.count
        case .strategy: return raw.filter { !isNodeOnlyGroup($0) }.count
        case .nodes: return raw.filter { isNodeOnlyGroup($0) }.count
        case .leafNodes: return rawLeafNodeCount
        }
    }

    /// Raw leaf-node count (P-D9, same base as folderCount):
    /// MuYu countLeafNodes over allGroups — pure dedupe, no
    /// search/hide/delay filter (compute.dart:76-89).
    private var rawLeafNodeCount: Int {
        let groupNames = allGroupNames
        var seen = Set<String>()
        var count = 0
        for group in proxyStore.groups {
            for node in group.nodes {
                guard !groupNames.contains(node.name),
                      !Self.reservedNames.contains(node.name),
                      seen.insert(node.name).inserted else { continue }
                count += 1
            }
        }
        return count
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
        return base.filter { !hidden.contains($0.name) || proxyStore.expandedGroups.contains($0.name) }
    }

    /// Names of groups that are members of a currently-expanded
    /// group (v0.2.68, item 6): read from the RAW groups, so a
    /// member hidden by the page search still counts — its card
    /// is hidden by the search anyway, and the exclusion must not
    /// depend on the filtered copy.
    private var expandedMemberNames: Set<String> {
        var out = Set<String>()
        for name in proxyStore.expandedGroups {
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
        return visibleGroups.filter { !hidden.contains($0.name) || proxyStore.expandedGroups.contains($0.name) }
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

    /// Explicit empty state for an expanded group with no nodes
    /// to show (v0.2.119 FIX 2): without it an expansion renders
    /// an empty grid and reads as "no response" apart from the
    /// chevron / triangle swap — in card style the only other
    /// change is the magnifier appearing. A group CAN be empty
    /// while having members: in the local YAML fallback a
    /// `use:`-only group whose http provider has no cached file
    /// resolves to zero members (ProfileStore
    /// .resolveProviderNodes returns [] — the nodes stay unknown
    /// until the tunnel runs), and a group filter matching
    /// nothing does the same. The live path resolves `use:` in
    /// the core, so this is mainly the VPN-off fallback; a
    /// per-group search matching nothing says so instead of
    /// "暂无节点".
    private func emptyNodesRow(for group: ProxyGroup) -> some View {
        let searching = !(groupSearchKeywords[group.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 13))
            Text(searching ? "proxies.empty.noMatchShort".l10n : "proxies.empty.none".l10n)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 14)
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
    /// name (IconPackStore.iconURL), then the bundled brands
    /// (BrandIcons, v0.2.141 — a match returns the name so
    /// GroupIconImageView resolves it to the brand mark there).
    /// Leaf nodes have no icon source — the Concord core exposes
    /// no per-node icon (ConcordNodeInfo has name/type/provider
    /// only), so they show nothing, exactly as MuYu's
    /// `if (proxy.icon.isNotEmpty)`.
    /// A pack URL is returned as a string: GroupIconImageView loads
    /// http(s) icon strings directly.
    private func memberIcon(for node: ProxyNode, groupsByName: [String: ProxyGroup]) -> String? {
        guard Self.groupTypes.contains(node.type),
              let sub = groupsByName[node.name] else { return nil }
        if !sub.icon.isEmpty { return sub.icon }
        if let packURL = IconPackStore.shared.iconURL(for: node.name) {
            return packURL.absoluteString
        }
        return BrandIcons.hasBrand(for: node.name) ? node.name : nil
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
                    // The top inline search field (searchField
                    // renders nothing while !isSearching): shown on
                    // the tab page and in the picker sheet alike
                    // (v0.2.146 P-D1 — the picker has no bottom
                    // floating bar any more; its magnifier button
                    // opens this field).
                    searchField
                    // Direct user-action feedback (v0.2.146 P-D12):
                    // the only notice left on this page. rs.1 has
                    // no delay-test / repair banners (those are
                    // gone, with their store state), but its
                    // selectGroupProxy DOES show a warning banner
                    // for a non-selectable tap (card.dart:10-35) —
                    // so a notice row stays for exactly that:
                    // taps the user made and the app must answer
                    // (not-allowed tip, add-to-local results).
                    // Text + dismiss × only — no retry / 修复 buttons.
                    if let notice {
                        HStack {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { self.notice = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    // Picker and tab page render the same content:
                    // the USER'S style (v0.2.146 P-D1) — the picker
                    // no longer forces the card grid.
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
                        .accessibilityLabel("common.close".l10n)
                    }
                    ToolbarItem(placement: .principal) {
                        Text("tab.proxies".l10n)
                            .font(.headline)
                    }
                    // P-D1: the picker opens the top inline search
                    // field from a magnifier circle (same 36pt
                    // circle as the bolt), like the tab page's
                    // magnifier opens it from the pill.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isSearching = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(.label))
                                .frame(width: 36, height: 36)
                                .background(ConcordTheme.cardBackground, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("common.search".l10n)
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
                    // Upstream proxies.dart iconActions (v0.2.123):
                    // in tab style the locate button sits in the
                    // top bar next to the search/bolt pill — scroll
                    // to the selected node of the current group.
                    // It used to live as the ⋯ menu's first row
                    // (MuYu video build); upstream has it here and
                    // the menu has no such row, so it moves here.
                    if styleStore.style == .tab {
                        ToolbarItem(placement: .topBarTrailing) {
                            locateButton
                        }
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
            .task {
                // The refresh's VPN-off fallback scans the active
                // profile's YAML; the scan itself runs off the main
                // thread (ProxyStore.refresh falls back via
                // Task.detached). Deferring one runloop turn here
                // additionally guarantees the static title and the
                // loading state render before any of that starts.
                // v0.2.167: refresh on EVERY first mount, not only
                // when the list is empty — the Dashboard fills the
                // list first (with the core's defaults), so the old
                // `groups.isEmpty` gate skipped this refresh and the
                // page showed the defaults until a manual refresh,
                // even though a remembered pick was on disk. The
                // refresh carries the active profile, so the
                // remembered picks are re-applied (ProxyStore
                // applyPendingSelections); one extra fetch buys
                // correctness.
                DispatchQueue.main.async {
                    Task { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
                }
            }
            .onChange(of: profileStore.activeProfile?.id) { _, _ in
                Task { await proxyStore.refresh(activeProfile: profileStore.activeProfile) }
            }
            .onChange(of: groupSearchFocus) { _, focused in
                if focused == nil {
                    for name in groupSearchOpen where (groupSearchKeywords[name] ?? "").isEmpty {
                        groupSearchOpen.remove(name)
                    }
                }
            }
            .onAppear {
                // The bar's opaque appearance has no view behind
                // it anymore (v0.2.123: the representable is
                // gone), so it is applied here on every appear.
                applyNavBarAppearance()
            }
            .onChange(of: themeStore.accent) { _, _ in
                applyNavBarAppearance()
            }
            .onChange(of: themeStore.appearance) { _, _ in
                applyNavBarAppearance()
            }
            .onChange(of: themeStore.pureBlack) { _, _ in
                applyNavBarAppearance()
            }
        }
        .toolbarBackground(ConcordTheme.pageBackground, for: .navigationBar)
        // v0.2.108: the bar must render the SOLID page colour at
        // rest, not the system translucent material. Upstream's
        // Scaffold bar sits on the page surface (tone 94) with no
        // separate bar background (scaffold.dart: the bar and body
        // share backgroundColor; ProxiesView passes none, so both
        // are the page surface). With the default .automatic
        // visibility the bar showed the translucent material at
        // rest, which rendered as a near-white strip (~#FBFBFD)
        // across the top of this page while the page itself is
        // #F2F2F7 (IMG_1290). The Dashboard has no NavigationStack
        // and no such strip.
        // toolbarBackgroundVisibility(.visible) would force it, but
        // that API is iOS 18+ and the deployment target is iOS 17
        // (CI archive error: 'toolbarBackgroundVisibility is only
        // available in iOS 18.0 or newer'). The opaque
        // UINavigationBarAppearance is therefore applied by plain
        // code — applyNavBarAppearance(), from .onAppear and on
        // theme change — NOT by a representable: v0.2.123 removed
        // the ProxiesNavBarAppearance .background layer entirely
        // (see the file-scope note at the top), so no UIKit view
        // sits anywhere above this page's content.
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
                                isPresented: $showMoreMenu
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

    /// The opaque nav-bar appearance, applied by plain code —
    /// no view, no view controller (see the file-scope note at
    /// the top: the v0.2.108–122 UIViewControllerRepresentable
    /// is gone in v0.2.123). The appearance proxy covers bars
    /// created later; the window walk restyles the live bar —
    /// the Proxies bar already exists when this page appears
    /// (all four tabs mount at launch), so the proxy alone would
    /// not restyle it. Called from .onAppear and whenever the
    /// theme changes (the .onChange observers below).
    private func applyNavBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(ConcordTheme.pageBackground)
        appearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.applyNavBarAppearance(appearance, to: window.rootViewController)
            }
        }
    }

    /// Recursively applies one appearance to every navigation
    /// bar under a view controller (children + presented).
    private static func applyNavBarAppearance(_ appearance: UINavigationBarAppearance, to viewController: UIViewController?) {
        guard let viewController else { return }
        if let nav = viewController as? UINavigationController {
            nav.navigationBar.standardAppearance = appearance
            nav.navigationBar.scrollEdgeAppearance = appearance
            nav.navigationBar.compactAppearance = appearance
        }
        for child in viewController.children {
            applyNavBarAppearance(appearance, to: child)
        }
        applyNavBarAppearance(appearance, to: viewController.presentedViewController)
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
                TextField("proxies.search.placeholder".l10n, text: $searchText)
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
                    .accessibilityLabel("proxies.search.clear".l10n)
                }
                Button {
                    isSearching = false
                    searchText = ""
                } label: {
                    Text("common.cancel".l10n)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 10))
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
    /// searchField). Scroll-to-selected is a top-bar button in
    /// tab style (upstream proxies.dart iconActions, v0.2.123 —
    /// it used to be the ⋯ menu's first row, MuYu video build);
    /// re-tapping the active group pill scrolls to the selected
    /// node too.
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
            Button {
                // v0.2.123 discriminator: if the group headers
                // stay dead, this line proves whether ANY touch
                // reaches the page at all (toolbar vs cards).
                ProxyTapDiagnostics.record("top bar search tapped")
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .imageScale(.medium)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.search".l10n)
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
    /// delayTestingGroupsProvider.isNotEmpty). While searching
    /// only the search-matching names are tested (v0.2.146 P-F2:
    /// the old no-filter call tested everything even mid-search).
    private var topBarTestAllButton: some View {
        let testing = !proxyStore.testingGroups.isEmpty
        return Button {
            Task { await proxyStore.testLatency(nodeNames: searchMatchedAllNodeNames) }
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
        .accessibilityLabel("proxies.testAll".l10n)
    }

    /// The picker header's bolt (v0.2.68, video f_018): a
    /// STANDALONE white circle, 36pt like the ✕ on the other side
    /// — not the magnifier+bolt capsule, and with no ⋯ menu next
    /// to it. Tests all groups, like the list / card bolt; while
    /// searching only the search-matching names (v0.2.146 P-F2).
    private var pickerBoltButton: some View {
        let testing = !proxyStore.testingGroups.isEmpty
        return Button {
            Task { await proxyStore.testLatency(nodeNames: searchMatchedAllNodeNames) }
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
        .accessibilityLabel("proxies.testAll".l10n)
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
        Button {
            // v0.2.123 discriminator, as on the search button
            // above: toolbar proof vs group-card proof.
            ProxyTapDiagnostics.record("top bar more tapped")
            showMoreMenu.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 19, weight: .semibold))
                .imageScale(.medium)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("common.more".l10n)
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
        .accessibilityLabel("proxies.testSpeed".l10n)
    }

    /// The locate button (FlClash proxies.dart iconActions,
    /// v0.2.123): tab style only, in the top bar next to the
    /// search/bolt pill. Scrolls the current group's grid to its
    /// selected node. Same 44pt circle as the ⋯ button; the
    /// target glyph matches the per-header locate button below.
    private var locateButton: some View {
        Button { scrollToSelected(in: selectedGroup) } label: {
            Image(systemName: "scope")
                .font(.system(size: 19, weight: .semibold))
                .imageScale(.medium)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(selectedGroup?.selectedNodeName == nil)
        .accessibilityLabel("proxies.scrollToSelected".l10n)
        .background(ConcordTheme.cardBackground, in: Circle())
    }

    // MARK: - ⋯ menu (FlClash PopupMenu, lib/views/proxies/proxies.dart)

    /// The ⋯ menu is a white card, not a native context menu:
    /// 风格， 排序， 布局， 尺寸， 图标样式 (not in tab style), and
    /// the hide-timeout toggle last. Each of the five rows drills
    /// into a SUBMENU with a checkmark on the current value
    /// (v0.2.146 P-D2 — rs.1 PopupMenu, proxies.dart:40-110; the
    /// old inline accordion is gone). Tapping an option applies it
    /// and closes the menu. No test-all and no refresh in the menu
    /// — FlClash has neither there (the bolt is the test; refresh
    /// is pull-to-refresh). Icon style shows in list AND card
    /// style, hidden only in tab style (MuYu changed FlClash's
    /// `type == list` to `type != tab` when it added the card
    /// style, proxies.dart).
    /// A plain VStack, NOT a NavigationStack: a NavigationStack
    /// inside a popover reports no usable ideal height, so the card
    /// rendered clipped to ~1 row (v0.2.27). The drilled-in
    /// section is state, and the card sizes itself to the VStack
    /// — the same as FlClash's PopupMenu sizing to its content.

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

        /// The section currently drilled into (v0.2.146 P-D2):
        /// rs.1's PopupMenu opens each section as a SUBMENU,
        /// not an inline accordion — one section at a time, with
        /// a back row to the root. Nil = the root list.
        private enum MenuSection: Hashable {
            case style, sort, layout, size, iconStyle
        }
        @State private var activeSection: MenuSection?

        var body: some View {
            VStack(spacing: 0) {
                if let section = activeSection {
                    // Back row: returns to the root list, labelled
                    // with the section's own name — rs.1's submenu
                    // title is the same section name.
                    Button {
                        withAnimation { activeSection = nil }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(sectionLabel(section))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                        .padding(.vertical, 4)
                    submenuOptions(for: section)
                } else {
                    // Root: one row per section, each drilling into
                    // its submenu (chevron.right); the hide-timeout
                    // toggle stays a direct row, as in rs.1.
                    menuSectionRow(
                        icon: Image(systemName: "list.bullet")
                            .font(.system(size: 19, weight: .semibold)),
                        label: "proxies.options.style".l10n
                    ) { activeSection = .style }
                    // 排序 (MuYu: three horizontal lines, decreasing —
                    // SF line.3.horizontal.decrease; the old
                    // arrow.up.arrow.down up/down arrows do not match).
                    menuSectionRow(
                        icon: Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 19, weight: .semibold)),
                        label: "proxies.options.sort".l10n
                    ) { activeSection = .sort }
                    menuSectionRow(
                        icon: Image(systemName: "square.grid.2x2")
                            .font(.system(size: 19, weight: .semibold)),
                        label: "proxies.options.layout".l10n
                    ) { activeSection = .layout }
                    // 尺寸 (MuYu: a "Tt" glyph — SF Symbols has none,
                    // so the custom TtIcon in CustomGlyphs.swift).
                    menuSectionRow(
                        icon: TtIcon(size: 20),
                        label: "proxies.options.size".l10n
                    ) { activeSection = .size }
                    if styleStore.style != .tab {
                        menuSectionRow(
                            icon: Image(systemName: "photo")
                                .font(.system(size: 19, weight: .semibold)),
                            label: "proxies.options.iconStyle".l10n
                        ) { activeSection = .iconStyle }
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
                            Text("proxies.options.hideTimeout".l10n)
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
            .onDisappear { activeSection = nil }
        }

        private func sectionLabel(_ section: MenuSection) -> String {
            switch section {
            case .style: return "proxies.options.style".l10n
            case .sort: return "proxies.options.sort".l10n
            case .layout: return "proxies.options.layout".l10n
            case .size: return "proxies.options.size".l10n
            case .iconStyle: return "proxies.options.iconStyle".l10n
            }
        }

        /// The options of one drilled-in section (v0.2.146 P-D2):
        /// tapping one applies it and closes the whole menu.
        @ViewBuilder
        private func submenuOptions(for section: MenuSection) -> some View {
            switch section {
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

        /// One root row (v0.2.146 P-D2): the whole row is the tap
        /// target — icon, label, empty space and chevron all drill
        /// into the submenu (`.contentShape(Rectangle())` makes
        /// the Button cover the full row width). The chevron is
        /// only a visual indicator: > always (the row drills down,
        /// it never expands inline). The icon is a generic View so
        /// the SF Symbol rows and the custom TtIcon row share this
        /// helper.
        private func menuSectionRow<Icon: View>(
            icon: Icon,
            label: String,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                withAnimation { action() }
            } label: {
                HStack(spacing: 12) {
                    icon
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
                                        // Picker mode (v0.2.146 P-D1): a pill
                                        // tap PICKS the group (dashboard
                                        // sheet contract) instead of
                                        // selecting / scrolling to it.
                                        if picker, let pick = onPickGroup {
                                            pick(group.name)
                                        } else if selectedVisibleGroup?.id == group.id {
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
                                    .background(selectedVisibleGroup?.id == group.id ? ConcordTheme.accent : ConcordTheme.softFill, in: Capsule())
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
                        .accessibilityLabel("proxies.allGroups".l10n)
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
                        .padding(.top, 12)
                        .padding(.bottom, ConcordTheme.tabBarClearance)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            withAnimation { reader.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            } else if proxyStore.displayGroups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searching {
                ContentUnavailableView("proxies.empty.noMatchTitle".l10n, systemImage: "magnifyingglass", description: Text("proxies.empty.tryAnotherKeyword".l10n))
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
    /// Each card's row is the brand icon (~40pt), the name bold
    /// with the selected node in gray below, and on the right the
    /// capitalized type ("Selector") + a light-gray solid circle
    /// holding a black chevron (▼ collapsed, ▲ expanded).
    /// Tapping the row expands the group inline: its nodes appear
    /// inside the same card. The expanded header shows the locate
    /// / bolt / per-group-search pill (MuYu list.dart) and the
    /// collapse triangle. Headers pin while scrolling (v0.2.146
    /// P-D4 — one Section per group, pinnedViews .sectionHeaders),
    /// so the header stays visible while its nodes scroll under
    /// it; the node grid is the section's content. Members of an
    /// expanded group are not listed again as their own cards
    /// below (listGroups, item 6).
    private func listContent(width: CGFloat) -> some View {
        // One group lookup for this pass (see rawGroupsByName).
        let groupsByName = rawGroupsByName
        return Group {
            if proxyStore.displayGroups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGroups.isEmpty && searching {
                ContentUnavailableView("proxies.empty.noMatchTitle".l10n, systemImage: "magnifyingglass", description: Text("proxies.empty.tryAnotherKeyword".l10n))
            } else if visibleGroups.isEmpty {
                noGroupsView
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        // P-D4 (rs.1/MuYu PinnedHeaderSliver): one
                        // Section per group, headers pinned — the
                        // header stays visible while its nodes scroll
                        // under it. spacing 0 + the flush header /
                        // content seam keep the one-card look: the
                        // header carries the top corners when
                        // expanded and the full radius when
                        // collapsed, the node container the bottom
                        // corners. The 8pt inter-card gap is a
                        // clear spacer at the end of each section's
                        // content (NOT header padding, which would
                        // stick to the pinned header, and NOT stack
                        // spacing, which would also gap the header
                        // from its own nodes).
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(listGroups) { group in
                                Section {
                                    if proxyStore.expandedGroups.contains(group.name) {
                                        listGroupNodes(group, width: width, groupsByName: groupsByName)
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 12)
                                            .background(ConcordTheme.cardBackground, in: UnevenRoundedRectangle(bottomLeadingRadius: ConcordTheme.panelRadius, bottomTrailingRadius: ConcordTheme.panelRadius))
                                    }
                                    Color.clear.frame(height: 8)
                                } header: {
                                    listGroupHeader(group)
                                        .id(groupHeaderID(group.name))
                                }
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
                    ContentUnavailableView("proxies.empty.noMatchTitle".l10n, systemImage: "magnifyingglass", description: Text("proxies.empty.tryAnotherKeyword".l10n))
                } else if iconFolder == .leafNodes && leafNodeEntries.isEmpty {
                    noGroupsView
                } else if folderGroups.isEmpty && searching {
                    ContentUnavailableView("proxies.empty.noMatchTitle".l10n, systemImage: "magnifyingglass", description: Text("proxies.empty.tryAnotherKeyword".l10n))
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
                    }
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            // P-D4 (rs.1/MuYu PinnedHeaderSliver):
                            // expanded groups are Sections, so the
                            // card pins while its nodes scroll under
                            // it; collapsed pairs stay plain rows.
                            // The 8pt stack spacing is the gap the
                            // old expanded VStack(spacing: 8) gave
                            // between card and nodes, and between
                            // rows — unchanged.
                            LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                                ForEach(iconSegments) { segment in
                                    switch segment {
                                    case .pair(let first, let second):
                                        HStack(spacing: 8) {
                                            iconGroupCard(first, groupsByName: groupsByName)
                                                .id(groupHeaderID(first.name))
                                            if let second {
                                                iconGroupCard(second, groupsByName: groupsByName)
                                                    .id(groupHeaderID(second.name))
                                            } else {
                                                Color.clear
                                                    .frame(maxWidth: .infinity)
                                            }
                                        }
                                    case .expanded(let group):
                                        Section {
                                            if displayNodes(for: group).isEmpty {
                                                emptyNodesRow(for: group)
                                            } else {
                                                LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                                                    ForEach(displayNodes(for: group)) { node in
                                                        nodeCard(node, in: group, groupsByName: groupsByName)
                                                            .id(scrollID(nodeName: node.name, groupName: group.name))
                                                    }
                                                }
                                            }
                                        } header: {
                                            iconGroupCard(group, groupsByName: groupsByName)
                                                .id(groupHeaderID(group.name))
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
            if proxyStore.expandedGroups.contains(group.name) {
                out.append(.expanded(group))
                index += 1
                continue
            }
            let next = index + 1
            if next < folderGroups.count, !proxyStore.expandedGroups.contains(folderGroups[next].name) {
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
    /// GroupIconCard): every value the card renders is precomputed
    /// here into plain values. The per-group search state, the
    /// latency pill action and the tap action are passed as
    /// closures the parent owns; the struct only calls them.
    /// v0.2.120: the card is deliberately NOT Equatable and call
    /// sites do NOT add .equatable() — that wrapper froze the card
    /// in its launch-time disabled state (see IconGroupCard), so
    /// no tap ever reached it on 117–119. Plain values keep the
    /// re-render cheap; the delay-test churn the old == skipped
    /// is 3–4 group cards, not the 40+ node cards (those keep
    /// .equatable(), their tap sits outside the wrapper).
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
            expanded: proxyStore.expandedGroups.contains(group.name),
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
                // Expansion goes through the store (v0.2.118): the
                // store reference can never go stale, so the action
                // must not close over the view's @State.
                let wasExpanded = proxyStore.expandedGroups.contains(group.name)
                proxyStore.toggleExpanded(group.name)
                if !wasExpanded {
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
    /// name (IconPackStore.iconURL), then the bundled brands
    /// (BrandIcons, v0.2.141 — a match returns the name so
    /// GroupIconImageView resolves it to the brand mark there).
    /// A node with no icon anywhere shows no monogram there. A
    /// pack URL is returned as a string: GroupIconImageView loads
    /// http(s) icon strings directly.
    private func selectedNodeIcon(for group: ProxyGroup, groupsByName: [String: ProxyGroup]) -> String? {
        guard let selected = group.selectedNodeName else { return nil }
        if let sub = groupsByName[selected],
           !sub.icon.isEmpty {
            return sub.icon
        }
        if let packURL = IconPackStore.shared.iconURL(for: selected) {
            return packURL.absoluteString
        }
        return BrandIcons.hasBrand(for: selected) ? selected : nil
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
            ContentUnavailableView("proxies.empty.noGroups".l10n, systemImage: "globe", description: Text("proxies.empty.importHint".l10n))
        } else {
            ContentUnavailableView("proxies.empty.noGroupsInProfile".l10n, systemImage: "globe", description: Text("proxies.empty.noProxiesInProfile".l10n))
        }
    }

    /// One list-style group header (v0.2.68, video f_040): the
    /// header row — brand icon (~40pt, groupIcon), name bold with
    /// the selected node in gray below (FlClash ListHeader: the
    /// subtitle is the selected node name whenever there is one,
    /// hidden entirely when there is none; the minHeight keeps the
    /// two-line height stable when the subtitle is empty —
    /// upstream's header is a fixed 61pt), and on the right the
    /// capitalized type ("Selector", never the raw lowercase type)
    /// + a light-gray solid circle holding a black chevron (▼
    /// collapsed, ▲ expanded). Tapping the row toggles
    /// expand/collapse; expanding scrolls the group into view once
    /// its rows are laid out (FlClash _handleChange, list.dart:
    /// 45-60). Built as a plain ListGroupHeader (v0.2.120: NOT
    /// Equatable, no .equatable() — see the struct; the old wrapper
    /// froze the card in its launch-time disabled state and no tap
    /// ever reached it on 117–119). The header's values are plain
    /// inputs. The expanded node grid is the section's content
    /// (listGroupNodes), not part of the header.
    private func listGroupHeader(_ group: ProxyGroup) -> some View {
        let expanded = proxyStore.expandedGroups.contains(group.name)
        return ListGroupHeader(
            name: group.name,
            icon: group.icon,
            typeDisplay: Self.typeDisplayName(group.type),
            selectedName: group.selectedNodeName,
            expanded: expanded,
            iconStyle: styleStore.iconStyle,
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
            onToggleExpand: {
                // Picker (v0.2.146 P-D1): tapping a group picks it
                // instead of expanding — the caller selects the
                // group, dismisses the sheet, and switches to the
                // Proxies tab (same contract as the card style's
                // onTap).
                if picker {
                    onPickGroup?(group.name)
                    return
                }
                // Expansion goes through the store (v0.2.118): the
                // store reference can never go stale, so the action
                // must not close over the view's @State.
                let wasExpanded = proxyStore.expandedGroups.contains(group.name)
                proxyStore.toggleExpanded(group.name)
                if !wasExpanded {
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        scrollTargetName = groupHeaderID(group.name)
                        scrollNonce += 1
                    }
                }
            },
            onScrollToSelected: { scrollToSelected(in: group) },
            onTestAll: { Task { await proxyStore.testLatency(group: group, nodeNames: searchMatchedNodeNames(forGroupNamed: group.name)) } }
        )
    }

    /// The node grid inside an expanded list-style group (the
    /// Section content in listContent): the same LazyVGrid the old
    /// ListGroupCard drew inside the card, now as the section's
    /// rows. The per-group search keyword (displayNodes) filters
    /// only this group's nodes.
    private func listGroupNodes(_ group: ProxyGroup, width: CGFloat, groupsByName: [String: ProxyGroup]) -> some View {
        let nodes = displayNodes(for: group)
        return Group {
            if nodes.isEmpty {
                emptyNodesRow(for: group)
            } else {
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
            }
        }
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
            // P-D3: queued for a group run but not yet started —
            // the clock glyph (rs.1 DelayTestPhase.queued).
            queued: proxyStore.queuedNodes.contains(node.name),
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
            // v0.2.123 discriminator: node taps use a gesture,
            // headers a Button — if this line appears while the
            // header lines stay empty, the blocker is specific
            // to the header Button path, not the page.
            ProxyTapDiagnostics.record("node card tapped: \(node.name) in \(group.name)")
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
                        Text("proxies.selector.select".l10n)
                        Spacer()
                        if selected { Image(systemName: "checkmark") }
                    }
                }
            } else if group.type == "url-test" || group.type == "fallback" || group.type == "smart" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    HStack {
                        Text("proxies.selector.preferred".l10n)
                        Spacer()
                        if pinned { Image(systemName: "checkmark") }
                    }
                }
            }
            if isAddable(node) {
                Button { Task { await addToLocal(node: node) } } label: {
                    Label("proxies.menu.addLocal".l10n, systemImage: "plus.square.on.square")
                }
            }
            // v0.2.146 P-D11: the ours-only 测速 / 节点详情 rows are
            // gone — the menu keeps ONLY 选择/设为首选 + 添加到本地
            // 节点. Per-node test stays on the delay chip.
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
                showNotice("proxies.notice.readFailed".l10n)
                return
            }
            let issues = try await client.validateProxies(proxies: [definition])
            if let first = issues.first {
                showNotice("\("proxies.notice.validationFailed".l10n)\(first.message)")
                return
            }
            if customStore.proxies.contains(where: { $0.name == node.name })
                || customStore.rawProxies.contains(where: { $0.objectValue?["name"]?.stringValue == node.name }) {
                showNotice("proxies.notice.alreadyLocal".l10n)
                return
            }
            customStore.rawProxies.append(definition)
            customStore.save()
            guard var text = profileStore.activeProfileYAML() else {
                showNotice("proxies.notice.noWritableConfig".l10n)
                return
            }
            text = CustomProxyStore.bakeCurrent(into: text)
            let saved = await profileStore.saveActiveProfileYAML(text)
            showNotice("\("proxies.notice.addedLocal".l10n)\(saved)")
        } catch {
            showNotice("\("proxies.notice.addFailed".l10n)\(error.localizedDescription)")
        }
    }
}

/// A group's icon image, resolved in priority order: the profile's
/// own icon (a URL is loaded; a name is matched through the
/// user-imported icon pack, v0.2.57; other short text such as an
/// emoji or a letter is shown as-is), then the user-imported icon
/// pack (IconPackStore, matched by group name), then the bundled
/// brand marks (BrandIcons, v0.2.141 — the icons revert restores
/// MuYu's 20-entry map; the pack wins over a brand when both
/// match), else the group's first character.
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
                // icon pack first, then the bundled brands; only a
                // miss in both falls back to showing the text
                // itself (an emoji or a single letter). A URL never
                // reaches here — it is handled above.
                if let packURL = iconPack.iconURL(for: icon) {
                    CachedIconImage(url: packURL) {
                        Text(monogram)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                } else if let brand = BrandIcons.icon(for: icon) {
                    BrandIcons.view(for: brand)
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
            } else if let brand = BrandIcons.icon(for: name) {
                BrandIcons.view(for: brand)
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
/// name), else a bundled brand mark (v0.2.141), else the group's
/// first character. Filled = rounded tile with 6pt inner padding,
/// plain = bare in the accent colour, hidden = nothing.
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
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// One card-style group card (MuYu icon_card.dart GroupIconCard),
/// fed only by plain values. v0.2.120: deliberately NOT Equatable,
/// and never wrapped in .equatable() again — the wrapper froze the
/// card in the disabled state it mounted in (ContentView disables
/// every off-screen tab; all four pages mount at launch, so the
/// cards are born disabled, and while collapsed every == field was
/// static, so the frozen subtree never re-rendered enabled). That
/// is why no tap — gesture in 117, Button in 119 — ever reached
/// the card. As a plain view the parent rebuilds it with the live
/// environment on every render. Same trade as ListGroupHeader: the
/// 40+ node cards keep their Equatable optimization.
private struct IconGroupCard: View {
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

    /// The card metrics tuple, named so cardContent / nameRow can
    /// take it without repeating the tuple type.
    private typealias CardMetrics = (inset: CGFloat, nameIconGap: CGFloat, metaGap: CGFloat, bottomGap: CGFloat, brandSize: CGFloat)

    /// Card metrics (MuYu icon_card.dart _cardMetrics, lines 20–49):
    /// inset, name↔icon gap, meta gap, bottom gap, brand icon size.
    /// Same switch as ProxiesView.iconCardMetrics — the struct
    /// derives them from cardType instead of reading the store.
    private static func metrics(for cardType: ProxyStyleStore.CardType) -> CardMetrics {
        switch cardType {
        case .compact: return (8, 6, 4, 8, 40)
        case .standard: return (12, 8, 6, 8, 48)
        case .loose: return (16, 8, 8, 10, 56)
        }
    }

    var body: some View {
        let m = Self.metrics(for: cardType)
        // The collapsed card is a real Button (v0.2.119 FIX 2,
        // same pattern as ListGroupHeader in v0.2.118): the old
        // .onTapGesture on this card never fired on-device
        // (v0.2.117 — every group card untappable in card style).
        // The gesture and the 119 Button both died the same way:
        // the card was wrapped in .equatable(), which froze it in
        // the disabled state it mounted in (see the struct
        // comment) — v0.2.120 removes the wrapper, so this Button
        // is rebuilt live on every render. The collapsed card
        // DOES hold one inner Button — the latency pill, shown
        // whenever a node is selected — and SwiftUI gives the
        // innermost Button the tap, so tapping the pill still
        // tests the group instead of expanding it; taps anywhere
        // else expand/collapse. Expanded, the card also holds the
        // search TextField, and a Button wrapping a TextField
        // swallows its focus (the reason for the old gesture),
        // so the expanded card is NOT wrapped: only its name row
        // is a Button, which collapses. The search control and
        // the latency pill keep working untouched in both states.
        if expanded {
            cardContent(m: m)
        } else {
            Button(action: { tapAction() }) {
                cardContent(m: m)
            }
            .buttonStyle(.plain)
        }
    }

    /// The Button action, shared by the collapsed wrap and the
    /// expanded name row: records the proof line, then runs the
    /// parent's tap (pick in picker mode, else toggle expand in
    /// the store — toggleExpanded records its own line, so one
    /// tap must produce both lines in the log export).
    private func tapAction() {
        ProxyTapDiagnostics.record("IconGroupCard button fired: \(name) (expanded=\(expanded))")
        onTap()
    }

    /// The card's rows (name / subtitle / selected node + pill),
    /// without any tap handling: the caller wraps it in a Button
    /// when collapsed, and the name row is itself a Button when
    /// expanded (see body). Visuals unchanged from the old
    /// .onTapGesture version.
    private func cardContent(m: CardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                Button(action: { tapAction() }) {
                    nameRow(m: m)
                        // v0.2.121: same hit-area fix as the list
                        // card — the name row is an HStack with a
                        // Spacer, so without a contentShape only its
                        // glyphs collapse the card.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                nameRow(m: m)
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
                        Text("proxies.loadBalance".l10n)
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
    }

    /// The top row: group name + brand icon. A Button by itself
    /// only when expanded (collapsed, the whole card is already
    /// the Button — see body).
    private func nameRow(m: CardMetrics) -> some View {
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
                    TextField("common.search".l10n, text: Binding(
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
                    .accessibilityLabel("proxies.search.clear".l10n)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 8))
                .onAppear(perform: onSearchAppear)
            } else {
                Button(action: onSearchOpen) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("proxies.search.thisGroup".l10n)
            }
        }
    }

    /// The latency pill (MuYu icon_card.dart _SelectedDelay): the
    /// bare number, no "ms" suffix; bolt when untested, spinner
    /// while testing. Tapping tests the group. While a test runs
    /// the pill is deliberately neutral instead of keeping the last
    /// delay's colour.
    private var latencyPill: some View {
        // P-D10: the colour is the theme delay colour (rs.1
        // delayColor), not a literal — same hues, so the look is
        // unchanged. ms == 0 follows delayColor too (success);
        // the text for 0 stays 失败 (unchanged).
        let color: Color = {
            if testing { return .secondary }
            guard let ms = latencyMs else { return .secondary }
            return ConcordTheme.delayColor(for: ms)
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
                        Text(ms == -1 ? "proxies.latency.timeout".l10n : "common.failed".l10n)
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

/// One list-style group header (v0.2.68, video f_040) as its own
/// view, fed only by plain values (same scoping idea as
/// ProxyNodeCard). v0.2.146 P-D4: the header is a Section header
/// in listContent's LazyVStack (pinned while scrolling — rs.1/MuYu
/// PinnedHeaderSliver), so the old ListGroupCard (header + node
/// grid in one rounded card) is split: this struct is the header
/// only, and the node grid is the section's content. The header
/// carries its own background — full radius when collapsed,
/// top-only radius when expanded (the section content carries
/// the bottom radius) — so the seam stays flush at spacing 0.
/// v0.2.120: deliberately NOT Equatable, and never wrapped in
/// .equatable() again — the wrapper froze the card in the
/// disabled state it mounted in (ContentView disables every
/// off-screen tab; all four pages mount at launch, so the cards
/// are born disabled, and while collapsed every == field was
/// static, so the frozen subtree never re-rendered enabled).
/// That is why no tap — gesture in 117, Button in 118/119 —
/// ever reached the card. As a plain view the parent rebuilds
/// it with the live environment on every render, so the header
/// Button is enabled whenever the tab is selected. The cost is
/// re-rendering 3–4 group headers on store changes; the 40+ node
/// cards keep their Equatable optimization (their tap sits
/// outside the wrapper, and they mount after the tab is
/// selected, so they never mount disabled).
private struct ListGroupHeader: View {
    let name: String
    let icon: String
    /// Capitalized type display name (Selector / URLTest / ...).
    let typeDisplay: String
    let selectedName: String?
    let expanded: Bool
    let iconStyle: ProxyStyleStore.IconStyle
    /// Per-group search (MuYu GroupSearchControl, common.dart),
    /// rendered only while expanded: the keyword filters only
    /// this group's nodes (v0.2.146 P-F1 — the state was dead
    /// code in list style before; the card style already had it).
    let searchKeyword: String
    let searchOpen: Bool
    let searchFocus: FocusState<String?>.Binding
    let onSearchKeywordChange: (String) -> Void
    let onSearchOpen: () -> Void
    let onSearchClose: () -> Void
    let onSearchAppear: () -> Void
    /// Header tap: toggle expand/collapse (+ scroll into view).
    let onToggleExpand: () -> Void
    /// Expanded-header actions (MuYu list.dart, v0.2.88):
    /// scroll to the selected node, test this group.
    let onScrollToSelected: () -> Void
    let onTestAll: () -> Void

    init(
        name: String,
        icon: String,
        typeDisplay: String,
        selectedName: String?,
        expanded: Bool,
        iconStyle: ProxyStyleStore.IconStyle,
        searchKeyword: String,
        searchOpen: Bool,
        searchFocus: FocusState<String?>.Binding,
        onSearchKeywordChange: @escaping (String) -> Void,
        onSearchOpen: @escaping () -> Void,
        onSearchClose: @escaping () -> Void,
        onSearchAppear: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void,
        onScrollToSelected: @escaping () -> Void,
        onTestAll: @escaping () -> Void
    ) {
        self.name = name
        self.icon = icon
        self.typeDisplay = typeDisplay
        self.selectedName = selectedName
        self.expanded = expanded
        self.iconStyle = iconStyle
        self.searchKeyword = searchKeyword
        self.searchOpen = searchOpen
        self.searchFocus = searchFocus
        self.onSearchKeywordChange = onSearchKeywordChange
        self.onSearchOpen = onSearchOpen
        self.onSearchClose = onSearchClose
        self.onSearchAppear = onSearchAppear
        self.onToggleExpand = onToggleExpand
        self.onScrollToSelected = onScrollToSelected
        self.onTestAll = onTestAll
    }

    var body: some View {
        // The expanded header is NOT wrapped in a Button: it
        // holds a TextField (the per-group search), and a Button
        // wrapping a TextField swallows its focus — the same
        // reason IconGroupCard's expanded card is unwrapped.
        // Only the left icon+name part is a Button (collapse);
        // the actions pill and the triangle keep working
        // untouched. Collapsed, the whole header is one Button,
        // as before.
        Group {
            if expanded {
                HStack(spacing: 10) {
                    Button(action: { tapAction() }) {
                        leftContent
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The middle gap collapses too (v0.2.123: the
                    // whole header used to be one Button, and the
                    // old split left the centre dead). It cannot be
                    // part of a Button — the header now holds a
                    // TextField — so the Spacer itself takes the tap.
                    Spacer()
                        .contentShape(Rectangle())
                        .onTapGesture { tapAction() }
                    expandedHeaderActions
                }
                .padding(6)
            } else {
                Button(action: { tapAction() }) {
                    HStack(spacing: 10) {
                        leftContent
                        Spacer()
                        collapsedRight
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            ConcordTheme.cardBackground,
            in: expanded
                ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: ConcordTheme.panelRadius, topTrailingRadius: ConcordTheme.panelRadius))
                : AnyShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        )
    }

    /// The header Button action (v0.2.119 FIX 2, v0.2.123: now
    /// the whole header in BOTH states): records the proof line,
    /// then toggles the store — the same two-line proof as
    /// IconGroupCard, so one tap in either style must produce both
    /// lines in the log export. (The expanded triangle Button keeps
    /// calling onToggleExpand directly; its proof is
    /// toggleExpanded's own line.)
    private func tapAction() {
        ProxyTapDiagnostics.record("ListGroupHeader button fired: \(name) (expanded=\(expanded))")
        onToggleExpand()
    }

    /// Brand icon + name / selected node (MuYu ListHeader,
    /// v0.2.81): name = callout 16pt emphasized, subtitle +
    /// type = caption1 12pt emphasized grey. Row stays 60pt:
    /// 48pt icon + 2×6pt padding.
    private var leftContent: some View {
        HStack(spacing: 10) {
            groupIconView(icon: icon, name: name, iconStyle: iconStyle)
            VStack(alignment: .leading, spacing: 2) {
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
    }

    /// Collapsed right side: capitalized type + a light-gray
    /// solid circle holding a black chevron (MuYu ExpandIcon in
    /// a tonal compact IconButton, v0.2.81: ~36pt circle with a
    /// ~14pt chevron).
    private var collapsedRight: some View {
        HStack(spacing: 10) {
            Text(typeDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(Color(.systemGray4), in: Circle())
        }
    }

    /// MuYu expanded header (list.dart, v0.2.88): a light pill
    /// with target / bolt / per-group search, plus a separate
    /// grey circle with a black up-triangle to collapse (IMG_1243
    /// — the triangle sits in its own circle, like the collapsed
    /// chevron, not inside the pill). The pill fill is
    /// pageBackground — the same grey as the node cards, one
    /// level above the white group card. Icons use .primary so
    /// they stay visible in dark mode, where the pill fill is
    /// dark; the triangle circle keeps the existing black-on-
    /// systemGray4, which reads in both modes. The magnifier that
    /// used to open the PAGE search is gone (v0.2.146 P-F1): the
    /// GroupSearchControl sits here instead, filtering only this
    /// group's nodes.
    private var expandedHeaderActions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                Button(action: onScrollToSelected) {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("proxies.scrollToSelected".l10n)
                Button(action: onTestAll) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("proxies.testGroup".l10n)
                groupSearchControl
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
            .accessibilityLabel("proxies.collapse".l10n)
        }
    }

    /// Per-group search (MuYu GroupSearchControl, common.dart):
    /// a magnifier opens a 128pt field; the keyword filters only
    /// this group's nodes. Closes the field (MuYu _close) and
    /// clears the keyword on ×. Autofocus on open; the keyword
    /// entry is removed when the text becomes empty. The keyword
    /// Binding is built here from the plain keyword value + the
    /// parent's change callback; focus is the parent's FocusState
    /// binding. Same control as IconGroupCard's.
    private var groupSearchControl: some View {
        Group {
            if searchOpen {
                HStack(spacing: 4) {
                    TextField("common.search".l10n, text: Binding(
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
                    .accessibilityLabel("proxies.search.clear".l10n)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 8))
                .onAppear(perform: onSearchAppear)
            } else {
                Button(action: onSearchOpen) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("proxies.search.thisGroup".l10n)
            }
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
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 14))
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
    /// Queued for a group run but not yet started (v0.2.146 P-D3 —
    /// rs.1 DelayTestPhase.queued): the clock glyph in DelayText.
    let queued: Bool
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
        queued: Bool,
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
        self.queued = queued
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
            && lhs.queued == rhs.queued
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
                        DelayText(latencyMs: latencyMs, testing: testing, queued: queued)
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
                        DelayText(latencyMs: latencyMs, testing: testing, queued: queued)
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

/// Delay-test colours (v0.2.146 P-D10): rs.1's delayColor reads the
/// theme's success / warning / error tokens (ui/delay_color.dart),
/// not literal green / orange / red. This app's theme has no such
/// tokens yet (DesignSystem.swift defines ConcordTheme without
/// them), so they live here as an extension on ConcordTheme until
/// a theme pass adds them to the theme itself — same hues as the
/// old literals, so the look is unchanged. NOTE for the v0.2.146
/// coordinator: if another agent adds the same three tokens (e.g.
/// in DesignSystem.swift), delete these three lines — a duplicate
/// definition is a compile error.
extension ConcordTheme {
    /// Success green (<600 ms).
    static var success: Color { .green }
    /// Warning orange (>=600 ms).
    static var warning: Color { .orange }
    /// Error red (<0 ms — 超时 / 失败）.
    static var error: Color { .red }

    /// The delay colour for one latency (rs.1 delayColor,
    /// ui/delay_color.dart:5-10): <0 → error, <600 → success, else
    /// warning. (Null → no colour — the caller shows the bolt.)
    static func delayColor(for ms: Int32) -> Color {
        if ms < 0 { return ConcordTheme.error }
        return ms < 600 ? ConcordTheme.success : ConcordTheme.warning
    }
}

/// Delay text, FlClash _DelayText (card.dart:258-400): plain text,
/// no capsule. Colours come from the theme success/warning/error
/// tokens (v0.2.146 P-D10 — rs.1 delayColor, ui/delay_color.dart:
/// 5-10): <600ms success, >=600ms warning, <0 error; -1 is 超时,
/// other negatives 失败 (video f_043 — not "测速失败")
/// (ui/delay_color.dart:5-10, common/app_localizations.dart:130-134).
/// Untested shows the bolt glyph, as in FlClash; queued shows a
/// clock glyph (rs.1 DelayTestPhase.queued, card.dart:360-372).
private struct DelayText: View {
    let latencyMs: Int32?
    /// While this node's test runs (FlClash shows an ActivityIndicator
    /// for DelayTestPhase.running); without it the tap shows nothing
    /// until the result lands.
    var testing: Bool = false
    /// Queued for a group run but not yet started (v0.2.146 P-D3 —
    /// rs.1 DelayTestPhase.queued, card.dart:360-372): a clock glyph
    /// in the secondary colour (rs.1 AppGlyphs.clock, onSurfaceVariant
    /// opacity 38 — .secondary here).
    var queued: Bool = false

    var body: some View {
        Group {
            if testing {
                // S2 (v0.2.145, upstream rs.1 card.dart:258-400):
                // the indicator slot is the caption2 text height
                // (11pt), not footnote — the spinner renders at
                // ~11pt (20pt default x 0.55). (v0.2.138 used
                // footnote 13pt per the stable-v0.9.5 spec; the
                // user decision "按照上游的改" follows rs.1.)
                ProgressView()
                    .frame(width: 11, height: 11)
                    .scaleEffect(0.55)
            } else if queued {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            } else if let ms = latencyMs {
                if ms > 0 {
                    Text("\(ms) ms")
                        .foregroundStyle(ConcordTheme.delayColor(for: ms))
                } else {
                    Text(ms == -1 ? "proxies.latency.timeout".l10n : "common.failed".l10n)
                        .foregroundStyle(ConcordTheme.error)
                }
            } else {
                Image(systemName: "bolt")
                    .foregroundStyle(.secondary)
            }
        }
        // S2 (v0.2.145, upstream rs.1 card.dart:258-400): the
        // delay indicator (bolt / spinner / text) is caption2
        // (11pt), emphasized — the textHeight(caption2) slot
        // upstream sizes the spinner and glyphs by.
        .font(.caption2)
        .fontWeight(.semibold)
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
