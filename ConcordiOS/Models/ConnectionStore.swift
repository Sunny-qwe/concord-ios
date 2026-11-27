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
    /// Upstream process UID (tracker_info_detail.dart
    /// TrackerPathSection shows `process(uid)`): decoded in
    /// ConcordClient but dropped in the mapping until v0.2.146.
    let uid: UInt32?
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
    /// How many identical failed dials this row stands for
    /// (upstream TrackerRepeats, `×N`): 1 unless the failed-status
    /// list merged repeats into it (see
    /// ConnectionStore.mergedRepeats).
    var repeatCount: Int = 1

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
        uid = c.uid
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

/// One filter condition on the connections list (upstream
/// lib/models/connection_query.dart RecordCondition): a field, a
/// value, and how the value meets the field. Same-field conditions
/// widen each other, different fields narrow; an excluding one
/// drops whatever it holds. The `+` button's editor and the
/// `field:` search syntax both build these.
struct ConnectionCondition: Identifiable, Equatable {
    enum Field: String, CaseIterable, Identifiable {
        case host, app, exit, rule, net, ip

        var id: String { rawValue }

        var label: String {
            switch self {
            case .host: return "域名"
            case .app: return "应用"
            case .exit: return "出口"
            case .rule: return "规则"
            case .net: return "网络"
            case .ip: return "IP"
            }
        }

        /// The field's searchable values for one connection
        /// (upstream ConnectionField.valuesOf).
        func values(of connection: LiveConnection) -> [String] {
            switch self {
            case .host:
                return [connection.host ?? "", connection.host ?? connection.destinationIp ?? ""]
            case .app:
                return [connection.process ?? "", connection.processPath ?? ""]
            case .exit:
                return connection.chains
            case .rule:
                return [Self.ruleText(of: connection)]
            case .net:
                return [connection.network]
            case .ip:
                return [connection.destinationIp ?? "", connection.sourceIp]
            }
        }

        /// Rule with its matched payload (upstream TrackerRuleText);
        /// "无规则" when no rule decided.
        static func ruleText(of connection: LiveConnection) -> String {
            guard let rule = connection.rule, !rule.isEmpty else { return "无规则" }
            if let payload = connection.rulePayload, !payload.isEmpty {
                return "\(rule) (\(payload))"
            }
            return rule
        }
    }

    enum Op: String, CaseIterable, Identifiable {
        case contains = "包含"
        case notContains = "不包含"
        case equals = "等于"
        case notEquals = "不等于"

        var id: String { rawValue }
    }

    let id = UUID()
    var field: Field
    var value: String
    var op: Op

    var excludes: Bool { op == .notContains || op == .notEquals }
    var isEquals: Bool { op == .equals || op == .notEquals }

    /// Whether the connection meets this condition's value, before
    /// exclusion is applied (upstream RecordCondition.holds).
    func holds(_ connection: LiveConnection) -> Bool {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return false }
        let values = field.values(of: connection)
        if isEquals {
            return values.contains { $0.lowercased() == needle }
        }
        return values.joined(separator: "\n").lowercased().contains(needle)
    }
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
    /// Structured filter conditions (upstream
    /// connection_conditions.dart): built by the `+` condition
    /// editor and by "隐藏此主机". Same-field conditions widen,
    /// cross-field conditions narrow, excluding ones drop.
    @Published var conditions: [ConnectionCondition] = []
    /// Status filter (upstream ConditionFilterRow): all / active /
    /// failed. Session-only; filters in addition to search/facets.
    @Published var statusFilter: ConnectionStatusFilter = .all
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    /// First-load state (upstream requests.dart _loaded): false until
    /// the first snapshot read has landed, so the page can show a
    /// loading indicator instead of the empty state.
    @Published var loaded = false
    /// Record-filter facets (upstream trackerInfoFacets: network,
    /// rule, MITM, app/process, proxy chains). Session-only:
    /// MULTI-value per facet (upstream conditionsMatcher: values
    /// on one field widen each other), empty = unfiltered.
    @Published var facetNetworks: Set<String> = []
    @Published var facetRules: Set<String> = []
    @Published var facetProxies: Set<String> = []
    @Published var facetProcesses: Set<String> = []
    @Published var facetMitmOnly = false
    /// Last-seen byte counts behind the per-connection live speeds
    /// (same differencing idea as TrafficStore.refreshNodeSpeeds,
    /// but per connection id instead of per chain name).
    private var previousBytes: [UInt64: (upload: Int64, download: Int64, at: Date)] = [:]

    /// Facet value lists offered by the current data (live + recent).
    var offeredNetworks: [String] {
        Array(Set((connections + recentConnections).map { $0.network.lowercased() })).sorted()
    }
    var offeredRules: [String] {
        Array(Set((connections + recentConnections).compactMap(\.rule))).sorted()
    }
    var offeredProxies: [String] {
        Array(Set((connections + recentConnections).flatMap { $0.chains.isEmpty ? [$0.proxy].compactMap { $0 } : $0.chains })).sorted()
    }
    var offeredProcesses: [String] {
        Array(Set((connections + recentConnections).compactMap(\.process))).sorted()
    }

    var hasActiveFacets: Bool {
        !facetNetworks.isEmpty || !facetRules.isEmpty || !facetProxies.isEmpty
            || !facetProcesses.isEmpty || facetMitmOnly || !conditions.isEmpty
    }

    func clearFacets() {
        facetNetworks.removeAll()
        facetRules.removeAll()
        facetProxies.removeAll()
        facetProcesses.removeAll()
        facetMitmOnly = false
        conditions.removeAll()
    }

    private func matchesFacets(_ connection: LiveConnection) -> Bool {
        if !facetNetworks.isEmpty, !facetNetworks.contains(connection.network.lowercased()) { return false }
        if !facetRules.isEmpty, !facetRules.contains(connection.rule ?? "") { return false }
        if !facetProxies.isEmpty,
           !connection.chains.contains(where: { facetProxies.contains($0) })
           && !(connection.proxy.map { facetProxies.contains($0) } ?? false) { return false }
        if !facetProcesses.isEmpty, !facetProcesses.contains(connection.process ?? "") { return false }
        if facetMitmOnly, !connection.mitm { return false }
        return true
    }

    /// `field:` conditions in the search text (upstream
    /// ConnectionQuery.parse): `host:github.com`,
    /// `-host:ads` (exclude), `rule:=DIRECT` (equals), quoted
    /// values with spaces. A match only counts when it starts the
    /// text or follows whitespace, as upstream's lookbehind does.
    private static let queryConditionPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try — static literal pattern.
        try! NSRegularExpression(
            pattern: "(-?)(host|app|exit|rule|net|ip):(=?)(\"([^\"]*)\"|([^\\s]+))",
            options: [.caseInsensitive]
        )
    }()

    /// The search text split into `field:` conditions and the
    /// remaining free-text terms (upstream ConnectionQuery).
    private func parsedSearch() -> (conditions: [ConnectionCondition], terms: [String]) {
        let text = searchText
        let nsText = text as NSString
        let matches = Self.queryConditionPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length))
        var conditions: [ConnectionCondition] = []
        var rest = text
        for match in matches.reversed() {
            let range = match.range
            // Only a token at the start or after whitespace counts.
            if range.location > 0 {
                let prev = nsText.character(at: range.location - 1)
                guard prev == 32 || prev == 9 || prev == 10 else { continue }
            }
            guard let swiftRange = Range(range, in: rest) else { continue }
            let minus = nsText.substring(with: match.range(at: 1)) == "-"
            let fieldName = nsText.substring(with: match.range(at: 2)).lowercased()
            let equals = nsText.substring(with: match.range(at: 3)) == "="
            let value: String
            if match.range(at: 5).location != NSNotFound {
                value = nsText.substring(with: match.range(at: 5))
            } else if match.range(at: 6).location != NSNotFound {
                value = nsText.substring(with: match.range(at: 6))
            } else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let field = ConnectionCondition.Field(rawValue: fieldName) else { continue }
            let op: ConnectionCondition.Op =
                equals ? (minus ? .notEquals : .equals)
                       : (minus ? .notContains : .contains)
            conditions.append(ConnectionCondition(field: field, value: trimmed, op: op))
            rest.replaceSubrange(swiftRange, with: " ")
        }
        let terms = rest.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return (conditions, terms)
    }

    /// The free-text search fields (upstream TrackerInfo.searchFields,
    /// common.dart:226-243): network, host, dest/source IP/port,
    /// process/path, remote destination, ASN, GeoIP, special
    /// proxy/rules, rule/payload, chains. Every free-text term must
    /// appear somewhere in the joined fields (upstream SearchQuery).
    private func searchFieldText(_ connection: LiveConnection) -> String {
        var fields: [String] = [
            connection.network,
            connection.host ?? "",
            connection.destinationIp ?? "",
            "\(connection.destinationPort)",
            connection.sourceIp,
            "\(connection.sourcePort)",
            connection.process ?? "",
            connection.processPath ?? "",
            connection.remoteDestination ?? "",
            connection.destinationAsn ?? "",
        ]
        fields += connection.destinationGeoIp
        fields += [
            connection.specialProxy ?? "",
            connection.specialRules ?? "",
            connection.rule ?? "",
            connection.rulePayload ?? "",
        ]
        if (connection.rule ?? "").isEmpty {
            fields.append(ConnectionCondition.Field.ruleText(of: connection))
        }
        fields += connection.chains
        return fields.joined(separator: "\n").lowercased()
    }

    /// Whether a connection passes the search text and the structured
    /// conditions: excluding conditions drop what they hold, same-field
    /// conditions widen, cross-field conditions narrow (upstream
    /// conditionsMatcher), then every free-text term must match.
    private func matchesQuery(
        _ connection: LiveConnection,
        parsed: [ConnectionCondition],
        terms: [String]
    ) -> Bool {
        let all = parsed + conditions
        for condition in all where condition.excludes && condition.holds(connection) {
            return false
        }
        let included = Dictionary(grouping: all.filter { !$0.excludes }) { $0.field }
        for (_, group) in included {
            if !group.contains(where: { $0.holds(connection) }) { return false }
        }
        guard !terms.isEmpty else { return true }
        let haystack = searchFieldText(connection)
        return terms.allSatisfy { haystack.contains($0) }
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

    /// The connections segment's single list (upstream Requests:
    /// one log, newest first): live connections plus the locally
    /// built recent list, filtered by search / facets / conditions
    /// / status. No sort control — upstream v0.9.5 has none (log
    /// order, newest first). Failed dials merge into `×N` rows
    /// while the status filter is 失败 (upstream mergesRepeats).
    var displayedConnections: [LiveConnection] {
        let (parsed, terms) = parsedSearch()
        let liveIds = Set(connections.map(\.id))
        var rows = (connections + recentConnections)
            .filter { matchesQuery($0, parsed: parsed, terms: terms) }
            .filter { matchesFacets($0) }
            .filter { matchesStatus($0, liveIds: liveIds) }
            .sorted { $0.start > $1.start }
        if statusFilter == .failed {
            rows = mergedRepeats(rows)
        }
        return rows
    }

    /// Whether this id is still an open connection.
    func isLive(_ id: UInt64) -> Bool {
        connections.contains { $0.id == id }
    }

    /// Merge identical failed dials into one row carrying the count
    /// (upstream trackerRepeatKeyOf: failure kind, network, title,
    /// destination port, process). The newest dial is the row's
    /// representative; the list is already newest-first.
    private func mergedRepeats(_ rows: [LiveConnection]) -> [LiveConnection] {
        var seen: [String: Int] = [:]
        var out: [LiveConnection] = []
        for row in rows {
            guard row.failureKind != nil else {
                out.append(row)
                continue
            }
            let key = [
                row.failureKind ?? "",
                row.network,
                row.host ?? row.destinationIp ?? row.destination,
                "\(row.destinationPort)",
                row.process ?? "",
            ].joined(separator: "\u{1f}")
            if let index = seen[key] {
                out[index].repeatCount += 1
            } else {
                seen[key] = out.count
                var representative = row
                representative.repeatCount = 1
                out.append(representative)
            }
        }
        return out
    }

    /// Value suggestions with counts for the condition editor
    /// (upstream FieldDraft.suggestionsOf): the field's distinct
    /// values across live + recent, most common first, filtered
    /// by the typed text.
    func suggestedValues(
        for field: ConnectionCondition.Field,
        matching text: String,
        limit: Int = 6
    ) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for connection in connections + recentConnections {
            for value in field.values(of: connection) where !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return counts
            .filter { needle.isEmpty || $0.key.lowercased().contains(needle) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    /// How many live + recent rows a draft condition holds (the
    /// editor's "将匹配 N 条" preview; excluding conditions invert it).
    func countMatching(_ condition: ConnectionCondition) -> Int {
        (connections + recentConnections).filter { condition.holds($0) }.count
    }

    /// Feed-scoped status counts (upstream ConnectionRows.counts /
    /// offerCounts: the counts shown are the held totals, not
    /// affected by search/facets). The connections segment is one
    /// merged list, so 全部 counts live + recent, 活动 counts live,
    /// 失败 counts failed rows in both.
    func statusCount(for status: ConnectionStatusFilter) -> Int {
        switch status {
        case .all: return connections.count + recentConnections.count
        case .active: return connections.count
        case .failed:
            return (connections + recentConnections).filter { $0.failureKind != nil }.count
        }
    }

    /// The status filter, in addition to search/facets. A live row
    /// is active by definition (it is still open); a recent row is
    /// closed, so it only passes the failed status when its dial
    /// failed.
    private func matchesStatus(_ connection: LiveConnection, liveIds: Set<UInt64>) -> Bool {
        switch statusFilter {
        case .all: return true
        case .active: return liveIds.contains(connection.id)
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
