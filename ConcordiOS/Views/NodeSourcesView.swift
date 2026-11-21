import SwiftUI

// MARK: - Node sources (FlClash: lib/views/profiles/node_sources.dart)
// For every node, which subscription / provider it came from.
// Provenance is derived from the profile files themselves
// (ProfileStore.localProxyGroups, a line scan of each profile's
// `proxies:` / `proxy-providers:` sections — no core needed, so
// it works with the tunnel stopped; provider nodes resolve from
// their files / the core's cached copies, and show their type +
// provider offline).
// Local custom nodes come from CustomProxyStore.

struct NodeSourcesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customProxyStore = CustomProxyStore()
    @State private var sections: [NodeSourceSection] = []

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

    var body: some View {
        List {
            if sections.isEmpty {
                ContentUnavailableView("暂无节点来源", systemImage: "list.clipboard", description: Text("先导入一个订阅，或在「代理」里添加自定义节点"))
            }
            ForEach(sections) { section in
                Section("\(section.profileName) · \(section.kindLabel)（\(section.nodes.count) 个）") {
                    ForEach(section.nodes) { node in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).font(.footnote)
                                if !node.type.isEmpty || node.provider != nil {
                                    Text(nodeDetail(node))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .navigationTitle("节点来源")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Every profile YAML is scanned synchronously by
            // localProxyGroups/localNodeNames; running that in this
            // task's first (main-actor) segment stalled the push
            // transition and the nav title. Snapshot the inputs on
            // the main actor, scan off-thread, assign back on the
            // main actor. The page starts with its empty state and
            // fills in when the scan lands.
            let profiles = profileStore.profiles
            let customs = customProxyStore.proxies
            let raws = customProxyStore.rawProxies
            let storeRef = profileStore
            sections = await Task.detached(priority: .userInitiated) {
                Self.buildSections(profiles: profiles, customProxies: customs, rawProxies: raws, store: storeRef)
            }.value
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
    /// Pure file work (no @Published state touched), so it runs in
    /// a detached task — see the .task above.
    private static func buildSections(profiles: [Profile], customProxies: [CustomProxy], rawProxies: [JSONValue], store: ProfileStore) -> [NodeSourceSection] {
        var built: [NodeSourceSection] = profiles.map { profile in
            let nodes: [NodeEntry]
            if let parsed = store.localProxyGroups(for: profile) {
                nodes = parsed.nodes.map {
                    NodeEntry(name: $0.name, type: $0.type == "unknown" ? "" : $0.type, provider: $0.provider)
                }
            } else {
                nodes = store.localNodeNames(for: profile).map {
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
        let customNames = customProxies.map { NodeEntry(name: $0.name, type: $0.type) }
            + rawProxies.compactMap { value -> NodeEntry? in
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
        return built.filter { !$0.nodes.isEmpty }
    }
}
