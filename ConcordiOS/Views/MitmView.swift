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
    @EnvironmentObject private var client: ConcordClient

    let initialConnectionId: UInt64?
    @State private var connectionIdText: String
    @State private var detailSummary: MitmExchangeSummary?

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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
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
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let result = mitmStore.scriptResult {
                    JSONValueView(value: result)
                        .frame(minHeight: 60)
                }
                Text("脚本是核心里的 MITM 脚本（按名字运行）。没有列出脚本的接口，名字就是脚本文件名。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let message = mitmStore.exchangesMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(mitmStore.exchanges) { exchange in
                    Button { detailSummary = exchange } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(ConcordFormat.time(rfc3339: exchange.start))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(exchange.method)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                    Text(exchange.url)
                                        .font(.body)
                                        .lineLimit(1)
                                    Spacer()
                                    if exchange.pending ?? false {
                                        Text("进行中").font(.caption).foregroundStyle(.orange)
                                    } else {
                                        Text("\(exchange.status)")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(exchange.status >= 400 ? .red : .green)
                                    }
                                }
                                Text("↑ \(ConcordFormat.bytes(exchange.requestSize)) · ↓ \(ConcordFormat.bytes(exchange.responseSize)) · \(exchange.duration) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let error = exchange.error, !error.isEmpty {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("MITM 拦截")
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
            }
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
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
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
