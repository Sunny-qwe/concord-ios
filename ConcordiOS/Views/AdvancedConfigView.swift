import SwiftUI

// MARK: - Advanced config hub (FlClash: Tools -> 进阶配置)
// A hub of the advanced pages. 脚本 is NOT here: concord has no
// script-loading API (only MITM scripts, which live under MITM
// 模块）, so there is nothing real to put behind that row.

struct AdvancedConfigView: View {
    /// Navigate through the Tools page's single NavigationStack —
    /// no nested stacks.
    let navigate: (ToolsDestination) -> Void

    var body: some View {
        List {
            Section("进阶配置") {
                advancedRow(icon: "network", title: "网络", subtitle: "TUN、MTU、DNS、IPv6、路由", destination: .advancedNetwork)
                advancedRow(icon: "globe", title: "DNS", subtitle: "上游 DNS、Fake-IP", destination: .advancedDns)
                advancedRow(icon: "list.bullet", title: "附加规则", subtitle: "排在订阅规则之前的自定义规则", destination: .advancedRules)
                advancedRow(icon: "server.rack", title: "代理", subtitle: "自定义节点", destination: .advancedProxies)
                advancedRow(icon: "square.stack.3d.up", title: "规则提供方", subtitle: "远程规则集与本地规则", destination: .advancedProviders)
                advancedRow(icon: "line.3.horizontal.decrease.circle", title: "过滤器", subtitle: "代理组节点过滤", destination: .advancedFilters)
                advancedRow(icon: "photo.on.rectangle.angled", title: "图标集", subtitle: "代理组与节点的图标", destination: .iconSets)
                advancedRow(icon: "doc.text", title: "编辑配置 (YAML)", subtitle: "直接编辑当前配置文本", destination: .configEditor)
            }
            Section {
                Text("脚本：上游 FlClash 有这个入口，但 concord 核心没有加载 Clash 脚本的接口，无法实现——不在此列出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("进阶配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func advancedRow(icon: String, title: String, subtitle: String, destination: ToolsDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(ConcordTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
