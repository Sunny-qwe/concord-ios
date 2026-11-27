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
    // OpenVPN (v0.2.151, core crates/config/src/proxy/openvpn.rs):
    // `cipher` above is reused for the OpenVPN cipher (empty =
    // core default AES-128-GCM) and `password` for auth-user-pass.
    // All fields below carry declaration defaults, so the
    // synthesized Codable decoder tolerates files saved before
    // they existed. `peer-info` / `ip-stack` are NOT exposed in
    // the form (reachable via raw definitions, kept verbatim).
    var ovpnProto: String = "udp"
    var ovpnCa: String = ""
    var ovpnCert: String = ""
    var ovpnKey: String = ""
    var ovpnTlsAuth: String = ""
    var ovpnTlsCrypt: String = ""
    var ovpnTlsCryptV2: String = ""
    var ovpnKeyDirection: String = ""
    var ovpnUsername: String = ""
    var ovpnDataCiphers: String = ""
    var ovpnDataCiphersFallback: String = ""
    var ovpnAuth: String = ""
    var ovpnCompLzo: Bool = false
    var ovpnPing: Int = 0
    var ovpnPingRestart: Int = 0
    var ovpnTranWindow: Int = 0
    var ovpnHandshakeTimeout: Int = 0
    var ovpnMtu: Int = 0
    var ovpnRemoteDnsResolve: Bool = false
    var ovpnDns: String = ""

    init(id: String = UUID().uuidString, name: String = "", type: String = "ss",
         server: String = "", port: Int = 0, password: String = "",
         uuid: String = "", cipher: String = "", tls: Bool = false,
         sni: String = "", network: String = "", udp: Bool = false,
         ovpnProto: String = "udp", ovpnCa: String = "", ovpnCert: String = "",
         ovpnKey: String = "", ovpnTlsAuth: String = "", ovpnTlsCrypt: String = "",
         ovpnTlsCryptV2: String = "", ovpnKeyDirection: String = "",
         ovpnUsername: String = "", ovpnDataCiphers: String = "",
         ovpnDataCiphersFallback: String = "", ovpnAuth: String = "",
         ovpnCompLzo: Bool = false, ovpnPing: Int = 0, ovpnPingRestart: Int = 0,
         ovpnTranWindow: Int = 0, ovpnHandshakeTimeout: Int = 0, ovpnMtu: Int = 0,
         ovpnRemoteDnsResolve: Bool = false, ovpnDns: String = "") {
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
        self.ovpnProto = ovpnProto
        self.ovpnCa = ovpnCa
        self.ovpnCert = ovpnCert
        self.ovpnKey = ovpnKey
        self.ovpnTlsAuth = ovpnTlsAuth
        self.ovpnTlsCrypt = ovpnTlsCrypt
        self.ovpnTlsCryptV2 = ovpnTlsCryptV2
        self.ovpnKeyDirection = ovpnKeyDirection
        self.ovpnUsername = ovpnUsername
        self.ovpnDataCiphers = ovpnDataCiphers
        self.ovpnDataCiphersFallback = ovpnDataCiphersFallback
        self.ovpnAuth = ovpnAuth
        self.ovpnCompLzo = ovpnCompLzo
        self.ovpnPing = ovpnPing
        self.ovpnPingRestart = ovpnPingRestart
        self.ovpnTranWindow = ovpnTranWindow
        self.ovpnHandshakeTimeout = ovpnHandshakeTimeout
        self.ovpnMtu = ovpnMtu
        self.ovpnRemoteDnsResolve = ovpnRemoteDnsResolve
        self.ovpnDns = ovpnDns
    }

    static let types = ["ss", "vmess", "vless", "trojan", "socks5", "http", "hysteria2", "tuic", "openvpn"]

    /// OpenVPN ciphers the core accepts (openvpn.rs
    /// OPENVPN_CIPHERS). Empty = core default AES-128-GCM.
    static let openvpnCiphers = ["AES-128-GCM", "AES-192-GCM", "AES-256-GCM",
                                  "AES-128-CBC", "AES-192-CBC", "AES-256-CBC",
                                  "CHACHA20-POLY1305"]
    /// OpenVPN auth digests the core accepts (OPENVPN_AUTHS).
    /// Empty = core default SHA256.
    static let openvpnAuths = ["MD5", "SHA1", "SHA256", "SHA384", "SHA512"]

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
        case "openvpn":
            // Core crates/config/src/proxy/openvpn.rs: proto udp
            // (default) / tcp; `ca` is inline PEM and REQUIRED;
            // cert+key together, or a username (auth-user-pass),
            // is REQUIRED — both are checked by validate.proxies
            // before save, so a bad node never reaches the
            // profile silently. Only non-default values are
            // emitted (0 durations / mtu = core default).
            if ovpnProto.lowercased() == "tcp" { lines.append("    proto: tcp") }
            lines.append(contentsOf: Self.blockLines("ca", value: ovpnCa))
            lines.append(contentsOf: Self.blockLines("cert", value: ovpnCert))
            lines.append(contentsOf: Self.blockLines("key", value: ovpnKey))
            lines.append(contentsOf: Self.blockLines("tls-auth", value: ovpnTlsAuth))
            lines.append(contentsOf: Self.blockLines("tls-crypt", value: ovpnTlsCrypt))
            lines.append(contentsOf: Self.blockLines("tls-crypt-v2", value: ovpnTlsCryptV2))
            if ovpnKeyDirection == "0" || ovpnKeyDirection == "1" {
                lines.append("    key-direction: \(ovpnKeyDirection)")
            }
            if !ovpnUsername.isEmpty { lines.append("    username: \(Self.quote(ovpnUsername))") }
            if !password.isEmpty { lines.append("    password: \(Self.quote(password))") }
            if !cipher.isEmpty { lines.append("    cipher: \(cipher)") }
            let dataCiphers = Self.splitList(ovpnDataCiphers)
            if !dataCiphers.isEmpty {
                lines.append("    data-ciphers:")
                for item in dataCiphers { lines.append("      - \(Self.quote(item))") }
            }
            if !ovpnDataCiphersFallback.isEmpty { lines.append("    data-ciphers-fallback: \(Self.quote(ovpnDataCiphersFallback))") }
            if !ovpnAuth.isEmpty { lines.append("    auth: \(ovpnAuth)") }
            if ovpnCompLzo { lines.append("    comp-lzo: yes") }
            if ovpnPing > 0 { lines.append("    ping: \(ovpnPing)") }
            if ovpnPingRestart > 0 { lines.append("    ping-restart: \(ovpnPingRestart)") }
            if ovpnTranWindow > 0 { lines.append("    tran-window: \(ovpnTranWindow)") }
            if ovpnHandshakeTimeout > 0 { lines.append("    handshake-timeout: \(ovpnHandshakeTimeout)") }
            if ovpnMtu > 0 { lines.append("    mtu: \(ovpnMtu)") }
            if ovpnRemoteDnsResolve { lines.append("    remote-dns-resolve: true") }
            let dns = Self.splitCommaList(ovpnDns)
            if !dns.isEmpty {
                lines.append("    dns:")
                for item in dns { lines.append("      - \(Self.quote(item))") }
            }
        default:
            break
        }
        // An OpenVPN node always carries UDP (core warns when
        // `udp: false` is written), so it is always emitted.
        if udp || type == "openvpn" { lines.append("    udp: true") }
        return lines
    }

    /// A multi-line value as a YAML literal block scalar
    /// (`key: |-` + indented lines). `quote()` would double-quote
    /// it, and YAML folds the newlines inside double quotes to
    /// spaces — which corrupts PEM blocks (ca/cert/key,
    /// tls-auth, tls-crypt, tls-crypt-v2). The `|-` form keeps
    /// every line verbatim; the core reads the exact text back.
    static func blockLines(_ key: String, value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out = ["    \(key): |-"]
        for line in trimmed.components(separatedBy: "\n") {
            out.append("      \(line.trimmingCharacters(in: .whitespaces))")
        }
        return out
    }

    /// Split a comma- or colon-separated list field
    /// (data-ciphers) into trimmed non-empty items. The core
    /// splits data-ciphers on ':' too, so both separators are
    /// accepted on input.
    static func splitList(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",:"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Split a comma-separated list field (dns) into trimmed
    /// non-empty items. DNS entries KEEP their colons: IPv6
    /// literals, `host:port`, `tcp://host:port` are all valid
    /// core DNS forms (remote_dns) — splitting on ':' would
    /// shred them into junk. data-ciphers uses splitList, where
    /// the core itself splits on ':' too.
    static func splitCommaList(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
