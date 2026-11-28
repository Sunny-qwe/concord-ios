import SwiftUI

// MARK: - Tools (reference IMG_1111)
//
// The reference Tools page is three plain white cards with grey
// outline icons and 17pt semibold titles — no coloured tiles, no
// subtitles:
//   (no header)  请求 / 资源 / 日志（v0.2.68 起仅当
//                常规 -> 日志捕获 开启时显示，见 SettingsStore.openLogs；
//                v0.2.40–v0.2.67 曾始终显示，因用户找不到日志入口——
//                恢复开关后默认关闭会再次隐藏入口，见 ToolsView 日志行注释）
//                DNS查询不是独立入口：上游没有独立的 DNS 页，DNS 是
//                请求页的一个分段（v0.2.146, 见 ConnectionsView）。
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
    case resources
    case logs
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
    // T-D1 (v0.2.138): the language picker is an inline Menu row
    // in the Settings section below, bound to this manager — the
    // pushed LanguageView page and its restart requirement are
    // gone (upstream tools.dart:148-175 ListItem.options).
    @EnvironmentObject private var localization: LocalizationManager
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

    /// The language picker's displayed value (v0.2.158): the menu
    /// Picker's label is explicit (see below) and reads the live
    /// selection, so it updates when the user picks a language.
    private var currentLanguageName: String {
        LocalizationManager.supportedLanguages.first(where: { $0.code == localization.language })?.name ?? ""
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                    // FlClash pageTitle is 24pt semibold on a tab
                    // page (scaffold.dart:780).
                    Text("tools.title".l10n)
                        .font(.system(size: 24, weight: .semibold))
                    UpstreamCardSection(header: nil) {
                        UpstreamNavRow(icon: "clock", title: "tools.requests".l10n) { navPath.append(.requests) }
                        UpstreamDivider()
                        UpstreamNavRow(icon: "archivebox", title: "tools.resources".l10n) { navPath.append(.resources) }
                        // v0.2.68 (MuYu): the Logs row shows only
                        // when 常规 → 日志捕获 is on (restored
                        // toggle, SettingsStore.openLogs). NOTE: the
                        // stored default is off, so a fresh install
                        // hides the Logs row until the user turns
                        // 日志捕获 on in 常规.
                        if settingsStore.openLogs {
                            UpstreamDivider()
                            UpstreamNavRow(icon: "terminal", title: "tools.logs".l10n) { navPath.append(.logs) }
                        }
                    }
                    UpstreamCardSection(header: "tools.section.settings".l10n) {
                        // T-D1 (v0.2.138): inline language row —
                        // upstream tools.dart:148-175
                        // ListItem<Locale?>.options. A Menu picker:
                        // picking a language switches the app's
                        // localised strings immediately (no restart,
                        // no separate page); only the ~50 .l10n keys
                        // switch, the rest of the app stays Chinese.
                        HStack(spacing: 16) {
                            UpstreamRowIcon(systemName: "character.bubble")
                            Text("tools.language".l10n)
                                .font(.body)
                                .foregroundStyle(Color(.label))
                            Spacer()
                            // v0.2.158: the menu Picker's synthesised
                            // value label ignores .font() — measured
                            // on IMG_1402, the value glyphs are 43px
                            // tall vs 33px for the 13pt row titles,
                            // i.e. it renders at the 17pt default,
                            // not the .footnote on the Picker. An
                            // explicit label forces the upstream
                            // _OptionsValueButton style: 17pt regular
                            // in onSurfaceVariant grey, with the
                            // picker glyph after it.
                            Picker(selection: $localization.language) {
                                ForEach(LocalizationManager.supportedLanguages, id: \.code) { language in
                                    Text(language.name).tag(language.code)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(currentLanguageName)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .font(.body)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            }
                            .pickerStyle(.menu)
                            .tint(ConcordTheme.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                        UpstreamDivider()
                        UpstreamNavRow(icon: "paintbrush", title: "tools.theme".l10n) { navPath.append(.theme) }
                        UpstreamDivider()
                        UpstreamNavRow(icon: "arrow.clockwise.icloud", title: "tools.backup".l10n) { navPath.append(.backup) }
                        UpstreamDivider()
                        UpstreamNavRow(icon: "wrench", title: "tools.advanced".l10n) { navPath.append(.config) }
                        UpstreamDivider()
                        UpstreamNavRow(icon: "gear", title: "tools.settings".l10n) { navPath.append(.settings) }
                    }
                    UpstreamCardSection(header: "tools.section.other".l10n) {
                        // v0.2.68 (MuYu): the disclaimer icon is a
                        // gavel, not doc.text (which also collided
                        // with the Logs icon). GavelIcon lives in
                        // Views/CustomGlyphs.swift (shared with the
                        // Connections page).
                        ToolGlyphRow(title: "tools.disclaimer".l10n, icon: { GavelIcon(size: 18, color: ConcordTheme.onSurfaceVariant) }) { navPath.append(.disclaimer) }
                        if settingsStore.developerMode {
                            UpstreamDivider()
                            UpstreamNavRow(icon: "hammer", title: "tools.developer".l10n) { navPath.append(.developer) }
                        }
                        UpstreamDivider()
                        UpstreamNavRow(icon: "info.circle", title: "tools.about".l10n) { navPath.append(.about) }
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
                case .resources: ResourcesView()
                case .logs: LogsView()
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
}

/// A row whose icon is a custom-drawn glyph view instead of an
/// SF Symbol (v0.2.68: the disclaimer gavel, GavelIcon from
/// CustomGlyphs.swift). Same 56pt upstream geometry as UpstreamNavRow.
private struct ToolGlyphRow<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                icon()
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Spacer()
                UpstreamChevron()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Disclaimer
//
// FlClash's disclaimer (lib/views/disclaimer.dart), mobile branch:
// no in-content title (the title2 heading is desktop-only), the
// intro in a raised card with a 28pt accent gavel, and 10 numbered
// terms — 28pt circle badge + 17pt semibold title, 15pt grey
// paragraphs at 1.6 line height. Opened from Tools there is no
// consent bar (disclaimer.dart:85-87); this app has no first-launch
// consent gate, so the agree/disagree bar and its retype dialog are
// gone in v0.2.159.
private struct DisclaimerView: View {
    private static var terms: [(String, String)] {
        [
        ("disclaimer.terms.nature.title".l10n, "disclaimer.terms.nature.body".l10n),
        ("disclaimer.terms.usage.title".l10n, "disclaimer.terms.usage.body".l10n),
        ("disclaimer.terms.responsibility.title".l10n, "disclaimer.terms.responsibility.body".l10n),
        ("disclaimer.terms.thirdparty.title".l10n, "disclaimer.terms.thirdparty.body".l10n),
        ("disclaimer.terms.nowarranty.title".l10n, "disclaimer.terms.nowarranty.body".l10n),
        ("disclaimer.terms.liability.title".l10n, "disclaimer.terms.liability.body".l10n),
        ("disclaimer.terms.privacy.title".l10n, "disclaimer.terms.privacy.body".l10n),
        ("disclaimer.terms.license.title".l10n, "disclaimer.terms.license.body".l10n),
        ("disclaimer.terms.changes.title".l10n, "disclaimer.terms.changes.body".l10n),
        ("disclaimer.terms.relation.title".l10n, "disclaimer.terms.relation.body".l10n),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    GavelIcon(size: 28, color: ConcordTheme.accent)
                        .frame(width: 28, height: 28)
                    Text("disclaimer.intro".l10n)
                        .font(.subheadline)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .lineSpacing(4)
                }
                .padding(20)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                ForEach(Array(DisclaimerView.terms.enumerated()), id: \.offset) { index, term in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .frame(width: 28, height: 28)
                                .background(ConcordTheme.cardBackground, in: Circle())
                            Text(term.0)
                                .font(.headline)
                                .foregroundStyle(Color(.label))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(term.1.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.subheadline)
                                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                    .lineSpacing(4)
                            }
                        }
                    }
                    .padding(.top, 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "tools.disclaimer".l10n)
    }
}