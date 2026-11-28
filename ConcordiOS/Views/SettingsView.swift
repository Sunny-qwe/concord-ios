import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Upstream row atoms (v0.2.159, shared by the Settings cluster)
// Defined here — not in DesignSystem.swift (coordinator-owned):
// toggle / picker / stepper rows in the upstream card style, built
// on the shared UpstreamDivider / UpstreamToggleStyle atoms.
// Upstream's general/config field rows carry NO leading glyph
// (general.dart has none), so these rows have no icon either and
// their titles start at the 16pt card inset (dividers leading 16).

/// One 56pt upstream toggle row: 17pt title, optional 15pt grey
/// subtitle, UpstreamToggleStyle switch (52x32, solid grey OFF
/// track). The whole row toggles (upstream ListItem.toggle).
struct UpstreamToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
            }
        }
        .toggleStyle(UpstreamToggleStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

/// One 56pt upstream options row: 17pt title, optional 15pt grey
/// subtitle, menu Picker showing the current value.
struct UpstreamPickerRow<Value: Hashable, Options: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: Value
    @ViewBuilder let options: () -> Options

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
            }
            Spacer()
            Picker("", selection: $selection) { options() }
                .pickerStyle(.menu)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

/// One 56pt upstream stepper row: 17pt title, 15pt grey value
/// subtitle, − / + stepper.
struct UpstreamStepperRow: View {
    let title: String
    var valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Text(valueText)
                    .font(.subheadline)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            Spacer()
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

// MARK: - Settings / Tools (FlClash: ToolsView, lib/views/tools.dart)
// FlClash's Tools page is the settings hub: locale, theme, hotkeys,
// access, backup, advanced config, general config (log level, ports,
// allow LAN, IPv6, sniffing, user agent, delay timeout), plus the
// "More" pages (Requests, DNS, Resources, Logs). On iOS the equivalents
// are: 通用、TUN、DNS、MITM、网络、提供方、资源、关于. DNS queries and
// Resources are sub-pages here, matching FlClash's moreFull/more modes.
//
// v0.2.159: upstream FlClash general.dart order + wording
// (启动与后台 / 请求 / 入站 / 出站 / 连接 / 核心 / 日志与诊断,
// then the kept 配置 / 图标源 / 更多工具 sections). Sections and
// entries removed here are all duplicates of Tools landing rows or
// Advanced pages — see the per-page table in
// scratch/v0.2.159/reports/settings-cluster.md.

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var profileStore: ProfileStore
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
    /// Port form sheet (upstream general/port_form.dart): the five
    /// ports live on one 端口 row + form sheet, not as inline
    /// steppers.
    @State private var showPortForm = false

    /// The app's own version (Info.plist CFBundleShortVersionString),
    /// never a hardcoded string.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Hosts summary for the 核心 → Hosts row: "无" when the
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 启动与后台 (upstream general.dart _startupItems):
                // 自动运行 + 按需运行. "退出时最小化" is desktop-only
                // upstream (iOS has no system tray) — correctly absent.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.startup".l10n) {
                        UpstreamToggleRow(title: "settings.autorun".l10n, isOn: $settingsStore.autoRun)
                        UpstreamDivider(leading: 16)
                        NavigationLink {
                            OnDemandView()
                        } label: {
                            UpstreamNavRowContent(icon: "wifi", title: "settings.ondemand".l10n)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("自动运行：打开应用后自动启动 VPN（需已有配置）。上游另有「退出时最小化到托盘」，iOS 没有系统托盘，退出应用即进入后台，故不设此开关。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 请求 (upstream _requestItems): 用户代理 + 校验 TLS
                // 证书. The 自动检查更新 toggle lived here until
                // v0.2.159 — upstream puts it in About → 更新
                // (about.dart:89-102); removed here, to be added
                // there by the About agent (AboutView has no 更新
                // section yet). Behaviour/default unchanged.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "请求") {
                        NavigationLink {
                            UserAgentsView()
                        } label: {
                            UpstreamNavRowContent(
                                icon: "globe",
                                title: "settings.userAgent".l10n,
                                subtitle: settingsStore.globalUa.isEmpty ? "common.default".l10n : settingsStore.globalUa
                            )
                        }
                        .buttonStyle(.plain)
                        UpstreamDivider()
                        UpstreamToggleRow(title: "settings.checkCertificate".l10n, isOn: $settingsStore.checkCertificate)
                    }
                    Text("settings.checkCertificate.hint".l10n)
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 入站 (upstream _inboundItems): 端口 row (subtitle
                // = mixed-port number) → form sheet with the same
                // five fields (general/port_form.dart:26-76);
                // 局域网代理; 外部控制器密钥 link → GeneralAuthView
                // (upstream has the controller toggle + secret +
                // 允许跨域访问 inline — ours keeps the sub-page;
                // the CORS toggle is BLOCKED: no SettingsStore /
                // ConfigPatchParams field exists, see the report);
                // 认证 toggle.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.inbound".l10n) {
                        Button { showPortForm = true } label: {
                            UpstreamNavRowContent(icon: "number", title: "端口", subtitle: "\(settingsStore.mixedPort)")
                        }
                        .buttonStyle(.plain)
                        UpstreamDivider()
                        UpstreamToggleRow(title: "settings.allowLan".l10n, isOn: $settingsStore.allowLan)
                        UpstreamDivider(leading: 16)
                        NavigationLink {
                            GeneralAuthView()
                        } label: {
                            UpstreamNavRowContent(
                                icon: "key",
                                title: "settings.externalControllerSecret".l10n,
                                value: settingsStore.externalControllerSecret.isEmpty ? "common.notset".l10n : settingsStore.externalControllerSecret
                            )
                        }
                        .buttonStyle(.plain)
                        UpstreamDivider()
                        UpstreamToggleRow(title: "settings.auth".l10n, isOn: $settingsStore.authEnabled)
                    }
                    Text("端口 0 表示停用；启用的端口须在 1024–49151 之间且互不冲突。HTTP / redir / tproxy 在 iOS 上一般用不到，FlClash 仍在 iOS 上提供这三项，这里同样提供。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 出站 — KEPT functional (restyle only): upstream
                // has keep-alive in desktop-only outboundItems
                // (network.dart:396-425) and IPv6 in the
                // Android-only VpnSections, but the three
                // keep-alive keys + IPv6 are real core behaviour
                // with no other UI in our app, so they stay here.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.outbound".l10n) {
                        UpstreamToggleRow(title: "settings.disableKeepAlive".l10n, isOn: $settingsStore.disableKeepAlive)
                        UpstreamDivider(leading: 16)
                        // TCP 保活（核心 keep-alive-idle / interval /
                        // disable-keep-alive；0 = 核心默认）。经
                        // general-overlay.json 下发，下次启动 VPN 或切换出站
                        // 模式时生效。
                        UpstreamStepperRow(title: "settings.keepalive.idleLabel".l10n, valueText: keepAliveIdleText, value: $settingsStore.keepAliveIdle, range: 0...3600, step: 15)
                        UpstreamDivider(leading: 16)
                        UpstreamStepperRow(title: "settings.keepalive.intervalLabel".l10n, valueText: keepAliveIntervalText, value: $settingsStore.keepAliveInterval, range: 0...3600, step: 15)
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "IPv6", isOn: $settingsStore.ipv6)
                    }
                    Text("保活空闲 / 间隔为 0 表示用核心默认（空闲 15 秒）。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 连接 (upstream _connectionItems): 延迟测试超时,
                // 查找进程, 自动关闭连接, 仅统计代理流量. Plus the
                // kept 域名嗅探 master toggle (upstream has no
                // master toggle in General — sniffer enable is
                // per-profile — but it is the only switch for the
                // global master in our app), TCP 并发, 统一延迟
                // (both are _generalOverrideSpec keys upstream;
                // ours keeps them as direct toggles too).
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.connection".l10n) {
                        UpstreamPickerRow(title: "settings.delayTestTimeout".l10n, selection: $settingsStore.delayTestTimeout) {
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
                        UpstreamDivider(leading: 16)
                        // NOTED DIFFERENCE (flagged, kept on purpose):
                        // MuYu shows 始终查找进程 as a toggle; ours keeps
                        // the 3-way Picker (默认 strict / 始终 always /
                        // 关闭 off) — collapsing it to a toggle would force
                        // "off" on everyone who never touched it and disable
                        // PROCESS-NAME / PROCESS-PATH rules (config B4).
                        UpstreamPickerRow(title: "查找进程", selection: $settingsStore.findProcessModeSetting) {
                            Text("settings.findProcess.strict".l10n).tag("strict")
                            Text("settings.findProcess.always".l10n).tag("always")
                            Text("settings.findProcess.off".l10n).tag("off")
                        }
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "settings.autoCloseConnections".l10n, isOn: $settingsStore.autoCloseConnections)
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "settings.onlyStatisticsProxy".l10n, isOn: $settingsStore.onlyStatisticsProxy)
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "域名嗅探", isOn: $settingsStore.sniffing)
                            // B6: the master switch only takes effect
                            // when sniffer.json is re-saved (effective
                            // enable = master && page switch).
                            // SettingsStore.save() also propagates it;
                            // this makes the wiring explicit at the
                            // switch itself.
                            .onChange(of: settingsStore.sniffing) { _, _ in SnifferStore.shared.save() }
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "settings.tcpConcurrent".l10n, isOn: $settingsStore.tcpConcurrent)
                        UpstreamDivider(leading: 16)
                        UpstreamToggleRow(title: "settings.unifiedDelay".l10n, isOn: $settingsStore.unifiedDelay)
                    }
                    Text("\("settings.findProcess.explainerPrefix".l10n)\(settingsStore.findProcessMode ?? "common.unknown".l10n)\("settings.findProcess.explainerSuffix".l10n)")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                    Text("仅统计代理流量：打开后流量统计只计代理流量，直连流量不计入（上游 getTraffic 参数）。当前版本此开关只保存偏好，流量接口尚未接线，数字暂无变化。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                    Text("统一延迟测试：打开后测速只计量热连接上的第二次请求，拨号与 TLS 握手不再计入，延迟更接近真实往返耗时。VPN 开启时切换后立即生效；VPN 关闭时，隧道核心在下次启动时读取。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 核心 (upstream OverrideSection with
                // _generalOverrideSpec): Hosts row (subtitle 无 / N
                // 条), 追加系统 DNS, 添加覆盖 link, then the 通用
                // override keys in their own card below (test-url /
                // unified-delay / tcp-concurrent / ipv6). The editor
                // is OverrideSectionEditorCard, not the Section
                // version: a SwiftUI Section only renders inside a
                // List/Form, so embedding it in this card's VStack
                // would risk the key rows not rendering at all.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "核心") {
                        NavigationLink {
                            HostsView()
                        } label: {
                            UpstreamNavRowContent(icon: "list.bullet", title: "Hosts", subtitle: hostsSummary)
                        }
                        .buttonStyle(.plain)
                        UpstreamDivider()
                        // FlClash general.dart:360 _coreItems:
                        // appendSystemDns — append the system DNS
                        // servers to dns.nameserver at config build
                        // (task.dart:314). Wired in SettingsStore:
                        // the servers are read from /etc/resolv.conf
                        // and appended to dns.json's nameserver list.
                        UpstreamToggleRow(title: "settings.appendSystemDns".l10n, isOn: $settingsStore.appendSystemDns)
                        UpstreamDivider(leading: 16)
                        NavigationLink {
                            OverrideView()
                        } label: {
                            UpstreamNavRowContent(icon: "slider.horizontal.3", title: "settings.addOverride".l10n)
                        }
                        .buttonStyle(.plain)
                    }
                    OverrideSectionEditorCard(section: .general, scope: .constant(nil))
                        .padding(.top, 16) // 8 (group spacing) + 16 = 24, the page's inter-card gap
                    Text("追加系统 DNS：打开后，系统当前用的 DNS 服务器会追加到 DNS 上游列表末尾（订阅自带的解析服务器优先）。改动随 DNS 设置保存，下次启动 VPN 或点「应用 DNS 设置」后生效。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 日志与诊断 (upstream _logItems): 日志捕获 only.
                // The 日志级别 picker lived here until v0.2.159 —
                // upstream sets the level in the Logs page menu
                // (logs.dart:76-100); LogsView already has that
                // submenu (Picker "日志等级" writing
                // SettingsStore.logLevel), so nothing else to move.
                UpstreamCardSection(header: "settings.section.logs".l10n) {
                    // v0.2.68: the 日志捕获 toggle is back (deleted in
                    // v0.2.40). When it is OFF the Tools → 日志 row is
                    // hidden (ToolsView gates on openLogs); logging
                    // itself is still collected by LogStore either way.
                    UpstreamToggleRow(title: "settings.openLogs".l10n, isOn: $settingsStore.openLogs)
                }

                // 配置 — KEPT (restyle only): the only entry to the
                // global NTP / 嗅探 pages. Upstream has NTP/Sniffer
                // per-profile only, but our global pages are the
                // only UI for those settings.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.config".l10n) {
                        NavigationLink {
                            NtpSettingsView()
                        } label: {
                            UpstreamNavRowContent(icon: "clock", title: "NTP")
                        }
                        .buttonStyle(.plain)
                        UpstreamDivider()
                        NavigationLink {
                            SnifferSettingsView()
                        } label: {
                            UpstreamNavRowContent(icon: "waveform", title: "settings.sniff".l10n)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("settings.sniff.hint".l10n)
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 图标源 — KEPT (restyle only): NOT a duplicate of
                // Advanced → 图标集. Evidence: IconPackStore is the
                // single app-wide name→URL pack that ProxiesView /
                // Dashboard actually resolve group icons from
                // (IconPackStore.shared.iconURL); IconSetStore
                // manages multiple imported packs + a picker whose
                // selectedPack has no consumer outside IconSetsView.
                // Removing this section would orphan the live pack.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "settings.section.iconSource".l10n) {
                        HStack(spacing: 16) {
                            UpstreamRowIcon(systemName: "link")
                            TextField("settings.iconSource.urlPlaceholder".l10n, text: $iconPack.urlText)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        UpstreamDivider(leading: 16)
                        HStack(spacing: 16) {
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        if let name = iconPack.packName, iconPack.iconCount > 0 {
                            UpstreamDivider(leading: 16)
                            iconPackValueRow(title: "settings.iconPack.name".l10n, value: name)
                            UpstreamDivider(leading: 16)
                            iconPackValueRow(title: "settings.iconPack.count".l10n, value: String(format: "common.count.items".l10n, "\(iconPack.iconCount)"))
                            if let date = iconPack.fetchedAt {
                                UpstreamDivider(leading: 16)
                                iconPackValueRow(title: "settings.iconPack.updated".l10n, value: date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                    if iconPack.packName == nil || iconPack.iconCount == 0 {
                        Text("settings.iconSource.hint".l10n)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                    if let error = iconPack.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    } else if let notice = iconPack.noticeMessage {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                }

                // 更多工具 — KEPT (restyle only): without this
                // section the three pages are unreachable. Upstream
                // has no such section in Settings, and none of these
                // three pages has an upstream standalone entry:
                // RulesView is the global rules-in-force viewer
                // (upstream shows rules in force only inside the
                // profile editor / connections); ShortcutsView is
                // iOS-only (concord:// URL actions); the MITM
                // capture list upstream lives in the
                // Connections/Requests HTTP segment (same mitm.query
                // feed as MitmCaptureListView).
                UpstreamCardSection(header: "更多工具") {
                    NavigationLink {
                        RulesView()
                    } label: {
                        UpstreamNavRowContent(icon: "list.bullet.rectangle", title: "规则")
                    }
                    .buttonStyle(.plain)
                    UpstreamDivider()
                    NavigationLink {
                        ShortcutsView()
                    } label: {
                        UpstreamNavRowContent(icon: "bolt", title: "快捷指令")
                    }
                    .buttonStyle(.plain)
                    UpstreamDivider()
                    NavigationLink {
                        MitmCaptureListView()
                    } label: {
                        UpstreamNavRowContent(icon: "eye", title: "MITM 拦截记录")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 16)
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .background(ConcordTheme.pageBackground)
        .tint(ConcordTheme.accent)
        .upstreamNavBar(title: "title.settings".l10n)
        .concordNavBarBackground()
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
        .sheet(isPresented: $showPortForm) {
            PortFormSheet(
                mixedPort: $settingsStore.mixedPort,
                socksPort: $settingsStore.socksPort,
                httpPort: $httpPort,
                redirPort: $redirPort,
                tproxyPort: $tproxyPort,
                onSave: { settingsStore.save() }
            )
        }
    }

    /// One pack-info value row inside the 图标源 card: 17pt title,
    /// 11pt semibold grey trailing value.
    private func iconPackValueRow(title: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.body)
                .foregroundStyle(Color(.label))
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ConcordTheme.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

// MARK: - Port form sheet (FlClash: general/port_form.dart:26-76)
//
// Upstream presentation: one 端口 row (subtitle = mixed-port
// number) opening a form sheet with the same five fields
// (mixed / HTTP / SOCKS / redir / tproxy), validation
// (port_form.dart:118-152: mixed required 1024–49151, the others
// allow 0 = disabled, no two enabled ports may share a value)
// and a reset (mixed 7890, the rest 0). The sheet keeps the
// system default top padding (no 40pt).

private struct PortFormSheet: View {
    @Binding var mixedPort: Int
    @Binding var socksPort: Int
    @Binding var httpPort: Int
    @Binding var redirPort: Int
    @Binding var tproxyPort: Int
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mixedText: String
    @State private var httpText: String
    @State private var socksText: String
    @State private var redirText: String
    @State private var tproxyText: String

    init(mixedPort: Binding<Int>, socksPort: Binding<Int>, httpPort: Binding<Int>, redirPort: Binding<Int>, tproxyPort: Binding<Int>, onSave: @escaping () -> Void) {
        _mixedPort = mixedPort
        _socksPort = socksPort
        _httpPort = httpPort
        _redirPort = redirPort
        _tproxyPort = tproxyPort
        self.onSave = onSave
        _mixedText = State(initialValue: "\(mixedPort.wrappedValue)")
        _httpText = State(initialValue: "\(httpPort.wrappedValue)")
        _socksText = State(initialValue: "\(socksPort.wrappedValue)")
        _redirText = State(initialValue: "\(redirPort.wrappedValue)")
        _tproxyText = State(initialValue: "\(tproxyPort.wrappedValue)")
    }

    /// Upstream field order: mixed, HTTP, SOCKS, redir, tproxy.
    private var fieldTexts: [String] { [mixedText, httpText, socksText, redirText, tproxyText] }
    private var fieldLabels: [String] { ["settings.port.mixed".l10n, "HTTP", "SOCKS", "redir", "tproxy"] }
    private var fieldAllowDisabled: [Bool] { [false, true, true, true, true] }

    private func fieldIssue(text: String, label: String, allowDisabled: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else { return "\(label)请输入数字" }
        if value == 0 {
            return allowDisabled ? nil : "settings.ports.mixedRequired".l10n
        }
        if value < 1024 || value > 49151 {
            return "\(label)\("settings.ports.rangeError".l10n)"
        }
        return nil
    }

    /// First validation problem across the five fields, or nil.
    private var issue: String? {
        var seen: [Int: String] = [:]
        for index in fieldTexts.indices {
            if let problem = fieldIssue(text: fieldTexts[index], label: fieldLabels[index], allowDisabled: fieldAllowDisabled[index]) {
                return problem
            }
            let value = Int(fieldTexts[index].trimmingCharacters(in: .whitespaces)) ?? 0
            if value != 0 {
                if let other = seen[value] {
                    return "\(fieldLabels[index])\("settings.ports.conflictWith".l10n)\(other)\("settings.ports.conflictSuffix".l10n)"
                }
                seen[value] = fieldLabels[index]
            }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("端口")
                    .font(.headline)
                    .foregroundStyle(Color(.label))
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: nil) {
                        portField(label: fieldLabels[0], text: $mixedText)
                        UpstreamDivider(leading: 16)
                        portField(label: fieldLabels[1], text: $httpText)
                        UpstreamDivider(leading: 16)
                        portField(label: fieldLabels[2], text: $socksText)
                        UpstreamDivider(leading: 16)
                        portField(label: fieldLabels[3], text: $redirText)
                        UpstreamDivider(leading: 16)
                        portField(label: fieldLabels[4], text: $tproxyText)
                    }
                    if let issue {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                    Text("端口 0 表示停用；启用的端口须在 1024–49151 之间且互不冲突。HTTP / redir / tproxy 在 iOS 上一般用不到，FlClash 仍在 iOS 上提供这三项，这里同样提供。改动在下次启动 VPN 时生效；切换出站模式时也会立即应用。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                HStack {
                    Button("重置") {
                        mixedText = "7890"
                        httpText = "0"
                        socksText = "0"
                        redirText = "0"
                        tproxyText = "0"
                    }
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("保存") {
                        mixedPort = Int(mixedText.trimmingCharacters(in: .whitespaces)) ?? mixedPort
                        httpPort = Int(httpText.trimmingCharacters(in: .whitespaces)) ?? httpPort
                        socksPort = Int(socksText.trimmingCharacters(in: .whitespaces)) ?? socksPort
                        redirPort = Int(redirText.trimmingCharacters(in: .whitespaces)) ?? redirPort
                        tproxyPort = Int(tproxyText.trimmingCharacters(in: .whitespaces)) ?? tproxyPort
                        onSave()
                        dismiss()
                    }
                    .disabled(issue != nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .background(ConcordTheme.pageBackground)
        .presentationDetents([.medium])
    }

    private func portField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.body)
                .foregroundStyle(Color(.label))
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body)
                .frame(width: 100)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

// MARK: - Providers (FlClash: providers view, lib/views/config/providers.dart)
//
// v0.2.159: title 规则集 (upstream ruleProviders, l10n_zh:963);
// rows per upstream providers.dart:329-348 — label + behavior chip,
// subtitle 远程/本地, trailing last-update time. The long dynamic
// list keeps its List structure (swipe actions, import/sideload
// sections); only rows/fonts/nav-bar change. Import + sideload stay
// on the page (upstream: add menu; ours keeps the sections — the
// paste box is the nearest equivalent of blank-create, and moving
// them would orphan the sideload flow).

struct ProvidersView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var profileStore: ProfileStore
    /// The shared ClashProvider records store (v0.2.157): the
    /// scheduled auto-update runs on this instance (ContentView
    /// timer) and its lastAutoUpdateError is shown below.
    @EnvironmentObject private var clashProviderStore: ClashProviderStore
    /// Custom subscriptions, loaded once — the delete swipe
    /// action maps a confined-path row back to its owning
    /// definition (v0.2.152).
    @StateObject private var customStore = CustomSubscriptionStore()
    /// A confined rule provider awaiting delete confirm.
    @State private var pendingRuleProviderDelete: PendingRuleProviderDelete?
    @State private var showRuleProviderDeleteAlert = false

    /// A confined rule provider awaiting delete confirm (v0.2.152).
    private struct PendingRuleProviderDelete {
        var sub: CustomSubscription
        var provider: CustomProvider
    }
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            // v0.2.141 (C20-c1): this page is rule providers only
            // (upstream Advanced → 提供方, advanced.dart). Proxy
            // providers live in the profile-detail sheet
            // (dashboard profile card → ProfileDetailSheet).
            ForEach(ruleStore.ruleProviders) { provider in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.name)
                                .font(.body)
                                .foregroundStyle(Color(.label))
                                .lineLimit(1)
                            if let behavior = provider.behavior {
                                Text(behavior)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(.systemGray5), in: Capsule())
                            }
                        }
                        Text(provider.vehicleType.lowercased() == "http" ? "common.remote".l10n : "common.local".l10n)
                            .font(.subheadline)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                    Spacer()
                    if let updated = provider.updatedAt {
                        Text(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                    // v0.2.152 (C20-b3): delete, only for rows
                    // this app owns — a rule provider baked from
                    // a custom subscription via a confined file
                    // (path <home>/providers/<subID>/rules/
                    // <token>). All other rows are profile-defined
                    // / http-cache providers with no delete here,
                    // matching upstream (proxies/providers.dart
                    // has no delete; config/providers.dart deletes
                    // only its own ClashProvider records).
                    if let owned = CustomSubscriptionStore.ownerOfConfinedRuleProvider(path: provider.path, in: customStore.subscriptions) {
                        Button("common.delete".l10n) {
                            requestDeleteRuleProvider(sub: owned.sub, provider: owned.provider)
                        }
                        .tint(.red)
                    }
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
                    .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = ruleStore.providerActionMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let error = ruleStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
            // v0.2.157: scheduled provider auto-update failures
            // (same summary shape as the profile auto-update —
            // "自动更新失败（N 个）：…" — cleared on a clean run).
            if let error = clashProviderStore.lastAutoUpdateError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.top, 40)
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: "规则集")
        .concordNavBarBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await ruleStore.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await ruleStore.refresh() }
        // v0.2.152: referenced-provider delete confirm (see
        // requestDeleteRuleProvider) — the message names the
        // RULE-SET rules stripped along with the provider.
        .alert("删除提供方？", isPresented: $showRuleProviderDeleteAlert) {
            Button("common.delete".l10n, role: .destructive) {
                if let pending = pendingRuleProviderDelete {
                    deleteRuleProvider(sub: pending.sub, provider: pending.provider)
                }
                pendingRuleProviderDelete = nil
            }
            Button("取消", role: .cancel) { pendingRuleProviderDelete = nil }
        } message: {
            if let pending = pendingRuleProviderDelete {
                let users = ruleProviderDeleteUsers(sub: pending.sub, name: pending.provider.name)
                Text(users.isEmpty ? "删除后，提供方将从配置中移除。" : users.map { "「\(pending.provider.name)」正被\($0)使用" }.joined(separator: "\n") + "\n删除后，这些引用会一并移除。")
            } else {
                Text("")
            }
        }
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

    // MARK: - Confined rule-provider delete (v0.2.152, C20-b3)

    /// RULE-SET rules naming a rule provider inside its owning
    /// subscription (groups never use rule providers).
    private func ruleProviderDeleteUsers(sub: CustomSubscription, name: String) -> [String] {
        var users = sub.rules.filter { $0.type == "RULE-SET" && $0.content == name }.map { "规则「\($0.text)」" }
        // v0.2.157: the delete also strips the scoped DNS /
        // sniffer `rule-set:` references (see deleteRuleProvider),
        // so they count in the confirm too.
        users.append(contentsOf: CustomSubscriptionStore.ruleSetPolicyReferenceLabels(in: sub, name: name))
        return users
    }

    /// Delete swipe action: an unreferenced provider goes
    /// straight away; a referenced one asks first, because the
    /// delete also strips the RULE-SET rules naming it.
    private func requestDeleteRuleProvider(sub: CustomSubscription, provider: CustomProvider) {
        if ruleProviderDeleteUsers(sub: sub, name: provider.name).isEmpty {
            deleteRuleProvider(sub: sub, provider: provider)
        } else {
            pendingRuleProviderDelete = PendingRuleProviderDelete(sub: sub, provider: provider)
            showRuleProviderDeleteAlert = true
        }
    }

    /// Removes the definition + its RULE-SET rules, persists,
    /// then cleans up the map entry / confined file /
    /// ClashProvider record and re-applies the active profile
    /// when it bakes this subscription — the same path as the
    /// editor's saveDraft. The row is refreshed afterwards; a
    /// re-apply failure surfaces in ruleStore.lastError (only
    /// read when a re-apply actually ran — see
    /// reapplyActiveForSubscription) so the provider does not
    /// silently survive.
    private func deleteRuleProvider(sub: CustomSubscription, provider: CustomProvider) {
        var copy = sub
        copy.ruleProviders.removeAll { $0.name == provider.name }
        copy.rules.removeAll { $0.type == "RULE-SET" && $0.content == provider.name }
        // v0.2.157: strip the scoped DNS / sniffer `rule-set:`
        // references (the 152 gap). No same-named survivor can
        // exist here — removeAll above took every provider of
        // this name — so no twin guard is needed.
        CustomSubscriptionStore.stripRuleSetPolicyReferences(in: &copy, deletedName: provider.name)
        let store = CustomSubscriptionStore()
        store.update(copy)
        _ = CustomSubscriptionStore.cleanupDeletedProviders(old: sub, new: copy)
        customStore.load()
        Task {
            let reapplied = await profileStore.reapplyActiveForSubscription(id: sub.id)
            // Capture the re-apply failure BEFORE refresh():
            // refresh() clears lastError on success, which would
            // wipe the failure message (audit g). Restore it
            // afterwards, combined with a refresh failure when
            // both happened.
            let reapplyError = reapplied ? profileStore.lastError : nil
            await ruleStore.refresh()
            if let error = reapplyError {
                if let refreshError = ruleStore.lastError {
                    ruleStore.lastError = "删除「\(provider.name)」后重新应用配置失败：\(error)；刷新列表失败：\(refreshError)"
                } else {
                    ruleStore.lastError = "删除「\(provider.name)」后重新应用配置失败：\(error)"
                }
            }
        }
    }
}

// MARK: - Resources (FlClash: ResourcesView, lib/views/resources.dart)
//
// v0.2.159: upstream order — 自动更新 (+ 更新间隔 tap row) /
// Geo 资源 / 图标集 / 规则集 / 脚本 / MITM 模块; update-all is the
// toolbar sync icon (resources.dart:184-193), not a button; every
// row is title + last-update-or-未知 subtitle + size/count chip
// with a per-row menu (同步 / 编辑 URL / 复制链接,
// _ResourceItem). Removed: the 可更新 button section, the Geo file
// list + three Geo update buttons (now per-row menu sync), the
// inline Geo URL fields (now per-row 编辑 URL dialog), the builtin
// icon-set row ("默认" — upstream has none), the MITM 脚本
// total-count row (now one row per script), the 刷新 button section,
// and the toolbar Geo menu.

struct ResourcesView: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var iconSetStore = IconSetStore.shared
    /// Standalone MITM scripts (MitmScriptStore — ScriptsView owns
    /// its own instance the same way; this one only reads the
    /// registry + syncs remote scripts).
    @StateObject private var scriptStore = MitmScriptStore()
    @State private var geoFiles: [GeoFileInfo] = []
    /// Update-interval dialog draft (FlClash resources.dart
    /// _updateInterval: a free number input in hours, digits only,
    /// max 6 digits, must be > 0). Set from the stored hours when
    /// the dialog opens; the stored value updates on save.
    @State private var showIntervalDialog = false
    @State private var intervalDraft = ""
    @State private var geoIntervalIssue: String?
    /// Per-row Geo URL edit dialog (upstream UpdateGeoUrlFormDialog):
    /// which kind is being edited + its draft URL. Empty = core default.
    @State private var urlEditKind: GeoResourceKind?
    @State private var urlEditText = ""
    @State private var geoURLIssue: String?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 自动更新 (upstream: untitled first section) —
                // toggle + [if on] 更新间隔 row, subtitle "N 小时",
                // tap → number input dialog.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: nil) {
                        UpstreamToggleRow(title: "resources.geo.autoUpdate".l10n, isOn: $geoAutoUpdate)
                            // C3: the toggle writes general-overlay.json
                            // (via settingsStore.save) so the tunnel core
                            // picks the change up at the next VPN start /
                            // live re-apply — the same pattern as the port
                            // steppers. Without this the file would keep
                            // the old value until an unrelated settings save.
                            .onChange(of: geoAutoUpdate) { _, _ in settingsStore.save() }
                        if geoAutoUpdate {
                            UpstreamDivider(leading: 16)
                            Button {
                                intervalDraft = "\(Int(geoAutoUpdateHours))"
                                showIntervalDialog = true
                            } label: {
                                UpstreamNavRowContent(
                                    icon: "clock",
                                    title: "resources.geo.interval".l10n,
                                    subtitle: "\(Int(geoAutoUpdateHours)) \("resources.geo.hours".l10n)"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // v0.2.157: the same switch + interval also drives
                    // the scheduled rule-provider auto-update (upstream
                    // resources.dart autoUpdate gates providers on the
                    // geo switch) — no separate provider switch exists
                    // upstream, so none is added here.
                    Text("打开后，规则提供方的内容也会按同一间隔自动更新（上次更新时间见提供方页）。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                    if let geoIntervalIssue {
                        Text(geoIntervalIssue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                    if let message = updateAllMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                }

                // Geo 资源 (upstream _GeoResourceItem per GeoResource):
                // title = type name, subtitle = last-update or 未知,
                // trailing chip = file size, menu: 同步 / 编辑 URL /
                // 复制链接.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "resources.section.geo".l10n) {
                        ForEach(Array(GeoResourceKind.allCases.enumerated()), id: \.element) { index, kind in
                            if index > 0 { UpstreamDivider(leading: 16) }
                            geoRow(kind: kind)
                        }
                    }
                    Text("concord 的 geo.update 支持 MMDB、ASN、GEOSITE 三种（上游 FlClash 的 GeoResource 也是这三种）。更新在后台进行，完成后文件会出现在容器里。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                    if let geoURLIssue {
                        Text(geoURLIssue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }

                // 图标集 (upstream _IconSetItem): imported sets only.
                // Remote sets get a sync menu; local (file-imported)
                // packs have no source URL and no update action.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "resources.section.iconSets".l10n) {
                        if iconSetStore.importedPacks.isEmpty {
                            Text("暂无已导入的图标集。")
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        } else {
                            ForEach(Array(iconSetStore.importedPacks.enumerated()), id: \.element.id) { index, pack in
                                if index > 0 { UpstreamDivider(leading: 16) }
                                ResourceMenuRow(
                                    title: pack.name,
                                    subtitle: updatedSubtitle(Int64(pack.lastUpdate.timeIntervalSince1970)),
                                    chip: String(format: "common.count.icons".l10n, "\(pack.icons.count)"),
                                    isUpdating: updatingItems.contains("iconset:\(pack.id)"),
                                    showMenu: pack.isRemote
                                ) {
                                    Button("同步") {
                                        Task {
                                            updatingItems.insert("iconset:\(pack.id)")
                                            await iconSetStore.syncPack(pack)
                                            updatingItems.remove("iconset:\(pack.id)")
                                        }
                                    }
                                    if !pack.url.isEmpty {
                                        Button("复制链接") {
                                            UIPasteboard.general.string = pack.url
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let message = iconSetStore.actionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                    if let error = iconSetStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }

                // 规则集 (upstream _RuleProviderItem): title, subtitle
                // = last-update or 未知, trailing chip = entry count,
                // menu: 同步.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "规则集") {
                        if ruleStore.ruleProviders.isEmpty {
                            Text("resources.noRuleProviders".l10n)
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        } else {
                            ForEach(Array(ruleStore.ruleProviders.enumerated()), id: \.element.id) { index, provider in
                                if index > 0 { UpstreamDivider(leading: 16) }
                                ResourceMenuRow(
                                    title: provider.name,
                                    subtitle: updatedSubtitle(provider.updatedAt),
                                    chip: String(format: "common.count.entries".l10n, "\(provider.count)"),
                                    isUpdating: updatingItems.contains("provider:\(provider.name)")
                                ) {
                                    Button("同步") {
                                        Task {
                                            updatingItems.insert("provider:\(provider.name)")
                                            await updateProvider(provider)
                                            updatingItems.remove("provider:\(provider.name)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let message = ruleStore.providerActionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                    if let error = ruleStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }

                // 脚本 (upstream _ScriptItem): one row per script,
                // not a total-count row. Remote scripts get a sync
                // menu; local scripts are plain rows.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "脚本") {
                        if scriptStore.scripts.isEmpty {
                            Text("暂无 MITM 脚本。")
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        } else {
                            ForEach(Array(scriptStore.scripts.enumerated()), id: \.element.id) { index, script in
                                if index > 0 { UpstreamDivider(leading: 16) }
                                ResourceMenuRow(
                                    title: script.label,
                                    subtitle: updatedSubtitle(Int64(script.lastUpdateTime.timeIntervalSince1970)),
                                    isUpdating: scriptStore.updatingIds.contains(script.id),
                                    showMenu: script.isRemote
                                ) {
                                    Button("同步") {
                                        Task { await scriptStore.update(script) }
                                    }
                                    if let url = script.url, !url.isEmpty {
                                        Button("复制链接") {
                                            UIPasteboard.general.string = url
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let error = scriptStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }

                // MITM 模块 (upstream _ModuleItem): title, subtitle =
                // last-update or 未知, menu: 同步 / 复制链接.
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "resources.section.mitmModules".l10n) {
                        if mitmModuleStore.modules.isEmpty {
                            Text("resources.noMitmModules".l10n)
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        } else {
                            ForEach(Array(mitmModuleStore.modules.enumerated()), id: \.element.id) { index, module in
                                if index > 0 { UpstreamDivider(leading: 16) }
                                ResourceMenuRow(
                                    title: module.name,
                                    subtitle: updatedSubtitle(Int64(module.lastUpdateTime.timeIntervalSince1970)),
                                    isUpdating: updatingItems.contains("module:\(module.id)")
                                ) {
                                    Button("同步") {
                                        Task {
                                            updatingItems.insert("module:\(module.id)")
                                            await mitmModuleStore.update(module)
                                            updatingItems.remove("module:\(module.id)")
                                        }
                                    }
                                    if let url = module.url, !url.isEmpty {
                                        Button("复制链接") {
                                            UIPasteboard.general.string = url
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let error = mitmModuleStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 16)
        }
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "tools.resources".l10n)
        .concordNavBarBackground()
        .toolbar {
            // Update-all is the app-bar sync icon upstream
            // (resources.dart:184-193), not a button on the page.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await updateAllResources() }
                } label: {
                    if isUpdatingAll {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isUpdatingAll)
            }
        }
        .task {
            scanGeoFiles()
        }
        .alert("resources.geo.interval".l10n, isPresented: $showIntervalDialog) {
            TextField("24", text: $intervalDraft)
                .keyboardType(.numberPad)
            Button("保存") { saveInterval() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("更新间隔（小时），须大于 0。")
        }
        .alert("编辑下载地址", isPresented: Binding(
            get: { urlEditKind != nil },
            set: { if !$0 { urlEditKind = nil } }
        )) {
            TextField("https://…", text: $urlEditText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") { saveGeoURL() }
            Button("恢复默认") {
                if let kind = urlEditKind {
                    var binding = geoURLBinding(for: kind)
                    binding.wrappedValue = ""
                }
                geoURLIssue = nil
                urlEditKind = nil
            }
            Button("取消", role: .cancel) { urlEditKind = nil }
        } message: {
            Text("留空使用核心默认地址。")
        }
    }

    /// Upstream _ResourceItem subtitle: last-update time, or 未知.
    private func updatedSubtitle(_ updatedAt: Int64?) -> String {
        guard let updatedAt else { return "common.unknown".l10n }
        return "\("common.updatedAt".l10n) \(Date(timeIntervalSince1970: TimeInterval(updatedAt)).formatted(date: .abbreviated, time: .shortened))"
    }

    /// The Geo file on disk for one kind, matched by filename
    /// heuristic (mihomo names: Country.mmdb / GeoIP.dat for MMDB,
    /// ASN.mmdb for ASN, geosite.dat for GeoSite). "ASN.mmdb"
    /// contains "mmdb" too, so the MMDB match excludes "asn".
    private func geoFile(for kind: GeoResourceKind) -> GeoFileInfo? {
        geoFiles.first { file in
            let lower = file.name.lowercased()
            switch kind {
            case .mmdb:
                return (lower.contains("mmdb") || lower.contains("geoip") || lower.contains("country")) && !lower.contains("asn")
            case .asn:
                return lower.contains("asn")
            case .geosite:
                return lower.contains("geosite")
            }
        }
    }

    private func geoURLBinding(for kind: GeoResourceKind) -> Binding<String> {
        switch kind {
        case .mmdb: return $geoURLMMDB
        case .asn: return $geoURLASN
        case .geosite: return $geoURLGeosite
        }
    }

    /// One Geo row: title = type name, subtitle = last-update or
    /// 未知, trailing chip = file size, menu: 同步 / 编辑 URL /
    /// 复制链接 (upstream _GeoResourceItem + _ResourceItem menu).
    private func geoRow(kind: GeoResourceKind) -> some View {
        let file = geoFile(for: kind)
        let url = geoURLBinding(for: kind).wrappedValue
        return ResourceMenuRow(
            title: kind.title,
            subtitle: updatedSubtitle(file?.modified.map { Int64($0.timeIntervalSince1970) }),
            chip: file.map { ConcordFormat.bytes($0.size) },
            isUpdating: updatingItems.contains("geo:\(kind.rawValue)")
        ) {
            Button("同步") {
                Task {
                    updatingItems.insert("geo:\(kind.rawValue)")
                    await ruleStore.geoUpdate(kind: kind.rawValue)
                    scanGeoFiles()
                    updatingItems.remove("geo:\(kind.rawValue)")
                }
            }
            Button("编辑 URL") {
                urlEditText = url
                urlEditKind = kind
            }
            if !url.isEmpty {
                Button("复制链接") {
                    UIPasteboard.general.string = url
                }
            }
        }
    }

    /// Interval dialog save (FlClash input_limits.dart
    /// geoUpdateInterval: digits only, max 6 chars, must be > 0).
    private func saveInterval() {
        let digits = intervalDraft.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 6, let hours = Int(digits), hours > 0 else {
            geoIntervalIssue = "resources.geo.intervalInvalid".l10n
            return
        }
        geoAutoUpdateHours = Double(hours)
        geoIntervalIssue = nil
        settingsStore.save()
    }

    /// Geo URL dialog save (upstream UpdateGeoUrlFormDialog):
    /// empty = core default; otherwise must be an http(s) URL.
    private func saveGeoURL() {
        guard let kind = urlEditKind else { return }
        var binding = geoURLBinding(for: kind)
        let value = urlEditText.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            binding.wrappedValue = ""
            geoURLIssue = nil
            urlEditKind = nil
            return
        }
        guard let parsed = URL(string: value),
              parsed.scheme?.hasPrefix("http") == true,
              parsed.host != nil else {
            geoURLIssue = "resources.geo.invalidUrl".l10n
            urlEditKind = nil
            return
        }
        binding.wrappedValue = value
        geoURLIssue = nil
        urlEditKind = nil
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

/// One Geo resource kind (upstream GeoResource: MMDB / ASN / GEOSITE).
private enum GeoResourceKind: String, CaseIterable {
    case mmdb = "MMDB"
    case asn = "ASN"
    case geosite = "GEOSITE"

    var title: String {
        switch self {
        case .mmdb: return "GeoIP（MMDB）"
        case .asn: return "ASN"
        case .geosite: return "GeoSite"
        }
    }
}

/// One upstream resource row (FlClash resources.dart _ResourceItem):
/// 17pt title, 15pt grey last-update subtitle, trailing size/count
/// chip (or spinner while updating), per-row menu (同步 / 编辑 URL /
/// 复制链接). Local items pass showMenu: false and render plain.
private struct ResourceMenuRow<MenuContent: View>: View {
    let title: String
    let subtitle: String
    var chip: String? = nil
    var isUpdating: Bool = false
    var showMenu: Bool = true
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            Spacer()
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                if let chip {
                    Text(chip)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray5), in: Capsule())
                }
                if showMenu {
                    Menu {
                        menuContent()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}
