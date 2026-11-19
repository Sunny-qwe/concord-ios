import Foundation
import Combine

// MARK: - Custom subscription (FlClash: lib/views/profiles/custom/)
// A full custom subscription: proxy groups (+ members), per-proxy
// dialers, proxy/rule providers and rules — beyond the node-only
// editing in CustomProxiesView. Stored as JSON in the App Group
// (custom-subscriptions.json), one entry per subscription; the
// editor bakes the chosen subscription into the ACTIVE profile's
// YAML (proxy-groups / proxy-providers / rule-providers / rules /
// dialer-proxy on proxies) through the existing profile apply path
// (ProfileStore.saveActiveProfileYAML + reapplyActive), so a
// subscription refresh of the underlying profile does not wipe it
// any more than the custom proxies it already re-bakes.

struct CustomGroup: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: String
    /// Member names: node names, other group names, DIRECT / REJECT…
    var members: [String]
    /// Provider names used by this group (`use:`).
    var useProviders: [String]
    var url: String
    var interval: Int
    var timeout: Int
    var tolerance: Int
    var lazy: Bool
    var hidden: Bool
    var disableUDP: Bool
    var filter: String
    var excludeFilter: String
    var strategy: String

    init(id: String = UUID().uuidString, name: String = "", type: String = "select",
         members: [String] = [], useProviders: [String] = [],
         url: String = "", interval: Int = 0, timeout: Int = 0, tolerance: Int = 0,
         lazy: Bool = false, hidden: Bool = false, disableUDP: Bool = false,
         filter: String = "", excludeFilter: String = "", strategy: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.members = members
        self.useProviders = useProviders
        self.url = url
        self.interval = interval
        self.timeout = timeout
        self.tolerance = tolerance
        self.lazy = lazy
        self.hidden = hidden
        self.disableUDP = disableUDP
        self.filter = filter
        self.excludeFilter = excludeFilter
        self.strategy = strategy
    }

    static let types = ["select", "url-test", "fallback", "load-balance", "relay", "direct", "reject"]
    static let strategies = ["consistent-hashing", "round-robin"]
    static let reservedTargets = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]
}

/// One proxy's dialer: traffic from `proxy` goes out through
/// `dialer` (FlClash custom/dialers.dart). Baked as `dialer-proxy:`
/// on the proxy's entry in the profile's `proxies:` section.
struct CustomDialer: Codable, Equatable, Identifiable {
    var id: String
    var proxy: String
    var dialer: String

    init(id: String = UUID().uuidString, proxy: String = "", dialer: String = "") {
        self.id = id
        self.proxy = proxy
        self.dialer = dialer
    }
}

/// A proxy-provider or rule-provider (FlClash custom/providers.dart).
struct CustomProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// "http" or "file".
    var kind: String
    var url: String
    var path: String
    var interval: Int
    var healthCheck: Bool
    var filter: String
    var excludeFilter: String

    init(id: String = UUID().uuidString, name: String = "", kind: String = "http",
         url: String = "", path: String = "", interval: Int = 0,
         healthCheck: Bool = false, filter: String = "", excludeFilter: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.path = path
        self.interval = interval
        self.healthCheck = healthCheck
        self.filter = filter
        self.excludeFilter = excludeFilter
    }

    static let kinds = ["http", "file"]
}

/// One rule (FlClash custom/rules.dart): "TYPE,CONTENT,TARGET"
/// with optional ",no-resolve" / ",src".
struct CustomRule: Codable, Equatable, Identifiable {
    var id: String
    var type: String
    var content: String
    var target: String
    var noResolve: Bool
    var src: Bool

    init(id: String = UUID().uuidString, type: String = "DOMAIN-SUFFIX",
         content: String = "", target: String = "DIRECT",
         noResolve: Bool = false, src: Bool = false) {
        self.id = id
        self.type = type
        self.content = content
        self.target = target
        self.noResolve = noResolve
        self.src = src
    }

    static let types = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
        "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6", "IP-ASN",
        "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "PROCESS-NAME",
        "PROCESS-PATH", "IN-TYPE", "RULE-SET", "MATCH", "FINAL",
    ]

    var text: String {
        if type == "MATCH" || type == "FINAL" { return "\(type),\(target)" }
        var line = "\(type),\(content),\(target)"
        if noResolve { line += ",no-resolve" }
        if src { line += ",src" }
        return line
    }
}

struct CustomSubscription: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var groups: [CustomGroup]
    var dialers: [CustomDialer]
    var proxyProviders: [CustomProvider]
    var ruleProviders: [CustomProvider]
    var rules: [CustomRule]

    init(id: UUID = UUID(), name: String = "", groups: [CustomGroup] = [],
         dialers: [CustomDialer] = [], proxyProviders: [CustomProvider] = [],
         ruleProviders: [CustomProvider] = [], rules: [CustomRule] = []) {
        self.id = id
        self.name = name
        self.groups = groups
        self.dialers = dialers
        self.proxyProviders = proxyProviders
        self.ruleProviders = ruleProviders
        self.rules = rules
    }
}

final class CustomSubscriptionStore: ObservableObject {
    @Published var subscriptions: [CustomSubscription] = []

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: "custom-subscriptions.json")
    }

    init() { load() }

    func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CustomSubscription].self, from: data) else { return }
        subscriptions = decoded
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(subscriptions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func create(name: String) -> CustomSubscription {
        let sub = CustomSubscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自定义订阅" : name)
        subscriptions.append(sub)
        save()
        return sub
    }

    func update(_ sub: CustomSubscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[index] = sub
        } else {
            subscriptions.append(sub)
        }
        save()
    }

    func delete(_ sub: CustomSubscription) {
        subscriptions.removeAll { $0.id == sub.id }
        save()
    }

    // MARK: - Baking into the active profile YAML

    static let groupsBegin = "# concord-ios 自定义分组 开始"
    static let groupsEnd = "# concord-ios 自定义分组 结束"
    static let proxyProvidersBegin = "# concord-ios 自定义代理提供方 开始"
    static let proxyProvidersEnd = "# concord-ios 自定义代理提供方 结束"
    static let ruleProvidersBegin = "# concord-ios 自定义规则提供方 开始"
    static let ruleProvidersEnd = "# concord-ios 自定义规则提供方 结束"
    static let rulesBegin = "# concord-ios 自定义规则 开始"
    static let rulesEnd = "# concord-ios 自定义规则 结束"

    /// Bake a custom subscription into profile YAML text: custom
    /// groups / providers / rules replace any previously baked
    /// block (marker-delimited, so re-baking never duplicates),
    /// and dialers set `dialer-proxy:` on the matching proxy
    /// entries. Sections that do not exist yet are created.
    static func bake(_ sub: CustomSubscription, into text: String) -> String {
        var result = text
        result = bakeSection(
            result, key: "proxy-groups:", begin: groupsBegin, end: groupsEnd,
            lines: sub.groups.flatMap { groupYAML($0) }
        )
        result = bakeSection(
            result, key: "proxy-providers:", begin: proxyProvidersBegin, end: proxyProvidersEnd,
            lines: sub.proxyProviders.flatMap { providerYAML($0) }
        )
        result = bakeSection(
            result, key: "rule-providers:", begin: ruleProvidersBegin, end: ruleProvidersEnd,
            lines: sub.ruleProviders.flatMap { providerYAML($0) }
        )
        result = bakeSection(
            result, key: "rules:", begin: rulesBegin, end: rulesEnd,
            lines: sub.rules.map { "  - \(CustomProxy.quote($0.text))" }
        )
        result = bakeDialers(sub.dialers, into: result)
        return result
    }

    /// Insert (or re-insert) a marker-delimited block right after
    /// the `key:` line; when the key is missing, append the whole
    /// section at the end. An empty block just removes the stale
    /// one.
    private static func bakeSection(
        _ text: String, key: String, begin: String, end: String,
        lines: [String]
    ) -> String {
        var out = text.components(separatedBy: "\n")
        if let beginIndex = out.firstIndex(of: begin),
           let endIndex = out.firstIndex(of: end), endIndex >= beginIndex {
            out.removeSubrange(beginIndex...endIndex)
        }
        guard !lines.isEmpty else { return out.joined(separator: "\n") }
        var block = [begin]
        block.append(contentsOf: lines)
        block.append(end)
        if let keyIndex = out.firstIndex(where: { $0 == key || $0.hasPrefix(key + " ") }) {
            out.insert(contentsOf: block, at: keyIndex + 1)
        } else {
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append(key)
            out.append(contentsOf: block)
        }
        return out.joined(separator: "\n")
    }

    private static func groupYAML(_ group: CustomGroup) -> [String] {
        var lines = ["  - name: \(CustomProxy.quote(group.name))", "    type: \(group.type)"]
        if !group.members.isEmpty {
            lines.append("    proxies:")
            lines.append(contentsOf: group.members.map { "      - \(CustomProxy.quote($0))" })
        }
        if !group.useProviders.isEmpty {
            lines.append("    use:")
            lines.append(contentsOf: group.useProviders.map { "      - \(CustomProxy.quote($0))" })
        }
        if !group.url.isEmpty { lines.append("    url: \(CustomProxy.quote(group.url))") }
        if group.interval > 0 { lines.append("    interval: \(group.interval)") }
        if group.timeout > 0 { lines.append("    timeout: \(group.timeout)") }
        if group.tolerance > 0 { lines.append("    tolerance: \(group.tolerance)") }
        if group.type == "load-balance" && !group.strategy.isEmpty { lines.append("    strategy: \(group.strategy)") }
        if group.lazy { lines.append("    lazy: true") }
        if group.hidden { lines.append("    hidden: true") }
        if group.disableUDP { lines.append("    disable-udp: true") }
        if !group.filter.isEmpty { lines.append("    filter: \(CustomProxy.quote(group.filter))") }
        if !group.excludeFilter.isEmpty { lines.append("    exclude-filter: \(CustomProxy.quote(group.excludeFilter))") }
        return lines
    }

    private static func providerYAML(_ provider: CustomProvider) -> [String] {
        var lines = ["  \(CustomProxy.quote(provider.name)):", "    type: \(provider.kind)"]
        if provider.kind == "http", !provider.url.isEmpty {
            lines.append("    url: \(CustomProxy.quote(provider.url))")
        } else if provider.kind == "file", !provider.path.isEmpty {
            lines.append("    path: \(CustomProxy.quote(provider.path))")
        }
        if provider.interval > 0 { lines.append("    interval: \(provider.interval)") }
        if provider.healthCheck { lines.append("    health-check: {enable: true}") }
        if !provider.filter.isEmpty { lines.append("    filter: \(CustomProxy.quote(provider.filter))") }
        if !provider.excludeFilter.isEmpty { lines.append("    exclude-filter: \(CustomProxy.quote(provider.excludeFilter))") }
        return lines
    }

    /// Set `dialer-proxy:` on the matching proxy entries inside
    /// the `proxies:` section (inserted after the entry's `name:`
    /// line, replacing an existing one).
    private static func bakeDialers(_ dialers: [CustomDialer], into text: String) -> String {
        guard !dialers.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let proxiesIndex = lines.firstIndex(where: { $0 == "proxies:" || $0.hasPrefix("proxies: ") }) else {
            return text
        }
        for dialer in dialers where !dialer.proxy.isEmpty && !dialer.dialer.isEmpty {
            guard let nameIndex = lines[(proxiesIndex + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- name:") &&
                $0.contains(dialer.proxy)
            }) else { continue }
            var end = lines.count
            for i in (nameIndex + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- name:") || (!lines[i].hasPrefix(" ") && !trimmed.isEmpty) {
                    end = i
                    break
                }
            }
            if let dialerIndex = (nameIndex..<end).first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("dialer-proxy:")
            }) {
                lines[dialerIndex] = "    dialer-proxy: \(CustomProxy.quote(dialer.dialer))"
            } else {
                lines.insert("    dialer-proxy: \(CustomProxy.quote(dialer.dialer))", at: nameIndex + 1)
            }
        }
        return lines.joined(separator: "\n")
    }
}
