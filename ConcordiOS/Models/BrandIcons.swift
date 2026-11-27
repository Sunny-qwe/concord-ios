// BrandIcons.swift — bundled brand icons (MuYu lib/common/brand_icons.dart).
//
// v0.2.141 icons revert (user 2026-11-27 ~00:12, "三处都改回上游的样子"):
// group icons no longer come only from the user's own packs. The
// built-in marks are MuYu's 20-entry map over Simple Icons 13.0.0
// (CC0) SVGs, rendered here from the embedded PNGs in
// BrandIconData.swift (black glyph on transparent, so
// .renderingMode(.template) reproduces MuYu's SvgTheme(currentColor:)
// tinting). Upstream FlClash rs.1 itself has NO built-in brand
// icons — icon sets there are 100% user-imported — but the MuYu
// build the user compares against has this map, and the revert
// restores it.
//
// Resolution order (MuYu lib/widgets/icon.dart GroupBrandIcon,
// with the user's pack inserted before the bundled tier, per the
// user's §7 icon-source direction): the profile's own icon URL
// wins, then the user-imported icon pack (IconPackStore), then the
// bundled brand below, then the monogram. The pack wins when both
// match, so a user's own pack is never shadowed by a bundled mark.
//
// Matching is MuYu's: compact the name (lowercase, strip
// non-alphanumerics) and look it up exactly — "YouTube" and
// "youtube!" both match 'youtube'; "YouTube Premium" does not
// (the compacted key 'youtubepremium' is not in the map).

import SwiftUI
import UIKit

/// One bundled brand mark: an embedded PNG or an SF Symbol glyph.
enum BrandIcon {
    /// Key into BrandIconData.all (a black-on-transparent PNG).
    case image(String)
    /// An SF Symbol name (MuYu's glyph entries, e.g. rocket → send).
    case glyph(String)
}

enum BrandIcons {
    /// MuYu's _brandIcons map, verbatim (20 keys; chatgpt/disney/
    /// prime are aliases of the openai/disneyplus/primevideo art,
    /// rocket is a glyph, not an image).
    private static let brandIcons: [String: BrandIcon] = [
        "apple": .image("brand-apple"),
        "appletv": .image("brand-appletv"),
        "bilibili": .image("brand-bilibili"),
        "chatgpt": .image("brand-openai"),
        "claude": .image("brand-claude"),
        "discord": .image("brand-discord"),
        "disney": .image("brand-disneyplus"),
        "disneyplus": .image("brand-disneyplus"),
        "gemini": .image("brand-gemini"),
        "github": .image("brand-github"),
        "google": .image("brand-google"),
        "netflix": .image("brand-netflix"),
        "openai": .image("brand-openai"),
        "prime": .image("brand-primevideo"),
        "primevideo": .image("brand-primevideo"),
        "spotify": .image("brand-spotify"),
        "steam": .image("brand-steam"),
        "tiktok": .image("brand-tiktok"),
        "youtube": .image("brand-youtube"),
        // MuYu: rocket → AppGlyphs.send (a paper-plane glyph).
        "rocket": .glyph("paperplane.fill"),
    ]

    /// MuYu's _compactBrandName: lowercase, strip non-alphanumerics.
    /// Microsoft and OneDrive are absent: Simple Icons 13.0.0
    /// carries neither (MuYu's comment, kept).
    static func compactName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The built-in mark for a group name, or nil when no brand
    /// matches (MuYu brandIconFor, exact compacted-key lookup only).
    static func icon(for name: String) -> BrandIcon? {
        let key = compactName(name)
        guard !key.isEmpty else { return nil }
        return brandIcons[key]
    }

    /// Whether any bundled brand matches this name (for the
    /// member/selected-icon helpers, which return nil when a group
    /// has no icon anywhere — a brand match turns into the name
    /// string so GroupIconImageView resolves it there).
    static func hasBrand(for name: String) -> Bool {
        icon(for: name) != nil
    }

    /// The mark as a tintable SwiftUI view (template rendering, so
    /// the caller supplies the colour via .foregroundStyle, as
    /// MuYu's SvgTheme(currentColor:) does).
    @ViewBuilder
    static func view(for brand: BrandIcon) -> some View {
        switch brand {
        case .image(let resource):
            if let data = BrandIconData.all[resource].flatMap({ Data(base64Encoded: $0) }),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            }
        case .glyph(let systemName):
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
        }
    }
}
