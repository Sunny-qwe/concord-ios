import SwiftUI
import UIKit

// MARK: - App icon picker (alternate icons, public API only)
// iOS alternate icons MUST be loose PNG files in the bundle — they
// cannot live in an asset catalog. The three alternates are declared
// in ConcordiOS/Info.plist under CFBundleIcons > CFBundleAlternateIcons
// and their files live in ConcordiOS/AppIcons/ (registered in the app
// target's Resources phase). This view uses only the public
// UIApplication.shared.setAlternateIconName API — no private APIs.
// The user previously hit error -54 in another app, so a failure shows
// the full NSError (domain + code + description + underlying error)
// instead of a generic "切换失败".

struct AppIconOption: Identifiable {
    /// Name passed to setAlternateIconName; nil = the primary icon.
    let iconName: String?
    let title: String
    let subtitle: String
    /// 180px preview file (without extension) in the main bundle.
    let previewResource: String

    var id: String { iconName ?? "default" }
}

struct AppIconPickerView: View {
    private static let options: [AppIconOption] = [
        AppIconOption(iconName: nil, title: "默认", subtitle: "蓝紫渐变", previewResource: "AppIcon-Default@3x"),
        AppIconOption(iconName: "Dark", title: "墨黑", subtitle: "近黑底 · 白 C", previewResource: "AppIcon-Dark@3x"),
        AppIconOption(iconName: "Teal", title: "曜青", subtitle: "青绿渐变 · 白 C", previewResource: "AppIcon-Teal@3x"),
        AppIconOption(iconName: "Light", title: "雪白", subtitle: "白底 · 深蓝 C", previewResource: "AppIcon-Light@3x"),
    ]

    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var isChanging = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        List {
            if !UIApplication.shared.supportsAlternateIcons {
                Text("当前设备不支持切换图标（supportsAlternateIcons 为 false）。自签安装也可能被系统拒绝，见下方错误信息。")
                    .font(.caption)
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
                                Text(option.title).font(.body)
                                Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
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
            }
            if isChanging {
                Section {
                    ProgressView("正在切换图标…")
                }
            }
            if let message = statusMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("App 图标")
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

// Loads a loose PNG from the bundle by resource name. UIImage(named:)
// does not reliably find loose files, so go through Bundle.main.url.
private struct AppIconPreview: View {
    let resource: String

    var body: some View {
        if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
           let uiImage = UIImage(contentsOfFile: url.path) {
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
