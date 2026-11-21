import CoreGraphics
import Combine
import Foundation

// MARK: - Proxies page style (FlClash: ProxiesStyleProps,
// lib/models/config.dart)
// The 代理 page's display options, persisted in UserDefaults:
// style (tab / list), sort, layout (grid columns), card size, icon
// style (group headers in list style) and hide-timeout. Defaults
// match FlClash (ProxiesStyleProps, models/config.dart:423): list
// style, standard layout and card size, filled icons, show every node.
// A stored value always wins over the default, so a user who picked
// 标签页 keeps it; only never-set installs change to 列表.

enum ProxySort: String, CaseIterable, Identifiable {
    case `default` = "默认"
    case delay = "延迟"
    case name = "名称"
    var id: String { rawValue }
}

final class ProxyStyleStore: ObservableObject {
    /// 标签页：一次看一组（顶部切换组）；列表：所有组上下排布，可折叠；
    /// 卡片（MuYu iOS build, v0.9.4-ios 新增的第三种风格，上游 FlClash
    /// 0.9.3 没有）：组以两列卡片网格排布，卡片上有品牌图标与
    /// “TYPE · n/m” 及当前节点行，顶部有文件夹筛选栏。
    enum Style: String, CaseIterable {
        case tab, list, icons
        var label: String {
            switch self {
            case .tab: return "标签页"
            case .list: return "列表"
            case .icons: return "卡片"
            }
        }
    }
    /// 列数（FlClash getProxiesColumns）：手机宽度下紧凑 3 列、
    /// 标准 2 列、宽松 1 列。Case 顺序即 ⋯ 子菜单里的顺序
    /// （FlClash enum.dart:213：loose, standard, tight）。
    enum Layout: String, CaseIterable {
        case loose = "宽松"
        case standard = "标准"
        case tight = "紧凑"
    }
    /// 卡片内容：紧凑只显示一行名称；标准两行名称；宽松再加一行
    /// 描述（类型，组节点显示它当前选中的节点）。Case 顺序即
    /// ⋯ 子菜单里的顺序（FlClash enum.dart:215：
    /// loose, standard, compact）。
    enum CardType: String, CaseIterable {
        case loose = "宽松"
        case standard = "标准"
        case compact = "紧凑"
    }
    /// 列表与卡片样式里组头的图标：色块（圆角底 + 首字）、纯图标
    /// （只有首字）、隐藏。卡片样式里图标是组卡片右上角的大品牌
    /// 图标（MuYu icon_card.dart _GroupBrandIcon）。
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
        style = Style(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.style") ?? "") ?? .list
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

    /// Re-reads the persisted keys (audit B8: after a backup restore
    /// the keys change behind this instance's back; the Proxies page
    /// must show the restored style without restarting the app).
    /// The didSet save() on each property writes the same values
    /// back — harmless.
    func reload() {
        style = Style(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.style") ?? "") ?? .list
        sort = ProxySort(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.sort") ?? "") ?? .default
        layout = Layout(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.layout") ?? "") ?? .standard
        cardType = CardType(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.cardType") ?? "") ?? .standard
        iconStyle = IconStyle(rawValue: Self.defaults.string(forKey: "ConcordiOS.proxies.iconStyle") ?? "") ?? .filled
        hideTimeout = Self.defaults.bool(forKey: "ConcordiOS.proxies.hideTimeout")
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
