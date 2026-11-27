import SwiftUI
import UniformTypeIdentifiers

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
    /// Cached 主机映射 summary ("无" / "N 条"): hosts.json is
    /// read + parsed once here (and refreshed on appear) instead
    /// of on every body evaluation.
    @State private var hostsSummaryCache: String = Self.readHostsSummary()
    // FlClash general/port_form.dart: HTTP / redir / tproxy ports
    // (0 = disabled, otherwise 1024–49151, no conflicts). These
    // live in @AppStorage until the SettingsStore owner wires them
    // into general.json / mitm.json (see the v0.2.32 handoff).
    @AppStorage("ConcordiOS.httpPort") private var httpPort = 0
    @AppStorage("ConcordiOS.redirPort") private var redirPort = 0
    @AppStorage("ConcordiOS.tproxyPort") private var tproxyPort = 0

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

    /// Hosts summary for the 内核 → 主机映射 row: "无" when the
    /// user has no hosts.json entries, else "N 条". Read from the
    /// shared hosts.json (same file HostsView edits).
    private static func readHostsSummary() -> String {
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.hostsFileName),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return "无"
        }
        return json.isEmpty ? "无" : "\(json.count) 条"
    }

    private var hostsSummary: String { hostsSummaryCache }

    /// Keep-alive display: 0 = the core default. Idle defaults to
    /// 15 s (Go's defaultTCPKeepAliveIdle, which concord inherits
    /// when keep-alive-idle is unset); the interval default could
    /// not be verified from the core code in this tree, so 0 shows
    /// "默认" rather than a guessed number.
    private var keepAliveIdleText: String {
        settingsStore.keepAliveIdle == 0 ? "15 秒" : "\(settingsStore.keepAliveIdle) 秒"
    }

    private var keepAliveIntervalText: String {
        settingsStore.keepAliveInterval == 0 ? "默认" : "\(settingsStore.keepAliveInterval) 秒"
    }

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar.
        Form {
            // v0.2.68 (MuYu): the general settings are grouped
            // into MuYu's 7 groups with MuYu's labels. Defaults
            // are NOT changed to match the video — the video shows
            // one user's configured state, not defaults (log level
            // stays info, 自动关闭连接 stays off, …). "退出时最小化"
            // is not added: iOS has no system tray.
            Section("启动与后台") {
                Toggle("自动运行", isOn: $settingsStore.autoRun)
                NavigationLink("按需运行") {
                    OnDemandView()
                }
                Text("自动运行：打开应用后自动启动 VPN（需已有配置）。上游另有「退出时最小化到托盘」，iOS 没有系统托盘，退出应用即进入后台，故不设此开关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("请求与更新") {
                NavigationLink {
                    UserAgentsView()
                } label: {
                    HStack {
                        Text("用户代理")
                        Spacer()
                        Text(settingsStore.globalUa.isEmpty ? "默认" : settingsStore.globalUa)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Toggle("校验 TLS 证书", isOn: $settingsStore.checkCertificate)
                Toggle("自动检查更新", isOn: $settingsStore.autoCheckUpdate)
                Text("校验 TLS 证书：关闭后订阅下载不再验证服务器证书（自签证书的订阅源可用）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("入站") {
                Stepper("端口：\(settingsStore.mixedPort)", value: $settingsStore.mixedPort, in: 1024...49151)
                Toggle("局域网代理", isOn: $settingsStore.allowLan)
                NavigationLink {
                    GeneralAuthView()
                } label: {
                    HStack {
                        Text("外部控制器密钥")
                        Spacer()
                        Text(settingsStore.externalControllerSecret.isEmpty ? "未设置" : settingsStore.externalControllerSecret)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Toggle("认证", isOn: $settingsStore.authEnabled)
                // v0.2.68 gap (flagged): MuYu's 入站 shows only the
                // mixed port — the SOCKS / HTTP / redir / tproxy
                // steppers + reset were meant to move to the 网络
                // settings page, but NetworkSettingsView.swift is
                // outside this change's file ownership, so they stay
                // here until that move lands. Removing them would
                // orphan the settings, not dedup them.
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
                Text("端口 0 表示停用；启用的端口须在 1024–49151 之间且互不冲突。HTTP / redir / tproxy 在 iOS 上一般用不到，FlClash 仍在 iOS 上提供这三项，这里同样提供。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("出站") {
                // v0.2.141 (C1-d1): the outbound-mode picker lived
                // here until v0.2.140; upstream has no mode switch
                // in Settings (the mode segment is on the
                // Dashboard). The mode itself is unchanged — the
                // Dashboard segment still sets settingsStore.mode,
                // and the .onChange(save) below still persists it.
                Toggle("禁用 TCP 保活", isOn: $settingsStore.disableKeepAlive)
                // TCP 保活（核心 keep-alive-idle / interval /
                // disable-keep-alive；0 = 核心默认）。经
                // general-overlay.json 下发，下次启动 VPN 或切换出站
                // 模式时生效。
                Stepper("TCP 保持活动空闲时间：\(keepAliveIdleText)", value: $settingsStore.keepAliveIdle, in: 0...3600, step: 15)
                Stepper("TCP 保持活动间隔：\(keepAliveIntervalText)", value: $settingsStore.keepAliveInterval, in: 0...3600, step: 15)
                Text("保活空闲 / 间隔为 0 表示用核心默认（空闲 15 秒）。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("IPv6", isOn: $settingsStore.ipv6)
            }

            Section("连接") {
                Picker("延迟测试超时", selection: $settingsStore.delayTestTimeout) {
                    Text("3000 ms").tag(3000)
                    Text("5000 ms").tag(5000)
                    Text("8000 ms").tag(8000)
                    Text("10000 ms").tag(10000)
                    Text("15000 ms").tag(15000)
                    // A value saved by the old Stepper (500–8000,
                    // step 500) may not be one of the five menu
                    // options — keep it selectable instead of
                    // showing a blank picker.
                    if ![3000, 5000, 8000, 10000, 15000].contains(settingsStore.delayTestTimeout) {
                        Text("\(settingsStore.delayTestTimeout) ms").tag(settingsStore.delayTestTimeout)
                    }
                }
                // NOTED DIFFERENCE (flagged, kept on purpose):
                // MuYu shows 始终查找进程 as a toggle; ours keeps
                // the 3-way Picker (默认 strict / 始终 always /
                // 关闭 off) — collapsing it to a toggle would force
                // "off" on everyone who never touched it and disable
                // PROCESS-NAME / PROCESS-PATH rules (config B4).
                Picker("始终查找进程", selection: $settingsStore.findProcessModeSetting) {
                    Text("默认（strict）").tag("strict")
                    Text("始终（always）").tag("always")
                    Text("关闭（off）").tag("off")
                }
                Text("进程查找方式：默认 strict（核心默认）；always 始终按进程匹配，off 关闭进程匹配。核心当前报告：\(settingsStore.findProcessMode ?? "未知")。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("自动关闭连接", isOn: $settingsStore.autoCloseConnections)
                // FlClash general.dart:337 _connectionItems:
                // only count proxy traffic in the traffic stats.
                // Stored in SettingsStore; the traffic feed
                // (traffic.watch) takes no such parameter yet,
                // so this only records the preference until
                // ConcordClient / TrafficStore wire it — it does
                // not change the numbers shown today.
                Toggle("仅统计代理流量", isOn: $settingsStore.onlyStatisticsProxy)
                Text("仅统计代理流量：打开后流量统计只计代理流量，直连流量不计入（上游 getTraffic 参数）。当前版本此开关只保存偏好，流量接口尚未接线，数字暂无变化。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Text("统一延迟测试：打开后测速只计量热连接上的第二次请求，拨号与 TLS 握手不再计入，延迟更接近真实往返耗时。VPN 开启时切换后立即生效；VPN 关闭时，隧道核心在下次启动时读取。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("内核") {
                NavigationLink {
                    HostsView()
                } label: {
                    HStack {
                        Text("主机映射")
                        Spacer()
                        Text(hostsSummary)
                            .foregroundStyle(.secondary)
                    }
                }
                // FlClash general.dart:360 _coreItems:
                // appendSystemDns — append the system DNS
                // servers to dns.nameserver at config build
                // (task.dart:314). Wired in SettingsStore:
                // the servers are read from /etc/resolv.conf
                // and appended to dns.json's nameserver list.
                Toggle("追加系统DNS", isOn: $settingsStore.appendSystemDns)
                Text("追加系统 DNS：打开后，系统当前用的 DNS 服务器会追加到 DNS 上游列表末尾（订阅自带的解析服务器优先）。改动随 DNS 设置保存，下次启动 VPN 或点「应用 DNS 设置」后生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                NavigationLink("添加覆写项") {
                    OverrideView()
                }
            }

            // FlClash GeneralView 的「核心」OverrideSection
            // (general/overrides.dart:7-13): 测速地址、统一延迟、
            // TCP 并发、IPv6、地理数据加载方式 5 项内联在 常规 里
            // （自带「通用」组头），Hosts 也在该区
            // （general.dart _coreItems）。覆盖只对启用的项生效；
            // 没启用的项用订阅自己的值。
            OverrideSectionEditor(section: .general, scope: .constant(nil))

            Section("日志与诊断") {
                Picker("日志等级", selection: $settingsStore.logLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                // v0.2.68: the 日志捕获 toggle is back (deleted in
                // v0.2.40). When it is OFF the Tools → 日志 row is
                // hidden (ToolsView gates on openLogs); logging
                // itself is still collected by LogStore either way.
                // v0.2.141 (C1-d2): the read-from-core / apply-to-
                // core buttons are gone (upstream has no such
                // buttons in Settings). The store methods stay:
                // applyGeneralToCore is still called on Dashboard
                // mode switches and at app launch, and
                // refreshFromCore is still used by the Logs page.
                Toggle("日志捕获", isOn: $settingsStore.openLogs)
            }

            // v0.2.68 (MuYu): the TUN + DNS sections moved out —
            // the Advanced 网络 page (NetworkSettingsView) hosts
            // the TUN settings + TUN 覆盖 link, and the Advanced
            // DNS page (DnsSettingsView) hosts 启用 DNS / DoH 上游 /
            // Fake-IP + 保存并应用. Remaining gap (flagged): the
            // core-reported TUN state readout (refreshTunState) had
            // no host on either subpage, so it is dropped for now.
            Section("配置") {
                NavigationLink("NTP") {
                    NtpSettingsView()
                }
                NavigationLink("嗅探") {
                    SnifferSettingsView()
                }
                Text("覆盖：对通用、DNS、TUN、嗅探、NTP 的逐项覆盖，分全局和单个订阅两级，带 YAML 预览。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // v0.2.141 (C20-c1): upstream splits providers — proxy
            // providers live under Proxies (their
            // ExternalProvidersSliver is in the profile-detail
            // sheet, which our Dashboard/Profiles phase does not
            // have yet), rule providers under Advanced → 提供方.
            // The hub therefore offers both pages; the caption
            // counts the rule-provider page.
            Section("提供方（provider.list）") {
                NavigationLink("代理提供方") {
                    ProxyProvidersView()
                }
                NavigationLink("规则提供方") {
                    ProvidersView()
                }
                Text("规则提供方 \(ruleStore.ruleProviders.count) 个")
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
                // v0.2.141 (C1-d1): the 自动更新订阅 toggle and the
                // 核心模式 picker are gone (upstream has neither in
                // Settings). The properties stay — autoUpdateProfiles
                // still drives ContentView's subscription refresh,
                // client.mode still drives the sample/live badge —
                // frozen at their persisted values. The 开发者模式
                // toggle stays: it also gates the Developer row in
                // ToolsView.
                Toggle("开发者模式", isOn: $settingsStore.developerMode)
            }

            // Group icon pack (v0.2.53): the user pastes the URL
            // of an icon-pack JSON file (iBL3ND format) and taps
            // 导入 / 更新; the pack is downloaded once, stored
            // locally, and group icons resolve from it by name.
            // The pack still wins over the bundled brands
            // (BrandIcons, v0.2.141). The field starts empty;
            // nothing is fetched until the button is tapped.
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

            // v0.2.136 (D1): the App 图标 section is deleted —
            // upstream has no alternate-icon switching (rs.1: only
            // an unused app_icon plugin); the icon now changes at
            // install time in SideKite.
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

            // v0.2.141 (C1-d6): the 更多工具 section is gone
            // (upstream has no such section in Settings). Entry
            // points lost: 规则 (RulesView — no other entry point;
            // Tools uses AddedRulesView, a different page), 快捷指令
            // (ShortcutsView — no other entry point), MITM 拦截记录
            // (MitmView — no other entry point). LogsView is still
            // reachable from ToolsView:186.
            // v0.2.141 (C1-d7): the developer section is gone
            // (upstream has no developer section in Settings).
            // The store methods stay (refreshDeveloperInfo,
            // setPressure, crashCore); the MITM pressure picker
            // and the crash button lose their only UI. The
            // 开发者模式 toggle in 应用 stays — it also gates the
            // Developer row in ToolsView.
            Section("关于") {
                LabeledContent("版本", value: "Lumen \(Self.appVersion)")
                LabeledContent("核心", value: "chen08209/concord（GPL-3.0-or-later）")
                LabeledContent("界面来源", value: "chen08209/FlClash（GPL-3.0）")
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
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
        .onChange(of: settingsStore.openLogs) { _, _ in settingsStore.save() }
        .onAppear { hostsSummaryCache = Self.readHostsSummary() }
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
    /// Provider-detail page push (upstream providers.dart:226-250
    /// pushes an EditorPage — no detail sheet). Local state, NOT
    /// the shared ruleStore.providerDetail: opening Edit Provider
    /// makes EditProviderView.task load the detail into the store,
    /// which used to trip the old detail sheet while the edit
    /// sheet was open (P2 cross-trigger). A Bool + stored value,
    /// not navigationDestination(item:): ConcordProviderInfo is
    /// not Hashable (and its model file is outside this change).
    @State private var detailProvider: ConcordProviderInfo?
    @State private var showDetailPage = false
    /// Import from URL (FlClash providers.dart _handleImportFromUrl):
    /// one URL per line; the provider name comes from the URL file
    /// stem and is deduplicated against the existing names.
    @State private var importURLs = ""
    @State private var showProviderImporter = false

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
            // v0.2.141 (C20-c1): this page is rule providers only
            // (upstream Advanced → 提供方, advanced.dart). Proxy
            // providers moved to ProxyProvidersView (below).
            ForEach(ruleStore.ruleProviders) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(provider.name).font(.footnote)
                        Spacer()
                        // v0.2.141 (C20-d2): the purple type capsule
                        // is gone — on a rule-only page every row
                        // would say "rule".
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
                        Task {
                            await ruleStore.loadProviderDetail(provider)
                            if let detail = ruleStore.providerDetail {
                                detailProvider = detail
                                ruleStore.providerDetail = nil
                                showDetailPage = true
                            }
                        }
                    }
                    .tint(.blue)
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
            Section("从链接导入提供方") {
                TextEditor(text: $importURLs)
                    .frame(minHeight: 60)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                Button("导入") {
                    Task { await importProvidersFromURLs() }
                }
                .disabled(importURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("每行一个链接；下载到的内容按链接文件名作为提供方名称（重名时自动加后缀），通过 provider.sideLoad 存到核心。只下载文本内容，失败的链接会汇总在下面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                Button("载入") {
                    Task { await ruleStore.sideLoadProvider(name: sideLoadName, data: sideLoadText) }
                }
                .disabled(sideLoadName.trimmingCharacters(in: .whitespaces).isEmpty || sideLoadText.isEmpty)
                // FlClash providers.dart _handleImportFromFile: pick
                // a file, read its bytes, side-load under the file
                // stem. Same core method as the paste box above.
                Button("从文件导入…") {
                    showProviderImporter = true
                }
                Text("把提供方文件内容（YAML / MRS / 文本）直接贴进来，核心会把它存到该名称下。只处理本地内容，不联网拉取；从文件导入时名称取文件主名。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = ruleStore.providerActionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let error = ruleStore.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("规则提供方")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await ruleStore.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await ruleStore.refresh() }
        .fileImporter(isPresented: $showProviderImporter, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    ruleStore.lastError = "读取文件失败或文件为空"
                    return
                }
                let name = uniqueProviderName(url.deletingPathExtension().lastPathComponent)
                Task { await ruleStore.sideLoadProvider(name: name, data: String(decoding: data, as: UTF8.self)) }
            case .failure(let error):
                ruleStore.lastError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        // Provider detail is a pushed page (upstream EditorPage),
        // not a sheet — and nothing here observes the shared
        // ruleStore.providerDetail any more, so EditProviderView's
        // own detail load can no longer trip a detail sheet.
        .navigationDestination(isPresented: $showDetailPage) {
            if let detail = detailProvider {
                ProviderDetailView(provider: detail)
                    .concordNavBarBackground()
            }
        }
        .sheet(item: $editingProvider) { provider in
            EditProviderView(provider: provider)
        }
    }

    /// A provider name not already in the list (FlClash's
    /// _uniqueLabel): the base name, or base-2, base-3, …
    private func uniqueProviderName(_ base: String) -> String {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = clean.isEmpty ? "provider" : clean
        let existing = Set(ruleStore.providers.map(\.name))
        guard existing.contains(stem) else { return stem }
        var index = 2
        while existing.contains("\(stem)-\(index)") { index += 1 }
        return "\(stem)-\(index)"
    }

    /// Downloads each URL (one per line) and side-loads its content
    /// under the URL file stem (FlClash providers.dart
    /// _handleImportFromUrl). Non-2xx and HTML error pages are
    /// reported as failures instead of being stored as providers;
    /// one summary message covers the whole batch.
    private func importProvidersFromURLs() async {
        let lines = importURLs.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            ruleStore.providerActionMessage = "请先输入提供方链接"
            return
        }
        var imported: [String] = []
        var failures: [String] = []
        for raw in lines {
            guard let url = URL(string: raw),
                  url.scheme?.hasPrefix("http") == true, url.host != nil else {
                failures.append(raw)
                continue
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode), !data.isEmpty else {
                    failures.append(raw)
                    continue
                }
                if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                   contentType.lowercased().contains("text/html") {
                    failures.append(raw)
                    continue
                }
                let name = uniqueProviderName(url.deletingPathExtension().lastPathComponent)
                try await client.providerSideLoad(name: name, data: String(decoding: data, as: UTF8.self))
                imported.append(name)
            } catch {
                failures.append(raw)
            }
        }
        await ruleStore.refresh()
        if failures.isEmpty {
            ruleStore.providerActionMessage = "已导入提供方：\(imported.joined(separator: "、"))"
        } else if imported.isEmpty {
            ruleStore.lastError = "导入失败：\(failures.joined(separator: "、"))"
        } else {
            ruleStore.providerActionMessage = "已导入提供方：\(imported.joined(separator: "、"))；失败：\(failures.joined(separator: "、"))"
        }
    }
}

// MARK: - Proxy providers (C20-c1)

/// Proxy providers only. Upstream's ExternalProvidersSliver
/// (views/proxies/providers.dart) lists proxy providers with a
/// header sync button and per-row update; it lives in the
/// profile-detail sheet, which our Dashboard/Profiles phase does
/// not have yet, so the hub's 提供方 section links here instead.
/// No delete swipe: the core has no provider.delete (C20-b3,
/// v0.2.142). No health check either (D8 — the core returns no
/// health state to display).
struct ProxyProvidersView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient
    @State private var isSyncing = false

    private var proxyProviders: [ConcordProviderInfo] {
        ruleStore.providers.filter { $0.type == "proxy" }
    }

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
            if proxyProviders.isEmpty {
                Text("没有代理提供方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(proxyProviders) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.footnote)
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
            if let message = ruleStore.providerActionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let error = ruleStore.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("代理提供方")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await syncAll() }
                } label: {
                    if isSyncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isSyncing)
            }
        }
        .refreshable { await ruleStore.refresh() }
        .task { await ruleStore.refresh() }
    }

    /// Upstream's sliver header sync: updates every proxy
    /// provider in turn, then refreshes the list.
    private func syncAll() async {
        isSyncing = true
        defer { isSyncing = false }
        for provider in proxyProviders {
            do {
                try await client.providerUpdate(name: provider.name)
            } catch {
                ruleStore.lastError = error.localizedDescription
            }
        }
        await ruleStore.refresh()
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
    @ObservedObject private var iconSetStore = IconSetStore.shared
    @State private var geoFiles: [GeoFileInfo] = []
    /// Geo update interval text field (FlClash resources.dart
    /// _updateInterval: a free number input in hours, digits only,
    /// max 6 digits, must be > 0). Synced once from the stored
    /// hours on appear; the stored value updates as valid text is
    /// typed.
    @State private var geoIntervalText = ""
    @State private var geoIntervalIssue: String?
    @State private var geoIntervalSynced = false
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
    // kind; the URLs ARE used since v0.2.119 —
    // SettingsStore.resolvedGeoURLs() feeds them as the `geox-url`
    // map into config apply and the live patch (C21-c2: the old
    // comment claiming they were recorded-but-unused was stale).
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
            // v0.2.141 (C21-d1/d2): the 核心 section (memory +
            // release button) and the 已加载 section are gone
            // (upstream resources.dart has neither — memory lives
            // on the Dashboard, counts live on their own pages).
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
            // v0.2.141 (C21-d3): the 代理提供方 section is gone —
            // proxy providers live on their own page now
            // (ProxyProvidersView, C20-c1).
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
                LabeledContent("内置图标集", value: "默认")
                Text("内置图标集没有远程更新；切换图标集见 工具 → 进阶配置 → 图标集。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // FlClash resources.dart:238,568 _IconSetItem:
                // imported icon sets with a per-set update. Local
                // (file-imported) packs have no source URL and no
                // update action, so they get a plain row.
                ForEach(iconSetStore.importedPacks) { pack in
                    if pack.isRemote {
                        resourceRow(
                            title: pack.name,
                            subtitle: "\(pack.icons.count) 个图标 · 远程",
                            updatedAt: Int64(pack.lastUpdate.timeIntervalSince1970),
                            updatingKey: "iconset:\(pack.id)",
                            onUpdate: { await iconSetStore.syncPack(pack) }
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .font(.footnote)
                            Text("\(pack.icons.count) 个图标 · 本地文件（无来源链接，不可同步）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("更新于 \(Date(timeIntervalSince1970: pack.lastUpdate.timeIntervalSince1970).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if let message = iconSetStore.actionMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let error = iconSetStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
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
                        TextField("24", text: $geoIntervalText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: geoIntervalText) { _, value in
                                // FlClash input_limits.dart geoUpdateInterval:
                                // digits only, max 6 chars, must be > 0.
                                var digits = value.filter(\.isNumber)
                                if digits.count > 6 {
                                    digits = String(digits.prefix(6))
                                }
                                if digits != value {
                                    geoIntervalText = digits
                                    return
                                }
                                if digits.isEmpty {
                                    geoIntervalIssue = "更新间隔不能为空"
                                } else if let hours = Int(digits), hours > 0 {
                                    geoAutoUpdateHours = Double(hours)
                                    geoIntervalIssue = nil
                                    settingsStore.save()
                                } else {
                                    geoIntervalIssue = "更新间隔应为大于 0 的小时数"
                                }
                            }
                        Text("小时")
                            .foregroundStyle(.secondary)
                    }
                    if let geoIntervalIssue {
                        Text(geoIntervalIssue)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
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
                Text("自定义下载地址：下面填的地址会作为 geox-url 发给核心（VPN 运行时立即生效，下次启动 VPN 时也生效）；留空或填错为默认地址。")
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
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
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
            // FlClash puts the geo updates on the Resources page
            // (resources.dart:507-561); the same menu used to live
            // on the Providers toolbar.
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
        }
        .task {
            scanGeoFiles()
            if !geoIntervalSynced {
                geoIntervalText = "\(Int(geoAutoUpdateHours))"
                geoIntervalSynced = true
            }
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
