import SwiftUI

// MARK: - Proxies (FlClash: ProxiesView, lib/views/proxies/)
// FlClash proxies page: group tabs, search, delay test (URL test),
// sort (default / delay / name), list/grid layout, card size and
// icon style, tap a node to select it (proxy.select), long-press for
// the node detail. This page reproduces the same controls in SwiftUI.

enum ProxySort: String, CaseIterable, Identifiable {
    case `default` = "默认"
    case delay = "延迟"
    case name = "名称"
    var id: String { rawValue }
}

struct ProxiesView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var client: ConcordClient
    @State private var searchText = ""
    @State private var selectedGroupName: String?
    @State private var sort: ProxySort = .default
    @State private var useGrid = false
    @State private var detailNode: ProxyNode?

    private var selectedGroup: ProxyGroup? {
        if let name = selectedGroupName {
            return proxyStore.groups.first { $0.name == name }
        }
        return proxyStore.groups.first
    }

    private var filteredNodes: [ProxyNode] {
        guard let group = selectedGroup else { return [] }
        var nodes = group.nodes
        if !searchText.isEmpty {
            nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText) }
        }
        switch sort {
        case .default: break
        case .delay: nodes.sort { ($0.latencyMs ?? Int32.max) < ($1.latencyMs ?? Int32.max) }
        case .name: nodes.sort { $0.name < $1.name }
        }
        return nodes
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("节点与延迟为示例数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                // Group tabs (FlClash ProxiesTabView)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(proxyStore.groups) { group in
                            Button(group.name) {
                                selectedGroupName = group.name
                            }
                            .fontWeight(.semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedGroup?.id == group.id ? ConcordTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(selectedGroup?.id == group.id ? .white : Color(.label))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)

                if let group = selectedGroup {
                    Text("\(group.type) · \(group.nodes.count) 个节点 · 当前：\(group.selectedNodeName ?? "未选择")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)

                    if useGrid {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(filteredNodes) { node in
                                    nodeCard(node, in: group)
                                }
                            }
                            .padding()
                        }
                    } else {
                        List(filteredNodes) { node in
                            nodeRow(node, in: group)
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                } else {
                    ContentUnavailableView("暂无代理组", systemImage: "globe", description: Text("请先在“订阅”页导入并激活一个订阅"))
                }
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle("代理")
            .searchable(text: $searchText, prompt: "搜索节点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sort) {
                            ForEach(ProxySort.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Button(useGrid ? "切换为列表" : "切换为网格") { useGrid.toggle() }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await proxyStore.testLatency() }
                    } label: {
                        Image(systemName: "bolt")
                    }
                    .disabled(proxyStore.isTesting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await proxyStore.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $detailNode) { node in
                NodeDetailView(node: node)
            }
            .refreshable { await proxyStore.refresh() }
            .task { if proxyStore.groups.isEmpty { await proxyStore.refresh() } }
        }
    }

    private func nodeRow(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.body)
                Text("\(node.type)\(node.provider.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LatencyChip(latencyMs: node.latencyMs)
            if group.selectedNodeName == node.name {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await proxyStore.select(node: node, in: group) }
        }
        .onLongPressGesture { detailNode = node }
        .swipeActions {
            Button("测速") { Task { await proxyStore.testLatency(node: node) } }
                .tint(.blue)
        }
    }

    private func nodeCard(_ node: ProxyNode, in group: ProxyGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(node.name).font(.subheadline).fontWeight(.semibold).lineLimit(2)
                Spacer()
                if group.selectedNodeName == node.name {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                }
            }
            Text(node.type).font(.caption).foregroundStyle(.secondary)
            LatencyChip(latencyMs: node.latencyMs)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .shadow(color: ConcordTheme.cardShadow, radius: 8, x: 0, y: 2)
        .onTapGesture {
            Task { await proxyStore.select(node: node, in: group) }
        }
        .onLongPressGesture { detailNode = node }
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
                        Text(error).font(.caption).foregroundStyle(.orange)
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
