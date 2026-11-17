import SwiftUI

// MARK: - Tools tab
// The pages that used to be tabs (rules, connections, logs, MITM,
// settings) plus the settings sub-pages (DNS queries, providers,
// resources) live here as a grouped list. Each row pushes the
// ORIGINAL page — no functionality was removed or rewritten, only
// the navigation moved.

struct ToolsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    toolSection(title: "监控") {
                        toolLink(icon: "list.bullet.rectangle", tint: .blue,
                                 title: "规则", subtitle: "生效规则与规则提供方") {
                            RulesView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "arrow.left.arrow.right", tint: .green,
                                 title: "连接", subtitle: "实时连接与请求") {
                            ConnectionsView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "doc.text", tint: .orange,
                                 title: "日志", subtitle: "核心日志与事件") {
                            LogsView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "shield.lefthalf.filled", tint: .purple,
                                 title: "MITM 拦截", subtitle: "拦截记录与脚本") {
                            MitmView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "puzzlepiece.extension", tint: .brown,
                                 title: "MITM 模块", subtitle: "Surge / Loon / QX 模块") {
                            MitmModulesView()
                        }
                    }
                    toolSection(title: "更多") {
                        toolLink(icon: "location.circle", tint: .red,
                                 title: "IP 质量", subtitle: "出口 IP 的归属与位置") {
                            IPQualityView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "archivebox", tint: .cyan,
                                 title: "备份与恢复", subtitle: "导出 / 导入全部数据") {
                            BackupView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "command", tint: .mint,
                                 title: "快捷指令", subtitle: "Shortcuts 动作与 URL 动作") {
                            ShortcutsView()
                        }
                    }
                    toolSection(title: "管理") {
                        toolLink(icon: "gear", tint: .gray,
                                 title: "设置", subtitle: "通用、TUN、DNS、MITM") {
                            SettingsView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "magnifyingglass", tint: .teal,
                                 title: "DNS 查询", subtitle: "查询记录与手动查询") {
                            DnsQueriesView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "tray.full", tint: .indigo,
                                 title: "提供方", subtitle: "代理与规则提供方") {
                            ProvidersView()
                        }
                        Divider().padding(.leading, 52)
                        toolLink(icon: "memorychip", tint: .pink,
                                 title: "资源", subtitle: "核心内存与已加载内容") {
                            ResourcesView()
                        }
                    }
                }
                .padding(16)
            }
            .concordPageBackground()
            .navigationTitle("工具")
        }
    }

    private func toolSection<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                rows()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 24))
            .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
        }
    }

    private func toolLink<Destination: View>(icon: String, tint: Color,
                                             title: String, subtitle: String,
                                             @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.label))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
