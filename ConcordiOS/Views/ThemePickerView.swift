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
    @Environment(\.dismiss) private var dismiss
    /// The preview toggle is a live miniature, not a real switch:
    /// it used to be bound to `.constant(true)`, so tapping it did
    /// nothing and looked dead. It now flips local state.
    @State private var previewVpnOn = true
    @State private var newCustomColor = Color.blue
    @State private var customColorMessage: String?
    @State private var showResetConfirm = false

    /// FlClash defaultPrimaryColors (common/constant.dart:196-205)
    /// not covered by the 5 ThemeAccent presets: pink, red, yellow.
    /// They are applied as a custom hex (ThemeStore's accent enum
    /// is owned by the store file), bringing the preset total to 8.
    private static let extraPresets: [(label: String, hex: String)] = [
        ("粉色", "#FF2D55"),
        ("红色", "#FF383C"),
        ("黄色", "#FFCC00"),
    ]

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
                Toggle("纯黑模式", isOn: $themeStore.pureBlack)
                    .onChange(of: themeStore.pureBlack) { _, _ in themeStore.save() }
                Text("「跟随系统」时 App 跟随 iPhone 的深色 / 浅色设置自动切换。纯黑模式只在深色下生效：页面背景变纯黑，卡片变深灰。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("主题色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(ThemeAccent.allCases) { accent in
                        Button {
                            themeStore.accent = accent
                            themeStore.customAccentHex = nil
                            themeStore.save()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(accent.color)
                                        .frame(width: 44, height: 44)
                                    if themeStore.customAccentHex == nil && themeStore.accent == accent {
                                        Image(systemName: "checkmark")
                                            .font(.callout.weight(.semibold))
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(accent.label)
                                    .font(.caption2)
                                    .foregroundStyle(themeStore.customAccentHex == nil && themeStore.accent == accent ? Color(.label) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(Self.extraPresets, id: \.hex) { preset in
                        Button {
                            themeStore.customAccentHex = preset.hex
                            themeStore.save()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: preset.hex) ?? .gray)
                                        .frame(width: 44, height: 44)
                                    if themeStore.customAccentHex == preset.hex {
                                        Image(systemName: "checkmark")
                                            .font(.callout.weight(.semibold))
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(preset.label)
                                    .font(.caption2)
                                    .foregroundStyle(themeStore.customAccentHex == preset.hex ? Color(.label) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                if !themeStore.customColors.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        ForEach(themeStore.customColors, id: \.self) { hex in
                            Button {
                                themeStore.customAccentHex = hex
                                themeStore.save()
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: hex) ?? .gray)
                                            .frame(width: 44, height: 44)
                                        if themeStore.customAccentHex == hex {
                                            Image(systemName: "checkmark")
                                                .font(.callout.weight(.semibold))
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    Text(hex)
                                        .font(.system(size: 9))
                                        .foregroundStyle(themeStore.customAccentHex == hex ? Color(.label) : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    themeStore.customColors.removeAll { $0 == hex }
                                    if themeStore.customAccentHex == hex {
                                        themeStore.customAccentHex = nil
                                    }
                                    themeStore.save()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    ColorPicker("自定义颜色", selection: $newCustomColor)
                    Button("添加") {
                        guard let hex = Self.hexString(of: newCustomColor) else { return }
                        if themeStore.customColors.contains(hex) {
                            customColorMessage = "这个颜色已经加过了"
                            return
                        }
                        themeStore.customColors.append(hex)
                        themeStore.customAccentHex = hex
                        themeStore.save()
                        customColorMessage = nil
                    }
                }
                if let customColorMessage {
                    Text(customColorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("主题色会用在按钮、开关、选中状态和进度条上。长按自定义颜色可删除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // FlClash theme.dart:109-135 _PrimaryColorItem reset:
                // confirm, then back to the default blue + vivid
                // style (and the preset list back to the defaults,
                // which here means clearing user-added swatches).
                Button("恢复默认颜色", role: .destructive) {
                    showResetConfirm = true
                }
                .alert("恢复默认颜色吗？", isPresented: $showResetConfirm) {
                    Button("恢复默认", role: .destructive) {
                        themeStore.accent = .blue
                        themeStore.customAccentHex = nil
                        themeStore.customColors = []
                        themeStore.colorStyle = .vivid
                        themeStore.save()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("主题色会回到默认蓝色，颜色风格回到生动，自己添加的颜色也会清空。")
                }
            }

            Section("颜色风格") {
                Picker("颜色风格", selection: $themeStore.colorStyle) {
                    ForEach(ThemeColorStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeStore.colorStyle) { _, _ in themeStore.save() }
                Text("生动：原样；柔和：降低饱和度；单色：灰色主题色。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("导航栏") {
                Picker("导航栏样式", selection: $themeStore.navBarStyle) {
                    ForEach(ThemeNavBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeStore.navBarStyle) { _, _ in themeStore.save() }
                Text("悬浮：底部悬浮胶囊栏；停靠：系统自带底部标签栏。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("文字大小") {
                Toggle("自定义文字大小", isOn: $themeStore.textScaleEnabled)
                    .onChange(of: themeStore.textScaleEnabled) { _, _ in themeStore.save() }
                if themeStore.textScaleEnabled {
                    HStack {
                        Text("小")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $themeStore.textScale, in: 0.8...1.3, step: 0.1)
                            .onChange(of: themeStore.textScale) { _, _ in themeStore.save() }
                        Text("大")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("当前 \(Int(themeStore.textScale * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("字体") {
                NavigationLink("settings.font".l10n) {
                    FontPickerView()
                }
                Text("系统默认字体，或已安装的任意字体。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("预览") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        BlobIcon(systemName: "globe", iconColor: .white, blobColor: themeStore.accentColor, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("仪表盘")
                                .font(.caption.weight(.semibold))
                            Text("这就是换主题后的样子")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PillBadge(text: "运行中", tint: .green)
                    }
                    CapsuleProgressBar(fraction: 0.62)
                    HStack(spacing: 8) {
                        ForEach(["规则", "全局", "直连"], id: \.self) { mode in
                            Text(mode)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(mode == "规则" ? themeStore.accentColor : ConcordTheme.softFill, in: Capsule())
                                .foregroundStyle(mode == "规则" ? .white : Color(.label))
                        }
                    }
                    // NAGRAM-style VPN row (v0.2.46 ITEM 2): the
                    // preview depicts the running state (its header
                    // pill says 运行中), so it shows the blue shield
                    // + "已连接" + an ON toggle. The toggle stays
                    // decorative — bound to local $previewVpnOn
                    // only, never wired to start/stop the VPN.
                    // (VpnGlyphIcon is file-private to
                    // DashboardView, so the preview uses the SF
                    // shield.fill glyph: white shield on the same
                    // blue flower badge.)
                    HStack(spacing: 12) {
                        ZStack {
                            FlowerBadgeShape()
                                .fill(Color.blue)
                                .frame(width: 40, height: 40)
                            Image(systemName: "shield.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VPN")
                                .font(.system(size: 14, weight: .semibold))
                            Text("已连接")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $previewVpnOn)
                            .labelsHidden()
                            .tint(.blue)
                    }
                }
                .concordCard()
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
    }

    /// "#RRGGBB" for a picked colour.
    static func hexString(of color: Color) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}
