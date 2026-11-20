import SwiftUI

// MARK: - Node sources (FlClash: lib/views/profiles/node_sources.dart)
// For every node, which subscription / provider it came from.
// Provenance is derived from the profile files themselves
// (ProfileStore.localProxyGroups, a line scan of each profile's
// `proxies:` / `proxy-providers:` sections — no core needed, so
// it works with the tunnel stopped; provider nodes resolve from
// their files / the core's cached copies, and show their type +
// provider offline). "从核心读取" still enriches with the core's
// convert.subscription output when the tunnel is running.
// Local custom nodes come from CustomProxyStore.

struct NodeSourcesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customProxyStore = CustomProxyStore()
    @State private var query = ""
    @State private var sections: [NodeSourceSection] = []
    @State private var isLoadingCore = false
    @State private var coreMessage: String?

    struct NodeEntry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        var type: String
        /// Proxy-provider the node came from, when it did not come
        /// from the profile's own `proxies:` section (resolved
        /// offline from the provider's file / cached copy).
        var provider: String?

        init(name: String, type: String, provider: String? = nil) {
            self.name = name
            self.type = type
            self.provider = provider
        }
    }

    struct NodeSourceSection: Identifiable {
        var id: UUID { profileID }
        let profileID: UUID
        let profileName: String
        let kindLabel: String
        var nodes: [NodeEntry]
    }

    private var filteredSections: [NodeSourceSection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return sections }
        let needle = query.lowercased()
        return sections.compactMap { section in
            let nodes = section.nodes.filter {
                $0.name.lowercased().contains(needle) || $0.type.lowercased().contains(needle)
            }
            guard !nodes.isEmpty else { return nil }
            return NodeSourceSection(
                profileID: section.profileID,
                profileName: section.profileName,
                kindLabel: section.kindLabel,
                nodes: nodes
            )
        }
    }

    var body: some View {
        List {
            Section {
                Text("每个节点来自哪个订阅：名字取自各订阅文件的 proxies: 段；点「从核心读取」可补上类型和提供方拉取的节点（需启动 VPN）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await enrichFromCore() }
                } label: {
                    Label(isLoadingCore ? "正在从核心读取…" : "从核心读取节点（含提供方）", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingCore)
                if let coreMessage {
                    Text(coreMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sections.isEmpty {
                ContentUnavailableView("暂无节点来源", systemImage: "list.clipboard", description: Text("先导入一个订阅，或在「代理」里添加自定义节点"))
            }
            ForEach(filteredSections) { section in
                Section("\(section.profileName) · \(section.kindLabel)（\(section.nodes.count) 个）") {
                    ForEach(section.nodes) { node in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).font(.system(size: 13))
                                if !node.type.isEmpty || node.provider != nil {
                                    Text(nodeDetail(node))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("节点来源")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索节点名或类型")
        .task {
            rebuildFromLocalFiles()
        }
    }

    /// "type · 提供方：name" (either part alone when the other is
    /// missing — a provider node with no cached file has no type
    /// offline, a literal node has no provider).
    private func nodeDetail(_ node: NodeEntry) -> String {
        var parts: [String] = []
        if !node.type.isEmpty { parts.append(node.type) }
        if let provider = node.provider, !provider.isEmpty {
            parts.append("提供方：\(provider)")
        }
        return parts.joined(separator: " · ")
    }

    /// Local provenance only: every profile's own `proxies:` names
    /// plus the locally added custom nodes. Types and providers
    /// come from the same offline parse (proxy-provider nodes are
    /// resolved from their files / the core's cached copies).
    private func rebuildFromLocalFiles() {
        var built: [NodeSourceSection] = profileStore.profiles.map { profile in
            let nodes: [NodeEntry]
            if let parsed = profileStore.localProxyGroups(for: profile) {
                nodes = parsed.nodes.map {
                    NodeEntry(name: $0.name, type: $0.type == "unknown" ? "" : $0.type, provider: $0.provider)
                }
            } else {
                nodes = profileStore.localNodeNames(for: profile).map {
                    NodeEntry(name: $0, type: "")
                }
            }
            return NodeSourceSection(
                profileID: profile.id,
                profileName: profile.name,
                kindLabel: profile.kind.rawValue,
                nodes: nodes
            )
        }
        let customNames = customProxyStore.proxies.map { NodeEntry(name: $0.name, type: $0.type) }
            + customProxyStore.rawProxies.compactMap { value -> NodeEntry? in
                guard let name = value.objectValue?["name"]?.stringValue else { return nil }
                return NodeEntry(name: name, type: value.objectValue?["type"]?.stringValue ?? "")
            }
        if !customNames.isEmpty {
            built.append(NodeSourceSection(
                profileID: UUID(),
                profileName: "自定义节点",
                kindLabel: "本地添加",
                nodes: customNames
            ))
        }
        sections = built.filter { !$0.nodes.isEmpty }
    }

    /// Merge the core's convert.subscription output: adds the node
    /// type and any provider-fetched nodes the local scan cannot
    /// see. Runs only when the core is reachable.
    private func enrichFromCore() async {
        isLoadingCore = true
        defer { isLoadingCore = false }
        var enriched = sections
        var resolved = 0
        for profile in profileStore.profiles {
            switch await profileStore.convertProfile(profile) {
            case .success(let proxies):
                guard !proxies.isEmpty else { continue }
                resolved += 1
                let coreNodes = proxies.compactMap { value -> NodeEntry? in
                    guard let name = value.objectValue?["name"]?.stringValue else { return nil }
                    return NodeEntry(name: name, type: value.objectValue?["type"]?.stringValue ?? "")
                }
                if let index = enriched.firstIndex(where: { $0.profileID == profile.id }) {
                    var merged = enriched[index].nodes
                    for node in coreNodes {
                        if let existing = merged.firstIndex(where: { $0.name == node.name }) {
                            if merged[existing].type.isEmpty { merged[existing].type = node.type }
                        } else {
                            merged.append(node)
                        }
                    }
                    enriched[index].nodes = merged.sorted { $0.name < $1.name }
                } else {
                    enriched.append(NodeSourceSection(
                        profileID: profile.id,
                        profileName: profile.name,
                        kindLabel: profile.kind.rawValue,
                        nodes: coreNodes.sorted { $0.name < $1.name }
                    ))
                }
            case .failure:
                continue
            }
        }
        sections = enriched
        coreMessage = resolved == 0
            ? "核心不可用（需先启动 VPN），当前只显示本地文件里的节点"
            : "已从核心补齐 \(resolved) 个订阅的节点类型与提供方节点"
    }
}
