import Foundation
import Combine

// MARK: - Localisation
//
// The app's localised strings live in Localizable.xcstrings (424
// keys as of v0.2.145) and are compiled into per-language
// Localizable.strings in each <lang>.lproj. `"key".l10n` resolves
// through the language the user picked in Tools -> 语言 — NOT
// through Bundle.main's system language.
//
// T-D1 (v0.2.138): the language used to be a pushed picker page
// that wrote AppleLanguages and demanded a restart (upstream
// tools.dart:148-175 is an inline ListItem.options row and the
// whole Flutter app rebuilds immediately). The picker is now an
// inline Menu row in the Tools Settings section and the switch
// is immediate: LocalizationManager publishes the choice, .l10n
// reads the matching language bundle, and ContentView remounts
// the tab container on the change (.id(localization.language)),
// which re-renders every page in the new language — the SwiftUI
// equivalent of upstream's rebuild. The choice is still kept in
// sync with AppleLanguages, so a relaunch resolves the same
// language for anything that reads Bundle.main.
//
// Honest limit (v0.2.145, after the auditor-driven pass 2):
// the 4 tabs + Tools/Settings chrome switches — titles, section
// headers, toggles, buttons, labels, prompts, empty states,
// short notices, validation/format messages, count strings.
// Still hardcoded Chinese: the 11 multi-sentence explanatory
// paragraphs in SettingsView, and every other page
// (Connections, MITM, Developer, Logs, and the Tools/Settings
// sub-pages not covered here). A key missing from the picked
// language falls back to Chinese, so untranslated keys never
// show a raw key.

/// The user-picked app language, shared by .l10n and by the
/// Tools picker. "" means "follow the system" (Bundle.main).
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    static let appLanguageKey = "ConcordiOS.appLanguage"

    /// The seven languages the Tools picker offers (FlClash's
    /// supported locales: en, es, fr, ja, ko, ru, zh-CN), plus
    /// the system default. Names are shown in their own language,
    /// as in the old picker page.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("", "默认"),
        ("zh-Hans", "简体中文"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("ru", "Русский"),
    ]

    @Published var language: String = UserDefaults.standard.string(forKey: appLanguageKey) ?? "" {
        didSet { Self.persist(language) }
    }

    private init() {}

    /// The bundle .l10n reads from: the picked language's .lproj
    /// when it exists, Bundle.main (system language) otherwise.
    /// The built app carries en/es/fr/ja/ko/ru/zh-Hans .lproj
    /// dirs (verified in the v0.2.137 IPA), so every offered
    /// language resolves here.
    var bundle: Bundle {
        guard !language.isEmpty,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    /// Persist the choice and keep AppleLanguages in sync, so a
    /// relaunch resolves the same language. didSet does not fire
    /// during init, so the stored value is read once above.
    private static func persist(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: appLanguageKey)
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set(code, forKey: appLanguageKey)
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }
}

extension String {
    /// Localised string for this key, from the language the user
    /// picked in Tools -> 语言. A key missing from the picked
    /// language falls back to the Chinese bundle, so a missing
    /// translation shows Chinese instead of a raw key; a key
    /// missing there too returns the key itself (the old
    /// behaviour).
    var l10n: String {
        let manager = LocalizationManager.shared
        let value = NSLocalizedString(self, bundle: manager.bundle, comment: "")
        if value != self { return value }
        if let zhPath = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
           let zhBundle = Bundle(path: zhPath) {
            return NSLocalizedString(self, bundle: zhBundle, comment: "")
        }
        return value
    }
}
