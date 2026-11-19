import CoreGraphics
import Combine
import Foundation

// MARK: - Proxies page style (FlClash: ProxiesStyleProps,
// lib/models/config.dart)
// The 代理 page's display options, persisted in UserDefaults:
// style (tab / list), sort, layout (grid columns), card size, icon
// style (group headers in list style) and hide-timeout. Defaults
// match the page as it was: tab style, standard layout and card
// size, filled icons, show every node.

enum ProxySort: String, CaseIterable, Identifiable {
    case `default` = "默认"
    case delay = "延迟"
    case name = "名称"
    var id: String { rawValue }
}

final class ProxyStyleStore: ObservableObject {
    /// 标签页：一次看一组（顶部切换组）；列表：所有组上下排布，可折叠。
    enum Style: String, CaseIterable {
        case tab, list
        var label: String { self == .tab ? "标签页" : "列表" }
    }
    /// 列数（FlClash getProxiesColumns）：手机宽度下紧凑 3 列、
    /// 标准 2 列、宽松 1 列。
    enum Layout: String, CaseIterable {
        case tight = "紧凑"
        case standard = "标准"
        case loose = "宽松"
    }
    /// 卡片内容：紧凑只显示一行名称；标准两行名称；宽松再加一行
    /// 描述（类型，组节点显示它当前选中的节点）。
    enum CardType: String, CaseIterable {
        case compact = "紧凑"
        case standard = "标准"
        case loose = "宽松"
    }
    /// 列表样式里组头的图标：色块（圆角底 + 首字）、纯图标
    /// （只有首字）、隐藏。
    enum IconStyle: String, CaseIterable {
        case filled = "色块"
        case plain = "纯图标"
        case hidden = "隐藏"
    }

    @Published var style: Style { didSet { save() } }
    @Published var sort: ProxySort { didSet { save() } }
    @Published var layout: Layout { didSet { save() } }
    @Published var cardType: CardType { didSet { save() } }
    @Published var iconStyle: IconStyle { didSet { save() } }
    @Published var hideTimeout: Bool { didSet { save() } }

    private static let defaults = UserDefaults.standard

    init() {
        style = Style(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.style") ?? "") ?? .tab
        sort = ProxySort(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.sort") ?? "") ?? .default
        layout = Layout(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.layout") ?? "") ?? .standard
        cardType = CardType(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.cardType") ?? "") ?? .standard
        iconStyle = IconStyle(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.iconStyle") ?? "") ?? .filled
        hideTimeout = Self.defaults.bool(forKey: "ConcordiOS.proxies.hideTimeout")
    }

    private func save() {
        Self.defaults.set(style.rawValue, forKey: "ConcordiOS.proxies.style")
        Self.defaults.set(sort.rawValue, forKey: "ConcordiOS.proxies.sort")
        Self.defaults.set(layout.rawValue, forKey: "ConcordiOS.proxies.layout")
        Self.defaults.set(cardType.rawValue, forKey: "ConcordiOS.proxies.cardType")
        Self.defaults.set(iconStyle.rawValue, forKey: "ConcordiOS.proxies.iconStyle")
        Self.defaults.set(hideTimeout, forKey: "ConcordiOS.proxies.hideTimeout")
    }

    /// Grid columns for the node cards (FlClash common/layout.dart
    /// getProxiesColumns): base = max(ceil((width - 32) / 250), 2);
    /// tight adds one column, loose takes one away (min 1).
    static func columns(for layout: Layout, width: CGFloat) -> Int {
        let base = max(Int(ceil((width - 32) / 250)), 2)
        switch layout {
        case .tight: return base + 1
        case .standard: return base
        case .loose: return max(base - 1, 1)
        }
    }
}
