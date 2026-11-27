import Foundation
import Combine

// MARK: - Custom subscription (FlClash: lib/views/profiles/custom/)
// A full custom subscription: proxy groups (+ members), per-proxy
// dialers, proxy/rule providers and rules — beyond the node-only
// editing in CustomProxiesView. Stored as JSON in the App Group
// (custom-subscriptions.json), one entry per subscription; the
// editor bakes the chosen subscription into the ACTIVE profile's
// YAML (proxy-groups / proxy-providers / rule-providers / rules /
// dialer-proxy on proxies, plus the per-profile scoped sections
// dns / ntp / sniffer / tun — v0.2.55, each replacing the
// profile's own section of the same key) through the existing
// profile apply path (ProfileStore.saveActiveProfileYAML +
// reapplyActive), so a subscription refresh of the underlying
// profile does not wipe it any more than the custom proxies it
// already re-bakes.

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
    /// Group icon URL (FlClash custom/icon.dart IconPickerView):
    /// baked as `icon:` on the group. Empty = no icon (the group's
    /// icon then comes from the profile icon / icon pack).
    var icon: String
    /// Upstream _GroupOption extras (custom/groups.dart:30-56):
    /// maxFailedTimes (default 5), expectedStatus (default ''),
    /// emptyFallback (default 'COMPATIBLE'), defaultSelected
    /// (default '', selector only), hashKey (default '', load-balance
    /// non-round-robin only). Stored as optionals so "unset" (nil)
    /// bakes nothing and round-trips old files.
    var maxFailedTimes: Int?
    var expectedStatus: String?
    var emptyFallback: String?
    var defaultSelected: String?
    var hashKey: String?
    /// Smart-group only (v0.2.60, upstream c4bc31d): the
    /// `policy-priority:` string — `pattern:factor` pairs separated
    /// by `;` (e.g. `hk:1.5; (?i)jp.*:0.5`), weighting the
    /// per-site pick toward matching members. Nil = unset, bakes
    /// nothing. Stored verbatim; the core parses it leniently
    /// (invalid pairs are skipped with a warning).
    var policyPriority: String?

    init(id: String = UUID().uuidString, name: String = "", type: String = "select",
         members: [String] = [], useProviders: [String] = [],
         url: String = "", interval: Int = 0, timeout: Int = 0, tolerance: Int = 0,
         lazy: Bool = false, hidden: Bool = false, disableUDP: Bool = false,
         filter: String = "", excludeFilter: String = "", strategy: String = "",
         icon: String = "", maxFailedTimes: Int? = nil, expectedStatus: String? = nil,
         emptyFallback: String? = nil, defaultSelected: String? = nil, hashKey: String? = nil,
         policyPriority: String? = nil) {
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
        self.icon = icon
        self.maxFailedTimes = maxFailedTimes
        self.expectedStatus = expectedStatus
        self.emptyFallback = emptyFallback
        self.defaultSelected = defaultSelected
        self.hashKey = hashKey
        self.policyPriority = policyPriority
    }

    // Tolerant decode: files saved before v0.2.54 have no `icon`
    // key (and no option keys); decodeIfPresent keeps them loading
    // instead of dropping the whole subscription list.
    enum CodingKeys: String, CodingKey {
        case id, name, type, members, useProviders, url, interval, timeout,
             tolerance, lazy, hidden, disableUDP, filter, excludeFilter,
             strategy, icon, maxFailedTimes, expectedStatus, emptyFallback,
             defaultSelected, hashKey, policyPriority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "select"
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        useProviders = try c.decodeIfPresent([String].self, forKey: .useProviders) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 0
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 0
        tolerance = try c.decodeIfPresent(Int.self, forKey: .tolerance) ?? 0
        lazy = try c.decodeIfPresent(Bool.self, forKey: .lazy) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        disableUDP = try c.decodeIfPresent(Bool.self, forKey: .disableUDP) ?? false
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? ""
        excludeFilter = try c.decodeIfPresent(String.self, forKey: .excludeFilter) ?? ""
        strategy = try c.decodeIfPresent(String.self, forKey: .strategy) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        maxFailedTimes = try c.decodeIfPresent(Int.self, forKey: .maxFailedTimes)
        expectedStatus = try c.decodeIfPresent(String.self, forKey: .expectedStatus)
        emptyFallback = try c.decodeIfPresent(String.self, forKey: .emptyFallback)
        defaultSelected = try c.decodeIfPresent(String.self, forKey: .defaultSelected)
        hashKey = try c.decodeIfPresent(String.self, forKey: .hashKey)
        policyPriority = try c.decodeIfPresent(String.self, forKey: .policyPriority)
    }

    static let types = ["select", "url-test", "fallback", "load-balance", "smart", "relay", "direct", "reject"]
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
    /// Upstream _ProviderOption extras (custom/providers.dart:257-291):
    /// health-check url / timeout / lazy / expectedStatus, and proxy
    /// overrides udp / skip-cert-verify / ip-version /
    /// additional-prefix / additional-suffix. Nil = unset (bakes
    /// nothing); healthCheckURL etc. only bake inside the
    /// `health-check:` map, the overrides only under
    /// `proxy-override:` — both standard mihomo provider keys.
    var healthCheckURL: String?
    var healthCheckTimeout: Int?
    var healthCheckLazy: Bool?
    var expectedStatus: String?
    var udp: Bool?
    var skipCertVerify: Bool?
    var ipVersion: String?
    var additionalPrefix: String?
    var additionalSuffix: String?
    /// Rule-provider only (v0.2.148): mihomo `behavior`
    /// (domain / ipcidr / classical) and `format` (yaml / text /
    /// mrs). Nil = unset — the importer stores the source value
    /// verbatim when present; bake emits
    /// `behavior: <stored ?? classical>` for every rule provider,
    /// because the core REQUIRES behavior (parse_rule_provider
    /// requires type+behavior and finish() errors on missing
    /// keys, so a rule provider baked without behavior is
    /// rejected outright). The core itself has NO classical
    /// default — the default comes from bake. Proxy providers
    /// never set these (mihomo proxy providers have no
    /// behavior/format).
    var behavior: String?
    var format: String?
    /// Rule-provider only (v0.2.148): `type: inline` payload —
    /// the rule lines. Empty = not inline.
    var payload: [String]

    init(id: String = UUID().uuidString, name: String = "", kind: String = "http",
         url: String = "", path: String = "", interval: Int = 0,
         healthCheck: Bool = false, filter: String = "", excludeFilter: String = "",
         healthCheckURL: String? = nil, healthCheckTimeout: Int? = nil,
         healthCheckLazy: Bool? = nil, expectedStatus: String? = nil,
         udp: Bool? = nil, skipCertVerify: Bool? = nil, ipVersion: String? = nil,
         additionalPrefix: String? = nil, additionalSuffix: String? = nil,
         behavior: String? = nil, format: String? = nil, payload: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.path = path
        self.interval = interval
        self.healthCheck = healthCheck
        self.filter = filter
        self.excludeFilter = excludeFilter
        self.healthCheckURL = healthCheckURL
        self.healthCheckTimeout = healthCheckTimeout
        self.healthCheckLazy = healthCheckLazy
        self.expectedStatus = expectedStatus
        self.udp = udp
        self.skipCertVerify = skipCertVerify
        self.ipVersion = ipVersion
        self.additionalPrefix = additionalPrefix
        self.additionalSuffix = additionalSuffix
        self.behavior = behavior
        self.format = format
        self.payload = payload
    }

    // Tolerant decode (CustomSubscription pattern, v0.2.147):
    // synthesized decode REQUIRES every key, and files saved
    // before v0.2.148 have no behavior / format / payload keys —
    // without this the whole subscription list would fail to load
    // when one provider lacks them. Every field decodes with
    // decodeIfPresent and the init's defaults.
    enum CodingKeys: String, CodingKey {
        case id, name, kind, url, path, interval, healthCheck, filter,
             excludeFilter, healthCheckURL, healthCheckTimeout,
             healthCheckLazy, expectedStatus, udp, skipCertVerify,
             ipVersion, additionalPrefix, additionalSuffix, behavior,
             format, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "http"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 0
        healthCheck = try c.decodeIfPresent(Bool.self, forKey: .healthCheck) ?? false
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? ""
        excludeFilter = try c.decodeIfPresent(String.self, forKey: .excludeFilter) ?? ""
        healthCheckURL = try c.decodeIfPresent(String.self, forKey: .healthCheckURL)
        healthCheckTimeout = try c.decodeIfPresent(Int.self, forKey: .healthCheckTimeout)
        healthCheckLazy = try c.decodeIfPresent(Bool.self, forKey: .healthCheckLazy)
        expectedStatus = try c.decodeIfPresent(String.self, forKey: .expectedStatus)
        udp = try c.decodeIfPresent(Bool.self, forKey: .udp)
        skipCertVerify = try c.decodeIfPresent(Bool.self, forKey: .skipCertVerify)
        ipVersion = try c.decodeIfPresent(String.self, forKey: .ipVersion)
        additionalPrefix = try c.decodeIfPresent(String.self, forKey: .additionalPrefix)
        additionalSuffix = try c.decodeIfPresent(String.self, forKey: .additionalSuffix)
        behavior = try c.decodeIfPresent(String.self, forKey: .behavior)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        payload = try c.decodeIfPresent([String].self, forKey: .payload) ?? []
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

// MARK: - Per-profile scoped sections (v0.2.55, FlClash
// custom.dart _MoreSectionsView: DnsView.profile / NtpView /
// SnifferView / TunView per profile)
//
// Each section is optional on CustomSubscription: nil = unset,
// and an unset section bakes nothing (no empty sections, no
// defaults injected). Inside a section every field is optional
// too: nil = that key is not baked, so a profile only overrides
// the keys the user actually set — the rest keep the
// subscription's own values. An explicit false IS baked: nil vs
// false is the difference between "follow the profile" and
// "turn this off for this profile".
//
// Field shapes mirror the global pages (DnsSettingsView /
// NtpStore / SnifferStore / TunOverrideView + OverrideStore's
// dns / ntp / sniffer / tun key specs) and upstream
// lib/models/clash_config.dart (Dns / Ntp / Sniffer / Tun).
// TUN leaves out device / auto-route: on iOS the device is the
// packet channel, owned by the extension (TunOverrideView).
//
// Codable is tolerant like CustomGroup's v0.2.54 `icon`
// fallback: files saved before v0.2.55 have none of these keys,
// and every field decodes with decodeIfPresent, so old
// custom-subscriptions.json files keep loading.

/// The fallback-filter map inside a DNS section (upstream
/// FallbackFilter: geoip / geoip-code / geosite / ipcidr /
/// domain). All optional: a filter that sets nothing bakes no
/// `fallback-filter:` map at all.
struct CustomDnsFallbackFilter: Codable, Equatable {
    var geoip: Bool?
    var geoipCode: String?
    var geosite: [String]?
    var ipcidr: [String]?
    var domain: [String]?

    init(geoip: Bool? = nil, geoipCode: String? = nil, geosite: [String]? = nil,
         ipcidr: [String]? = nil, domain: [String]? = nil) {
        self.geoip = geoip
        self.geoipCode = geoipCode
        self.geosite = geosite
        self.ipcidr = ipcidr
        self.domain = domain
    }

    enum CodingKeys: String, CodingKey {
        case geoip, geoipCode, geosite, ipcidr, domain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        geoip = try c.decodeIfPresent(Bool.self, forKey: .geoip)
        geoipCode = try c.decodeIfPresent(String.self, forKey: .geoipCode)
        geosite = try c.decodeIfPresent([String].self, forKey: .geosite)
        ipcidr = try c.decodeIfPresent([String].self, forKey: .ipcidr)
        domain = try c.decodeIfPresent([String].self, forKey: .domain)
    }
}

/// Per-profile DNS (baked under the top-level `dns:` key).
struct CustomDnsSection: Codable, Equatable {
    var enable: Bool?
    var listen: String?
    var listenRoutingMark: Int?
    var preferH3: Bool?
    var useHosts: Bool?
    var useSystemHosts: Bool?
    var respectRules: Bool?
    var ipv6: Bool?
    var ipv6Timeout: Int?
    var cacheAlgorithm: String?
    var cacheMaxSize: Int?
    var defaultNameserver: [String]?
    /// "normal" / "fake-ip" / "redir-host" (no "hosts": the core
    /// rejects it as an enhanced-mode — DnsSettingsView).
    var enhancedMode: String?
    var fakeIpRange: String?
    var fakeIpRange6: String?
    var fakeIpFilter: [String]?
    /// "blacklist" / "whitelist" / "rule".
    var fakeIpFilterMode: String?
    var fakeIpTtl: Int?
    var nameserverPolicy: [String: String]?
    var nameserver: [String]?
    var fallback: [String]?
    var fallbackLazyQuery: Bool?
    var proxyServerNameserver: [String]?
    var proxyServerNameserverPolicy: [String: String]?
    var directNameserver: [String]?
    var directNameserverFollowPolicy: Bool?
    var fallbackFilter: CustomDnsFallbackFilter?

    init(enable: Bool? = nil, listen: String? = nil, listenRoutingMark: Int? = nil,
         preferH3: Bool? = nil, useHosts: Bool? = nil, useSystemHosts: Bool? = nil,
         respectRules: Bool? = nil, ipv6: Bool? = nil, ipv6Timeout: Int? = nil,
         cacheAlgorithm: String? = nil, cacheMaxSize: Int? = nil,
         defaultNameserver: [String]? = nil, enhancedMode: String? = nil,
         fakeIpRange: String? = nil, fakeIpRange6: String? = nil,
         fakeIpFilter: [String]? = nil, fakeIpFilterMode: String? = nil,
         fakeIpTtl: Int? = nil, nameserverPolicy: [String: String]? = nil,
         nameserver: [String]? = nil, fallback: [String]? = nil,
         fallbackLazyQuery: Bool? = nil, proxyServerNameserver: [String]? = nil,
         proxyServerNameserverPolicy: [String: String]? = nil,
         directNameserver: [String]? = nil, directNameserverFollowPolicy: Bool? = nil,
         fallbackFilter: CustomDnsFallbackFilter? = nil) {
        self.enable = enable
        self.listen = listen
        self.listenRoutingMark = listenRoutingMark
        self.preferH3 = preferH3
        self.useHosts = useHosts
        self.useSystemHosts = useSystemHosts
        self.respectRules = respectRules
        self.ipv6 = ipv6
        self.ipv6Timeout = ipv6Timeout
        self.cacheAlgorithm = cacheAlgorithm
        self.cacheMaxSize = cacheMaxSize
        self.defaultNameserver = defaultNameserver
        self.enhancedMode = enhancedMode
        self.fakeIpRange = fakeIpRange
        self.fakeIpRange6 = fakeIpRange6
        self.fakeIpFilter = fakeIpFilter
        self.fakeIpFilterMode = fakeIpFilterMode
        self.fakeIpTtl = fakeIpTtl
        self.nameserverPolicy = nameserverPolicy
        self.nameserver = nameserver
        self.fallback = fallback
        self.fallbackLazyQuery = fallbackLazyQuery
        self.proxyServerNameserver = proxyServerNameserver
        self.proxyServerNameserverPolicy = proxyServerNameserverPolicy
        self.directNameserver = directNameserver
        self.directNameserverFollowPolicy = directNameserverFollowPolicy
        self.fallbackFilter = fallbackFilter
    }

    enum CodingKeys: String, CodingKey {
        case enable, listen, listenRoutingMark, preferH3, useHosts, useSystemHosts,
             respectRules, ipv6, ipv6Timeout, cacheAlgorithm, cacheMaxSize,
             defaultNameserver, enhancedMode, fakeIpRange, fakeIpRange6,
             fakeIpFilter, fakeIpFilterMode, fakeIpTtl, nameserverPolicy,
             nameserver, fallback, fallbackLazyQuery, proxyServerNameserver,
             proxyServerNameserverPolicy, directNameserver,
             directNameserverFollowPolicy, fallbackFilter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable)
        listen = try c.decodeIfPresent(String.self, forKey: .listen)
        listenRoutingMark = try c.decodeIfPresent(Int.self, forKey: .listenRoutingMark)
        preferH3 = try c.decodeIfPresent(Bool.self, forKey: .preferH3)
        useHosts = try c.decodeIfPresent(Bool.self, forKey: .useHosts)
        useSystemHosts = try c.decodeIfPresent(Bool.self, forKey: .useSystemHosts)
        respectRules = try c.decodeIfPresent(Bool.self, forKey: .respectRules)
        ipv6 = try c.decodeIfPresent(Bool.self, forKey: .ipv6)
        ipv6Timeout = try c.decodeIfPresent(Int.self, forKey: .ipv6Timeout)
        cacheAlgorithm = try c.decodeIfPresent(String.self, forKey: .cacheAlgorithm)
        cacheMaxSize = try c.decodeIfPresent(Int.self, forKey: .cacheMaxSize)
        defaultNameserver = try c.decodeIfPresent([String].self, forKey: .defaultNameserver)
        enhancedMode = try c.decodeIfPresent(String.self, forKey: .enhancedMode)
        fakeIpRange = try c.decodeIfPresent(String.self, forKey: .fakeIpRange)
        fakeIpRange6 = try c.decodeIfPresent(String.self, forKey: .fakeIpRange6)
        fakeIpFilter = try c.decodeIfPresent([String].self, forKey: .fakeIpFilter)
        fakeIpFilterMode = try c.decodeIfPresent(String.self, forKey: .fakeIpFilterMode)
        fakeIpTtl = try c.decodeIfPresent(Int.self, forKey: .fakeIpTtl)
        nameserverPolicy = try c.decodeIfPresent([String: String].self, forKey: .nameserverPolicy)
        nameserver = try c.decodeIfPresent([String].self, forKey: .nameserver)
        fallback = try c.decodeIfPresent([String].self, forKey: .fallback)
        fallbackLazyQuery = try c.decodeIfPresent(Bool.self, forKey: .fallbackLazyQuery)
        proxyServerNameserver = try c.decodeIfPresent([String].self, forKey: .proxyServerNameserver)
        proxyServerNameserverPolicy = try c.decodeIfPresent([String: String].self, forKey: .proxyServerNameserverPolicy)
        directNameserver = try c.decodeIfPresent([String].self, forKey: .directNameserver)
        directNameserverFollowPolicy = try c.decodeIfPresent(Bool.self, forKey: .directNameserverFollowPolicy)
        fallbackFilter = try c.decodeIfPresent(CustomDnsFallbackFilter.self, forKey: .fallbackFilter)
    }
}

/// Per-profile NTP (baked under the top-level `ntp:` key).
struct CustomNtpSection: Codable, Equatable {
    var enable: Bool?
    var server: String?
    var port: Int?
    var interval: Int?
    var dialerProxy: String?
    var writeToSystem: Bool?

    init(enable: Bool? = nil, server: String? = nil, port: Int? = nil,
         interval: Int? = nil, dialerProxy: String? = nil, writeToSystem: Bool? = nil) {
        self.enable = enable
        self.server = server
        self.port = port
        self.interval = interval
        self.dialerProxy = dialerProxy
        self.writeToSystem = writeToSystem
    }

    enum CodingKeys: String, CodingKey {
        case enable, server, port, interval, dialerProxy, writeToSystem
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable)
        server = try c.decodeIfPresent(String.self, forKey: .server)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval)
        dialerProxy = try c.decodeIfPresent(String.self, forKey: .dialerProxy)
        writeToSystem = try c.decodeIfPresent(Bool.self, forKey: .writeToSystem)
    }
}

/// Per-profile sniffer (baked under the top-level `sniffer:`
/// key). The per-protocol configs reuse SniffProtocolConfig
/// (SnifferStore): ports (empty = the protocol's standard port)
/// and override-destination (nil = inherit the section's).
/// A protocol with no ports and no override bakes nothing.
struct CustomSnifferSection: Codable, Equatable {
    var enable: Bool?
    var overrideDestination: Bool?
    var forceDnsMapping: Bool?
    var parsePureIp: Bool?
    var forceDomain: [String]?
    var skipDomain: [String]?
    var skipSrcAddress: [String]?
    var skipDstAddress: [String]?
    var sniffHttp: SniffProtocolConfig
    var sniffTls: SniffProtocolConfig
    var sniffQuic: SniffProtocolConfig

    init(enable: Bool? = nil, overrideDestination: Bool? = nil,
         forceDnsMapping: Bool? = nil, parsePureIp: Bool? = nil,
         forceDomain: [String]? = nil, skipDomain: [String]? = nil,
         skipSrcAddress: [String]? = nil, skipDstAddress: [String]? = nil,
         sniffHttp: SniffProtocolConfig = SniffProtocolConfig(),
         sniffTls: SniffProtocolConfig = SniffProtocolConfig(),
         sniffQuic: SniffProtocolConfig = SniffProtocolConfig()) {
        self.enable = enable
        self.overrideDestination = overrideDestination
        self.forceDnsMapping = forceDnsMapping
        self.parsePureIp = parsePureIp
        self.forceDomain = forceDomain
        self.skipDomain = skipDomain
        self.skipSrcAddress = skipSrcAddress
        self.skipDstAddress = skipDstAddress
        self.sniffHttp = sniffHttp
        self.sniffTls = sniffTls
        self.sniffQuic = sniffQuic
    }

    enum CodingKeys: String, CodingKey {
        case enable, overrideDestination, forceDnsMapping, parsePureIp,
             forceDomain, skipDomain, skipSrcAddress, skipDstAddress,
             sniffHttp, sniffTls, sniffQuic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable)
        overrideDestination = try c.decodeIfPresent(Bool.self, forKey: .overrideDestination)
        forceDnsMapping = try c.decodeIfPresent(Bool.self, forKey: .forceDnsMapping)
        parsePureIp = try c.decodeIfPresent(Bool.self, forKey: .parsePureIp)
        forceDomain = try c.decodeIfPresent([String].self, forKey: .forceDomain)
        skipDomain = try c.decodeIfPresent([String].self, forKey: .skipDomain)
        skipSrcAddress = try c.decodeIfPresent([String].self, forKey: .skipSrcAddress)
        skipDstAddress = try c.decodeIfPresent([String].self, forKey: .skipDstAddress)
        sniffHttp = try c.decodeIfPresent(SniffProtocolConfig.self, forKey: .sniffHttp) ?? SniffProtocolConfig()
        sniffTls = try c.decodeIfPresent(SniffProtocolConfig.self, forKey: .sniffTls) ?? SniffProtocolConfig()
        sniffQuic = try c.decodeIfPresent(SniffProtocolConfig.self, forKey: .sniffQuic) ?? SniffProtocolConfig()
    }
}

/// Per-profile TUN (baked under the top-level `tun:` key).
/// Keys mirror OverrideStore's tun specs plus the base
/// enable / stack / mtu from NetworkSettingsView. No device /
/// auto-route (extension-owned). iOS note (TunOverrideView):
/// only mtu + congestion-controller reach tun.start; the other
/// keys only enter the core's TUN device-create path, which the
/// iOS packet-channel TUN never runs — they are stored and
/// baked, but have no effect on this platform.
struct CustomTunSection: Codable, Equatable {
    var enable: Bool?
    /// "gvisor" / "system" / "lwip" (NetworkSettingsView).
    var stack: String?
    var mtu: Int?
    var congestionController: String?
    var strictRoute: Bool?
    var routeAddress: [String]?
    var routeExcludeAddress: [String]?
    var dnsHijack: [String]?
    var udpTimeout: Int?
    var disableIcmpForwarding: Bool?
    var gso: Bool?
    var includeInterface: [String]?
    var excludeInterface: [String]?
    var includeUid: [Int]?
    var excludeUid: [Int]?
    var excludeSrcPort: [Int]?
    var excludeDstPort: [Int]?
    var loopbackAddress: [String]?

    init(enable: Bool? = nil, stack: String? = nil, mtu: Int? = nil,
         congestionController: String? = nil, strictRoute: Bool? = nil,
         routeAddress: [String]? = nil, routeExcludeAddress: [String]? = nil,
         dnsHijack: [String]? = nil, udpTimeout: Int? = nil,
         disableIcmpForwarding: Bool? = nil, gso: Bool? = nil,
         includeInterface: [String]? = nil, excludeInterface: [String]? = nil,
         includeUid: [Int]? = nil, excludeUid: [Int]? = nil,
         excludeSrcPort: [Int]? = nil, excludeDstPort: [Int]? = nil,
         loopbackAddress: [String]? = nil) {
        self.enable = enable
        self.stack = stack
        self.mtu = mtu
        self.congestionController = congestionController
        self.strictRoute = strictRoute
        self.routeAddress = routeAddress
        self.routeExcludeAddress = routeExcludeAddress
        self.dnsHijack = dnsHijack
        self.udpTimeout = udpTimeout
        self.disableIcmpForwarding = disableIcmpForwarding
        self.gso = gso
        self.includeInterface = includeInterface
        self.excludeInterface = excludeInterface
        self.includeUid = includeUid
        self.excludeUid = excludeUid
        self.excludeSrcPort = excludeSrcPort
        self.excludeDstPort = excludeDstPort
        self.loopbackAddress = loopbackAddress
    }

    enum CodingKeys: String, CodingKey {
        case enable, stack, mtu, congestionController, strictRoute,
             routeAddress, routeExcludeAddress, dnsHijack, udpTimeout,
             disableIcmpForwarding, gso, includeInterface, excludeInterface,
             includeUid, excludeUid, excludeSrcPort, excludeDstPort,
             loopbackAddress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable)
        stack = try c.decodeIfPresent(String.self, forKey: .stack)
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        congestionController = try c.decodeIfPresent(String.self, forKey: .congestionController)
        strictRoute = try c.decodeIfPresent(Bool.self, forKey: .strictRoute)
        routeAddress = try c.decodeIfPresent([String].self, forKey: .routeAddress)
        routeExcludeAddress = try c.decodeIfPresent([String].self, forKey: .routeExcludeAddress)
        dnsHijack = try c.decodeIfPresent([String].self, forKey: .dnsHijack)
        udpTimeout = try c.decodeIfPresent(Int.self, forKey: .udpTimeout)
        disableIcmpForwarding = try c.decodeIfPresent(Bool.self, forKey: .disableIcmpForwarding)
        gso = try c.decodeIfPresent(Bool.self, forKey: .gso)
        includeInterface = try c.decodeIfPresent([String].self, forKey: .includeInterface)
        excludeInterface = try c.decodeIfPresent([String].self, forKey: .excludeInterface)
        includeUid = try c.decodeIfPresent([Int].self, forKey: .includeUid)
        excludeUid = try c.decodeIfPresent([Int].self, forKey: .excludeUid)
        excludeSrcPort = try c.decodeIfPresent([Int].self, forKey: .excludeSrcPort)
        excludeDstPort = try c.decodeIfPresent([Int].self, forKey: .excludeDstPort)
        loopbackAddress = try c.decodeIfPresent([String].self, forKey: .loopbackAddress)
    }
}

/// A proxy-provider's link to its real URL Profile (v0.2.148,
/// upstream importCustomProfile: a proxy-provider with a URL
/// becomes a real Profile). Keyed by provider name in
/// CustomSubscription.providerProfileMap. fileToken is
/// md5("name@url") at import time (upstream confineProviders
/// key) — the confined file's stable name, so bake needs no
/// Profile lookup. The profile's ageSecretKey is NOT duplicated
/// here: it lives only on the Profile (age-encrypted provider
/// content falls back to http at bake time until the profile
/// update decrypts it).
struct ProviderProfileRef: Codable, Equatable {
    var profileId: UUID
    var fileToken: String
}

/// A rule-provider's link to its ClashProvider record
/// (v0.2.148, upstream ClashProvider). Keyed by provider name
/// in CustomSubscription.ruleProviderMap. fileToken is
/// md5("name@url") at import time (upstream confineProviders
/// key). Bake resolves the record via ClashProviderStore to
/// find its downloaded content file.
struct RuleProviderRef: Codable, Equatable {
    var clashProviderId: UUID
    var fileToken: String
}

struct CustomSubscription: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var groups: [CustomGroup]
    var dialers: [CustomDialer]
    var proxyProviders: [CustomProvider]
    var ruleProviders: [CustomProvider]
    var rules: [CustomRule]
    /// Per-profile scoped sections (v0.2.55, FlClash custom.dart
    /// _MoreSectionsView: DnsView.profile / NtpView / SnifferView /
    /// TunView per profile). Nil = unset: the section bakes
    /// nothing for this profile. A set section replaces the
    /// profile's own section of the same key when baked (see
    /// bakeScopedSection); the profile's original is preserved
    /// inside the marker block and restored on unset.
    var dns: CustomDnsSection?
    var ntp: CustomNtpSection?
    var sniffer: CustomSnifferSection?
    var tun: CustomTunSection?
    /// Per-group selected node (upstream Profile.selectedMap,
    /// lib/models/profile.dart:77 — group name -> selected proxy
    /// name; passed to the core as the selection at apply time).
    /// On iOS the selection lives in ProxyStore's pending
    /// selections; this map is the persisted copy that survives a
    /// re-bake (a fresh config load resets the core's picks, so
    /// refresh() re-fills missing pendings from here). Empty =
    /// no stored pick for that group.
    var selectedMap: [String: String]
    /// The extend-script library id chosen for this subscription
    /// (upstream Profile.scriptId; the iOS script library uses
    /// String ids — MitmScript.id — not upstream's ints). When
    /// the subscription is applied to a profile, applyNow copies
    /// this into that profile's ExtendSettings.scriptId. Nil =
    /// no library script chosen.
    var scriptId: String?
    /// Per-exit outbound target (upstream Profile.exitTargets,
    /// lib/models/profile.dart:80 — exit name -> group/proxy
    /// name; resolves added-rule custom exits and MITM module
    /// policies at build time). Stored only in v0.2.147: iOS has
    /// no structured exit concept yet (added rules are raw
    /// strings, modules carry no exit policies), so no bake step
    /// reads it — the map is persisted so a future exit surface
    /// can use it without a migration.
    var exitTargets: [String: String]
    /// Provider-name → real URL Profile (v0.2.148): a
    /// proxy-provider with a URL is a real Profile (created at
    /// import, downloaded there); bake rewrites the mapped entry
    /// to `type: file` with the profile's content confined under
    /// providers/<sub-id>/proxies/. Unmapped entries bake as
    /// today (the core downloads them itself).
    var providerProfileMap: [String: ProviderProfileRef]
    /// Provider-name → ClashProvider record (v0.2.148): a
    /// rule-provider with a URL is a ClashProvider record
    /// (downloaded at import); bake rewrites the mapped entry to
    /// `type: file` with the record's content confined under
    /// providers/<sub-id>/rules/. Unmapped entries bake as today.
    var ruleProviderMap: [String: RuleProviderRef]

    init(id: UUID = UUID(), name: String = "", groups: [CustomGroup] = [],
         dialers: [CustomDialer] = [], proxyProviders: [CustomProvider] = [],
         ruleProviders: [CustomProvider] = [], rules: [CustomRule] = [],
         dns: CustomDnsSection? = nil, ntp: CustomNtpSection? = nil,
         sniffer: CustomSnifferSection? = nil, tun: CustomTunSection? = nil,
         selectedMap: [String: String] = [:], scriptId: String? = nil,
         exitTargets: [String: String] = [:],
         providerProfileMap: [String: ProviderProfileRef] = [:],
         ruleProviderMap: [String: RuleProviderRef] = [:]) {
        self.id = id
        self.name = name
        self.groups = groups
        self.dialers = dialers
        self.proxyProviders = proxyProviders
        self.ruleProviders = ruleProviders
        self.rules = rules
        self.dns = dns
        self.ntp = ntp
        self.sniffer = sniffer
        self.tun = tun
        self.selectedMap = selectedMap
        self.scriptId = scriptId
        self.exitTargets = exitTargets
        self.providerProfileMap = providerProfileMap
        self.ruleProviderMap = ruleProviderMap
    }

    // Tolerant decode (CustomGroup pattern): the struct has no
    // custom decoder today, and synthesized decode REQUIRES every
    // key — files saved before v0.2.147 have no selectedMap /
    // scriptId / exitTargets keys, so without this the whole
    // subscription list would fail to load. Every field decodes
    // with decodeIfPresent and the init's defaults.
    enum CodingKeys: String, CodingKey {
        case id, name, groups, dialers, proxyProviders, ruleProviders,
             rules, dns, ntp, sniffer, tun, selectedMap, scriptId,
             exitTargets, providerProfileMap, ruleProviderMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        groups = try c.decodeIfPresent([CustomGroup].self, forKey: .groups) ?? []
        dialers = try c.decodeIfPresent([CustomDialer].self, forKey: .dialers) ?? []
        proxyProviders = try c.decodeIfPresent([CustomProvider].self, forKey: .proxyProviders) ?? []
        ruleProviders = try c.decodeIfPresent([CustomProvider].self, forKey: .ruleProviders) ?? []
        rules = try c.decodeIfPresent([CustomRule].self, forKey: .rules) ?? []
        dns = try c.decodeIfPresent(CustomDnsSection.self, forKey: .dns)
        ntp = try c.decodeIfPresent(CustomNtpSection.self, forKey: .ntp)
        sniffer = try c.decodeIfPresent(CustomSnifferSection.self, forKey: .sniffer)
        tun = try c.decodeIfPresent(CustomTunSection.self, forKey: .tun)
        selectedMap = try c.decodeIfPresent([String: String].self, forKey: .selectedMap) ?? [:]
        scriptId = try c.decodeIfPresent(String.self, forKey: .scriptId)
        exitTargets = try c.decodeIfPresent([String: String].self, forKey: .exitTargets) ?? [:]
        providerProfileMap = try c.decodeIfPresent([String: ProviderProfileRef].self, forKey: .providerProfileMap) ?? [:]
        ruleProviderMap = try c.decodeIfPresent([String: RuleProviderRef].self, forKey: .ruleProviderMap) ?? [:]
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
    /// Scoped-section markers (v0.2.55). The block between them
    /// holds the baked section PLUS the profile's own section
    /// preserved as `#~ `-prefixed lines (see bakeScopedSection).
    static let dnsBegin = "# concord-ios 自定义 DNS 开始"
    static let dnsEnd = "# concord-ios 自定义 DNS 结束"
    static let ntpBegin = "# concord-ios 自定义 NTP 开始"
    static let ntpEnd = "# concord-ios 自定义 NTP 结束"
    static let snifferBegin = "# concord-ios 自定义嗅探 开始"
    static let snifferEnd = "# concord-ios 自定义嗅探 结束"
    static let tunBegin = "# concord-ios 自定义 TUN 开始"
    static let tunEnd = "# concord-ios 自定义 TUN 结束"
    /// Note line inside every scoped block, above the preserved
    /// original: tells a reader (or a hand-editor) the block is
    /// managed and the original comes back when the section is
    /// unset. parseScopedBlock skips comment lines here.
    static let scopedNote = "# 取消自定义后恢复订阅原有配置（请勿手动编辑此块）"
    /// Prefix for a preserved original-section line inside a
    /// scoped block. A blank original line encodes as "#~".
    static let scopedPreservePrefix = "#~ "

    /// Bake a custom subscription into profile YAML text: custom
    /// groups / providers / rules replace any previously baked
    /// block (marker-delimited, so re-baking never duplicates),
    /// and dialers set `dialer-proxy:` on the matching proxy
    /// entries. Sections that do not exist yet are created.
    /// The scoped sections (dns / ntp / sniffer / tun) replace
    /// the profile's own section of the same key instead of
    /// appending into it (bakeScopedSection): appending the same
    /// keys would create duplicate keys in one mapping, which the
    /// core's YAML parser rejects. A section that sets nothing
    /// bakes nothing — the profile's own section is left alone
    /// (or restored, when a previous bake replaced it).
    static func bake(_ sub: CustomSubscription, into text: String) -> String {
        var result = text
        result = bakeSection(
            result, key: "proxy-groups:", begin: groupsBegin, end: groupsEnd,
            lines: sub.groups.flatMap { groupYAML($0) }
        )
        result = bakeSection(
            result, key: "proxy-providers:", begin: proxyProvidersBegin, end: proxyProvidersEnd,
            lines: sub.proxyProviders.flatMap { providerYAML($0, in: sub, isRuleProvider: false) }
        )
        result = bakeSection(
            result, key: "rule-providers:", begin: ruleProvidersBegin, end: ruleProvidersEnd,
            lines: sub.ruleProviders.flatMap { providerYAML($0, in: sub, isRuleProvider: true) }
        )
        result = bakeSection(
            result, key: "rules:", begin: rulesBegin, end: rulesEnd,
            lines: sub.rules.map { "  - \(CustomProxy.quote($0.text))" }
        )
        result = bakeDialers(sub.dialers, into: result)
        result = bakeScopedSection(
            result, key: "dns:", begin: dnsBegin, end: dnsEnd,
            lines: sub.dns.map { dnsYAML($0) } ?? []
        )
        result = bakeScopedSection(
            result, key: "ntp:", begin: ntpBegin, end: ntpEnd,
            lines: sub.ntp.map { ntpYAML($0) } ?? []
        )
        result = bakeScopedSection(
            result, key: "sniffer:", begin: snifferBegin, end: snifferEnd,
            lines: sub.sniffer.map { snifferYAML($0) } ?? []
        )
        result = bakeScopedSection(
            result, key: "tun:", begin: tunBegin, end: tunEnd,
            lines: sub.tun.map { tunYAML($0) } ?? []
        )
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
        // Scoped sections carry differently: the old block's baked
        // lines are kept, but the preserved original is replaced
        // by the fresh text's own section (if any) — the
        // subscription author's current section, not the stale one
        // stored in the old block (carryScopedBlock).
        for (key, begin, end) in [
            ("dns:", dnsBegin, dnsEnd),
            ("ntp:", ntpBegin, ntpEnd),
            ("sniffer:", snifferBegin, snifferEnd),
            ("tun:", tunBegin, tunEnd),
        ] {
            let oldLines = oldText.components(separatedBy: "\n")
            guard let beginIndex = oldLines.firstIndex(of: begin),
                  let endIndex = oldLines.firstIndex(of: end),
                  endIndex > beginIndex else { continue }
            let block = Array(oldLines[beginIndex...endIndex])
            result = carryScopedBlock(block, key: key, begin: begin, end: end, into: result)
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

    // MARK: - Scoped map sections (dns / ntp / sniffer / tun)
    //
    // A scoped section is a YAML *map*, not a list, so the
    // append-into-the-profile's-section trick bakeSection uses
    // for groups / providers / rules does not work here:
    // appending `enable: true` under a profile that already has
    // `enable: false` creates duplicate keys in one mapping, and
    // the core's YAML parser rejects duplicate keys. A scoped
    // section therefore REPLACES the profile's own section, in
    // place, inside a marker block that also preserves the
    // profile's original section verbatim (as `#~ `-prefixed
    // lines) — so un-setting the section restores the original
    // exactly, and a subscription refresh re-preserves the
    // author's current section instead of a stale copy.
    //
    // Block layout (all comment lines at column 0 are legal YAML
    // anywhere):
    //   # concord-ios 自定义 DNS 开始
    //   # 取消自定义后恢复订阅原有配置（请勿手动编辑此块）
    //   #~ dns:
    //   #~   enable: false
    //   dns:
    //     enable: true
    //     ...
    //   # concord-ios 自定义 DNS 结束
    // With no original section there are simply no `#~ ` lines.

    /// The line range of a top-level `key:` section: the key line
    /// plus following blank / comment / indented lines, up to (not
    /// including) the next column-0 non-comment line or EOF. Nil
    /// when the key is absent. Matches bakeSection's rule for
    /// where a section ends.
    private static func topLevelSectionRange(in lines: [String], key: String) -> Range<Int>? {
        for idx in lines.indices {
            let line = lines[idx]
            guard line == key || line.hasPrefix(key + " ") else { continue }
            var end = idx + 1
            while end < lines.endIndex {
                let next = lines[end]
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix(" ") || next.hasPrefix("\t") {
                    end += 1
                } else {
                    break
                }
            }
            return idx..<end
        }
        return nil
    }

    /// The line range of a marker block, markers included. Nil
    /// when either marker is missing or the end precedes the begin.
    private static func markerBlockRange(in lines: [String], begin: String, end: String) -> Range<Int>? {
        guard let beginIndex = lines.firstIndex(of: begin),
              let endIndex = lines.firstIndex(of: end),
              endIndex >= beginIndex else { return nil }
        return beginIndex..<(endIndex + 1)
    }

    /// Splits a scoped marker block into its preserved original
    /// section lines (the `#~ `-prefixed lines, prefix stripped)
    /// and its baked lines (the `key:` line plus its indented
    /// content). Nil when the block is malformed (no `key:` line
    /// inside): the caller then rebuilds the block from scratch
    /// instead of trusting it.
    private static func parseScopedBlock(_ block: [String], key: String) -> (preserved: [String], baked: [String])? {
        guard block.count >= 3 else { return nil }
        var preserved: [String] = []
        var idx = 1
        while idx < block.count - 1 {
            let line = block[idx]
            if line.hasPrefix(scopedPreservePrefix) {
                preserved.append(String(line.dropFirst(scopedPreservePrefix.count)))
                idx += 1
            } else if line == "#~" {
                preserved.append("")
                idx += 1
            } else if line.hasPrefix("#") {
                // The note line (or any other comment): skip.
                idx += 1
            } else {
                break
            }
        }
        guard idx < block.count - 1,
              block[idx] == key || block[idx].hasPrefix(key + " ") else { return nil }
        return (preserved, Array(block[idx..<(block.count - 1)]))
    }

    /// Bake one scoped map section into profile YAML text.
    /// `lines` are the section's content lines (indented two
    /// spaces, without the `key:` line). When `lines` is empty
    /// the section is un-baked: any marker block is removed and
    /// the preserved original is put back; with no block at all
    /// the profile's own section is left untouched. Baking is
    /// idempotent: re-baking the same lines rebuilds the same
    /// block with the same preserved original.
    private static func bakeScopedSection(
        _ text: String, key: String, begin: String, end: String,
        lines: [String]
    ) -> String {
        var out = text.components(separatedBy: "\n")
        // 1. An existing marker block: take its preserved
        // original, then drop the block.
        var preserved: [String] = []
        var insertAt: Int? = nil
        if let blockRange = markerBlockRange(in: out, begin: begin, end: end) {
            let block = Array(out[blockRange])
            if let parsed = parseScopedBlock(block, key: key) {
                preserved = parsed.preserved
            }
            insertAt = blockRange.lowerBound
            out.removeSubrange(blockRange)
        }
        // 2. A live top-level section for this key is the current
        // original (a fresh download after a carried block, or the
        // profile's own section on first bake): preserve it and
        // remove it from the text. Fresh wins over the stored
        // copy from step 1 when both exist.
        if let sectionRange = topLevelSectionRange(in: out, key: key) {
            preserved = Array(out[sectionRange])
            if insertAt == nil { insertAt = sectionRange.lowerBound }
            out.removeSubrange(sectionRange)
        }
        // 3. Unset: put the preserved original back (or nothing
        // when there never was one).
        guard !lines.isEmpty else {
            if !preserved.isEmpty {
                out.insert(contentsOf: preserved, at: insertAt ?? out.endIndex)
            }
            return out.joined(separator: "\n")
        }
        // 4. Build the block and insert it where the section was
        // (or at the old block's place, or at end of file).
        var block = [begin, scopedNote]
        for line in preserved {
            block.append(line.isEmpty ? "#~" : scopedPreservePrefix + line)
        }
        block.append(key)
        block.append(contentsOf: lines)
        block.append(end)
        if let insertAt = insertAt {
            out.insert(contentsOf: block, at: insertAt)
        } else {
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append(contentsOf: block)
        }
        return out.joined(separator: "\n")
    }

    /// Carries a scoped marker block from an old profile text into
    /// a fresh download. The old block's baked lines are kept, but
    /// the preserved original is replaced by the fresh text's own
    /// section (if any) — the subscription author's current
    /// section, not the stale one stored in the old block. A
    /// malformed old block (no `key:` line inside) is dropped
    /// rather than carried.
    private static func carryScopedBlock(
        _ blockLines: [String], key: String, begin: String, end: String,
        into text: String
    ) -> String {
        guard let parsed = parseScopedBlock(blockLines, key: key),
              !parsed.baked.isEmpty else { return text }
        var out = text.components(separatedBy: "\n")
        if let existing = markerBlockRange(in: out, begin: begin, end: end) {
            out.removeSubrange(existing)
        }
        var preserved = parsed.preserved
        var insertAt: Int? = nil
        if let sectionRange = topLevelSectionRange(in: out, key: key) {
            preserved = Array(out[sectionRange])
            insertAt = sectionRange.lowerBound
            out.removeSubrange(sectionRange)
        }
        var block = [begin, scopedNote]
        for line in preserved {
            block.append(line.isEmpty ? "#~" : scopedPreservePrefix + line)
        }
        block.append(contentsOf: parsed.baked)
        block.append(end)
        if let insertAt = insertAt {
            out.insert(contentsOf: block, at: insertAt)
        } else {
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append(contentsOf: block)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Scoped-section YAML (keys are the core's kebab-case
    // RawConfig keys — SettingsStore's dns dict, NtpStore's
    // overlayDict, SnifferStore's overlayDict, OverrideStore's tun
    // specs). Only set fields emit lines; a section that sets
    // nothing returns [] and bakes nothing.

    /// `key:` followed by `  - value` items (2-space key indent,
    /// 4-space items). Empty / nil values emit nothing.
    private static func yamlStringList(_ key: String, _ values: [String]?) -> [String] {
        guard let values = values, !values.isEmpty else { return [] }
        var lines = ["  \(key):"]
        lines.append(contentsOf: values.map { "    - \(CustomProxy.quote($0))" })
        return lines
    }

    /// `key:` followed by `  - number` items.
    private static func yamlIntList(_ key: String, _ values: [Int]?) -> [String] {
        guard let values = values, !values.isEmpty else { return [] }
        var lines = ["  \(key):"]
        lines.append(contentsOf: values.map { "    - \($0)" })
        return lines
    }

    /// `key:` followed by sorted `  name: value` lines.
    private static func yamlStringMap(_ key: String, _ values: [String: String]?) -> [String] {
        guard let values = values, !values.isEmpty else { return [] }
        var lines = ["  \(key):"]
        for mapKey in values.keys.sorted() {
            lines.append("    \(CustomProxy.quote(mapKey)): \(CustomProxy.quote(values[mapKey] ?? ""))")
        }
        return lines
    }

    private static func dnsYAML(_ section: CustomDnsSection) -> [String] {
        var lines: [String] = []
        if let enable = section.enable { lines.append("  enable: \(enable)") }
        if let listen = section.listen, !listen.isEmpty { lines.append("  listen: \(CustomProxy.quote(listen))") }
        if let mark = section.listenRoutingMark { lines.append("  listen-routing-mark: \(mark)") }
        if let preferH3 = section.preferH3 { lines.append("  prefer-h3: \(preferH3)") }
        if let useHosts = section.useHosts { lines.append("  use-hosts: \(useHosts)") }
        if let useSystemHosts = section.useSystemHosts { lines.append("  use-system-hosts: \(useSystemHosts)") }
        if let respectRules = section.respectRules { lines.append("  respect-rules: \(respectRules)") }
        if let ipv6 = section.ipv6 { lines.append("  ipv6: \(ipv6)") }
        if let timeout = section.ipv6Timeout { lines.append("  ipv6-timeout: \(timeout)") }
        if let algorithm = section.cacheAlgorithm, !algorithm.isEmpty { lines.append("  cache-algorithm: \(CustomProxy.quote(algorithm))") }
        if let maxSize = section.cacheMaxSize { lines.append("  cache-max-size: \(maxSize)") }
        lines.append(contentsOf: yamlStringList("default-nameserver", section.defaultNameserver))
        if let mode = section.enhancedMode, !mode.isEmpty { lines.append("  enhanced-mode: \(CustomProxy.quote(mode))") }
        if let range = section.fakeIpRange, !range.isEmpty { lines.append("  fake-ip-range: \(CustomProxy.quote(range))") }
        if let range6 = section.fakeIpRange6, !range6.isEmpty { lines.append("  fake-ip-range6: \(CustomProxy.quote(range6))") }
        lines.append(contentsOf: yamlStringList("fake-ip-filter", section.fakeIpFilter))
        if let filterMode = section.fakeIpFilterMode, !filterMode.isEmpty { lines.append("  fake-ip-filter-mode: \(CustomProxy.quote(filterMode))") }
        if let ttl = section.fakeIpTtl { lines.append("  fake-ip-ttl: \(ttl)") }
        lines.append(contentsOf: yamlStringMap("nameserver-policy", section.nameserverPolicy))
        lines.append(contentsOf: yamlStringList("nameserver", section.nameserver))
        lines.append(contentsOf: yamlStringList("fallback", section.fallback))
        if let lazy = section.fallbackLazyQuery { lines.append("  fallback-lazy-query: \(lazy)") }
        lines.append(contentsOf: yamlStringList("proxy-server-nameserver", section.proxyServerNameserver))
        lines.append(contentsOf: yamlStringMap("proxy-server-nameserver-policy", section.proxyServerNameserverPolicy))
        lines.append(contentsOf: yamlStringList("direct-nameserver", section.directNameserver))
        if let follow = section.directNameserverFollowPolicy { lines.append("  direct-nameserver-follow-policy: \(follow)") }
        if let filter = section.fallbackFilter {
            let filterLines = dnsFallbackFilterYAML(filter)
            if !filterLines.isEmpty {
                lines.append("  fallback-filter:")
                lines.append(contentsOf: filterLines)
            }
        }
        return lines
    }

    /// The `fallback-filter:` map's content lines (4-space keys,
    /// 6-space list items). Empty when the filter sets nothing.
    private static func dnsFallbackFilterYAML(_ filter: CustomDnsFallbackFilter) -> [String] {
        var lines: [String] = []
        if let geoip = filter.geoip { lines.append("    geoip: \(geoip)") }
        if let code = filter.geoipCode, !code.isEmpty { lines.append("    geoip-code: \(CustomProxy.quote(code))") }
        if let geosite = filter.geosite, !geosite.isEmpty {
            lines.append("    geosite:")
            lines.append(contentsOf: geosite.map { "      - \(CustomProxy.quote($0))" })
        }
        if let ipcidr = filter.ipcidr, !ipcidr.isEmpty {
            lines.append("    ipcidr:")
            lines.append(contentsOf: ipcidr.map { "      - \(CustomProxy.quote($0))" })
        }
        if let domain = filter.domain, !domain.isEmpty {
            lines.append("    domain:")
            lines.append(contentsOf: domain.map { "      - \(CustomProxy.quote($0))" })
        }
        return lines
    }

    private static func ntpYAML(_ section: CustomNtpSection) -> [String] {
        var lines: [String] = []
        if let enable = section.enable { lines.append("  enable: \(enable)") }
        if let server = section.server, !server.isEmpty { lines.append("  server: \(CustomProxy.quote(server))") }
        if let port = section.port { lines.append("  port: \(port)") }
        if let interval = section.interval { lines.append("  interval: \(interval)") }
        if let dialerProxy = section.dialerProxy, !dialerProxy.isEmpty { lines.append("  dialer-proxy: \(CustomProxy.quote(dialerProxy))") }
        if let writeToSystem = section.writeToSystem { lines.append("  write-to-system: \(writeToSystem)") }
        return lines
    }

    private static func snifferYAML(_ section: CustomSnifferSection) -> [String] {
        var lines: [String] = []
        if let enable = section.enable { lines.append("  enable: \(enable)") }
        if let overrideDest = section.overrideDestination { lines.append("  override-destination: \(overrideDest)") }
        if let forceDnsMapping = section.forceDnsMapping { lines.append("  force-dns-mapping: \(forceDnsMapping)") }
        if let parsePureIp = section.parsePureIp { lines.append("  parse-pure-ip: \(parsePureIp)") }
        lines.append(contentsOf: yamlStringList("force-domain", section.forceDomain))
        lines.append(contentsOf: yamlStringList("skip-domain", section.skipDomain))
        lines.append(contentsOf: yamlStringList("skip-src-address", section.skipSrcAddress))
        lines.append(contentsOf: yamlStringList("skip-dst-address", section.skipDstAddress))
        var sniffLines: [String] = []
        sniffLines.append(contentsOf: sniffProtocolYAML("HTTP", section.sniffHttp))
        sniffLines.append(contentsOf: sniffProtocolYAML("TLS", section.sniffTls))
        sniffLines.append(contentsOf: sniffProtocolYAML("QUIC", section.sniffQuic))
        if !sniffLines.isEmpty {
            lines.append("  sniff:")
            lines.append(contentsOf: sniffLines)
        }
        return lines
    }

    /// One protocol's sniff config (`    HTTP:` + `      ports:` /
    /// `      override-destination:`). Empty when the protocol
    /// sets nothing (ports empty + override nil): an empty ports
    /// list is the protocol's standard port, so emitting it
    /// would inject a default.
    private static func sniffProtocolYAML(_ name: String, _ config: SniffProtocolConfig) -> [String] {
        var inner: [String] = []
        if !config.ports.isEmpty {
            inner.append("      ports:")
            // Port strings ("8080", "8000-9000") are quoted:
            // unquoted they would parse as numbers, and the
            // core reads them as strings.
            inner.append(contentsOf: config.ports.map { "        - \(CustomProxy.quote($0))" })
        }
        if let overrideDest = config.overrideDest { inner.append("      override-destination: \(overrideDest)") }
        guard !inner.isEmpty else { return [] }
        var lines = ["    \(name):"]
        lines.append(contentsOf: inner)
        return lines
    }

    private static func tunYAML(_ section: CustomTunSection) -> [String] {
        var lines: [String] = []
        if let enable = section.enable { lines.append("  enable: \(enable)") }
        if let stack = section.stack, !stack.isEmpty { lines.append("  stack: \(CustomProxy.quote(stack))") }
        if let mtu = section.mtu { lines.append("  mtu: \(mtu)") }
        if let congestion = section.congestionController, !congestion.isEmpty { lines.append("  congestion-controller: \(CustomProxy.quote(congestion))") }
        if let strictRoute = section.strictRoute { lines.append("  strict-route: \(strictRoute)") }
        lines.append(contentsOf: yamlStringList("route-address", section.routeAddress))
        lines.append(contentsOf: yamlStringList("route-exclude-address", section.routeExcludeAddress))
        lines.append(contentsOf: yamlStringList("dns-hijack", section.dnsHijack))
        if let udpTimeout = section.udpTimeout { lines.append("  udp-timeout: \(udpTimeout)") }
        if let disableIcmp = section.disableIcmpForwarding { lines.append("  disable-icmp-forwarding: \(disableIcmp)") }
        if let gso = section.gso { lines.append("  gso: \(gso)") }
        lines.append(contentsOf: yamlStringList("include-interface", section.includeInterface))
        lines.append(contentsOf: yamlStringList("exclude-interface", section.excludeInterface))
        lines.append(contentsOf: yamlIntList("include-uid", section.includeUid))
        lines.append(contentsOf: yamlIntList("exclude-uid", section.excludeUid))
        lines.append(contentsOf: yamlIntList("exclude-src-port", section.excludeSrcPort))
        lines.append(contentsOf: yamlIntList("exclude-dst-port", section.excludeDstPort))
        lines.append(contentsOf: yamlStringList("loopback-address", section.loopbackAddress))
        return lines
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
        if let policyPriority = group.policyPriority, !policyPriority.isEmpty { lines.append("    policy-priority: \(CustomProxy.quote(policyPriority))") }
        if group.type == "load-balance" && !group.strategy.isEmpty { lines.append("    strategy: \(group.strategy)") }
        if group.lazy { lines.append("    lazy: true") }
        if group.hidden { lines.append("    hidden: true") }
        if group.disableUDP { lines.append("    disable-udp: true") }
        if !group.icon.isEmpty { lines.append("    icon: \(CustomProxy.quote(group.icon))") }
        if let maxFailedTimes = group.maxFailedTimes { lines.append("    max-failed-times: \(maxFailedTimes)") }
        if let expectedStatus = group.expectedStatus, !expectedStatus.isEmpty { lines.append("    expected-status: \(CustomProxy.quote(expectedStatus))") }
        if let emptyFallback = group.emptyFallback, !emptyFallback.isEmpty { lines.append("    empty-fallback: \(CustomProxy.quote(emptyFallback))") }
        if let defaultSelected = group.defaultSelected, !defaultSelected.isEmpty { lines.append("    default-selected: \(CustomProxy.quote(defaultSelected))") }
        if let hashKey = group.hashKey, !hashKey.isEmpty { lines.append("    hash-key: \(CustomProxy.quote(hashKey))") }
        if !group.filter.isEmpty { lines.append("    filter: \(CustomProxy.quote(group.filter))") }
        if !group.excludeFilter.isEmpty { lines.append("    exclude-filter: \(CustomProxy.quote(group.excludeFilter))") }
        return lines
    }

    /// App Group root — where the app writes shared files. The
    /// EXTENSION core's home is this directory (PacketTunnel
    /// core.init {"home": <app-group dir>}); the IN-APP core's
    /// home is separate (ApplicationSupport/ConcordAppCore) and is
    /// seeded from here before boot (AppCore.seedProviderCache).
    /// Confined provider files are written under here, but the
    /// baked YAML carries RELATIVE providers/... paths so
    /// HomeDir::confine resolves them under EACH core's home.
    private static var appGroupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
    }

    /// Age-encrypted marker sniff (ProfileStore.looksAgeEncrypted
    /// equivalent, local so bake stays self-contained): the first
    /// 64 bytes contain the age header.
    private static func isAgeEncryptedData(_ data: Data) -> Bool {
        let head = data.prefix(64)
        guard let text = String(data: head, encoding: .ascii) else { return false }
        return text.contains("age-encryption.org/v1")
    }

    /// Confined file for a mapped proxy provider (upstream
    /// confineProviders shape): copies the URL Profile's
    /// downloaded file (profiles/<profileId>.yaml —
    /// ProfileStore.profilesDirectory) to
    /// providers/<subID>/proxies/<fileToken>.yaml and returns the
    /// RELATIVE path for the baked YAML (see appGroupURL: an
    /// absolute App Group path fails confine in the in-app core,
    /// whose home is separate; the relative path resolves under
    /// both homes). Nil when the App Group is unavailable, the
    /// profile file is missing, or its content is age-encrypted
    /// (the http fallback then applies — the profile update
    /// decrypts it with the stored key and the next bake confines
    /// the plaintext). The file holds the full subscription YAML;
    /// parse_provider_content takes the `proxies:` list from it
    /// and ignores the other keys.
    private static func confinedProxyProviderFile(ref: ProviderProfileRef, subID: UUID) -> String? {
        guard let root = appGroupURL else { return nil }
        let source = root.appendingPathComponent("profiles/\(ref.profileId.uuidString).yaml")
        guard let data = try? Data(contentsOf: source), !isAgeEncryptedData(data) else { return nil }
        let relative = "providers/\(subID.uuidString)/proxies/\(ref.fileToken).yaml"
        let dest = root.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        } catch { return nil }
        return relative
    }

    /// Confined file for a mapped rule provider: copies the
    /// ClashProvider record's downloaded content to
    /// providers/<subID>/rules/<fileToken> and returns the
    /// RELATIVE path for the baked YAML (same two-homes reason as
    /// confinedProxyProviderFile). Nil when the record or its
    /// content file is missing (the http fallback then applies).
    private static func confinedRuleProviderFile(ref: RuleProviderRef, subID: UUID) -> String? {
        guard let root = appGroupURL else { return nil }
        let store = ClashProviderStore()
        guard let record = store.provider(id: ref.clashProviderId),
              let contentURL = ClashProviderStore.contentFileURL(for: record),
              let data = try? Data(contentsOf: contentURL), !data.isEmpty else { return nil }
        let relative = "providers/\(subID.uuidString)/rules/\(ref.fileToken)"
        let dest = root.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        } catch { return nil }
        return relative
    }

    private static func providerYAML(_ provider: CustomProvider, in sub: CustomSubscription, isRuleProvider: Bool) -> [String] {
        var lines = ["  \(CustomProxy.quote(provider.name)):"]
        if isRuleProvider {
            // Inline payload providers bake verbatim (core
            // RuleSource::Inline): type + behavior + payload.
            if provider.kind == "inline" {
                lines.append("    type: inline")
                lines.append("    behavior: \(provider.behavior ?? "classical")")
                if let format = provider.format, !format.isEmpty { lines.append("    format: \(format)") }
                if !provider.payload.isEmpty {
                    lines.append("    payload:")
                    lines.append(contentsOf: provider.payload.map { "      - \(CustomProxy.quote($0))" })
                }
                // Fall through to the shared tail below: the core
                // reads `interval` before the source match
                // (provider.rs parse_rule_provider), so an inline
                // provider with interval > 0 needs the line too.
                // (health-check / proxy-override / filter are
                // ignored by the core's rule parse — finish()
                // only errors on missing fields — so emitting
                // them here is harmless and matches the old bake.)
            } else {
                if let ref = sub.ruleProviderMap[provider.name],
                   let confined = confinedRuleProviderFile(ref: ref, subID: sub.id) {
                    lines.append("    type: file")
                    lines.append("    path: \(CustomProxy.quote(confined))")
                } else if provider.kind == "http", !provider.url.isEmpty {
                    lines.append("    type: http")
                    lines.append("    url: \(CustomProxy.quote(provider.url))")
                } else if provider.kind == "file", !provider.path.isEmpty {
                    lines.append("    type: file")
                    lines.append("    path: \(CustomProxy.quote(provider.path))")
                } else {
                    // No usable source (the importer requires url
                    // for http and path for file) — bake the kind
                    // line alone rather than dropping the provider
                    // silently; the core reports it.
                    lines.append("    type: \(provider.kind)")
                }
                // behavior is REQUIRED by the core
                // (parse_rule_provider requires type+behavior and
                // finish() errors on missing keys): classical is
                // the default. Before v0.2.148 bake emitted no
                // behavior line at all, so every
                // custom-subscription rule provider produced a
                // config the core rejected.
                lines.append("    behavior: \(provider.behavior ?? "classical")")
                if let format = provider.format, !format.isEmpty { lines.append("    format: \(format)") }
            }
        } else if let ref = sub.providerProfileMap[provider.name],
                  let confined = confinedProxyProviderFile(ref: ref, subID: sub.id) {
            lines.append("    type: file")
            lines.append("    path: \(CustomProxy.quote(confined))")
        } else if provider.kind == "http", !provider.url.isEmpty {
            lines.append("    type: http")
            lines.append("    url: \(CustomProxy.quote(provider.url))")
        } else if provider.kind == "file", !provider.path.isEmpty {
            lines.append("    type: file")
            lines.append("    path: \(CustomProxy.quote(provider.path))")
        } else {
            lines.append("    type: \(provider.kind)")
        }
        if provider.interval > 0 { lines.append("    interval: \(provider.interval)") }
        if provider.healthCheck || provider.healthCheckURL != nil || provider.healthCheckTimeout != nil
            || provider.healthCheckLazy != nil || provider.expectedStatus != nil {
            var parts: [String] = []
            if provider.healthCheck { parts.append("enable: true") }
            if let url = provider.healthCheckURL, !url.isEmpty { parts.append("url: \(CustomProxy.quote(url))") }
            if let timeout = provider.healthCheckTimeout { parts.append("timeout: \(timeout)") }
            if let lazy = provider.healthCheckLazy { parts.append("lazy: \(lazy)") }
            if let expected = provider.expectedStatus, !expected.isEmpty { parts.append("expected-status: \(CustomProxy.quote(expected))") }
            lines.append("    health-check: {\(parts.joined(separator: ", "))}")
        }
        if provider.udp != nil || provider.skipCertVerify != nil || provider.ipVersion != nil
            || provider.additionalPrefix != nil || provider.additionalSuffix != nil {
            lines.append("    proxy-override:")
            if let udp = provider.udp { lines.append("      udp: \(udp)") }
            if let skip = provider.skipCertVerify { lines.append("      skip-cert-verify: \(skip)") }
            if let version = provider.ipVersion, !version.isEmpty { lines.append("      ip-version: \(CustomProxy.quote(version))") }
            if let prefix = provider.additionalPrefix, !prefix.isEmpty { lines.append("      additional-prefix: \(CustomProxy.quote(prefix))") }
            if let suffix = provider.additionalSuffix, !suffix.isEmpty { lines.append("      additional-suffix: \(CustomProxy.quote(suffix))") }
        }
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
