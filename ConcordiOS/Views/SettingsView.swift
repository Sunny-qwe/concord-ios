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
    // User-imported group icon pack (Settings → 图标源). A shared
    // singleton, not an environment object: the Proxies page reads
    // it through its icon leaf views only, never at page level.
    @ObservedObject private var iconPack = IconPackStore.shared
    @State private var mitmIssueHost = ""
    @State private var showCrashConfirm = false
    @State private var showMitmEnableConfirm = false
    // FlClash general/port_form.dart: HTTP / redir / tproxy ports
    // (0 = disabled, otherwise 1024–49151, no conflicts) and the
    // find-process-mode picker (strict/always/off, default strict)
    // + MITM h2 / decrypt-untrusted. These live in @AppStorage
    // until the SettingsStore owner wires them into general.json /
    // mitm.json (see the v0.2.32 handoff: keys port, redir-port,
    // tproxy-port, find-process-mode, h2, decrypt-tls).
    @AppStorage("ConcordiOS.httpPort") private var httpPort = 0
    @AppStorage("ConcordiOS.redirPort") private var redirPort = 0
    @AppStorage("ConcordiOS.tproxyPort") private var tproxyPort = 0
    @AppStorage("ConcordiOS.mitmH2") private var mitmH2 = false
    @AppStorage("ConcordiOS.mitmDecryptUntrusted") private var mitmDecryptUntrusted = false

    /// The app's own version (Info.plist CFBundleShortVersionString),
    /// never a hardcoded string.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Port validation (FlClash port_form.dart:118-152): mixed is
    /// required 1024–49151; the others allow 0 (disabled); no two
    /// enabled ports may share a value.
    private var portIssue: String? {
        var seen: [Int: String] = [:]
        let ports: [(String, Int, Bool)] = [
            ("混合", settingsStore.mixedPort, false),
            ("SOCKS", settingsStore.socksPort, true),
            ("HTTP", httpPort, true),
            ("redir", redirPort, true),
            ("tproxy", tproxyPort, true),
        ]
        for (label, port, allowDisabled) in ports {
            if port == 0 {
                if !allowDisabled { return "混合端口必填，不能为 0" }
                continue
            }
            if port < 1024 || port > 49151 {
                return "\(label)端口应在 1024–49151 之间（0 表示停用）"
            }
            if let other = seen[port] {
                return "\(label)端口与\(other)端口冲突"
            }
            seen[port] = label
        }
        return nil
    }

    private var mitmHostnameSummary: String {
        let count = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.count
        return count == 0 ? "未设置" : "\(count) 个域名"
    }

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (The DNS / providers / resources sub-pages below are
        // pushed onto the same stack.)
        Form {
                // Row order follows FlClash GeneralView
                // (lib/views/config/general.dart:396-442): 启动与后台 /
                // 请求与更新 / 入站 / 连接 / 日志与诊断. 出站模式、流量
                // 嗅探、TCP 并发、统一延迟、IPv6 直连开关是本应用自有
                // 的行，FlClash 的 常规 里没有，保留并在报告里列出。
                Section("通用（config.general）") {
                    Picker("出站模式", selection: $settingsStore.mode) {
                        ForEach(OutboundMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("启动时自动连接", isOn: $settingsStore.autoRun)
                    NavigationLink {
                        UserAgentsView()
                    } label: {
                        HStack {
                            Text("全局 User-Agent")
                            Spacer()
                            Text(settingsStore.globalUa.isEmpty ? "默认" : settingsStore.globalUa)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Toggle("校验订阅证书", isOn: $settingsStore.checkCertificate)
                    Toggle("启动时自动检查更新", isOn: $settingsStore.autoCheckUpdate)
                    Toggle("隐藏出口 IP", isOn: $settingsStore.hideIp)
                    Stepper("混合端口：\(settingsStore.mixedPort)", value: $settingsStore.mixedPort, in: 1024...49151)
                    Stepper("SOCKS 端口：\(settingsStore.socksPort == 0 ? "停用" : "\(settingsStore.socksPort)")", value: $settingsStore.socksPort, in: 0...49151)
                    Stepper("HTTP 端口：\(httpPort == 0 ? "停用" : "\(httpPort)")", value: $httpPort, in: 0...49151)
                        .onChange(of: httpPort) { _, _ in settingsStore.save() }
                    Stepper("redir 端口：\(redirPort == 0 ? "停用" : "\(redirPort)")", value: $redirPort, in: 0...49151)
                        .onChange(of: redirPort) { _, _ in settingsStore.save() }
                    Stepper("tproxy 端口：\(tproxyPort == 0 ? "停用" : "\(tproxyPort)")", value: $tproxyPort, in: 0...49151)
                        .onChange(of: tproxyPort) { _, _ in settingsStore.save() }
                    if let portIssue {
                        Text(portIssue)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Button("恢复默认端口（混合 7890、SOCKS 7891，其余停用）") {
                        settingsStore.mixedPort = 7890
                        settingsStore.socksPort = 7891
                        httpPort = 0
                        redirPort = 0
                        tproxyPort = 0
                        settingsStore.save()
                    }
                    Text("端口 0 表示停用；启用的端口须在 1024–49151 之间且互不冲突。HTTP / redir / tproxy 在 iOS 上一般用不到，FlClash 仍在 iOS 上提供这三项，这里同样提供。改动在下次启动 VPN 或点「应用通用设置到核心」后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("允许局域网连接", isOn: $settingsStore.allowLan)
                    NavigationLink("鉴权与外部控制器") {
                        GeneralAuthView()
                    }
                    Stepper("延迟测试超时：\(settingsStore.delayTestTimeout) ms", value: $settingsStore.delayTestTimeout, in: 500...8000, step: 500)
                    // B4: three states, not a toggle — the old
                    // always/off switch forced "off" on everyone who
                    // never touched it, disabling PROCESS-NAME /
                    // PROCESS-PATH rules. Default strict = the core
                    // default; the picked value travels via
                    // general-overlay.json (SettingsStore).
                    Picker("进程查找方式", selection: $settingsStore.findProcessModeSetting) {
                        Text("默认（strict）").tag("strict")
                        Text("始终（always）").tag("always")
                        Text("关闭（off）").tag("off")
                    }
                    Text("进程查找方式：默认 strict（核心默认）；always 始终按进程匹配，off 关闭进程匹配。核心当前报告：\(settingsStore.findProcessMode ?? "未知")。改动在下次启动 VPN 或点「应用通用设置到核心」后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("切换配置后自动关闭连接", isOn: $settingsStore.autoCloseConnections)
                    Toggle("流量嗅探", isOn: $settingsStore.sniffing)
                        // B6: the master switch only takes effect
                        // when sniffer.json is re-saved (effective
                        // enable = master && page switch).
                        // SettingsStore.save() also propagates it;
                        // this makes the wiring explicit at the
                        // switch itself.
                        .onChange(of: settingsStore.sniffing) { _, _ in SnifferStore.shared.save() }
                    Toggle("TCP 并发", isOn: $settingsStore.tcpConcurrent)
                    Toggle("统一延迟测试", isOn: $settingsStore.unifiedDelay)
                    // TCP 保活（核心 keep-alive-idle / interval /
                    // disable-keep-alive；0 = 核心默认，空闲 15 秒）。
                    // 经 general-overlay.json 下发（config.patch 没有
                    // 这三个字段），下次启动 VPN 或点「应用通用设置到
                    // 核心」后生效。
                    Stepper("TCP 保活空闲：\(settingsStore.keepAliveIdle) 秒", value: $settingsStore.keepAliveIdle, in: 0...3600, step: 15)
                    Stepper("TCP 保活间隔：\(settingsStore.keepAliveInterval) 秒", value: $settingsStore.keepAliveInterval, in: 0...3600, step: 15)
                    Toggle("禁用 TCP 保活", isOn: $settingsStore.disableKeepAlive)
                    Text("保活空闲 / 间隔为 0 表示用核心默认（空闲 15 秒）。改动在下次启动 VPN 或点「应用通用设置到核心」后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("IPv6", isOn: $settingsStore.ipv6)
                    Picker("日志级别", selection: $settingsStore.logLevel) {
                        ForEach(LogLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    // v0.2.40: the "记录日志" toggle is gone — it only
                    // gated the Tools "日志" row, which is now always
                    // shown (users could not find the log page).
                    Text("启动时自动连接：打开应用后自动启动 VPN（需已有配置）。校验订阅证书：关闭后订阅下载不再验证服务器证书（自签证书的订阅源可用）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("从核心读取当前配置") {
                        Task { await settingsStore.refreshFromCore() }
                    }
                    Button("应用通用设置到核心（config.patch）") {
                        Task { await settingsStore.applyGeneralToCore() }
                    }
                    if let message = settingsStore.generalApplyMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // FlClash GeneralView 的「核心」OverrideSection
                // (general/overrides.dart:7-13): 测速地址、统一延迟、
                // TCP 并发、IPv6、地理数据加载方式 5 项内联在 常规 里
                // （自带「通用」组头），Hosts 也在该区
                // （general.dart _coreItems）。覆盖只对启用的项生效；
                // 没启用的项用订阅自己的值。
                OverrideSectionEditor(section: .general, scope: .constant(nil))
                Section("核心（覆盖）") {
                    NavigationLink("Hosts") {
                        HostsView()
                    }
                    Text("上面的 5 项是覆盖：启用后才生效，作用于全部订阅；单个订阅的覆盖（设置 → 配置 → 覆盖）优先于这里。Hosts 在这里改，核心在 DNS 查询前先查这张表。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    NavigationLink("TUN 覆盖（拥塞控制、路由、劫持…）") {
                        TunOverrideView()
                    }
                    Text("iOS 上 TUN 由系统 NetworkExtension 拥有，核心不会自己创建 TUN 设备（见 TUN_INVESTIGATION.md）。这些参数会写入共享 tunnel.json，扩展启动时传给 tun.start（packet-channel 路径）并用于配置隧道接口。改动后需重启 VPN 生效。IPv6 开关（通用里）打开时，隧道接口会同时配置 IPv6 地址 fdfe:dcba:9876::1/126 并接管 IPv6 默认路由；关闭时 IPv6 流量不进隧道。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !settingsStore.tunEnabled {
                        Text("TUN 已关闭：iOS 上 TUN 是唯一的数据面，关闭后启动 VPN 会直接报错。请重新打开后再启动。")
                            .font(.caption2)
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let message = settingsStore.tunStateMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("DNS") {
                    Toggle("启用 DNS", isOn: $settingsStore.dnsEnabled)
                    TextField("DoH 上游", text: $settingsStore.dnsNameserver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("Fake-IP", isOn: $settingsStore.dnsFakeIpEnabled)
                        .onChange(of: settingsStore.dnsFakeIpEnabled) { _, value in
                            settingsStore.dnsEnhancedMode = value ? "fake-ip" : "normal"
                            settingsStore.save()
                        }
                    TextField("Fake-IP 段", text: $settingsStore.dnsFakeIpRange)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("应用 DNS 设置（重新应用配置）") {
                        Task { await settingsStore.applyDnsSettings() }
                    }
                    if let message = settingsStore.dnsApplyMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("DNS 设置会写入共享 dns.json，扩展把它并进 config.apply 的 overlay（会覆盖订阅自带的 DNS）。Fake-IP 段须为 a.b.c.d/n 格式。改动后下次启动 VPN 生效；VPN 运行时点「应用」可立即生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    NavigationLink("DNS 查询记录") {
                        DnsQueriesView()
                    }
                    NavigationLink("更多 DNS 设置") {
                        DnsSettingsView()
                    }
                }

                Section("配置") {
                    NavigationLink("覆盖（全局 / 按订阅）") {
                        OverrideView()
                    }
                    NavigationLink("NTP") {
                        NtpSettingsView()
                    }
                    NavigationLink("按需连接") {
                        OnDemandView()
                    }
                    NavigationLink("嗅探") {
                        SnifferSettingsView()
                    }
                    Text("覆盖：对通用、DNS、TUN、嗅探、NTP 的逐项覆盖，分全局和单个订阅两级，带 YAML 预览。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // MITM 选项按上游 FlClash mitm.dart 一页式布局重排
                // (v0.2.43 E1; fork ac90aeb 改前即真上游): 启用/捕获
                // 置顶，证书组第二，模块与主机名随后，四个选项开关
                // 在"选项"组按上游顺序。只移动行，不改任何 wiring；
                // ours-only 行（解密 TLS、验证、签发叶证书、拦截记录
                // 入口等）原地保留在就近的组里。
                Section {
                    // FlClash mitm.dart:509-540: 开启要先确认，没有 CA
                    // 时自动生成一张；关闭直接关。
                    Toggle("启用 MITM", isOn: Binding(
                        get: { settingsStore.mitmEnabled },
                        set: { newValue in
                            if newValue {
                                showMitmEnableConfirm = true
                            } else {
                                settingsStore.mitmEnabled = false
                                settingsStore.save()
                            }
                        }
                    ))
                    .disabled(!settingsStore.mitmAvailable)
                    .onChange(of: settingsStore.mitmEnabled) { _, _ in settingsStore.save() }
                    .alert("启用 HTTPS 解密吗？", isPresented: $showMitmEnableConfirm) {
                        Button("启用") {
                            settingsStore.mitmEnabled = true
                            settingsStore.save()
                            if settingsStore.mitmCertificate == nil {
                                Task { await settingsStore.generateMitmCertificate() }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("开启后，本应用会用自己的 CA 解密你勾选的域名的 HTTPS 流量，用于模块改写与脚本。还没有 CA 证书时会自动生成一张；生成后还需要在 iPhone「设置」里安装并完全信任它，解密才会真正生效。")
                    }
                    Toggle("捕获拦截记录", isOn: $settingsStore.mitmCapture)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmCapture) { _, _ in settingsStore.save() }
                    Picker("最多保留条数", selection: $settingsStore.mitmCaptureEntries) {
                        Text("16").tag(16)
                        Text("32").tag(32)
                        Text("64").tag(64)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settingsStore.mitmAvailable || !settingsStore.mitmCapture)
                    .onChange(of: settingsStore.mitmCaptureEntries) { _, _ in settingsStore.save() }
                    Text("开启后拦截记录才会保存；iOS 上限 64 条（1 MB）。改动下次启动 VPN 后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("验证 MITM 配置（mitm.validate）") {
                        Task { await settingsStore.validateMitmConfig() }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    Button("应用 MITM 设置（重新应用配置）") {
                        Task { await settingsStore.applyMitmSettings() }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                }

                Section {
                    if let info = settingsStore.mitmCertificate {
                        LabeledContent("CA 主题", value: info.subject)
                        LabeledContent("CA 指纹", value: info.fingerprint)
                        LabeledContent("有效期", value: "\(info.notBefore) 至 \(info.notAfter)")
                        ShareLink("分享 CA 证书（PEM）", item: info.pem)
                    } else {
                        Text("尚未生成 CA 证书。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("生成 CA 证书（mitm.generateCertificate）") {
                        Task { await settingsStore.generateMitmCertificate() }
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
                } footer: {
                    Text("安装 CA 到系统信任（必须手动完成）：App 无法以编程方式安装受信任 CA。分享上面的 CA 证书，在 iPhone「设置 → 通用 → VPN 与设备管理」里安装，再到「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任。未安装时 HTTPS 只做透传，仅明文 HTTP 可改写。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("MITM 模块") {
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
                }

                Section {
                    NavigationLink {
                        MitmHostnameEditorView()
                    } label: {
                        HStack {
                            Text("解密主机名")
                            Spacer()
                            Text(mitmHostnameSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .disabled(!settingsStore.mitmAvailable)
                }

                Section {
                    Toggle("跳过服务端证书验证", isOn: $settingsStore.mitmSkipServerCertVerify)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmSkipServerCertVerify) { _, _ in settingsStore.save() }
                    Text("只跳过上游服务器证书的验证（测试自签服务时用）；开启后中间人可伪造服务器证书，不要长期开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("阻止 QUIC", isOn: $settingsStore.mitmAutoQuicBlock)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmAutoQuicBlock) { _, _ in settingsStore.save() }
                    Text("默认开启：QUIC 把 TLS 握手藏在 UDP 里，解密不了；阻止后客户端回落到 TCP + TLS 才能解密。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("启用 HTTP/2（h2）", isOn: $mitmH2)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: mitmH2) { _, _ in settingsStore.save() }
                    Text("改动随 MITM 配置保存，下次启动 VPN 或重载配置后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("解密 TLS", isOn: $settingsStore.mitmDecryptTls)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmDecryptTls) { _, _ in settingsStore.save() }
                    Toggle("解密不受信任的证书", isOn: $mitmDecryptUntrusted)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: mitmDecryptUntrusted) { _, _ in settingsStore.save() }
                    Text("上游 decrypt-untrusted：打开后，即使服务器证书不受信任也解密。发给核心的 decrypt-tls = 解密不受信任的证书 || 已填受信任的服务器证书指纹（FlClash clash_config.dart:2322-2323）。改动随 MITM 配置保存，下次启动 VPN 或重载配置后生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("受信任的服务器证书指纹（可选）", text: $settingsStore.mitmTrustedFingerprint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmTrustedFingerprint) { _, _ in settingsStore.save() }
                    Text("填入某个服务器证书的 SHA-256 指纹后，只信任该指纹的证书（解密 TLS 随之开启）；留空则用本应用 CA 的指纹。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("选项")
                }

                Section {
                    if !settingsStore.mitmIssues.isEmpty {
                        ForEach(settingsStore.mitmIssues, id: \.self) { issue in
                            Text(issue).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if let message = settingsStore.mitmStatusMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("MITM 拦截记录") {
                        MitmView()
                    }
                    .disabled(!settingsStore.mitmAvailable)
                    if !settingsStore.mitmAvailable {
                        Text("MITM 当前不可用：核心未报告 mitm 能力（core.capabilities features.mitm），或隧道未运行。请先启动 VPN。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("提供方（provider.list）") {
                    NavigationLink("查看全部提供方") {
                        ProvidersView()
                    }
                    Text("代理提供方 \(ruleStore.providers.filter { $0.type == "proxy" }.count) 个 · 规则提供方 \(ruleStore.ruleProviders.count) 个")
                        .font(.caption2)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Group icon pack (v0.2.53): the user pastes the URL
                // of an icon-pack JSON file (iBL3ND format) and taps
                // 导入 / 更新; the pack is downloaded once, stored
                // locally, and group icons resolve from it by name.
                // There are no bundled brand icons — the pack is the
                // only icon source besides a group's own profile
                // icon. The field starts empty; nothing is fetched
                // until the button is tapped.
                Section("图标源") {
                    TextField("图标源链接（JSON）", text: $iconPack.urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button(iconPack.iconCount > 0 ? "更新" : "导入") {
                            Task { await iconPack.importPack() }
                        }
                        .disabled(iconPack.isImporting || iconPack.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if iconPack.isImporting {
                            ProgressView()
                        } else if iconPack.iconCount > 0 {
                            Button("删除", role: .destructive) {
                                iconPack.clearPack()
                            }
                        }
                    }
                    if let name = iconPack.packName, iconPack.iconCount > 0 {
                        LabeledContent("图标包", value: name)
                        LabeledContent("图标数量", value: "\(iconPack.iconCount) 个")
                        if let date = iconPack.fetchedAt {
                            LabeledContent("上次更新", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    } else {
                        Text("粘贴一个图标源链接（JSON，iBL3ND 格式），导入后策略组会按名称自动匹配图标。留空表示不使用图标源。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = iconPack.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let notice = iconPack.noticeMessage {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("settings.appIcon".l10n) {
                    NavigationLink("切换 App 图标") {
                        AppIconPickerView()
                    }
                    Text("在 App 内切换主屏幕图标（默认 / 墨黑 / 曜青 / 雪白），用的是系统公开接口。切换失败时页面会显示完整错误信息。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("settings.theme".l10n) {
                    NavigationLink("外观与主题色") {
                        ThemePickerView()
                    }
                    Text("浅色 / 深色 / 跟随系统，外加 8 种主题色。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("settings.backup".l10n) {
                    NavigationLink("备份与恢复") {
                        BackupView()
                    }
                    Text("把全部订阅、设置和 MITM 模块导出成一个备份文件，或从备份文件恢复。")
                        .font(.caption2)
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
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let message = settingsStore.developerInfoMessage {
                            Text(message).font(.caption2).foregroundStyle(.red)
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
                            Text(message).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("压力只升不降（核心在一段时间后自动解除），只影响 MITM 抓包的内存占用：等级 1 停止运行脚本、2 停止保存请求体、3 仅中继流量。MITM 关闭时不起作用。")
                            .font(.caption2)
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
                            Text(message).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "Concord iOS \(Self.appVersion)（FlClash 风格界面）")
                    LabeledContent("核心", value: "chen08209/concord（GPL-3.0-or-later）")
                    LabeledContent("界面来源", value: "chen08209/FlClash（GPL-3.0）")
                    Text("本 App 是 FlClash 界面的 SwiftUI 复刻，核心经 PacketTunnel 扩展链接（packet-channel 数据面），但静态库构建与真机数据面尚未验证，见 README 的「已上线与待办」一节。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .tint(ConcordTheme.accent)
            .navigationTitle("title.settings".l10n)
            .navigationBarTitleDisplayMode(.inline)
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
            .task {
                if client.mode == .live {
                    await settingsStore.refreshMitmStatus()
                }
            }
    }
}

// MARK: - DNS queries (FlClash: DnsQueriesView, lib/views/dns_queries.dart)

/// Record-list filter: all, failed only, cache hits, live lookups.
private enum DnsRecordFilter: String, CaseIterable {
    case all, errors, cached, live

    var title: String {
        switch self {
        case .all: return "全部"
        case .errors: return "错误"
        case .cached: return "缓存命中"
        case .live: return "实时查询"
        }
    }

    func matches(_ entry: ConcordDnsEntry) -> Bool {
        switch self {
        case .all: return true
        case .errors: return DnsErrorRow.isFailed(entry)
        case .cached: return entry.cached == true
        case .live: return entry.cached != true
        }
    }
}

/// One displayed DNS row after folding (C10): the newest entry of
/// a run of identical consecutive rows, plus how many it stands for.
private struct FoldedDnsEntry: Identifiable {
    var id: String { entry.id }
    let entry: ConcordDnsEntry
    let count: Int
}

struct DnsQueriesView: View {
    @EnvironmentObject private var dnsStore: DnsStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: ConcordClient
    @State private var queryName = ""
    @State private var queryType = "A"
    @State private var selectedEntry: ConcordDnsEntry?
    @State private var recordFilter: DnsRecordFilter = .all
    /// Record-type facet (FlClash dns_queries.dart: the type facet
    /// of dnsQueryFacets): the types present in the current list.
    @State private var selectedType: String?

    /// Search text first (DnsStore.filtered), then the group filter,
    /// then the record-type facet.
    private var visibleEntries: [ConcordDnsEntry] {
        dnsStore.filtered.filter { recordFilter.matches($0) }
            .filter { selectedType == nil || $0.type == selectedType }
    }

    /// Consecutive identical rows folded for display only (C10):
    /// repeated queries flood the list. The stored entries are
    /// untouched — only the rows shown are grouped, newest first.
    /// One row + a ×N badge stands for N identical consecutive rows.
    private var foldedEntries: [FoldedDnsEntry] {
        var folded: [FoldedDnsEntry] = []
        for entry in visibleEntries {
            if let last = folded.last, Self.sameQuery(last.entry, entry) {
                folded[folded.count - 1] = FoldedDnsEntry(entry: last.entry, count: last.count + 1)
            } else {
                folded.append(FoldedDnsEntry(entry: entry, count: 1))
            }
        }
        return folded
    }

    /// Two rows are the same query when everything the row shows
    /// matches (time and delay excluded — each query has its own).
    private static func sameQuery(_ a: ConcordDnsEntry, _ b: ConcordDnsEntry) -> Bool {
        a.domain == b.domain && a.type == b.type && a.initiator == b.initiator
            && a.upstream == b.upstream && a.cached == b.cached
            && a.answers == b.answers && a.rcode == b.rcode && a.error == b.error
    }

    private var availableTypes: [String] {
        Array(NSOrderedSet(array: dnsStore.filtered.map { $0.type })) as? [String] ?? []
    }

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("DNS 记录为示例数据")
                        .font(.caption2)
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(result.answers, id: \.data) { record in
                            Text("\(record.name) → \(record.data)（TTL \(record.ttl)）")
                                .font(.caption2)
                        }
                        if !result.authorities.isEmpty {
                            Text("权威记录 \(result.authorities.count) 条")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = dnsStore.queryError {
                    Text(error).font(.caption2).foregroundStyle(.red)
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
                    Text(message).font(.caption2).foregroundStyle(.green)
                }
                // Failures of the actions above (clear cache /
                // clear Fake-IP, or a VPN-off attempt) only wrote
                // lastError — render it here so the failure is
                // visible with its real reason (audit B16).
                if let error = dnsStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Section("查询记录（dns.watch）") {
                Picker("筛选", selection: $recordFilter) {
                    ForEach(DnsRecordFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                HStack {
                    Text("记录类型")
                    Spacer()
                    Picker("记录类型", selection: $selectedType) {
                        Text("全部").tag(nil as String?)
                        ForEach(availableTypes, id: \.self) { type in
                            Text(type).tag(type as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .listRowBackground(Color.clear)
                if visibleEntries.isEmpty {
                    Text(dnsStore.filtered.isEmpty ? "暂无 DNS 查询记录" : "没有符合筛选的记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // A failed refresh (e.g. VPN off) only wrote
                    // lastError — show the real reason instead of a
                    // bare "暂无记录" (audit B16).
                    if let error = dnsStore.lastError, dnsStore.filtered.isEmpty {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                } else {
                    ForEach(foldedEntries) { folded in
                        let entry = folded.entry
                        Button {
                            selectedEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.domain).font(.footnote)
                                    if folded.count > 1 {
                                        Text("×\(folded.count)")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(entry.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                                Text("上游 \(entry.upstream) · \(entry.delay) ms · \(entry.cached == true ? "缓存命中" : "实时查询")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("应答：\(entry.answers.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                // Keyword chips (FlClash _DnsKeyword):
                                // tapping one filters the list by it.
                                HStack(spacing: 6) {
                                    DnsKeywordChip(label: entry.type, isError: false) {
                                        toggleSearch(entry.type)
                                    }
                                    if let rcode = entry.rcode, !rcode.isEmpty {
                                        DnsKeywordChip(label: rcode, isError: DnsErrorRow.isFailed(entry)) {
                                            toggleSearch(rcode)
                                        }
                                    }
                                }
                                if let error = entry.error {
                                    DnsErrorRow(error: error)
                                }
                                Text(ConcordFormat.time(entry.time))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("DNS 查询")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .searchable(text: $dnsStore.searchText, prompt: "搜索域名或上游")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
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

    /// Tapping a keyword chip filters by it; tapping it again clears.
    private func toggleSearch(_ keyword: String) {
        dnsStore.searchText = dnsStore.searchText == keyword ? "" : keyword
    }
}

/// A tappable keyword chip (FlClash _DnsKeyword): type or rcode.
/// Tapping filters the record list by that keyword.
private struct DnsKeywordChip: View {
    let label: String
    let isError: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((isError ? Color.red : Color.blue).opacity(0.12), in: Capsule())
                .foregroundStyle(isError ? .red : .blue)
        }
        .buttonStyle(.plain)
    }
}

/// A failed query's error line (FlClash _ErrorRow): red text,
/// tapping copies the error.
private struct DnsErrorRow: View {
    let error: String

    @State private var copied = false

    static func isFailed(_ entry: ConcordDnsEntry) -> Bool {
        entry.error != nil
            || (entry.rcode != nil && entry.rcode != "NOERROR" && entry.rcode != "NoError")
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = error
            copied = true
        } label: {
            HStack(spacing: 4) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                if copied {
                    Text("已复制")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
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
                            .font(.caption)
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
                        DnsErrorRow(error: error)
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
            .font(.footnote.weight(.semibold))
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: ConcordClient
    @State private var sideLoadName = ""
    @State private var sideLoadText = ""
    @State private var editingProvider: ConcordProviderInfo?

    var body: some View {
        List {
            if client.mode == .sample {
                HStack {
                    SampleDataBadge()
                    Text("提供方为示例数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(ruleStore.providers) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(provider.name).font(.footnote)
                        Spacer()
                        Text(provider.type)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                    }
                    Text("\(provider.vehicleType) · \(provider.count) 条 · \(provider.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let updated = provider.updatedAt {
                        Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("编辑") {
                        editingProvider = provider
                    }
                    .tint(.purple)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = ruleStore.providerActionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            // Tools B16: the old copy here (via RuleStore's trigger
            // message) promised "稍后刷新列表查看", but the core
            // never returns provider health state, so no refresh
            // can ever show a result. The trigger message itself
            // is fixed in RuleStore (another worker) to this same
            // wording; this footnote states it on this page too,
            // next to the 健康检查 swipe action above.
            Text("健康检查已触发，但核心不返回提供方健康状态，无法显示结果")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            if let error = ruleStore.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("提供方")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
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
        .sheet(item: $editingProvider) { provider in
            EditProviderView(provider: provider)
        }
    }
}

// MARK: - Resources (FlClash: ResourcesView, lib/views/resources.dart)

struct ResourcesView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var releaseMessage: String?
    @State private var geoFiles: [GeoFileInfo] = []
    /// Per-item update state (FlClash ResourcesView): the names of
    /// the items currently updating, plus the update-all result.
    @State private var updatingItems: Set<String> = []
    @State private var isUpdatingAll = false
    @State private var updateAllMessage: String?
    // C3: default on, 24 h — upstream FlClash 1b2ea11 flipped the
    // geo auto-update default false -> true; an explicitly saved
    // false stays off (@AppStorage only supplies the default when
    // the key is absent). ContentView.swift:57 still declares
    // false for the same key — see the C3 report; it only gates
    // the redundant app-side manual loop, not the core's own
    // auto-update.
    @AppStorage("ConcordiOS.geoAutoUpdate") private var geoAutoUpdate = true
    @AppStorage("ConcordiOS.geoAutoUpdateHours") private var geoAutoUpdateHours = 24.0
    // Custom Geo download URLs (FlClash resources.dart:661
    // UpdateGeoUrlFormDialog, with its reset-to-default). Stored per
    // kind; the core's geo.update takes no URL parameter yet, so the
    // saved URL is recorded here and honoured once the core /
    // extension download path accepts one — the form says so rather
    // than pretending the URL is already used.
    @AppStorage("ConcordiOS.geoURL.MMDB") private var geoURLMMDB = ""
    @AppStorage("ConcordiOS.geoURL.ASN") private var geoURLASN = ""
    @AppStorage("ConcordiOS.geoURL.GEOSITE") private var geoURLGeosite = ""

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
                    .font(.caption2)
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
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("已加载") {
                LabeledContent("代理组", value: "\(proxyStore.nonHiddenGroups.count)")
                LabeledContent("节点", value: "\(proxyStore.allNodes.count)")
                LabeledContent("规则", value: "\(ruleStore.rules.count)")
                LabeledContent("提供方", value: "\(ruleStore.providers.count)")
                LabeledContent("规则提供方", value: "\(ruleStore.ruleProviders.count)")
                LabeledContent("MITM 模块", value: "\(mitmModuleStore.modules.filter(\.enabled).count) / \(mitmModuleStore.modules.count) 已启用")
            }
            Section("可更新资源") {
                Button(isUpdatingAll ? "全部更新中…" : "全部更新") {
                    Task { await updateAllResources() }
                }
                .disabled(isUpdatingAll)
                if let message = updateAllMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                Text("全部更新会依次更新所有提供方、MITM 模块与三类 Geo 数据库；失败的项会继续更新其余项，最后汇总。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("规则提供方") {
                if ruleStore.ruleProviders.isEmpty {
                    Text("没有规则提供方。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ruleStore.ruleProviders) { provider in
                        resourceRow(
                            title: provider.name,
                            subtitle: "\(provider.count) 条 · \(provider.vehicleType)",
                            updatedAt: provider.updatedAt,
                            updatingKey: "provider:\(provider.name)",
                            onUpdate: { await updateProvider(provider) }
                        )
                    }
                }
            }
            Section("代理提供方") {
                let proxyProviders = ruleStore.providers.filter { $0.type == "proxy" }
                if proxyProviders.isEmpty {
                    Text("没有代理提供方。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(proxyProviders) { provider in
                        resourceRow(
                            title: provider.name,
                            subtitle: "\(provider.count) 条 · \(provider.vehicleType)",
                            updatedAt: provider.updatedAt,
                            updatingKey: "provider:\(provider.name)",
                            onUpdate: { await updateProvider(provider) }
                        )
                    }
                }
            }
            Section("MITM 模块") {
                if mitmModuleStore.modules.isEmpty {
                    Text("没有 MITM 模块。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mitmModuleStore.modules) { module in
                        resourceRow(
                            title: module.name,
                            subtitle: "\(module.scripts) 个脚本 · \(module.enabled ? "已启用" : "已暂停")",
                            updatedAt: Int64(module.lastUpdateTime.timeIntervalSince1970),
                            updatingKey: "module:\(module.id)",
                            onUpdate: { await mitmModuleStore.update(module) }
                        )
                    }
                }
            }
            Section("MITM 脚本") {
                let totalScripts = mitmModuleStore.modules.reduce(0) { $0 + $1.scripts }
                LabeledContent("脚本总数", value: "\(totalScripts) 个")
                Text("脚本没有独立的更新接口，随所属 MITM 模块一起更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("图标集") {
                LabeledContent("内置备用图标", value: "深色 / 青色 / 浅色")
                Text("图标集随应用内置，没有远程更新；切换图标见 工具 → 应用图标。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Geo 资源") {
                Toggle("自动更新", isOn: $geoAutoUpdate)
                    // C3: the toggle writes general-overlay.json
                    // (via settingsStore.save) so the tunnel core
                    // picks the change up at the next VPN start /
                    // live re-apply — the same pattern as the port
                    // steppers. Without this the file would keep
                    // the old value until an unrelated settings save.
                    .onChange(of: geoAutoUpdate) { _, _ in settingsStore.save() }
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
                    .onChange(of: geoAutoUpdateHours) { _, _ in settingsStore.save() }
                }
                if geoFiles.isEmpty {
                    Text("容器里没有找到 Geo 文件（MMDB / ASN / GeoSite）。点下面按钮更新，核心会在后台下载。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(geoFiles) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.footnote)
                            Text("\(ConcordFormat.bytes(file.size))\(file.modified.map { " · 更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                                .font(.caption2)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("自定义下载地址：核心 geo.update 目前不接受自定义地址参数，下面填的地址会先保存在本机，待核心 / 扩展的下载路径支持自定义地址后使用；留空为默认地址。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                GeoURLRow(title: "GeoIP（MMDB）", url: $geoURLMMDB)
                GeoURLRow(title: "ASN", url: $geoURLASN)
                GeoURLRow(title: "GeoSite", url: $geoURLGeosite)
                if let message = ruleStore.providerActionMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let error = ruleStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
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
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("资源")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .task {
            scanGeoFiles()
        }
    }

/// One custom Geo download URL (FlClash UpdateGeoUrlFormDialog):
/// an http(s) URL field with validation and a reset-to-default
/// button. Empty means the core's default address.
private struct GeoURLRow: View {
    let title: String
    @Binding var url: String

    private var urlIssue: String? {
        let value = url.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        guard let parsed = URL(string: value),
              parsed.scheme?.hasPrefix("http") == true,
              parsed.host != nil else {
            return "地址无效，应为 http(s) 链接"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)下载地址")
                .font(.footnote.weight(.semibold))
            HStack {
                TextField("留空为默认地址", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !url.isEmpty {
                    Button("恢复默认") { url = "" }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let urlIssue {
                Text(urlIssue)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

    /// One updatable resource row (FlClash ResourcesView): name,
    /// detail, last-update time, and its own update button.
    private func resourceRow(
        title: String,
        subtitle: String,
        updatedAt: Int64?,
        updatingKey: String,
        onUpdate: @escaping () async -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let updatedAt {
                    Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(updatedAt)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if updatingItems.contains(updatingKey) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("更新") {
                    Task {
                        updatingItems.insert(updatingKey)
                        await onUpdate()
                        updatingItems.remove(updatingKey)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(ConcordTheme.accent)
            }
        }
    }

    /// Updates one provider (provider.update) and refreshes the
    /// provider list so the new time/count show up.
    private func updateProvider(_ provider: ConcordProviderInfo) async {
        do {
            try await client.providerUpdate(name: provider.name)
            await ruleStore.refresh()
            ruleStore.providerActionMessage = "已更新提供方 \(provider.name)"
        } catch {
            ruleStore.lastError = error.localizedDescription
        }
    }

    /// Updates every updatable resource, one after another, and
    /// reports how many failed instead of stopping at the first.
    private func updateAllResources() async {
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        var failures: [String] = []
        for provider in ruleStore.providers {
            do {
                try await client.providerUpdate(name: provider.name)
            } catch {
                failures.append(provider.name)
            }
        }
        for module in mitmModuleStore.modules {
            let before = mitmModuleStore.lastError
            await mitmModuleStore.update(module)
            if mitmModuleStore.lastError != nil && mitmModuleStore.lastError != before {
                failures.append(module.name)
            }
        }
        for kind in ["MMDB", "ASN", "GEOSITE"] {
            do {
                try await client.geoUpdate(kind: kind)
            } catch {
                failures.append("Geo \(kind)")
            }
        }
        await ruleStore.refresh()
        await trafficStore.refreshMemory()
        scanGeoFiles()
        updateAllMessage = failures.isEmpty
            ? "全部更新完成"
            : "全部更新完成，\(failures.count) 项失败：\(failures.joined(separator: "、"))"
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
