import SwiftUI
import UIKit

// MARK: - App icon picker (alternate icons, public API only)
// v0.2.67: the 7 alternates now live in the asset catalog as
// Dark/Emerald/Neon/Purple/Sakura/Sunset/Titanium .appiconset folders
// (Xcode generates CFBundleAlternateIcons from them at build time) —
// the earlier loose-PNG + hand-written Info.plist setup failed at the
// system call with NSOSStatusErrorDomain -54 on the self-signed
// install, and the catalog is Apple's supported path. The picker
// previews come from AppIconPreview-* .imageset entries in the same
// catalog. This view uses only the public
// UIApplication.shared.setAlternateIconName API — no private APIs.
// A failure shows the full NSError (domain + code + description +
// underlying error) instead of a generic "切换失败".

struct AppIconOption: Identifiable {
    /// Name passed to setAlternateIconName; nil = the primary icon.
    let iconName: String?
    let title: String
    let subtitle: String
    /// Preview image-set name in the asset catalog (AppIconPreview-*).
    let previewResource: String

    var id: String { iconName ?? "default" }
}

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss

    private static let options: [AppIconOption] = [
        AppIconOption(iconName: nil, title: "经典原版", subtitle: "蓝紫渐变 · 当前主图标", previewResource: "AppIconPreview-Default"),
        AppIconOption(iconName: "Dark", title: "黑曜暗金", subtitle: "近黑底 · 金 C", previewResource: "AppIconPreview-Dark"),
        AppIconOption(iconName: "Neon", title: "赛博霓虹", subtitle: "深蓝底 · 青品渐变 C", previewResource: "AppIconPreview-Neon"),
        AppIconOption(iconName: "Sunset", title: "落日晚霞", subtitle: "蜜桃底 · 橙红渐变 C", previewResource: "AppIconPreview-Sunset"),
        AppIconOption(iconName: "Emerald", title: "翡翠薄荷", subtitle: "薄荷底 · 翠绿渐变 C", previewResource: "AppIconPreview-Emerald"),
        AppIconOption(iconName: "Sakura", title: "浪漫樱花", subtitle: "粉底 · 玫红渐变 C", previewResource: "AppIconPreview-Sakura"),
        AppIconOption(iconName: "Titanium", title: "钛合金灰", subtitle: "银灰底 · 石墨渐变 C", previewResource: "AppIconPreview-Titanium"),
        AppIconOption(iconName: "Purple", title: "极光幽紫", subtitle: "深紫底 · 紫罗兰渐变 C", previewResource: "AppIconPreview-Purple"),
    ]

    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var isChanging = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !UIApplication.shared.supportsAlternateIcons {
                    Text("当前设备不支持切换图标（supportsAlternateIcons 为 false）。自签安装也可能被系统拒绝，见下方错误信息。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Self.options) { option in
                        Button {
                            select(option)
                        } label: {
                            HStack(spacing: 12) {
                                AppIconPreview(resource: option.previewResource)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).font(.footnote.weight(.semibold))
                                    Text(option.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if currentIconName == option.iconName {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(ConcordTheme.accent)
                                }
                            }
                        }
                        .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
                    }
                } footer: {
                    Text("切换后系统会弹出确认框，确认后主屏幕图标立即更换。图标文件都在 App 里，不联网。")
                        .font(.footnote)
                }
                if isChanging {
                    Section {
                        ProgressView("正在切换图标…")
                    }
                }
                if let message = statusMessage {
                    Section {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                    .id("iconError")
                }
                // v0.2.72: invisible scrollable space below the error
                // card so its bottom can clear the floating tab bar —
                // the v0.2.66 contentMargins alone left the card's
                // bottom edge cut off (IMG_1213).
                if statusMessage != nil {
                    Section {
                        Color.clear
                            .frame(height: ConcordTheme.tabBarClearance)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
            }
            // v0.2.66: tab-bar clearance for pushed pages.
            .contentMargins(.bottom, ConcordTheme.tabBarClearance)
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .listStyle(.insetGrouped)
            .navigationTitle("App 图标")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
            // v0.2.72: reveal the error card when it appears — it is
            // appended below the fold when a switch fails.
            .onChange(of: statusMessage) { _, message in
                if message != nil {
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("iconError", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func select(_ option: AppIconOption) {
        guard currentIconName != option.iconName else { return }
        guard UIApplication.shared.supportsAlternateIcons else { return }
        isChanging = true
        statusMessage = nil
        statusIsError = false
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            DispatchQueue.main.async {
                isChanging = false
                if let error = error {
                    let nsError = error as NSError
                    var detail = "切换失败\n域名：\(nsError.domain)\n错误码：\(nsError.code)\n描述：\(nsError.localizedDescription)"
                    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        detail += "\n底层错误：\(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
                    }
                    statusMessage = detail
                    statusIsError = true
                } else {
                    currentIconName = option.iconName
                    statusMessage = "已切换为「\(option.title)」"
                    statusIsError = false
                }
            }
        }
    }
}

// Loads a preview image from the asset catalog by image-set name.
// (The alternate icons themselves are .appiconset entries, which are
// not loadable as UIImages — hence the separate AppIconPreview-*
// .imageset entries carrying the same 180px artwork.)
private struct AppIconPreview: View {
    let resource: String

    var body: some View {
        if let uiImage = UIImage(named: resource) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}
