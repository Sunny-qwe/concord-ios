import Foundation

// MARK: - Default config for node-only imports
// Turns pasted node links into a ready-to-use config: the nodes, one
// "节点选择" select group (every node + DIRECT) and two basic rules
// (GEOIP,CN,DIRECT / MATCH,节点选择). No separate config file is
// needed — the unified importer saves this as the "我的节点" profile
// and activates it. Rewriting an old "我的节点" profile replaces it
// (the app has no YAML parser to merge into an old file).

enum DefaultConfig {
    /// The profile name every node import (re)writes.
    static let profileName = "我的节点"
    static let groupName = "节点选择"

    /// Full YAML from locally parsed nodes.
    static func yaml(nodes: [ParsedNode]) -> String {
        yaml(proxies: nodes.map { $0.jsonValue })
    }

    /// Full YAML from proxy definitions (local parse and/or core
    /// decode — both arrive as JSONValue, so one path builds the file).
    static func yaml(proxies: [JSONValue]) -> String {
        let uniqueProxies = uniquifiedNames(proxies)
        let proxiesSection = "proxies:\n" + uniqueProxies
            .map { "  - " + jsonValueToYaml($0, indent: 4) }
            .joined(separator: "\n")
        let names = uniqueProxies.compactMap { $0.objectValue?["name"]?.stringValue }
        return wrap(proxiesSection: proxiesSection, names: names)
    }

    /// Duplicate proxy names break config validation, so the second
    /// node with the same name gets a " 2" / " 3" suffix.
    private static func uniquifiedNames(_ proxies: [JSONValue]) -> [JSONValue] {
        var seen: Set<String> = []
        return proxies.map { proxy in
            guard var dict = proxy.objectValue,
                  let name = dict["name"]?.stringValue else { return proxy }
            guard seen.contains(name) else {
                seen.insert(name)
                return proxy
            }
            var i = 2
            var candidate = "\(name) \(i)"
            while seen.contains(candidate) {
                i += 1
                candidate = "\(name) \(i)"
            }
            dict["name"] = .string(candidate)
            seen.insert(candidate)
            return .object(dict)
        }
    }

    /// Wraps an already-rendered "proxies:" section with the select
    /// group and the two basic rules.
    static func wrap(proxiesSection: String, names: [String]) -> String {
        var out = "# 由 Concord iOS 统一导入生成\n"
        out += proxiesSection + "\n"
        out += "proxy-groups:\n"
        out += "  - name: \(NodeLinkParser.yamlQuote(groupName))\n"
        out += "    type: select\n"
        out += "    proxies:\n"
        for name in names {
            out += "      - \(NodeLinkParser.yamlQuote(name))\n"
        }
        out += "      - DIRECT\n"
        out += "rules:\n"
        out += "  - GEOIP,CN,DIRECT\n"
        out += "  - MATCH,\(groupName)\n"
        return out
    }

    // MARK: - JSON -> YAML
    // Twin of ProfileStore.jsonValueToYaml / yamlQuoted, kept here so
    // the importer never touches ProfileStore internals. The two
    // renderers must stay in sync (same quoting rule, same object
    // layout: "  - " + value with indent 4).

    static func jsonValueToYaml(_ value: JSONValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return "\(i)"
        case .double(let d):
            return "\(d)"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "\n" + items.map { "\(pad)- \(jsonValueToYaml($0, indent: indent + 2))" }.joined(separator: "\n")
        case .string(let s):
            return yamlQuoted(s)
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            return "\n" + dict.sorted(by: { $0.key < $1.key }).map { key, val in
                "\(pad)\(key): \(jsonValueToYaml(val, indent: indent + 2))"
            }.joined(separator: "\n")
        }
    }

    static func yamlQuoted(_ string: String) -> String {
        let needsQuotes = string.isEmpty
            || string.contains(": ") || string.contains(" #")
            || string.hasPrefix("-") || string.hasPrefix("#")
            || string.hasPrefix("[") || string.hasPrefix("{")
            || string.contains("\n")
            || Double(string) != nil
            || string == "true" || string == "false" || string == "null" || string == "~"
        guard needsQuotes else { return string }
        return "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
