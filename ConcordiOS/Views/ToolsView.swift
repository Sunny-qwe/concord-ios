import SwiftUI

// MARK: - Tools (reference IMG_1111)
//
// The reference Tools page is three plain white cards with grey
// outline icons and 17pt semibold titles — no coloured tiles, no
// subtitles:
//   (no header)  请求 / DNS查询 / 资源 / 日志（v0.2.40 起始终显示；
//                此前仅当 常规 -> 记录日志开启时显示，见 FlClash
//                ToolsView 的 openLogs 门控——用户找不到日志入口，
//                故改为常显；日志本身一直由 LogStore 收集，与该开关无关）
//   设置         语言（值 "默认"）/ 主题 / 字体 / 应用图标 / 图标集 /
//                备份与恢复 / 可靠性中心 / 进阶配置 / MITM模块 /
//                MITM证书设置 / 常规 / 本地网络设置 / 回环保护
//   其他         免责声明 / 开发者模式（仅当开发者模式开启时显示）/ 关于
// Rows are 56pt tall, section labels 13pt semibold grey, card
// corner radius 24pt. Each row keeps its existing destination;
// 语言 is a real picker (AppStorage + AppleLanguages, restart to
// apply) and 免责声明 is the full 10-term text from FlClash.
//
// NOTE: the old Tools page also linked 规则 / 连接 / 日志 /
// MITM拦截 / MITM模块 / IP质量 / 快捷指令 / 提供方. 规则 / 日志 /
// IP质量 / 快捷指令 are reachable from the 常规 (Settings) page,
// and the rest remain linked from there or from MITM / Profiles,
// so no functionality is lost.

/// Tools destinations, navigated programmatically (see below).
/// Internal (not private): the Advanced hub and the Diagnostics
/// hub live in their own files and append their sub-pages to the
/// same path through one .navigationDestination.
enum ToolsDestination: Hashable {
    case requests
    case dns
    case resources
    case logs
    case language
    case theme
    case font
    case appIcon
    case iconSets
    case backup
    case diagnostics
    case diagnosticsHealth
    case diagnosticsAudit
    case diagnosticsPreflight
    case config
    case advancedNetwork
    case advancedDns
    case advancedRules
    case advancedProxies
    case advancedProviders
    case advancedFilters
    case configEditor
    case mitmModules
    case mitmCertificate
    case localNetwork
    case loopback
    case settings
    case disclaimer
    case developer
    case about
}

struct ToolsView: View {
    @AppStorage("ConcordiOS.appLanguage") private var appLanguage = ""
    @EnvironmentObject private var settingsStore: SettingsStore
    /// Programmatic navigation path. The rows used to be
    /// NavigationLinks; on the user's device (v0.2.15) every row was
    /// dead — taps did nothing — even though the stack and the links
    /// are present in the pushed source and no overlay, .disabled or
    /// gesture anywhere in the app can explain it. Buttons provably
    /// receive taps in this app (the floating tab bar is Buttons),
    /// so the rows are now Buttons that append to this path and the
    /// destinations render from one .navigationDestination — the
    /// NavigationLink tap handling is bypassed entirely.
    @State private var navPath: [ToolsDestination] = []

    private var languageDisplayName: String {
        switch appLanguage {
        case "zh-Hans": return "简体中文"
        case "en": return "English"
        case "es": return "Español"
        case "fr": return "Français"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "ru": return "Русский"
        default: return "默认"
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("tools.title".l10n)
                        .font(.system(size: 18, weight: .bold))
                    toolSection(header: nil) {
                        ToolRow(icon: "clock", title: "tools.requests".l10n) { navPath.append(.requests) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "server.rack", title: "tools.dns".l10n) { navPath.append(.dns) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "archivebox", title: "tools.resources".l10n) { navPath.append(.resources) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "doc.text", title: "tools.logs".l10n) { navPath.append(.logs) }
                    }
                    toolSection(header: "tools.section.settings".l10n) {
                        Button { navPath.append(.language) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 24, height: 24)
                                Text("tools.language".l10n)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(languageDisplayName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(.label))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "paintbrush", title: "tools.theme".l10n) { navPath.append(.theme) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "textformat", title: "settings.font".l10n) { navPath.append(.font) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "app", title: "tools.appIcon".l10n) { navPath.append(.appIcon) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "square.grid.2x2", title: "settings.iconSets".l10n) { navPath.append(.iconSets) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "arrow.clockwise.icloud", title: "tools.backup".l10n) { navPath.append(.backup) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "heart.text.square", title: "tools.diagnostics".l10n) { navPath.append(.diagnostics) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "wrench", title: "tools.advanced".l10n) { navPath.append(.config) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "puzzlepiece", title: "tools.mitmModules".l10n) { navPath.append(.mitmModules) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "key", title: "tools.mitmCert".l10n) { navPath.append(.mitmCertificate) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "gear", title: "tools.settings".l10n) { navPath.append(.settings) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "network", title: "tools.localNetwork".l10n) { navPath.append(.localNetwork) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "arrow.triangle.2.circlepath", title: "tools.loopback".l10n) { navPath.append(.loopback) }
                    }
                    toolSection(header: "tools.section.other".l10n) {
                        ToolRow(icon: "doc.text", title: "tools.disclaimer".l10n) { navPath.append(.disclaimer) }
                        if settingsStore.developerMode {
                            Divider().padding(.leading, 54)
                            ToolRow(icon: "hammer", title: "tools.developer".l10n) { navPath.append(.developer) }
                        }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "info.circle", title: "tools.about".l10n) { navPath.append(.about) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .background(ConcordTheme.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ToolsDestination.self) { destination in
                switch destination {
                case .requests: ConnectionsView()
                case .dns: DnsQueriesView()
                case .resources: ResourcesView()
                case .logs: LogsView()
                case .language: LanguageView()
                case .theme: ThemePickerView()
                case .font: FontPickerView()
                case .appIcon: AppIconPickerView()
                case .iconSets: IconSetsView()
                case .backup: BackupView()
                case .diagnostics: DiagnosticsView(navigate: { navPath.append($0) })
                case .diagnosticsHealth: NetworkHealthView()
                case .diagnosticsAudit: ModuleAuditView()
                case .diagnosticsPreflight: ConfigPreflightView()
                case .config: AdvancedConfigView(navigate: { navPath.append($0) })
                case .advancedNetwork: NetworkSettingsView()
                case .advancedDns: DnsSettingsView()
                case .advancedRules: AddedRulesView()
                case .advancedProxies: CustomProxiesView()
                case .advancedProviders: ProvidersView()
                case .advancedFilters: FiltersView()
                case .configEditor: ConfigEditorView()
                case .mitmModules: MitmModulesView()
                case .mitmCertificate: MitmCertificateView()
                case .localNetwork: LocalNetworkView()
                case .loopback: LoopbackView()
                case .settings: SettingsView()
                case .disclaimer: DisclaimerView()
                case .developer: DeveloperView()
                case .about: AboutView()
                }
            }
        }
    }

    /// One card: an optional 13pt section label above a 24pt-radius
    /// white card. Row dividers are written explicitly between rows
    /// (inset 54pt = 16 padding + 24 icon + 14 spacing).
    @ViewBuilder
    private func toolSection<Content: View>(header: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 24))
            .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
        }
    }
}

/// One 56pt row: plain grey outline icon, 13pt semibold title,
/// chevron right (16pt vertical padding + 24pt icon frame). A plain
/// Button (not a NavigationLink — see the note on navPath above).
/// The label fills the row width and carries the contentShape:
/// on device, contentShape on the Button itself did NOT extend the
/// hit area — only the chevron responded (v0.2.18) — while the
/// shape on the label HStack makes the whole row rect, including
/// the gap between the title and the chevron, tappable.
private struct ToolRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(.label))
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.label))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Language (real picker)
//
// FlClash's supported locales: en, es, fr, ja, ko, ru, zh-CN.
// The choice is persisted and applied via the standard
// AppleLanguages mechanism, which iOS reads at launch, so a
// restart is required before it takes effect. The primary
// interface strings (tab bar, Tools titles, common buttons —
// Localizable.xcstrings) follow the choice after restart; the
// rest of the app's strings are still hardcoded Chinese.
private struct LanguageView: View {
    @AppStorage("ConcordiOS.appLanguage") private var appLanguage = ""
    @State private var showRestartAlert = false

    private var displayName: String {
        switch appLanguage {
        case "zh-Hans": return "简体中文"
        case "en": return "English"
        case "es": return "Español"
        case "fr": return "Français"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "ru": return "Русский"
        default: return "默认"
        }
    }

    var body: some View {
        List {
            Section {
                Picker("语言", selection: $appLanguage) {
                    Text("默认（跟随系统）").tag("")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Русский").tag("ru")
                }
                .pickerStyle(.inline)
            } footer: {
                Text("切换语言后需要重启应用才会生效。重启后底部标签栏、工具页标题与常用按钮会按所选语言显示；页面内的其他文字仍为中文（只本地化了主要界面文字）。")
                    .font(.system(size: 13))
            }
        }
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appLanguage) { _, code in
            if code.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
            showRestartAlert = true
        }
        .alert("需要重启应用", isPresented: $showRestartAlert) {
            Button("common.ok".l10n, role: .cancel) {}
        } message: {
            Text("语言已设为\(displayName)，重启应用后生效。")
        }
    }
}

// MARK: - Disclaimer
//
// FlClash's full disclaimer (lib/views/disclaimer.dart): 10
// numbered terms plus the intro. The text is the Chinese version
// from the upstream localisation (messages_zh_CN.dart).
private struct DisclaimerView: View {
    /// The sentence the user must retype to agree (FlClash
    /// disclaimerNoServiceStatement — also the page's last line).
    static let restatement = "本应用不提供任何网络代理服务。"

    @AppStorage("ConcordiOS.disclaimer.consented") private var consented = false
    @AppStorage("ConcordiOS.disclaimer.consentedAt") private var consentedAt: Double = 0
    @Environment(\.dismiss) private var dismiss
    @State private var showRestateDialog = false
    @State private var disagreeMessage: String?
    private static let terms: [(String, String)] = [
        ("一、软件说明", "本应用是一款基于开源项目构建的网络代理工具，旨在帮助用户管理网络连接、优化网络访问体验。本应用不提供任何代理服务、服务器或网络内容，所有网络流量均由用户自行配置的代理服务器处理。"),
        ("二、使用范围", "本应用仅供个人学习、研究和合法用途使用。用户应确保其使用行为符合所在国家或地区的法律法规，不得将本应用用于任何非法目的，包括但不限于：访问非法内容、进行网络攻击、侵犯他人隐私、传播违法信息等。"),
        ("三、用户责任", "用户对使用本应用所产生的一切行为和后果承担全部责任。用户应自行确保所使用的代理服务器、订阅链接及相关配置的合法性与安全性。本应用不对用户通过第三方服务产生的任何问题负责。"),
        ("四、第三方服务", "本应用可能涉及第三方服务（如代理服务器、订阅服务、DNS 服务等），这些服务由第三方提供，与本应用无关。本应用不对第三方服务的可用性、安全性、合法性作任何保证，用户使用第三方服务时应自行承担风险。"),
        ("五、免责声明", "本应用按“现状”提供，不作任何明示或暗示的保证，包括但不限于对适销性、特定用途适用性、不侵权性的保证。在法律允许的最大范围内，开发者不对因使用或无法使用本应用而造成的任何直接、间接、附带、特殊或后果性损失承担责任。"),
        ("六、责任限制", "在任何情况下，开发者对用户因使用本应用而产生的任何损失（包括但不限于数据丢失、隐私泄露、财产损失）均不承担责任，即使开发者已被告知可能发生此类损失。"),
        ("七、隐私说明", "本应用不会收集、上传用户的个人信息或网络流量数据。所有配置与数据均保存在用户设备本地。MITM 抓包功能会解密 HTTPS 流量，仅可在自己拥有或已获授权的设备与流量上使用；抓包前需在系统设置中手动安装并信任自签 CA 证书。"),
        ("八、开源许可", "本应用核心为 chen08209/concord，界面复刻自 chen08209/FlClash，均以 GPL-3.0 开源。用户可自由查看、修改与分发源代码，但须遵守 GPL-3.0 许可证的条款。"),
        ("九、条款变更", "开发者保留随时修改本免责声明的权利，修改后的条款将在应用内公布。用户继续使用本应用即视为接受修改后的条款。"),
        ("十、接受条款", "使用本应用即表示您已阅读、理解并同意本免责声明的全部内容。如您不同意其中任何条款，请立即停止使用本应用并将其卸载。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("免责声明")
                        .font(.system(size: 18, weight: .bold))
                    Text("在使用本应用之前，请仔细阅读以下免责声明。使用本应用即表示您同意以下全部条款。")
                    ForEach(DisclaimerView.terms, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(body)
                        }
                    }
                    Text(DisclaimerView.restatement)
                        .font(.system(size: 13, weight: .semibold))
                    if let disagreeMessage {
                        Text(disagreeMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 13))
                .padding(16)
            }
            _ConsentBar(
                consented: consented,
                consentedDate: consentedAt > 0 ? Date(timeIntervalSince1970: consentedAt) : nil,
                onAgree: { showRestateDialog = true },
                onDisagree: {
                    consented = false
                    disagreeMessage = "您选择了不同意：请停止使用本应用并将其卸载。"
                },
                onWithdraw: { consented = false }
            )
        }
        .background(ConcordTheme.pageBackground)
        .navigationTitle("免责声明")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRestateDialog) {
            _RestateDialog(statement: DisclaimerView.restatement) {
                consented = true
                consentedAt = Date().timeIntervalSince1970
                showRestateDialog = false
            }
        }
    }
}

/// Consent bar (FlClash _ConsentBar): the bottom bar below the
/// terms. Agree opens the restatement dialog; disagree declines;
/// after agreeing it shows the consent time with a withdraw action.
private struct _ConsentBar: View {
    let consented: Bool
    let consentedDate: Date?
    let onAgree: () -> Void
    let onDisagree: () -> Void
    let onWithdraw: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if consented {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已同意免责声明")
                            .font(.system(size: 13, weight: .semibold))
                        if let date = consentedDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("撤回同意", role: .destructive, action: onWithdraw)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 12) {
                    Button("不同意", action: onDisagree)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button("同意", action: onAgree)
                        .buttonStyle(.borderedProminent)
                        .tint(ConcordTheme.accent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(ConcordTheme.cardBackground)
    }
}

/// Restatement dialog (FlClash _RestateDialog): shows the
/// statement and asks the user to type it out exactly. Confirm
/// stays disabled until the typed text matches; a non-prefix is
/// flagged as a mismatch. Typing it proves the user read it,
/// instead of a single thoughtless tap.
private struct _RestateDialog: View {
    let statement: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private enum Restatement { case partial, diverged, complete }

    private var restatement: Restatement {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == statement { return .complete }
        if trimmed.isEmpty || statement.hasPrefix(trimmed) { return .partial }
        return .diverged
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("请复述以下声明，以确认您已阅读并同意免责声明。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(statement)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                TextField("请逐字输入上方声明", text: $typed, axis: .vertical)
                    .lineLimit(3...)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if restatement == .diverged {
                    Text("输入与声明不一致，请对照上方文字重新输入。")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("确认同意")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认") { onConfirm() }
                        .disabled(restatement != .complete)
                }
            }
        }
    }
}
