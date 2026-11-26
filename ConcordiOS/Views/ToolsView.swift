import SwiftUI

// MARK: - Tools (reference IMG_1111)
//
// The reference Tools page is three plain white cards with grey
// outline icons and 17pt semibold titles — no coloured tiles, no
// subtitles:
//   (no header)  请求 / DNS查询 / 资源 / 日志（v0.2.68 起仅当
//                常规 -> 日志捕获 开启时显示，见 SettingsStore.openLogs；
//                v0.2.40–v0.2.67 曾始终显示，因用户找不到日志入口——
//                恢复开关后默认关闭会再次隐藏入口，见 ToolsView 日志行注释）
//   设置         语言（值 "默认"）/ 主题 / 备份与恢复 / 进阶配置 /
//                常规 — exactly upstream tools.dart _getSettingList
//                on iOS (Locale / Theme / Backup / AdvancedConfig /
//                General). 字体 lives in the Theme page (upstream
//                theme.dart _FontFamilyItem), 图标集 / MITM模块 /
//                MITM证书 / 本地网络设置 live in 进阶配置 (upstream
//                advanced.dart), 应用图标 and 回环保护 do not exist
//                upstream and are deleted (v0.2.136).
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
/// Internal (not private): the Advanced hub lives in its own
/// file and appends its sub-pages to the same path through one
/// .navigationDestination.
enum ToolsDestination: Hashable {
    case requests
    case dns
    case resources
    case logs
    case language
    case theme
    case iconSets
    case backup
    case config
    case advancedNetwork
    case advancedDns
    case advancedRules
    case advancedScripts
    case advancedProxies
    case advancedProviders
    case advancedFilters
    case configEditor
    case settings
    case disclaimer
    case developer
    case about
}

/// Posted when the Tools tab is re-tapped while already selected:
/// upstream ToolsView jumps its scroll controller to 0 on
/// re-selection (tools.dart:41-48).
extension Notification.Name {
    static let toolsScrollToTop = Notification.Name("ConcordiOS.toolsScrollToTop")
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
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                    // FlClash pageTitle is 24pt semibold on a tab
                    // page (scaffold.dart:780); the 18pt bold here
                    // was the v0.2.50-era guess.
                    Text("tools.title".l10n)
                        .font(.system(size: 24, weight: .bold))
                    toolSection(header: nil) {
                        ToolRow(icon: "clock", title: "tools.requests".l10n) { navPath.append(.requests) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "server.rack", title: "tools.dns".l10n) { navPath.append(.dns) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "archivebox", title: "tools.resources".l10n) { navPath.append(.resources) }
                        // v0.2.68 (MuYu): the Logs row shows only
                        // when 常规 → 日志捕获 is on (restored
                        // toggle, SettingsStore.openLogs). NOTE: the
                        // stored default is off, so a fresh install
                        // hides the Logs row until the user turns
                        // 日志捕获 on in 常规.
                        if settingsStore.openLogs {
                            Divider().padding(.leading, 54)
                            ToolRow(icon: "terminal", title: "tools.logs".l10n) { navPath.append(.logs) }
                        }
                    }
                    toolSection(header: "tools.section.settings".l10n) {
                        Button { navPath.append(.language) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 24, height: 24)
                                Text("tools.language".l10n)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(languageDisplayName)
                                    .font(.footnote)
                                    .foregroundStyle(Color(.label))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.semibold))
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
                        ToolRow(icon: "arrow.clockwise.icloud", title: "tools.backup".l10n) { navPath.append(.backup) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "wrench", title: "tools.advanced".l10n) { navPath.append(.config) }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "gear", title: "tools.settings".l10n) { navPath.append(.settings) }
                    }
                    toolSection(header: "tools.section.other".l10n) {
                        // v0.2.68 (MuYu): the disclaimer icon is a
                        // gavel, not doc.text (which also collided
                        // with the Logs icon). GavelIcon lives in
                        // Views/CustomGlyphs.swift (shared with the
                        // Connections page).
                        ToolGlyphRow(title: "tools.disclaimer".l10n, icon: { GavelIcon(size: 18, color: Color(.label)) }) { navPath.append(.disclaimer) }
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
                .padding(.bottom, ConcordTheme.tabBarClearance)
                .id("toolsTop")
                }
                .background(ConcordTheme.pageBackground)
                .toolbar(.hidden, for: .navigationBar)
                .onReceive(NotificationCenter.default.publisher(for: .toolsScrollToTop)) { _ in
                    // Re-tap on the Tools tab (M0-1/T-M1): jump back
                    // to the top of the page.
                    withAnimation { scrollProxy.scrollTo("toolsTop", anchor: .top) }
                }
            }
            .navigationDestination(for: ToolsDestination.self) { destination in
                // v0.2.83 white-bar fix: the bar blends with the page
                // background on every Tools sub-page.
                Group {
                    switch destination {
                    case .requests: ConnectionsView(applyTabBarClearance: true)
                case .dns: DnsQueriesView()
                case .resources: ResourcesView()
                case .logs: LogsView()
                case .language: LanguageView()
                case .theme: ThemePickerView()
                case .iconSets: IconSetsView()
                case .backup: BackupView()
                case .config: AdvancedConfigView(navigate: { navPath.append($0) })
                case .advancedNetwork: NetworkSettingsView()
                case .advancedDns: DnsSettingsView()
                case .advancedRules: AddedRulesView()
                case .advancedScripts: ScriptsView()
                case .advancedProxies: CustomProxiesView()
                case .advancedProviders: ProvidersView()
                case .advancedFilters: FiltersView()
                case .configEditor: ConfigEditorView()
                case .settings: SettingsView()
                case .disclaimer: DisclaimerView()
                case .developer: DeveloperView()
                case .about: AboutView()
                    }
                }
                .concordNavBarBackground()
            }
        }
        .toolbarBackground(ConcordTheme.pageBackground, for: .navigationBar)
    }

    /// One card: an optional 13pt section label above a 24pt-radius
    /// white card. Row dividers are written explicitly between rows
    /// (inset 54pt = 16 padding + 24 icon + 14 spacing).
    @ViewBuilder
    private func toolSection<Content: View>(header: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
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

/// A ToolRow whose icon is a custom-drawn glyph view instead of
/// an SF Symbol (v0.2.68: the disclaimer gavel, GavelIcon from
/// CustomGlyphs.swift). Same 56pt row geometry as ToolRow.
private struct ToolGlyphRow<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
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
                    .font(.footnote)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
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
// titled sections from the upstream localisation (l10n_zh.dart
// disclaimer*Title/Content + disclaimerNoServiceStatement).
// Section 1's content is the software content plus the
// no-service statement, exactly as upstream composes it
// (disclaimer.dart:29); the intro is disclaimerDesc. The
// retype-to-agree sentence IS the no-service statement
// (disclaimer.dart:467).
private struct DisclaimerView: View {
    /// The sentence the user must retype to agree (FlClash
    /// disclaimerNoServiceStatement — also the page's last line).
    static let restatement = "本软件自身不提供任何代理服务器、节点、订阅、机场或网络接入服务，也不与任何此类服务的提供者存在合作、代理或担保关系。"

    @AppStorage("ConcordiOS.disclaimer.consented") private var consented = false
    @AppStorage("ConcordiOS.disclaimer.consentedAt") private var consentedAt: Double = 0
    @Environment(\.dismiss) private var dismiss
    @State private var showRestateDialog = false
    @State private var restateTyped = ""
    @State private var disagreeMessage: String?
    private static let terms: [(String, String)] = [
        ("软件性质", "本软件是基于 Concord 内核的开源网络代理客户端，仅提供配置管理、规则分流与流量转发等本地工具功能。\n\n本软件自身不提供任何代理服务器、节点、订阅、机场或网络接入服务，也不与任何此类服务的提供者存在合作、代理或担保关系。"),
        ("使用说明", "任何人基于本软件开展的商业活动，包括付费分发、捆绑销售或作为商业服务的组成部分，均与本软件的开发者无关，开发者不为其提供背书、支持或担保。\n\n你须自行遵守所在国家或地区的法律法规，因违法使用本软件产生的后果由你自行承担。"),
        ("用户责任", "你应自行确认使用本软件在你所在国家或地区是合法的，并对使用本软件的全部行为及其后果独立承担法律责任。\n\n你导入的订阅、节点与配置由你自行选择和判断，其来源是否合法、内容是否安全、服务是否稳定，均由你与相关提供者自行负责。"),
        ("第三方内容", "订阅链接、配置文件、规则集、脚本、外部资源及外部链接均由第三方提供，开发者无法也不会对其合法性、准确性、安全性和可用性进行审查或担保。\n\n因使用第三方内容导致的数据泄露、财产损失、账号封禁或其他任何损失，由你与第三方自行解决，开发者不承担任何责任。"),
        ("无担保声明", "本软件按“现状”和“可用”的原则提供，不附带任何明示或默示的担保，包括但不限于适销性、特定用途适用性、不侵权以及持续可用、无错误、无安全漏洞的担保。\n\n开发者不保证本软件能满足你的需求，也不保证本软件的运行不会中断或不会出现错误。"),
        ("责任限制", "在适用法律允许的最大范围内，开发者及所有贡献者均不对因使用或无法使用本软件而产生的任何直接、间接、偶然、特殊、惩罚性或后果性损害承担责任，包括但不限于数据丢失、设备损坏、网络异常、业务中断、利润损失或因此引起的任何法律纠纷，即使已被告知发生此类损害的可能性。"),
        ("数据收集与隐私", "本软件不会收集或上传你的订阅地址、节点信息、配置内容、访问的网站、连接记录、流量内容和日志，这些数据仅保存在你的设备本地，开发者无法获取。\n\n本软件只会在你使用相应功能时访问外部网络，例如更新订阅时访问你提供的订阅地址、检查更新时访问 GitHub。\n\n本软件在所有平台上均未集成任何数据统计或崩溃上报服务。"),
        ("开源协议", "本软件以 GPL-3.0 协议开源，你可以依该协议运行、研究、修改和分发本软件；分发本软件或其修改版本时，须同样以 GPL-3.0 协议提供源代码并保留原有的版权声明。\n\n本软件包含的第三方组件（包括 Concord 内核）分别遵循其各自的开源协议。基于本软件修改或分发的版本所产生的任何问题，与原作者无关。"),
        ("声明变更", "本声明可能随版本更新而修订，以每个版本附带的内容为准。"),
        ("与开源协议的关系", "本声明是对软件性质、风险与责任的说明，不是 GPL-3.0 之外的附加条款，也不限制该协议授予你的运行、复制、修改和分发等任何权利；两者不一致时，以 GPL-3.0 为准。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("免责声明")
                        .font(.system(size: 18, weight: .bold))
                    Text("在使用 FlClash（以下简称“本软件”）前，请仔细阅读并充分理解本声明。点击“同意”表示你已阅读并理解以下内容；如不想继续，可点击“退出”。")
                    ForEach(DisclaimerView.terms, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.footnote.weight(.semibold))
                            Text(body)
                        }
                    }
                    Text(DisclaimerView.restatement)
                        .font(.footnote.weight(.semibold))
                    if let disagreeMessage {
                        Text(disagreeMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .font(.footnote)
                .padding(16)
                // v0.2.66: tab-bar clearance for pushed pages.
                .padding(.bottom, ConcordTheme.tabBarClearance)
            }
            _ConsentBar(
                consented: consented,
                consentedDate: consentedAt > 0 ? Date(timeIntervalSince1970: consentedAt) : nil,
                onAgree: {
                    restateTyped = ""
                    showRestateDialog = true
                },
                onDisagree: {
                    consented = false
                    disagreeMessage = "您选择了不同意：请停止使用本应用并将其卸载。"
                }
            )
        }
        .background(ConcordTheme.pageBackground)
        .navigationTitle("免责声明")
        .navigationBarTitleDisplayMode(.inline)
        // Upstream _handleAgree → dialogs.showCommonDialog
        // (dismissible: false, child: _RestateDialog())
        // (disclaimer.dart:305): a centered AlertDialog with
        // Cancel + Confirm — NOT a sheet, NOT scrim-dismissible.
        // Confirm stays disabled until the typed text matches the
        // statement exactly; a non-prefix is flagged as a mismatch.
        .alert("确认同意", isPresented: $showRestateDialog) {
            TextField("请逐字输入声明", text: $restateTyped)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { restateTyped = "" }
            Button("确认") {
                consented = true
                consentedAt = Date().timeIntervalSince1970
                restateTyped = ""
            }
            .disabled(restateTyped.trimmingCharacters(in: .whitespacesAndNewlines) != DisclaimerView.restatement)
        } message: {
            Text("请复述以下声明，以确认您已阅读并同意免责声明：\n\(DisclaimerView.restatement)\(restateMismatch ? "\n输入与声明不一致，请对照上方文字重新输入。" : "")")
        }
    }

    /// The typed restatement matches the statement so far, or
    /// diverges from it (a non-prefix, non-empty input).
    private var restateMismatch: Bool {
        let trimmed = restateTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != DisclaimerView.restatement
            && !DisclaimerView.restatement.hasPrefix(trimmed)
    }
}

/// Consent bar (FlClash _ConsentBar): the bottom bar below the
/// terms. Agree opens the restatement dialog; disagree declines;
/// after agreeing it shows the consent time. Upstream has no
/// withdraw action (v0.2.136: the 撤回同意 button is deleted).
private struct _ConsentBar: View {
    let consented: Bool
    let consentedDate: Date?
    let onAgree: () -> Void
    let onDisagree: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if consented {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已同意免责声明")
                            .font(.footnote.weight(.semibold))
                        if let date = consentedDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
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
