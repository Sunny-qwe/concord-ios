import Foundation
import Combine

// MARK: - Custom proxies + filter overrides (FlClash: Tools ->
// 进阶配置 -> 代理 / 过滤器)
// FlClash keeps custom proxies and per-group filters in its own
// database and merges them into the config it builds. Concord's
// config.apply overlay does NOT carry proxies (the profile owns
// them — see PacketTunnelProvider's header comment), so on iOS the
// equivalent is: store the proxies here (App Group
// custom-proxies.json), and bake them into the active profile's
// YAML under `proxies:` — between `# concord-ios 自定义代理 开始`
// and `# concord-ios 自定义代理 结束` markers, so they can be
// removed and re-inserted cleanly. ProfileStore re-applies them
// after every subscription update of the active profile, so a
// subscription refresh never loses them. The same marker trick
// applies per-group `filter:` overrides (filter-overrides.json).

struct CustomProxy: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: String
    var server: String
    var port: Int
    var password: String
    var uuid: String
    var cipher: String
    var tls: Bool
    var sni: String
    var network: String
    var udp: Bool

    init(id: String = UUID().uuidString, name: String = "", type: String = "ss",
         server: String = "", port: Int = 0, password: String = "",
         uuid: String = "", cipher: String = "", tls: Bool = false,
         sni: String = "", network: String = "", udp: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.password = password
        self.uuid = uuid
        self.cipher = cipher
        self.tls = tls
        self.sni = sni
        self.network = network
        self.udp = udp
    }

    static let types = ["ss", "vmess", "vless", "trojan", "socks5", "http", "hysteria2", "tuic"]

    /// The YAML mapping for this proxy, as it appears under
    /// `proxies:` in the profile (2-space indent, list item).
    func yamlLines() -> [String] {
        var lines: [String] = ["  - name: \(Self.quote(name))", "    type: \(type)"]
        if !server.isEmpty { lines.append("    server: \(Self.quote(server))") }
        if port > 0 { lines.append("    port: \(port)") }
        switch type {
        case "ss":
            if !password.isEmpty { lines.append("    password: \(Self.quote(password))") }
            if !cipher.isEmpty { lines.append("    cipher: \(Self.quote(cipher))") }
        case "vmess", "vless":
            if !uuid.isEmpty { lines.append("    uuid: \(Self.quote(uuid))") }
            if type == "vmess", !cipher.isEmpty { lines.append("    cipher: \(Self.quote(cipher))") }
            if tls { lines.append("    tls: true") }
            if !sni.isEmpty { lines.append("    servername: \(Self.quote(sni))") }
            if !network.isEmpty { lines.append("    network: \(network)") }
        case "trojan":
            if !password.isEmpty { lines.append("    password: \(Self.quote(password))") }
            if !sni.isEmpty { lines.append("    sni: \(Self.quote(sni))") }
        case "socks5", "http":
            if !password.isEmpty { lines.append("    password: \(Self.quote(password))") }
        case "hysteria2", "tuic":
            if !password.isEmpty { lines.append("    password: \(Self.quote(password))") }
            if !sni.isEmpty { lines.append("    sni: \(Self.quote(sni))") }
        default:
            break
        }
        if udp { lines.append("    udp: true") }
        return lines
    }

    /// Quote a YAML scalar when it needs it (special characters,
    /// leading/trailing spaces, or a value that would parse as a
    /// non-string).
    static func quote(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value != value.trimmingCharacters(in: .whitespaces)
            || value.contains(": ") || value.contains(" #")
            || value.hasPrefix("-") || value.hasPrefix("#")
            || value.hasPrefix("\"") || value.hasPrefix("'")
            || value.contains("\n")
            || ["true", "false", "null", "~", "yes", "no", "on", "off"].contains(value.lowercased())
            || Int(value) != nil || Double(value) != nil
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

final class CustomProxyStore: ObservableObject {
    @Published var proxies: [CustomProxy] = []
    /// Per-group filter overrides: group name -> filter expression.
    /// Per-group filter overrides: group name -> filter expression.
    @Published var filterOverrides: [String: String] = [:]

    /// Full node definitions added from the 代理 page ("添加到本地
    /// 节点", FlClash addToLocalProxies): the definition as the core
    /// wrote it (proxy.definition), kept whole — ws-opts, grpc-opts,
    /// reality-opts, flow, alpn — so the baked node behaves exactly
    /// like the original. The form proxies above are a subset (name /
    /// server / port / uuid / password / cipher / tls / sni /
    /// network / udp) and cannot express those keys, so definitions
    /// live here instead of being squeezed into CustomProxy.
    @Published var rawProxies: [JSONValue] = []

    static let beginMarker = "# concord-ios 自定义代理 开始"
    static let endMarker = "# concord-ios 自定义代理 结束"

    private var proxiesURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.customProxiesFileName)
    }

    private var filtersURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.filterOverridesFileName)
    }

    private var rawProxiesURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.rawProxiesFileName)
    }

    init() { load() }

    func load() {
        if let url = proxiesURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CustomProxy].self, from: data) {
            proxies = decoded
        }
        if let url = filtersURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            filterOverrides = decoded
        }
        if let url = rawProxiesURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) {
            rawProxies = decoded
        }
    }

    func save() {
        if let url = proxiesURL, let data = try? JSONEncoder().encode(proxies) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if let url = filtersURL, let data = try? JSONEncoder().encode(filterOverrides) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if let url = rawProxiesURL, let data = try? JSONEncoder().encode(rawProxies) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Append imported node definitions to the raw store (v0.2.147,
    /// upstream CustomProfileImport proxies): definitions the
    /// importer already deduped and renamed, so this only guards
    /// against a double save (same name already held) before
    /// writing. The definitions bake verbatim into the active
    /// profile's `proxies:` section via bakeCurrent.
    func addRawProxies(_ definitions: [JSONValue]) {
        guard !definitions.isEmpty else { return }
        var changed = false
        for definition in definitions {
            guard case .object(let dict) = definition,
                  case .string(let name) = dict["name"], !name.isEmpty else { continue }
            guard !rawProxies.contains(where: {
                guard case .object(let held) = $0,
                      case .string(let heldName) = held["name"] else { return false }
                return heldName == name
            }) else { continue }
            rawProxies.append(definition)
            changed = true
        }
        if changed { save() }
    }

    /// Bake whatever is stored on disk right now (form proxies +
    /// raw definitions) into `text`. Every bake path must use this —
    /// a bake that only knew the form proxies would silently drop
    /// the raw definitions from the profile.
    static func bakeCurrent(into text: String) -> String {
        let store = CustomProxyStore()
        return bakeProxies(store.proxies, raw: store.rawProxies, into: text)
    }

    /// Insert (or re-insert) the custom proxies into a profile's
    /// YAML text: any previously inserted block is removed first,
    /// then the current list is written right after the `proxies:`
    /// line. When the profile has no `proxies:` key, or the list is
    /// empty, the text is returned with any stale block removed.
    static func bakeProxies(_ proxies: [CustomProxy], raw rawProxies: [JSONValue] = [], into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // Remove a previously baked block, if any.
        if let begin = lines.firstIndex(of: beginMarker),
           let end = lines.firstIndex(of: endMarker), end >= begin {
            lines.removeSubrange(begin...end)
        }
        guard !proxies.isEmpty || !rawProxies.isEmpty else { return lines.joined(separator: "\n") }
        guard let proxiesIndex = lines.firstIndex(where: { $0 == "proxies:" || $0.hasPrefix("proxies: ") }) else {
            return lines.joined(separator: "\n")
        }
        var block: [String] = [beginMarker]
        for proxy in proxies { block.append(contentsOf: proxy.yamlLines()) }
        for definition in rawProxies { block.append(contentsOf: YAMLValue.proxyItemLines(for: definition, indent: 2)) }
        block.append(endMarker)
        lines.insert(contentsOf: block, at: proxiesIndex + 1)
        return lines.joined(separator: "\n")
    }

    /// The group/proxy name on a `- name: ...` line, quotes
    /// stripped (same rule as CustomSubscriptionStore.exactName):
    /// "US" parses to US, `"US"` and `'US'` too.
    private static func exactName(from line: String, key: String = "- name:") -> String {
        guard let range = line.range(of: key) else { return "" }
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
            (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Apply stored filter overrides to a profile's YAML text: for
    /// each overridden group, the `filter:` line inside that group's
    /// block is replaced (or inserted after the group's `name:` line
    /// when it has none). The replacement is scoped to the group
    /// block (from its `- name:` line to the next list item or the
    /// end of the `proxy-groups:` section).
    static func bakeFilterOverrides(_ overrides: [String: String], into text: String) -> String {
        guard !overrides.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        for (group, filter) in overrides {
            // Exact-name match: a filter for "US" must not land on
            // the first "- name: US-2" (the old contains() match did
            // exactly that — audit B20). The name is parsed out of
            // the `- name:` line (quotes stripped) and compared
            // exactly; a flow-style `- {name: US}` line has no
            // `- name:` prefix and is skipped, like before.
            guard let nameIndex = lines.firstIndex(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- name:") && Self.exactName(from: trimmed) == group
            }) else { continue }
            var end = lines.count
            for i in (nameIndex + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- name:") || (!trimmed.hasPrefix(" ") && !trimmed.isEmpty && !lines[i].hasPrefix(" ")) {
                    end = i
                    break
                }
            }
            if let filterIndex = (nameIndex..<end).first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("filter:")
            }) {
                lines[filterIndex] = "    filter: \(CustomProxy.quote(filter))"
            } else {
                lines.insert("    filter: \(CustomProxy.quote(filter))", at: nameIndex + 1)
            }
        }
        return lines.joined(separator: "\n")
    }
}
