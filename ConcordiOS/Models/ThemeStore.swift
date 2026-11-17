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

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let storageKey = "ConcordiOS.theme.v1"

    @Published var appearance: ThemeAppearance = .system
    @Published var accent: ThemeAccent = .blue

    /// nil = follow the system (SwiftUI decides).
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accentColor: Color { accent.color }

    private init() {
        load()
    }

    private struct Saved: Codable {
        var appearance: String
        var accent: String
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
    }

    func save() {
        let saved = Saved(appearance: appearance.rawValue, accent: accent.rawValue)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
