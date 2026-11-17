import SwiftUI

// MARK: - Connections (FlClash: RequestsView, lib/views/connection/)
// FlClash's "Requests" page is the live connection table: host, rule,
// proxy, up/down, duration, search, sort, kill a connection
// (connection.close) and kill all. DNS queries live on their own page
// under Settings (FlClash DnsQueriesView).

struct ConnectionsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var client: ConcordClient
    @State private var detail: LiveConnection?

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (ConnectionDetailView keeps its own stack as a sheet.)
        VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("连接为示例数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                HStack(spacing: 16) {
                    Text("\(connectionStore.connections.count) 个连接")
                    Text("上行 \(ConcordFormat.bytes(connectionStore.totalUpload))")
                    Text("下行 \(ConcordFormat.bytes(connectionStore.totalDownload))")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
                if let message = connectionStore.networkUpdateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if let error = connectionStore.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                if connectionStore.filtered.isEmpty {
                    ContentUnavailableView("暂无活动连接", systemImage: "arrow.left.arrow.right", description: Text("开启 VPN 后，这里的实时连接会按 host / 规则 / 代理列出"))
                } else {
                    List(connectionStore.filtered) { connection in
                        Button { detail = connection } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(ConcordFormat.time(Int64(connection.start.timeIntervalSince1970 * 1000)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.host ?? connection.destination)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text("\(connection.network.uppercased()) · \(connection.rule ?? "—") · \(connection.proxy ?? "—")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("持续 \(ConcordFormat.duration(seconds: connection.durationSeconds)) · ↑ \(ConcordFormat.bytes(connection.upload)) ↓ \(ConcordFormat.bytes(connection.download))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("断开", role: .destructive) {
                                Task { await connectionStore.close(connection) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle("连接")
            .searchable(text: $connectionStore.searchText, prompt: "搜索域名、代理或规则")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $connectionStore.sort) {
                            ForEach(ConnectionSort.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Button("重置解析器连接（network.reset）") {
                            Task { await connectionStore.resetNetwork() }
                        }
                        Button("通知核心网络已变化（network.update）") {
                            Task { await connectionStore.networkUpdate(interfaceChanged: false) }
                        }
                        Button("通知核心网络接口已切换（network.update）") {
                            Task { await connectionStore.networkUpdate(interfaceChanged: true) }
                        }
                        Button("断开全部连接", role: .destructive) {
                            Task { await connectionStore.closeAll() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await connectionStore.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $detail) { connection in
                ConnectionDetailView(connection: connection)
            }
            .refreshable { await connectionStore.refresh() }
            .task { if connectionStore.connections.isEmpty { await connectionStore.refresh() } }
    }
}

struct ConnectionDetailView: View {
    let connection: LiveConnection
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    LabeledContent("域名", value: connection.host ?? "—")
                    LabeledContent("目标", value: connection.destination)
                    LabeledContent("来源", value: connection.source)
                    LabeledContent("网络", value: connection.network.uppercased())
                    LabeledContent("入站", value: connection.inboundType)
                    if let process = connection.process {
                        LabeledContent("进程", value: process)
                    }
                }
                Section("路由") {
                    LabeledContent("规则", value: connection.rule ?? "—")
                    LabeledContent("代理", value: connection.proxy ?? "—")
                    LabeledContent("持续", value: ConcordFormat.duration(seconds: connection.durationSeconds))
                    LabeledContent("上行", value: ConcordFormat.bytes(connection.upload))
                    LabeledContent("下行", value: ConcordFormat.bytes(connection.download))
                }
                Section {
                    Button("断开此连接", role: .destructive) {
                        Task {
                            await connectionStore.close(connection)
                            dismiss()
                        }
                    }
                    NavigationLink("MITM 拦截记录（mitm.exchanges）") {
                        MitmView(initialConnectionId: connection.id)
                    }
                    Text("断开调用 connection.close；拦截记录调用 mitm.exchanges，需要 MITM 已开启并正在捕获。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("连接详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
