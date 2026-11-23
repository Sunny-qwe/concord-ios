import Foundation
import Combine

// MARK: - Added rules (FlClash: Tools -> 进阶配置 -> 附加规则)
// Extra Clash rules the user adds on top of the profile's own
// rules. They are stored in the App Group as added-rules.json (a
// JSON array of rule strings) and the PacketTunnel extension merges
// them into config.apply's overlay — the core prepends overlay
// rules before the profile's own rules (upstream
// crates/config/src/merge.rs), so they take effect at the next VPN
// start or live re-apply, without touching the profile YAML.

/// Rule presets (FlClash features/form/rule_preset.dart):
/// the same seven quick actions, same raw rule strings.
enum RulePreset: String, CaseIterable {
    case blockQuic = "拦截 QUIC"
    case blockStun = "拦截 STUN"
    case blockDot = "拦截 DoT (853)"
    case blockLoopback = "防止代理回环"
    case lanDirect = "局域网直连"
    case systemServicesDirect = "系统服务直连"
    case bittorrentDirect = "BT 直连"

    var rawRules: [String] {
        switch self {
        case .blockQuic: return ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP"]
        case .blockStun: return ["AND,((NETWORK,UDP),(DST-PORT,3478/19302)),REJECT-DROP"]
        case .blockDot: return ["DST-PORT,853,REJECT"]
        case .blockLoopback: return AddedRulesStore.loopbackPresetRules
        case .lanDirect: return ["GEOSITE,private,DIRECT", "GEOIP,LAN,DIRECT,no-resolve"]
        case .systemServicesDirect: return ["GEOSITE,apple,DIRECT", "GEOSITE,microsoft,DIRECT"]
        case .bittorrentDirect: return [
            "GEOSITE,category-public-tracker,DIRECT",
            "GEOSITE,category-pt,DIRECT",
            "PROCESS-NAME-REGEX,(?i)^(qbittorrent|transmission.*|deluge.*|aria2c|motrix|utorrent|bitcomet)(\\.exe)?$,DIRECT",
        ]
        }
    }
}

final class AddedRulesStore: ObservableObject {
    @Published var rules: [String] = []
    /// Global rules disabled per profile (FlClash
    /// profileDisabledRuleIdsProvider / _EditGlobalAddedRules):
    /// a disabled rule is moved OUT of the active list into this
    /// persisted list, so the tunnel overlay (which reads only
    /// `rules`) never sees it — disabling is real, not a UI flag.
    /// Stored in added-rules-disabled.json next to added-rules.json.
    @Published var disabledRules: [String] = []

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.addedRulesFileName)
    }

    private var disabledFileURL: URL? {
        ConfigStore.sharedFileURL(name: "added-rules-disabled.json")
    }

    init() { load() }

    func load() {
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            rules = decoded
        }
        if let url = disabledFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            disabledRules = decoded
        }
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(rules) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if let disabledURL = disabledFileURL,
           let disabledData = try? JSONEncoder().encode(disabledRules) {
            try? disabledData.write(to: disabledURL, options: .atomic)
        }
    }

    /// Move a rule between the active list and the disabled list.
    func setRule(_ rule: String, disabled: Bool) {
        if disabled {
            rules.removeAll { $0 == rule }
            if !disabledRules.contains(rule) { disabledRules.append(rule) }
        } else {
            disabledRules.removeAll { $0 == rule }
            if !rules.contains(rule) { rules.append(rule) }
        }
        save()
    }

    func isRuleDisabled(_ rule: String) -> Bool { disabledRules.contains(rule) }

    // MARK: - Loopback protection (FlClash rule preset "防止代理回环")

    /// FlClash's blockLoopback preset (rule_preset.dart): traffic to
    /// the device itself must never be proxied — 0.0.0.0 / :: also
    /// reach a local listener — and a TUN-originated DNS request on
    /// port 853 is looped traffic too.
    static let loopbackPresetRules: [String] = [
        "IP-CIDR,127.0.0.0/8,REJECT,no-resolve",
        "IP-CIDR,0.0.0.0/32,REJECT,no-resolve",
        "IP-CIDR6,::1/128,REJECT,no-resolve",
        "IP-CIDR6,::/128,REJECT,no-resolve",
        "AND,((IN-TYPE,TUN),(DST-PORT,853)),REJECT",
    ]

    /// A rule is "TYPE,VALUE,POLICY" with an optional ",no-resolve".
    /// Known types come from Clash's rule grammar, plus the two
    /// upstream 165154c types: URL-REGEX (a regex over the request
    /// URL) and USER-AGENT (a *? glob, case-sensitive, over the
    /// User-Agent header — from an HTTP proxy CONNECT when there is
    /// one). Both are undecided before the request is read: they do
    /// not match a fresh connection, and NOT around them does not
    /// turn them into a match; inside a decrypted session each
    /// request is routed on URL + UA after rewrites. The core does
    /// the actual matching — the app only recognizes, validates and
    /// offers them. Their payloads may be quoted (the core's
    /// QUOTED_PAYLOAD), because a regex or glob may contain commas.
    static let knownTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
        "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6", "IP-ASN",
        "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "PROCESS-NAME",
        "PROCESS-PATH", "IN-TYPE", "AND", "OR", "NOT", "MATCH",
        "FINAL", "RULE-SET", "URL-REGEX", "USER-AGENT",
    ]

    /// Returns an error message when the rule text is malformed, or
    /// nil when it parses.
    static func validationError(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "规则不能为空" }
        var parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.last == "no-resolve" { parts.removeLast() }
        guard parts.count >= 2 else { return "规则格式应为 类型,值,策略，例如 DOMAIN-SUFFIX,example.com,PROXY" }
        guard knownTypes.contains(parts[0].uppercased()) else {
            return "未知规则类型 \(parts[0])"
        }
        let type = parts[0].uppercased()
        if type == "URL-REGEX" || type == "USER-AGENT" {
            // The payload may be quoted and may contain commas, so
            // re-split quote-aware (the core's QUOTED_PAYLOAD).
            var qparts = quotedParts(trimmed)
            if qparts.last == "no-resolve" { qparts.removeLast() }
            guard qparts.count == 3, !qparts[1].isEmpty, !qparts[2].isEmpty else {
                return "规则格式应为 类型,值,策略，例如 URL-REGEX,^https://example\\.com/,PROXY"
            }
            if type == "URL-REGEX" {
                let pattern = qparts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard (try? NSRegularExpression(pattern: pattern)) != nil else { return "正则表达式无效" }
            }
            return nil
        }
        if parts[0].uppercased() == "MATCH" || parts[0].uppercased() == "FINAL" {
            guard parts.count == 2 else { return "MATCH / FINAL 只有策略一个参数" }
            return nil
        }
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else {
            return "规则格式应为 类型,值,策略，例如 DOMAIN-SUFFIX,example.com,PROXY"
        }
        return nil
    }

    /// Splits a rule line on commas outside double quotes (the core
    /// accepts quoted payloads for URL-REGEX / USER-AGENT, whose
    /// regex or glob may contain commas).
    private static func quotedParts(_ text: String) -> [String] {
        var parts: [String] = []
        var quoted = false
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                quoted.toggle()
            } else if c == "," && !quoted {
                parts.append(String(text[start..<i]).trimmingCharacters(in: .whitespaces))
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        parts.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
        return parts
    }
}
