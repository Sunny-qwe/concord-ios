import SwiftUI
import UIKit

// MARK: - Logs (FlClash: LogsView, lib/views/logs.dart)
// FlClash logs page: level filter, search, auto-scroll and export
// (no clear button — the rows come from the extension snapshot, so
// clearing the in-memory list would only fake it). Backed by Concord
// log.watch (stream of LogEntry) and core.lastWarnings.
//
// v0.2.139: upstream has NO Events page at all — the 日志/事件 segment
// is deleted (user reversal 2026-11-27 ~00:12, "三处都改回上游的样子").
// This is now the Logs-only page. The EventStore class and the
// events.watch stream stay for the script-notification banner
// (ScriptNotificationBanner) and Dashboard refreshes; only the tab
// UI and its store API are gone.

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var exportError: String?
    @State private var showExportError = false
    @State private var showExportSuccess = false
    @State private var exportedFileName: String?
    @State private var showCopiedAlert = false
    @Environment(\.dismiss) private var dismiss
    /// The log row tapped for its detail sheet (C8).
    @State private var selectedEntry: ConcordLogEntry?
    /// Persisted diagnostics (v0.2.40): AppCore writes the boot
    /// report and the last delay-test report to disk; they do not
    /// need the tunnel running, so the Logs page shows them while
    /// the VPN is off and the live list is empty.
    @State private var bootReport: String?
    @State private var delayReport: String?
    /// v0.2.139 (L-D6): the one-time scroll that opens the page at
    /// the newest row. The list itself stays pinned to the bottom
    /// through `.defaultScrollAnchor(.bottom)` (see below); this
    /// flag only covers the first population, when the anchor has
    /// no content change to maintain yet.
    @State private var didInitialScroll = false

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
                        Text("日志为示例数据")
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
                    TextField("搜索日志", text: $logStore.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !logStore.searchText.isEmpty {
                        Button {
                            logStore.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 4)

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
                    // v0.2.111: this card only — radius 20, not the
                    // global cardRadius 28 (user: 核心警告 card too
                    // round). Same fill + padding + shadow as
                    // .concordCard, only the corner radius differs.
                    .padding(12)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
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
                        ZStack(alignment: .trailing) {
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
                            // v0.2.139 (L-M3): the page provides its
                            // own floating scrollbar (below), so the
                            // system indicator is hidden.
                            .scrollIndicators(.hidden)
                            // v0.2.139 (L-D6): upstream's `reverse:
                            // true` — the list is anchored at the
                            // bottom (newest) and new rows pin it
                            // there while the user is at the end,
                            // without a scrollTo on every update
                            // (SwiftUI's native equivalent of
                            // FollowEndScrollPhysics). The one-time
                            // scroll below covers the first
                            // population, when the anchor has no
                            // content change to maintain yet.
                            .defaultScrollAnchor(.bottom)
                            // v0.2.66: tab-bar clearance for pushed pages.
                            .contentMargins(.bottom, ConcordTheme.tabBarClearance)
                            .onAppear { scrollToNewestOnce(proxy) }
                            .onChange(of: logStore.filtered.count) { _, _ in
                                scrollToNewestOnce(proxy)
                            }
                            // v0.2.139 (L-M3): floating scrollbar
                            // with a time hint (upstream
                            // FloatingScrollbar + hintBuilder).
                            if !logStore.filtered.isEmpty {
                                LogsFloatingScrollbar(entries: logStore.filtered, proxy: proxy)
                            }
                        }
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
                        // v0.2.86 (item 9): upstream logs.dart
                        // _buildMenuItems puts the CORE log level
                        // in the same bar menu as a submenu
                        // (label = logLevel, subtitle = current
                        // level, checked row = active option) and
                        // writes it via patchClashConfig. This
                        // submenu mirrors it: same label
                        // ("日志等级", arb/intl_zh.arb:122) and
                        // same option names (LogLevel raw values
                        // = Dart enum .name). Unlike the filter
                        // above (display-only, LogStore), a pick
                        // here writes SettingsStore.logLevel —
                        // the .onChange below saves it and
                        // patches the running core. Upstream
                        // default is error; ours stays info.
                        Menu("日志等级") {
                            Picker("日志等级", selection: $settingsStore.logLevel) {
                                ForEach(LogLevel.allCases) { level in
                                    Text(level.rawValue).tag(level)
                                }
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
                    // written to Documents ("文件" App) with a
                    // success dialog — or a copy of the same text
                    // to the clipboard, so the user can paste it
                    // straight into a message.
                    Menu {
                        Button("导出日志文件") { exportLogFile() }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            loadPersistedReports()
                            await logStore.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            // v0.2.86 (item 9): the log-level submenu above writes
            // SettingsStore.logLevel; persist it (UserDefaults +
            // general.json, so the extension picks it up at the
            // next VPN start) and patch the running core — the
            // same save + applyGeneralToCore pair the Settings
            // page's "应用通用设置到核心" button uses, and the
            // same .onChange pattern DashboardView uses for mode.
            // With the VPN off applyGeneralToCore returns early
            // by design (it guards on TunnelManager.isRunning),
            // so the level is only saved then; the running
            // in-app overlay core gets no live patch either —
            // AppCore only observes unifiedDelay, never
            // logLevel — so the new level reaches a core at the
            // next VPN start (extension) or not at all for the
            // overlay until a live-patch channel is added.
            .onChange(of: settingsStore.logLevel) { _, _ in
                settingsStore.save()
                Task { await settingsStore.applyGeneralToCore() }
            }
            .sheet(item: $selectedEntry) { entry in
                LogEntryDetailView(entry: entry)
                    // Ours-only detail view (no upstream detail):
                    // stays a sheet, with the upstream snap detents
                    // [9/16, 0.9] and a drag handle.
                    .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                    .presentationDragIndicator(.visible)
            }
            .alert("已复制", isPresented: $showCopiedAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("日志已复制到剪贴板，可以直接粘贴发送。")
            }
            // Upstream _handleExport writes the file to disk, then
            // showAlert "exportSuccess" (logs.dart:115-128) — no
            // share sheet.
            .alert("导出成功", isPresented: $showExportSuccess) {
                Button("好", role: .cancel) {}
            } message: {
                Text("日志已保存到「文件」：\(exportedFileName ?? "")")
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "未知错误")
            }
            .refreshable {
                loadPersistedReports()
                await logStore.refresh()
            }
            // Live feed (audit B26/B35): poll every 1 s like
            // FlClash, only while this page is visible. The old
            // `guard TunnelManager.isRunning` stopped all
            // polling with the VPN off — but the app core runs (and
            // logs) without the tunnel, so LogStore.refresh() now
            // reads the app core's log.watch buffer when it is up
            // and no-ops when neither core runs (Issue 2).
            .task {
                loadPersistedReports()
                if logStore.entries.isEmpty { await logStore.refresh() }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    await logStore.refresh()
                }
            }
    }

    /// Opens the page at the newest row, once: the first time the
    /// list is populated (or on appear when it already holds rows).
    /// Deferred to the next runloop (v0.2.82: never scroll
    /// synchronously inside onChange/layout).
    private func scrollToNewestOnce(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, let last = logStore.filtered.last else { return }
        didInitialScroll = true
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
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
        .concordCard(padding: 12)
    }

    /// Writes the bundled log export to a .txt file in Documents
    /// (visible in the Files app) and shows a success dialog.
    /// Upstream _handleExport (logs.dart:115-128): write to disk,
    /// then showAlert "exportSuccess" — no share sheet.
    private func exportLogFile() {
        do {
            // Connection diagnostics for the export (v0.2.60):
            // failed dials + recently ended connections.
            logStore.connectionDiagnosticText = connectionStore.diagnosticExportText
            let tmpURL = try logStore.exportLogFile()
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let dest = docs.appendingPathComponent(tmpURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                exportedFileName = dest.lastPathComponent
            } else {
                exportedFileName = tmpURL.lastPathComponent
            }
            showExportSuccess = true
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
    ///
    /// v0.2.128 item 4: the row was a Button containing a nested
    /// Button (the level pill). A Button inside a Button makes the
    /// List mis-measure the cell height, so multi-line rows
    /// overlapped and the text garbled (video 1). The row is now
    /// a plain HStack with an onTapGesture (detail) and the pill
    /// is the only Button (level filter).
    private func logRow(_ entry: ConcordLogEntry, selectedEntry: Binding<ConcordLogEntry?>) -> some View {
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
            // v0.2.128 item 4: the body takes its ideal height, so
            // the List cannot compress a multi-line row into a
            // single-line cell (the overlap in video 1). The width
            // stays flexible so the text wraps to the row.
            logBody(entry)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEntry.wrappedValue = entry
        }
        .id(entry.id)
    }

    /// Parsed route body (L-M2, upstream logs.dart _LogBody):
    /// destination as the title, the error in the error colour,
    /// `rule → proxy`, and the tag/source line. A line that does not
    /// match the route/dial patterns falls back to the raw text.
    @ViewBuilder
    private func logBody(_ entry: ConcordLogEntry) -> some View {
        let payload = LogPayload.parse(entry.text)
        if let route = payload.route {
            VStack(alignment: .leading, spacing: 2) {
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
            VStack(alignment: .leading, spacing: 2) {
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
}

/// Floating scrollbar with a time hint (upstream logs.dart
/// FloatingScrollbar + hintBuilder, and record_feed.dart
/// `recordAtFraction`: the hint is the date-time of the log at the
/// dragged fraction of the list; dragging scrubs the list there).
/// SwiftUI's List exposes no scroll offset on iOS 17
/// (`.onScrollGeometryChange` is iOS 18+), so the thumb does NOT
/// track manual list scrolling — it rests at the last scrub
/// position (initially the bottom = newest). Tapping the track
/// jumps the list to that fraction, like upstream's scrollbar.
private struct LogsFloatingScrollbar: View {
    let entries: [ConcordLogEntry]
    let proxy: ScrollViewProxy

    /// Thumb position, 0 = top (oldest) … 1 = bottom (newest).
    @State private var fraction: CGFloat = 1
    @State private var hint: String?
    @State private var scrubbing = false
    @State private var hideToken = 0
    @State private var lastScrubScroll = Date.distantPast

    private static let thumbHeight: CGFloat = 56
    private static let stripWidth: CGFloat = 28

    /// The log at the current fraction (upstream recordAtFraction).
    private var hintEntry: ConcordLogEntry? {
        guard !entries.isEmpty else { return nil }
        let index = Int((fraction * CGFloat(entries.count - 1)).rounded())
        return entries[max(0, min(entries.count - 1, index))]
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let thumbY = fraction * max(0, height - Self.thumbHeight)
            ZStack(alignment: .trailing) {
                // Track: transparent hit strip at the trailing edge.
                // minimumDistance 0, so a tap on the track jumps
                // the list to that fraction; a drag scrubs it.
                Color.clear
                    .frame(width: Self.stripWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrubbing = true
                                let y = value.location.y - Self.thumbHeight / 2
                                fraction = min(1, max(0, y / max(1, height - Self.thumbHeight)))
                                hint = hintEntry.map { Self.fullDateTime($0.time) }
                                scrub(to: hintEntry, force: false)
                            }
                            .onEnded { _ in
                                scrub(to: hintEntry, force: true)
                                let token = hideToken + 1
                                hideToken = token
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    if hideToken == token {
                                        scrubbing = false
                                        hint = nil
                                    }
                                }
                            }
                    )
                // Thumb + hint pill. Hit-testing off: the track
                // above owns the touches in this strip.
                VStack(alignment: .trailing, spacing: 0) {
                    Spacer().frame(height: thumbY)
                    HStack(spacing: 8) {
                        if scrubbing, let hint {
                            Text(hint)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                        }
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(scrubbing ? 0.9 : 0.55))
                            .frame(width: 5, height: Self.thumbHeight)
                    }
                    .padding(.trailing, (Self.stripWidth - 5) / 2)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Scrolls to the entry at the current fraction, throttled
    /// while scrubbing (v0.2.82: never scroll synchronously inside
    /// a gesture/layout pass — defer to the next runloop).
    private func scrub(to entry: ConcordLogEntry?, force: Bool) {
        guard let entry else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastScrubScroll) > 0.1 else { return }
        lastScrubScroll = now
        DispatchQueue.main.async {
            proxy.scrollTo(entry.id, anchor: .top)
        }
    }

    /// Full date-time for the hint ("2026-11-26 23:15:29"):
    /// DateFormatter setup is expensive, so one instance serves
    /// every call (main thread only — all callers are view code).
    private static let fullDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func fullDateTime(_ epochMillis: Int64) -> String {
        fullDateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
    }
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

    private static let routeRegex: NSRegularExpression? = regex("^" + endpoint + #" --> (\S+) (?:(?:match (.+?)|(doesn't match any rule)) )?using (.+)$"#)

    private static let dialRegex: NSRegularExpression? = regex(#"^dial (.+?) (?:\(match (.+?)\) )?"# + endpoint + #" --> (\S+) error: (.+)$"#, dotAll: true)

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
