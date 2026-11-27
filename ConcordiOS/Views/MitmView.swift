import SwiftUI
import UIKit

// MARK: - MITM capture (FlClash: MITM requests page)
// One connection's captured exchanges (upstream
// lib/features/connection/mitm_exchanges.dart MitmExchangesView):
// the page is pushed from a connection, never opened standalone.
// Rows show path + query only (upstream `exchangePathOf`); tapping
// one opens the detail (mitm.exchange) and reads its request /
// response body (mitm.body). Scripts run only from a module's
// script lines — there is no run-script box here (upstream
// mitm_modules.dart:42-56).
// The cross-connection search (mitm.query) lives on the Requests
// page's HTTP segment (upstream RequestsView), not here — the
// per-connection tab lists only this connection's exchanges.
// The exchange context menu (copy / export / add-rule) is
// MitmExchangeMenuButtons at the bottom of this file (upstream
// lib/features/connection/mitm_exchange_menu.dart).

/// Renders open JSON (proxy definitions, exchange details, script
/// results) as pretty-printed monospaced text.
struct JSONValueView: View {
    let value: JSONValue

    var body: some View {
        ScrollView {
            Text(value.prettyPrinted)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}

struct MitmView: View {
    @EnvironmentObject private var mitmStore: MitmStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var moduleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    /// The exchange context menu's state (privacy warning, HAR
    /// share, add-rule editor) — one model for this page's rows.
    @StateObject private var menuModel = MitmExchangeMenuModel()

    /// The one connection this page shows (upstream
    /// MitmExchangesView(trackerInfo)). The page is pushed from a
    /// connection; there is no standalone entry point.
    let connectionId: UInt64
    @State private var detailSummary: MitmExchangeSummary?

    init(connectionId: UInt64) {
        self.connectionId = connectionId
    }

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("拦截记录为示例数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            // This connection's exchanges (upstream MitmExchangesView):
            // one connection at a time, newest first — no
            // all-connections feed, no connection-id field.
            Section {
                if mitmStore.isLoadingExchanges {
                    ProgressView()
                }
                if mitmStore.capturing {
                    Text("正在捕获")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let message = mitmStore.exchangesMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                // Capture off (audit B46): the switch lives on the
                // settings page — offer it right here instead of a
                // dead end.
                if mitmStore.exchangesMessage?.contains("未开启") == true {
                    captureOffBanner
                }
                ForEach(mitmStore.exchanges) { exchange in
                    Button { detailSummary = exchange } label: {
                        exchangeRow(exchange)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        MitmExchangeMenuButtons(summary: exchange, model: menuModel)
                    }
                }
            } footer: {
                // Upstream `missing`: this connection began before
                // capture started, so requests from before `since`
                // are not in this list (see MitmStore).
                if mitmStore.exchangesMissingNotice {
                    Text("抓包开启前发出或已被清除的请求不在列表中。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .mitmExchangeMenuOverlays(menuModel, moduleStore: moduleStore)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("MITM 拦截")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await mitmStore.loadExchanges(connection: connectionId, noHosts: httpCaptureNoHosts) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $detailSummary) { summary in
            MitmExchangeDetailView(summary: summary)
                // Upstream tap → showInSheet(MitmExchangeView):
                // snap sheet [9/16, 0.9] with a drag handle, scrim
                // dismiss (mitm_exchanges.dart:159).
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
        .task {
            await mitmStore.loadExchanges(connection: connectionId, noHosts: httpCaptureNoHosts)
            // Upstream mitmExchangesProvider: re-fetch every 2 s
            // until the connection closed and nothing is pending;
            // the task is cancelled when the page disappears.
            while !Task.isCancelled && !mitmStore.exchangesSettled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, !mitmStore.exchangesSettled else { break }
                await mitmStore.loadExchanges(connection: connectionId, quiet: true, noHosts: httpCaptureNoHosts)
            }
        }
    }

    /// Upstream httpCaptureHasNoHost (http_capture.dart:10-12):
    /// no listed host and no enabled module — capture records
    /// nothing. Hostnames are the comma-separated mitmHostnames;
    /// a "-" line excludes a host, so only a non-empty line that
    /// does not start with "-" counts as a host (an empty list
    /// counts as no host, like upstream's `every` on an empty list).
    private var httpCaptureNoHosts: Bool {
        guard !moduleStore.modules.contains(where: { $0.enabled }) else { return false }
        let hosts = settingsStore.mitmHostnames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hosts.allSatisfy { $0.hasPrefix("-") }
    }

    /// The capture switch lives in the MITM options page
    /// (进阶配置 → MITM → 选项， the "抓包" status row,
    /// mitm.json `capture`): when capturing is off this page would
    /// otherwise be a dead end (audit B46). v0.2.137: the in-page
    /// toggle is gone (upstream's capture control lives only on
    /// the capture settings page) — the banner only explains where
    /// to turn it on.
    private var captureOffBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MITM 捕获未开启：拦截记录不会保存。")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("在「进阶配置 → MITM → 选项」里点「抓包」开启；开启后下次启动 VPN（或重新应用配置）生效；最多保留 \(settingsStore.mitmCaptureEntries) 条。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// One captured exchange (upstream MitmExchangesView's
    /// _MitmExchangeItem): the title is path + query only
    /// (`exchangePathOf`); the subtitle is the method plus the
    /// outcome — status (red ≥400, green 2xx), error, pending, or
    /// response size + duration + rewrite mark. No time column.
    private func exchangeRow(_ exchange: MitmExchangeSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exchangePathOf(exchange.url))
                    .font(.footnote)
                    .lineLimit(1)
                exchangeSubtitle(exchange)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// The subtitle of one exchange row: method, then the outcome
    /// parts upstream joins with " · ".
    private func exchangeSubtitle(_ exchange: MitmExchangeSummary) -> Text {
        var text = Text(exchange.method)
        if exchange.status != 0 {
            text = text + Text(" · ") + Text("\(exchange.status)")
                .foregroundStyle(exchange.status >= 400 ? .red : (exchange.status >= 200 && exchange.status < 300 ? .green : .secondary))
        }
        if let error = exchange.error, !error.isEmpty {
            text = text + Text(" · ") + Text(error).foregroundStyle(.red)
        } else if exchange.pending ?? false {
            text = text + Text(" · ") + Text("进行中")
        } else {
            text = text + Text(" · ↓ \(ConcordFormat.bytes(exchange.responseSize))")
            text = text + Text(" · \(httpMillisText(exchange.duration))")
            if let mark = exchangeMark(exchange) {
                text = text + Text(" · \(mark)")
            }
        }
        return text
    }

    /// The rewrite mark upstream appends to a finished exchange
    /// (`exchangeMark`): the answer label, or the first action kind's
    /// label, plus how many other actions there are.
    private func exchangeMark(_ exchange: MitmExchangeSummary) -> String? {
        if let answer = exchange.answer {
            let answerKind: String = {
                switch answer {
                case .reject, .redirect: return "url-rewrite"
                case .mapLocal: return "map-local"
                case .script: return "script"
                }
            }()
            let others = (exchange.actionKinds ?? []).filter { $0 != answerKind }.count
            return others > 0 ? "\(answer.label) +\(others)" : answer.label
        }
        guard let kinds = exchange.actionKinds, !kinds.isEmpty else { return nil }
        let label = MitmExchangeAction.kindLabel(for: kinds[0])
        return kinds.count > 1 ? "\(label) +\(kinds.count - 1)" : label
    }

    /// The row title: path + query only (upstream `exchangePathOf`).
    /// No authority → the whole URL.
    private func exchangePathOf(_ url: String) -> String {
        guard let parsed = URL(string: url), parsed.host != nil else { return url }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        if let query = parsed.query { return "\(path)?\(query)" }
        return path
    }

    /// The duration as upstream shows it (`httpMillisText`).
    private func httpMillisText(_ millis: Int64) -> String {
        millis < 1000 ? "\(millis) ms" : String(format: "%.1f s", Double(millis) / 1000)
    }
}

// MARK: - Standalone capture list (v0.2.153)

// The "MITM 拦截记录" entry cut in v0.2.141 pointed at
// MitmView(), but MitmView is per-connection only since the
// v0.2.143 rebuild (init(connectionId:) — no standalone init,
// and mitm.exchanges needs a connection id). The standalone
// list is the same feed upstream's Requests page shows: the
// cross-connection mitm.query (MitmStore.runQuery), newest
// first, with the same search / paging / detail / context menu
// as the Connections HTTP segment. It shares MitmStore with
// that segment (one store, one query state). There is NO 1 s
// poll here, unlike the Connections segment: ContentView's
// slidingTabView keeps all four tab pages mounted (off-screen
// HStack / opacity-0 ZStack), so a .task loop in this page
// would keep running on other tabs and fight the Connections
// poll over the shared query state (search wipe, paging
// reset). The live feed stays on the Connections page; this
// list refreshes on appear, on search submit, on
// pull-to-refresh, and on the toolbar button.

struct MitmCaptureListView: View {
    @EnvironmentObject private var mitmStore: MitmStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var moduleStore: MitmModuleStore
    /// The exchange context menu's state — same model as MitmView.
    @StateObject private var menuModel = MitmExchangeMenuModel()
    @State private var detailSummary: MitmExchangeSummary?

    var body: some View {
        Group {
            if mitmStore.isQuerying && mitmStore.queryResults.isEmpty {
                ProgressView("正在加载拦截记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mitmStore.queryResults.isEmpty {
                ContentUnavailableView("暂无拦截记录", systemImage: "eye.slash", description: Text(httpCaptureNoHosts ? "在“主机名”中添加主机后才会记录。" : (mitmStore.queryMessage ?? "开启抓包后，这里列出全部连接的拦截记录")))
            } else {
                VStack(spacing: 0) {
                    if let matched = mitmStore.queryMatched, let held = mitmStore.queryHeld {
                        Text("共 \(matched) 条匹配（已保留 \(held) 条）· 已加载 \(mitmStore.queryResults.count) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    // v0.2.153 audit N2: a fresh query clears this
                    // when results arrive, so a message here means
                    // the "加载更多" page failed — show it instead
                    // of failing silently.
                    if let message = mitmStore.queryMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    List {
                        ForEach(mitmStore.queryResults) { exchange in
                            Button { detailSummary = exchange } label: {
                                httpExchangeRow(exchange)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                MitmExchangeMenuButtons(summary: exchange, model: menuModel)
                            }
                            .listRowBackground(ConcordTheme.cardBackground)
                        }
                        if mitmStore.queryNext != nil {
                            Button("加载更多") {
                                Task { await mitmStore.runQuery(loadMore: true) }
                            }
                            .disabled(mitmStore.isQuerying)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await mitmStore.runQuery()
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .mitmExchangeMenuOverlays(menuModel, moduleStore: moduleStore)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("MITM 拦截记录")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $mitmStore.queryText, prompt: "搜索 URL、方法、内容类型或应用")
        .onSubmit(of: .search) {
            Task { await mitmStore.runQuery() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await mitmStore.runQuery() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $detailSummary) { summary in
            MitmExchangeDetailView(summary: summary)
                // Same snap sheet as MitmView / ConnectionsView.
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
        .task {
            // No 1 s poll: the tab pages stay mounted, so a loop
            // here would fight the Connections poll over the
            // shared MitmStore state (see the header comment).
            // Refresh is on appear, on search submit, on
            // pull-to-refresh, and on the toolbar button.
            await mitmStore.runQuery()
        }
    }

    /// Upstream httpCaptureHasNoHost (http_capture.dart:10-12) —
    /// same computation as MitmView's: no listed host and no
    /// enabled module means capture records nothing.
    private var httpCaptureNoHosts: Bool {
        guard !moduleStore.modules.contains(where: { $0.enabled }) else { return false }
        let hosts = settingsStore.mitmHostnames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hosts.allSatisfy { $0.hasPrefix("-") }
    }

    /// One cross-connection row — same shape as the Connections
    /// HTTP segment's row (method + host/path, status + time):
    /// unlike MitmView's per-connection rows, this list spans
    /// connections, so it shows the host too.
    private func httpExchangeRow(_ exchange: MitmExchangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(exchange.method)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Text(exchange.host ?? "")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if exchange.status > 0 {
                    Text("\(exchange.status)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(exchange.status >= 400 ? .red : .secondary)
                }
            }
            HStack(spacing: 6) {
                Text(exchange.path ?? "/")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(ConcordFormat.time(rfc3339: exchange.start))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = exchange.error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Exchange detail (mitm.exchange / mitm.body)

struct MitmExchangeDetailView: View {
    let summary: MitmExchangeSummary
    @EnvironmentObject private var mitmStore: MitmStore
    @EnvironmentObject private var moduleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    @Environment(\.dismiss) private var dismiss
    @State private var bodyKind: BodyKind = .request
    /// The exchange context menu's state (privacy warning, HAR
    /// export notice, add-rule editor) for this detail page.
    @StateObject private var menuModel = MitmExchangeMenuModel()

    enum BodyKind: String, CaseIterable, Identifiable {
        case request = "请求正文"
        case response = "响应正文"
        var id: String { rawValue }
    }

    /// The full exchange when mitm.exchange answered (headers,
    /// original URL, protocol, TTFB, matched actions); nil while
    /// it loads or when the open JSON does not decode as one.
    private var detail: MitmExchangeDetail? { mitmStore.exchangeDetailTyped }

    /// Status with the response reason phrase when the core sent
    /// one (upstream 9d1f485, b678d79): e.g. "200 OK".
    private var statusText: String {
        if summary.pending ?? false { return "进行中" }
        if let reason = detail?.reason, !reason.isEmpty {
            return "\(summary.status) \(reason)"
        }
        return "\(summary.status)"
    }

    /// The loaded side's Content-Type, for body rendering.
    private var bodyContentType: String {
        detail?.headerValue("Content-Type", response: bodyKind == .response) ?? ""
    }

    /// The body, rendered by its content type (upstream
    /// MitmBodySection / readMitmBody): JSON is pretty-printed,
    /// images preview, anything that is not UTF-8 text gets the
    /// honest note it used to get. The footer names an encoding
    /// the core could not undo, or that only the start was kept.
    private var bodyDisplay: (text: String, imageData: Data?, footer: String?) {
        guard let body = mitmStore.exchangeBody else { return ("尚未加载正文", nil, nil) }
        let bytes = Data(base64Encoded: body.data) ?? Data()
        var footer: [String] = []
        if let encoding = body.encoding, !encoding.isEmpty {
            footer.append("正文是 \(encoding) 编码，未解码")
        } else if body.truncated == true {
            footer.append("只记录了这段内容的开头部分。")
        }
        let footerText = footer.isEmpty ? nil : footer.joined(separator: "\n")
        let mime = bodyContentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if mime.hasPrefix("image/") && !mime.contains("svg") {
            return ("", bytes, footerText)
        }
        if let text = mitmBodyText(bytes, truncated: body.truncated == true) {
            let shown = mime.contains("json") ? prettyJSON(text) : text
            return (shown, nil, footerText)
        }
        return ("正文不是 UTF-8 文本（\(bytes.count) 字节\(body.truncated == true ? "，已截断" : "")）", nil, footerText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("请求") {
                    LabeledContent("开始时间", value: ConcordFormat.time(rfc3339: summary.start))
                    LabeledContent("方法", value: summary.method)
                    LabeledContent("URL", value: summary.url)
                    if let original = detail?.originalUrl, !original.isEmpty, original != summary.url {
                        LabeledContent("原始 URL", value: original)
                    }
                    if let proto = detail?.proto, !proto.isEmpty {
                        LabeledContent("协议", value: proto)
                    }
                    LabeledContent("状态", value: statusText)
                    // Upstream 9d1f485 (b678d79): what answered it
                    // in place of its server; nil = went to the server.
                    if let answer = summary.answer {
                        LabeledContent("应答", value: answer.label)
                    } else if !(summary.pending ?? false), summary.status != 0 {
                        LabeledContent("应答", value: "服务器")
                    }
                    // Upstream 9d1f485 (b678d79): the kinds of the
                    // actions that acted on it, each once.
                    if let kinds = summary.actionKinds, !kinds.isEmpty {
                        LabeledContent("处理动作", value: kinds.map { MitmExchangeAction.kindLabel(for: $0) }.joined(separator: "、"))
                    }
                    if summary.status != 0, let ttfb = detail?.ttfb {
                        LabeledContent("首字节时间", value: "\(ttfb) ms")
                    }
                    LabeledContent("耗时", value: "\(summary.duration) ms")
                    LabeledContent("上行", value: ConcordFormat.bytes(summary.requestSize))
                    LabeledContent("下行", value: ConcordFormat.bytes(summary.responseSize))
                    if let error = summary.error, !error.isEmpty {
                        LabeledContent("错误", value: error)
                    }
                }
                // Upstream DetailTabs `matchedRules`: which
                // rewrite / script / map-local acted, per phase.
                if let actions = detail?.actions, !actions.isEmpty {
                    Section("匹配的规则") {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            HStack {
                                Text(action.kindLabel)
                                Spacer()
                                if let phase = action.phaseLabel {
                                    Text(phase)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                                if let text = action.detail, !text.isEmpty {
                                    Text(text)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let module = action.module, !module.isEmpty {
                                    Text(module)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let detail {
                    headerSection(title: "请求头", headers: detail.sortedHeaders(response: false))
                    headerSection(title: "响应头", headers: detail.sortedHeaders(response: true))
                }
                Section("正文（mitm.body）") {
                    Picker("正文", selection: $bodyKind) {
                        ForEach(BodyKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button("加载\(bodyKind.rawValue)") {
                        Task { await mitmStore.loadBody(id: summary.exchangeId, response: bodyKind == .response) }
                    }
                    if let imageData = bodyDisplay.imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                    } else {
                        Text(bodyDisplay.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let footer = bodyDisplay.footer {
                        Text(footer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = mitmStore.exchangeDetail {
                    Section("完整详情（mitm.exchange）") {
                        JSONValueView(value: detail)
                            .frame(minHeight: 120)
                    }
                }
                if let message = mitmStore.detailMessage {
                    Section {
                        Text(message).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("拦截详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        MitmExchangeMenuButtons(summary: summary, detail: detail, model: menuModel)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await mitmStore.loadExchangeDetail(summary)
                // Upstream mitmExchange provider: re-fetch every 2 s
                // while the exchange is still pending.
                while !Task.isCancelled, mitmStore.exchangeDetailTyped?.pending == true {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { break }
                    await mitmStore.loadExchangeDetail(summary)
                }
            }
            .mitmExchangeMenuOverlays(menuModel, moduleStore: moduleStore)
        }
    }

    /// One side's headers, sorted by name (upstream
    /// _MitmSideView); an empty side says so instead of vanishing.
    private func headerSection(title: String, headers: [(String, [String])]) -> some View {
        Section(title) {
            if headers.isEmpty {
                Text("无")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(headers, id: \.0) { name, values in
                    ForEach(values, id: \.self) { value in
                        HStack(alignment: .top) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// Pretty-printed JSON when the text parses as JSON, else the
/// text itself (upstream MitmBodyContent `_indented`).
private func prettyJSON(_ text: String) -> String {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let out = String(data: pretty, encoding: .utf8) else { return text }
    return out
}

// MARK: - Exchange context menu (upstream
// lib/features/connection/mitm_exchange_menu.dart)
//
// Copy link / as cURL / raw request / raw response / response
// body, export HAR, add a REJECT or map-local rule into one of the
// user's own modules or a new one. A list row knows only the
// summary, so the full exchange is loaded on demand when an item
// is picked (upstream `withExchange`); the detail page passes the
// exchange it already loaded. Copy/export warn once that the
// traffic may hold private data (upstream `_warned`).

/// One context-menu action on a captured exchange.
enum MitmExchangeMenuAction: Equatable {
    case copyLink
    case copyCurl
    case copyRequest
    case copyResponse
    case copyResponseBody
    case exportHar
    case addRejectRule(target: MitmModule?)
    case addMapLocalRule(target: MitmModule?)

    /// Copy/export actions warn once that the traffic may hold
    /// private data; adding a rule does not.
    var needsWarning: Bool {
        switch self {
        case .copyLink, .addRejectRule, .addMapLocalRule: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .copyLink: return "复制链接"
        case .copyCurl: return "复制为 cURL"
        case .copyRequest: return "复制请求"
        case .copyResponse: return "复制响应"
        case .copyResponseBody: return "复制响应体"
        case .exportHar: return "导出 HAR"
        case .addRejectRule: return "添加拒绝规则"
        case .addMapLocalRule: return "添加本地映射规则"
        }
    }
}

struct MitmMenuNotice: Identifiable {
    let id = UUID()
    let text: String
}

struct MitmRuleEditorRequest: Identifiable, Hashable {
    let id = UUID()
    let module: MitmModule?
    let initialText: String
    let attachmentName: String?
    let attachmentData: Data?
}

/// The menu's UI state (privacy warning, copy notice, HAR export,
/// add-rule editor), one per menu host. The stores are passed per
/// call so the model itself holds no environment.
@MainActor
final class MitmExchangeMenuModel: ObservableObject {
    @Published var warningAction: MitmExchangeMenuAction?
    @Published var warningSummary: MitmExchangeSummary?
    @Published var warningDetail: MitmExchangeDetail?
    @Published var notice: MitmMenuNotice?
    @Published var ruleEditor: MitmRuleEditorRequest?

    private var client: ConcordClient?
    private var mitmStore: MitmStore?
    private var moduleStore: MitmModuleStore?

    func request(_ action: MitmExchangeMenuAction, summary: MitmExchangeSummary, detail: MitmExchangeDetail? = nil, client: ConcordClient, mitmStore: MitmStore, moduleStore: MitmModuleStore) {
        self.client = client
        self.mitmStore = mitmStore
        self.moduleStore = moduleStore
        if action.needsWarning && !mitmStore.exportWarned {
            warningAction = action
            warningSummary = summary
            warningDetail = detail
            return
        }
        Task { await perform(action, summary: summary, detail: detail) }
    }

    func confirmWarning() {
        guard let action = warningAction, let summary = warningSummary else { return }
        let detail = warningDetail
        warningAction = nil
        warningSummary = nil
        warningDetail = nil
        mitmStore?.exportWarned = true
        Task { await perform(action, summary: summary, detail: detail) }
    }

    func dismissWarning() {
        warningAction = nil
        warningSummary = nil
        warningDetail = nil
    }

    private func perform(_ action: MitmExchangeMenuAction, summary: MitmExchangeSummary, detail: MitmExchangeDetail?) async {
        guard let client, let mitmStore, let moduleStore else { return }
        switch action {
        case .copyLink:
            UIPasteboard.general.string = summary.url
            notice = MitmMenuNotice(text: "已复制链接")
        case .copyCurl, .copyRequest, .copyResponse, .copyResponseBody, .exportHar:
            let resolvedDetail: MitmExchangeDetail?
            if let detail {
                resolvedDetail = detail
            } else {
                resolvedDetail = (try? await client.mitmExchange(id: summary.exchangeId).result) ?? nil
            }
            guard let full = resolvedDetail else {
                notice = MitmMenuNotice(text: "读取详情失败：这条请求的记录已清除")
                return
            }
            switch action {
            case .copyCurl:
                let body = await requestBody(summary: summary, mitmStore: mitmStore)
                UIPasteboard.general.string = mitmCurl(full, body: body)
                notice = MitmMenuNotice(text: "复制成功")
            case .copyRequest:
                let body = await requestBody(summary: summary, mitmStore: mitmStore)
                UIPasteboard.general.string = mitmRawRequest(full, body: body)
                notice = MitmMenuNotice(text: "复制成功")
            case .copyResponse:
                let body = await responseBody(summary: summary, mitmStore: mitmStore)
                UIPasteboard.general.string = mitmRawResponse(full, body: body)
                notice = MitmMenuNotice(text: "复制成功")
            case .copyResponseBody:
                guard let body = await responseBody(summary: summary, mitmStore: mitmStore) else {
                    notice = MitmMenuNotice(text: "读取响应正文失败")
                    return
                }
                UIPasteboard.general.string = mitmBodyCopyText(body)
                notice = MitmMenuNotice(text: "复制成功")
            case .exportHar:
                let request = await requestBody(summary: summary, mitmStore: mitmStore)
                let response = await responseBody(summary: summary, mitmStore: mitmStore)
                let har = mitmHar(full, request: request, response: response)
                let host = URL(string: full.url)?.host ?? "concord"
                let fileName = "\(host)-\(full.exchangeId).har"
                // Upstream _exportHar writes the HAR file to disk
                // and shows an exportSuccess banner
                // (mitm_exchange_menu.dart:226) — no share sheet.
                // Documents is visible in the Files app.
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                    .appendingPathComponent(fileName)
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                do {
                    try har.data(using: .utf8)?.write(to: url, options: .atomic)
                    notice = MitmMenuNotice(text: "已导出 HAR：\(fileName)，可在「文件」里查看")
                } catch {
                    notice = MitmMenuNotice(text: "导出失败：\(error.localizedDescription)")
                }
            default:
                break
            }
        case .addRejectRule(let target), .addMapLocalRule(let target):
            let resolvedDetail: MitmExchangeDetail?
            if let detail {
                resolvedDetail = detail
            } else {
                resolvedDetail = (try? await client.mitmExchange(id: summary.exchangeId).result) ?? nil
            }
            guard let full = resolvedDetail else {
                notice = MitmMenuNotice(text: "读取详情失败：这条请求的记录已清除")
                return
            }
            let effectiveURL = (full.originalUrl ?? "").isEmpty ? full.url : full.originalUrl!
            let isReject = {
                if case .addRejectRule = action { return true }
                return false
            }()
            let section = isReject ? "URL Rewrite" : "Map Local"
            var line: String
            var attachmentName: String?
            var attachmentData: Data?
            if isReject {
                line = MitmModuleParser.mitmRejectLine(effectiveURL)
            } else {
                let body = await responseBody(summary: summary, mitmStore: mitmStore)
                let bytes: Data? = {
                    guard let body, body.truncated != true, (body.encoding ?? "").isEmpty else { return nil }
                    return Data(base64Encoded: body.data)
                }()
                if let bytes, !bytes.isEmpty {
                    let taken = target.map { moduleStore.attachments(of: $0) } ?? []
                    attachmentName = MitmModuleParser.mitmAttachmentName(full.url, taken: taken)
                    attachmentData = bytes
                }
                line = MitmModuleParser.mitmMapLocalLine(
                    full.url,
                    file: attachmentName,
                    status: Int(full.status),
                    contentType: full.headerValue("Content-Type", response: true))
            }
            let baseText = target.flatMap { moduleStore.text(of: $0) }
                ?? MitmModuleStore.blankTemplate(name: "新模块")
            guard let edited = MitmModuleParser.mitmAddLine(baseText, section: section, line: line) else {
                UIPasteboard.general.string = line
                notice = MitmMenuNotice(text: "这个模块是 Stash 覆写，规则已复制，请手动添加。")
                return
            }
            ruleEditor = MitmRuleEditorRequest(
                module: target, initialText: edited,
                attachmentName: attachmentName, attachmentData: attachmentData)
        }
    }

    /// The request body, when one was kept (upstream `_body`).
    private func requestBody(summary: MitmExchangeSummary, mitmStore: MitmStore) async -> MitmBody? {
        guard summary.requestSize > 0, !(summary.pending ?? false) else { return nil }
        return await mitmStore.loadBodyData(id: summary.exchangeId, response: false)
    }

    /// The response body, when one was kept.
    private func responseBody(summary: MitmExchangeSummary, mitmStore: MitmStore) async -> MitmBody? {
        guard summary.responseSize > 0, !(summary.pending ?? false) else { return nil }
        return await mitmStore.loadBodyData(id: summary.exchangeId, response: true)
    }
}

/// The menu items for one captured exchange, for a context menu or
/// a toolbar Menu (upstream mitmExchangeMenuItems).
struct MitmExchangeMenuButtons: View {
    let summary: MitmExchangeSummary
    var detail: MitmExchangeDetail? = nil
    @ObservedObject var model: MitmExchangeMenuModel
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var mitmStore: MitmStore
    @EnvironmentObject private var moduleStore: MitmModuleStore

    private var localModules: [MitmModule] {
        moduleStore.modules.filter { $0.url == nil }
    }

    private func request(_ action: MitmExchangeMenuAction) {
        model.request(action, summary: summary, detail: detail, client: client, mitmStore: mitmStore, moduleStore: moduleStore)
    }

    var body: some View {
        Button("复制链接") { request(.copyLink) }
        Button("复制为 cURL") { request(.copyCurl) }
        Button("复制请求") { request(.copyRequest) }
        if summary.status != 0 {
            Button("复制响应") { request(.copyResponse) }
        }
        if !(summary.pending ?? false) && summary.responseSize > 0 {
            Button("复制响应体") { request(.copyResponseBody) }
        }
        Button("导出 HAR") { request(.exportHar) }
        Menu("添加拒绝规则") {
            Button("新建模块") { request(.addRejectRule(target: nil)) }
            ForEach(localModules) { module in
                Button(module.name) { request(.addRejectRule(target: module)) }
            }
        }
        if !(summary.pending ?? false) && summary.status != 0 {
            Menu("添加本地映射规则") {
                Button("新建模块") { request(.addMapLocalRule(target: nil)) }
                ForEach(localModules) { module in
                    Button(module.name) { request(.addMapLocalRule(target: module)) }
                }
            }
        }
    }
}

extension View {
    /// The context-menu model's alert + editor page: the privacy
    /// warning, the copy/export notice, and the add-rule editor.
    /// The editor is a page push (upstream openMitmModuleEditor →
    /// BaseNavigator.push(EditorPage), module_editor.dart:48):
    /// pushed in the caller's stack, or nested inside the detail
    /// sheet's own stack when opened from there.
    func mitmExchangeMenuOverlays(_ model: MitmExchangeMenuModel, moduleStore: MitmModuleStore) -> some View {
        self
            .alert("包含隐私信息", isPresented: Binding(
                get: { model.warningAction != nil },
                set: { if !$0 { model.dismissWarning() } }
            )) {
                Button("取消", role: .cancel) { model.dismissWarning() }
                Button(model.warningAction?.title ?? "继续") { model.confirmWarning() }
            } message: {
                Text("请求里可能有 Cookie、令牌、密码和表单内容，分享前请确认内容和对象。")
            }
            .alert("提示", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ), presenting: model.notice) { _ in
                Button("好") { model.notice = nil }
            } message: { notice in
                Text(notice.text)
            }
            .navigationDestination(item: Binding(
                get: { model.ruleEditor },
                set: { model.ruleEditor = $0 }
            )) { request in
                MitmModuleTextEditorView(module: request.module, initialText: request.initialText, onSaved: { saved in
                    if let saved, let name = request.attachmentName, let data = request.attachmentData {
                        Task { await moduleStore.attachFile(saved, fileName: name, data: data) }
                    }
                }, pushed: true)
            }
    }
}

// MARK: - Exchange export formats (upstream mitm_export.dart /
// mitm_body.dart)

private func mitmShellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A body as text when it is valid UTF-8 without a dense run of
/// control characters (upstream mitmBodyText); nil otherwise. A
/// body cut at the limit may end inside a character, so a
/// truncated body is decoded tolerantly.
func mitmBodyText(_ bytes: Data, truncated: Bool = false) -> String? {
    let text: String?
    if truncated {
        text = String(decoding: bytes, as: UTF8.self)
    } else {
        text = String(data: bytes, encoding: .utf8)
    }
    guard let text else { return nil }
    var controls = 0
    var count = 0
    for scalar in text.unicodeScalars {
        count += 1
        if scalar.value == 0 { return nil }
        if scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
            controls += 1
        }
    }
    if count > 0 && controls * 100 > count { return nil }
    return text
}

/// A body for copying: its text, or its Base64 when it is not
/// text (upstream mitmBodyCopyText).
private func mitmBodyCopyText(_ body: MitmBody) -> String {
    if !(body.encoding ?? "").isEmpty { return body.data }
    let bytes = Data(base64Encoded: body.data) ?? Data()
    return mitmBodyText(bytes, truncated: body.truncated == true) ?? body.data
}

/// A POSIX shell command that sends `exchange` again, with `body`
/// as the request body; a body that is not text is piped in from
/// Base64 (upstream mitmCurl).
private func mitmCurl(_ exchange: MitmExchangeDetail, body: MitmBody?) -> String {
    let bytes = body.flatMap { Data(base64Encoded: $0.data) } ?? Data()
    let url = URL(string: exchange.url)
    let authority: String? = {
        guard let host = url?.host else { return nil }
        if let port = url?.port { return "\(host):\(port)" }
        return host
    }()
    let method = exchange.method
    let hasBody = !bytes.isEmpty
    var arguments = [mitmShellQuoted(exchange.url)]
    if method == "HEAD" {
        arguments.append("--head")
    } else if method != (hasBody ? "POST" : "GET") {
        arguments.append("-X \(mitmShellQuoted(method))")
    }
    var compressed = false
    for (name, values) in exchange.sortedHeaders(response: false) {
        let lower = name.lowercased()
        for value in values {
            if lower == "content-length" { continue }
            if lower == "host", value == authority { continue }
            if lower == "content-encoding", hasBody, (body?.encoding ?? "").isEmpty { continue }
            if lower == "accept-encoding" { compressed = true }
            arguments.append("-H \(mitmShellQuoted("\(name): \(value)"))")
        }
    }
    if compressed { arguments.append("--compressed") }
    var input = ""
    if hasBody {
        if let text = mitmBodyText(bytes, truncated: body?.truncated == true) {
            arguments.append("--data-raw \(mitmShellQuoted(text))")
        } else {
            input = "printf '%s' '\(bytes.base64EncodedString())' | base64 --decode | "
            arguments.append("--data-binary @-")
        }
    }
    return "\(input)curl \(arguments.joined(separator: " \\\n  "))"
}

private func mitmRawMessage(startLine: String, headers: [(String, [String])], body: MitmBody?) -> String {
    var out = startLine
    for (name, values) in headers {
        for value in values { out += "\n\(name): \(value)" }
    }
    if let body, !body.data.isEmpty { out += "\n\n\(mitmBodyCopyText(body))" }
    return out
}

/// `exchange`'s request as HTTP/1 text; a body that is not text
/// is Base64 (upstream mitmRawRequest).
private func mitmRawRequest(_ exchange: MitmExchangeDetail, body: MitmBody?) -> String {
    let url = URL(string: exchange.url)
    let target: String
    if let url, url.host != nil {
        let path = url.path.isEmpty ? "/" : url.path
        target = url.query.map { "\(path)?\($0)" } ?? path
    } else {
        target = exchange.url
    }
    return mitmRawMessage(
        startLine: "\(exchange.method) \(target) \(exchange.proto ?? "")",
        headers: exchange.sortedHeaders(response: false), body: body)
}

/// `exchange`'s response as HTTP/1 text (upstream mitmRawResponse).
private func mitmRawResponse(_ exchange: MitmExchangeDetail, body: MitmBody?) -> String {
    mitmRawMessage(
        startLine: "\(exchange.proto ?? "") \(exchange.status)",
        headers: exchange.sortedHeaders(response: true), body: body)
}

private func mitmHarHeaders(_ headers: [(String, [String])]) -> [[String: String]] {
    headers.flatMap { name, values in values.map { ["name": name, "value": $0] } }
}

private func mitmHarText(_ body: MitmBody) -> [String: Any] {
    let bytes = Data(base64Encoded: body.data) ?? Data()
    let text = (body.encoding ?? "").isEmpty ? mitmBodyText(bytes, truncated: body.truncated == true) : nil
    var out: [String: Any] = ["text": text ?? body.data]
    if text == nil { out["encoding"] = "base64" }
    if body.truncated == true { out["comment"] = "truncated" }
    return out
}

/// `exchange` with its bodies as an HTTP Archive 1.2 log, which
/// browser developer tools import (upstream mitmHar).
private func mitmHar(_ exchange: MitmExchangeDetail, request: MitmBody?, response: MitmBody?) -> String {
    let requestType = exchange.headerValue("Content-Type", response: false)
    let responseType = exchange.headerValue("Content-Type", response: true)
    let ttfb = (exchange.ttfb ?? 0) > 0 ? (exchange.ttfb ?? 0) : exchange.duration
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let started = ISO8601DateFormatter().date(from: exchange.start)
        .map { ISO8601DateFormatter().string(from: $0) } ?? exchange.start
    var queryString: [[String: String]] = []
    if let components = URLComponents(string: exchange.url), let items = components.queryItems {
        queryString = items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }
    var requestDict: [String: Any] = [
        "method": exchange.method,
        "url": exchange.url,
        "httpVersion": exchange.proto ?? "",
        "cookies": [],
        "headers": mitmHarHeaders(exchange.sortedHeaders(response: false)),
        "queryString": queryString,
        "headersSize": -1,
        "bodySize": exchange.requestSize,
    ]
    if let request, !request.data.isEmpty {
        let requestText = mitmHarText(request)
        var postData: [String: Any] = ["mimeType": requestType]
        if let text = requestText["text"] as? String { postData["text"] = text }
        if let encoding = requestText["encoding"] as? String { postData["_encoding"] = encoding }
        requestDict["postData"] = postData
    }
    var content: [String: Any] = [
        "size": response.map { Data(base64Encoded: $0.data)?.count ?? Int(exchange.responseSize) } ?? Int(exchange.responseSize),
        "mimeType": responseType.isEmpty ? "x-unknown" : responseType,
    ]
    if let response { content.merge(mitmHarText(response)) { _, new in new } }
    let entry: [String: Any] = [
        "startedDateTime": started,
        "time": exchange.duration,
        "request": requestDict,
        "response": [
            "status": exchange.status,
            "statusText": "",
            "httpVersion": exchange.proto ?? "",
            "cookies": [],
            "headers": mitmHarHeaders(exchange.sortedHeaders(response: true)),
            "content": content,
            "redirectURL": exchange.headerValue("Location", response: true),
            "headersSize": -1,
            "bodySize": exchange.responseSize,
        ],
        "cache": [:],
        "timings": [
            "send": 0,
            "wait": ttfb,
            "receive": exchange.duration > ttfb ? exchange.duration - ttfb : 0,
        ],
    ]
    var logEntry = entry
    if let connection = exchange.connection, !connection.isEmpty {
        logEntry["connection"] = connection
    }
    let log: [String: Any] = [
        "log": [
            "version": "1.2",
            "creator": ["name": "Lumen", "version": version],
            "entries": [logEntry],
        ],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
