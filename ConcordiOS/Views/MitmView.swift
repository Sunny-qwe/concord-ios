import SwiftUI

// MARK: - MITM capture (FlClash: MITM requests page)
// Two real functions, both backed by ConcordClient:
//   * run a named MITM script (mitm.runScript) and show its result;
//   * list the captured exchanges of one connection (mitm.exchanges),
//     open one (mitm.exchange) and read its request/response body
//     (mitm.body).
// There is no list-scripts API, so the script name is typed in. The
// connection id comes from the Connections page (tap a connection ->
// "MITM 拦截记录") or is typed in here.

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
    @EnvironmentObject private var client: ConcordClient

    let initialConnectionId: UInt64?
    @State private var connectionIdText: String
    @State private var detailSummary: MitmExchangeSummary?
    /// Live all-connections feed (audit B45): merged exchanges from
    /// every live connection, polled while this page is visible.
    @State private var allExchanges: [MitmExchangeSummary] = []
    /// nil = no live connections yet (unknown); false = capture off.
    @State private var allCapturing: Bool?
    @State private var liveListError: String?

    init(initialConnectionId: UInt64? = nil) {
        self.initialConnectionId = initialConnectionId
        _connectionIdText = State(initialValue: initialConnectionId.map(String.init) ?? "")
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

            Section("模块") {
                NavigationLink {
                    MitmModulesView()
                } label: {
                    HStack {
                        Text("MITM 模块")
                        Spacer()
                        Text("Surge / Loon / QX")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    MitmScriptsView()
                } label: {
                    HStack {
                        Text("MITM 脚本")
                        Spacer()
                        Text("独立脚本库")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("模块把规则、重写、脚本和解密域名打包在一起，整体开关。MITM 拦截本身就是为模块服务的：模块里的重写和脚本要靠它才能改 HTTPS 请求的内容。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("运行脚本（mitm.runScript）") {
                TextField("脚本名", text: $mitmStore.scriptName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("运行脚本") {
                    Task { await mitmStore.runScript() }
                }
                .disabled(mitmStore.isRunningScript || mitmStore.scriptName.trimmingCharacters(in: .whitespaces).isEmpty)
                if let message = mitmStore.scriptMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let result = mitmStore.scriptResult {
                    JSONValueView(value: result)
                        .frame(minHeight: 60)
                }
                Text("脚本是核心里的 MITM 脚本（按名字运行）。没有列出脚本的接口，名字就是脚本文件名。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Live all-connections list (audit B45): FlClash's MITM
            // page lists the captured requests live. mitm.exchanges
            // is per connection, so this polls connection.watch and
            // merges every live connection's exchanges (newest
            // first), 1 s while the page is visible.
            if initialConnectionId == nil {
                Section("实时拦截（全部连接）") {
                    if allCapturing == false {
                        captureOffBanner
                    }
                    if allCapturing == true {
                        Text("正在捕获 · \(allExchanges.count) 条")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let liveListError {
                        Text(liveListError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if allExchanges.isEmpty && allCapturing == true {
                        Text("正在捕获，暂无拦截记录：产生 HTTPS 流量后会出现在这里。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(allExchanges) { exchange in
                        Button { detailSummary = exchange } label: {
                            exchangeRow(exchange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("拦截记录（mitm.exchanges）") {
                HStack {
                    TextField("连接 ID", text: $connectionIdText)
                        .keyboardType(.numberPad)
                    Button("加载") {
                        if let id = UInt64(connectionIdText) {
                            Task { await mitmStore.loadExchanges(connection: id) }
                        }
                    }
                    .disabled(UInt64(connectionIdText) == nil)
                }
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
                }
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("MITM 拦截")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { if let id = UInt64(connectionIdText) { await mitmStore.loadExchanges(connection: id) } } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(UInt64(connectionIdText) == nil)
            }
        }
        .sheet(item: $detailSummary) { summary in
            MitmExchangeDetailView(summary: summary)
        }
        .task {
            if let id = initialConnectionId {
                await mitmStore.loadExchanges(connection: id)
            } else {
                // Live all-connections feed: poll every 1 s while
                // this page is visible; the task is cancelled when
                // the page disappears.
                await pollAllExchanges()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    await pollAllExchanges()
                }
            }
        }
    }

    /// The capture switch lives in Settings (常规 MITM 区的
    /// "捕获拦截记录", mitm.json `capture`): when capturing is off
    /// this page would otherwise be a dead end (audit B46). The
    /// toggle saves on change, exactly like the settings page's
    /// copy; it takes effect at the next VPN start (or the next
    /// config.apply while running).
    private var captureOffBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MITM 捕获未开启：拦截记录不会保存。")
                .font(.caption2)
                .foregroundStyle(.orange)
            Toggle("捕获拦截记录", isOn: $settingsStore.mitmCapture)
                .font(.footnote)
                .onChange(of: settingsStore.mitmCapture) { _, _ in settingsStore.save() }
            Text("开启后下次启动 VPN（或重新应用配置）生效；最多保留 \(settingsStore.mitmCaptureEntries) 条。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// One exchange row, shared by the live list and the
    /// per-connection list.
    private func exchangeRow(_ exchange: MitmExchangeSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(ConcordFormat.time(rfc3339: exchange.start))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(exchange.method)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                    Text(exchange.url)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    if exchange.pending ?? false {
                        Text("进行中").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("\(exchange.status)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(exchange.status >= 400 ? .red : .green)
                    }
                }
                Text("↑ \(ConcordFormat.bytes(exchange.requestSize)) · ↓ \(ConcordFormat.bytes(exchange.responseSize)) · \(exchange.duration) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let error = exchange.error, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    /// Merges every live connection's exchanges into allExchanges.
    /// mitm.exchanges is per connection and the core only captures
    /// while options.mitmCapture is on, so `capturing` is true when
    /// any connection reports it. Capped at 20 connections per
    /// poll; the calls run concurrently.
    private func pollAllExchanges() async {
        guard client.mode == .sample || TunnelManager.shared.isRunning else {
            liveListError = "VPN 未运行：启动 VPN 后这里会实时列出解密的请求"
            return
        }
        do {
            let snapshot = try await client.connectionSnapshot()
            let ids = Array(snapshot.connections.prefix(20).map(\.id))
            guard !ids.isEmpty else {
                allCapturing = nil
                allExchanges = []
                liveListError = nil
                return
            }
            var capturing = false
            var merged: [Int64: MitmExchangeSummary] = [:]
            let client = self.client
            await withTaskGroup(of: MitmExchangeList?.self) { group in
                for id in ids {
                    group.addTask {
                        do {
                            let result = try await client.mitmExchanges(connection: id).result
                            return try result.decoded(as: MitmExchangeList.self)
                        } catch {
                            return nil
                        }
                    }
                }
                for await list in group {
                    guard let list else { continue }
                    if list.capturing { capturing = true }
                    for exchange in list.exchanges {
                        merged[exchange.exchangeId] = exchange
                    }
                }
            }
            allCapturing = capturing
            allExchanges = merged.values.sorted { $0.start > $1.start }
            liveListError = nil
        } catch {
            liveListError = "读取拦截记录失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Exchange detail (mitm.exchange / mitm.body)

struct MitmExchangeDetailView: View {
    let summary: MitmExchangeSummary
    @EnvironmentObject private var mitmStore: MitmStore
    @Environment(\.dismiss) private var dismiss
    @State private var bodyKind: BodyKind = .request

    enum BodyKind: String, CaseIterable, Identifiable {
        case request = "请求正文"
        case response = "响应正文"
        var id: String { rawValue }
    }

    private var bodyText: String {
        guard let body = mitmStore.exchangeBody else { return "尚未加载正文" }
        if let text = body.text { return text }
        let bytes = Data(base64Encoded: body.data)?.count ?? 0
        return "正文不是 UTF-8 文本（\(bytes) 字节\(body.truncated == true ? "，已截断" : "")）"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("请求") {
                    LabeledContent("开始时间", value: ConcordFormat.time(rfc3339: summary.start))
                    LabeledContent("方法", value: summary.method)
                    LabeledContent("URL", value: summary.url)
                    LabeledContent("状态", value: (summary.pending ?? false) ? "进行中" : "\(summary.status)")
                    LabeledContent("耗时", value: "\(summary.duration) ms")
                    LabeledContent("上行", value: ConcordFormat.bytes(summary.requestSize))
                    LabeledContent("下行", value: ConcordFormat.bytes(summary.responseSize))
                    if let error = summary.error, !error.isEmpty {
                        LabeledContent("错误", value: error)
                    }
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
                    Text(bodyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
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
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await mitmStore.loadExchangeDetail(summary)
            }
        }
    }
}
