import SwiftUI

// MARK: - Tools (reference IMG_1111)
//
// The reference Tools page is three plain white cards with grey
// outline icons and 17pt semibold titles — no coloured tiles, no
// subtitles:
//   (no header)  请求 / DNS查询 / 资源
//   设置         语言（值 "默认"）/ 主题 / 备份与恢复 / 进阶配置 / 常规
//   其他         免责声明
// Rows are 56pt tall, section labels 13pt semibold grey, card
// corner radius 24pt. Each row keeps its existing destination;
// the two rows with no existing destination (语言, 免责声明) get
// minimal static pages below — no new features are invented.
//
// NOTE: the old Tools page also linked 规则 / 连接 / 日志 /
// MITM拦截 / MITM模块 / IP质量 / 快捷指令 / 提供方. Those pages
// are NOT on the reference page, so they are not listed here;
// 规则 / 日志 / IP质量 / 快捷指令 are instead reachable from the
// 常规 (Settings) page, and the rest remain linked from there or
// from MITM / Profiles, so no functionality is lost.

struct ToolsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("工具")
                        .font(.system(size: 18, weight: .bold))
                    toolSection(header: nil) {
                        ToolRow(icon: "clock", title: "请求") { ConnectionsView() }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "server.rack", title: "DNS查询") { DnsQueriesView() }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "archivebox", title: "资源") { ResourcesView() }
                    }
                    toolSection(header: "设置") {
                        NavigationLink { LanguageView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 24, height: 24)
                                Text("语言")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text("默认")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(.label))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "paintbrush", title: "主题") { ThemePickerView() }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "arrow.clockwise.icloud", title: "备份与恢复") { BackupView() }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "wrench", title: "进阶配置") { ConfigEditorView() }
                        Divider().padding(.leading, 54)
                        ToolRow(icon: "gear", title: "常规") { SettingsView() }
                    }
                    toolSection(header: "其他") {
                        ToolRow(icon: "gavel", title: "免责声明") { DisclaimerView() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .background(ConcordTheme.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
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

/// One 56pt row: plain grey outline icon, 17pt semibold title,
/// chevron right (16pt vertical padding + 24pt icon frame).
private struct ToolRow<Destination: View>: View {
    let icon: String
    let title: String
    let destination: () -> Destination

    init(icon: String, title: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.icon = icon
        self.title = title
        self.destination = destination
    }

    var body: some View {
        NavigationLink { destination() } label: {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Language (no in-app language setting exists)

/// The app follows the system language; there is no in-app
/// language picker to invent. This page only states the current
/// value ("默认") so the 语言 row has somewhere to go.
private struct LanguageView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("当前语言", value: "默认")
                Text("跟随系统语言显示。应用内没有单独的语言切换。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Disclaimer

/// Short generic disclaimer text (no existing disclaimer view).
private struct DisclaimerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("免责声明")
                    .font(.system(size: 18, weight: .bold))
                Text("本 App 是一个开源代理客户端：核心为 chen08209/concord，界面复刻自 chen08209/FlClash，均以 GPL-3.0 开源。")
                Text("请遵守所在国家和地区的法律法规，合理、合法使用本 App；因使用本 App 产生的任何后果由使用者自行承担。")
                Text("MITM 抓包会解密 HTTPS 流量，仅可在自己拥有或已获授权的设备与流量上使用；抓包前需在系统设置中手动安装并信任自签 CA 证书。")
            }
            .font(.system(size: 13))
            .padding(16)
        }
        .background(ConcordTheme.pageBackground)
        .navigationTitle("免责声明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
