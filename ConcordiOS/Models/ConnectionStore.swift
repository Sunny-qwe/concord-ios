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
    /// Upstream 0c9788f (ConnectionInfo): the deciding rule's
    /// position, from 0, in the list `rule.list` gave for the config
    /// the connection was routed by. Nil when no rule decided.
    var ruleIndex: UInt32?
    /// Upstream 0c9788f: why this connection's dial failed (kind +
    /// the error as the core logs it). Only on a failed dial.
    var failureKind: String?
    var failureMessage: String?
    /// Upstream 0c9788f: per-step setup timing, microseconds after
    /// the core accepted the flow.
    var timing: ConcordConnectionTiming?
    /// Upstream 0c9788f: the `id`s of the `dns.watch` entries that
    /// gave out the destination's address. Resolve against
    /// DnsStore entries by their numeric `id`.
    var dnsQueries: [UInt64] = []
    /// Upstream 0c9788f (ConnectionDelta.ended, forwarded by the
    /// extension): why this finished connection ended, when, and
    /// the error text for timeout / reset / error. Set only on
    /// 最近请求 rows; the live feed has none of these.
    var endReason: String?
    var endedAt: Int64?
    var endMessage: String?
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
        ruleIndex = c.ruleIndex
        failureKind = c.failure?.kind
        failureMessage = c.failure?.message
        timing = c.timing
        dnsQueries = c.dnsQueries ?? []
    }

    /// Builds a finished row from an `ended` entry the extension
    /// forwarded (upstream 0c9788f): the ConnectionInfo carries the
    /// core's FINAL totals, plus why and when it ended. A failed
    /// dial (opened + closed in the same delta, zero traffic) only
    /// ever arrives this way — the live snapshots never hold it.
    init(ended: ConcordEndedConnection) {
        self.init(ended.connection)
        endReason = ended.reason
        endedAt = ended.endedAt
        endMessage = ended.message
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

/// Status filter for the Requests list (upstream ConnectionStatus,
/// connection_filters.dart:8 — all / active / failed).
enum ConnectionStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "活动"
    case failed = "失败"

    var id: String { rawValue }
}

/// One minute's records, in the list's existing order (upstream
/// RecordMinuteList: a header closes each minute's records).
struct ConnectionMinuteGroup {
    let minute: Date
    var rows: [LiveConnection]
}

final class ConnectionStore: ObservableObject {
    @Published var connections: [LiveConnection] = []
    @Published var searchText = ""
    @Published var sort: ConnectionSort = .newest
    /// Status filter (upstream ConditionFilterRow): all / active /
    /// failed. Session-only; filters in addition to search/facets.
    @Published var statusFilter: ConnectionStatusFilter = .all
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
    @Published var groupBy: ConnectionGroupBy = ConnectionGroupBy(rawValue: UserDefaults.standard.string(forKey: ConnectionStore.groupByKey) ?? "") ?? .none {
        didSet { UserDefaults.standard.set(groupBy.rawValue, forKey: ConnectionStore.groupByKey) }
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
        sorted(connections.filter { matchesSearch($0) && matchesFacets($0) && matchesStatus($0, isLive: true) })
    }

    /// Recent connections matching the search text, facets and sort
    /// (the view used to filter these itself with search only).
    var recentFiltered: [LiveConnection] {
        sorted(recentConnections.filter { matchesSearch($0) && matchesFacets($0) && matchesStatus($0, isLive: false) })
    }

    /// Feed-scoped status counts (v0.2.121): the pills used to count
    /// live + recent held rows regardless of the feed being viewed,
    /// so on the recent feed 全部 included live rows that aren't
    /// listed. Pass the viewed feed: on recent, 全部 = recent held,
    /// 活动 = 0 (recent holds only closed rows), 失败 = failed
    /// recent; on live, 全部/活动 = live, 失败 = failed live.
    /// (Upstream ConnectionRows.counts / offerCounts: the counts
    /// shown are the held totals, not affected by search/facets.)
    func statusCount(for status: ConnectionStatusFilter, inRecentFeed: Bool) -> Int {
        switch status {
        case .all: return inRecentFeed ? recentConnections.count : connections.count
        case .active: return inRecentFeed ? 0 : connections.count
        case .failed:
            let rows = inRecentFeed ? recentConnections : connections
            return rows.filter { $0.failureKind != nil }.count
        }
    }

    /// The status filter, in addition to search/facets. A live row
    /// is active by definition (it is still open); a recent row is
    /// closed, so it only passes the failed status when its dial
    /// failed.
    private func matchesStatus(_ connection: LiveConnection, isLive: Bool) -> Bool {
        switch statusFilter {
        case .all: return true
        case .active: return isLive
        case .failed: return connection.failureKind != nil
        }
    }

    /// Groups a list into consecutive runs sharing a `start` minute
    /// (upstream recordMinuteGroups / RecordMinuteList). Follows the
    /// list's existing order — never re-sorts by time, so under a
    /// non-time sort one minute may appear in several runs.
    func minuteGroups(_ list: [LiveConnection]) -> [ConnectionMinuteGroup] {
        var groups: [ConnectionMinuteGroup] = []
        for connection in list {
            let minute = Self.minuteStart(of: connection.start)
            if groups.last?.minute == minute {
                groups[groups.count - 1].rows.append(connection)
            } else {
                groups.append(ConnectionMinuteGroup(minute: minute, rows: [connection]))
            }
        }
        return groups
    }

    /// The minute a date falls in, with seconds zeroed.
    static func minuteStart(of date: Date) -> Date {
        Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        ) ?? date
    }

    /// Upstream recordMinuteLabel: today `HH:mm`, other days
    /// `MM-DD HH:mm`.
    static func minuteLabel(_ minute: Date) -> String {
        if Calendar.current.isDateInToday(minute) {
            return minuteTimeFormatter.string(from: minute)
        }
        return minuteDateFormatter.string(from: minute)
    }

    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let minuteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

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

    /// Recent-feed byte totals for the sheet header (v0.2.121): the
    /// header used to show the live totals on the recent feed too.
    var recentTotalUpload: Int64 { recentConnections.reduce(0) { $0 + $1.upload } }
    var recentTotalDownload: Int64 { recentConnections.reduce(0) { $0 + $1.download } }

    @MainActor
    func refresh() async {
        defer { loaded = true }
        do {
            // v0.2.115: the live table no longer comes from the
            // extension snapshot only. Tunnel up → the extension
            // snapshot, as before. Tunnel down → the in-app core's
            // live connection.watch table (AppCore boots it on
            // demand; the Dashboard / Connections lifecycle keeps
            // it running while the app is in the foreground, like
            // MuYu's startCore at launch), so the Dashboard 实时连接
            // count and the sheet show rows with the VPN off
            // instead of 0. The merge below is identical for both
            // sources.
            let snapshot = try await runConnections(
                tunnel: { try await self.client.connectionSnapshot() },
                appCore: {
                    // Lazily (re-)subscribe if the boot-time
                    // subscribe failed or the session restarted
                    // since — same as DnsStore.refresh; a no-op
                    // when a sub already exists.
                    if AppCore.shared.isRunning {
                        try? await AppCore.shared.subscribeConnectionsWatch()
                    }
                    return await AppCore.shared.connectionSnapshot()
                })
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
            // Ended connections with final totals (upstream 0c9788f
            // ConnectionDelta.ended, forwarded by the extension):
            // apply them FIRST, so a connection the core closed with
            // its final totals keeps those exact totals instead of
            // the last-seen ones from the diff below. An id already
            // recorded is updated in place (final totals + end
            // reason); a new one is inserted. A failed dial only
            // ever arrives this way.
            for ended in snapshot.ended ?? [] {
                // A connection the core re-opened after closing it
                // (an `opened` repeat) is live again, not recent.
                guard !liveIds.contains(ended.connection.connectionId) else { continue }
                let record = LiveConnection(ended: ended)
                if let index = recentConnections.firstIndex(where: { $0.id == record.id }) {
                    recentConnections[index] = record
                } else {
                    recentConnections.append(record)
                }
            }
            // Record what finished since the last poll: ids that were
            // live and are gone now. (A connection the user closed by
            // hand is recorded too — it did finish.)
            let nextIds = liveIds
            let finished = connections.filter { !nextIds.contains($0.id) }
            if !finished.isEmpty {
                // Ids the `ended` list already covered keep the
                // core's record (final totals + end reason); the
                // diff only adds the ones the core did not report
                // (e.g. closed by connection.close before the
                // extension saw the delta).
                let endedIds = Set((snapshot.ended ?? []).map { $0.connection.connectionId })
                let uncovered = finished.filter { !endedIds.contains($0.id) }
                recentConnections = (uncovered + recentConnections)
                    .sorted { $0.start > $1.start }
                if recentConnections.count > 200 {
                    recentConnections = Array(recentConnections.prefix(200))
                }
            }
            // The `ended` inserts above are unsorted and uncapped
            // when nothing finished by diffing; sort + cap them too.
            recentConnections.sort { $0.start > $1.start }
            if recentConnections.count > 200 {
                recentConnections = Array(recentConnections.prefix(200))
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

    /// One-line-per-record diagnostics for the log export
    /// (LogStore "连接诊断" section): failed dials first (kind +
    /// the core's error text), then the other recently ended
    /// connections with their end reason and final totals. Nil
    /// when there is nothing to report. Newest first, capped at
    /// 50 lines so the export stays readable.
    var diagnosticExportText: String? {
        let failed = recentConnections.filter { $0.failureKind != nil }
        let ended = recentConnections.filter { $0.failureKind == nil && $0.endReason != nil }
        guard !failed.isEmpty || !ended.isEmpty else { return nil }
        var lines: [String] = []
        for connection in failed.prefix(50) {
            let when = ConcordFormat.time(Int64(connection.start.timeIntervalSince1970 * 1000))
            let kind = connection.failureKind.map(ConcordConnectionFailure.label) ?? ""
            lines.append("[\(when)] \(connection.host ?? connection.destination) 拨号失败（\(kind)）：\(connection.failureMessage ?? "")")
        }
        for connection in ended.prefix(50) {
            let when = connection.endedAt.map { ConcordFormat.time($0) } ?? ConcordFormat.time(Int64(connection.start.timeIntervalSince1970 * 1000))
            let reason = connection.endReason.map(ConcordEndedConnection.label) ?? ""
            lines.append("[\(when)] \(connection.host ?? connection.destination) 结束（\(reason)）：↑ \(ConcordFormat.bytes(connection.upload)) ↓ \(ConcordFormat.bytes(connection.download))")
        }
        return lines.joined(separator: "\n")
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

    /// Runs one connections query against the tunnel core when it
    /// is up, or the in-app core (booted on demand) when the VPN is
    /// off — same shape as DnsStore.runDns. The in-app core's live
    /// connection.watch table is the only live source with the VPN
    /// off, so the Dashboard 实时连接 count and the Connections
    /// sheet show rows instead of 0. The ensureStarted call is
    /// skipped when the core is already running: its early-return
    /// path walks the whole provider cache (reads every file to
    /// compare bytes), and refresh() runs on the Connections page's
    /// 1 s poll — re-walking the cache every second would be pure
    /// disk I/O for nothing. If the tunnel starts while AppCore is
    /// booting, AppCore refuses to run alongside it
    /// (AppCoreError.tunnelRunning) — the tunnel core is used
    /// instead, not reported as a failure.
    private func runConnections<T>(tunnel: () async throws -> T, appCore: () async throws -> T) async throws -> T {
        if hasCore {
            return try await tunnel()
        }
        if !AppCore.shared.isRunning {
            do {
                try await AppCore.shared.ensureStarted()
            } catch {
                if case AppCoreError.tunnelRunning = error {
                    return try await tunnel()
                }
                throw error
            }
        }
        return try await appCore()
    }

    /// True when the connections query can reach the tunnel core:
    /// the tunnel is running, or the client is in sample mode.
    /// With the VPN off in live mode the in-app core (AppCore,
    /// booted on demand by runConnections) is the fallback.
    private var hasCore: Bool {
        client.mode == .sample || TunnelManager.shared.isRunning
    }
}
