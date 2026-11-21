import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Design system (reference screenshots IMG_1082 / IMG_103)
// One visual language for the whole app, matching the reference
// dashboard: light-grey page, white cards with big rounded corners
// and a soft shadow, blue #007AFF accent, big bold numbers, pale
// capsule badges. Only the look changed here — no data logic lives
// in this file (except the local intranet-IP read, which is device
// info, not core data).
//
// Typography standard (v0.2.34 font unification; grounded in the
// four tab roots — Dashboard, Proxies, Config, Tools — and the
// screenshots IMG_1132–1135). The app root sets a 17pt body font
// (ConcordiOSApp: .environment(\.font, fontStore.rootFont)), so any
// Text without an explicit font renders at 17pt regular — that is
// why sub-pages built from plain List/Form/Section looked bigger
// than the first-level pages. Sub-pages fix it with a container
// font on their outermost List/Form — .font(.footnote.weight(.semibold))
// (v0.2.50: was .font(.system(size: 13, weight: .semibold)); the fixed
// size ignored the global text size, the footnote token is the same
// 13pt at default scale and scales with it) — which propagates to rows,
// TextFields, Buttons and section headers, while explicit fonts on
// individual elements override it:
//   - Pushed-page nav title: system .inline (17 semibold, default);
//     .largeTitle kept where already used (DNS 查询 mirrors Proxies).
//   - Section header: 13 semibold, secondary grey.
//   - Row label / primary text (settings row, nav row, Toggle /
//     Picker label, Button row, TextField input): 13 semibold.
//   - Row value / secondary text: 13 regular.
//   - Row icon (SF Symbol): 18 regular.
//   - Card title inside a card: 14 semibold (Proxies) / 12 semibold
//     (Dashboard CardTitleRow).
//   - Footnote / explainer / message / error: 10 (Diagnostics uses
//     .footnote = 13, also in range); section footers: explicit 13
//     regular (the root font would otherwise make them 17).
//   - Caption / badge / chip / timestamp: 10 (semibold for chips).
//   - Small secondary: 11.
//   - Named-entity primary: profile / group / provider / dialer
//     names 17 semibold (Profiles lineage); group names 15
//     (Proxies); node names 13 regular (Proxies); provider names 13
//     regular (ProvidersView).
//   - Mono / code text: keep .body / .caption mono.
//   - Large display numbers / titles: keep (Dashboard 21 bold,
//     Tools title 18 bold, hero titles 17 bold).
//   - Leave alone (system-styled): alert text, ContentUnavailableView,
//     Picker .tag option texts, Menu / context-menu items, toolbar
//     buttons, segmented Picker option labels.
//   - Known trade-off: LabeledContent label AND value both become
//     13 semibold under a container font (values ideally 13 regular,
//     but they cannot be separated without restructuring ~100 sites);
//     strictly closer to the first-level row style than 17 regular.

enum ConcordTheme {
    /// Page background: the system grouped background — #F2F2F7 in
    /// light mode, dark in dark mode. (ThemeStore drives the colour
    /// scheme; these semantic colours follow it automatically.)
    /// With 纯黑模式 on in dark mode the page is pure black.
    static var pageBackground: Color {
        ThemeStore.shared.pureBlack && ThemeStore.shared.isDark
            ? .black : Color(.systemGroupedBackground)
    }
    /// Card background: secondary system grouped background — white
    /// in light mode, dark grey in dark mode. Pure black mode keeps
    /// cards a very dark grey so they stay distinguishable.
    static var cardBackground: Color {
        ThemeStore.shared.pureBlack && ThemeStore.shared.isDark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(.secondarySystemGroupedBackground)
    }
    /// Main card corner radius.
    static let cardRadius: CGFloat = 28
    /// Inner panel corner radius (speed halves, mode pills).
    static let panelRadius: CGFloat = 20
    /// Primary accent — the theme's accent colour (default blue
    /// #007AFF). Read from ThemeStore so a theme change recolours
    /// every page that uses it.
    static var accent: Color { ThemeStore.shared.accentColor }
    /// Pale grey fill for unselected pills / inner panels.
    static let softFill = Color(.secondarySystemFill)
    /// Selected-tab capsule fill in the floating bar.
    static let tabSelectedFill = Color(.systemFill)
    /// Unselected tab icon/label grey.
    static let tabUnselected = Color(red: 0.25, green: 0.25, blue: 0.28)
    /// Soft card shadow.
    static let cardShadow = Color.black.opacity(0.05)
}

// MARK: - Card

struct ConcordCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.cardRadius))
            .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
    }
}

extension View {
    /// White card, corner radius 28, soft shadow.
    func concordCard(padding: CGFloat = 16) -> some View {
        modifier(ConcordCardModifier(padding: padding))
    }

    /// The app-wide page background.
    func concordPageBackground() -> some View {
        background(ConcordTheme.pageBackground)
    }
}

// MARK: - Card header (small icon + bold title)

struct CardTitleRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(.label))
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
        }
    }
}

// MARK: - Pale capsule badge ("未运行" grey, "全部可用" green, "11 超时" orange)

struct PillBadge: View {
    let text: String
    let tint: Color
    /// When true, a 6pt dot is drawn before the text (FlClash chips
    /// show a dot while running).
    var dot: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if dot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

// MARK: - Skeleton bar (FlClash SkeletonPill / inactive bars)
///
/// True base colour for the light-mode bars. Measured from the
/// FlClash reference (IMG_1115-2, 1170x2532): every bar — IP
/// (140x18), the two chips (48x28, 72x28) and the org bar (96x12)
/// — renders RGB (233,231,232) = #E9E7E8, while the card bg is
/// (252,248,249) and the wave is (239,237,240) = #EFEDF0. The
/// source's literal 0xB3ECE9EB (#ECE9EB @ 0.7) does NOT reproduce
/// this: composited over the card bg it renders (241,238,239) and
/// over the wave (237,234,237) — visibly too light. So the bars
/// are OPAQUE #E9E7E8 in light mode: the render is exactly the
/// measured colour no matter what sits behind them (the wave edge
/// crosses the bars). In dark mode the source literal is kept
/// (#ECE9EB @ 0.7), which reads as a muted grey on a dark card.

struct SkeletonBar: View {
    let width: CGFloat
    let height: CGFloat
    /// True while running and waiting for the probe (pulsing);
    /// false for the static not-running bars.
    var animated: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    /// Light mode: opaque #E9E7E8 (measured — see comment above).
    /// Dark mode: static bars keep the source literal #ECE9EB @
    /// 0.7; pulsing bars use white 15% (the source's
    /// surfaceContainerHighest is theme-dependent).
    private var barColor: Color {
        if colorScheme == .dark {
            return animated ? Color.white.opacity(0.15) : Color(red: 0.925, green: 0.914, blue: 0.922)
        }
        return Color(red: 233.0 / 255.0, green: 231.0 / 255.0, blue: 232.0 / 255.0)
    }

    private var barOpacity: CGFloat {
        if animated { return pulse ? 1.0 : 0.5 }
        return colorScheme == .dark ? 0.7 : 1.0
    }

    var body: some View {
        Capsule()
            .fill(barColor)
            .opacity(barOpacity)
            .frame(width: width, height: height)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Organic blob (the grey shape behind the globe / the blue
// shape behind the VPN shield in the reference)

struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0.50 * w, y: 0.03 * h))
        path.addCurve(to: CGPoint(x: 0.93 * w, y: 0.28 * h),
                      control1: CGPoint(x: 0.78 * w, y: 0.02 * h),
                      control2: CGPoint(x: 0.99 * w, y: 0.10 * h))
        path.addCurve(to: CGPoint(x: 0.88 * w, y: 0.74 * h),
                      control1: CGPoint(x: 0.90 * w, y: 0.44 * h),
                      control2: CGPoint(x: 0.99 * w, y: 0.58 * h))
        path.addCurve(to: CGPoint(x: 0.52 * w, y: 0.97 * h),
                      control1: CGPoint(x: 0.80 * w, y: 0.86 * h),
                      control2: CGPoint(x: 0.72 * w, y: 0.99 * h))
        path.addCurve(to: CGPoint(x: 0.12 * w, y: 0.80 * h),
                      control1: CGPoint(x: 0.32 * w, y: 0.96 * h),
                      control2: CGPoint(x: 0.08 * w, y: 0.93 * h))
        path.addCurve(to: CGPoint(x: 0.05 * w, y: 0.34 * h),
                      control1: CGPoint(x: 0.16 * w, y: 0.68 * h),
                      control2: CGPoint(x: 0.02 * w, y: 0.55 * h))
        path.addCurve(to: CGPoint(x: 0.50 * w, y: 0.03 * h),
                      control1: CGPoint(x: 0.08 * w, y: 0.14 * h),
                      control2: CGPoint(x: 0.22 * w, y: 0.04 * h))
        path.closeSubpath()
        return path
    }
}

/// An SF Symbol centred on a blob-shaped fill.
struct BlobIcon: View {
    let systemName: String
    let iconColor: Color
    let blobColor: Color
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            BlobShape()
                .fill(blobColor)
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Capsule progress bar (subscription traffic; the reference
// uses a wavy bar, a rounded capsule carries the same information)

struct CapsuleProgressBar: View {
    /// 0...1.
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.898, green: 0.898, blue: 0.925))
                Capsule()
                    .fill(ConcordTheme.accent)
                    .frame(width: max(geometry.size.width * CGFloat(min(max(fraction, 0), 1)), 8))
                Circle()
                    .fill(ConcordTheme.accent)
                    .frame(width: 10, height: 10)
                    .offset(x: geometry.size.width - 5)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Relative time ("刚刚" / "3 分钟前" / "2 小时前" / "5 天前")

enum ConcordRelativeTime {
    static func string(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    /// Whole days from now until an epoch-seconds expiry; 0 when the
    /// expiry is absent or already past.
    static func daysUntil(epochSeconds: Int64) -> Int {
        guard epochSeconds > 0 else { return 0 }
        let remaining = TimeInterval(epochSeconds) - Date().timeIntervalSince1970
        guard remaining > 0 else { return 0 }
        return Int(remaining / 86_400)
    }
}

// MARK: - Byte split for big numbers ("0" + "B", "1.5" + "MB")

enum ConcordBytes {
    static func split(_ value: Int64) -> (number: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        var number = String(format: "%.1f", v)
        if number.hasSuffix(".0") { number.removeLast(2) }
        return (number, units[i])
    }
}

// MARK: - Device intranet IP (Wi-Fi interface en0)

enum DeviceNetwork {
    /// The IPv4 address of the Wi-Fi interface (en0), if any. Local
    /// device info only — nothing is sent anywhere.
    static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if let name = current.pointee.ifa_name,
               String(cString: name) == "en0",
               (flags & IFF_UP) == IFF_UP,
               (flags & IFF_LOOPBACK) == 0,
               let socketAddress = current.pointee.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return nil
    }

    /// Active network type for the status card ("Wi-Fi" / "移动网络"):
    /// en0 up with an IPv4 address means Wi-Fi; pdp_ip0 (the
    /// cellular data interface) up means mobile data. Same getifaddrs
    /// source as localIPv4Address — local device info only.
    static func currentNetworkType() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "未知网络" }
        defer { freeifaddrs(ifaddr) }
        var hasWifi = false
        var hasCellular = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let name = current.pointee.ifa_name,
               let socketAddress = current.pointee.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_INET) {
                let ifName = String(cString: name)
                if ifName == "en0" { hasWifi = true }
                if ifName.hasPrefix("pdp_ip") { hasCellular = true }
            }
            cursor = current.pointee.ifa_next
        }
        if hasWifi { return "Wi-Fi" }
        if hasCellular { return "移动网络" }
        return "未知网络"
    }
}

// MARK: - FlClash status-card geometry (transcribed from prism_ui)
//
// Outlines generated from the FlClash source
// (plugins/prism_ui/lib/shapes/{material_shapes,rounded_polygon,morph}.dart):
// the RoundedPolygon corner math was re-implemented in Python and the
// resulting unit-square outlines were sampled by arc length (start at the
// top, clockwise). morphCircle is RoundedPolygon.circle(10 vertices,
// radius 0.5) which is a true circle; morphStar is cookie9Sided =
// star(9, innerRadius 0.8, rounding 0.5) rotated -90 degrees and
// normalized; clover is clover4Leaf = _customPolygon seeds
// (0.5, 0.074) unrounded + (0.725, -0.099) rounding 0.476, 4 reps
// mirrored, normalized. The morph lerps matching arc-length samples,
// which is what Morph.asCubics does (it matches cubics by outline
// progress and lerps their control points).

enum FlClashShapes {
// Generated from FlClash prism_ui RoundedPolygon geometry
// (plugins/prism_ui/lib/shapes/{material_shapes,rounded_polygon,morph}.dart).
// Unit-square outlines, sampled by arc length, starting at the top, clockwise.
// morphCircle: RoundedPolygon.circle(10 vertices, r 0.5) = true circle.
// morphStar: cookie9Sided = star(9, inner 0.8, rounding 0.5) rotated -90deg, normalized.
// clover: clover4Leaf = _customPolygon seeds (0.5,0.074) + (0.725,-0.099) r 0.476, reps 4 mirrored, normalized.
    static let morphCircle: [CGPoint] = [
        CGPoint(x: 0.5000, y: 0.0000), CGPoint(x: 0.5174, y: 0.0003), CGPoint(x: 0.5349, y: 0.0012), CGPoint(x: 0.5523, y: 0.0027),
        CGPoint(x: 0.5696, y: 0.0049), CGPoint(x: 0.5868, y: 0.0076), CGPoint(x: 0.6040, y: 0.0109), CGPoint(x: 0.6210, y: 0.0149),
        CGPoint(x: 0.6378, y: 0.0194), CGPoint(x: 0.6545, y: 0.0245), CGPoint(x: 0.6710, y: 0.0302), CGPoint(x: 0.6873, y: 0.0364),
        CGPoint(x: 0.7034, y: 0.0432), CGPoint(x: 0.7192, y: 0.0506), CGPoint(x: 0.7347, y: 0.0585), CGPoint(x: 0.7500, y: 0.0670),
        CGPoint(x: 0.7650, y: 0.0760), CGPoint(x: 0.7796, y: 0.0855), CGPoint(x: 0.7939, y: 0.0955), CGPoint(x: 0.8078, y: 0.1060),
        CGPoint(x: 0.8214, y: 0.1170), CGPoint(x: 0.8346, y: 0.1284), CGPoint(x: 0.8473, y: 0.1403), CGPoint(x: 0.8597, y: 0.1527),
        CGPoint(x: 0.8716, y: 0.1654), CGPoint(x: 0.8830, y: 0.1786), CGPoint(x: 0.8940, y: 0.1922), CGPoint(x: 0.9045, y: 0.2061),
        CGPoint(x: 0.9145, y: 0.2204), CGPoint(x: 0.9240, y: 0.2350), CGPoint(x: 0.9330, y: 0.2500), CGPoint(x: 0.9415, y: 0.2653),
        CGPoint(x: 0.9494, y: 0.2808), CGPoint(x: 0.9568, y: 0.2966), CGPoint(x: 0.9636, y: 0.3127), CGPoint(x: 0.9698, y: 0.3290),
        CGPoint(x: 0.9755, y: 0.3455), CGPoint(x: 0.9806, y: 0.3622), CGPoint(x: 0.9851, y: 0.3790), CGPoint(x: 0.9891, y: 0.3960),
        CGPoint(x: 0.9924, y: 0.4132), CGPoint(x: 0.9951, y: 0.4304), CGPoint(x: 0.9973, y: 0.4477), CGPoint(x: 0.9988, y: 0.4651),
        CGPoint(x: 0.9997, y: 0.4826), CGPoint(x: 1.0000, y: 0.5000), CGPoint(x: 0.9997, y: 0.5174), CGPoint(x: 0.9988, y: 0.5349),
        CGPoint(x: 0.9973, y: 0.5523), CGPoint(x: 0.9951, y: 0.5696), CGPoint(x: 0.9924, y: 0.5868), CGPoint(x: 0.9891, y: 0.6040),
        CGPoint(x: 0.9851, y: 0.6210), CGPoint(x: 0.9806, y: 0.6378), CGPoint(x: 0.9755, y: 0.6545), CGPoint(x: 0.9698, y: 0.6710),
        CGPoint(x: 0.9636, y: 0.6873), CGPoint(x: 0.9568, y: 0.7034), CGPoint(x: 0.9494, y: 0.7192), CGPoint(x: 0.9415, y: 0.7347),
        CGPoint(x: 0.9330, y: 0.7500), CGPoint(x: 0.9240, y: 0.7650), CGPoint(x: 0.9145, y: 0.7796), CGPoint(x: 0.9045, y: 0.7939),
        CGPoint(x: 0.8940, y: 0.8078), CGPoint(x: 0.8830, y: 0.8214), CGPoint(x: 0.8716, y: 0.8346), CGPoint(x: 0.8597, y: 0.8473),
        CGPoint(x: 0.8473, y: 0.8597), CGPoint(x: 0.8346, y: 0.8716), CGPoint(x: 0.8214, y: 0.8830), CGPoint(x: 0.8078, y: 0.8940),
        CGPoint(x: 0.7939, y: 0.9045), CGPoint(x: 0.7796, y: 0.9145), CGPoint(x: 0.7650, y: 0.9240), CGPoint(x: 0.7500, y: 0.9330),
        CGPoint(x: 0.7347, y: 0.9415), CGPoint(x: 0.7192, y: 0.9494), CGPoint(x: 0.7034, y: 0.9568), CGPoint(x: 0.6873, y: 0.9636),
        CGPoint(x: 0.6710, y: 0.9698), CGPoint(x: 0.6545, y: 0.9755), CGPoint(x: 0.6378, y: 0.9806), CGPoint(x: 0.6210, y: 0.9851),
        CGPoint(x: 0.6040, y: 0.9891), CGPoint(x: 0.5868, y: 0.9924), CGPoint(x: 0.5696, y: 0.9951), CGPoint(x: 0.5523, y: 0.9973),
        CGPoint(x: 0.5349, y: 0.9988), CGPoint(x: 0.5174, y: 0.9997), CGPoint(x: 0.5000, y: 1.0000), CGPoint(x: 0.4826, y: 0.9997),
        CGPoint(x: 0.4651, y: 0.9988), CGPoint(x: 0.4477, y: 0.9973), CGPoint(x: 0.4304, y: 0.9951), CGPoint(x: 0.4132, y: 0.9924),
        CGPoint(x: 0.3960, y: 0.9891), CGPoint(x: 0.3790, y: 0.9851), CGPoint(x: 0.3622, y: 0.9806), CGPoint(x: 0.3455, y: 0.9755),
        CGPoint(x: 0.3290, y: 0.9698), CGPoint(x: 0.3127, y: 0.9636), CGPoint(x: 0.2966, y: 0.9568), CGPoint(x: 0.2808, y: 0.9494),
        CGPoint(x: 0.2653, y: 0.9415), CGPoint(x: 0.2500, y: 0.9330), CGPoint(x: 0.2350, y: 0.9240), CGPoint(x: 0.2204, y: 0.9145),
        CGPoint(x: 0.2061, y: 0.9045), CGPoint(x: 0.1922, y: 0.8940), CGPoint(x: 0.1786, y: 0.8830), CGPoint(x: 0.1654, y: 0.8716),
        CGPoint(x: 0.1527, y: 0.8597), CGPoint(x: 0.1403, y: 0.8473), CGPoint(x: 0.1284, y: 0.8346), CGPoint(x: 0.1170, y: 0.8214),
        CGPoint(x: 0.1060, y: 0.8078), CGPoint(x: 0.0955, y: 0.7939), CGPoint(x: 0.0855, y: 0.7796), CGPoint(x: 0.0760, y: 0.7650),
        CGPoint(x: 0.0670, y: 0.7500), CGPoint(x: 0.0585, y: 0.7347), CGPoint(x: 0.0506, y: 0.7192), CGPoint(x: 0.0432, y: 0.7034),
        CGPoint(x: 0.0364, y: 0.6873), CGPoint(x: 0.0302, y: 0.6710), CGPoint(x: 0.0245, y: 0.6545), CGPoint(x: 0.0194, y: 0.6378),
        CGPoint(x: 0.0149, y: 0.6210), CGPoint(x: 0.0109, y: 0.6040), CGPoint(x: 0.0076, y: 0.5868), CGPoint(x: 0.0049, y: 0.5696),
        CGPoint(x: 0.0027, y: 0.5523), CGPoint(x: 0.0012, y: 0.5349), CGPoint(x: 0.0003, y: 0.5174), CGPoint(x: 0.0000, y: 0.5000),
        CGPoint(x: 0.0003, y: 0.4826), CGPoint(x: 0.0012, y: 0.4651), CGPoint(x: 0.0027, y: 0.4477), CGPoint(x: 0.0049, y: 0.4304),
        CGPoint(x: 0.0076, y: 0.4132), CGPoint(x: 0.0109, y: 0.3960), CGPoint(x: 0.0149, y: 0.3790), CGPoint(x: 0.0194, y: 0.3622),
        CGPoint(x: 0.0245, y: 0.3455), CGPoint(x: 0.0302, y: 0.3290), CGPoint(x: 0.0364, y: 0.3127), CGPoint(x: 0.0432, y: 0.2966),
        CGPoint(x: 0.0506, y: 0.2808), CGPoint(x: 0.0585, y: 0.2653), CGPoint(x: 0.0670, y: 0.2500), CGPoint(x: 0.0760, y: 0.2350),
        CGPoint(x: 0.0855, y: 0.2204), CGPoint(x: 0.0955, y: 0.2061), CGPoint(x: 0.1060, y: 0.1922), CGPoint(x: 0.1170, y: 0.1786),
        CGPoint(x: 0.1284, y: 0.1654), CGPoint(x: 0.1403, y: 0.1527), CGPoint(x: 0.1527, y: 0.1403), CGPoint(x: 0.1654, y: 0.1284),
        CGPoint(x: 0.1786, y: 0.1170), CGPoint(x: 0.1922, y: 0.1060), CGPoint(x: 0.2061, y: 0.0955), CGPoint(x: 0.2204, y: 0.0855),
        CGPoint(x: 0.2350, y: 0.0760), CGPoint(x: 0.2500, y: 0.0670), CGPoint(x: 0.2653, y: 0.0585), CGPoint(x: 0.2808, y: 0.0506),
        CGPoint(x: 0.2966, y: 0.0432), CGPoint(x: 0.3127, y: 0.0364), CGPoint(x: 0.3290, y: 0.0302), CGPoint(x: 0.3455, y: 0.0245),
        CGPoint(x: 0.3622, y: 0.0194), CGPoint(x: 0.3790, y: 0.0149), CGPoint(x: 0.3960, y: 0.0109), CGPoint(x: 0.4132, y: 0.0076),
        CGPoint(x: 0.4304, y: 0.0049), CGPoint(x: 0.4477, y: 0.0027), CGPoint(x: 0.4651, y: 0.0012), CGPoint(x: 0.4826, y: 0.0003),
    ]
    static let morphStar: [CGPoint] = [
        CGPoint(x: 0.5000, y: 0.0052), CGPoint(x: 0.5177, y: 0.0062), CGPoint(x: 0.5351, y: 0.0092), CGPoint(x: 0.5521, y: 0.0141),
        CGPoint(x: 0.5684, y: 0.0209), CGPoint(x: 0.5839, y: 0.0295), CGPoint(x: 0.5983, y: 0.0397), CGPoint(x: 0.6118, y: 0.0512),
        CGPoint(x: 0.6260, y: 0.0616), CGPoint(x: 0.6414, y: 0.0704), CGPoint(x: 0.6576, y: 0.0774), CGPoint(x: 0.6746, y: 0.0824),
        CGPoint(x: 0.6920, y: 0.0856), CGPoint(x: 0.7096, y: 0.0868), CGPoint(x: 0.7273, y: 0.0867), CGPoint(x: 0.7449, y: 0.0881),
        CGPoint(x: 0.7623, y: 0.0915), CGPoint(x: 0.7792, y: 0.0968), CGPoint(x: 0.7953, y: 0.1039), CGPoint(x: 0.8106, y: 0.1129),
        CGPoint(x: 0.8248, y: 0.1234), CGPoint(x: 0.8377, y: 0.1356), CGPoint(x: 0.8491, y: 0.1490), CGPoint(x: 0.8589, y: 0.1637),
        CGPoint(x: 0.8671, y: 0.1794), CGPoint(x: 0.8734, y: 0.1959), CGPoint(x: 0.8779, y: 0.2130), CGPoint(x: 0.8808, y: 0.2305),
        CGPoint(x: 0.8851, y: 0.2476), CGPoint(x: 0.8912, y: 0.2642), CGPoint(x: 0.8992, y: 0.2800), CGPoint(x: 0.9089, y: 0.2948),
        CGPoint(x: 0.9202, y: 0.3084), CGPoint(x: 0.9329, y: 0.3207), CGPoint(x: 0.9466, y: 0.3319), CGPoint(x: 0.9591, y: 0.3444),
        CGPoint(x: 0.9703, y: 0.3581), CGPoint(x: 0.9798, y: 0.3730), CGPoint(x: 0.9876, y: 0.3889), CGPoint(x: 0.9935, y: 0.4055),
        CGPoint(x: 0.9976, y: 0.4227), CGPoint(x: 0.9997, y: 0.4403), CGPoint(x: 0.9998, y: 0.4580), CGPoint(x: 0.9979, y: 0.4756),
        CGPoint(x: 0.9940, y: 0.4928), CGPoint(x: 0.9883, y: 0.5096), CGPoint(x: 0.9807, y: 0.5255), CGPoint(x: 0.9717, y: 0.5408),
        CGPoint(x: 0.9639, y: 0.5567), CGPoint(x: 0.9580, y: 0.5733), CGPoint(x: 0.9539, y: 0.5905), CGPoint(x: 0.9519, y: 0.6081),
        CGPoint(x: 0.9517, y: 0.6258), CGPoint(x: 0.9536, y: 0.6434), CGPoint(x: 0.9569, y: 0.6608), CGPoint(x: 0.9585, y: 0.6784),
        CGPoint(x: 0.9582, y: 0.6960), CGPoint(x: 0.9559, y: 0.7136), CGPoint(x: 0.9517, y: 0.7307), CGPoint(x: 0.9455, y: 0.7473),
        CGPoint(x: 0.9376, y: 0.7631), CGPoint(x: 0.9279, y: 0.7779), CGPoint(x: 0.9166, y: 0.7915), CGPoint(x: 0.9038, y: 0.8038),
        CGPoint(x: 0.8898, y: 0.8145), CGPoint(x: 0.8746, y: 0.8236), CGPoint(x: 0.8586, y: 0.8310), CGPoint(x: 0.8419, y: 0.8369),
        CGPoint(x: 0.8257, y: 0.8441), CGPoint(x: 0.8105, y: 0.8530), CGPoint(x: 0.7963, y: 0.8636), CGPoint(x: 0.7834, y: 0.8757),
        CGPoint(x: 0.7719, y: 0.8892), CGPoint(x: 0.7621, y: 0.9039), CGPoint(x: 0.7534, y: 0.9193), CGPoint(x: 0.7433, y: 0.9338),
        CGPoint(x: 0.7317, y: 0.9471), CGPoint(x: 0.7187, y: 0.9591), CGPoint(x: 0.7044, y: 0.9695), CGPoint(x: 0.6891, y: 0.9783),
        CGPoint(x: 0.6728, y: 0.9853), CGPoint(x: 0.6559, y: 0.9904), CGPoint(x: 0.6385, y: 0.9935), CGPoint(x: 0.6208, y: 0.9947),
        CGPoint(x: 0.6032, y: 0.9939), CGPoint(x: 0.5857, y: 0.9912), CGPoint(x: 0.5687, y: 0.9865), CGPoint(x: 0.5521, y: 0.9803),
        CGPoint(x: 0.5351, y: 0.9754), CGPoint(x: 0.5177, y: 0.9724), CGPoint(x: 0.5000, y: 0.9714), CGPoint(x: 0.4823, y: 0.9724),
        CGPoint(x: 0.4649, y: 0.9754), CGPoint(x: 0.4479, y: 0.9803), CGPoint(x: 0.4313, y: 0.9865), CGPoint(x: 0.4143, y: 0.9912),
        CGPoint(x: 0.3968, y: 0.9939), CGPoint(x: 0.3792, y: 0.9947), CGPoint(x: 0.3615, y: 0.9935), CGPoint(x: 0.3441, y: 0.9904),
        CGPoint(x: 0.3272, y: 0.9853), CGPoint(x: 0.3109, y: 0.9783), CGPoint(x: 0.2956, y: 0.9695), CGPoint(x: 0.2813, y: 0.9591),
        CGPoint(x: 0.2683, y: 0.9471), CGPoint(x: 0.2567, y: 0.9338), CGPoint(x: 0.2466, y: 0.9193), CGPoint(x: 0.2379, y: 0.9039),
        CGPoint(x: 0.2281, y: 0.8892), CGPoint(x: 0.2166, y: 0.8757), CGPoint(x: 0.2037, y: 0.8636), CGPoint(x: 0.1895, y: 0.8530),
        CGPoint(x: 0.1743, y: 0.8441), CGPoint(x: 0.1581, y: 0.8369), CGPoint(x: 0.1414, y: 0.8310), CGPoint(x: 0.1254, y: 0.8236),
        CGPoint(x: 0.1102, y: 0.8145), CGPoint(x: 0.0962, y: 0.8038), CGPoint(x: 0.0834, y: 0.7915), CGPoint(x: 0.0721, y: 0.7779),
        CGPoint(x: 0.0624, y: 0.7631), CGPoint(x: 0.0545, y: 0.7473), CGPoint(x: 0.0483, y: 0.7307), CGPoint(x: 0.0441, y: 0.7136),
        CGPoint(x: 0.0418, y: 0.6960), CGPoint(x: 0.0415, y: 0.6784), CGPoint(x: 0.0431, y: 0.6608), CGPoint(x: 0.0464, y: 0.6434),
        CGPoint(x: 0.0483, y: 0.6258), CGPoint(x: 0.0481, y: 0.6081), CGPoint(x: 0.0461, y: 0.5905), CGPoint(x: 0.0420, y: 0.5733),
        CGPoint(x: 0.0361, y: 0.5567), CGPoint(x: 0.0283, y: 0.5408), CGPoint(x: 0.0193, y: 0.5255), CGPoint(x: 0.0117, y: 0.5096),
        CGPoint(x: 0.0060, y: 0.4928), CGPoint(x: 0.0021, y: 0.4756), CGPoint(x: 0.0002, y: 0.4580), CGPoint(x: 0.0003, y: 0.4403),
        CGPoint(x: 0.0024, y: 0.4227), CGPoint(x: 0.0065, y: 0.4055), CGPoint(x: 0.0124, y: 0.3889), CGPoint(x: 0.0202, y: 0.3730),
        CGPoint(x: 0.0297, y: 0.3581), CGPoint(x: 0.0409, y: 0.3444), CGPoint(x: 0.0534, y: 0.3319), CGPoint(x: 0.0671, y: 0.3207),
        CGPoint(x: 0.0798, y: 0.3084), CGPoint(x: 0.0911, y: 0.2948), CGPoint(x: 0.1008, y: 0.2800), CGPoint(x: 0.1088, y: 0.2642),
        CGPoint(x: 0.1149, y: 0.2476), CGPoint(x: 0.1192, y: 0.2305), CGPoint(x: 0.1221, y: 0.2130), CGPoint(x: 0.1266, y: 0.1959),
        CGPoint(x: 0.1329, y: 0.1794), CGPoint(x: 0.1411, y: 0.1637), CGPoint(x: 0.1509, y: 0.1490), CGPoint(x: 0.1623, y: 0.1356),
        CGPoint(x: 0.1752, y: 0.1234), CGPoint(x: 0.1894, y: 0.1129), CGPoint(x: 0.2047, y: 0.1039), CGPoint(x: 0.2208, y: 0.0968),
        CGPoint(x: 0.2377, y: 0.0915), CGPoint(x: 0.2551, y: 0.0881), CGPoint(x: 0.2727, y: 0.0867), CGPoint(x: 0.2904, y: 0.0868),
        CGPoint(x: 0.3080, y: 0.0856), CGPoint(x: 0.3254, y: 0.0824), CGPoint(x: 0.3424, y: 0.0774), CGPoint(x: 0.3586, y: 0.0704),
        CGPoint(x: 0.3740, y: 0.0616), CGPoint(x: 0.3882, y: 0.0512), CGPoint(x: 0.4017, y: 0.0397), CGPoint(x: 0.4161, y: 0.0295),
        CGPoint(x: 0.4316, y: 0.0209), CGPoint(x: 0.4479, y: 0.0141), CGPoint(x: 0.4649, y: 0.0092), CGPoint(x: 0.4823, y: 0.0062),
    ]
    static let clover: [CGPoint] = [
        CGPoint(x: 0.7007, y: 0.0000), CGPoint(x: 0.7384, y: 0.0027), CGPoint(x: 0.7754, y: 0.0100), CGPoint(x: 0.8112, y: 0.0218),
        CGPoint(x: 0.8453, y: 0.0381), CGPoint(x: 0.8770, y: 0.0585), CGPoint(x: 0.9059, y: 0.0827), CGPoint(x: 0.9317, y: 0.1103),
        CGPoint(x: 0.9537, y: 0.1409), CGPoint(x: 0.9718, y: 0.1740), CGPoint(x: 0.9856, y: 0.2091), CGPoint(x: 0.9949, y: 0.2457),
        CGPoint(x: 0.9994, y: 0.2832), CGPoint(x: 0.9993, y: 0.3209), CGPoint(x: 0.9944, y: 0.3584), CGPoint(x: 0.9849, y: 0.3949),
        CGPoint(x: 0.9710, y: 0.4299), CGPoint(x: 0.9527, y: 0.4629), CGPoint(x: 0.9307, y: 0.4936), CGPoint(x: 0.9437, y: 0.5237),
        CGPoint(x: 0.9637, y: 0.5557), CGPoint(x: 0.9795, y: 0.5900), CGPoint(x: 0.9910, y: 0.6259), CGPoint(x: 0.9978, y: 0.6630),
        CGPoint(x: 1.0000, y: 0.7007), CGPoint(x: 0.9973, y: 0.7384), CGPoint(x: 0.9900, y: 0.7754), CGPoint(x: 0.9782, y: 0.8112),
        CGPoint(x: 0.9619, y: 0.8453), CGPoint(x: 0.9415, y: 0.8770), CGPoint(x: 0.9173, y: 0.9059), CGPoint(x: 0.8897, y: 0.9317),
        CGPoint(x: 0.8591, y: 0.9537), CGPoint(x: 0.8260, y: 0.9718), CGPoint(x: 0.7909, y: 0.9856), CGPoint(x: 0.7543, y: 0.9949),
        CGPoint(x: 0.7168, y: 0.9994), CGPoint(x: 0.6791, y: 0.9993), CGPoint(x: 0.6416, y: 0.9944), CGPoint(x: 0.6051, y: 0.9849),
        CGPoint(x: 0.5701, y: 0.9710), CGPoint(x: 0.5371, y: 0.9527), CGPoint(x: 0.5064, y: 0.9307), CGPoint(x: 0.4763, y: 0.9437),
        CGPoint(x: 0.4443, y: 0.9637), CGPoint(x: 0.4100, y: 0.9795), CGPoint(x: 0.3741, y: 0.9910), CGPoint(x: 0.3370, y: 0.9978),
        CGPoint(x: 0.2993, y: 1.0000), CGPoint(x: 0.2616, y: 0.9973), CGPoint(x: 0.2246, y: 0.9900), CGPoint(x: 0.1888, y: 0.9782),
        CGPoint(x: 0.1547, y: 0.9619), CGPoint(x: 0.1230, y: 0.9415), CGPoint(x: 0.0941, y: 0.9173), CGPoint(x: 0.0683, y: 0.8897),
        CGPoint(x: 0.0463, y: 0.8591), CGPoint(x: 0.0282, y: 0.8260), CGPoint(x: 0.0144, y: 0.7909), CGPoint(x: 0.0051, y: 0.7543),
        CGPoint(x: 0.0006, y: 0.7168), CGPoint(x: 0.0007, y: 0.6791), CGPoint(x: 0.0056, y: 0.6416), CGPoint(x: 0.0151, y: 0.6051),
        CGPoint(x: 0.0290, y: 0.5701), CGPoint(x: 0.0473, y: 0.5371), CGPoint(x: 0.0693, y: 0.5064), CGPoint(x: 0.0563, y: 0.4763),
        CGPoint(x: 0.0363, y: 0.4443), CGPoint(x: 0.0205, y: 0.4100), CGPoint(x: 0.0090, y: 0.3741), CGPoint(x: 0.0022, y: 0.3370),
        CGPoint(x: 0.0000, y: 0.2993), CGPoint(x: 0.0027, y: 0.2616), CGPoint(x: 0.0100, y: 0.2246), CGPoint(x: 0.0218, y: 0.1888),
        CGPoint(x: 0.0381, y: 0.1547), CGPoint(x: 0.0585, y: 0.1230), CGPoint(x: 0.0827, y: 0.0941), CGPoint(x: 0.1103, y: 0.0683),
        CGPoint(x: 0.1409, y: 0.0463), CGPoint(x: 0.1740, y: 0.0282), CGPoint(x: 0.2091, y: 0.0144), CGPoint(x: 0.2457, y: 0.0051),
        CGPoint(x: 0.2832, y: 0.0006), CGPoint(x: 0.3209, y: 0.0007), CGPoint(x: 0.3584, y: 0.0056), CGPoint(x: 0.3949, y: 0.0151),
        CGPoint(x: 0.4299, y: 0.0290), CGPoint(x: 0.4629, y: 0.0473), CGPoint(x: 0.4936, y: 0.0693), CGPoint(x: 0.5237, y: 0.0563),
        CGPoint(x: 0.5557, y: 0.0363), CGPoint(x: 0.5900, y: 0.0205), CGPoint(x: 0.6259, y: 0.0090), CGPoint(x: 0.6630, y: 0.0022),
    ]
}

/// The status-card wave (_StatusWavePainter): exact cubic path across
/// the right ~46% of the card, in fractions of the card size.
struct StatusWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0.540 * w, y: 0))
        path.addCurve(to: CGPoint(x: 0.521 * w, y: 0.200 * h),
                      control1: CGPoint(x: 0.532 * w, y: 0.056 * h),
                      control2: CGPoint(x: 0.565 * w, y: 0.103 * h))
        path.addCurve(to: CGPoint(x: 0.541 * w, y: 0.445 * h),
                      control1: CGPoint(x: 0.478 * w, y: 0.295 * h),
                      control2: CGPoint(x: 0.525 * w, y: 0.365 * h))
        path.addCurve(to: CGPoint(x: 0.555 * w, y: 0.660 * h),
                      control1: CGPoint(x: 0.562 * w, y: 0.540 * h),
                      control2: CGPoint(x: 0.502 * w, y: 0.608 * h))
        path.addCurve(to: CGPoint(x: 0.638 * w, y: 0.771 * h),
                      control1: CGPoint(x: 0.586 * w, y: 0.693 * h),
                      control2: CGPoint(x: 0.629 * w, y: 0.683 * h))
        path.addCurve(to: CGPoint(x: 0.727 * w, y: 0.848 * h),
                      control1: CGPoint(x: 0.648 * w, y: 0.868 * h),
                      control2: CGPoint(x: 0.686 * w, y: 0.867 * h))
        path.addCurve(to: CGPoint(x: 0.833 * w, y: 0.927 * h),
                      control1: CGPoint(x: 0.776 * w, y: 0.825 * h),
                      control2: CGPoint(x: 0.774 * w, y: 0.929 * h))
        path.addCurve(to: CGPoint(x: 0.946 * w, y: 0.850 * h),
                      control1: CGPoint(x: 0.887 * w, y: 0.925 * h),
                      control2: CGPoint(x: 0.879 * w, y: 0.831 * h))
        path.addCurve(to: CGPoint(x: w, y: 0.842 * h),
                      control1: CGPoint(x: 0.974 * w, y: 0.862 * h),
                      control2: CGPoint(x: 0.988 * w, y: 0.858 * h))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        return path
    }
}

/// The start toggle morph (_StartToggle): interpolates circle (stopped)
/// to cookie9Sided (running) by lerping matching arc-length samples.
/// Rotation (progress x 40 degrees) is applied by the caller, as in
/// _MorphPainter; the glyph is a separate view on top and does not rotate.
struct StartToggleMorphShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = FlClashShapes.morphCircle.count
        var path = Path()
        for i in 0..<count {
            let c = FlClashShapes.morphCircle[i]
            let s = FlClashShapes.morphStar[i]
            let x = (c.x + (s.x - c.x) * progress) * rect.width
            let y = (c.y + (s.y - c.y) * progress) * rect.height
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

/// The country badge shape (MaterialShapes.clover4Leaf), drawn in the
/// unit square; the caller rotates it 45 degrees and centres the glyph
/// or country code on top, upright.
struct CloverShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts = FlClashShapes.clover
        var path = Path()
        for (i, p) in pts.enumerated() {
            let point = CGPoint(x: p.x * rect.width, y: p.y * rect.height)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
