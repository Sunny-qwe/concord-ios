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
// 语言 is a real picker (AppStorage + AppleLanguages, restart to
// apply) and 免责声明 is a static text page.
//
// NOTE: the old Tools page also linked 规则 / 连接 / 日志 /
// MITM拦截 / MITM模块 / IP质量 / 快捷指令 / 提供方. Those pages
// are NOT on the reference page, so they are not listed here;
// 规则 / 日志 / IP质量 / 快捷指令 are instead reachable from the
// 常规 (Settings) page, and the rest remain linked from there or
// from MITM / Profiles, so no functionality is lost.

struct ToolsView: View {
    @AppStorage("ConcordiOS.appLanguage") private var appLanguage = ""

    private var languageDisplayName: String {
        switch appLanguage {
        case "zh-Hans": return "简体中文"
        case "en": return "English"
        default: return "默认"
        }
    }

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
                                Text(languageDisplayName)
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

// MARK: - Language (real picker)

/// In-app language picker. The choice is persisted and applied via
/// the standard AppleLanguages mechanism, which iOS reads at launch,
/// so a restart is required before it takes effect. Honest limit:
/// the app's own strings are hardcoded Chinese, so only system UI
/// (dates, system controls) follows the choice until the strings
/// are localised.
private struct LanguageView: View {
    @AppStorage("ConcordiOS.appLanguage") private var appLanguage = ""
    @State private var showRestartAlert = false

    private var displayName: String {
        switch appLanguage {
        case "zh-Hans": return "简体中文"
        case "en": return "English"
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
                }
                .pickerStyle(.inline)
            } footer: {
                Text("切换语言后需要重启应用才会生效。当前应用内文字为中文硬编码，切换后仅系统界面（如日期、系统控件）会跟随语言，应用内文字暂不变。")
            }
        }
        .scrollContentBackground(.hidden)
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
            Button("知道了", role: .cancel) {}
        } message: {
            Text("语言已设为\(displayName)，重启应用后生效。")
        }
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
