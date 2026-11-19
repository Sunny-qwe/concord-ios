import SwiftUI

// MARK: - Theme picker (Settings -> 主题)
// Appearance (follow system / light / dark) + accent colour, from
// ThemeStore. The preview card below the pickers is a live miniature
// of the app's own design language, so the change is visible before
// leaving the page. Changing either control saves immediately
// (ThemeStore.save) and the app root re-renders with the new scheme
// and tint.

struct ThemePickerView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    /// The preview toggle is a live miniature, not a real switch:
    /// it used to be bound to `.constant(true)`, so tapping it did
    /// nothing and looked dead. It now flips local state.
    @State private var previewVpnOn = true

    var body: some View {
        List {
            Section("外观") {
                ForEach(ThemeAppearance.allCases) { appearance in
                    Button {
                        themeStore.appearance = appearance
                        themeStore.save()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: appearance.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(themeStore.appearance == appearance ? themeStore.accentColor : .secondary)
                                .frame(width: 28)
                            Text(appearance.label)
                                .foregroundStyle(Color(.label))
                            Spacer()
                            if themeStore.appearance == appearance {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(themeStore.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("「跟随系统」时 App 跟随 iPhone 的深色 / 浅色设置自动切换。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("主题色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(ThemeAccent.allCases) { accent in
                        Button {
                            themeStore.accent = accent
                            themeStore.save()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(accent.color)
                                        .frame(width: 44, height: 44)
                                    if themeStore.accent == accent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .semibold))
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(accent.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(themeStore.accent == accent ? Color(.label) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                Text("主题色会用在按钮、开关、选中状态和进度条上。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("预览") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        BlobIcon(systemName: "globe", iconColor: .white, blobColor: themeStore.accentColor, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("仪表盘")
                                .font(.system(size: 12, weight: .semibold))
                            Text("这就是换主题后的样子")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PillBadge(text: "运行中", tint: .green)
                    }
                    CapsuleProgressBar(fraction: 0.62)
                    HStack(spacing: 8) {
                        ForEach(["规则", "全局", "直连"], id: \.self) { mode in
                            Text(mode)
                                .font(.system(size: 13))
                                .fontWeight(.semibold)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(mode == "规则" ? themeStore.accentColor : ConcordTheme.softFill, in: Capsule())
                                .foregroundStyle(mode == "规则" ? .white : Color(.label))
                        }
                    }
                    Toggle("VPN 开关", isOn: $previewVpnOn)
                        .tint(themeStore.accentColor)
                }
                .concordCard()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .navigationTitle("主题")
    }
}
