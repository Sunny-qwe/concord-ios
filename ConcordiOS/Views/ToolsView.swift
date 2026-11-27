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
                        // T-D1 (v0.2.138): inline language row —
                        // upstream tools.dart:148-175
                        // ListItem<Locale?>.options. A Menu picker:
                        // picking a language switches the app's
                        // localised strings immediately (no restart,
                        // no separate page); only the ~50 .l10n keys
                        // switch, the rest of the app stays Chinese.
                        HStack(spacing: 14) {
                            Image(systemName: "character.bubble")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(Color(.label))
                                .frame(width: 24, height: 24)
                            Text("tools.language".l10n)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(.label))
                            Spacer()
                            Picker("", selection: $localization.language) {
                                ForEach(LocalizationManager.supportedLanguages, id: \.code) { language in
                                    Text(language.name).tag(language.code)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .font(.footnote)
                            .tint(Color(.label))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
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
    static var restatement: String { "disclaimer.restatement".l10n }

    @AppStorage("ConcordiOS.disclaimer.consented") private var consented = false
    @AppStorage("ConcordiOS.disclaimer.consentedAt") private var consentedAt: Double = 0
    @Environment(\.dismiss) private var dismiss
    @State private var showRestateDialog = false
    @State private var restateTyped = ""
    @State private var disagreeMessage: String?
    private static var terms: [(String, String)] {
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
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("tools.disclaimer".l10n)
                        .font(.system(size: 18, weight: .bold))
                    Text("disclaimer.intro".l10n)
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
                    disagreeMessage = "disclaimer.disagree.message".l10n
                }
            )
        }
        .background(ConcordTheme.pageBackground)
        .navigationTitle("tools.disclaimer".l10n)
        .navigationBarTitleDisplayMode(.inline)
        // Upstream _handleAgree → dialogs.showCommonDialog
        // (dismissible: false, child: _RestateDialog())
        // (disclaimer.dart:305): a centered AlertDialog with
        // Cancel + Confirm — NOT a sheet, NOT scrim-dismissible.
        // Confirm stays disabled until the typed text matches the
        // statement exactly; a non-prefix is flagged as a mismatch.
        .alert("disclaimer.confirm.title".l10n, isPresented: $showRestateDialog) {
            TextField("disclaimer.retype.placeholder".l10n, text: $restateTyped)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.cancel".l10n, role: .cancel) { restateTyped = "" }
            Button("common.confirm".l10n) {
                consented = true
                consentedAt = Date().timeIntervalSince1970
                restateTyped = ""
            }
            .disabled(restateTyped.trimmingCharacters(in: .whitespacesAndNewlines) != DisclaimerView.restatement)
        } message: {
            Text("\("disclaimer.retype.prompt".l10n)\n\(DisclaimerView.restatement)\(restateMismatch ? "\n\("disclaimer.retype.mismatch".l10n)" : "")")
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
                        Text("disclaimer.agreed".l10n)
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
                    Button("disclaimer.disagree".l10n, action: onDisagree)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button("disclaimer.agree".l10n, action: onAgree)
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
