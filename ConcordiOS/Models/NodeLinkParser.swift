import Foundation

// MARK: - Local node-link parser (ss / vmess / trojan / vless)
// Parses share links WITHOUT the core: no VPN needed, no network.
// Anything this parser cannot handle (ssr, hysteria2, tuic, …) falls
// back to the core's convert.decodeLinks, which does need the tunnel
// running — the unified importer says so honestly instead of failing
// silently.

/// A parse/import failure carrying a human-readable reason.
/// Swift's Result requires its Failure type to conform to Error,
/// and String does not — so the reason travels inside this type.
struct NodeLinkError: Error {
    let message: String
}

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
    /// Non-fatal transport caveats (e.g. a link option the Clash
    /// YAML cannot represent). The node is still imported with the
    /// closest representation — never silently degraded: the
    /// importer surfaces the first warning with the import result.
    let warnings: [String]

    init(name: String, type: String, fields: [(key: String, value: NodeYamlValue)], warnings: [String] = []) {
        self.name = name
        self.type = type
        self.fields = fields
        self.warnings = warnings
    }

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
    static func parse(_ line: String) -> Result<ParsedNode, NodeLinkError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ss://") { return parseSS(String(trimmed.dropFirst(5))) }
        if lower.hasPrefix("vmess://") { return parseVmess(String(trimmed.dropFirst(8))) }
        if lower.hasPrefix("trojan://") { return parseTrojan(String(trimmed.dropFirst(9))) }
        if lower.hasPrefix("vless://") { return parseVless(String(trimmed.dropFirst(8))) }
        return .failure(NodeLinkError(message: "不支持的链接格式（本地只解析 ss / vmess / trojan / vless）"))
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

    private static func parseSS(_ body: String) -> Result<ParsedNode, NodeLinkError> {
        let (noFragment, name) = splitFragment(body)
        let (mainRaw, query) = splitQuery(noFragment)
        let main = mainRaw.hasSuffix("/") ? String(mainRaw.dropLast()) : mainRaw
        if main.contains("@") {
            // Form 2: BASE64(method:password)@host:port — or the
            // plaintext form method:password@host:port. The
            // plaintext form always contains ":", which is not a
            // base64 character, so a base64 decode of it fails and
            // the plaintext attempt below is reached.
            guard let at = main.firstIndex(of: "@") else {
                return .failure(NodeLinkError(message: "ss 链接格式不对"))
            }
            let encoded = String(main[..<at])
            let hostPort = String(main[main.index(after: at)...])
            if let data = decodeBase64(encoded),
               let credential = String(data: data, encoding: .utf8),
               let colon = credential.firstIndex(of: ":") {
                let method = String(credential[..<colon])
                let password = String(credential[credential.index(after: colon)...])
                guard let (host, port) = splitHostPort(hostPort) else {
                    return .failure(NodeLinkError(message: "ss 链接没有有效的服务器地址"))
                }
                return makeSS(name: name, method: method, password: password, host: host, port: port, query: query)
            }
            // Form 2b: plaintext method:password@host:port
            let plain = percentDecode(encoded)
            if let colon = plain.firstIndex(of: ":") {
                let method = String(plain[..<colon])
                let password = String(plain[plain.index(after: colon)...])
                if !method.isEmpty, !password.isEmpty,
                   let (host, port) = splitHostPort(hostPort) {
                    return makeSS(name: name, method: method, password: password, host: host, port: port, query: query)
                }
            }
            return .failure(NodeLinkError(message: "ss 链接的账号部分无法解析（应为 base64 或明文 method:password）"))
        }
        // Form 1: BASE64(method:password@host:port)
        guard let data = decodeBase64(main),
              let plain = String(data: data, encoding: .utf8),
              let at = plain.lastIndex(of: "@") else {
            return .failure(NodeLinkError(message: "ss 链接不是有效的 base64（应为 method:password@服务器:端口）"))
        }
        let credential = String(plain[..<at])
        let hostPort = String(plain[plain.index(after: at)...])
        guard let colon = credential.firstIndex(of: ":") else {
            return .failure(NodeLinkError(message: "ss 链接的账号格式不对（应为 method:password）"))
        }
        let method = String(credential[..<colon])
        let password = String(credential[credential.index(after: colon)...])
        guard let (host, port) = splitHostPort(hostPort) else {
            return .failure(NodeLinkError(message: "ss 链接没有有效的服务器地址"))
        }
        return makeSS(name: name, method: method, password: password, host: host, port: port, query: query)
    }

    private static func makeSS(name: String?, method: String, password: String,
                               host: String, port: Int, query: [String: String]) -> Result<ParsedNode, NodeLinkError> {
        guard !method.isEmpty else { return .failure(NodeLinkError(message: "ss 链接没有加密方式")) }
        guard !password.isEmpty else { return .failure(NodeLinkError(message: "ss 链接的密码为空")) }
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

    private static func parseVmess(_ body: String) -> Result<ParsedNode, NodeLinkError> {
        let (noFragment, name) = splitFragment(body)
        let clean = noFragment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let data = decodeBase64(clean),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(NodeLinkError(message: "vmess 链接不是有效的 base64 JSON"))
        }
        guard let server = nonEmpty(obj["add"] as? String) else {
            return .failure(NodeLinkError(message: "vmess 链接缺少服务器地址 (add)"))
        }
        guard let uuid = nonEmpty(obj["id"] as? String) else {
            return .failure(NodeLinkError(message: "vmess 链接缺少 UUID (id)"))
        }
        guard let port = intValue(obj["port"]), (1...65535).contains(port) else {
            return .failure(NodeLinkError(message: "vmess 链接的端口无效"))
        }
        let nodeName = name ?? nonEmpty(obj["ps"] as? String) ?? "\(server):\(port)"
        // "tls" arrives as a JSON boolean in many generators and as
        // the string "tls" in others; both mean TLS on.
        let tls: Bool
        if let tlsBool = obj["tls"] as? Bool {
            tls = tlsBool
        } else if let tlsString = obj["tls"] as? String {
            tls = tlsString.lowercased() == "tls" || tlsString == "1"
        } else {
            tls = false
        }
        let net = ((obj["net"] as? String) ?? "tcp").lowercased()
        let aid = intValue(obj["aid"]) ?? 0
        let host = nonEmpty(obj["host"] as? String) ?? ""
        let path = nonEmpty(obj["path"] as? String) ?? ""
        let sni = nonEmpty(obj["sni"] as? String) ?? ""
        // "type" is the obfuscation, not the transport: "http"
        // means HTTP obfuscation over TCP (Clash http-opts).
        let obfs = ((obj["type"] as? String) ?? "none").lowercased()
        var warnings: [String] = []
        if obfs != "none" && obfs != "http" {
            warnings.append("vmess 混淆类型 \(obfs) 不受支持，已忽略")
        }
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
        case "tcp":
            // HTTP obfuscation over TCP ("type": "http" in the
            // vmess JSON): Clash http-opts.
            if obfs == "http" {
                var http: [(key: String, value: NodeYamlValue)] = [
                    ("method", .string("GET")),
                    ("path", .string(path.isEmpty ? "/" : path)),
                ]
                if !host.isEmpty { http.append(("headers", .map([("Host", .string(host))]))) }
                fields.append(("http-opts", .map(http)))
            }
        default:
            break
        }
        return .success(ParsedNode(name: nodeName, type: "vmess", fields: fields, warnings: warnings))
    }

    // MARK: - Trojan

    private static func parseTrojan(_ body: String) -> Result<ParsedNode, NodeLinkError> {
        let (noFragment, name) = splitFragment(body)
        let (main, query) = splitQuery(noFragment)
        guard let at = main.lastIndex(of: "@") else {
            return .failure(NodeLinkError(message: "trojan 链接里没有服务器地址"))
        }
        let password = percentDecode(String(main[..<at]))
        guard !password.isEmpty else { return .failure(NodeLinkError(message: "trojan 链接的密码为空")) }
        guard let (host, port) = splitHostPort(String(main[main.index(after: at)...])) else {
            return .failure(NodeLinkError(message: "trojan 链接没有有效的服务器地址"))
        }
        let nodeName = name ?? "\(host):\(port)"
        let sni = nonEmpty(query["sni"]) ?? nonEmpty(query["peer"]) ?? host
        // Transport: ?type=ws|grpc (+ path/host), ?type=tcp (default).
        // An unrepresentable type is kept verbatim with a warning —
        // never silently downgraded to plain trojan.
        let transport = (query["type"] ?? "tcp").lowercased()
        var warnings: [String] = []
        if transport != "tcp" && transport != "ws" && transport != "grpc" {
            warnings.append("trojan 传输类型 \(transport) 不受支持，已保留原值，核心可能无法使用")
        }
        var fields: [(key: String, value: NodeYamlValue)] = [
            ("name", .string(nodeName)),
            ("type", .string("trojan")),
            ("server", .string(host)),
            ("port", .int(port)),
            ("password", .string(password)),
            ("sni", .string(sni)),
            ("udp", .bool(true)),
        ]
        if transport != "tcp" { fields.append(("network", .string(transport))) }
        switch transport {
        case "ws":
            let path = nonEmpty(query["path"]) ?? "/"
            var ws: [(key: String, value: NodeYamlValue)] = [("path", .string(path))]
            if let hostHeader = nonEmpty(query["host"]) {
                ws.append(("headers", .map([("Host", .string(hostHeader))])))
            }
            fields.append(("ws-opts", .map(ws)))
        case "grpc":
            let serviceName = nonEmpty(query["serviceName"]) ?? nonEmpty(query["path"]) ?? ""
            fields.append(("grpc-opts", .map([("grpc-service-name", .string(serviceName))])))
        default:
            break
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
        return .success(ParsedNode(name: nodeName, type: "trojan", fields: fields, warnings: warnings))
    }

    // MARK: - VLESS

    private static func parseVless(_ body: String) -> Result<ParsedNode, NodeLinkError> {
        let (noFragment, name) = splitFragment(body)
        let (main, query) = splitQuery(noFragment)
        guard let at = main.lastIndex(of: "@") else {
            return .failure(NodeLinkError(message: "vless 链接里没有服务器地址"))
        }
        let uuid = percentDecode(String(main[..<at]))
        guard !uuid.isEmpty else { return .failure(NodeLinkError(message: "vless 链接缺少 UUID")) }
        guard let (host, port) = splitHostPort(String(main[main.index(after: at)...])) else {
            return .failure(NodeLinkError(message: "vless 链接没有有效的服务器地址"))
        }
        let nodeName = name ?? "\(host):\(port)"
        let security = (query["security"] ?? "none").lowercased()
        let network = (query["type"] ?? "tcp").lowercased()
        let sni = nonEmpty(query["sni"]) ?? ""
        let flow = nonEmpty(query["flow"]) ?? ""
        var warnings: [String] = []
        // Clash vless has no encryption field: anything other than
        // "none" is dropped — with a warning, not silently.
        if let encryption = nonEmpty(query["encryption"]), encryption.lowercased() != "none" {
            warnings.append("vless encryption=\(encryption) 不受支持，已忽略")
        }
        if network != "tcp" && network != "ws" && network != "grpc" && network != "http" && network != "h2" {
            warnings.append("vless 传输类型 \(network) 不受支持，已保留原值，核心可能无法使用")
        }
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
        case "http":
            let path = nonEmpty(query["path"]) ?? "/"
            var http: [(key: String, value: NodeYamlValue)] = [
                ("method", .string("GET")),
                ("path", .string(path)),
            ]
            if let hostHeader = nonEmpty(query["host"]) {
                http.append(("headers", .map([("Host", .string(hostHeader))])))
            }
            fields.append(("http-opts", .map(http)))
        case "h2":
            var h2: [(key: String, value: NodeYamlValue)] = []
            if let hostHeader = nonEmpty(query["host"]) { h2.append(("host", .string(hostHeader))) }
            if let path = nonEmpty(query["path"]) { h2.append(("path", .string(path))) }
            if !h2.isEmpty { fields.append(("h2-opts", .map(h2))) }
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
        return .success(ParsedNode(name: nodeName, type: "vless", fields: fields, warnings: warnings))
    }
}
