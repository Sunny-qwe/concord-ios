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
        // Upstream 165154c: URL-REGEX (regex over the request URL)
        // and USER-AGENT (*? glob, case-sensitive, over the
        // User-Agent header). Both are undecided before the request
        // is read; inside a decrypted session each request is
        // routed on URL + UA after rewrites.
        "URL-REGEX", "USER-AGENT",
    ]

    var text: String {
        if type == "MATCH" || type == "FINAL" { return "\(type),\(target)" }
        var content = self.content
        // A regex or glob may contain commas; the core accepts
        // quoted payloads for these two types (QUOTED_PAYLOAD).
        if (type == "URL-REGEX" || type == "USER-AGENT") && content.contains(",") && !content.hasPrefix("\"") {
            content = "\"\(content)\""
        }
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

    /// Which custom subscription was last baked into which profile
    /// (profile UUID string → custom-subscription UUID string).
    /// ProfileStore reads this when a subscription updates or when
    /// the user switches to a profile, so the baked blocks are
    /// re-applied from the store instead of being wiped (B9/B10).
    /// Persisted in UserDefaults (not in custom-subscriptions.json,
    /// whose shape must keep decoding old files).
    private static let bakeMapKey = "ConcordiOS.customBakeMap.v1"

    private static func bakeMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: bakeMapKey) as? [String: String] ?? [:]
    }

    private static func saveBakeMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: bakeMapKey)
    }

    /// Records that `subscriptionID` was baked into `profileID`
    /// (called by the editor's "应用到当前配置").
    static func noteBaked(subscriptionID: UUID, into profileID: UUID) {
        var map = bakeMap()
        map[profileID.uuidString] = subscriptionID.uuidString
        saveBakeMap(map)
    }

    /// The custom subscription baked into `profileID`, if any.
    static func bakedSubscriptionID(for profileID: UUID) -> UUID? {
        guard let raw = bakeMap()[profileID.uuidString] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Drops the mapping for `profileID` (the mapped subscription
    /// was deleted).
    static func clearBakedSubscription(for profileID: UUID) {
        var map = bakeMap()
        map.removeValue(forKey: profileID.uuidString)
        saveBakeMap(map)
    }

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
        // Drop bake-map entries pointing at the deleted
        // subscription: the next update of an affected profile
        // falls back to the blocks already in its file instead of
        // resurrecting a deleted subscription (see ProfileStore).
        var map = Self.bakeMap()
        for (profileID, subID) in map where subID == sub.id.uuidString {
            map.removeValue(forKey: profileID)
        }
        Self.saveBakeMap(map)
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

    /// Carries the marker-delimited custom blocks (groups /
    /// providers / rules) and the inline `dialer-proxy:` lines from
    /// an OLD profile text into a fresh download, verbatim. Used
    /// when no bake-map entry exists for the profile (bakes made
    /// before the map existed). The fresh text never has the blocks
    /// already, so this is a pure re-insert; a block missing from
    /// the old text is simply not carried over.
    static func reapplyBakedBlocks(from oldText: String, into newText: String) -> String {
        var result = newText
        for (key, begin, end) in [
            ("proxy-groups:", groupsBegin, groupsEnd),
            ("proxy-providers:", proxyProvidersBegin, proxyProvidersEnd),
            ("rule-providers:", ruleProvidersBegin, ruleProvidersEnd),
            ("rules:", rulesBegin, rulesEnd),
        ] {
            let oldLines = oldText.components(separatedBy: "\n")
            guard let beginIndex = oldLines.firstIndex(of: begin),
                  let endIndex = oldLines.firstIndex(of: end),
                  endIndex > beginIndex else { continue }
            let inner = Array(oldLines[(beginIndex + 1)..<endIndex])
            guard !inner.isEmpty else { continue }
            result = bakeSection(result, key: key, begin: begin, end: end, lines: inner)
        }
        let dialers = extractDialers(from: oldText)
        if !dialers.isEmpty {
            result = bakeDialers(dialers, into: result)
        }
        return result
    }

    /// Reads `dialer-proxy:` lines out of a profile's `proxies:`
    /// section, paired with the `- name:` line above each one.
    /// Exact-name matching: a dialer for "US" must not land on
    /// "US-2" (the old contains() match did exactly that).
    static func extractDialers(from text: String) -> [CustomDialer] {
        var out: [CustomDialer] = []
        let lines = text.components(separatedBy: "\n")
        guard let proxiesIndex = lines.firstIndex(where: { $0 == "proxies:" || $0.hasPrefix("proxies: ") }) else {
            return out
        }
        var currentName: String?
        for line in lines[(proxiesIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty { break }
            if trimmed.hasPrefix("- name:") {
                currentName = Self.exactName(from: trimmed)
            } else if trimmed.hasPrefix("dialer-proxy:"), let name = currentName {
                let value = Self.exactName(from: trimmed, key: "dialer-proxy:")
                if !value.isEmpty {
                    out.append(CustomDialer(proxy: name, dialer: value))
                }
            }
        }
        return out
    }

    /// The value after `- name:` / `dialer-proxy:` with quotes
    /// stripped — the whole value, not a substring match.
    private static func exactName(from line: String, key: String = "- name:") -> String {
        guard let range = line.range(of: key) else { return "" }
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
            (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Insert (or re-insert) a marker-delimited block at the END
    /// of the `key:` section (after the section's own entries, so
    /// baked content never outranks them); when the key is missing,
    /// append the whole section at the end. An empty block just
    /// removes the stale one.
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
            if out[keyIndex] == key {
                // B26-sub: the block belongs at the END of the
                // section, not right after the `key:` line — the old
                // position made custom rules outrank the
                // subscription author's own rules (first match
                // wins). The section ends at the first non-empty,
                // non-comment line at column 0 after the key (the
                // next top-level key); the block goes just before
                // it, or at the end of file.
                var insertAt = out.endIndex
                for idx in (keyIndex + 1)..<out.endIndex {
                    let line = out[idx]
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
                    insertAt = idx
                    break
                }
                out.insert(contentsOf: block, at: insertAt)
            } else {
                // Inline value (e.g. `rules: [...]`): no block to
                // append to, keep the old behaviour.
                out.insert(contentsOf: block, at: keyIndex + 1)
            }
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
                Self.exactName(from: $0.trimmingCharacters(in: .whitespaces)) == dialer.proxy
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
