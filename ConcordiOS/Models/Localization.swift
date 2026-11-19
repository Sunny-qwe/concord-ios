import Foundation

// MARK: - Localization helper (Batch E, v0.2.26)
// Primary user-facing strings live in Localizable.xcstrings (source
// language zh-Hans, translated into en / es / fr / ja / ko / ru —
// the seven languages LanguageView offers). Use `"key".l10n` at the
// call site. Strings with no entry keep their Chinese source text
// as the fallback: NSLocalizedString returns the key itself when a
// translation is missing, so every key's zh-Hans value is also the
// literal fallback — a missing translation can never surface a raw
// key to the user as long as the key is only ever used through this
// helper with a Chinese source value present in the table.
// The language itself is chosen in LanguageView (AppleLanguages +
// restart); this helper only reads the bundle's resolved language.

extension String {
    /// Localised string for this key from Localizable.xcstrings.
    var l10n: String {
        NSLocalizedString(self, comment: "")
    }
}
