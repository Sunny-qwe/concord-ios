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
    /// 列表与卡片样式里组头的图标：色块（圆角底 + 图标）、纯图标
    /// （只有图标）、隐藏。图标来自配置里的 icon 或用户在设置 →
    /// 图标源导入的图标包（按组名匹配），都没有时显示组名首字；
    /// 没有内置品牌图标（v0.2.53，用户要求自行添加）。
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

// MARK: - Group icon pack (user-supplied JSON source, v0.2.53)
//
// The user pastes the URL of an icon-pack JSON file (iBL3ND format:
// {"name": "...", "description": "...", "icons": [{"name": "...",
// "url": "https://...png"}, ...]}) in Settings → 图标源 and taps
// 导入 / 更新. There are NO bundled brand icons: the pack is the
// only icon source besides a group's own profile icon, and the
// monogram is the only fallback. The source URL and the downloaded
// name→URL map are persisted in UserDefaults under
// "ConcordiOS.iconPack.v1" (one JSON blob). The download happens
// ONLY when the user taps 导入 / 更新 — never on launch, never in
// the background. The map is read on the Proxies page only, never
// by the tunnel extension. A failed import never wipes the
// previously imported pack.

final class IconPackStore: ObservableObject {
    static let shared = IconPackStore()

    private static let storageKey = "ConcordiOS.iconPack.v1"
    private static let defaults = UserDefaults.standard

    /// The imported pack's display name (the JSON's top-level
    /// "name"), nil when no pack is active.
    @Published private(set) var packName: String?
    /// Number of usable icons in the active pack.
    @Published private(set) var iconCount = 0
    /// When the active pack was last imported.
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isImporting = false
    /// The last import failure, shown inline in Settings. Cleared
    /// on the next import attempt.
    @Published private(set) var errorMessage: String?
    /// A non-error import note (e.g. "imported N icons, skipped M
    /// invalid entries"), shown in secondary text.
    @Published private(set) var noticeMessage: String?
    /// The URL field content in Settings. Seeded from the stored
    /// source URL (empty when no pack was ever imported). Editing
    /// it changes nothing until 导入 / 更新 is tapped.
    @Published var urlText = ""

    /// Usable entries in file order (exact names deduped,
    /// first duplicate wins). The source of truth; the lookup
    /// maps below are rebuilt from it on load and on import.
    private var orderedIcons: [StoredEntry] = []
    private var exactMap: [String: String] = [:]
    private var lowerMap: [String: String] = [:]
    private var normMap: [String: String] = [:]
    private var orderedNorm: [(norm: String, url: String)] = []

    private struct StoredPack: Codable {
        var url: String
        var name: String?
        var icons: [StoredEntry]
        var fetchedAt: Date
    }

    private struct StoredEntry: Codable {
        var name: String
        var url: String
    }

    private struct PackFile: Decodable {
        var name: String?
        var icons: [PackEntry]?
    }

    private struct PackEntry: Decodable {
        var name: String?
        var url: String?
    }

    private init() {
        if let data = Self.defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(StoredPack.self, from: data) {
            urlText = stored.url
            apply(stored: stored)
        }
    }

    private func apply(stored: StoredPack) {
        orderedIcons = stored.icons
        packName = stored.name
        iconCount = stored.icons.count
        fetchedAt = stored.fetchedAt
        rebuildDerived()
    }

    private func rebuildDerived() {
        var exact: [String: String] = [:]
        var lower: [String: String] = [:]
        var norm: [String: String] = [:]
        var ordered: [(String, String)] = []
        for entry in orderedIcons {
            exact[entry.name] = entry.url
            let low = entry.name.lowercased()
            if lower[low] == nil { lower[low] = entry.url }
            let n = Self.normalize(entry.name)
            if norm[n] == nil { norm[n] = entry.url }
            ordered.append((n, entry.url))
        }
        exactMap = exact
        lowerMap = lower
        normMap = norm
        orderedNorm = ordered
    }

    /// Normalizes a name for matching: lowercase, keep only
    /// letters and digits (Unicode-aware, so Chinese characters
    /// survive) — spaces, punctuation, emoji and symbols are
    /// dropped. "YouTube 油管" → "youtube油管", "Egern 松鼠 🐿️" →
    /// "egern松鼠", "苹果  🍎iPhone" → "苹果iphone".
    static func normalize(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.append(Character(scalar))
        }
        return out
    }

    /// Resolves a group's icon URL from the imported pack, or nil.
    /// (a) exact name match; (b) case-insensitive exact match;
    /// (c) normalized exact match; (d) normalized prefix match
    /// first (either direction), then normalized contains (either
    /// direction), scanning in file order — so group "YouTube"
    /// matches pack entry "YouTube 油管". First duplicate wins at
    /// every step. An empty normalized group name never matches:
    /// an empty string is contained in everything. Step (d) also
    /// requires both sides to be at least 2 characters: a
    /// single-character name would match almost anything ("x" is
    /// contained in "netflix"), and 1-character names are already
    /// handled exactly by (a)–(c) above.
    func iconURL(for groupName: String) -> URL? {
        if let raw = exactMap[groupName], let url = URL(string: raw) { return url }
        let lower = groupName.lowercased()
        if let raw = lowerMap[lower], let url = URL(string: raw) { return url }
        let norm = Self.normalize(groupName)
        guard !norm.isEmpty else { return nil }
        if let raw = normMap[norm], let url = URL(string: raw) { return url }
        guard norm.count >= 2 else { return nil }
        for (n, raw) in orderedNorm where n.count >= 2 && (n.hasPrefix(norm) || norm.hasPrefix(n)) {
            if let url = URL(string: raw) { return url }
        }
        for (n, raw) in orderedNorm where n.count >= 2 && (n.contains(norm) || norm.contains(n)) {
            if let url = URL(string: raw) { return url }
        }
        return nil
    }

    /// Downloads the pack from the URL in `urlText` and replaces
    /// the stored pack on success. Runs only from the Settings
    /// button — never on launch, never in the background.
    @MainActor
    func importPack() async {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = "链接无效：请输入 http:// 或 https:// 开头的图标源链接"
            noticeMessage = nil
            return
        }
        isImporting = true
        errorMessage = nil
        noticeMessage = nil
        defer { isImporting = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "下载失败：服务器没有返回有效的响应"
                return
            }
            guard http.statusCode == 200 else {
                errorMessage = "下载失败：服务器返回状态码 \(http.statusCode)"
                return
            }
            guard let file = try? JSONDecoder().decode(PackFile.self, from: data),
                  let entries = file.icons, !entries.isEmpty else {
                errorMessage = "这个文件不是图标源：找不到 icons 列表"
                return
            }
            var ordered: [StoredEntry] = []
            var seenExact = Set<String>()
            var skipped = 0
            for entry in entries {
                guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let link = entry.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let linkURL = URL(string: link),
                      let linkScheme = linkURL.scheme?.lowercased(),
                      linkScheme == "http" || linkScheme == "https" else {
                    skipped += 1
                    continue
                }
                // First duplicate wins.
                guard seenExact.insert(name).inserted else { continue }
                ordered.append(StoredEntry(name: name, url: link))
            }
            guard !ordered.isEmpty else {
                errorMessage = "这个图标源里没有可用的图标（条目缺少名称或链接）"
                return
            }
            let stored = StoredPack(url: raw, name: file.name, icons: ordered, fetchedAt: Date())
            if let blob = try? JSONEncoder().encode(stored) {
                Self.defaults.set(blob, forKey: Self.storageKey)
            }
            urlText = raw
            apply(stored: stored)
            if skipped > 0 {
                noticeMessage = "已导入 \(ordered.count) 个图标，跳过 \(skipped) 条无效条目"
            }
        } catch let error as URLError {
            errorMessage = "下载失败：\(Self.urlErrorMessage(error))"
        } catch {
            errorMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    /// Clears the stored pack. The link text stays in the field,
    /// so one tap on 导入 brings the pack back; only the stored
    /// source is removed (the field is empty again on next launch).
    @MainActor
    func clearPack() {
        orderedIcons = []
        exactMap = [:]
        lowerMap = [:]
        normMap = [:]
        orderedNorm = []
        packName = nil
        iconCount = 0
        fetchedAt = nil
        errorMessage = nil
        noticeMessage = nil
        Self.defaults.removeObject(forKey: Self.storageKey)
    }

    private static func urlErrorMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "网络未连接"
        case .timedOut: return "下载超时（20 秒）"
        case .cannotFindHost, .cannotConnectToHost: return "找不到服务器，请检查链接"
        case .networkConnectionLost: return "网络连接中断"
        case .cancelled: return "已取消"
        default: return error.localizedDescription
        }
    }
}
