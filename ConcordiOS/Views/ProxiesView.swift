import SwiftUI

// MARK: - Proxies (FlClash: ProxiesView, lib/views/proxies/)
// FlClash proxies page, reproduced in SwiftUI:
// - Top bar: ONE capsule (FlClash TonalButtonGroup) holding search
//   (magnifier, presents the search field) + bolt (tab style only,
//   delay-tests the current group) + ⋯. The ⋯ opens a white card
//   menu (FlClash PopupMenu): 风格/排序/布局/尺寸/图标样式, each
//   opening a submenu with a checkmark on the current value, plus
//   隐藏超时代理. No test-all and no refresh in the menu (FlClash
//   has neither there); no locate button in the bar — re-tapping the
//   active group pill scrolls to the selected node.
// - Style 标签页： group pills on top, one group's nodes as cards in
//   a grid. Style 列表： every group stacked with a collapsible
//   header (icon, name, selected node, per-group delay test +
//   scroll to selected), nodes as cards in a grid.
// - Layout 紧凑/标准/宽松 sets the grid columns (3/2/1 on a phone);
//   size 紧凑/标准/宽松 sets the card content (1-line name / 2-line
//   name / + description row). Icon style only applies to the list
//   headers. Hide-timeout keeps the selected node, group nodes and
//   untested nodes, and never empties a group.
// - Tap a card to select it (Selector) or pin/unpin it as 首选
//   (url-test / fallback); load-balance / relay cannot be chosen by
//   hand. Long-press opens the card menu: 选择/设为首选， 添加到本地
//   节点， 测速， 节点详情. Tapping the delay chip tests that node.

struct ProxiesView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @StateObject private var styleStore = ProxyStyleStore()
    @StateObject private var customStore = CustomProxyStore()
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showMoreMenu = false
    @State private var menuPath = NavigationPath()
    @State private var selectedGroupName: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var detailNode: ProxyNode?
    @State private var notice: String?
    @State private var scrollTargetName: String?
    @State private var scrollNonce = 0

    private static let groupTypes: Set<String> = ["select", "url-test", "fallback", "load-balance", "relay"]
    private static let unprobeableTypes: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS"]
    private static let reservedNames: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "GLOBAL"]

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedGroup: ProxyGroup? {
        if let name = selectedGroupName {
            return proxyStore.groups.first { $0.name == name }
        }
        return proxyStore.groups.first
    }

    /// Groups after search + hide-timeout + sort (FlClash:
    /// filterGroupsState + computeHideTimeout). Searching bypasses
    /// hide-timeout, so a group whose matches all timed out keeps
    /// them; a group left with no visible node keeps all its nodes.
    /// Group identity is preserved (copies keep the same id), so the
    /// expanded/collapsed state and scroll ids survive a refresh.
    private var visibleGroups: [ProxyGroup] {
        var out: [ProxyGroup] = []
        for group in proxyStore.groups {
            var nodes = group.nodes
            if searching {
                nodes = nodes.filter { node in
                    node.name.localizedCaseInsensitiveContains(searchText)
                        || node.type.localizedCaseInsensitiveContains(searchText)
                }
                guard !nodes.isEmpty else { continue }
            } else if styleStore.hideTimeout {
                let kept = nodes.filter { keepWhenHidingTimeout($0, in: group) }
                if !kept.isEmpty { nodes = kept }
            }
            var copy = group
            copy.nodes = sortNodes(nodes)
            out.append(copy)
        }
        return out
    }

    private func keepWhenHidingTimeout(_ node: ProxyNode, in group: ProxyGroup) -> Bool {
        // The selected node, and nodes that are groups themselves,
        // are always kept — hiding them would take away the only way
        // to choose that group.
        if node.name == group.selectedNodeName { return true }
        if proxyStore.groups.contains(where: { $0.name == node.name }) { return true }
        if Self.unprobeableTypes.contains(node.type) { return true }
        guard let ms = node.latencyMs else { return true }
        return ms > 0
    }

    private func sortNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
        switch styleStore.sort {
        case .default: return nodes
        case .delay: return nodes.sorted { ($0.latencyMs ?? Int32.max) < ($1.latencyMs ?? Int32.max) }
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

    private func gridColumns(width: CGFloat) -> [GridItem] {
        let count = ProxyStyleStore.columns(for: styleStore.layout, width: width)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var cardHeight: CGFloat {
        switch styleStore.cardType {
        case .compact: return 68
        case .standard: return 88
        case .loose: return 112
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
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                    if let notice {
                        HStack {
                            Text(notice)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { self.notice = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
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
                    }
                }
                .background(ConcordTheme.pageBackground)
            }
            .navigationTitle("代理")
            .searchable(text: $searchText, isPresented: $isSearching, prompt: "搜索节点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    topBarCapsule
                }
            }
            .sheet(item: $detailNode) { node in
                NodeDetailView(node: node)
            }
            .task { if proxyStore.groups.isEmpty { await proxyStore.refresh() } }
        }
    }

    // MARK: - Top bar

    /// One capsule holding search + bolt + ⋯ (FlClash TonalButtonGroup:
    /// the bar groups its actions into a single pill; the bolt only
    /// shows in tab style, where it tests the current group). The
    /// search is a magnifier button that presents the search field;
    /// there is no separate locate button in the bar (FlClash folds
    /// it into the ⋯ menu) — re-tapping the active group pill scrolls
    /// to the selected node instead.
    private var topBarCapsule: some View {
        HStack(spacing: 0) {
            Button { isSearching = true } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
            capsuleDivider
            if styleStore.style == .tab {
                topBarBoltButton(for: selectedGroup)
                capsuleDivider
            }
            Button { showMoreMenu = true } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
            .popover(isPresented: $showMoreMenu, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                moreMenuPopover
            }
        }
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private var capsuleDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 20)
    }

    /// The bolt: in tab style it tests the current group (FlClash
    /// delayTestCurrentGroup). There is no test-all in the ⋯ menu —
    /// the bolt is the delay test, as in FlClash.
    private func topBarBoltButton(for group: ProxyGroup?) -> some View {
        let testing = group.map { proxyStore.testingGroups.contains($0.name) } ?? false
        return Button {
            if let group { Task { await proxyStore.testLatency(group: group) } }
        } label: {
            if testing {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "bolt.fill")
                    .frame(width: 36, height: 36)
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
    /// the test; refresh is pull-to-refresh). Icon style only shows
    /// in list style, as in FlClash.
    private enum MenuDestination: Hashable {
        case style, sort, layout, size, iconStyle
    }

    private var moreMenuPopover: some View {
        NavigationStack(path: $menuPath) {
            VStack(spacing: 0) {
                menuRow(icon: "list.bullet", label: "风格", destination: .style)
                menuRow(icon: "arrow.up.arrow.down", label: "排序", destination: .sort)
                menuRow(icon: "square.grid.2x2", label: "布局", destination: .layout)
                menuRow(icon: "textformat.size", label: "尺寸", destination: .size)
                if styleStore.style == .list {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationDestination(for: MenuDestination.self) { dest in
                menuOptionsView(for: dest)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minWidth: 260, idealWidth: 280)
        .presentationCompactAdaptation(.popover)
    }

    private func menuRow(icon: String, label: String, destination: MenuDestination) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 22)
                Text(label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A submenu: the options with a checkmark on the current value.
    /// Tapping one applies it and pops back to the menu root.
    private func menuOptionsView(for dest: MenuDestination) -> some View {
        VStack(spacing: 0) {
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
        .navigationTitle(menuTitle(for: dest))
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
            menuPath = NavigationPath()
        } label: {
            HStack(spacing: 12) {
                Text(label)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab style

    private func tabContent(width: CGFloat) -> some View {
        VStack(spacing: 0) {
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
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedVisibleGroup?.id == group.id ? ConcordTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(selectedVisibleGroup?.id == group.id ? .white : Color(.label))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 6)

            if let group = selectedVisibleGroup {
                Text("\(group.type) · \(group.nodes.count) 个节点 · 当前：\(group.selectedNodeName ?? "未选择")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .refreshable { await proxyStore.refresh() }
                }
            } else if proxyStore.groups.isEmpty && proxyStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searching {
                ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
            } else {
                ContentUnavailableView("暂无代理组", systemImage: "globe", description: Text("请先在“订阅”页导入并激活一个订阅"))
            }
        }
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
                ContentUnavailableView("暂无代理组", systemImage: "globe", description: Text("请先在“订阅”页导入并激活一个订阅"))
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(visibleGroups) { group in
                                groupSection(group, width: width)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        if let target = scrollTargetName {
                            withAnimation { reader.scrollTo(target, anchor: .center) }
                        }
                    }
                    .refreshable { await proxyStore.refresh() }
                }
            }
        }
    }

    private func groupSection(_ group: ProxyGroup, width: CGFloat) -> some View {
        let expanded = !collapsedGroups.contains(group.name)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                groupIcon(group)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 15))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(expanded ? (group.selectedNodeName ?? "未选择") : group.type)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if expanded {
                    RoundedBarButton(systemName: "location.fill", label: "滚动到已选", size: 28) {
                        scrollToSelectedInList(group)
                    }
                    let testing = proxyStore.testingGroups.contains(group.name)
                    Button {
                        Task { await proxyStore.testLatency(group: group) }
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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { collapsedGroups.insert(group.name) }
                else { collapsedGroups.remove(group.name) }
            }
            if expanded {
                LazyVGrid(columns: gridColumns(width: width), spacing: 8) {
                    ForEach(group.nodes) { node in
                        nodeCard(node, in: group)
                            .id(scrollID(nodeName: node.name, groupName: group.name))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
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
                        .font(.system(size: 15))
                        .fontWeight(.semibold)
                }
            } else {
                Text(text)
                    .font(.system(size: 15))
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
        let pinned = group.fixed == node.name
        let selected = group.selectedNodeName == node.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                Text(node.name)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .lineLimit(styleStore.cardType == .compact ? 1 : 2)
                Spacer()
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? ConcordTheme.accent : .secondary)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.blue)
                }
            }
            if styleStore.cardType == .loose {
                Text(nodeDescription(node))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button { Task { await proxyStore.testLatency(node: node) } } label: {
                    LatencyChip(latencyMs: node.latencyMs)
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Text(node.type)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { Task { await proxyStore.testLatency(node: node) } } label: {
                        LatencyChip(latencyMs: node.latencyMs)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cardHeight, alignment: .top)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .shadow(color: ConcordTheme.cardShadow, radius: 8, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .onTapGesture { Task { await selectNode(node, in: group) } }
        .contextMenu { nodeMenu(node, in: group) }
    }

    private func nodeMenu(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        Group {
            let pinned = group.fixed == node.name
            let selected = group.selectedNodeName == node.name
            if group.type == "select" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    Label("选择", systemImage: selected ? "checkmark" : "circle")
                }
            } else if group.type == "url-test" || group.type == "fallback" {
                Button { Task { await selectNode(node, in: group) } } label: {
                    Label(pinned ? "取消首选" : "设为首选", systemImage: pinned ? "pin.fill" : "pin")
                }
            }
            if isAddable(node) {
                Button { Task { await addToLocal(node: node) } } label: {
                    Label("添加到本地节点", systemImage: "plus.square.on.square")
                }
            }
            Button { Task { await proxyStore.testLatency(node: node) } } label: {
                Label("测速", systemImage: "bolt")
            }
            Button { detailNode = node } label: {
                Label("节点详情", systemImage: "info.circle")
            }
        }
    }

    private func isAddable(_ node: ProxyNode) -> Bool {
        !Self.groupTypes.contains(node.type) && !Self.reservedNames.contains(node.name)
    }

    // MARK: - Actions

    private func selectNode(_ node: ProxyNode, in group: ProxyGroup) async {
        if let note = await proxyStore.select(node: node, in: group) {
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
        if collapsedGroups.contains(group.name) {
            collapsedGroups.remove(group.name)
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
                        Task { await proxyStore.testLatency(node: node) }
                    }
                }
                if let definition = detail?.definition {
                    Section("配置（proxy.definition）") {
                        JSONValueView(value: definition)
                            .frame(minHeight: 120)
                    }
                } else if let error = detail?.error {
                    Section {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        ProgressView()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("节点详情")
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
