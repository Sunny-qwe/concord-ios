import Foundation
import Combine

// MARK: - Proxy store (FlClash: Proxies page)
// Backed by Concord proxy.groups / proxy.select / delay.test.
// In `.sample` mode the groups come from ConcordSampleData via
// ConcordClient; in `.live` mode they come from the real core.

struct ProxyNode: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let provider: String?
    var latencyMs: Int32?
}

struct ProxyGroup: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    var nodes: [ProxyNode]
    var selectedNodeName: String?
    var testUrl: String
    /// Manual override for url-test / fallback groups (Clash
    /// `fixed`): the node pinned as 首选； nil/"" = the pick is
    /// computed by the group itself.
    var fixed: String?
    /// Group icon from the profile (URL or short text); "" = none,
    /// the list header falls back to the name's first character.
    var icon: String
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    @Published var groups: [ProxyGroup] = []
    @Published var latencies: [String: Int32] = [:]
    /// Group names with a delay test in flight (per-group spinners).
    @Published var testingGroups: Set<String> = []
    /// True while any delay test runs.
    var isTesting: Bool { !testingGroups.isEmpty }
    /// True while the group list itself is loading (first load).
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    let client: ConcordClient
    private var cancellables = Set<AnyCancellable>()

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        // In live mode the running state follows the system VPN, so a
        // disconnect from outside the app (e.g. iOS Settings) is
        // reflected here too.
        TunnelManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.client.mode == .live else { return }
                self.isRunning = status == .connected || status == .connecting || status == .reasserting
            }
            .store(in: &cancellables)
    }

    var selectedOutbound: String? {
        groups.first { $0.name == "GLOBAL" }?.selectedNodeName
            ?? groups.first?.selectedNodeName
    }

    var allNodes: [ProxyNode] {
        groups.flatMap { $0.nodes }
    }

    @MainActor
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // proxy.watch is the live table: the extension subscribes
            // once at startup and rewrites snapshots/proxies.json on
            // every change, so this is fresher than a one-shot
            // proxy.groups call. Fall back to proxy.groups when the
            // snapshot file is missing (tunnel never subscribed yet).
            let result: ConcordProxyGroups
            do {
                result = try await client.proxyWatchSnapshot()
            } catch {
                result = try await client.proxyGroups()
            }
            let nodeTypes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.name, $0) })
            groups = result.groups.filter { !$0.hidden }.map { g in
                ProxyGroup(
                    name: g.name,
                    type: g.type,
                    nodes: (g.all ?? []).map { name in
                        let info = nodeTypes[name]
                        return ProxyNode(name: name, type: info?.type ?? "unknown", provider: info?.provider, latencyMs: latencies[name])
                    },
                    selectedNodeName: g.now,
                    testUrl: g.testUrl,
                    fixed: g.fixed,
                    icon: g.icon
                )
            }
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Select a node (FlClash card.dart selectGroupProxy). Returns a
    /// notice when the group cannot be chosen by hand, else nil.
    /// - Selector: tap selects the node.
    /// - url-test / fallback: tap pins the node as 首选； tapping the
    ///   pinned node again clears the pin (proxy.select with "").
    /// - load-balance / relay / other: not selectable by hand.
    /// A successful change reloads the groups so `now` and `fixed`
    /// show what the core actually picked.
    @MainActor
    func select(node: ProxyNode, in group: ProxyGroup) async -> String? {
        switch group.type {
        case "select":
            return await applySelect(group: group, proxy: node.name)
        case "url-test", "fallback":
            let pinned = group.fixed == node.name
            return await applySelect(group: group, proxy: pinned ? "" : node.name)
        default:
            return "该策略组（\(group.type)）不可手动选择"
        }
    }

    @MainActor
    private func applySelect(group: ProxyGroup, proxy: String) async -> String? {
        do {
            let result = try await client.proxySelect(group: group.name, proxy: proxy)
            if result.changed { await refresh() }
            lastError = nil
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Batch latency test for every node. In live mode this uses
    /// delay.run: one stream tests all nodes at once and the extension
    /// accumulates the results into snapshots/delay.json, which is
    /// polled here until the run reports `done` (up to ~60 s). If the
    /// run cannot start, or the poll never completes, it falls back to
    /// sequential delay.test calls — the same results, just slower.
    @MainActor
    func testLatency() async {
        var nodes: [(name: String, url: String?)] = []
        for group in groups {
            for node in group.nodes where node.type != "DIRECT" {
                nodes.append((name: node.name, url: group.testUrl.isEmpty ? nil : group.testUrl))
            }
        }
        await runLatencyTest(nodes: nodes, groupNames: Set(groups.map { $0.name }), batchURL: nil)
    }

    /// Batch latency test for one group only (the bolt on a group
    /// header, or the top bolt in tab style, which tests the current
    /// group). Same batch/sequential logic as the all-groups test.
    @MainActor
    func testLatency(group: ProxyGroup) async {
        await runLatencyTest(nodes: group.nodes.filter { $0.type != "DIRECT" }.map { (name: $0.name, url: group.testUrl) }, groupNames: [group.name], batchURL: group.testUrl.isEmpty ? nil : group.testUrl)
    }

    @MainActor
    private func runLatencyTest(nodes: [(name: String, url: String?)], groupNames: Set<String>, batchURL: String?) async {
        guard !nodes.isEmpty, testingGroups.isDisjoint(with: groupNames) else { return }
        testingGroups.formUnion(groupNames)
        defer { testingGroups.subtract(groupNames) }
        if client.mode == .live {
            let names = nodes.map { $0.name }
            do {
                _ = try await client.delayRunStart(proxies: names, url: batchURL)
                var polls = 0
                while polls < 120, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    polls += 1
                    do {
                        let snapshot = try await client.delayRunPoll()
                        for result in snapshot.results {
                            latencies[result.name] = result.value
                        }
                        applyLatencies()
                        if snapshot.done {
                            lastError = nil
                            return
                        }
                    } catch is TunnelError {
                        // The extension has not written the run file
                        // yet — keep polling, do not fail.
                        continue
                    }
                }
                // The run is still going (or its file never appeared):
                // keep the partial results and let the next test
                // start a fresh run.
                lastError = nil
                return
            } catch {
                // delay.run failed to start — fall through to the
                // sequential delay.test loop below.
            }
        }
        for node in nodes {
            do {
                let result = try await client.delayTest(proxy: node.name, url: node.url)
                latencies[node.name] = result.value
            } catch {
                latencies[node.name] = -2
            }
        }
        applyLatencies()
        lastError = nil
    }

    @MainActor
    func testLatency(node: ProxyNode) async {
        do {
            let result = try await client.delayTest(proxy: node.name)
            latencies[node.name] = result.value
            applyLatencies()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyLatencies() {
        groups = groups.map { g in
            var g = g
            g.nodes = g.nodes.map { n in
                var n = n
                n.latencyMs = latencies[n.name]
                return n
            }
            return g
        }
    }

    /// Full node detail for the detail sheet: the configured definition
    /// (proxy.definition, open JSON) and the live state (proxy.states:
    /// alive / UDP / delay history). Either may be absent — the sheet
    /// shows what it got and says what it did not.
    struct NodeDetail {
        var definition: JSONValue?
        var state: ConcordProxyState?
        var error: String?
    }

    @MainActor
    func fetchNodeDetail(name: String) async -> NodeDetail {
        var detail = NodeDetail()
        do {
            detail.definition = try await client.proxyDefinition(name: name)
        } catch {
            detail.error = "读取节点配置失败：\(error.localizedDescription)"
        }
        do {
            detail.state = try await client.proxyStates(names: [name]).first
        } catch {
            if detail.error == nil {
                detail.error = "读取节点状态失败：\(error.localizedDescription)"
            }
        }
        return detail
    }

    // Engine lifecycle.
    //
    // `.live`: the Dashboard start/stop button drives the SYSTEM VPN
    // (TunnelManager -> NETunnelProviderManager). The extension's
    // startTunnel boots the core (engine.start + tun.start) and its
    // stopTunnel tears it down; isRunning follows the tunnel status.
    // `.sample`: only flips local UI state, as before.
    @MainActor
    func toggle() async {
        if client.mode == .live {
            if TunnelManager.shared.isRunning {
                await TunnelManager.shared.stop()
                isRunning = false
            } else {
                do {
                    try await TunnelManager.shared.start()
                    isRunning = true
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                }
            }
            return
        }
        if isRunning {
            do {
                try await client.tunStop()
                try await client.engineStop()
            } catch {
                lastError = error.localizedDescription
            }
            isRunning = false
        } else {
            do {
                try await client.engineStart()
                isRunning = true
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
