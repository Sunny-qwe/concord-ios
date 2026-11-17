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

enum ConcordTheme {
    /// Page background: the system grouped background — #F2F2F7 in
    /// light mode, dark in dark mode. (ThemeStore drives the colour
    /// scheme; these semantic colours follow it automatically.)
    static let pageBackground = Color(.systemGroupedBackground)
    /// Card background: secondary system grouped background — white
    /// in light mode, dark grey in dark mode.
    static let cardBackground = Color(.secondarySystemGroupedBackground)
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
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.cardRadius))
            .shadow(color: ConcordTheme.cardShadow, radius: 10, x: 0, y: 3)
    }
}

extension View {
    /// White card, corner radius 28, soft shadow.
    func concordCard(padding: CGFloat = 20) -> some View {
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(.label))
            Text(title)
                .font(.headline)
            Spacer()
        }
    }
}

// MARK: - Pale capsule badge ("未运行" grey, "全部可用" green, "11 超时" orange)

struct PillBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
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
                .font(.system(size: size * 0.36, weight: .semibold))
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
}
