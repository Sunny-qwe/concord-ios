import Foundation
import Combine

// MARK: - Placeholder models
// TODO: replace placeholder data with live data from Concord via the
// PacketTunnelProvider / App Group shared state (see ConfigStore).
// The JSON-RPC methods in Concord's schema/api.json include proxy groups,
// connections, traffic and logs — but those are served by the desktop
// child-process / Android .so embedding, not by an iOS in-process staticlib
// yet. The iOS data path is still to be defined.

struct ProxyNode: Identifiable {
    let id = UUID()
    let name: String
    let type: String // e.g. "VLESS", "Trojan", "Shadowsocks"
    let latencyMs: Int? // nil = not tested
}

struct ProxyGroup: Identifiable {
    let id = UUID()
    let name: String
    let type: String // e.g. "select", "url-test", "fallback"
    var nodes: [ProxyNode]
    var selectedNodeName: String?
}

struct ConnectionInfo: Identifiable {
    let id = UUID()
    let host: String
    let rule: String
    let proxy: String
    let uploadBytes: Int64
    let downloadBytes: Int64
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    @Published var groups: [ProxyGroup] = [
        ProxyGroup(
            name: "PROXY",
            type: "select",
            nodes: [
                ProxyNode(name: "示例节点-1", type: "VLESS", latencyMs: nil),
                ProxyNode(name: "示例节点-2", type: "Trojan", latencyMs: nil),
            ],
            selectedNodeName: "示例节点-1"
        ),
        ProxyGroup(
            name: "DIRECT",
            type: "select",
            nodes: [ProxyNode(name: "直连", type: "DIRECT", latencyMs: nil)],
            selectedNodeName: "直连"
        ),
    ]
    @Published var connections: [ConnectionInfo] = []
    @Published var uploadBytes: Int64 = 0
    @Published var downloadBytes: Int64 = 0
    @Published var logs: [String] = [
        "TODO: 日志尚未接通 Concord。先在真机上验证 Packet Tunnel 能启动。"
    ]

    // TODO: start/stop the VPN via NEVPNManager, not by flipping a Bool.
    // This only flips local UI state for the scaffold.
    func toggle() {
        isRunning.toggle()
        // TODO: save VPN config via NEVPNManager, load tunnel provider,
        // and start/stop the PacketTunnel extension. Requires a valid
        // provisioning profile with packet-tunnel-provider (see README).
    }

    func select(node: ProxyNode, in group: ProxyGroup) {
        // TODO: call Concord proxy group select (JSON-RPC proxy.groups/select
        // equivalent) once the iOS staticlib API exists.
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].selectedNodeName = node.name
    }

    func testLatency() {
        // TODO: trigger URL-test / latency test via Concord.
    }
}
