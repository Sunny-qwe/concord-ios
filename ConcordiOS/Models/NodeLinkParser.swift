import Foundation

// MARK: - Local node-link parser (ss / vmess / trojan / vless)
// Parses share links WITHOUT the core: no VPN needed, no network.
// Anything this parser cannot handle (ssr, hysteria2, tuic, …) falls
// back to the core's convert.decodeLinks, which does need the tunnel
// running — the unified importer says so honestly instead of failing
// silently.

/// One YAML scalar / collection value inside a proxy definition.
enum NodeYamlValue {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([NodeYamlValue])
    case map([(key: String, value: NodeYamlValue)])

    var jsonValue: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .int(let i): return .int(Int64(i))
        case .bool(let b): return .bool(b)
        case .array(let items): return .array(items.map { $0.jsonValue })
        case .map(let pairs):
            var dict: [String: JSONValue] = [:]
            for pair in pairs { dict[pair.key] = pair.value.jsonValue }
            return .object(dict)
        }
    }
}

/// One node parsed from a share link.
struct ParsedNode {
    let name: String
    let type: String
    /// Ordered YAML fields (name first, then type, then the rest).
    let fields: [(key: String, value: NodeYamlValue)]

    /// JSON form, for merging with core-decoded proxies into one
    /// default config (see DefaultConfig).
    var jsonValue: JSONValue {
        var dict: [String: JSONValue] = [:]
        for field in fields { dict[field.key] = field.value.jsonValue }
        return .object(dict)
    }

    /// One "  - name: …" block for the proxies: section.
    var yamlEntry: String {
        let lines = NodeLinkParser.yamlLines(fields, indent: 4)
        guard let first = lines.first else { return "" }
        var out = "  - " + String(first.dropFirst(4))
        for line in lines.dropFirst() { out += "\n" + line }
        return out
    }
}

enum NodeLinkParser {
    /// Schemes parsed locally (no core, no VPN).
    static let localSchemes = ["ss://", "vmess://", "trojan://", "vless://"]

    /// Parses one share-link line. The failure reason is user-facing.
    static func parse(_ line: String) -> Result<ParsedNode, String> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ss://") { return parseSS(String(trimmed.dropFirst(5))) }
        if lower.hasPrefix("vmess://") { return parseVmess(String(trimmed.dropFirst(8))) }
        if lower.hasPrefix("trojan://") { return parseTrojan(String(trimmed.dropFirst(9))) }
        if lower.hasPrefix("vless://") { return parseVless(String(trimmed.dropFirst(8))) }
        return .failure("不支持的链接格式（本地只解析 ss / vmess / trojan / vless）")
    }

    // MARK: - YAML rendering

    static func yamlLines(_ fields: [(key: String, value: NodeYamlValue)], indent: Int) -> [String] {
        var out: [String] = []
        let pad = String(repeating: " ", count: indent)
        for (key, value) in fields {
            switch value {
            case .string(let s):
                out.append("\(pad)\(key): \(yamlQuote(s))")
            case .int(let i):
                out.append("\(pad)\(key): \(i)")
            case .bool(let b):
                out.append("\(pad)\(key): \(b ? "true" : "false")")
            case .array(let items):
                if items.isEmpty {
                    out.append("\(pad)\(key): []")
                } else {
                    out.append("\(pad)\(key):")
                    for item in items {
                        switch item {
                        case .string(let s): out.append("\(pad)  - \(yamlQuote(s))")
                        case .int(let i): out.append("\(pad)  - \(i)")
                        case .bool(let b): out.append("\(pad)  - \(b ? "true" : "false")")
                        default: break
                        }
                    }
                }
            case .map(let pairs):
                if pairs.isEmpty {
                    out.append("\(pad)\(key): {}")
                } else {
                    out.append("\(pad)\(key):")
                    out.append(contentsOf: yamlLines(pairs, indent: indent + 2))
                }
            }
        }
        return out
    }

    /// Quotes a YAML scalar only when it needs it (same rule as
    /// ProfileStore.yamlQuoted).
    static func yamlQuote(_ string: String) -> String {
        let needsQuotes = string.isEmpty
            || string.contains(": ") || string.contains(" #")
            || string.hasPrefix("-") || string.hasPrefix("#")
            || string.hasPrefix("[") || string.hasPrefix("{")
            || string.hasPrefix("*") || string.hasPrefix("&")
            || string.hasPrefix("!") || string.hasPrefix("|")
            || string.hasPrefix(">") || string.hasPrefix("'")
            || string.hasPrefix("\"") || string.hasPrefix("%")
            || string.hasPrefix("@") || string.hasPrefix("`")
            || string.contains("\n")
            || Double(string) != nil
            || ["true", "false", "null", "~", "yes", "no", "on", "off"].contains(string.lowercased())
        guard needsQuotes else { return string }
        return "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Small parsing helpers

    private static func splitFragment(_ body: String) -> (main: String, name: String?) {
        guard let hash = body.firstIndex(of: "#") else { return (body, nil) }
        let main = String(body[..<hash])
        let rawName = String(body[body.index(after: hash)...])
        let name = rawName.removingPercentEncoding ?? rawName
        return (main, name.isEmpty ? nil : name)
    }

    private static func splitQuery(_ body: String) -> (main: String, query: [String: String]) {
        guard let question = body.firstIndex(of: "?") else { return (body, [:]) }
        let main = String(body[..<question])
        let queryString = String(body[body.index(after: question)...])
        var out: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let rawValue = kv.count > 1 ? String(kv[1]) : ""
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            out[String(key)] = value
        }
        return (main, out)
    }

    private static func decodeBase64(_ string: String) -> Data? {
        var text = String(string.filter { !$0.isWhitespace })
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    private static func splitHostPort(_ string: String) -> (host: String, port: Int)? {
        let text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = String(text[text.index(after: close)...])
            guard rest.hasPrefix(":"),
                  let port = Int(rest.dropFirst()),
                  (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let portText = String(text[text.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func percentDecode(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Int64 { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: - Shadowsocks

    private static func parseSS(_ body: String) -> Result<ParsedNode, String> {
        let (noFragment, name) = splitFragment(body)
        let (mainRaw, query) = splitQuery(noFragment)
        let main = mainRaw.hasSuffix("/") ? String(mainRaw.dropLast()) : mainRaw
        if main.contains("@") {
            // Form 2: BASE64(method:password)@host:port
            guard let at = main.firstIndex(of: "@") else {
                return .failure("ss 链接格式不对")
            }
            let encoded = String(main[..<at])
            let hostPort = String(main[main.index(after: at)...])
            guard let data = decodeBase64(encoded),
                  let credential = String(data: data, encoding: .utf8),
                  let colon = credential.firstIndex(of: ":") else {
                return .failure("ss 链接的账号部分不是有效的 base64（应为 method:password）")
            }
            let method = String(credential[..<colon])
            let password = String(credential[credential.index(after: colon)...])
            guard let (host, port) = splitHostPort(hostPort) else {
                return .failure("ss 链接没有有效的服务器地址")
            }
            return makeSS(name: name, method: method, password: password, host: host, port: port, query: query)
        }
        // Form 1: BASE64(method:password@host:port)
        guard let data = decodeBase64(main),
              let plain = String(data: data, encoding: .utf8),
              let at = plain.lastIndex(of: "@") else {
            return .failure("ss 链接不是有效的 base64（应为 method:password@服务器:端口）")
        }
        let credential = String(plain[..<at])
        let hostPort = String(plain[plain.index(after: at)...])
        guard let colon = credential.firstIndex(of: ":") else {
            return .failure("ss 链接的账号格式不对（应为 method:password）")
        }
        let method = String(credential[..<colon])
        let password = String(credential[credential.index(after: colon)...])
        guard let (host, port) = splitHostPort(hostPort) else {
            return .failure("ss 链接没有有效的服务器地址")
        }
        return makeSS(name: name, method: method, password: password, host: host, port: port, query: query)
    }

    private static func makeSS(name: String?, method: String, password: String,
                               host: String, port: Int, query: [String: String]) -> Result<ParsedNode, String> {
        guard !method.isEmpty else { return .failure("ss 链接没有加密方式") }
        guard !password.isEmpty else { return .failure("ss 链接的密码为空") }
        let nodeName = name ?? "\(host):\(port)"
        var fields: [(key: String, value: NodeYamlValue)] = [
            ("name", .string(nodeName)),
            ("type", .string("ss")),
            ("server", .string(host)),
            ("port", .int(port)),
            ("cipher", .string(method)),
            ("password", .string(password)),
            ("udp", .bool(true)),
        ]
        if let plugin = nonEmpty(query["plugin"]) {
            let parts = plugin.split(separator: ";").map(String.init)
            if let pluginName = parts.first, !pluginName.isEmpty {
                fields.append(("plugin", .string(pluginName)))
                if parts.count > 1 {
                    fields.append(("plugin-opts", .string(parts.dropFirst().joined(separator: ";"))))
                }
            }
        }
        return .success(ParsedNode(name: nodeName, type: "ss", fields: fields))
    }

    // MARK: - VMess

    private static func parseVmess(_ body: String) -> Result<ParsedNode, String> {
        let (noFragment, name) = splitFragment(body)
        let clean = noFragment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let data = decodeBase64(clean),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("vmess 链接不是有效的 base64 JSON")
        }
        guard let server = nonEmpty(obj["add"] as? String) else {
            return .failure("vmess 链接缺少服务器地址 (add)")
        }
        guard let uuid = nonEmpty(obj["id"] as? String) else {
            return .failure("vmess 链接缺少 UUID (id)")
        }
        guard let port = intValue(obj["port"]), (1...65535).contains(port) else {
            return .failure("vmess 链接的端口无效")
        }
        let nodeName = name ?? nonEmpty(obj["ps"] as? String) ?? "\(server):\(port)"
        let tls = ((obj["tls"] as? String) ?? "").lowercased() == "tls"
        let net = ((obj["net"] as? String) ?? "tcp").lowercased()
        let aid = intValue(obj["aid"]) ?? 0
        let host = nonEmpty(obj["host"] as? String) ?? ""
        let path = nonEmpty(obj["path"] as? String) ?? ""
        let sni = nonEmpty(obj["sni"] as? String) ?? ""
        var fields: [(key: String, value: NodeYamlValue)] = [
            ("name", .string(nodeName)),
            ("type", .string("vmess")),
            ("server", .string(server)),
            ("port", .int(port)),
            ("uuid", .string(uuid)),
            ("alterId", .int(aid)),
            ("cipher", .string("auto")),
            ("tls", .bool(tls)),
            ("udp", .bool(true)),
        ]
        if net != "tcp" { fields.append(("network", .string(net))) }
        let serverName = sni.isEmpty ? host : sni
        if !serverName.isEmpty { fields.append(("servername", .string(serverName))) }
        switch net {
        case "ws":
            var ws: [(key: String, value: NodeYamlValue)] = [("path", .string(path.isEmpty ? "/" : path))]
            if !host.isEmpty { ws.append(("headers", .map([("Host", .string(host))]))) }
            fields.append(("ws-opts", .map(ws)))
        case "grpc":
            fields.append(("grpc-opts", .map([("grpc-service-name", .string(path))])))
        case "h2":
            var h2: [(key: String, value: NodeYamlValue)] = []
            if !host.isEmpty { h2.append(("host", .string(host))) }
            if !path.isEmpty { h2.append(("path", .string(path))) }
            if !h2.isEmpty { fields.append(("h2-opts", .map(h2))) }
        default:
            break
        }
        return .success(ParsedNode(name: nodeName, type: "vmess", fields: fields))
    }

    // MARK: - Trojan

    private static func parseTrojan(_ body: String) -> Result<ParsedNode, String> {
        let (noFragment, name) = splitFragment(body)
        let (main, query) = splitQuery(noFragment)
        guard let at = main.lastIndex(of: "@") else {
            return .failure("trojan 链接里没有服务器地址")
        }
        let password = percentDecode(String(main[..<at]))
        guard !password.isEmpty else { return .failure("trojan 链接的密码为空") }
        guard let (host, port) = splitHostPort(String(main[main.index(after: at)...])) else {
            return .failure("trojan 链接没有有效的服务器地址")
        }
        let nodeName = name ?? "\(host):\(port)"
        let sni = nonEmpty(query["sni"]) ?? nonEmpty(query["peer"]) ?? host
        var fields: [(key: String, value: NodeYamlValue)] = [
            ("name", .string(nodeName)),
            ("type", .string("trojan")),
            ("server", .string(host)),
            ("port", .int(port)),
            ("password", .string(password)),
            ("sni", .string(sni)),
            ("udp", .bool(true)),
        ]
        if query["allowInsecure"] == "1" {
            fields.append(("skip-cert-verify", .bool(true)))
        }
        return .success(ParsedNode(name: nodeName, type: "trojan", fields: fields))
    }

    // MARK: - VLESS

    private static func parseVless(_ body: String) -> Result<ParsedNode, String> {
        let (noFragment, name) = splitFragment(body)
        let (main, query) = splitQuery(noFragment)
        guard let at = main.lastIndex(of: "@") else {
            return .failure("vless 链接里没有服务器地址")
        }
        let uuid = percentDecode(String(main[..<at]))
        guard !uuid.isEmpty else { return .failure("vless 链接缺少 UUID") }
        guard let (host, port) = splitHostPort(String(main[main.index(after: at)...])) else {
            return .failure("vless 链接没有有效的服务器地址")
        }
        let nodeName = name ?? "\(host):\(port)"
        let security = (query["security"] ?? "none").lowercased()
        let network = (query["type"] ?? "tcp").lowercased()
        let sni = nonEmpty(query["sni"]) ?? ""
        let flow = nonEmpty(query["flow"]) ?? ""
        var fields: [(key: String, value: NodeYamlValue)] = [
            ("name", .string(nodeName)),
            ("type", .string("vless")),
            ("server", .string(host)),
            ("port", .int(port)),
            ("uuid", .string(uuid)),
            ("tls", .bool(security == "tls" || security == "reality")),
            ("udp", .bool(true)),
        ]
        if !sni.isEmpty { fields.append(("servername", .string(sni))) }
        if !flow.isEmpty { fields.append(("flow", .string(flow))) }
        if network != "tcp" { fields.append(("network", .string(network))) }
        switch network {
        case "ws":
            let path = nonEmpty(query["path"]) ?? "/"
            var ws: [(key: String, value: NodeYamlValue)] = [("path", .string(path))]
            if let hostHeader = nonEmpty(query["host"]) {
                ws.append(("headers", .map([("Host", .string(hostHeader))])))
            }
            fields.append(("ws-opts", .map(ws)))
        case "grpc":
            let serviceName = nonEmpty(query["serviceName"]) ?? ""
            fields.append(("grpc-opts", .map([("grpc-service-name", .string(serviceName))])))
        default:
            break
        }
        if security == "reality" {
            var reality: [(key: String, value: NodeYamlValue)] = []
            if let pbk = nonEmpty(query["pbk"]) { reality.append(("public-key", .string(pbk))) }
            if let sid = nonEmpty(query["sid"]) { reality.append(("short-id", .string(sid))) }
            if !reality.isEmpty { fields.append(("reality-opts", .map(reality))) }
        }
        if let alpn = nonEmpty(query["alpn"]) {
            let values = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !values.isEmpty {
                fields.append(("alpn", .array(values.map { .string($0) })))
            }
        }
        if query["allowInsecure"] == "1" {
            fields.append(("skip-cert-verify", .bool(true)))
        }
        return .success(ParsedNode(name: nodeName, type: "vless", fields: fields))
    }
}
