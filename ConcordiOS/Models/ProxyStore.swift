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
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    @Published var groups: [ProxyGroup] = []
    @Published var latencies: [String: Int32] = [:]
    @Published var isTesting = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
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
        do {
            let result = try await client.proxyGroups()
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
                    testUrl: g.testUrl
                )
            }
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func select(node: ProxyNode, in group: ProxyGroup) async {
        do {
            let result = try await client.proxySelect(group: group.name, proxy: node.name)
            if result.changed, let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index].selectedNodeName = node.name
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func testLatency() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        for group in groups {
            for node in group.nodes where node.type != "DIRECT" {
                do {
                    let result = try await client.delayTest(proxy: node.name)
                    latencies[node.name] = result.value
                } catch {
                    latencies[node.name] = -2
                }
            }
        }
        // Re-apply latencies to the visible nodes.
        groups = groups.map { g in
            var g = g
            g.nodes = g.nodes.map { n in
                var n = n
                n.latencyMs = latencies[n.name]
                return n
            }
            return g
        }
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

    // Engine lifecycle. In `.live` mode this calls engine.start/stop and
    // tun.start/stop on the real core; in `.sample` mode it only flips
    // local UI state and the VPN switch in the app must still be wired to
    // NEVPNManager (see PacketTunnelProvider).
    @MainActor
    func toggle() async {
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
