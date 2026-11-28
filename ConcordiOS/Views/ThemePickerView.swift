import SwiftUI

// MARK: - Theme picker (Settings -> 主题)
// Appearance (follow system / light / dark) + accent colour, from
// ThemeStore. The preview card at the top is a live miniature of
// the app's own design language (FlClash puts its live preview
// first too), so the change is visible before leaving the page.
// Changing either control saves immediately (ThemeStore.save) and
// the app root re-renders with the new scheme and tint.
//
// v0.2.159: sections, order and wording follow upstream theme.dart
// (live preview / 主题模式 / 纯黑模式 choice group / 主题色彩 /
// 配色风格 / 底栏 / 选项卡动画 / 液态玻璃 / 字体 / 文本缩放).
// Kept, restyled only: the teal + magenta presets, the inline
// 自定义颜色 picker, and the pure-black option (now a 标准/纯黑
// choice group, as upstream). The reset is a header icon, shown
// only when the colour is non-default, as upstream. No auto
// (follow-system) swatch: ThemeStore has no auto-accent concept
// to bind it to — flagged for the coordinator.

struct ThemePickerView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var fontStore: FontStore
    @State private var newCustomColor = Color.blue
    @State private var customColorMessage: String?
    @State private var showResetConfirm = false
    /// The custom colour awaiting delete confirmation (upstream
    /// _handleDelete asks first; the old long-press menu deleted
    /// with no confirm).
    @State private var deletingCustomColor: String?

    /// FlClash defaultPrimaryColors (common/constant.dart:196-205)
    /// not covered by the 6 ThemeAccent presets: pink, red, yellow,
    /// grey. They are applied as a custom hex (ThemeStore's accent
    /// enum is owned by the store file), bringing the preset total
    /// to 10 — upstream's 8 plus the teal preset this app already
    /// shipped (kept, not removed) plus the magenta preset (#B86CA2,
    /// the video's rendered primary) added in v0.2.68.
    private static let extraPresets: [(label: String, hex: String)] = [
        ("粉色", "#FF2D55"),
        ("红色", "#FF383C"),
        ("黄色", "#FFCC00"),
        ("灰色", "#8E8E93"),
    ]

    /// True when the colour differs from upstream's default (blue
    /// + vivid style, no custom colours): the header reset icon in
    /// the 主题色彩 section only shows then.
    private var isNonDefaultColor: Bool {
        themeStore.accent != .blue
            || themeStore.customAccentHex != nil
            || !themeStore.customColors.isEmpty
            || themeStore.colorStyle != .vivid
    }

    /// The pure-black choice (upstream 纯黑模式 choice group):
    /// 0 = 标准， 1 = 纯黑.
    private var pureBlackChoice: Binding<Int> {
        Binding(
            get: { themeStore.pureBlack ? 1 : 0 },
            set: { themeStore.pureBlack = $0 == 1; themeStore.save() }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: "预览") {
                    ThemeLivePreview()
                        .padding(16)
                }

                footerSection(header: "主题模式", footer: "「跟随系统」时 App 跟随 iPhone 的深色 / 浅色设置自动切换。") {
                    ForEach(Array(ThemeAppearance.allCases.enumerated()), id: \.element) { index, appearance in
                        appearanceRow(appearance)
                        if index < ThemeAppearance.allCases.count - 1 {
                            UpstreamDivider()
                        }
                    }
                }

                footerSection(header: "纯黑模式", footer: "纯黑模式只在深色下生效：页面背景变纯黑，卡片变深灰。") {
                    Picker("纯黑模式", selection: pureBlackChoice) {
                        Text("标准").tag(0)
                        Text("纯黑").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(16)
                }

                // 主题色彩: header carries the reset icon (upstream
                // _PrimaryColorItem), shown only when non-default.
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("主题色彩")
                            .font(.headline)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        Spacer()
                        if isNonDefaultColor {
                            Button { showResetConfirm = true } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("恢复默认颜色")
                        }
                    }
                    VStack(spacing: 0) {
                        // v0.2.141 (C2-d1): ONE swatch row, as upstream's
                        // _ColorSwatches Wrap — the old split grids (main
                        // presets / extra presets / custom list) are merged.
                        // The presets are upstream's 8 + the teal preset
                        // this app already shipped (kept) + magenta (the
                        // MuYu video's primary); custom colours follow in
                        // the same row. The add control stays below the row
                        // (upstream's _AddColorButton opens a colour sheet;
                        // ours keeps the inline picker).
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
                                // Upstream's swatch menu (theme.dart
                                // _ColorSwatches) has 编辑 + 删除 with a
                                // confirm dialog; ours keeps the delete
                                // half of that menu (no edit flow exists
                                // here), now with upstream's confirm.
                                .contextMenu {
                                    Button("删除", role: .destructive) {
                                        deletingCustomColor = hex
                                    }
                                }
                            }
                        }
                        .padding(16)
                        UpstreamDivider(leading: 16)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                        if let customColorMessage {
                            Text(customColorMessage)
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }
                    }
                    .background(
                        ConcordTheme.cardBackground,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                    Text("主题色会用在按钮、开关、选中状态和进度条上。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                footerSection(header: "配色风格", footer: "生动：原样；柔和：降低饱和度；单色：灰色主题色。") {
                    Picker("配色风格", selection: $themeStore.colorStyle) {
                        ForEach(ThemeColorStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: themeStore.colorStyle) { _, _ in themeStore.save() }
                    .padding(16)
                }

                footerSection(header: "底栏", footer: "悬浮：底部悬浮胶囊栏；停靠：系统自带底部标签栏。") {
                    Picker("底栏", selection: $themeStore.navBarStyle) {
                        ForEach(ThemeNavBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: themeStore.navBarStyle) { _, _ in themeStore.save() }
                    .padding(16)
                }

                footerSection(header: "选项卡动画", footer: "滑动：页面左右滑动切换；淡入：页面淡入淡出切换。") {
                    Picker("选项卡动画", selection: $themeStore.tabAnimation) {
                        ForEach(ThemeTabAnimation.allCases) { animation in
                            Text(animation.label).tag(animation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: themeStore.tabAnimation) { _, _ in themeStore.save() }
                    .padding(16)
                }

                footerSection(header: "液态玻璃", footer: "液态玻璃需要 iOS 26 及支持玻璃材质的界面；当前版本只保存你的选择，界面暂无可见变化。") {
                    Picker("液态玻璃", selection: $themeStore.liquidGlass) {
                        ForEach(ThemeLiquidGlassMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: themeStore.liquidGlass) { _, _ in themeStore.save() }
                    .padding(16)
                }

                footerSection(header: "字体", footer: "系统默认字体，或已安装的任意字体。") {
                    NavigationLink {
                        FontPickerView()
                    } label: {
                        UpstreamNavRowContent(
                            icon: "textformat",
                            title: "字体",
                            value: fontStore.selectedFamily ?? "默认"
                        )
                    }
                }

                footerSection(header: "文本缩放", footer: nil) {
                    toggleRow("自定义文字大小", isOn: $themeStore.textScaleEnabled)
                        .onChange(of: themeStore.textScaleEnabled) { _, _ in themeStore.save() }
                    if themeStore.textScaleEnabled {
                        UpstreamDivider(leading: 16)
                        HStack {
                            Text("小")
                                .font(.caption2)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            Slider(value: $themeStore.textScale, in: 0.8...1.4, step: 0.05)
                                .onChange(of: themeStore.textScale) { _, _ in themeStore.save() }
                            Text("大")
                                .font(.caption2)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                        UpstreamDivider(leading: 16)
                        HStack {
                            Text("当前 \(Int(themeStore.textScale * 100))%")
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            Spacer()
                            if themeStore.textScale != 1.0 {
                                Button("恢复") {
                                    themeStore.textScale = 1.0
                                    themeStore.save()
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                        UpstreamDivider(leading: 16)
                        Text("预览 AaBbCc 1234")
                            .font(.system(size: 17 * themeStore.textScale))
                            .foregroundStyle(Color(.label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 56)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            // v0.2.66: tab-bar clearance for pushed pages.
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "主题")
        // FlClash theme.dart:109-135 _PrimaryColorItem reset:
        // confirm, then back to the default blue + vivid
        // style (and the preset list back to the defaults,
        // which here means clearing user-added swatches).
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
        // Upstream _handleDelete confirms before removing a
        // custom colour (and falls back to the default blue when
        // the deleted colour was the active one).
        .alert("删除这个自定义颜色吗？", isPresented: Binding(
            get: { deletingCustomColor != nil },
            set: { if !$0 { deletingCustomColor = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let hex = deletingCustomColor {
                    themeStore.customColors.removeAll { $0 == hex }
                    if themeStore.customAccentHex == hex {
                        themeStore.customAccentHex = nil
                    }
                    themeStore.save()
                }
                deletingCustomColor = nil
            }
            Button("取消", role: .cancel) { deletingCustomColor = nil }
        }
    }

    /// One card section with a 13pt grey footer line under it.
    private func footerSection<Content: View>(
        header: String?,
        footer: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            UpstreamCardSection(header: header) {
                content()
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// One appearance choice row: grey leading icon, 17pt title,
    /// accent checkmark when selected.
    private func appearanceRow(_ appearance: ThemeAppearance) -> some View {
        Button {
            themeStore.appearance = appearance
            themeStore.save()
        } label: {
            HStack(spacing: 16) {
                UpstreamRowIcon(systemName: appearance.icon)
                Text(appearance.label)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Spacer()
                if themeStore.appearance == appearance {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One toggle row: 17pt title, upstream switch (the style
    /// renders the label + the 52x32 track, and the whole row
    /// toggles, as upstream's ListItem.toggle).
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.body)
            .foregroundStyle(Color(.label))
            .toggleStyle(UpstreamToggleStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
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
