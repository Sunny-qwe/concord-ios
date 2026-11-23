import Foundation
import Combine

// MARK: - Override framework (FlClash: lib/views/config/override.dart
// + general/overrides.dart, ntp.dart, sniffer.dart, tun.dart, and the
// DNS override keys in lib/enum/enum.dart)
//
// FlClash's override model, ported 1:1 in shape: every section
// (general / dns / tun / sniffer / ntp) holds a set of *enabled*
// keys plus the values for those keys. A key that is not enabled
// does not exist in the override at all, so the profile's own value
// stands. Two scopes exist: global (applies to every profile) and
// one entry per subscription (profile UUID); the profile's keys win
// over the global ones.
//
// Storage is twofold:
//   * UserDefaults ("ConcordiOS.overrides.v1") — the editable state
//     the UI binds to;
//   * the shared overrides.json — the same state plus the active
//     profile id, which the PacketTunnel extension reads and merges
//     into config.apply's overlay (base section file, then global
//     overrides, then the active profile's overrides). The merge
//     lives in the extension because that is where config.apply is
//     built; the app never rewrites the user's profile YAML.
//
// A key path may be dotted ("fallback-filter.geoip",
// "sniff.HTTP"): the extension expands it into nested maps when
// merging, and the YAML view here does the same for display.

enum OverrideSection: String, CaseIterable, Identifiable {
    case general, dns, tun, sniffer, ntp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "通用"
        case .dns: return "DNS"
        case .tun: return "TUN"
        case .sniffer: return "嗅探"
        case .ntp: return "NTP"
        }
    }
}

enum OverrideFieldKind {
    case toggle
    case text
    case number
    case stringList
    case numberList
    case stringMap
    case options
    /// A sniff protocol (ports + override-destination inherit/on/off).
    case sniff
}

/// One overridable key: its path, label, editor kind, default value
/// and (for numbers / options) its bounds or choices.
struct OverrideKeySpec {
    let key: String
    let label: String
    let kind: OverrideFieldKind
    let defaultValue: JSONValue
    let options: [String]?
    let optionLabels: [String: String]?
    let min: Int?
    let max: Int?
    let description: String?

    init(key: String, label: String, kind: OverrideFieldKind,
         defaultValue: JSONValue, options: [String]? = nil,
         optionLabels: [String: String]? = nil,
         min: Int? = nil, max: Int? = nil, description: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.options = options
        self.optionLabels = optionLabels
        self.min = min
        self.max = max
        self.description = description
    }
}

final class OverrideStore: ObservableObject {
    static let shared = OverrideStore()

    @Published var applyMessage: String?

    let client: ConcordClient
    private let storageKey = "ConcordiOS.overrides.v1"

    /// section -> key path -> value. Only enabled keys are present.
    private(set) var global: [String: [String: JSONValue]] = [:]
    /// profile UUID -> section -> key path -> value.
    private(set) var profiles: [String: [String: [String: JSONValue]]] = [:]
    /// The profile the extension treats as active when merging.
    private(set) var activeProfileID: String? = nil

    private struct Saved: Codable {
        var activeProfileID: String? = nil
        var global: [String: [String: JSONValue]] = [:]
        var profiles: [String: [String: [String: JSONValue]]] = [:]
    }

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
    }

    // MARK: - Key specs (FlClash OverrideKey enums + model defaults)

    static func specs(for section: OverrideSection) -> [OverrideKeySpec] {
        switch section {
        case .general:
            return [
                // B24: test-url is NOT a core RawConfig key — it is
                // config.apply / config.patch Options.testUrl, which
                // the app never sends. It is stored client-side only
                // (see testURL(scope:)) and stripped from
                // overrides.json before it can reach the core, so
                // the core never logs unknown_key for it.
                OverrideKeySpec(key: "test-url", label: "测速地址", kind: .text,
                                defaultValue: .string(""),
                                description: "只在 App 内用作测速地址兜底，不会发给核心（核心没有这个配置键）"),
                OverrideKeySpec(key: "unified-delay", label: "统一延迟测试", kind: .toggle,
                                defaultValue: .bool(false)),
                OverrideKeySpec(key: "tcp-concurrent", label: "TCP 并发", kind: .toggle,
                                defaultValue: .bool(true)),
                OverrideKeySpec(key: "ipv6", label: "IPv6", kind: .toggle,
                                defaultValue: .bool(true),
                                description: "关闭后核心不解析 IPv6 地址"),
                OverrideKeySpec(key: "geodata-loader", label: "地理数据加载方式", kind: .options,
                                defaultValue: .string("standard"),
                                options: ["standard", "memconservative"],
                                optionLabels: ["standard": "标准", "memconservative": "省内存"]),
            ]
        case .dns:
            return [
                OverrideKeySpec(key: "enable", label: "启用", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "listen", label: "监听地址", kind: .text, defaultValue: .string("")),
                OverrideKeySpec(key: "listen-routing-mark", label: "监听路由标记", kind: .number, defaultValue: .int(0), min: 0),
                OverrideKeySpec(key: "use-hosts", label: "使用 Hosts", kind: .toggle, defaultValue: .bool(true)),
                OverrideKeySpec(key: "use-system-hosts", label: "使用系统 Hosts", kind: .toggle, defaultValue: .bool(true)),
                OverrideKeySpec(key: "ipv6", label: "IPv6", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "ipv6-timeout", label: "IPv6 超时（ms）", kind: .number, defaultValue: .int(100), min: 0),
                OverrideKeySpec(key: "respect-rules", label: "遵循规则", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "prefer-h3", label: "优先 HTTP/3", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "cache-algorithm", label: "缓存算法", kind: .options, defaultValue: .string("lru"), options: ["lru", "arc"]),
                OverrideKeySpec(key: "cache-max-size", label: "缓存上限", kind: .number, defaultValue: .int(4096), min: 0),
                OverrideKeySpec(key: "enhanced-mode", label: "增强模式", kind: .options, defaultValue: .string("redir-host"),
                                options: ["normal", "fake-ip", "redir-host", "hosts"],
                                optionLabels: ["normal": "普通", "fake-ip": "Fake-IP", "redir-host": "redir-host", "hosts": "hosts"]),
                OverrideKeySpec(key: "fake-ip-range", label: "Fake-IP 段", kind: .text, defaultValue: .string("198.18.0.1/16")),
                OverrideKeySpec(key: "fake-ip-range6", label: "Fake-IP 段（IPv6）", kind: .text, defaultValue: .string("")),
                OverrideKeySpec(key: "fake-ip-filter", label: "Fake-IP 过滤", kind: .stringList,
                                defaultValue: .array(["dns.msftncsi.com", "www.msftncsi.com", "www.msftconnecttest.com"].map(JSONValue.string))),
                OverrideKeySpec(key: "fake-ip-filter-mode", label: "Fake-IP 过滤模式", kind: .options, defaultValue: .string("blacklist"),
                                options: ["blacklist", "whitelist", "rule"],
                                optionLabels: ["blacklist": "黑名单", "whitelist": "白名单", "rule": "规则"]),
                OverrideKeySpec(key: "fake-ip-ttl", label: "Fake-IP TTL", kind: .number, defaultValue: .int(1), min: 0),
                OverrideKeySpec(key: "default-nameserver", label: "默认解析服务器", kind: .stringList,
                                defaultValue: .array(["114.114.114.114", "223.5.5.5", "8.8.8.8", "1.0.0.1"].map(JSONValue.string))),
                OverrideKeySpec(key: "nameserver-policy", label: "解析策略", kind: .stringMap, defaultValue: .object([:])),
                OverrideKeySpec(key: "nameserver", label: "解析服务器", kind: .stringList,
                                defaultValue: .array(["https://doh.pub/dns-query", "tls://223.5.5.5:853"].map(JSONValue.string))),
                OverrideKeySpec(key: "fallback", label: "备用解析服务器", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "fallback-lazy-query", label: "备用懒查询", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "proxy-server-nameserver", label: "代理节点解析服务器", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "proxy-server-nameserver-policy", label: "代理节点解析策略", kind: .stringMap, defaultValue: .object([:])),
                OverrideKeySpec(key: "direct-nameserver", label: "直连解析服务器", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "direct-nameserver-follow-policy", label: "直连跟随解析策略", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "fallback-filter.geoip", label: "备用过滤：GeoIP", kind: .toggle, defaultValue: .bool(true)),
                OverrideKeySpec(key: "fallback-filter.geoip-code", label: "备用过滤：GeoIP 国家码", kind: .text, defaultValue: .string("")),
                OverrideKeySpec(key: "fallback-filter.geosite", label: "备用过滤：GeoSite", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "fallback-filter.ipcidr", label: "备用过滤：IP 段", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "fallback-filter.domain", label: "备用过滤：域名", kind: .stringList, defaultValue: .array([])),
            ]
        case .tun:
            return [
                // B12: on iOS only MTU + congestion-controller reach
                // tun.start (PacketTunnelProvider.readTunnelSettings);
                // every other key below only enters Applied.tun, whose
                // DeviceSource::Create path never runs on iOS — so
                // the key is stored and sent, but has no effect on
                // this platform. Each dead key says so in its
                // description (shown in the row and the add sheet).
                OverrideKeySpec(key: "mtu", label: "MTU", kind: .number, defaultValue: .int(9000), min: 1280, max: 65535,
                                description: "在 iOS 上生效：下次启动 VPN 时经 tun.start 应用"),
                OverrideKeySpec(key: "congestion-controller", label: "拥塞控制算法", kind: .text, defaultValue: .string("cubic"),
                                description: "如 cubic、bbr；在 iOS 上生效：下次启动 VPN 时经 tun.start 应用"),
                OverrideKeySpec(key: "strict-route", label: "严格路由", kind: .toggle, defaultValue: .bool(false),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "route-address", label: "路由地址", kind: .stringList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "route-exclude-address", label: "排除路由地址", kind: .stringList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径；要排除路由请用「网络」页的本机网络设置（写 tunnel.json，由系统路由生效）"),
                OverrideKeySpec(key: "dns-hijack", label: "DNS 劫持", kind: .stringList, defaultValue: .array([.string("any:53")]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径；隧道内的 DNS 劫持由扩展在 tun.start 时直接配置"),
                OverrideKeySpec(key: "udp-timeout", label: "UDP 超时（秒）", kind: .number, defaultValue: .int(300), min: 1,
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "disable-icmp-forwarding", label: "禁用 ICMP 转发", kind: .toggle, defaultValue: .bool(false),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "gso", label: "GSO", kind: .toggle, defaultValue: .bool(false),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "include-interface", label: "包含网卡", kind: .stringList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "exclude-interface", label: "排除网卡", kind: .stringList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "include-uid", label: "包含 UID", kind: .numberList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "exclude-uid", label: "排除 UID", kind: .numberList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "exclude-src-port", label: "排除源端口", kind: .numberList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "exclude-dst-port", label: "排除目标端口", kind: .numberList, defaultValue: .array([]),
                                description: "iOS 上无效：该键只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路"),
                OverrideKeySpec(key: "loopback-address", label: "回流地址", kind: .stringList,
                                defaultValue: .array([]),
                                description: "iOS 上无效：核心接受该配置（tun.loopback-address），但当前版本尚未实现回流路由"),
            ]
        case .sniffer:
            return [
                OverrideKeySpec(key: "enable", label: "启用", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "override-destination", label: "覆盖目标地址", kind: .toggle, defaultValue: .bool(true)),
                OverrideKeySpec(key: "force-dns-mapping", label: "强制 DNS 映射", kind: .toggle, defaultValue: .bool(true),
                                description: "把嗅探到的域名映射回 Fake-IP"),
                OverrideKeySpec(key: "parse-pure-ip", label: "解析纯 IP", kind: .toggle, defaultValue: .bool(true)),
                OverrideKeySpec(key: "force-domain", label: "强制嗅探域名", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "skip-domain", label: "跳过域名", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "skip-src-address", label: "跳过源地址", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "skip-dst-address", label: "跳过目标地址", kind: .stringList, defaultValue: .array([])),
                OverrideKeySpec(key: "sniff.HTTP", label: "嗅探 HTTP", kind: .sniff, defaultValue: .object(["ports": .array([])])),
                OverrideKeySpec(key: "sniff.TLS", label: "嗅探 TLS", kind: .sniff, defaultValue: .object(["ports": .array([])])),
                OverrideKeySpec(key: "sniff.QUIC", label: "嗅探 QUIC", kind: .sniff, defaultValue: .object(["ports": .array([])])),
            ]
        case .ntp:
            return [
                OverrideKeySpec(key: "enable", label: "启用", kind: .toggle, defaultValue: .bool(false)),
                OverrideKeySpec(key: "server", label: "服务器", kind: .text, defaultValue: .string("time.apple.com")),
                OverrideKeySpec(key: "port", label: "端口", kind: .number, defaultValue: .int(123), min: 1, max: 65535),
                OverrideKeySpec(key: "interval", label: "同步间隔（分钟）", kind: .number, defaultValue: .int(30), min: 1),
                OverrideKeySpec(key: "dialer-proxy", label: "拨号代理", kind: .text, defaultValue: .string("")),
                OverrideKeySpec(key: "write-to-system", label: "写入系统时间", kind: .toggle, defaultValue: .bool(false),
                                description: "iOS 不允许 App 修改系统时间，该值会传给核心，由核心决定是否执行"),
            ]
        }
    }

    // MARK: - Client-side test URL (config B24)

    /// The client-side fallback test URL: the general `test-url`
    /// override, profile scope winning over global. This value is
    /// stored client-side ONLY and is never sent to the core —
    /// there is no such RawConfig key (it is config.apply /
    /// config.patch `Options.testUrl`, which the app never sends;
    /// the core would only log `unknown_key` for it). ProxyStore
    /// reads it as the fallback delay-test URL when a group has no
    /// testUrl of its own. Returns nil when unset or blank.
    /// READ ACCESSOR for ProxyStore: `OverrideStore.shared.testURL(scope:)`
    /// (instance).
    func testURL(scope: String?) -> String? {
        if let scope,
           let value = profiles[scope]?["general"]?["test-url"]?.stringValue,
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespaces)
        }
        if let value = global["general"]?["test-url"]?.stringValue,
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The general section with `test-url` removed: that key must
    /// never reach the core (see testURL(scope:)). The stored
    /// value itself is untouched.
    private static func withoutTestURL(_ dict: [String: [String: JSONValue]]) -> [String: [String: JSONValue]] {
        var out = dict
        out["general"]?.removeValue(forKey: "test-url")
        return out
    }

    // MARK: - Scope access

    /// The enabled keys + values for one scope + section.
    func state(scope: String?, section: OverrideSection) -> [String: JSONValue] {
        if let scope {
            return profiles[scope]?[section.rawValue] ?? [:]
        }
        return global[section.rawValue] ?? [:]
    }

    func setValue(scope: String?, section: OverrideSection, key: String, value: JSONValue) {
        if let scope {
            var bySection = profiles[scope] ?? [:]
            var dict = bySection[section.rawValue] ?? [:]
            dict[key] = value
            bySection[section.rawValue] = dict
            profiles[scope] = bySection
        } else {
            var dict = global[section.rawValue] ?? [:]
            dict[key] = value
            global[section.rawValue] = dict
        }
        objectWillChange.send()
        save()
    }

    /// Whole-scope replace for the YAML quick editor (OverrideView):
    /// replaces every section of one scope with the given values
    /// (sections absent from `values` become empty), then persists.
    /// `test-url` is preserved by the caller when it was set (the
    /// editor's YAML text never shows it — see yamlText(scope:)).
    func replaceScope(scope: String?, values: [String: [String: JSONValue]]) {
        if let scope {
            profiles[scope] = values
        } else {
            global = values
        }
        objectWillChange.send()
        save()
    }

    /// Enables a key at its default value (FlClash: adding an entry
    /// resets it to the spec default).
    func addKey(scope: String?, section: OverrideSection, key: String) {
        guard let spec = Self.specs(for: section).first(where: { $0.key == key }) else { return }
        setValue(scope: scope, section: section, key: key, value: spec.defaultValue)
    }

    func removeKey(scope: String?, section: OverrideSection, key: String) {
        if let scope {
            profiles[scope]?[section.rawValue]?.removeValue(forKey: key)
        } else {
            global[section.rawValue]?.removeValue(forKey: key)
        }
        objectWillChange.send()
        save()
    }

    // MARK: - Persistence (UserDefaults + shared overrides.json)

    func save() {
        let saved = Saved(activeProfileID: activeProfileID, global: global, profiles: profiles)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        writeSharedFile()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        activeProfileID = saved.activeProfileID
        global = saved.global
        profiles = saved.profiles
    }

    /// The shared overrides.json the extension merges into
    /// config.apply's overlay. Written on every change. `test-url`
    /// is stripped here (config B24): it is stored client-side
    /// only and must never reach the core.
    private func writeSharedFile() {
        var doc: [String: Any] = [:]
        if let activeProfileID { doc["activeProfileId"] = activeProfileID }
        doc["global"] = jsonObject(Self.withoutTestURL(global))
        doc["profiles"] = profiles.mapValues { jsonObject(Self.withoutTestURL($0)) }
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.overridesFileName),
              let data = try? JSONSerialization.data(withJSONObject: doc) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func jsonObject(_ dict: [String: [String: JSONValue]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (section, values) in dict {
            out[section] = values.mapValues { jsonValueToAny($0) }
        }
        return out
    }

    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }

    /// Records a profile switch (called from ProfileStore.activate
    /// before the profile is applied, so the extension's merge at
    /// config.apply already sees the new active profile). Only
    /// rewrites overrides.json — the section files are untouched.
    static func noteActiveProfile(_ id: UUID) {
        let key = "ConcordiOS.overrides.v1"
        var global: [String: [String: JSONValue]] = [:]
        var profiles: [String: [String: [String: JSONValue]]] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            global = saved.global
            profiles = saved.profiles
        }
        // B24: strip the client-side-only test-url from the shared
        // file (it must never reach the core); the stored value in
        // UserDefaults is untouched.
        global = withoutTestURL(global)
        profiles = profiles.mapValues { withoutTestURL($0) }
        let doc: [String: Any] = [
            "activeProfileId": id.uuidString,
            "global": global.mapValues { section in
                section.mapValues { OverrideStore.jsonAny($0) }
            },
            "profiles": profiles.mapValues { bySection in
                bySection.mapValues { section in
                    section.mapValues { OverrideStore.jsonAny($0) }
                }
            },
        ]
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.overridesFileName),
              let data = try? JSONSerialization.data(withJSONObject: doc) else { return }
        try? data.write(to: url, options: .atomic)
        // Keep the in-memory singleton in sync when it exists.
        shared.activeProfileID = id.uuidString
    }

    private static func jsonAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { jsonAny($0) }
        case .object(let dict): return dict.mapValues { jsonAny($0) }
        }
    }

    // MARK: - YAML view

    /// Expands dotted keys ("fallback-filter.geoip",
    /// "sniff.HTTP") into nested maps for display / merging.
    static func expanded(_ values: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in values {
            let parts = key.split(separator: ".").map(String.init)
            insert(&out, parts: parts, value: value)
        }
        return out
    }

    private static func insert(_ dict: inout [String: JSONValue], parts: [String], value: JSONValue) {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dict[first] = value
            return
        }
        var child: [String: JSONValue] = [:]
        if case .object(let existing) = dict[first] { child = existing }
        insert(&child, parts: Array(parts.dropFirst()), value: value)
        dict[first] = .object(child)
    }

    /// The YAML text for one scope: one top-level mapping per
    /// section that has enabled keys. Read-only preview (there is
    /// no YAML parser in the app to parse edits back). `test-url`
    /// is left out of the preview (config B24): it is stored
    /// client-side only and never sent to the core, so showing it
    /// here would imply it is applied; a note line says so when
    /// one is stored.
    func yamlText(scope: String?) -> String {
        var doc: [String: JSONValue] = [:]
        for section in OverrideSection.allCases {
            var values = state(scope: scope, section: section)
            if section == .general { values.removeValue(forKey: "test-url") }
            guard !values.isEmpty else { continue }
            doc[section.rawValue] = .object(Self.expanded(values))
        }
        var text = doc.isEmpty
            ? "# 暂无覆盖项\n"
            : YAMLValue.lines(for: .object(doc), indent: 0).joined(separator: "\n") + "\n"
        if testURL(scope: scope) != nil {
            text += "# 注：test-url 只保存在 App 内用作测速地址兜底，不会发给核心\n"
        }
        return text
    }

    // MARK: - Apply

    /// Saves (rewriting overrides.json) and re-applies the active
    /// config so the overrides take effect. When the tunnel is
    /// stopped they still take effect at the next VPN start, when
    /// the extension merges overrides.json into the overlay.
    @MainActor
    func applyOverrides() async {
        save()
        guard client.mode == .live else {
            applyMessage = "示例模式：覆盖已保存在本地，切换到实时核心并重启 VPN 后生效"
            return
        }
        guard TunnelManager.shared.isRunning else {
            applyMessage = "覆盖已保存，下次启动 VPN 时生效"
            return
        }
        do {
            _ = try await client.configApply(profilePath: nil)
            applyMessage = "覆盖已应用（立即生效）"
        } catch {
            applyMessage = "应用失败：\(error.localizedDescription)"
        }
    }
}
