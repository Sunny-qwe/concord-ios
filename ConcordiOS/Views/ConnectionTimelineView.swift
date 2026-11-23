import Foundation
import SwiftUI

// MARK: - Connection timeline (upstream tracker_timeline.dart)
//
// The detail page's first tab: what happened to a connection, step
// by step from its address to now, each step on a vertical rail
// (upstream TrackerTimeline + TrackerRailRow in
// tracker_detail_parts.dart). The steps the core timed carry their
// time; steps within the same second show only the milliseconds.

/// One step of a connection's setup, in order (upstream
/// `TimelineEvent` in tracker_timeline.dart).
struct TimelineEvent {
    let kind: String
    let title: String
    let note: String
    let at: Date?
    let mark: TimelineRailMark
    /// The live status row: its title is rebuilt every second from
    /// the clock (upstream `TrackerLifetime` in tracker_clock.dart).
    let titleOf: ((Date) -> String)?
    let onPressed: (() -> Void)?

    init(
        kind: String,
        title: String = "",
        note: String = "",
        at: Date? = nil,
        mark: TimelineRailMark = .step,
        titleOf: ((Date) -> String)? = nil,
        onPressed: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.note = note
        self.at = at
        self.mark = mark
        self.titleOf = titleOf
        self.onPressed = onPressed
    }
}

/// The dot a step gets on the rail (upstream `RailMark`).
enum TimelineRailMark {
    case step
    case end
    case error
}

/// Builds the timeline steps, in order (upstream
/// `trackerTimelineEvents` in tracker_timeline.dart). A plain
/// function, not a ViewBuilder: the event list is assembled with
/// ordinary control flow, then rendered by TimelineRailRow.
/// `dnsEntries` is already resolved and newest-first (upstream
/// `_LinkedQueries.of`); `exchanges` is empty unless MITM capture
/// is on, in which case `onOpenRequests` switches to the HTTP tab.
func buildConnectionTimelineEvents(
    connection: LiveConnection,
    isLive: Bool,
    dnsEntries: [ConcordDnsEntry],
    exchanges: [MitmExchangeSummary],
    nodeDelayMs: Int32?,
    pickedGroupType: String?,
    standingRuleIndex: Int?,
    onOpenRequests: (() -> Void)?
) -> [TimelineEvent] {
    var events: [TimelineEvent] = []
    let timing = connection.timing
    let dnsMode = timelineDnsModeLabel(connection.dnsMode)
    let dnsTime = timelineMs(timing?.dnsStart, timing?.dnsEnd)
    func at(_ offset: UInt32?) -> Date? {
        guard let timing, let offset else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timing.accepted) / 1000 + TimeInterval(offset) / 1_000_000)
    }
    for entry in dnsEntries {
        events.append(TimelineEvent(
            kind: "DNS",
            title: "\(entry.type) → \(timelineDnsSummary(entry))",
            note: timelineJoin([dnsMode, entry.cached == true ? "缓存" : nil, "\(entry.delay) ms"]),
            at: at(timing?.dnsStart),
            mark: timelineDnsIsFailed(entry) ? .error : .step
        ))
    }
    if dnsEntries.isEmpty, let host = connection.host, !host.isEmpty, dnsMode != nil || dnsTime != nil {
        events.append(TimelineEvent(
            kind: "DNS",
            title: host,
            note: timelineJoin([dnsMode, dnsTime]),
            at: at(timing?.dnsStart)
        ))
    }
    events.append(TimelineEvent(
        kind: "规则",
        title: timelineRuleLine(connection),
        note: timelineJoinSpace([standingRuleIndex.map { "第 \($0 + 1) 条" }, connection.chains.last.map { "→ \($0)" }]),
        at: at(timing?.routed)
    ))
    if connection.chains.count > 1 {
        var nodeParts: [String?] = [pickedGroupType]
        if let delay = nodeDelayMs, delay > 0 {
            nodeParts.append("延迟 \(delay) ms")
        }
        events.append(TimelineEvent(
            kind: "节点",
            title: connection.chains.first ?? "",
            note: timelineJoin(nodeParts),
            at: at(timing?.dialStart)
        ))
    }
    let address = (connection.destinationIp ?? "").isEmpty ? (connection.host ?? "") : (connection.destinationIp ?? "")
    let target = timelineEndpoint(ip: address, port: connection.destinationPort)
    let connectionNote: String
    if let failureKind = connection.failureKind {
        connectionNote = timelineJoin([ConcordConnectionFailure.label(for: failureKind), connection.failureMessage])
    } else if let start = timing?.dialStart, let end = timing?.dialEnd, let ms = timelineMsValue(start, end) {
        connectionNote = "握手 \(ms) ms"
    } else {
        connectionNote = ""
    }
    events.append(TimelineEvent(
        kind: "连接",
        title: "\(connection.network.uppercased()) \(target)",
        note: connectionNote,
        at: at(timing?.dialEnd ?? timing?.connected),
        mark: connection.failureKind != nil ? .error : .step
    ))
    if connection.mitm {
        events.append(TimelineEvent(
            kind: "解密",
            title: "已解密",
            at: at(timing?.decrypted)
        ))
    }
    if connection.mitmRefused {
        events.append(TimelineEvent(
            kind: "解密",
            title: "客户端拒绝了证书",
            mark: .error
        ))
    }
    if let onOpenRequests, !exchanges.isEmpty {
        let ordered = exchanges.sorted(by: timelineExchangeLess)
        if let first = ordered.first, let latest = ordered.last {
            var latestText = "\(latest.method) \(timelineExchangePath(latest.url))"
            if latest.status > 0 {
                latestText += " \(latest.status)"
            }
            events.append(TimelineEvent(
                kind: "HTTP",
                title: "\(exchanges.count) 个 HTTP 请求",
                note: "最近一次 \(latestText)",
                at: timelineDate(rfc3339: first.start),
                onPressed: onOpenRequests
            ))
        }
    }
    let traffic = timelineJoin([
        "下载 \(ConcordFormat.bytes(connection.download))",
        "上传 \(ConcordFormat.bytes(connection.upload))",
    ])
    let failed = connection.failureKind != nil
        || connection.endReason == "error"
        || connection.endReason == "failed"
    if isLive {
        events.append(TimelineEvent(
            kind: "状态",
            note: traffic,
            mark: .end,
            titleOf: { now in "活动 \(timelineLiveLifetime(start: connection.start, now: now))" }
        ))
    } else {
        let endedAt = connection.endedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let lifetime = timelineLifetimeText(start: connection.start, endedAt: endedAt, now: Date())
        events.append(TimelineEvent(
            kind: "状态",
            title: "已关闭 \(lifetime)",
            note: timelineJoin([connection.endReason.map { ConcordEndedConnection.label(for: $0) }, traffic]),
            at: endedAt,
            mark: failed ? .error : .end
        ))
    }
    return events
}

/// Each second in full, and only the milliseconds in one already
/// given (upstream `_timeLabels` in tracker_timeline.dart). The
/// live status row shows "现在".
func timelineTimeLabels(_ events: [TimelineEvent]) -> [String] {
    var labels: [String] = []
    var shownSecond: Int64?
    for event in events {
        guard let at = event.at else {
            labels.append(event.titleOf != nil ? "现在" : "")
            continue
        }
        let millis = Int64(at.timeIntervalSince1970 * 1000)
        let second = millis / 1000
        if second == shownSecond {
            labels.append(".\(String(format: "%03d", Int(millis % 1000)))")
        } else {
            labels.append(timelineClockFormatter.string(from: at))
        }
        shownSecond = second
    }
    return labels
}

private let timelineClockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private let timelineRFC3339Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// The DNS mode's label (upstream `_dnsModeLabel`): fake-ip and
/// redir-host name themselves, hosts is "来自 hosts", normal has
/// no label.
func timelineDnsModeLabel(_ mode: String?) -> String? {
    switch mode {
    case "fake-ip": return "fake-ip 映射"
    case "redir-host": return "redir-host"
    case "hosts": return "来自 hosts"
    default: return nil
    }
}

/// A DNS query's answer (upstream `DnsQuery.summary`): the error,
/// else a failing rcode, else the answers.
func timelineDnsSummary(_ entry: ConcordDnsEntry) -> String {
    if let error = entry.error, !error.isEmpty {
        return error
    }
    if let rcode = entry.rcode, !rcode.isEmpty, rcode != "NOERROR" {
        return rcode
    }
    return entry.answers.joined(separator: ", ")
}

/// A DNS query failed (upstream `DnsQuery.isFailed`).
func timelineDnsIsFailed(_ entry: ConcordDnsEntry) -> Bool {
    if let error = entry.error, !error.isEmpty {
        return true
    }
    if let rcode = entry.rcode, !rcode.isEmpty, rcode != "NOERROR" {
        return true
    }
    return false
}

/// The rule as the profile writes it, type and payload on one line
/// (upstream `trackerRuleLine`): a comma, not the parentheses the
/// detail page's `ruleText` uses.
func timelineRuleLine(_ connection: LiveConnection) -> String {
    guard let rule = connection.rule, !rule.isEmpty else {
        return "未经规则"
    }
    if let payload = connection.rulePayload, !payload.isEmpty {
        return "\(rule),\(payload)"
    }
    return rule
}

/// Microseconds between two timing offsets, as rounded whole
/// milliseconds (upstream `_milliseconds`).
func timelineMsValue(_ from: UInt32, _ to: UInt32) -> Int? {
    guard to >= from else { return nil }
    return Int((Double(to - from) / 1000).rounded())
}

func timelineMs(_ from: UInt32?, _ to: UInt32?) -> String? {
    guard let from, let to, let value = timelineMsValue(from, to) else { return nil }
    return "\(value) ms"
}

/// `ip:port`, bracketing IPv6 (upstream `trackerEndpointText`).
func timelineEndpoint(ip: String, port: Int) -> String {
    if ip.isEmpty {
        return ""
    }
    return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
}

/// An exchange URL's path + query, `/` for an empty path
/// (upstream `exchangePathOf`).
func timelineExchangePath(_ url: String) -> String {
    guard let parsed = URL(string: url), parsed.host != nil else {
        return url
    }
    let path = parsed.path.isEmpty ? "/" : parsed.path
    if let query = parsed.query, !query.isEmpty {
        return "\(path)?\(query)"
    }
    return path
}

/// Earlier exchange first, by parsed start time (upstream scans
/// for the earliest and latest exchange).
func timelineExchangeLess(_ a: MitmExchangeSummary, _ b: MitmExchangeSummary) -> Bool {
    let dateA = timelineDate(rfc3339: a.start)
    let dateB = timelineDate(rfc3339: b.start)
    if let dateA, let dateB {
        return dateA < dateB
    }
    return a.start < b.start
}

func timelineDate(rfc3339: String) -> Date? {
    timelineRFC3339Formatter.date(from: rfc3339)
        ?? ISO8601DateFormatter().date(from: rfc3339)
}

/// A live connection's uptime, `M:SS` under an hour, `H:MM:SS`
/// above (upstream `trackerLifetimeText`).
func timelineLiveLifetime(start: Date, now: Date) -> String {
    let elapsed = max(0, Int(now.timeIntervalSince(start)))
    let seconds = String(format: "%02d", elapsed % 60)
    if elapsed < 3600 {
        return "\(elapsed / 60):\(seconds)"
    }
    return "\(elapsed / 3600):\(String(format: "%02d", elapsed / 60 % 60)):\(seconds)"
}

/// A finished connection's lifetime (upstream
/// `trackerLifetimeText` + `trackerDurationText`).
func timelineLifetimeText(start: Date, endedAt: Date?, now: Date) -> String {
    if let endedAt {
        return timelineDurationText(endedAt.timeIntervalSince(start))
    }
    return timelineLiveLifetime(start: start, now: now)
}

func timelineDurationText(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration))
    if seconds < 60 {
        return "\(seconds) s"
    }
    let minutes = Double(seconds) / 60
    if minutes < 60 {
        if minutes < 10 {
            return String(format: "%.1f min", minutes)
        }
        return "\(Int(minutes.rounded())) min"
    }
    return String(format: "%.1f h", minutes / 60)
}

/// Non-empty parts joined with ` · ` (upstream `join`).
func timelineJoin(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

/// Non-empty parts joined with a space (upstream joins the rule
/// note's parts with `' '`).
func timelineJoinSpace(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - Timeline view

/// The timeline tab: the built steps as rail rows, in order.
struct ConnectionTimelineView: View {
    let connection: LiveConnection
    let isLive: Bool
    let dnsEntries: [ConcordDnsEntry]
    let exchanges: [MitmExchangeSummary]
    let nodeDelayMs: Int32?
    let pickedGroupType: String?
    let standingRuleIndex: Int?
    let onOpenRequests: (() -> Void)?

    private var events: [TimelineEvent] {
        buildConnectionTimelineEvents(
            connection: connection,
            isLive: isLive,
            dnsEntries: dnsEntries,
            exchanges: exchanges,
            nodeDelayMs: nodeDelayMs,
            pickedGroupType: pickedGroupType,
            standingRuleIndex: standingRuleIndex,
            onOpenRequests: onOpenRequests
        )
    }

    var body: some View {
        let events = self.events
        let labels = timelineTimeLabels(events)
        return List {
            Section {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    TimelineRailRow(
                        event: event,
                        timeLabel: labels[index],
                        first: index == 0,
                        last: index == events.count - 1
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// A row of the timeline, its point on a rail that runs on through
/// the rows above and below it, level with the title (upstream
/// `TrackerRailRow`). SwiftUI has no CustomPaint, so the rail is
/// hand-built: a 40pt left slot with the dot and the line segments
/// above and below it; the first row has no upper line, the last
/// no lower line.
struct TimelineRailRow: View {
    let event: TimelineEvent
    let timeLabel: String
    let first: Bool
    let last: Bool

    /// Upstream `_RailPainter`: radius 5, stroke 1.7, rail 1.5,
    /// gap 3. The dot sits level with the title's centre: row
    /// padding 8 + half a body line (~11) = 19 from the row's top
    /// edge, so the upper line runs 0–11 and the dot 14–24.
    private static let slotWidth: CGFloat = 40
    private static let dotDiameter: CGFloat = 10
    private static let upperLineHeight: CGFloat = 11
    private static let dotGap: CGFloat = 3
    private static let railWidth: CGFloat = 1.5

    var body: some View {
        if event.onPressed != nil {
            Button { self.event.onPressed?() } label: { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 0) {
            railColumn
            textColumn
            Spacer(minLength: 8)
            trailingColumn
        }
        .padding(.vertical, 8)
    }

    private var railColumn: some View {
        VStack(spacing: 0) {
            railSegment(height: Self.upperLineHeight, visible: !first)
            Spacer().frame(height: Self.dotGap)
            railDot
            Spacer().frame(height: Self.dotGap)
            railSegmentFlexible(visible: !last)
        }
        .frame(width: Self.slotWidth, alignment: .top).frame(maxHeight: .infinity)
    }

    private func railSegment(height: CGFloat, visible: Bool) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: Self.railWidth, height: height)
            .opacity(visible ? 1 : 0)
    }

    private func railSegmentFlexible(visible: Bool) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: Self.railWidth).frame(maxHeight: .infinity)
            .opacity(visible ? 1 : 0)
    }

    private var railDot: some View {
        Group {
            if event.mark == .step {
                Circle().stroke(Color.secondary, lineWidth: 1.7)
            } else if event.mark == .end {
                Circle().fill(Color.accentColor)
            } else {
                Circle().fill(Color.red)
            }
        }
        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
    }

    private var subtitle: String {
        timelineJoin([event.kind, event.note])
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The live status row's title ticks every second (upstream
    /// `TrackerLifetime`); the same `TimelineView(.periodic)` leaf
    /// the Dashboard's uptime text already uses, so only this text
    /// re-renders, never the list.
    @ViewBuilder
    private var titleText: some View {
        if let titleOf = event.titleOf {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(titleOf(context.date))
                    .font(.body)
                    .fontWeight(self.event.mark == .end ? .semibold : .regular)
                    .lineLimit(1)
            }
        } else {
            Text(event.title)
                .font(.body)
                .fontWeight(event.mark == .end ? .semibold : .regular)
                .lineLimit(1)
        }
    }

    private var trailingColumn: some View {
        HStack(spacing: 4) {
            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if event.onPressed != nil {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
