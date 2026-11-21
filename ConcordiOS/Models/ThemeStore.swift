import Foundation
import SwiftUI
import Combine

// MARK: - Theme store (FlClash: theme / appearance settings)
// FlClash lets the user pick light / dark / follow-system plus an
// accent colour. There is no Concord API for this — it is pure client
// work: the choice is persisted in UserDefaults and applied at the
// app root (ConcordiOSApp / ContentView) via .preferredColorScheme
// and .tint. The card / page colours in DesignSystem are semantic
// system colours, so they follow the colour scheme automatically;
// the accent is read from here by ConcordTheme.accent.
//
// The store is a singleton (ThemeStore.shared) so DesignSystem can
// read the accent without an environment object; ConcordiOSApp owns
// the same instance as a @StateObject and injects it, so changing
// the theme re-renders the root and every page picks the new accent.

enum ThemeAppearance: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

enum ThemeAccent: String, CaseIterable, Identifiable {
    case blue = "blue"
    case green = "green"
    case purple = "purple"
    case orange = "orange"
    case teal = "teal"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .purple: return "紫色"
        case .orange: return "橙色"
        case .teal: return "青色"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
        case .green: return Color(red: 0.204, green: 0.780, blue: 0.349)
        case .purple: return Color(red: 0.686, green: 0.322, blue: 0.863)
        case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
        case .teal: return Color(red: 0.0, green: 0.663, blue: 0.678)
        }
    }
}

/// FlClash's colour style: vivid (default), soft (desaturated) or
/// monochrome (greyscale accent).
enum ThemeColorStyle: String, CaseIterable, Identifiable {
    case vivid = "vivid"
    case soft = "soft"
    case monochrome = "monochrome"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vivid: return "生动"
        case .soft: return "柔和"
        case .monochrome: return "单色"
        }
    }
}

/// FlClash's navigation-bar style: the floating capsule (default)
/// or the system docked tab bar.
enum ThemeNavBarStyle: String, CaseIterable, Identifiable {
    case floating = "floating"
    case docked = "docked"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .floating: return "悬浮"
        case .docked: return "停靠"
        }
    }
}

/// FlClash's tab-switch animation (theme.dart _TabAnimationItem,
/// enum.dart:825): slide or fade. Upstream default is fade
/// (config defaults). Stored here; the tab container that applies
/// it lives in ContentView, which reads this value.
enum ThemeTabAnimation: String, CaseIterable, Identifiable {
    case slide = "slide"
    case fade = "fade"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slide: return "滑动"
        case .fade: return "淡入"
        }
    }
}

/// FlClash's liquid-glass mode (theme.dart _LiquidGlassItem,
/// enum.dart:827): none / standard / ultra. Upstream default is
/// none. Stored here; applying it needs iOS 26 glass rendering in
/// the tab bar, which the current iOS 17 target does not do — the
/// picker says so instead of pretending the choice takes effect
/// today.
enum ThemeLiquidGlassMode: String, CaseIterable, Identifiable {
    case none = "none"
    case standard = "standard"
    case ultra = "ultra"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "无"
        case .standard: return "标准"
        case .ultra: return "超强"
        }
    }
}

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let storageKey = "ConcordiOS.theme.v1"

    @Published var appearance: ThemeAppearance = .system
    @Published var accent: ThemeAccent = .blue
    /// A user-added accent colour (hex, e.g. "#FF6B6B"). When set it
    /// overrides `accent`.
    @Published var customAccentHex: String?
    /// User-added accent swatches (hex strings), editable in the
    /// theme page (FlClash: ThemeView custom colours).
    @Published var customColors: [String] = []
    /// Pure black background in dark mode (FlClash: ThemeView).
    @Published var pureBlack: Bool = false
    @Published var colorStyle: ThemeColorStyle = .vivid
    @Published var navBarStyle: ThemeNavBarStyle = .floating
    /// Text scale (FlClash: ThemeView text-scale slider). Off =
    /// follow the system size; on = the slider's DynamicTypeSize.
    @Published var textScaleEnabled: Bool = false
    @Published var textScale: Double = 1.0
    /// Tab-switch animation (FlClash: slide / fade, default fade).
    @Published var tabAnimation: ThemeTabAnimation = .fade
    /// Liquid-glass mode (FlClash: none / standard / ultra,
    /// default none).
    @Published var liquidGlass: ThemeLiquidGlassMode = .none

    /// nil = follow the system (SwiftUI decides).
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Whether the UI is currently dark (used for pure-black
    /// backgrounds; .system resolves against the device trait).
    var isDark: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    /// The accent after the colour style is applied: vivid as-is,
    /// soft desaturated, monochrome greyscale.
    var accentColor: Color {
        let base: Color
        if let hex = customAccentHex, let parsed = Color(hex: hex) {
            base = parsed
        } else {
            base = accent.color
        }
        switch colorStyle {
        case .vivid:
            return base
        case .soft:
            return base.adjusted(saturationMultiplier: 0.7)
        case .monochrome:
            return base.adjusted(saturationMultiplier: 0.0)
        }
    }

    /// The text-size step the root applies (nil = system default).
    var dynamicTypeSize: DynamicTypeSize? {
        guard textScaleEnabled else { return nil }
        switch textScale {
        case ..<0.85: return .xSmall
        case ..<0.95: return .small
        case ..<1.05: return .large
        case ..<1.15: return .xLarge
        case ..<1.25: return .xxLarge
        default: return .xxxLarge
        }
    }

    private init() {
        load()
    }

    private struct Saved: Codable {
        var appearance: String
        var accent: String
        var customAccentHex: String?
        var customColors: [String]
        var pureBlack: Bool
        var colorStyle: String
        var navBarStyle: String
        var textScaleEnabled: Bool
        var textScale: Double
        var tabAnimation: String
        var liquidGlass: String

        // The post-0.2.17 fields are decoded leniently so themes
        // saved by earlier versions still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            appearance = try c.decode(String.self, forKey: .appearance)
            accent = try c.decode(String.self, forKey: .accent)
            customAccentHex = try c.decodeIfPresent(String.self, forKey: .customAccentHex)
            customColors = try c.decodeIfPresent([String].self, forKey: .customColors) ?? []
            pureBlack = try c.decodeIfPresent(Bool.self, forKey: .pureBlack) ?? false
            colorStyle = try c.decodeIfPresent(String.self, forKey: .colorStyle) ?? "vivid"
            navBarStyle = try c.decodeIfPresent(String.self, forKey: .navBarStyle) ?? "floating"
            textScaleEnabled = try c.decodeIfPresent(Bool.self, forKey: .textScaleEnabled) ?? false
            textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? 1.0
            tabAnimation = try c.decodeIfPresent(String.self, forKey: .tabAnimation) ?? "fade"
            liquidGlass = try c.decodeIfPresent(String.self, forKey: .liquidGlass) ?? "none"
        }

        init(appearance: String, accent: String, customAccentHex: String?, customColors: [String], pureBlack: Bool, colorStyle: String, navBarStyle: String, textScaleEnabled: Bool, textScale: Double, tabAnimation: String = "fade", liquidGlass: String = "none") {
            self.appearance = appearance
            self.accent = accent
            self.customAccentHex = customAccentHex
            self.customColors = customColors
            self.pureBlack = pureBlack
            self.colorStyle = colorStyle
            self.navBarStyle = navBarStyle
            self.textScaleEnabled = textScaleEnabled
            self.textScale = textScale
            self.tabAnimation = tabAnimation
            self.liquidGlass = liquidGlass
        }
    }

    /// Re-read the persisted choice (used after a backup restore).
    func reload() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        appearance = ThemeAppearance(rawValue: saved.appearance) ?? .system
        accent = ThemeAccent(rawValue: saved.accent) ?? .blue
        customAccentHex = saved.customAccentHex
        customColors = saved.customColors
        pureBlack = saved.pureBlack
        colorStyle = ThemeColorStyle(rawValue: saved.colorStyle) ?? .vivid
        navBarStyle = ThemeNavBarStyle(rawValue: saved.navBarStyle) ?? .floating
        textScaleEnabled = saved.textScaleEnabled
        textScale = saved.textScale
        tabAnimation = ThemeTabAnimation(rawValue: saved.tabAnimation) ?? .fade
        liquidGlass = ThemeLiquidGlassMode(rawValue: saved.liquidGlass) ?? .none
    }

    func save() {
        let saved = Saved(appearance: appearance.rawValue, accent: accent.rawValue, customAccentHex: customAccentHex, customColors: customColors, pureBlack: pureBlack, colorStyle: colorStyle.rawValue, navBarStyle: navBarStyle.rawValue, textScaleEnabled: textScaleEnabled, textScale: textScale, tabAnimation: tabAnimation.rawValue, liquidGlass: liquidGlass.rawValue)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension Color {
    /// Parse a "#RRGGBB" hex string.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Multiply the colour's saturation (HSB), leaving hue and
    /// brightness alone.
    func adjusted(saturationMultiplier: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return self
        }
        return Color(hue: hue, saturation: saturation * saturationMultiplier, brightness: brightness, opacity: alpha)
    }
}
