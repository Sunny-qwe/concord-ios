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

final class AddedRulesStore: ObservableObject {
    @Published var rules: [String] = []

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.addedRulesFileName)
    }

    init() { load() }

    func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        rules = decoded
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(rules) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

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

    /// True only when all five preset rules are present.
    var isLoopbackProtectionOn: Bool {
        Self.loopbackPresetRules.allSatisfy { rules.contains($0) }
    }

    /// How many of the five are present (for the "partially deleted
    /// by hand" hint on the loopback page).
    var loopbackPresetPresentCount: Int {
        Self.loopbackPresetRules.filter { rules.contains($0) }.count
    }

    /// Enabling (re)adds the five rules at the FRONT of the list,
    /// in order, so they match before any user rule that would
    /// proxy loopback; disabling removes all five. A user who
    /// deletes one by hand in 附加规则 just turns the switch off —
    /// turning it back on restores the missing ones.
    func setLoopbackProtection(_ on: Bool) {
        rules.removeAll { Self.loopbackPresetRules.contains($0) }
        if on {
            rules.insert(contentsOf: Self.loopbackPresetRules, at: 0)
        }
        save()
    }

    /// A rule is "TYPE,VALUE,POLICY" with an optional ",no-resolve".
    /// Known types come from Clash's rule grammar.
    static let knownTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
        "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6", "IP-ASN",
        "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "PROCESS-NAME",
        "PROCESS-PATH", "IN-TYPE", "AND", "OR", "NOT", "MATCH",
        "FINAL", "RULE-SET",
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
        if parts[0].uppercased() == "MATCH" || parts[0].uppercased() == "FINAL" {
            guard parts.count == 2 else { return "MATCH / FINAL 只有策略一个参数" }
            return nil
        }
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else {
            return "规则格式应为 类型,值,策略，例如 DOMAIN-SUFFIX,example.com,PROXY"
        }
        return nil
    }
}
