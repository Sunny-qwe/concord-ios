import SwiftUI
import UIKit

// MARK: - Logs (FlClash: LogsView, lib/views/logs.dart)
// FlClash logs page: level filter, search, auto-scroll and export
// (no clear button — the rows come from the extension snapshot, so
// clearing the in-memory list would only fake it). Backed by Concord
// log.watch (stream of LogEntry) and core.lastWarnings.

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showExportError = false
    @State private var showCopiedAlert = false
    @Environment(\.dismiss) private var dismiss
    @State private var tab = LogsTab.logs
    /// The log row tapped for its detail sheet (C8).
    @State private var selectedEntry: ConcordLogEntry?
    /// Persisted diagnostics (v0.2.40): AppCore writes the boot
    /// report and the last delay-test report to disk; they do not
    /// need the tunnel running, so the Logs page shows them while
    /// the VPN is off and the live list is empty.
    @State private var bootReport: String?
    @State private var delayReport: String?
    /// Whether the user is currently at the bottom of each list
    /// (upstream "following": logs.dart wires its auto-scroll
    /// through a follow-mode list controller, so new rows only pull
    /// the list down while it is already at the end). Without this,
    /// every new entry yanked the list to the bottom even while the
    /// user was reading older rows — the list fought the scroll.
    /// Tracked by the last row's appear/disappear below.
    @State private var followingLogs = true
    @State private var followingEvents = true

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation bar.
        // v0.2.63: the page background is a full-screen layer
        // behind the VStack. IMG_1195 showed a ~244pt white gap
        // ABOVE the search box on the Events tab (the Logs tab has
        // none) — the gap sits outside the VStack, so the VStack's
        // own background never paints it and the window behind it
        // is white. A full-screen background makes any such gap
        // the page gray instead of white. The VStack is pinned to
        // the top so the search box stays right under the nav bar.
        // (The VStack's children keep their old indentation; only
        // the wrap is new.)
        ZStack {
            ConcordTheme.pageBackground
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text(tab == .logs ? "日志为示例数据" : "事件为示例数据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                // Search is a permanent row now (v0.2.62): the
                // system `.searchable` field left a large white
                // gap above the segment on the Events tab
                // (IMG_1194) — the search controller's blank
                // area, not our page background — and pushed the
                // segment to the middle of the page. A plain row
                // keeps the segment directly below the search box
                // on both tabs, on the page background like the
                // Logs tab. Same bindings as the old searchable
                // field, so filtering is unchanged.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tab == .logs ? "搜索日志" : "搜索事件", text: tab == .logs ? $logStore.searchText : $eventStore.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !(tab == .logs ? logStore.searchText : eventStore.searchText).isEmpty {
                        Button {
                            if tab == .logs { logStore.searchText = "" } else { eventStore.searchText = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 4)

                Picker("内容", selection: $tab) {
                    ForEach(LogsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)

                if tab == .logs {
                    // Upstream (logs.dart, mobile): no permanent level
                    // row — the filter lives in the bar menu and only
                    // an ACTIVE filter shows as a removable chip under
                    // the bar (Scaffold keywords strip).
                    if logStore.levelFilter != .all {
                        HStack {
                            HStack(spacing: 4) {
                                Text(logStore.levelFilter.rawValue)
                                Button { logStore.levelFilter = .all } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    if !logStore.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("核心警告（core.lastWarnings）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(logStore.warnings, id: \.message) { warning in
                                Text(warning.message).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    if logStore.filtered.isEmpty && logStore.vpnDiagnosticEntries.isEmpty {
                        // The user asked for this order explicitly
                        // (v0.2.49, IMG_1165): the diagnostic cards
                        // sit right under the filters and the
                        // "暂无日志" block goes at the BOTTOM, after
                        // them — not in the middle of the page.
                        // (Upstream FlClash logs.dart shows its empty
                        // state where the list would be, i.e. at the
                        // top; this order is an intentional deviation
                        // — the diagnostics are ours-only content and
                        // the user wants the text at the top.)
                        ScrollView {
                            persistedDiagnosticsView
                            compactEmptyStateView
                        }
                        // v0.2.66: tab-bar clearance for pushed pages.
                        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
                    } else {
                        ScrollViewReader { proxy in
                            List {
                                // Native iOS VPN diagnostic logs
                                // (L-M1): the extension's own
                                // diagnostic files, prepended to the
                                // core logs like upstream prepends its
                                // native logs (logs.dart _setLogs).
                                if !logStore.vpnDiagnosticEntries.isEmpty {
                                    Section("VPN 诊断日志") {
                                        ForEach(logStore.vpnDiagnosticEntries) { entry in
                                            logRow(entry, selectedEntry: $selectedEntry)
                                        }
                                    }
                                }
                                ForEach(logStore.filtered) { entry in
                                    logRow(entry, selectedEntry: $selectedEntry)
                                }
                            }
                            .listStyle(.insetGrouped)
                            .scrollContentBackground(.hidden)
                            // v0.2.66: tab-bar clearance for pushed pages.
                            .contentMargins(.bottom, ConcordTheme.tabBarClearance)
                            .onChange(of: logStore.filtered.count) { _, _ in
                                if logStore.autoScroll, followingLogs, let last = logStore.filtered.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                } else {
                    Picker("类型", selection: $eventStore.typeFilter) {
                        ForEach(eventStore.eventTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                    if eventStore.filtered.isEmpty {
                        // Same compact treatment as the logs tab:
                        // a bounded empty state, not a greedy
                        // ContentUnavailableView.
                        VStack(spacing: 8) {
                            Image(systemName: "bolt")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("暂无事件")
                                .font(.headline)
                            Text("核心事件（提供方更新、测速、致命错误、状态变化）会显示在这里")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ScrollViewReader { proxy in
                            List(eventStore.filtered) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(ConcordFormat.time(entry.receivedAtMillis))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.event.type)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(eventColor(entry.event.type).opacity(0.15), in: Capsule())
                                            .foregroundStyle(eventColor(entry.event.type))
                                        Text(entry.event.summary)
                                            .font(.caption2)
                                            .lineLimit(3)
                                    }
                                }
                                .id(entry.id)
                                .onAppear { if entry.id == eventStore.filtered.last?.id { followingEvents = true } }
                                .onDisappear { if entry.id == eventStore.filtered.last?.id { followingEvents = false } }
                            }
                            .listStyle(.insetGrouped)
                            .scrollContentBackground(.hidden)
                            // v0.2.66: tab-bar clearance for pushed pages.
                            .contentMargins(.bottom, ConcordTheme.tabBarClearance)
                            .onChange(of: eventStore.filtered.count) { _, _ in
                                if logStore.autoScroll, followingEvents, let last = eventStore.filtered.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    if let updated = eventStore.lastUpdated {
                        Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    if let error = eventStore.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // v0.2.63: the keyboard must not shift this page. The gap
        // in IMG_1195 is ~244pt tall — about a keyboard tall — and
        // only on the Events tab, so the likeliest cause is the
        // keyboard pushing the page down and the layout getting
        // stuck. The search box sits at the top, so the keyboard
        // never covers it anyway.
        .ignoresSafeArea(.keyboard)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            // Upstream has no "返回" text: the leading slot holds a
            // back chevron glyph only (scaffold.dart _buildPopButton).
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
                if tab == .logs {
                    ToolbarItem(placement: .topBarTrailing) {
                        Toggle("自动滚动", isOn: $logStore.autoScroll)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Level filter (upstream: the filter lives in
                        // the bar's overflow menu, not a permanent row;
                        // a Picker inside a Menu renders checkmarks).
                        Menu {
                            Picker("级别", selection: $logStore.levelFilter) {
                                ForEach(LogLevelFilter.allCases) { level in
                                    Text(level.rawValue).tag(level)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Export (v0.2.35): the share icon now offers
                        // the full bundled export — one .txt file
                        // (app log + core warnings + app-core boot /
                        // GeoSeed diagnostic + VPN startup diagnostic)
                        // via the system share sheet — or a copy of
                        // the same text to the clipboard, so the user
                        // can paste it straight into a message.
                        Menu {
                            Button("导出日志文件") { exportAndShare() }
                            Button("复制日志文本") { copyLogs() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    // No clear button: the old trash button only
                    // emptied the in-memory list and the rows came
                    // back on the next refresh from the extension
                    // snapshot (audit B27). FlClash has no clear
                    // button either — only export.
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if tab == .logs {
                                loadPersistedReports()
                                await logStore.refresh()
                            } else { await eventStore.refresh() }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
            .sheet(item: $selectedEntry) { entry in
                LogEntryDetailView(entry: entry)
            }
            .alert("已复制", isPresented: $showCopiedAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("日志已复制到剪贴板，可以直接粘贴发送。")
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "未知错误")
            }
            .refreshable {
                if tab == .logs {
                    loadPersistedReports()
                    await logStore.refresh()
                } else { await eventStore.refresh() }
            }
            // Live feed (audit B26/B35): poll the active tab every
            // 1 s like FlClash, only while this page is visible.
            // The old `guard TunnelManager.isRunning` stopped all
            // polling with the VPN off — but the app core runs (and
            // logs) without the tunnel, so LogStore.refresh() now
            // reads the app core's log.watch buffer when it is up
            // and no-ops when neither core runs (Issue 2). The
            // events tab still only polls while the tunnel runs —
            // its stream is extension-only. The task restarts when
            // the tab changes (id: tab) and is cancelled when the
            // page disappears. New rows auto-scroll via the onChange
            // handlers on each list.
            .task(id: tab) {
                loadPersistedReports()
                if tab == .logs {
                    if logStore.entries.isEmpty { await logStore.refresh() }
                } else if eventStore.entries.isEmpty {
                    await eventStore.refresh()
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    if tab == .logs {
                        await logStore.refresh()
                    } else if TunnelManager.shared.isRunning {
                        await eventStore.refresh()
                    }
                }
            }
    }

    /// Reads the persisted diagnostics AppCore wrote to disk
    /// (boot report + last delay-test report). They do not need
    /// the tunnel running, so the Logs page can show them while
    /// the VPN is off and the live list is empty.
    private func loadPersistedReports() {
        bootReport = AppCore.lastBootReportText()
        delayReport = AppCore.lastDelayTestReportText()
    }

    /// Compact bounded empty state (FlClash NullStatus): a small
    /// icon + two lines, fixed height — the diagnostics below sit
    /// right under the filters instead of a giant gap.
    private var compactEmptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无日志")
                .font(.headline)
            Text("日志级别或搜索条件可能过滤掉了全部条目")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Persisted diagnostics (v0.2.40): when the live list is
    /// empty — no core running, or the level/search filter hides
    /// every row — show the reports AppCore already wrote to disk
    /// ABOVE the compact empty state (v0.2.49: the user wants the
    /// text right under the filters, the empty block at the
    /// bottom), instead of a blank page.
    /// "暂无记录" when a report was never written.
    @ViewBuilder
    private var persistedDiagnosticsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            diagnosticsBlock(title: "应用内核心启动诊断", text: bootReport)
            diagnosticsBlock(title: "最近一次测速诊断", text: delayReport)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func diagnosticsBlock(title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let text = text, !text.isEmpty {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("暂无记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Writes the bundled log export to a .txt file and opens the
    /// system share sheet for it. Sharing is user-initiated only;
    /// nothing is uploaded anywhere by the app itself.
    private func exportAndShare() {
        do {
            // Connection diagnostics for the export (v0.2.60):
            // failed dials + recently ended connections.
            logStore.connectionDiagnosticText = connectionStore.diagnosticExportText
            exportURL = try logStore.exportLogFile()
            showShare = true
        } catch {
            exportError = error.localizedDescription
            showExportError = true
        }
    }

    /// Copies the same bundled export text to the clipboard, so the
    /// user can paste it straight into a chat message.
    private func copyLogs() {
        logStore.connectionDiagnosticText = connectionStore.diagnosticExportText
        UIPasteboard.general.string = logStore.fullExportText
        showCopiedAlert = true
    }

    /// One log row (shared by the core list and the VPN diagnostic
    /// section). C8: a row opens its detail sheet (full text,
    /// selectable, with copy); the list itself still truncates.
    /// L-D3: the level pill is tappable and adds a level filter,
    /// like upstream (logs.dart:256-259); tapping the rest of the
    /// row opens the detail sheet.
    private func logRow(_ entry: ConcordLogEntry, selectedEntry: Binding<ConcordLogEntry?>) -> some View {
        Button {
            selectedEntry.wrappedValue = entry
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(ConcordFormat.time(entry.time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Button {
                    // "WARN" and "WARNING" are the same level.
                    let level = entry.level.uppercased() == "WARN" ? "WARNING" : entry.level.uppercased()
                    if let filter = LogLevelFilter(rawValue: level) {
                        logStore.levelFilter = filter
                    }
                } label: {
                    Text(entry.level.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(levelColor(entry.level).opacity(0.15), in: Capsule())
                        .foregroundStyle(levelColor(entry.level))
                }
                .buttonStyle(.plain)
                logBody(entry)
            }
        }
        .buttonStyle(.plain)
        .id(entry.id)
        .onAppear { if entry.id == logStore.filtered.last?.id { followingLogs = true } }
        .onDisappear { if entry.id == logStore.filtered.last?.id { followingLogs = false } }
    }

    /// Parsed route body (L-M2, upstream logs.dart _LogBody):
    /// destination as the title, the error in the error colour,
    /// `rule → proxy`, and the tag/source line. A line that does not
    /// match the route/dial patterns falls back to the raw text.
    @ViewBuilder
    private func logBody(_ entry: ConcordLogEntry) -> some View {
        let payload = LogPayload.parse(entry.text)
        if let route = payload.route {
            VStack(alignment: .leading, spacing: 1) {
                Text(route.destination)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !route.error.isEmpty {
                    Text(route.error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                HStack(spacing: 0) {
                    if !route.rule.isEmpty {
                        Text(route.rule)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(" → ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(route.proxy)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(ConcordTheme.accent)
                }
                .lineLimit(1)
                let sourceText = [payload.tag, route.source, route.sourceDetail]
                    .filter { !$0.isEmpty }.joined(separator: "  ·  ")
                if !sourceText.isEmpty {
                    Text(sourceText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.message)
                    .font(.caption2)
                    .lineLimit(3)
                if !payload.tag.isEmpty {
                    Text(payload.tag)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR": return .red
        case "WARNING": return .orange
        case "DEBUG": return .purple
        default: return .green
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "fatal": return .red
        case "resourceUpdate": return .blue
        case "delay": return .green
        case "stateChanged": return .orange
        case "dialerLoop": return .purple
        default: return .secondary
        }
    }
}

enum LogsTab: String, CaseIterable {
    case logs = "日志"
    case events = "事件"
}

/// One log row, full text selectable, with a copy button (C8):
/// the list truncates rows to 3 lines, so long rows are only
/// fully readable here.
private struct LogEntryDetailView: View {
    let entry: ConcordLogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(ConcordFormat.time(entry.time)) · \(entry.level.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = "[\(ConcordFormat.time(entry.time))] \(entry.level.uppercased()) \(entry.text)"
                        copied = true
                    }
                }
            }
            .navigationTitle("日志详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// Minimal share sheet (UIActivityViewController wrapper).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Parsed log line (upstream lib/common/log_payload.dart, mirroring
/// the wording of the routing and dial-failure lines in mihomo's
/// tunnel/tunnel.go): a `[TAG] message` line whose message matches a
/// route or dial pattern yields destination / rule → proxy / error /
/// source; a line that stops matching falls back to plain text.
private struct LogPayload {
    struct Route {
        let source: String
        let sourceDetail: String
        let destination: String
        let rule: String
        let proxy: String
        let error: String
    }

    let tag: String
    let message: String
    let route: Route?

    private static let endpoint = #"((?:\[[^\]]+\]|[^\s\[\]()]+):\d+|mihomo)(?:\((.*)\))?"#

    private static func regex(_ pattern: String, dotAll: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: pattern,
            options: dotAll ? [.dotMatchesLineSeparators] : [])
    }

    private static let tagRegex = regex(#"^\[([^\]]+)\] (.+)$"#, dotAll: true)

    private static var routeRegex: NSRegularExpression? {
        regex("^" + endpoint + #" --> (\S+) (?:(?:match (.+?)|(doesn't match any rule)) )?using (.+)$"#)
    }

    private static var dialRegex: NSRegularExpression? {
        regex(#"^dial (.+?) (?:\(match (.+?)\) )?"# + endpoint + #" --> (\S+) error: (.+)$"#, dotAll: true)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    static func parse(_ payload: String) -> LogPayload {
        let fullRange = NSRange(payload.startIndex..., in: payload)
        guard let tagMatch = tagRegex?.firstMatch(in: payload, range: fullRange) else {
            return LogPayload(tag: "", message: payload, route: nil)
        }
        let tag = group(tagMatch, 1, in: payload)
        let message = group(tagMatch, 2, in: payload)
        return LogPayload(tag: tag, message: message, route: parseRoute(message))
    }

    private static func parseRoute(_ message: String) -> Route? {
        let range = NSRange(message.startIndex..., in: message)
        if let match = routeRegex?.firstMatch(in: message, range: range) {
            let rule = group(match, 4, in: message)
            return Route(
                source: group(match, 1, in: message),
                sourceDetail: group(match, 2, in: message),
                destination: group(match, 3, in: message),
                rule: rule.isEmpty ? group(match, 5, in: message) : rule,
                proxy: group(match, 6, in: message),
                error: "")
        }
        if let match = dialRegex?.firstMatch(in: message, range: range) {
            return Route(
                source: group(match, 3, in: message),
                sourceDetail: group(match, 4, in: message),
                destination: group(match, 5, in: message),
                rule: group(match, 2, in: message),
                proxy: group(match, 1, in: message),
                error: group(match, 6, in: message))
        }
        return nil
    }
}
