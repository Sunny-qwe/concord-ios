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
    // (0 = disabled, otherwise 1024–49151, no conflicts).
    // SettingsStore writes them into the shared general-overlay.json
    // (RawConfig kebab-case keys, as FlClash writes rawConfig) and
    // PacketTunnelProvider.buildApplyOverlay merges every key into
    // every config.apply overlay — boot and live re-apply (C1-c5).
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
            ("settings.port.mixed".l10n, settingsStore.mixedPort, false),
            ("SOCKS", settingsStore.socksPort, true),
            ("HTTP", httpPort, true),
            ("redir", redirPort, true),
            ("tproxy", tproxyPort, true),
        ]
        for (label, port, allowDisabled) in ports {
            if port == 0 {
                if !allowDisabled { return "settings.ports.mixedRequired".l10n }
                continue
            }
            if port < 1024 || port > 49151 {
                return "\(label)\("settings.ports.rangeError".l10n)"
            }
            if let other = seen[port] {
                return "\(label)\("settings.ports.conflictWith".l10n)\(other)\("settings.ports.conflictSuffix".l10n)"
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
            return "common.none".l10n
        }
        return json.isEmpty ? "common.none".l10n : String(format: "common.count.hosts".l10n, "\(json.count)")
    }

    private var hostsSummary: String { hostsSummaryCache }

    /// Keep-alive display: 0 = the core default. Idle defaults to
    /// 15 s (Go's defaultTCPKeepAliveIdle, which concord inherits
    /// when keep-alive-idle is unset); the interval default could
    /// not be verified from the core code in this tree, so 0 shows
    /// "默认" rather than a guessed number.
    private var keepAliveIdleText: String {
        settingsStore.keepAliveIdle == 0 ? "settings.keepalive.idleDefault".l10n : String(format: "common.seconds".l10n, "\(settingsStore.keepAliveIdle)")
    }

    private var keepAliveIntervalText: String {
        settingsStore.keepAliveInterval == 0 ? "common.default".l10n : String(format: "common.seconds".l10n, "\(settingsStore.keepAliveInterval)")
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
            Section("settings.section.startup".l10n) {
                Toggle("settings.autorun".l10n, isOn: $settingsStore.autoRun)
                NavigationLink("settings.ondemand".l10n) {
                    OnDemandView()
                }
                Text("自动运行：打开应用后自动启动 VPN（需已有配置）。上游另有「退出时最小化到托盘」，iOS 没有系统托盘，退出应用即进入后台，故不设此开关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.request".l10n) {
                NavigationLink {
                    UserAgentsView()
                } label: {
                    HStack {
                        Text("settings.userAgent".l10n)
                        Spacer()
                        Text(settingsStore.globalUa.isEmpty ? "common.default".l10n : settingsStore.globalUa)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Toggle("settings.checkCertificate".l10n, isOn: $settingsStore.checkCertificate)
                Toggle("settings.autoCheckUpdate".l10n, isOn: $settingsStore.autoCheckUpdate)
                Text("settings.checkCertificate.hint".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.inbound".l10n) {
                Stepper("\("settings.port.label".l10n)\(settingsStore.mixedPort)", value: $settingsStore.mixedPort, in: 1024...49151)
                Toggle("settings.allowLan".l10n, isOn: $settingsStore.allowLan)
                NavigationLink {
                    GeneralAuthView()
                } label: {
                    HStack {
                        Text("settings.externalControllerSecret".l10n)
                        Spacer()
                        Text(settingsStore.externalControllerSecret.isEmpty ? "common.notset".l10n : settingsStore.externalControllerSecret)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Toggle("settings.auth".l10n, isOn: $settingsStore.authEnabled)
                // v0.2.68 gap (flagged): MuYu's 入站 shows only the
                // mixed port — the SOCKS / HTTP / redir / tproxy
                // steppers + reset were meant to move to the 网络
                // settings page, but NetworkSettingsView.swift is
                // outside this change's file ownership, so they stay
                // here until that move lands. Removing them would
                // orphan the settings, not dedup them.
                Stepper("\("settings.ports.socksLabel".l10n)\(settingsStore.socksPort == 0 ? "common.disabled".l10n : "\(settingsStore.socksPort)")", value: $settingsStore.socksPort, in: 0...49151)
                Stepper("\("settings.ports.httpLabel".l10n)\(httpPort == 0 ? "common.disabled".l10n : "\(httpPort)")", value: $httpPort, in: 0...49151)
                    .onChange(of: httpPort) { _, _ in settingsStore.save() }
                Stepper("\("settings.ports.redirLabel".l10n)\(redirPort == 0 ? "common.disabled".l10n : "\(redirPort)")", value: $redirPort, in: 0...49151)
                    .onChange(of: redirPort) { _, _ in settingsStore.save() }
                Stepper("\("settings.ports.tproxyLabel".l10n)\(tproxyPort == 0 ? "common.disabled".l10n : "\(tproxyPort)")", value: $tproxyPort, in: 0...49151)
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

            Section("settings.section.outbound".l10n) {
                // v0.2.141 (C1-d1): the outbound-mode picker lived
                // here until v0.2.140; upstream has no mode switch
                // in Settings (the mode segment is on the
                // Dashboard). The mode itself is unchanged — the
                // Dashboard segment still sets settingsStore.mode,
                // and the .onChange(save) below still persists it.
                Toggle("settings.disableKeepAlive".l10n, isOn: $settingsStore.disableKeepAlive)
                // TCP 保活（核心 keep-alive-idle / interval /
                // disable-keep-alive；0 = 核心默认）。经
                // general-overlay.json 下发，下次启动 VPN 或切换出站
                // 模式时生效。
                Stepper("\("settings.keepalive.idleLabel".l10n)\(keepAliveIdleText)", value: $settingsStore.keepAliveIdle, in: 0...3600, step: 15)
                Stepper("\("settings.keepalive.intervalLabel".l10n)\(keepAliveIntervalText)", value: $settingsStore.keepAliveInterval, in: 0...3600, step: 15)
                Text("保活空闲 / 间隔为 0 表示用核心默认（空闲 15 秒）。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("IPv6", isOn: $settingsStore.ipv6)
            }

            Section("settings.section.connection".l10n) {
                Picker("settings.delayTestTimeout".l10n, selection: $settingsStore.delayTestTimeout) {
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
                Picker("settings.findProcess".l10n, selection: $settingsStore.findProcessModeSetting) {
                    Text("settings.findProcess.strict".l10n).tag("strict")
                    Text("settings.findProcess.always".l10n).tag("always")
                    Text("settings.findProcess.off".l10n).tag("off")
                }
                Text("\("settings.findProcess.explainerPrefix".l10n)\(settingsStore.findProcessMode ?? "common.unknown".l10n)\("settings.findProcess.explainerSuffix".l10n)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("settings.autoCloseConnections".l10n, isOn: $settingsStore.autoCloseConnections)
                // FlClash general.dart:337 _connectionItems:
                // only count proxy traffic in the traffic stats.
                // Stored in SettingsStore; the traffic feed
                // (traffic.watch) takes no such parameter yet,
                // so this only records the preference until
                // ConcordClient / TrafficStore wire it — it does
                // not change the numbers shown today.
                Toggle("settings.onlyStatisticsProxy".l10n, isOn: $settingsStore.onlyStatisticsProxy)
                Text("仅统计代理流量：打开后流量统计只计代理流量，直连流量不计入（上游 getTraffic 参数）。当前版本此开关只保存偏好，流量接口尚未接线，数字暂无变化。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("settings.sniffing".l10n, isOn: $settingsStore.sniffing)
                    // B6: the master switch only takes effect
                    // when sniffer.json is re-saved (effective
                    // enable = master && page switch).
                    // SettingsStore.save() also propagates it;
                    // this makes the wiring explicit at the
                    // switch itself.
                    .onChange(of: settingsStore.sniffing) { _, _ in SnifferStore.shared.save() }
                Toggle("settings.tcpConcurrent".l10n, isOn: $settingsStore.tcpConcurrent)
                Toggle("settings.unifiedDelay".l10n, isOn: $settingsStore.unifiedDelay)
                Text("统一延迟测试：打开后测速只计量热连接上的第二次请求，拨号与 TLS 握手不再计入，延迟更接近真实往返耗时。VPN 开启时切换后立即生效；VPN 关闭时，隧道核心在下次启动时读取。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.core".l10n) {
                NavigationLink {
                    HostsView()
                } label: {
                    HStack {
                        Text("settings.hosts".l10n)
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
                Toggle("settings.appendSystemDns".l10n, isOn: $settingsStore.appendSystemDns)
                Text("追加系统 DNS：打开后，系统当前用的 DNS 服务器会追加到 DNS 上游列表末尾（订阅自带的解析服务器优先）。改动随 DNS 设置保存，下次启动 VPN 或点「应用 DNS 设置」后生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                NavigationLink("settings.addOverride".l10n) {
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

            Section("settings.section.logs".l10n) {
                Picker("settings.logLevel".l10n, selection: $settingsStore.logLevel) {
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
                // buttons in Settings). The store method stays:
                // applyGeneralToCore is still called on Dashboard
                // mode switches and at app launch.
                Toggle("settings.openLogs".l10n, isOn: $settingsStore.openLogs)
            }

            // v0.2.68 (MuYu): the TUN + DNS sections moved out —
            // the Advanced 网络 page (NetworkSettingsView) hosts
            // the TUN settings + TUN 覆盖 link, and the Advanced
            // DNS page (DnsSettingsView) hosts 启用 DNS / DoH 上游 /
            // Fake-IP + 保存并应用. Remaining gap (flagged): the
            // core-reported TUN state readout (refreshTunState) had
            // no host on either subpage, so it is dropped for now.
            Section("settings.section.config".l10n) {
                NavigationLink("NTP") {
                    NtpSettingsView()
                }
                NavigationLink("settings.sniff".l10n) {
                    SnifferSettingsView()
                }
                Text("settings.sniff.hint".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // v0.2.141 (C20-c1) + v0.2.145: upstream splits providers
            // — proxy providers live ONLY in the profile-detail
            // sheet (their ExternalProvidersSliver), opened from
            // the dashboard profile card; rule providers live
            // here under Advanced → 提供方. The hub therefore
            // offers only the rule-provider page; the caption
            // counts it.
            Section("settings.section.providers".l10n) {
                NavigationLink("settings.ruleProviders".l10n) {
                    ProvidersView()
                }
                Text(String(format: "settings.ruleProviders.count".l10n, "\(ruleStore.ruleProviders.count)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.resources".l10n) {
                NavigationLink("settings.resourceDetail".l10n) {
                    ResourcesView()
                }
                LabeledContent("settings.coreMemory".l10n, value: trafficStore.coreMemoryBytes.map { ConcordFormat.bytes(Int64($0)) } ?? "—")
            }

            Section("settings.section.app".l10n) {
                // v0.2.141 (C1-d1): the 自动更新订阅 toggle and the
                // 核心模式 picker are gone (upstream has neither in
                // Settings). The properties stay — autoUpdateProfiles
                // still drives ContentView's subscription refresh,
                // client.mode still drives the sample/live badge —
                // frozen at their persisted values. The 开发者模式
                // toggle stays: it also gates the Developer row in
                // ToolsView.
                Toggle("settings.developerMode".l10n, isOn: $settingsStore.developerMode)
            }

            // Group icon pack (v0.2.53): the user pastes the URL
            // of an icon-pack JSON file (iBL3ND format) and taps
            // 导入 / 更新; the pack is downloaded once, stored
            // locally, and group icons resolve from it by name.
            // The pack still wins over the bundled brands
            // (BrandIcons, v0.2.141). The field starts empty;
            // nothing is fetched until the button is tapped.
            Section("settings.section.iconSource".l10n) {
                TextField("settings.iconSource.urlPlaceholder".l10n, text: $iconPack.urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button(iconPack.iconCount > 0 ? "common.update".l10n : "common.import".l10n) {
                        Task { await iconPack.importPack() }
                    }
                    .disabled(iconPack.isImporting || iconPack.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if iconPack.isImporting {
                        ProgressView()
                    } else if iconPack.iconCount > 0 {
                        Button("common.delete".l10n, role: .destructive) {
                            iconPack.clearPack()
                        }
                    }
                }
                if let name = iconPack.packName, iconPack.iconCount > 0 {
                    LabeledContent("settings.iconPack.name".l10n, value: name)
                    LabeledContent("settings.iconPack.count".l10n, value: String(format: "common.count.items".l10n, "\(iconPack.iconCount)"))
                    if let date = iconPack.fetchedAt {
                        LabeledContent("settings.iconPack.updated".l10n, value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    Text("settings.iconSource.hint".l10n)
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
                NavigationLink("settings.appearance".l10n) {
                    ThemePickerView()
                }
                Text("settings.appearance.subtitle".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("settings.backup".l10n) {
                NavigationLink("settings.backup".l10n) {
                    BackupView()
                }
                Text("settings.backup.subtitle".l10n)
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
            Section("tools.about".l10n) {
                LabeledContent("settings.about.version".l10n, value: "Lumen \(Self.appVersion)")
                LabeledContent("settings.about.core".l10n, value: "chen08209/concord（GPL-3.0-or-later）")
                LabeledContent("settings.about.uiSource".l10n, value: "chen08209/FlClash（GPL-3.0）")
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
                    Text("providers.sampleNotice".l10n)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            // v0.2.141 (C20-c1): this page is rule providers only
            // (upstream Advanced → 提供方, advanced.dart). Proxy
            // providers live in the profile-detail sheet
            // (dashboard profile card → ProfileDetailSheet).
            ForEach(ruleStore.ruleProviders) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(provider.name).font(.footnote)
                        Spacer()
                        // v0.2.141 (C20-d2): the purple type capsule
                        // is gone — on a rule-only page every row
                        // would say "rule".
                    }
                    Text("\(provider.vehicleType) · \(String(format: "common.count.entries".l10n, "\(provider.count)")) · \(provider.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let updated = provider.updatedAt {
                        Text("\("common.updatedAt".l10n) \(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("common.edit".l10n) {
                        editingProvider = provider
                    }
                    .tint(.purple)
                    Button("common.details".l10n) {
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
                    Button("common.update".l10n) {
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
            Section("providers.section.importLink".l10n) {
                TextEditor(text: $importURLs)
                    .frame(minHeight: 60)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                Button("common.import".l10n) {
                    Task { await importProvidersFromURLs() }
                }
                .disabled(importURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("每行一个链接；下载到的内容按链接文件名作为提供方名称（重名时自动加后缀），通过 provider.sideLoad 存到核心。只下载文本内容，失败的链接会汇总在下面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("providers.section.sideload".l10n) {
                TextField("providers.sideload.namePlaceholder".l10n, text: $sideLoadName)
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
                Button("providers.sideload.load".l10n) {
                    Task { await ruleStore.sideLoadProvider(name: sideLoadName, data: sideLoadText) }
                }
                .disabled(sideLoadName.trimmingCharacters(in: .whitespaces).isEmpty || sideLoadText.isEmpty)
                // FlClash providers.dart _handleImportFromFile: pick
                // a file, read its bytes, side-load under the file
                // stem. Same core method as the paste box above.
                Button("providers.importFile".l10n) {
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
        .navigationTitle("settings.ruleProviders".l10n)
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
                    ruleStore.lastError = "providers.import.readFailed".l10n
                    return
                }
                let name = uniqueProviderName(url.deletingPathExtension().lastPathComponent)
                Task { await ruleStore.sideLoadProvider(name: name, data: String(decoding: data, as: UTF8.self)) }
            case .failure(let error):
                ruleStore.lastError = "\("providers.import.pickFileFailed".l10n)\(error.localizedDescription)"
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
            ruleStore.providerActionMessage = "providers.import.enterLinksFirst".l10n
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
            ruleStore.providerActionMessage = "\("providers.import.imported".l10n)\(imported.joined(separator: "common.listSeparator".l10n))"
        } else if imported.isEmpty {
            ruleStore.lastError = "\("providers.import.failed".l10n)\(failures.joined(separator: "common.listSeparator".l10n))"
        } else {
            ruleStore.providerActionMessage = "\("providers.import.imported".l10n)\(imported.joined(separator: "common.listSeparator".l10n))\("providers.import.failedSuffix".l10n)\(failures.joined(separator: "common.listSeparator".l10n))"
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
            Section("resources.section.updatable".l10n) {
                Button(isUpdatingAll ? "resources.updateAll.updating".l10n : "resources.updateAll.update".l10n) {
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
            Section("settings.ruleProviders".l10n) {
                if ruleStore.ruleProviders.isEmpty {
                    Text("resources.noRuleProviders".l10n)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ruleStore.ruleProviders) { provider in
                        resourceRow(
                            title: provider.name,
                            subtitle: "\(String(format: "common.count.entries".l10n, "\(provider.count)")) · \(provider.vehicleType)",
                            updatedAt: provider.updatedAt,
                            updatingKey: "provider:\(provider.name)",
                            onUpdate: { await updateProvider(provider) }
                        )
                    }
                }
            }
            // v0.2.141 (C21-d3) + v0.2.145: the 代理提供方 section
            // is gone — proxy providers live in the profile-detail
            // sheet now (dashboard profile card → ProfileDetailSheet).
            Section("resources.section.mitmModules".l10n) {
                if mitmModuleStore.modules.isEmpty {
                    Text("resources.noMitmModules".l10n)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mitmModuleStore.modules) { module in
                        resourceRow(
                            title: module.name,
                            subtitle: "\(String(format: "common.count.scripts".l10n, "\(module.scripts)")) · \(module.enabled ? "common.enabled".l10n : "common.paused".l10n)",
                            updatedAt: Int64(module.lastUpdateTime.timeIntervalSince1970),
                            updatingKey: "module:\(module.id)",
                            onUpdate: { await mitmModuleStore.update(module) }
                        )
                    }
                }
            }
            Section("resources.section.mitmScripts".l10n) {
                let totalScripts = mitmModuleStore.modules.reduce(0) { $0 + $1.scripts }
                LabeledContent("resources.scripts.total".l10n, value: String(format: "common.count.items".l10n, "\(totalScripts)"))
                Text("resources.scripts.hint".l10n)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("resources.section.iconSets".l10n) {
                LabeledContent("resources.iconSets.builtin".l10n, value: "common.default".l10n)
                Text("resources.iconSets.hint".l10n)
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
                            subtitle: "\(String(format: "common.count.icons".l10n, "\(pack.icons.count)")) · \("common.remote".l10n)",
                            updatedAt: Int64(pack.lastUpdate.timeIntervalSince1970),
                            updatingKey: "iconset:\(pack.id)",
                            onUpdate: { await iconSetStore.syncPack(pack) }
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .font(.footnote)
                            Text("\(pack.icons.count) \("settings.iconPack.iconsUnit".l10n)\("settings.iconPack.localFileNote".l10n)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\("common.updatedAt".l10n) \(Date(timeIntervalSince1970: pack.lastUpdate.timeIntervalSince1970).formatted(date: .abbreviated, time: .shortened))")
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
            Section("resources.section.geo".l10n) {
                Toggle("resources.geo.autoUpdate".l10n, isOn: $geoAutoUpdate)
                    // C3: the toggle writes general-overlay.json
                    // (via settingsStore.save) so the tunnel core
                    // picks the change up at the next VPN start /
                    // live re-apply — the same pattern as the port
                    // steppers. Without this the file would keep
                    // the old value until an unrelated settings save.
                    .onChange(of: geoAutoUpdate) { _, _ in settingsStore.save() }
                if geoAutoUpdate {
                    HStack {
                        Text("resources.geo.interval".l10n)
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
                                    geoIntervalIssue = "resources.geo.intervalEmpty".l10n
                                } else if let hours = Int(digits), hours > 0 {
                                    geoAutoUpdateHours = Double(hours)
                                    geoIntervalIssue = nil
                                    settingsStore.save()
                                } else {
                                    geoIntervalIssue = "resources.geo.intervalInvalid".l10n
                                }
                            }
                        Text("resources.geo.hours".l10n)
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
                            Text("\(ConcordFormat.bytes(file.size))\(file.modified.map { " · \("common.updatedAt".l10n) \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("resources.geo.updateMmdb".l10n) {
                    Task { await ruleStore.geoUpdate(kind: "MMDB") }
                }
                Button("resources.geo.updateAsn".l10n) {
                    Task { await ruleStore.geoUpdate(kind: "ASN") }
                }
                Button("resources.geo.updateGeosite".l10n) {
                    Task { await ruleStore.geoUpdate(kind: "GEOSITE") }
                }
                Text("concord 的 geo.update 支持 MMDB、ASN、GEOSITE 三种（上游 FlClash 的 GeoResource 也是这三种）。更新在后台进行，完成后文件会出现在容器里。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("resources.geo.urlHint".l10n)
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
                Button("common.refresh".l10n) {
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
        .navigationTitle("tools.resources".l10n)
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
                Menu("resources.geo.menu".l10n) {
                    Button("resources.geo.updateMmdb".l10n) {
                        Task { await ruleStore.geoUpdate(kind: "MMDB") }
                    }
                    Button("resources.geo.updateAsn".l10n) {
                        Task { await ruleStore.geoUpdate(kind: "ASN") }
                    }
                    Button("resources.geo.updateGeosite".l10n) {
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
            return "resources.geo.invalidUrl".l10n
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)\("resources.geo.downloadUrl".l10n)")
                .font(.footnote.weight(.semibold))
            HStack {
                TextField("resources.geo.urlPlaceholder".l10n, text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !url.isEmpty {
                    Button("resources.geo.restoreDefault".l10n) { url = "" }
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
                    Text("\("common.updatedAt".l10n) \(Date(timeIntervalSince1970: TimeInterval(updatedAt)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if updatingItems.contains(updatingKey) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("common.update".l10n) {
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
            ruleStore.providerActionMessage = "\("providers.updated".l10n) \(provider.name)"
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
            ? "resources.updateAll.done".l10n
            : "\("resources.updateAll.donePrefix".l10n)\(failures.count) \("resources.updateAll.failedSuffix".l10n)\(failures.joined(separator: "common.listSeparator".l10n))"
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
