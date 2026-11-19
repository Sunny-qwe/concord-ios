import Foundation
import SwiftUI
import Combine

// MARK: - Font store (FlClash: FontFamilyView, lib/views/font_family.dart)
// FlClash lists the device's installed font families and lets the
// user pick one; the choice is stored in the theme settings and
// applied to the whole app. Same idea here, client-side only: the
// selected family is persisted in UserDefaults and applied at the
// app root (ConcordiOSApp) through the .font environment, so every
// Text without an explicit font follows it. Texts that set an
// explicit .font(.system(...)) keep the system font — that is most
// of the app today, so the picker visibly changes titles and
// body text that use the default font, not every label.
// Honest limit: iOS ships mostly Latin-only families, so Chinese
// glyphs still fall back to the system font for CJK text.

final class FontStore: ObservableObject {
    static let shared = FontStore()
    static let storageKey = "ConcordiOS.font.family.v1"

    /// nil = the system default font.
    @Published var selectedFamily: String? {
        didSet { save() }
    }

    /// All font families installed on the device, sorted.
    var availableFamilies: [String] {
        UIFont.familyNames.sorted()
    }

    /// The root default font: the picked family at body text style
    /// (so Dynamic Type still scales it), or the system body font.
    /// NOTE: SwiftUI has no custom(_:textStyle:) overload — the size
    /// must come from UIFont.preferredFont and relativeTo: .body
    /// keeps Dynamic Type scaling.
    var rootFont: Font {
        if let family = selectedFamily {
            return Font.custom(family, size: UIFont.preferredFont(forTextStyle: .body).pointSize, relativeTo: .body)
        }
        return Font.body
    }

    /// A font in the picked family at an explicit size, for rows
    /// that preview their own family name.
    func font(family: String, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(family, size: size, relativeTo: .body).weight(weight)
    }

    private init() {
        selectedFamily = UserDefaults.standard.string(forKey: Self.storageKey)
    }

    func select(_ family: String?) {
        selectedFamily = family
    }

    private func save() {
        if let family = selectedFamily {
            UserDefaults.standard.set(family, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
