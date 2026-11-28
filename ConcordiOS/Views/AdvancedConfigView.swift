import SwiftUI

// MARK: - Advanced config hub (FlClash: Tools -> 进阶配置)
// Upstream advanced.dart, v0.2.159: THREE cards, no per-row
// subtitles except the MITM counts:
//   [网络 / DNS / 附加规则 / 脚本]            (no header)
//   自定义 [代理 / 规则集 / 筛选 / 图标集]
//   MITM [HTTPS 解密 toggle / 模块 / 主机名 / 选项]
// 模块 / 主机名 show "无" as the SUBTITLE when empty (upstream
// mitm_modules.dart:182 / mitm.dart:600), "N 项" as the subtitle
// otherwise; 主机名 shows "N 条中 M 条无效" when some are invalid
// (mitm.dart:600-604). There is NO "编辑配置 (YAML)" row upstream —
// the editor opens from profile edit/preview, provider and script
// edit (profiles/edit.dart:215 etc.), which our app already has —
// so the row is gone from this page (v0.2.159).

struct AdvancedConfigView: View {
    /// Navigate through the Tools page's single NavigationStack —
    /// no nested stacks. Used for the rows whose destinations are
    /// ToolsDestination cases; the MITM rows navigate directly
    /// with NavigationLink (same stack).
    let navigate: (ToolsDestination) -> Void

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var moduleStore: MitmModuleStore

    private var moduleSubtitle: String {
        moduleStore.modules.isEmpty ? "无" : "\(moduleStore.modules.count) 项"
    }

    private var hostnameSubtitle: String {
        let names = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if names.isEmpty { return "无" }
        let invalid = names.filter { !MitmHostnameEditorView.isValidHostname($0) }.count
        if invalid > 0 { return "\(names.count) 条中 \(invalid) 条无效" }
        return "\(names.count) 项"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: nil) {
                    UpstreamNavRow(icon: "key", title: "网络") { navigate(.advancedNetwork) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "server.rack", title: "DNS") { navigate(.advancedDns) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "list.bullet.rectangle", title: "附加规则") { navigate(.advancedRules) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "chevron.left.forwardslash.chevron.right", title: "脚本") { navigate(.advancedScripts) }
                }
                UpstreamCardSection(header: "自定义") {
                    UpstreamNavRow(icon: "globe", title: "代理") { navigate(.advancedProxies) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "archivebox", title: "规则集") { navigate(.advancedProviders) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "line.3.horizontal.decrease", title: "筛选") { navigate(.advancedFilters) }
                    UpstreamDivider()
                    UpstreamNavRow(icon: "photo.on.rectangle.angled", title: "图标集") { navigate(.iconSets) }
                }
                UpstreamCardSection(header: "MITM") {
                    HStack(spacing: 16) {
                        UpstreamRowIcon(systemName: "lock.open")
                        // FlClash MitmEnableItem (mitm.dart:538-581):
                        // enabling asks for confirmation and
                        // auto-generates a CA when none exists — the
                        // shared toggle, same as the certificate page.
                        MitmEnableToggle()
                            .disabled(!settingsStore.mitmAvailable)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    UpstreamDivider()
                    NavigationLink {
                        MitmModulesView().concordNavBarBackground()
                    } label: {
                        UpstreamNavRowContent(icon: "puzzlepiece", title: "模块", subtitle: moduleSubtitle)
                    }
                    .buttonStyle(.plain)
                    UpstreamDivider()
                    NavigationLink {
                        MitmHostnameEditorView().concordNavBarBackground()
                    } label: {
                        UpstreamNavRowContent(icon: "scope", title: "主机名", subtitle: hostnameSubtitle)
                    }
                    .buttonStyle(.plain)
                    UpstreamDivider()
                    NavigationLink {
                        MitmOptionsView().concordNavBarBackground()
                    } label: {
                        UpstreamNavRowContent(icon: "slider.horizontal.3", title: "选项")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            // 40pt below the 44pt system bar lands the first card
            // where upstream's 72pt bar + 12pt puts it (IMG_1406:
            // first card top 131pt).
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.pushedPageClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "进阶配置")
    }
}
