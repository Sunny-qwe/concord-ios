import SwiftUI

// MARK: - Connections (FlClash: RequestsView, lib/views/connection/)
// FlClash's "Requests" page is the live connection table: host, rule,
// proxy, up/down, duration, search, sort, kill a connection
// (connection.close) and kill all. DNS queries live on their own page
// under Settings (FlClash DnsQueriesView).

struct ConnectionsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var proxyStore: ProxyStore
    @State private var detail: LiveConnection?
    @State private var detailIsLive = true
    @State private var feed: ConnectionFeed = .live

    /// The two feeds of FlClash's Requests page: live connections
    /// and recently finished ones (built locally by diffing
    /// snapshots — see ConnectionStore.recentConnections).
    enum ConnectionFeed {
        case live
        case recent
    }

    /// Recent connections matching the search text.
    private var recentFiltered: [LiveConnection] {
        guard !connectionStore.searchText.isEmpty else { return connectionStore.recentConnections }
        let q = connectionStore.searchText.lowercased()
        return connectionStore.recentConnections.filter {
            ($0.host?.lowercased().contains(q) ?? false)
                || $0.destination.lowercased().contains(q)
                || ($0.proxy?.lowercased().contains(q) ?? false)
                || ($0.rule?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (ConnectionDetailView keeps its own stack as a sheet.)
        VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("连接为示例数据")
                            .font(.system(size: 10))
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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
                if let message = connectionStore.networkUpdateMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if let error = connectionStore.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                Picker("请求", selection: $feed) {
                    Text("正在运行").tag(ConnectionFeed.live)
                    Text("最近请求").tag(ConnectionFeed.recent)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 4)
                if feed == .live {
                    if connectionStore.filtered.isEmpty {
                        if proxyStore.isRunning {
                            ContentUnavailableView("暂无活动连接", systemImage: "arrow.left.arrow.right", description: Text("当前没有活动连接，产生流量后会在这里列出"))
                        } else {
                            ContentUnavailableView {
                                Label("暂无活动连接", systemImage: "arrow.left.arrow.right")
                            } description: {
                                Text("开启 VPN 后，这里的实时连接会按 host / 规则 / 代理列出")
                            } actions: {
                                Button("启动 VPN") {
                                    Task { await proxyStore.toggle() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        List(connectionStore.filtered) { connection in
                            Button { detail = connection; detailIsLive = true } label: {
                                connectionRow(connection)
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
                } else {
                    if recentFiltered.isEmpty {
                        ContentUnavailableView("暂无最近请求", systemImage: "clock", description: Text("已结束的连接会在这里列出（本会话内，最多 200 条）"))
                    } else {
                        List(recentFiltered) { connection in
                            Button { detail = connection; detailIsLive = false } label: {
                                connectionRow(connection)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
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
                        Button("清除最近请求记录", role: .destructive) {
                            connectionStore.clearRecent()
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
                ConnectionDetailView(connection: connection, isLive: detailIsLive)
            }
            .refreshable { await connectionStore.refresh() }
            .task { if connectionStore.connections.isEmpty { await connectionStore.refresh() } }
    }

    /// One connection row, shared by the live and recent feeds.
    private func connectionRow(_ connection: LiveConnection) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(ConcordFormat.time(Int64(connection.start.timeIntervalSince1970 * 1000)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.host ?? connection.destination)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("\(connection.network.uppercased()) · \(connection.rule ?? "—") · \(connection.proxy ?? "—")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("持续 \(ConcordFormat.duration(seconds: connection.durationSeconds)) · ↑ \(ConcordFormat.bytes(connection.upload)) ↓ \(ConcordFormat.bytes(connection.download))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

struct ConnectionDetailView: View {
    let connection: LiveConnection
    /// False for a finished connection from 最近请求： there is
    /// nothing to close.
    var isLive: Bool = true
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
                    if isLive {
                        Button("断开此连接", role: .destructive) {
                            Task {
                                await connectionStore.close(connection)
                                dismiss()
                            }
                        }
                    }
                    NavigationLink("MITM 拦截记录（mitm.exchanges）") {
                        MitmView(initialConnectionId: connection.id)
                    }
                    Text("断开调用 connection.close；拦截记录调用 mitm.exchanges，需要 MITM 已开启并正在捕获。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .font(.system(size: 13, weight: .semibold))
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
