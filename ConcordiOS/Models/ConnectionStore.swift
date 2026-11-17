import Foundation
import Combine

// MARK: - Connections store (FlClash: Requests / connections page)
// Backed by Concord connection.watch (stream) / connection.close.
// FlClash calls this page "Requests"; the list is the live connection
// table with host, rule, proxy, up/down and duration.

struct LiveConnection: Identifiable {
    let id: UInt64
    let start: Date
    let network: String
    let source: String
    let destination: String
    let host: String?
    let rule: String?
    let proxy: String?
    let inboundType: String
    let process: String?
    let upload: Int64
    let download: Int64

    var durationSeconds: Int64 {
        max(0, Int64(Date().timeIntervalSince(start)))
    }

    init(_ c: ConcordConnection) {
        id = c.connectionId
        start = Date(timeIntervalSince1970: TimeInterval(c.start))
        network = c.network
        source = "\(c.sourceIp):\(c.sourcePort)"
        destination = c.destinationIp.map { "\($0):\(c.destinationPort)" } ?? ":\(c.destinationPort)"
        host = c.host ?? c.sniffHost
        rule = c.rule
        proxy = c.proxy
        inboundType = c.inboundType
        process = c.process
        upload = c.upload ?? 0
        download = c.download ?? 0
    }
}

enum ConnectionSort: String, CaseIterable, Identifiable {
    case newest = "最新"
    case host = "域名"
    case download = "下行"
    case upload = "上行"

    var id: String { rawValue }
}

final class ConnectionStore: ObservableObject {
    @Published var connections: [LiveConnection] = []
    @Published var searchText = ""
    @Published var sort: ConnectionSort = .newest
    @Published var showOnlyActive = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    /// The result message of the last network.update call.
    @Published var networkUpdateMessage: String?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var filtered: [LiveConnection] {
        var list = connections
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                ($0.host?.lowercased().contains(q) ?? false)
                    || $0.destination.lowercased().contains(q)
                    || ($0.proxy?.lowercased().contains(q) ?? false)
                    || ($0.rule?.lowercased().contains(q) ?? false)
            }
        }
        switch sort {
        case .newest: list.sort { $0.start > $1.start }
        case .host: list.sort { ($0.host ?? "") < ($1.host ?? "") }
        case .download: list.sort { $0.download > $1.download }
        case .upload: list.sort { $0.upload > $1.upload }
        }
        return list
    }

    var totalUpload: Int64 { connections.reduce(0) { $0 + $1.upload } }
    var totalDownload: Int64 { connections.reduce(0) { $0 + $1.download } }

    @MainActor
    func refresh() async {
        do {
            let snapshot = try await client.connectionSnapshot()
            connections = snapshot.connections.map(LiveConnection.init)
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func close(_ connection: LiveConnection) async {
        do {
            try await client.connectionClose(id: connection.id)
            connections.removeAll { $0.id == connection.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func closeAll() async {
        do {
            try await client.connectionCloseAll()
            connections.removeAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Resets the core's resolver connections (network.reset) — the
    /// next DNS lookup re-dials. Useful when connections look stuck
    /// after a network change.
    @MainActor
    func resetNetwork() async {
        do {
            try await client.networkReset()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tells the core the system network changed (network.update).
    /// Reads the current system DNS servers from /etc/resolv.conf
    /// and sends them as `dnsServers`; `interfaceChanged` means the
    /// default network changed, so connections over the old one are
    /// closed. The extension does not yet notify the core
    /// automatically on network change — this is the manual trigger.
    @MainActor
    func networkUpdate(interfaceChanged: Bool = false) async {
        do {
            try await client.networkUpdate(dnsServers: Self.systemDnsServers(), interfaceChanged: interfaceChanged)
            networkUpdateMessage = interfaceChanged
                ? "已通知核心：网络接口已切换，旧连接已关闭"
                : "已通知核心：DNS 服务器已更新"
            lastError = nil
        } catch {
            networkUpdateMessage = nil
            lastError = error.localizedDescription
        }
    }

    /// The DNS servers iOS currently uses, read from /etc/resolv.conf
    /// (SCDynamicStore is macOS-only and unavailable on iOS), as socket
    /// addresses. Returns nil when they cannot be read (nil = "unchanged"
    /// to the core — the core still processes the network change).
    static func systemDnsServers() -> [String]? {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return nil
        }
        let servers = text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "nameserver" else { return nil }
            let server = String(parts[1])
            return server.contains(":") ? "[\(server)]:53" : "\(server):53"
        }
        return servers.isEmpty ? nil : servers
    }
}
