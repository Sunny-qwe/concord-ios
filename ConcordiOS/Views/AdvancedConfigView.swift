import SwiftUI

// MARK: - Advanced config hub (FlClash: Tools -> 进阶配置)
// v0.2.68 (MuYu): THREE cards, no per-row subtitles (except the
// 模块 / 主机名 "N 项" counts):
//   [网络 / DNS / 附加规则 / 脚本]
//   自定义 [代理 / 规则集 / 筛选 / 图标集]
//   MITM [HTTPS 解密 toggle / 模块 "N 项" / 主机名 "N 项" / 选项]
// Labels follow the video: 规则集 (not 规则提供方）, 筛选 (not
// 过滤器）. Icons follow the video's glyphs (see advancedRow
// call sites).
//
// 脚本 is a real row that opens the Scripts page (FlClash:
// views/config/scripts.dart) — the standalone script library
// (list / import / edit / sync / delete), stored as registry
// + `<id>.js` files. A script is a `main(config)` transform
// used by profile 扩展脚本模式.
//
// 编辑配置 (YAML) is KEPT: the Advanced row edits the current
// (merged) config text via ConfigEditorView(), and the only other
// YAML editor (Profiles → edit → file row) edits one profile's
// own file — a different target. So this row is the only entry
// point for the current config text.

struct AdvancedConfigView: View {
    /// Navigate through the Tools page's single NavigationStack —
    /// no nested stacks. Used for the rows whose destinations are
    /// ToolsDestination cases; the MITM rows navigate directly
    /// with NavigationLink (same stack).
    let navigate: (ToolsDestination) -> Void

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var moduleStore: MitmModuleStore

    private var moduleCountText: String { "\(moduleStore.modules.count) 项" }

    private var hostnameCountText: String {
        let count = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.count
        return "\(count) 项"
    }

    var body: some View {
        List {
            Section {
                advancedRow(icon: "key", title: "网络", destination: .advancedNetwork)
                advancedRow(icon: "server.rack", title: "DNS", destination: .advancedDns)
                advancedRow(icon: "list.bullet.rectangle", title: "附加规则", destination: .advancedRules)
                advancedRow(icon: "chevron.left.forwardslash.chevron.right", title: "脚本", destination: .advancedScripts)
            }
            Section("自定义") {
                advancedRow(icon: "globe", title: "代理", destination: .advancedProxies)
                advancedRow(icon: "archivebox", title: "规则集", destination: .advancedProviders)
                advancedRow(icon: "line.3.horizontal.decrease", title: "筛选", destination: .advancedFilters)
                advancedRow(icon: "photo.on.rectangle.angled", title: "图标集", destination: .iconSets)
                advancedRow(icon: "doc.text", title: "编辑配置 (YAML)", destination: .configEditor)
            }
            Section("MITM") {
                HStack(spacing: 12) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(ConcordTheme.accent)
                        .frame(width: 24)
                    Toggle("HTTPS 解密", isOn: $settingsStore.mitmEnabled)
                        .disabled(!settingsStore.mitmAvailable)
                        .onChange(of: settingsStore.mitmEnabled) { _, _ in settingsStore.save() }
                }
                NavigationLink {
                    MitmModulesView().concordNavBarBackground()
                } label: {
                    mitmRow(icon: "puzzlepiece", title: "模块", value: moduleCountText)
                }
                NavigationLink {
                    MitmHostnameEditorView().concordNavBarBackground()
                } label: {
                    mitmRow(icon: "scope", title: "主机名", value: hostnameCountText)
                }
                NavigationLink {
                    MitmOptionsView().concordNavBarBackground()
                } label: {
                    mitmRow(icon: "slider.horizontal.3", title: "选项", value: nil)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("进阶配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func advancedRow(icon: String, title: String, destination: ToolsDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(ConcordTheme.accent)
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// One MITM-card row: glyph + title + optional "N 项" value.
    private func mitmRow(icon: String, title: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(ConcordTheme.accent)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(Color(.label))
            Spacer()
            if let value {
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
