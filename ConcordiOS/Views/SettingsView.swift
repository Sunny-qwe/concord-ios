import SwiftUI

// MARK: - Settings / Tools (FlClash: ToolsView, lib/views/tools.dart)
// FlClash's Tools page is the settings hub: locale, theme, hotkeys,
// access, backup, advanced config, general config (log level, ports,
// allow LAN, IPv6, sniffing, user agent, delay timeout), plus the
// "More" pages (Requests, DNS, Resources, Logs). On iOS the equivalents
// are: 通用、TUN、DNS、MITM、网络、提供方、资源、关于. DNS queries and
// Resources are sub-pages here, matching FlClash's moreFull/more modes.

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient

    var body: some View {
        NavigationStack {
            Form {
                Section("通用（config.general）") {
                    Picker("出站模式", selection: $settingsStore.mode) {
                        ForEach(OutboundMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("日志级别", selection: $settingsStore.logLevel) {
                        ForEach(LogLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    Stepper("混合端口：\(settingsStore.mixedPort)", value: $settingsStore.mixedPort, in: 1...65535)
                    Stepper("SOCKS 端口：\(settingsStore.socksPort)", value: $settingsStore.socksPort, in: 1...65535)
                    Toggle("允许局域网连接", isOn: $settingsStore.allowLan)
                    Toggle("IPv6", isOn: $settingsStore.ipv6)
                    Toggle("TCP 并发", isOn: $settingsStore.tcpConcurrent)
                    Toggle("统一延迟测试", isOn: $settingsStore.unifiedDelay)
                    Toggle("流量嗅探", isOn: $settingsStore.sniffing)
                    TextField("全局 User-Agent（留空为默认）", text: $settingsStore.globalUa)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("延迟测试超时：\(settingsStore.delayTestTimeout) ms", value: $settingsStore.delayTestTimeout, in: 1000...30000, step: 1000)
                    Button("从核心读取当前配置") {
                        Task { await settingsStore.refreshFromCore() }
                    }
                }

                Section("TUN（PacketTunnel 扩展参数）") {
                    Toggle("启用 TUN", isOn: $settingsStore.tunEnabled)
                    Picker("协议栈", selection: $settingsStore.tunStack) {
                        Text("gVisor").tag("gvisor")
                        Text("System").tag("system")
                        Text("Lwip").tag("lwip")
                    }
                    Stepper("MTU：\(settingsStore.tunMtu)", value: $settingsStore.tunMtu, in: 1280...9000, step: 100)
                    TextField("TUN DNS（逗号分隔）", text: $settingsStore.tunDns)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("iOS 上 TUN 由系统 NetworkExtension 拥有，核心不会自己创建 TUN 设备（见 TUN_INVESTIGATION.md）。这些参数会传给 tun.start 的 inherited 路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DNS") {
                    Toggle("启用 DNS", isOn: $settingsStore.dnsEnabled)
                    TextField("DoH 上游", text: $settingsStore.dnsNameserver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("Fake-IP", isOn: $settingsStore.dnsFakeIpEnabled)
                    TextField("Fake-IP 段", text: $settingsStore.dnsFakeIpRange)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    NavigationLink("DNS 查询记录") {
                        DnsQueriesView()
                    }
                }

                Section("MITM") {
                    Toggle("启用 MITM", isOn: $settingsStore.mitmEnabled)
                        .disabled(!settingsStore.mitmAvailable)
                    Text("MITM 在 iOS 上暂不可用：需要核心的 mitm 能力（mitm.certificate / generateCertificate / runScript），尚未验证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("提供方（provider.list）") {
                    NavigationLink("查看全部提供方") {
                        ProvidersView()
                    }
                    Text("代理提供方 \(ruleStore.providers.filter { $0.type == "proxy" }.count) 个 · 规则提供方 \(ruleStore.ruleProviders.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("资源（core.stats）") {
                    NavigationLink("资源详情") {
                        ResourcesView()
                    }
                    LabeledContent("核心内存", value: trafficStore.coreMemoryBytes.map { ConcordFormat.bytes(Int64($0)) } ?? "—")
                }

                Section("应用") {
                    Toggle("自动更新订阅", isOn: $settingsStore.autoUpdateProfiles)
                    Toggle("开发者模式", isOn: $settingsStore.developerMode)
                    Picker("核心模式", selection: $client.mode) {
                        ForEach(ConcordMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text(client.mode == .sample
                         ? "示例数据模式：所有页面显示的都是内置示例数据，不是真实核心数据。"
                         : "实时核心模式：需要先链接 Concord 静态库，否则调用会报错。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: "Concord iOS 0.2.0（FlClash 风格界面）")
                    LabeledContent("核心", value: "chen08209/concord（GPL-3.0-or-later）")
                    LabeledContent("界面来源", value: "chen08209/FlClash（GPL-3.0）")
                    Text("本 App 是 FlClash 界面的 SwiftUI 复刻，核心尚未链接，不能代理流量。数据面、签名与核心链接仍是 TODO。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .onChange(of: settingsStore.mode) { _ in settingsStore.save() }
            .onChange(of: settingsStore.logLevel) { _ in settingsStore.save() }
            .onChange(of: settingsStore.allowLan) { _ in settingsStore.save() }
            .onChange(of: settingsStore.ipv6) { _ in settingsStore.save() }
            .onChange(of: settingsStore.tunEnabled) { _ in settingsStore.save() }
        }
    }
}

// MARK: - DNS queries (FlClash: DnsQueriesView, lib/views/dns_queries.dart)

struct DnsQueriesView: View {
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var client: ConcordClient

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("DNS 记录为示例数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                Button("清除 DNS 缓存（dns.clearCache）") {
                    Task { await dnsStore.clearCache() }
                }
                Button("清除 Fake-IP 映射（dns.flushFakeIp）") {
                    Task { await dnsStore.flushFakeIp() }
                }
                if let message = dnsStore.lastActionMessage {
                    Text(message).font(.caption).foregroundStyle(.green)
                }
            }
            Section("查询记录（dns.watch）") {
                if dnsStore.filtered.isEmpty {
                    Text("暂无 DNS 查询记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dnsStore.filtered) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.domain).font(.body)
                                Spacer()
                                Text(entry.type)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                            Text("上游 \(entry.upstream) · \(entry.delay) ms · \(entry.cached == true ? "缓存命中" : "实时查询")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("应答：\(entry.answers.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ConcordFormat.time(entry.time))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("DNS 查询")
        .searchable(text: $dnsStore.searchText, prompt: "搜索域名或上游")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await dnsStore.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await dnsStore.refresh() }
        .task { if dnsStore.entries.isEmpty { await dnsStore.refresh() } }
    }
}

// MARK: - Providers (FlClash: providers view, lib/views/config/providers.dart)

struct ProvidersView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("提供方为示例数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(ruleStore.providers) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(provider.name).font(.body)
                        Spacer()
                        Text(provider.type)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                    }
                    Text("\(provider.vehicleType) · \(provider.count) 条 · \(provider.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let updated = provider.updatedAt {
                        Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("更新") {
                        Task {
                            do {
                                try await client.providerUpdate(name: provider.name)
                                await ruleStore.refresh()
                            } catch {
                                // provider.update errors surface on the Rules page.
                            }
                        }
                    }
                    .tint(.orange)
                }
            }
        }
        .navigationTitle("提供方")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await ruleStore.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await ruleStore.refresh() }
    }
}

// MARK: - Resources (FlClash: ResourcesView, lib/views/resources.dart)

struct ResourcesView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var ruleStore: RuleStore

    var body: some View {
        List {
            Section("核心") {
                LabeledContent("内存占用", value: trafficStore.coreMemoryBytes.map { ConcordFormat.bytes(Int64($0)) } ?? "—")
                Text("core.stats 只暴露 rss。NetworkExtension 进程内存上限很紧（历史约 15–50 MB），大规则集与 GeoIP 可能触发 Jetsam。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("已加载") {
                LabeledContent("代理组", value: "\(proxyStore.groups.count)")
                LabeledContent("节点", value: "\(proxyStore.allNodes.count)")
                LabeledContent("规则", value: "\(ruleStore.rules.count)")
                LabeledContent("提供方", value: "\(ruleStore.providers.count)")
            }
            Section {
                Button("刷新") {
                    Task {
                        await trafficStore.refreshMemory()
                        await proxyStore.refresh()
                        await ruleStore.refresh()
                    }
                }
            }
        }
        .navigationTitle("资源")
    }
}
