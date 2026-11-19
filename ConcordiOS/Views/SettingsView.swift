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
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @State private var mitmIssueHost = ""
    @State private var showCrashConfirm = false

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (The DNS / providers / resources sub-pages below are
        // pushed onto the same stack.)
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
                    Toggle("启动时自动连接", isOn: $settingsStore.autoRun)
                    Toggle("切换配置后自动关闭连接", isOn: $settingsStore.autoCloseConnections)
                    Toggle("校验订阅证书", isOn: $settingsStore.checkCertificate)
                    Toggle("启动时自动检查更新", isOn: $settingsStore.autoCheckUpdate)
                    Toggle("记录日志（工具页显示「日志」）", isOn: $settingsStore.openLogs)
                    if let findProcessMode = settingsStore.findProcessMode {
                        LabeledContent("进程查找方式", value: findProcessMode)
                    }
                    NavigationLink("Hosts") {
                        HostsView()
                    }
                    Text("启动时自动连接：打开应用后自动启动 VPN（需已有配置）。校验订阅证书：关闭后订阅下载不再验证服务器证书（自签证书的订阅源可用）。进程查找方式由核心决定，不可修改。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("从核心读取当前配置") {
                        Task { await settingsStore.refreshFromCore() }
                    }
                    Button("应用通用设置到核心（config.patch）") {
                        Task { await settingsStore.applyGeneralToCore() }
                    }
                    if let message = settingsStore.generalApplyMessage {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
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
                    Text("iOS 上 TUN 由系统 NetworkExtension 拥有，核心不会自己创建 TUN 设备（见 TUN_INVESTIGATION.md）。这些参数会写入共享 tunnel.json，扩展启动时传给 tun.start（packet-channel 路径）并用于配置隧道接口。改动后需重启 VPN 生效。IPv6 开关（通用里）打开时，隧道接口会同时配置 IPv6 地址 fdfe:dcba:9876::1/126 并接管 IPv6 默认路由；关闭时 IPv6 流量不进隧道。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !settingsStore.tunEnabled {
                        Text("TUN 已关闭：iOS 上 TUN 是唯一的数据面，关闭后启动 VPN 会直接报错。请重新打开后再启动。")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Button("从核心读取 TUN 状态（config.general）") {
                        Task { await settingsStore.refreshTunState() }
                    }
                    if let tun = settingsStore.tunState {
                        LabeledContent("核心 TUN", value: tun.enable == true ? "已启用" : "未启用")
                        LabeledContent("设备", value: tun.device ?? "—")
                        LabeledContent("协议栈", value: tun.stack ?? "—")
                        LabeledContent("自动路由", value: tun.autoRoute == true ? "开" : "关")
                        LabeledContent("MTU", value: tun.mtu.map { "\($0)" } ?? "—")
                        Text("以上是核心报告的 TUN 状态，仅供查看：iOS 上 TUN 由扩展拥有（tun.start / tunnel.json），App 不会发 config.patch tun——那样会停用或替换扩展正在用的 TUN 设备。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let message = settingsStore.tunStateMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
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
                    Button("应用 DNS 设置（重新应用配置）") {
                        Task { await settingsStore.applyDnsSettings() }
                    }
                    if let message = settingsStore.dnsApplyMessage {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text("DNS 设置会写入共享 dns.json，扩展把它并进 config.apply 的 overlay（会覆盖订阅自带的 DNS）。Fake-IP 段须为 a.b.c.d/n 格式。改动后下次启动 VPN 生效；VPN 运行时点「应用」可立即生效。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    NavigationLink("DNS 查询记录") {
                        DnsQueriesView()
                    }
                }

                Section("MITM") {
                    Toggle("启用 MITM", isOn: $settingsStore.mitmEnabled)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmEnabled) { _, _ in settingsStore.save() }
                    TextField("解密主机名（逗号分隔，如 *.example.com）", text: $settingsStore.mitmHostnames)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmHostnames) { _, _ in settingsStore.save() }
                    Toggle("解密 TLS", isOn: $settingsStore.mitmDecryptTls)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmDecryptTls) { _, _ in settingsStore.save() }
                    if let info = settingsStore.mitmCertificate {
                        LabeledContent("CA 主题", value: info.subject)
                        LabeledContent("CA 指纹", value: info.fingerprint)
                        LabeledContent("有效期", value: "\(info.notBefore) 至 \(info.notAfter)")
                        ShareLink("分享 CA 证书（PEM）", item: info.pem)
                    } else {
                        Text("尚未生成 CA 证书。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button("生成 CA 证书（mitm.generateCertificate）") {
                        Task { await settingsStore.generateMitmCertificate() }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    Button("验证 MITM 配置（mitm.validate）") {
                        Task { await settingsStore.validateMitmConfig() }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    Button("应用 MITM 设置（重新应用配置）") {
                        Task { await settingsStore.applyMitmSettings() }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    TextField("签发叶证书的主机名", text: $mitmIssueHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!settingsStore.mitmAvailable)
                    Button("签发叶证书（mitm.issueCertificate）") {
                        Task { await settingsStore.issueMitmCertificate(host: mitmIssueHost) }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    if let pem = settingsStore.mitmIssuedPem {
                        ShareLink("分享叶证书（PEM）", item: pem)
                    }
                    if !settingsStore.mitmIssues.isEmpty {
                        ForEach(settingsStore.mitmIssues, id: \.self) { issue in
                            Text(issue).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    if let message = settingsStore.mitmStatusMessage {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text("安装 CA 到系统信任（必须手动完成）：App 无法以编程方式安装受信任 CA。分享上面的 CA 证书，在 iPhone「设置 → 通用 → VPN 与设备管理」里安装，再到「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任。未安装时 HTTPS 只做透传，仅明文 HTTP 可改写。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    NavigationLink("MITM 拦截记录") {
                        MitmView()
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    if !settingsStore.mitmAvailable {
                        Text("MITM 当前不可用：核心未报告 mitm 能力（core.capabilities features.mitm），或隧道未运行。请先启动 VPN。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("提供方（provider.list）") {
                    NavigationLink("查看全部提供方") {
                        ProvidersView()
                    }
                    Text("代理提供方 \(ruleStore.providers.filter { $0.type == "proxy" }.count) 个 · 规则提供方 \(ruleStore.ruleProviders.count) 个")
                        .font(.system(size: 10))
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
                         : "实时核心模式：数据来自 PacketTunnel 扩展内的真实核心（需先启动 VPN）。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("App 图标") {
                    NavigationLink("切换 App 图标") {
                        AppIconPickerView()
                    }
                    Text("在 App 内切换主屏幕图标（默认 / 墨黑 / 曜青 / 雪白），用的是系统公开接口。切换失败时页面会显示完整错误信息。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("主题") {
                    NavigationLink("外观与主题色") {
                        ThemePickerView()
                    }
                    Text("浅色 / 深色 / 跟随系统，外加 5 种主题色。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("备份与恢复") {
                    NavigationLink("备份与恢复") {
                        BackupView()
                    }
                    Text("把全部订阅、设置和 MITM 模块导出成一个备份文件，或从备份文件恢复。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // The reference Tools page (IMG_1111) has no rows for
                // these four pages, so they moved here from ToolsView
                // to stay reachable: 规则 / 日志 / IP 质量 / 快捷指令.
                Section("更多工具") {
                    NavigationLink("规则") {
                        RulesView()
                    }
                    NavigationLink("日志") {
                        LogsView()
                    }
                    NavigationLink("IP 质量") {
                        IPQualityView()
                    }
                    NavigationLink("快捷指令") {
                        ShortcutsView()
                    }
                }

                if settingsStore.developerMode {
                    Section("开发者（core.capabilities）") {
                        Button("读取核心能力") {
                            Task { await settingsStore.refreshDeveloperInfo() }
                        }
                        if let capabilities = settingsStore.capabilities {
                            LabeledContent("实现", value: "\(capabilities.implementation) \(capabilities.version)")
                            LabeledContent("代理类型", value: capabilities.proxyTypes.joined(separator: ", "))
                            LabeledContent("传输", value: capabilities.transports.joined(separator: ", "))
                            LabeledContent("规则类型", value: capabilities.ruleTypes.joined(separator: ", "))
                            LabeledContent("MITM", value: capabilities.features.mitm ? "支持" : "不支持")
                            LabeledContent("ECH", value: capabilities.features.ech ? "支持" : "不支持")
                            LabeledContent("系统协议栈", value: capabilities.features.systemStack ? "支持" : "不支持")
                            LabeledContent("SS 插件", value: capabilities.ssPlugins.isEmpty ? "—" : capabilities.ssPlugins.joined(separator: ", "))
                            LabeledContent("拥塞控制", value: capabilities.congestionControllers.isEmpty ? "—" : capabilities.congestionControllers.joined(separator: ", "))
                        } else {
                            Text("点「读取核心能力」查看核心报告的能力（需 VPN 运行）。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let message = settingsStore.developerInfoMessage {
                            Text(message).font(.system(size: 10)).foregroundStyle(.red)
                        }
                        Picker("MITM 内存压力（core.setPressure）", selection: $settingsStore.pressureLevel) {
                            Text("0 无压力").tag(0)
                            Text("1 停止脚本").tag(1)
                            Text("2 停止保存请求体").tag(2)
                            Text("3 仅中继").tag(3)
                        }
                        Button("设置内存压力") {
                            Task { await settingsStore.setPressure(level: settingsStore.pressureLevel) }
                        }
                        if let message = settingsStore.pressureMessage {
                            Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text("压力只升不降（核心在一段时间后自动解除），只影响 MITM 抓包的内存占用：等级 1 停止运行脚本、2 停止保存请求体、3 仅中继流量。MITM 关闭时不起作用。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button("让核心崩溃（debug.crash）", role: .destructive) {
                            showCrashConfirm = true
                        }
                        .alert("确定要让核心崩溃吗？", isPresented: $showCrashConfirm) {
                            Button("崩溃", role: .destructive) {
                                Task { await settingsStore.crashCore() }
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("debug.crash 会让核心进程立即中止，VPN 隧道随之断开，仅用于调试。注意：iOS 的发布版核心没有编译 debug 功能，调用会被核心拒绝，实际不会崩溃。")
                        }
                        if let message = settingsStore.crashMessage {
                            Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "Concord iOS 0.2.21（FlClash 风格界面）")
                    LabeledContent("核心", value: "chen08209/concord（GPL-3.0-or-later）")
                    LabeledContent("界面来源", value: "chen08209/FlClash（GPL-3.0）")
                    Text("本 App 是 FlClash 界面的 SwiftUI 复刻，核心经 PacketTunnel 扩展链接（packet-channel 数据面），但静态库构建与真机数据面尚未验证，见 README 的「已上线与待办」一节。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .tint(ConcordTheme.accent)
            .navigationTitle("常规")
            .onChange(of: settingsStore.mode) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.logLevel) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.allowLan) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.ipv6) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.tunEnabled) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.autoRun) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.autoCloseConnections) { _, value in
                profileStore.autoCloseConnections = value
                settingsStore.save()
            }
            .onChange(of: settingsStore.checkCertificate) { _, value in
                profileStore.checkCertificate = value
                settingsStore.save()
            }
            .onChange(of: settingsStore.autoCheckUpdate) { _, _ in settingsStore.save() }
            .onChange(of: settingsStore.openLogs) { _, _ in settingsStore.save() }
            .task {
                if client.mode == .live {
                    await settingsStore.refreshMitmStatus()
                }
            }
    }
}

// MARK: - DNS queries (FlClash: DnsQueriesView, lib/views/dns_queries.dart)

struct DnsQueriesView: View {
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var client: ConcordClient
    @State private var queryName = ""
    @State private var queryType = "A"
    @State private var selectedEntry: ConcordDnsEntry?

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("DNS 记录为示例数据")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            Section("手动查询（dns.query）") {
                HStack {
                    TextField("域名，如 www.google.com", text: $queryName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker("类型", selection: $queryType) {
                        Text("A").tag("A")
                        Text("AAAA").tag("AAAA")
                        Text("MX").tag("MX")
                        Text("TXT").tag("TXT")
                        Text("CNAME").tag("CNAME")
                    }
                    .pickerStyle(.menu)
                }
                Button("查询") {
                    Task { await dnsStore.query(name: queryName, qtype: queryType) }
                }
                .disabled(queryName.trimmingCharacters(in: .whitespaces).isEmpty)
                if let result = dnsStore.queriedResult {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("返回码 \(result.rcode) · 应答 \(result.answers.count) 条")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        ForEach(result.answers, id: \.data) { record in
                            Text("\(record.name) → \(record.data)（TTL \(record.ttl)）")
                                .font(.system(size: 10))
                        }
                        if !result.authorities.isEmpty {
                            Text("权威记录 \(result.authorities.count) 条")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = dnsStore.queryError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            Section {
                Button("清除 DNS 缓存（dns.clearCache）") {
                    Task { await dnsStore.clearCache() }
                }
                Button("清除 Fake-IP 映射（dns.flushFakeIp）") {
                    Task { await dnsStore.flushFakeIp() }
                }
                if let message = dnsStore.lastActionMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.green)
                }
            }
            Section("查询记录（dns.watch）") {
                if dnsStore.filtered.isEmpty {
                    Text("暂无 DNS 查询记录")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dnsStore.filtered) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.domain).font(.system(size: 13))
                                    Spacer()
                                    Text(entry.type)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                                Text("上游 \(entry.upstream) · \(entry.delay) ms · \(entry.cached == true ? "缓存命中" : "实时查询")")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text("应答：\(entry.answers.joined(separator: ", "))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(ConcordFormat.time(entry.time))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
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
        .sheet(item: $selectedEntry) { entry in
            DnsEntryDetailView(entry: entry)
        }
    }
}

/// One DNS query's full detail (FlClash: DnsQueriesView detail
/// sheet): time, domain, type, initiator, upstream, cached,
/// rcode, delay, answers, error, plus a copy button.
private struct DnsEntryDetailView: View {
    let entry: ConcordDnsEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("查询") {
                    detailRow("时间", ConcordFormat.time(entry.time))
                    detailRow("域名", entry.domain)
                    detailRow("类型", entry.type)
                    detailRow("发起方", entry.initiator)
                    detailRow("上游", entry.upstream)
                    detailRow("缓存", entry.cached == true ? "命中" : "未命中")
                    detailRow("返回码", entry.rcode ?? "—")
                    detailRow("延迟", "\(entry.delay) ms")
                }
                Section("应答") {
                    if entry.answers.isEmpty {
                        Text("无应答记录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.answers, id: \.self) { answer in
                            Text(answer)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if let error = entry.error {
                    Section("错误") {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(copied ? "已复制" : "复制详情") {
                        UIPasteboard.general.string = """
                        \(entry.domain) \(entry.type)
                        上游：\(entry.upstream)
                        返回码：\(entry.rcode ?? "—")
                        延迟：\(entry.delay) ms
                        应答：\(entry.answers.joined(separator: ", "))
                        """
                        copied = true
                    }
                }
            }
            .navigationTitle("DNS 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Providers (FlClash: providers view, lib/views/config/providers.dart)

struct ProvidersView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient
    @State private var sideLoadName = ""
    @State private var sideLoadText = ""

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("提供方为示例数据")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(ruleStore.providers) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(provider.name).font(.system(size: 13))
                        Spacer()
                        Text(provider.type)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                    }
                    Text("\(provider.vehicleType) · \(provider.count) 条 · \(provider.path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let updated = provider.updatedAt {
                        Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("详情") {
                        Task { await ruleStore.loadProviderDetail(provider) }
                    }
                    .tint(.blue)
                    Button("健康检查") {
                        Task { await ruleStore.healthCheckProvider(provider) }
                    }
                    .tint(.green)
                    Button("更新") {
                        Task {
                            do {
                                try await client.providerUpdate(name: provider.name)
                                await ruleStore.refresh()
                            } catch {
                                ruleStore.lastError = error.localizedDescription
                            }
                        }
                    }
                    .tint(.orange)
                }
            }
            Section("本地载入提供方（provider.sideLoad）") {
                TextField("提供方名称", text: $sideLoadName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextEditor(text: $sideLoadText)
                    .frame(minHeight: 100)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button("载入") {
                    Task { await ruleStore.sideLoadProvider(name: sideLoadName, data: sideLoadText) }
                }
                .disabled(sideLoadName.trimmingCharacters(in: .whitespaces).isEmpty || sideLoadText.isEmpty)
                Text("把提供方文件内容（YAML / MRS / 文本）直接贴进来，核心会把它存到该名称下。只处理本地内容，不联网拉取。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let message = ruleStore.providerActionMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let error = ruleStore.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("提供方")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("地理数据库") {
                    Button("更新 GeoIP（MMDB）") {
                        Task { await ruleStore.geoUpdate(kind: "MMDB") }
                    }
                    Button("更新 ASN（ASN）") {
                        Task { await ruleStore.geoUpdate(kind: "ASN") }
                    }
                    Button("更新 GeoSite（GEOSITE）") {
                        Task { await ruleStore.geoUpdate(kind: "GEOSITE") }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await ruleStore.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await ruleStore.refresh() }
        .sheet(isPresented: Binding(
            get: { ruleStore.providerDetail != nil },
            set: { if !$0 { ruleStore.providerDetail = nil } }
        )) {
            if let detail = ruleStore.providerDetail {
                ProviderDetailView(provider: detail)
            }
        }
    }
}

// MARK: - Resources (FlClash: ResourcesView, lib/views/resources.dart)

struct ResourcesView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    @State private var releaseMessage: String?
    @State private var geoFiles: [GeoFileInfo] = []
    @AppStorage("ConcordiOS.geoAutoUpdate") private var geoAutoUpdate = false
    @AppStorage("ConcordiOS.geoAutoUpdateHours") private var geoAutoUpdateHours = 24.0

    /// One Geo file found in the App Group container.
    struct GeoFileInfo: Identifiable {
        var id: String { name }
        let name: String
        let size: Int64
        let modified: Date?
    }

    var body: some View {
        List {
            Section("核心") {
                LabeledContent("内存占用", value: trafficStore.coreMemoryBytes.map { ConcordFormat.bytes(Int64($0)) } ?? "—")
                Text("core.stats 只暴露 rss。NetworkExtension 进程内存上限很紧（历史约 15–50 MB），大规则集与 GeoIP 可能触发 Jetsam。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("释放核心内存（core.releaseMemory）") {
                    Task {
                        do {
                            try await client.coreReleaseMemory()
                            await trafficStore.refreshMemory()
                            releaseMessage = "已请求核心释放内存"
                        } catch {
                            releaseMessage = "释放失败：\(error.localizedDescription)"
                        }
                    }
                }
                if let message = releaseMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Section("已加载") {
                LabeledContent("代理组", value: "\(proxyStore.groups.count)")
                LabeledContent("节点", value: "\(proxyStore.allNodes.count)")
                LabeledContent("规则", value: "\(ruleStore.rules.count)")
                LabeledContent("提供方", value: "\(ruleStore.providers.count)")
                LabeledContent("规则提供方", value: "\(ruleStore.ruleProviders.count)")
                LabeledContent("MITM 模块", value: "\(mitmModuleStore.modules.filter(\.enabled).count) / \(mitmModuleStore.modules.count) 已启用")
            }
            Section("Geo 资源") {
                Toggle("自动更新", isOn: $geoAutoUpdate)
                if geoAutoUpdate {
                    HStack {
                        Text("更新间隔")
                        Spacer()
                        Picker("", selection: $geoAutoUpdateHours) {
                            Text("12 小时").tag(12.0)
                            Text("24 小时").tag(24.0)
                            Text("72 小时").tag(72.0)
                            Text("每周").tag(168.0)
                        }
                        .pickerStyle(.menu)
                    }
                }
                if geoFiles.isEmpty {
                    Text("容器里没有找到 Geo 文件（MMDB / ASN / GeoSite）。点下面按钮更新，核心会在后台下载。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(geoFiles) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.system(size: 13))
                            Text("\(ConcordFormat.bytes(file.size))\(file.modified.map { " · 更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("更新 GeoIP（MMDB）") {
                    Task { await ruleStore.geoUpdate(kind: "MMDB") }
                }
                Button("更新 ASN（ASN）") {
                    Task { await ruleStore.geoUpdate(kind: "ASN") }
                }
                Button("更新 GeoSite（GEOSITE）") {
                    Task { await ruleStore.geoUpdate(kind: "GEOSITE") }
                }
                Text("concord 的 geo.update 只支持 MMDB、ASN、GEOSITE 三种，没有 GEOIP。更新在后台进行，完成后文件会出现在容器里。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let message = ruleStore.providerActionMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let error = ruleStore.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            Section {
                Button("刷新") {
                    Task {
                        await trafficStore.refreshMemory()
                        await proxyStore.refresh()
                        await ruleStore.refresh()
                        scanGeoFiles()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("资源")
        .task {
            scanGeoFiles()
        }
    }

    /// Scan the App Group container root for Geo database files.
    /// The core's home is the container itself, so its MMDB / ASN /
    /// GeoSite files land here; the names are matched loosely
    /// because the core does not publish them through the API.
    private func scanGeoFiles() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: container.path) else {
            geoFiles = []
            return
        }
        geoFiles = names.compactMap { name in
            let lower = name.lowercased()
            guard lower.contains("mmdb") || lower.contains("geo") || lower.contains("asn")
                    || lower.contains("country") || lower.hasSuffix(".dat") else {
                return nil
            }
            let url = container.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attributes?[.modificationDate] as? Date
            return GeoFileInfo(name: name, size: size, modified: modified)
        }.sorted { $0.name < $1.name }
    }
}
