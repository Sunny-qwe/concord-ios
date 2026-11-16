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
        for connection in connections {
            try? await client.connectionClose(id: connection.id)
        }
        connections.removeAll()
    }
}
