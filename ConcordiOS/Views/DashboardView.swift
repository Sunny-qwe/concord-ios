import SwiftUI

// MARK: - Dashboard (FlClash: DashboardView, lib/views/dashboard/)
// FlClash dashboard cards: CurrentOutbound, NetworkSpeed, OutboundMode,
// VpnButton, NetworkTakeover, ServiceStatus, Profiles, ProxyGroups,
// ConnectionStats, IntranetIp, MemoryInfo. This page reproduces those
// cards in a mobile list; the desktop grid layout is not used on iOS.

struct DashboardView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var client: ConcordClient

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Current outbound + start/stop (FlClash CurrentOutboundCard)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当前出站")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if client.mode == .sample { SampleDataBadge() }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proxyStore.selectedOutbound ?? "未选择")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                Text(proxyStore.isRunning ? "运行中" : "已停止")
                                    .font(.caption)
                                    .foregroundStyle(proxyStore.isRunning ? .green : .secondary)
                            }
                            Spacer()
                            Button(proxyStore.isRunning ? "停止" : "启动") {
                                Task { await proxyStore.toggle() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(proxyStore.isRunning ? .red : .blue)
                        }
                        if let error = proxyStore.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    // Network speed (FlClash NetworkSpeedCard)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("实时流量")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("↑ \(ConcordFormat.rate(trafficStore.current.up))  ↓ \(ConcordFormat.rate(trafficStore.current.down))")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        TrafficChartView(history: trafficStore.history)
                        HStack {
                            Text("上行总量 \(ConcordFormat.bytes(trafficStore.current.totalUp))")
                            Spacer()
                            Text("下行总量 \(ConcordFormat.bytes(trafficStore.current.totalDown))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    // Outbound mode (FlClash OutboundModeCard)
                    HStack {
                        Text("出站模式")
                        Spacer()
                        Picker("出站模式", selection: $settingsStore.mode) {
                            ForEach(OutboundMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    // Stats grid (FlClash ConnectionStats / MemoryInfo / Profiles / ProxyGroups)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: "活动连接", value: "\(connectionStore.connections.count)", subtitle: "上行 \(ConcordFormat.bytes(connectionStore.totalUpload)) · 下行 \(ConcordFormat.bytes(connectionStore.totalDownload))")
                        StatCard(title: "核心内存", value: trafficStore.coreMemoryBytes.map { ConcordFormat.bytes(Int64($0)) } ?? "—", subtitle: "core.stats rss")
                        StatCard(title: "当前订阅", value: profileStore.activeProfile?.name ?? "无", subtitle: profileStore.activeProfile?.updatedAt.map { "更新于 \($0.formatted(date: .abbreviated, time: .shortened))" })
                        StatCard(title: "代理组", value: "\(proxyStore.groups.count) 组 · \(proxyStore.allNodes.count) 节点", subtitle: "proxy.groups")
                        StatCard(title: "出口 IP", value: trafficStore.outboundIp ?? "—", subtitle: trafficStore.outboundChains.isEmpty ? "probe.outboundIp" : "经由 \(trafficStore.outboundChains.joined(separator: " → "))")
                        StatCard(title: "核心模式", value: client.mode.rawValue, subtitle: client.mode == .live ? "已链接真实核心" : "示例数据，核心未链接")
                    }

                    // Service status (FlClash ServiceStatusCard)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("引擎", value: proxyStore.isRunning ? "已启动" : "已停止")
                        LabeledContent("TUN", value: settingsStore.tunEnabled ? "已启用（\(settingsStore.tunStack)）" : "未启用")
                        LabeledContent("DNS", value: settingsStore.dnsEnabled ? "已启用" : "未启用")
                        Text("TUN 数据面仍是 TODO：核心尚未链接，VPN 开关目前只切换界面状态，不转发流量。见 TUN_INVESTIGATION.md。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("仪表盘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("核心") {
                        Picker("核心模式", selection: $client.mode) {
                            ForEach(ConcordMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await trafficStore.probe() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                await proxyStore.refresh()
                await connectionStore.refresh()
                await trafficStore.refresh()
            }
        }
    }
}
