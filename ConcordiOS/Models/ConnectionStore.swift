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
    /// Upstream detail fields (tracker_info_item.dart Overview): the
    /// core decodes them into ConcordConnection (A5) but the store
    /// never carried them through, so the detail page could not show
    /// them. All optional — older cores / sample data omit them.
    let destinationIp: String?
    let destinationPort: Int
    let sourceIp: String
    let sourcePort: Int
    let inboundIp: String?
    let inboundPort: Int?
    let inboundName: String?
    let inboundUser: String?
    let processPath: String?
    let dnsMode: String?
    let rulePayload: String?
    let rematchName: String?
    let chains: [String]
    let mitm: Bool
    let mitmRefused: Bool
    let remoteDestination: String?
    let sourceGeoIp: [String]
    let destinationGeoIp: [String]
    let sourceAsn: String?
    let destinationAsn: String?
    let specialRules: String?
    let specialProxy: String?
    /// Live up/down rates in bytes/s (upstream tracker_info_table
    /// downloadSpeed/uploadSpeed, ranked by TrackerSpeedRanker):
    /// per-connection byte deltas over the poll interval, computed
    /// in refresh() from consecutive snapshots. 0 for finished
    /// (recent) connections and before the second sample.
    var upSpeed: Double = 0
    var downSpeed: Double = 0

    var durationSeconds: Int64 {
        max(0, Int64(Date().timeIntervalSince(start)))
    }

    init(_ c: ConcordConnection) {
        id = c.connectionId
        // Upstream ConnectionInfo.start is unix MILLIS
        // (crates/api/src/convert.rs: `start: unix_millis(...)`) —
        // dividing by 1000; the old code read millis as seconds and
        // put every connection ~56000 years in the future.
        start = Date(timeIntervalSince1970: TimeInterval(c.start) / 1000)
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
        destinationIp = c.destinationIp
        destinationPort = c.destinationPort
        sourceIp = c.sourceIp
        sourcePort = c.sourcePort
        inboundIp = c.inboundIp
        inboundPort = c.inboundPort
        inboundName = c.inboundName
        inboundUser = c.inboundUser
        processPath = c.processPath
        dnsMode = c.dnsMode
        rulePayload = c.rulePayload
        rematchName = c.rematchName
        chains = c.chains ?? []
        mitm = c.mitm ?? false
        mitmRefused = c.mitmRefused ?? false
        remoteDestination = c.remoteDestination
        sourceGeoIp = c.sourceGeoIp ?? []
        destinationGeoIp = c.destinationGeoIp ?? []
        sourceAsn = c.sourceAsn
        destinationAsn = c.destinationAsn
        specialRules = c.specialRules
        specialProxy = c.specialProxy
    }

    /// Full creation time for the detail page (upstream
    /// tracker_info_item.dart shows start.showFull, not just HH:mm:ss).
    var startFullText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: start)
    }
}

enum ConnectionSort: String, CaseIterable, Identifiable {
    case newest = "最新"
    case host = "域名"
    case download = "下行"
    case upload = "上行"
    /// Upstream every table column is sortable
    /// (tracker_info_table.dart sortKey on each RecordColumn):
    /// rule (rule + payload), exit (first chain), duration (oldest
    /// start first = longest running), live up/down speeds, process.
    case rule = "规则"
    case exit = "出口"
    case duration = "持续"
    case downSpeed = "下行速度"
    case upSpeed = "上行速度"
    case process = "进程"

    var id: String { rawValue }
}

/// Record grouping (upstream trackerInfoGroupers, persisted per page
/// in appSetting.recordGroupings): group the list by process, host,
/// rule or exit chain instead of one flat list.
enum ConnectionGroupBy: String, CaseIterable, Identifiable {
    case none = "不分组"
    case process = "进程"
    case host = "域名"
    case rule = "规则"
    case exit = "出口"

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
    /// First-load state (upstream requests.dart _loaded): false until
    /// the first snapshot read has landed, so the page can show a
    /// loading indicator instead of the empty state.
    @Published var loaded = false
    /// Record-filter facets (upstream trackerInfoFacets: network,
    /// rule, MITM, app/process, proxy chains). Session-only: one
    /// selected value per facet, nil = unfiltered.
    @Published var facetNetwork: String?
    @Published var facetRule: String?
    @Published var facetProxy: String?
    @Published var facetProcess: String?
    @Published var facetMitmOnly = false
    /// Record grouping (upstream trackerInfoGroupers), persisted.
    @Published var groupBy: ConnectionGroupBy = ConnectionGroupBy(rawValue: UserDefaults.standard.string(forKey: Self.groupByKey) ?? "") ?? .none {
        didSet { UserDefaults.standard.set(groupBy.rawValue, forKey: Self.groupByKey) }
    }

    private static let groupByKey = "ConcordiOS.connections.groupBy.v1"
    /// Last-seen byte counts behind the per-connection live speeds
    /// (same differencing idea as TrafficStore.refreshNodeSpeeds,
    /// but per connection id instead of per chain name).
    private var previousBytes: [UInt64: (upload: Int64, download: Int64, at: Date)] = [:]

    /// Facet value lists offered by the current data (live + recent).
    var facetNetworks: [String] {
        Array(Set((connections + recentConnections).map { $0.network.lowercased() })).sorted()
    }
    var facetRules: [String] {
        Array(Set((connections + recentConnections).compactMap(\.rule))).sorted()
    }
    var facetProxies: [String] {
        Array(Set((connections + recentConnections).flatMap { $0.chains.isEmpty ? [$0.proxy].compactMap { $0 } : $0.chains })).sorted()
    }
    var facetProcesses: [String] {
        Array(Set((connections + recentConnections).compactMap(\.process))).sorted()
    }

    var hasActiveFacets: Bool {
        facetNetwork != nil || facetRule != nil || facetProxy != nil
            || facetProcess != nil || facetMitmOnly
    }

    func clearFacets() {
        facetNetwork = nil
        facetRule = nil
        facetProxy = nil
        facetProcess = nil
        facetMitmOnly = false
    }

    private func matchesFacets(_ connection: LiveConnection) -> Bool {
        if let network = facetNetwork, connection.network.lowercased() != network { return false }
        if let rule = facetRule, connection.rule != rule { return false }
        if let proxy = facetProxy, !connection.chains.contains(proxy) && connection.proxy != proxy { return false }
        if let process = facetProcess, connection.process != process { return false }
        if facetMitmOnly, !connection.mitm { return false }
        return true
    }

    private func matchesSearch(_ connection: LiveConnection) -> Bool {
        guard !searchText.isEmpty else { return true }
        let q = searchText.lowercased()
        return (connection.host?.lowercased().contains(q) ?? false)
            || connection.destination.lowercased().contains(q)
            || (connection.proxy?.lowercased().contains(q) ?? false)
            || (connection.rule?.lowercased().contains(q) ?? false)
    }

    private func sorted(_ list: [LiveConnection]) -> [LiveConnection] {
        var list = list
        switch sort {
        case .newest: list.sort { $0.start > $1.start }
        case .host: list.sort { ($0.host ?? "") < ($1.host ?? "") }
        case .download: list.sort { $0.download > $1.download }
        case .upload: list.sort { $0.upload > $1.upload }
        case .rule: list.sort { "\($0.rule ?? "") \($0.rulePayload ?? "")" < "\($1.rule ?? "") \($1.rulePayload ?? "")" }
        case .exit: list.sort { ($0.chains.first ?? $0.proxy ?? "") < ($1.chains.first ?? $1.proxy ?? "") }
        case .duration: list.sort { $0.start < $1.start }
        case .downSpeed: list.sort { $0.downSpeed > $1.downSpeed }
        case .upSpeed: list.sort { $0.upSpeed > $1.upSpeed }
        case .process: list.sort { ($0.process ?? "") < ($1.process ?? "") }
        }
        return list
    }

    /// Recently finished connections (FlClash: 请求 -> 最近请求).
    /// Concord has no connection history — its events carry no
    /// connection records — so the app builds this feed itself by
    /// diffing live snapshots: a connection that was present in the
    /// previous poll and is gone now is recorded here with its final
    /// counters. Kept in memory for the session, capped at 200, so
    /// the list never grows without bound.
    @Published var recentConnections: [LiveConnection] = []

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var filtered: [LiveConnection] {
        sorted(connections.filter { matchesSearch($0) && matchesFacets($0) })
    }

    /// Recent connections matching the search text, facets and sort
    /// (the view used to filter these itself with search only).
    var recentFiltered: [LiveConnection] {
        sorted(recentConnections.filter { matchesSearch($0) && matchesFacets($0) })
    }

    /// Group key for one connection under the active grouping
    /// (upstream trackerInfoGroupers: app/process, host, rule, exit).
    func groupKey(for connection: LiveConnection, by groupBy: ConnectionGroupBy) -> String {
        switch groupBy {
        case .none: return ""
        case .process: return connection.process ?? "未知进程"
        case .host: return connection.host ?? connection.destination
        case .rule: return connection.rule.map { rule in
            connection.rulePayload.map { "\(rule) (\($0))" } ?? rule
        } ?? "无规则"
        case .exit: return connection.chains.first ?? connection.proxy ?? "直连"
        }
    }

    /// A flat list grouped into (key, rows) sections, keys sorted,
    /// rows in the active sort order.
    func grouped(_ list: [LiveConnection], by groupBy: ConnectionGroupBy) -> [(key: String, rows: [LiveConnection])] {
        guard groupBy != .none else { return [("", list)] }
        let groups = Dictionary(grouping: list) { groupKey(for: $0, by: groupBy) }
        return groups.keys.sorted().map { key in (key, groups[key] ?? []) }
    }

    var totalUpload: Int64 { connections.reduce(0) { $0 + $1.upload } }
    var totalDownload: Int64 { connections.reduce(0) { $0 + $1.download } }

    @MainActor
    func refresh() async {
        defer { loaded = true }
        do {
            let snapshot = try await client.connectionSnapshot()
            let now = Date()
            var next = snapshot.connections.map(LiveConnection.init)
            // Live per-connection speeds (upstream downloadSpeed /
            // uploadSpeed): byte deltas since the previous poll over
            // the elapsed seconds. A connection first seen here is
            // only a baseline — its bytes so far would otherwise read
            // as one second's spike (same rule as
            // TrafficStore.refreshNodeSpeeds).
            for index in next.indices {
                let id = next[index].id
                if let previous = previousBytes[id] {
                    let elapsed = now.timeIntervalSince(previous.at)
                    if elapsed > 0 {
                        let upDelta = next[index].upload - previous.upload
                        let downDelta = next[index].download - previous.download
                        next[index].upSpeed = upDelta > 0 ? Double(upDelta) / elapsed : 0
                        next[index].downSpeed = downDelta > 0 ? Double(downDelta) / elapsed : 0
                    }
                }
                previousBytes[id] = (next[index].upload, next[index].download, now)
            }
            let liveIds = Set(next.map(\.id))
            previousBytes = previousBytes.filter { liveIds.contains($0.key) }
            // Record what finished since the last poll: ids that were
            // live and are gone now. (A connection the user closed by
            // hand is recorded too — it did finish.)
            let nextIds = liveIds
            let finished = connections.filter { !nextIds.contains($0.id) }
            if !finished.isEmpty {
                recentConnections = (finished + recentConnections)
                    .sorted { $0.start > $1.start }
                if recentConnections.count > 200 {
                    recentConnections = Array(recentConnections.prefix(200))
                }
            }
            connections = next
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Clear the recorded history.
    func clearRecent() {
        recentConnections.removeAll()
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
