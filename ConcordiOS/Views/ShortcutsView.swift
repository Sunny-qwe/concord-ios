import SwiftUI
import UIKit

// MARK: - Shortcuts (Tools -> 快捷指令)
// Explains the four AppIntents the app exposes to the Shortcuts app
// (see ConcordIntents.swift) and the concord:// URL actions, which
// are the fallback when an intent cannot act without the app
// running: any Shortcuts "Open URL" action with one of these URLs
// opens Concord and performs the action. Tapping a URL row copies
// it, so it can be pasted into a shortcut.
//
// v0.2.159: upstream has NO counterpart (iOS Shortcuts / URL-scheme
// feature), so there is no upstream layout to match — the page is
// kept whole and restyled to the shared Tools atoms. The 40pt
// accent tiles stay: they are the actions' icons (as in the iOS
// Shortcuts app), not upstream-style leading glyphs.

struct ShortcutsView: View {
    @State private var copiedURL: String?

    private let urlActions: [(url: String, title: String, subtitle: String)] = [
        ("concord://vpn/on", "开启 VPN", "启动 VPN 隧道"),
        ("concord://vpn/off", "关闭 VPN", "停止 VPN 隧道"),
        ("concord://vpn/toggle", "切换 VPN 开关", "开着就关闭，关着就开启"),
        ("concord://mode/rule", "规则模式", "把出站模式设为规则"),
        ("concord://mode/global", "全局模式", "把出站模式设为全局"),
        ("concord://mode/direct", "直连模式", "把出站模式设为直连"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: "快捷指令动作") {
                    Text("在 iPhone「快捷指令」App 里搜索 Lumen，就能找到这 4 个动作；也可以把它们放到小组件、自动化或操作按钮上。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    shortcutRow(icon: "power", title: "开启 VPN", subtitle: "启动 VPN 隧道")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 72)
                    shortcutRow(icon: "power.circle", title: "关闭 VPN", subtitle: "停止 VPN 隧道")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 72)
                    shortcutRow(icon: "repeat", title: "切换 VPN 开关", subtitle: "开着就关闭，关着就开启")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 72)
                    shortcutRow(icon: "arrow.triangle.2.circlepath", title: "切换出站模式", subtitle: "规则 / 全局 / 直连，选一个")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                UpstreamCardSection(header: "说明") {
                    Text("快捷指令尽量在后台直接操作：开关 VPN 走系统 VPN 配置，切换模式先保存、VPN 运行时再实时应用到核心。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    Text("如果某次操作在后台做不了（比如系统不让快捷指令直接碰 VPN 配置），这次操作会失败并在结果里写明原因——这时可以用下面的 URL 动作代替：用快捷指令里的「打开 URL」打开对应链接，App 打开后就会执行。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                UpstreamCardSection(header: "URL 动作（备用）") {
                    Text("点一行复制链接，粘贴到快捷指令的「打开 URL」动作里。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    ForEach(Array(urlActions.enumerated()), id: \.element.url) { _, action in
                        UpstreamDivider(leading: 16)
                        Button {
                            UIPasteboard.general.string = action.url
                            copiedURL = action.url
                        } label: {
                            HStack(spacing: 16) {
                                UpstreamRowIcon(systemName: "link")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(.body)
                                        .foregroundStyle(Color(.label))
                                    Text(action.url)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                }
                                Spacer()
                                if copiedURL == action.url {
                                    Text("已复制")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                        .font(.footnote)
                                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 56)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "快捷指令")
    }

    private func shortcutRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ConcordTheme.accent, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 56)
    }
}
