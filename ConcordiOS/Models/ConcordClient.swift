import Foundation
import Combine

// MARK: - Concord JSON-RPC 2.0 client
//
// Types are modelled on upstream Concord's schema/api.json (69 methods,
// checked 2026-11-19 against commit 165154c — mitm.readModule added).
// See TUN_INVESTIGATION.md for the full method map.
//
// Two modes:
//   - `.live` (default): the client talks to the real core, which runs
//     in the PacketTunnel extension process — NEVER in the app process.
//     Unary methods go through ExtensionConcordTransport:
//     NETunnelProviderManager.sendProviderMessage carrying one JSON-RPC
//     2.0 request, answered by the extension's handleAppMessage from
//     its in-process core session. The four stream methods
//     (traffic.watch, connection.watch, log.watch, dns.watch) read the
//     snapshot files the extension writes to the App Group container
//     (see PacketTunnelProvider.swift). `.live` only works while the
//     VPN tunnel is running; otherwise calls throw TunnelError
//     (notRunning) and the stores surface it as lastError.
//   - `.sample`: explicit fallback. The client answers from built-in
//     sample data, encoded to JSON and decoded again, so the Codable
//     request/response path is the same code the live path uses. Sample
//     data is labelled "示例数据" in the UI wherever it is shown. It is
//     NOT real core data.
//
// Wire format (verified against upstream crates/proto/src/types):
// the core speaks snake_case keys (total_up, source_ip, test_url,
// vehicle_type, ...), so the live path encodes requests with
// .convertToSnakeCase and decodes responses with .convertFromSnakeCase.
// The sample path uses plain Codable round-trips, so both decoders
// agree with the JSON each side produces. Structs with explicit
// CodingKeys spell the wire key out (ConcordConnection, MitmConfig,
// ConcordCertificateInfo).
//
// Stream protocol (upstream crates/rpc/src/session.rs, pump.rs): a
// stream call answers {"sub": N, "snapshot": ...} and events arrive as
// `$/event` notifications {"sub": N, "seq": M, "data": [...]}. The
// extension owns the subscriptions (and the $/credit refills); the app
// never subscribes directly, it only reads the snapshot files.
//
// FlClash feature -> Concord method map (see also TUN_INVESTIGATION.md):
//   Dashboard start/stop      engine.start / engine.stop, tun.start / tun.stop
//   Dashboard traffic         traffic.watch (stream) / traffic.reset
//   Dashboard outbound IP     probe.outboundIp
//   Dashboard core memory     core.stats (rss)
//   Proxies                   proxy.groups, proxy.watch, proxy.select,
//                             proxy.definition, proxy.states,
//                             delay.test / delay.run, validate.proxies
//   Profiles                  config.apply, config.validate, config.read,
//                             profile.inspect, profile.build,
//                             convert.subscription, provider.list/update
//   Rules                     rule.list, provider.list, ruleSet.dump /
//                             compile, geo.update
//   Connections               connection.watch, connection.close, network.reset
//   Logs                      log.watch, core.lastWarnings
//   DNS queries               dns.watch, dns.query, dns.clearCache,
//                             dns.flushFakeIp
//   Dashboard                 probe.outboundIp, probe.services, core.stats,
//                             core.releaseMemory
//   Settings (general)        config.general, config.patch
//   MITM                      mitm.certificate / generateCertificate /
//                             validate / issueCertificate / runScript /
//                             exchanges / exchange / body — live when the
//                             core reports features.mitm (core.capabilities).
//                             The local CA must be installed in the system
//                             trust store by the user (see SettingsView);
//                             there is no API for an app to install it.
//   NOT in Concord's API: FlClash's app-level backup/restore, theme,
//   hotkeys, IP-quality pages, and the desktop editor — those are app
//   features, not core features, and are implemented locally where they
//   make sense on iOS.

enum ConcordMode: String, CaseIterable, Identifiable {
    case sample = "示例数据"
    case live = "实时核心"

    var id: String { rawValue }
}

enum ConcordClientError: LocalizedError {
    case transport(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "传输错误：\(message)"
        case .decode(let message):
            return "解析错误：\(message)"
        }
    }
}

// MARK: - JSON value (for mitm.* results and config overlays, whose
// shapes are open-ended JSON in the schema)

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Human-readable one-line summary for status text.
    var displayString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .string(let value): return value
        case .array(let value): return value.map { $0.displayString }.joined(separator: ", ")
        case .object(let value):
            return value.map { "\($0.key): \($0.value.displayString)" }
                .sorted().joined(separator: "; ")
        }
    }
}

// MARK: JSON-RPC envelope (responses only — requests are assembled by
// the transports: the live transport embeds the already-encoded params
// JSON verbatim, the sample transport builds its envelope in
// ConcordSampleData)

struct JSONRPCResponse<Result: Decodable>: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: Result?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
    let data: String?
}

struct EmptyParams: Encodable {}
struct EmptyResult: Codable {}

// MARK: - Concord types (field names follow schema/api.json $defs;
// wire keys are snake_case — see the header comment)

struct ConcordCoreInitParams: Encodable {
    let home: String
    let sdkInt: Int?
}

struct ConcordWarning: Codable {
    let level: String
    let code: String?
    let path: String
    let message: String
}

struct ConcordProfileRef: Codable {
    let path: String
}

struct ConcordConfigOptions: Codable {
    var testUrl: String = ""
    var skipCertVerify: Bool = false
    var delayTestTimeout: Int = 0
    var mitmCapture: Bool = false
}

/// config.apply's overlay is an open JSON document, NOT a string map:
/// "The profile gives only proxies, proxy-groups, sub-rules and rules;
/// every other key, the listeners included, comes from here"
/// (upstream crates/proto/src/types/config.rs). The MITM section
/// ({"mitm": {...}}) travels here — see PacketTunnelProvider.swift.
struct ConcordConfigApplyParams: Encodable {
    var profile: ConcordProfileRef?
    var overlay: JSONValue?
    var selection: [String: String] = [:]
    var options: ConcordConfigOptions = ConcordConfigOptions()
}

struct ConcordConfigApplyResult: Codable {
    let warnings: [ConcordWarning]
}

/// config.patch accepts only the fields in ConfigPatchParams
/// (upstream crates/proto/src/types/config.rs): there is NO mitm
/// field and NO socks-port field. MITM is set via config.apply's
/// overlay instead.
struct ConcordConfigPatchParams: Encodable {
    var mode: String?
    var logLevel: String?
    var mixedPort: Int?
    var allowLan: Bool?
    var ipv6: Bool?
    var tcpConcurrent: Bool?
    var unifiedDelay: Bool?
    /// External-controller secret (core ConfigPatchParams `secret`).
    var secret: String?
    /// Local inbound auth lines, `user:password` (core
    /// ConfigPatchParams `authentication`).
    var authentication: [String]?
    /// External-controller listen address, "" = closed (core
    /// ConfigPatchParams `externalController`).
    var externalController: String?
}

struct ConcordGeneralState: Codable {
    var seq: UInt64?
    var port: Int?
    var socksPort: Int?
    var redirPort: Int?
    var tproxyPort: Int?
    var mixedPort: Int?
    var allowLan: Bool?
    var authentication: [String]?
    var skipAuthPrefixes: [String]?
    var mode: String?
    var logLevel: String?
    var ipv6: Bool?
    var tcpConcurrent: Bool?
    var unifiedDelay: Bool?
    var findProcessMode: String?
    var interfaceName: String?
    var routingMark: UInt32?
    var sniffing: Bool?
    var globalUa: String?
    var keepAliveIdle: UInt32?
    var keepAliveInterval: UInt32?
    /// The core's TUN state (config.general `tun`, upstream
    /// crates/proto TunState). Display-only on iOS: the PacketTunnel
    /// extension owns the TUN device (tun.start/tun.stop +
    /// tunnel.json), so the app never sends config.patch `tun` — it
    /// would fight the extension's tun.start. All fields optional:
    /// older cores may omit the whole object.
    var tun: ConcordTunState?
}

/// The core's TUN state (upstream crates/proto TunState).
struct ConcordTunState: Codable {
    let enable: Bool?
    let device: String?
    let stack: String?
    let autoRoute: Bool?
    let autoDetectInterface: Bool?
    let dnsHijack: [String]?
    let mtu: UInt32?
}

struct ConcordCoreStats: Codable {
    let rss: UInt64
}

struct ConcordFeatures: Codable {
    let mitm: Bool
    let ech: Bool
    let systemStack: Bool
}

struct ConcordCapabilities: Codable {
    let implementation: String
    let version: String
    let proxyTypes: [String]
    let transports: [String]
    let ruleTypes: [String]
    let ssPlugins: [String]
    let congestionControllers: [String]
    let features: ConcordFeatures
}

struct ConcordGroupInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let testUrl: String
    let expectedStatus: String?
    let fixed: String?
    let hidden: Bool
    let icon: String
    let emptyFallback: String
}

struct ConcordNodeInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let provider: String?
}

struct ConcordProxyGroups: Codable {
    let order: [String]
    let groups: [ConcordGroupInfo]
    let nodes: [ConcordNodeInfo]
}

struct ConcordProxySelectParams: Encodable {
    let group: String
    let proxy: String
}

struct ConcordProxySelectResult: Codable {
    let changed: Bool
    let seq: UInt64?
}

struct ConcordDelayTestParams: Encodable {
    let proxy: String
    let url: String?
    let timeout: UInt64?
    let expected: String?
}

struct ConcordDelayResult: Codable {
    let name: String
    let url: String
    /// Milliseconds when positive, -1 timeout, -2 failure.
    let value: Int32
}

struct ConcordRuleEntry: Codable, Identifiable {
    var id: String { "\(type) \(payload) -> \(target)" }
    let type: String
    let payload: String
    let target: String
}

struct ConcordRuleList: Codable {
    let rules: [ConcordRuleEntry]
}

struct ConcordTraffic: Codable {
    let up: Int64
    let down: Int64
    let totalUp: Int64
    let totalDown: Int64
}

struct ConcordConnection: Codable, Identifiable {
    var id: UInt64 { connectionId }
    let connectionId: UInt64
    let start: Int64
    let network: String
    let sourceIp: String
    let sourcePort: Int
    let destinationIp: String?
    let destinationPort: Int
    let host: String?
    let sniffHost: String?
    let inboundType: String
    let inboundIp: String?
    let inboundPort: Int?
    let inboundName: String?
    let inboundUser: String?
    let dnsMode: String?
    let uid: UInt32?
    let process: String?
    let processPath: String?
    let upload: Int64?
    let download: Int64?
    let rule: String?
    let proxy: String?
    /// Present since the upstream 83bfbae schema (ConnectionInfo
    /// `rematchName`); older cores omit it and it decodes as nil.
    let rematchName: String? = nil

    // Wire keys are snake_case (upstream crates/proto/src/types/live.rs:
    // ConnectionInfo). Explicit keys because the synthesized ones would
    // be camelCase and would not match the live wire format.
    enum CodingKeys: String, CodingKey {
        case connectionId = "id"
        case start, network
        case sourceIp = "source_ip"
        case sourcePort = "source_port"
        case destinationIp = "destination_ip"
        case destinationPort = "destination_port"
        case host
        case sniffHost = "sniff_host"
        case inboundType = "inbound_type"
        case inboundIp = "inbound_ip"
        case inboundPort = "inbound_port"
        case inboundName = "inbound_name"
        case inboundUser = "inbound_user"
        case dnsMode = "dns_mode"
        case uid, process
        case processPath = "process_path"
        case upload, download, rule, proxy
        case rematchName = "rematch_name"
    }
}

struct ConcordConnectionSnapshot: Codable {
    let connections: [ConcordConnection]
}

struct ConcordLogEntry: Codable, Identifiable {
    var id: String { "\(time)-\(text)" }
    let level: String
    let time: Int64
    let text: String
}

struct ConcordLogSnapshot: Decodable {
    let entries: [ConcordLogEntry]
}

struct ConcordDnsEntry: Codable, Identifiable {
    var id: String { "\(time)-\(domain)-\(type)" }
    let domain: String
    let type: String
    let initiator: String
    let upstream: String
    let cached: Bool?
    let answers: [String]
    let rcode: String?
    let error: String?
    let delay: Int64
    let time: Int64
}

struct ConcordDnsSnapshot: Decodable {
    let entries: [ConcordDnsEntry]
}

struct ConcordSubscriptionInfo: Codable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64
}

struct ConcordProviderInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let vehicleType: String
    let count: UInt64
    let path: String
    let updatedAt: Int64?
    let testUrl: String?
    let expectedStatus: String?
    let behavior: String?
    let format: String?
    /// Subscription traffic info (provider.get only; provider.list
    /// omits it). Nil on cores that do not report it. No default on
    /// purpose: a `let` with a default is excluded from the
    /// memberwise initializer on this toolchain (see run #69), so
    /// every construction passes it explicitly.
    let subscriptionInfo: ConcordSubscriptionInfo?
}

struct ConcordProviderList: Codable {
    let providers: [ConcordProviderInfo]
}

struct ConcordProfileInspect: Codable {
    let digest: String
    let matchRules: [String]
    let proxies: UInt64
    let proxyGroups: UInt64
    let rules: UInt64
}

struct ConcordOutboundIp: Codable {
    let url: String
    let body: String
    let delay: Int64
    let chains: [String]
    let error: String?
    let epoch: UInt64
    let version: UInt64
    /// The routing decisions this probe recorded (upstream
    /// crates/engine/src/probe/hits.rs). route.check re-validates
    /// them later; nil on cores that do not report hits.
    let hits: [ConcordRouteHit]? = nil
    let nodeHits: [ConcordRouteHit]? = nil
}

enum ConcordTunSource: Codable {
    case device(name: String?)
    case inherited(handle: UInt64)
    /// Option B packet channel (patched tree): the handle from
    /// concord_ios_packet_channel_open. This is the source the
    /// PacketTunnel extension uses; the app never builds one itself.
    case channel(handle: UInt64)

    enum CodingKeys: String, CodingKey { case kind, name, handle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "device": self = .device(name: try c.decodeIfPresent(String.self, forKey: .name))
        case "inherited": self = .inherited(handle: try c.decode(UInt64.self, forKey: .handle))
        case "channel": self = .channel(handle: try c.decode(UInt64.self, forKey: .handle))
        default: self = .device(name: nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device(let name):
            try c.encode("device", forKey: .kind)
            try c.encodeIfPresent(name, forKey: .name)
        case .inherited(let handle):
            try c.encode("inherited", forKey: .kind)
            try c.encode(handle, forKey: .handle)
        case .channel(let handle):
            try c.encode("channel", forKey: .kind)
            try c.encode(handle, forKey: .handle)
        }
    }
}

struct ConcordTunStartParams: Encodable {
    let source: ConcordTunSource
    let stack: String?
    let mtu: UInt32?
    let address: [String]
    let dns: [String]
    let congestionController: String?
}

// MARK: - MITM types (upstream crates/mitm/src/config.rs,
// crates/proto/src/types/probe.rs)
//
// RawConfig is kebab-case on the wire (#[serde(rename_all =
// "kebab-case")]), so the keys are spelled out: "decrypt-tls" and
// "ca-fingerprint", NOT the snake_case the live encoder would produce.
// mitm.certificate's `certificate` is a CertificateInfo
// {pem, fingerprint, subject, "not-before", "not-after"}; it is absent
// while no CA exists.

/// The `limits` object of the core's MitmSection (upstream
/// crates/config/src/mitm/mod.rs): only the keys set here are sent;
/// the rest keep the core's defaults. FlClash puts
/// `capture-entries` here (its `capture` switch itself is not a
/// core field — it travels as config.apply's `options.mitm_capture`).
struct MitmLimitsConfig: Codable {
    var captureEntries: Int? = nil

    enum CodingKeys: String, CodingKey {
        case captureEntries = "capture-entries"
    }
}

struct MitmConfig: Codable {
    var enable: Bool = false
    var hostname: [String] = []
    var skipServerCertVerify: Bool = false
    var decryptTls: Bool = true
    var caFingerprint: String = ""
    var h2: Bool = false
    /// FlClash Mitm.autoQuicBlock (default true in the core:
    /// auto_quic_block.unwrap_or(true)). QUIC hides its TLS
    /// handshake in UDP, so without blocking it the client never
    /// falls back to decryptable TCP+TLS.
    var autoQuicBlock: Bool = true
    /// Hosts whose servers' certificates go unchecked while the
    /// global skip switch is off (core
    /// `skip-server-cert-verify-hostname`).
    var skipVerifyHostname: [String] = []
    /// The clients decrypted for, in Surge's syntax (core
    /// `client-source-address`); empty means all of them.
    var clientSourceAddress: [String] = []
    /// Request-body mocks, in map-local line syntax (core
    /// `request-body-mock`, compiled like map-local).
    var requestBodyMock: [String] = []
    var limits: MitmLimitsConfig? = nil
    /// The core's MITM lists (RawConfig keys, kebab-case). The
    /// Settings page only fills hostname; the merged module lists
    /// (MitmModuleStore.mergedConfig) fill these for mitm.validate.
    /// Empty lists encode as [] and the core treats them as absent.
    var urlRewrite: [String] = []
    var headerRewrite: [String] = []
    var bodyRewrite: [String] = []
    var mapLocal: [String] = []
    var script: [String] = []

    enum CodingKeys: String, CodingKey {
        case enable, hostname
        case skipServerCertVerify = "skip-server-cert-verify"
        case decryptTls = "decrypt-tls"
        case caFingerprint = "ca-fingerprint"
        case h2
        case autoQuicBlock = "auto-quic-block"
        case skipVerifyHostname = "skip-server-cert-verify-hostname"
        case clientSourceAddress = "client-source-address"
        case requestBodyMock = "request-body-mock"
        case limits
        case urlRewrite = "url-rewrite"
        case headerRewrite = "header-rewrite"
        case bodyRewrite = "body-rewrite"
        case mapLocal = "map-local"
        case script
    }
}

struct ConcordCertificateInfo: Codable {
    let pem: String
    let fingerprint: String
    let subject: String
    let notBefore: String
    let notAfter: String

    enum CodingKeys: String, CodingKey {
        case pem, fingerprint, subject
        case notBefore = "not-before"
        case notAfter = "not-after"
    }
}

struct ConcordMitmCertificate: Codable {
    let certificate: ConcordCertificateInfo?
}

struct ConcordMitmIssue: Codable {
    let index: Int
    let message: String
}

struct ConcordMitmValidateResult: Codable {
    let issues: [String: [ConcordMitmIssue]]
}

// MARK: - mitm.readModule (upstream 165154c, the 69th method)
//
// The core reads a Surge module, Loon plugin, Quantumult X snippet
// or Stash override and returns every line that takes effect, in the
// same parsed forms mitm.validate returns — plus what it cannot read
// (`issues`) and what it does not take (`ignored`). The parsed rule
// views (`views`) are kept as JSON: the app needs their counts and
// their line indices, not the parsed structs — and the core's views
// have no line form to send back, so the MITM line lists still come
// from the Swift parser (see MitmModuleParser.parseWithCore).

struct ConcordMitmModuleMeta: Codable {
    let name: String?
    let desc: String?
    let author: String?
    let icon: String?
    let homepage: String?
    let category: String?
    let system: String?
    let requirement: String?
    let argumentsDesc: String?
}

/// `kind` is an internally-tagged object: {"type": "text"} |
/// {"type": "switch"} | {"type": "select", "options": [...]}.
struct ConcordMitmModuleArgumentKind: Codable {
    let type: String
    let options: [String]?
}

struct ConcordMitmModuleArgument: Codable {
    let name: String
    let kind: ConcordMitmModuleArgumentKind
    let number: Bool
    let `default`: String
    let label: String?
    let desc: String?
    let line: UInt32
}

struct ConcordMitmModuleResource: Codable {
    let url: String
    /// script | map-local | jq.
    let kind: String
    let lines: [UInt32]
}

/// `rule` is what goes before the policy in a profile's rule line;
/// `policy` is a built-in (DIRECT, REJECT, …) or a name the host
/// maps to one of its outbounds.
struct ConcordMitmModulePolicy: Codable {
    let builtin: String?
    let named: String?

    var display: String { builtin ?? named ?? "DIRECT" }
}

struct ConcordMitmModuleRule: Codable {
    let line: UInt32
    let rule: String
    let policy: ConcordMitmModulePolicy
    let noResolve: Bool
    let extendedMatching: Bool
}

struct ConcordMitmModuleIgnored: Codable {
    let line: UInt32
    let text: String
    let reason: String
    let detail: String?
}

struct ConcordMitmModuleOff: Codable {
    /// requirement | requirementUnreadable.
    let reason: String
}

struct ConcordMitmLineEntry: Codable {
    let index: UInt32
    let view: JSONValue
}

struct ConcordMitmModuleView: Codable {
    let format: String
    let meta: ConcordMitmModuleMeta
    /// Why the module takes no effect as a whole, though its lines
    /// still read; nil when it takes effect.
    let off: ConcordMitmModuleOff?
    let arguments: [ConcordMitmModuleArgument]
    let resources: [ConcordMitmModuleResource]
    /// The lines that declare a script, whatever the arguments turn off.
    let declaredScripts: [UInt32]
    let asksConsent: Bool
    /// As mitm.validate's, plus `force-http-hostname`; an `index` is
    /// the module line.
    let issues: [String: [ConcordMitmIssue]]
    /// By list, as mitm.validate keys them; an `index` is the module line.
    let views: [String: [ConcordMitmLineEntry]]
    let rules: [ConcordMitmModuleRule]
    /// Rule-set definitions (name / domain / source); kept as JSON —
    /// the app does not apply them yet.
    let ruleSets: [JSONValue]
    /// The network edits (nameservers, hosts, routes…), in mihomo's
    /// keys; kept as JSON — the app does not apply them yet.
    let network: JSONValue
    let ignored: [ConcordMitmModuleIgnored]
}

struct ConcordMitmPem: Codable {
    let pem: String
}

struct ConcordMitmResult: Codable {
    let result: JSONValue
}

// MARK: - Validation / config-read types (config.validate,
// config.read, convert.subscription, validate.proxies)
//
// config.validate returns at most one issue: the profile's parse
// error as a plain message (upstream crates/api/src/control.rs
// maps ops::validate_config's Option<String> through Issue::message).

struct ConcordIssue: Codable {
    let path: String?
    let line: UInt32?
    let column: UInt32?
    let message: String
    /// The position of the offending item (validate.filters /
    /// validate.proxies, upstream IndexedIssue). Nil for config
    /// validation issues, which carry path/line/column instead.
    let index: UInt32? = nil
}

struct ConcordConfigValidateResult: Codable {
    let issues: [ConcordIssue]
}

struct ConcordIssueList: Codable {
    let issues: [ConcordIssue]
}

struct ConcordConfigReadResult: Codable {
    let config: JSONValue
    let file: String?
    let size: UInt64?
}

struct ConcordProxyList: Codable {
    let proxies: [JSONValue]
}

struct ConcordTextResult: Codable {
    let text: String?
    let file: String?
    let size: UInt64?
}

struct ConcordOutputInline: Encodable {
    let inline: Bool
}

// MARK: - Proxy definition / states (proxy.definition, proxy.states)

struct ConcordProxyDefinition: Codable {
    let proxy: JSONValue
}

struct ConcordDelayRecord: Codable {
    let time: Int64
    /// 0 is a failed test.
    let delay: UInt16
}

struct ConcordUrlHealth: Codable {
    let url: String
    let alive: Bool
    let history: [ConcordDelayRecord]
}

struct ConcordProxyState: Codable, Identifiable {
    var id: String { name }
    let name: String
    let udp: Bool
    let alive: Bool
    let history: [ConcordDelayRecord]
    let extra: [ConcordUrlHealth]
}

struct ConcordProxyStates: Codable {
    let proxies: [ConcordProxyState]
}

// MARK: - delay.run (stream; snapshot is empty, events are results
// then `done` — upstream crates/api/src/watch.rs). The extension
// accumulates the events into snapshots/delay.json; the app polls it.

struct DelayRunStart: Codable {
    let sub: Int
    let snapshot: EmptyResult?
}

struct DelayRunSnapshot: Codable {
    let runId: Int?
    let done: Bool
    let results: [ConcordDelayResult]
}

// MARK: - DNS query / probe.services / geo / rule sets

struct ConcordDnsQuestion: Codable {
    let name: String
    let qtype: UInt16
    let qclass: UInt16
}

struct ConcordDnsRecord: Codable {
    let name: String
    let rtype: UInt16
    let ttl: UInt32
    let data: String
}

struct ConcordDnsQueryResult: Codable {
    let rcode: UInt16
    let questions: [ConcordDnsQuestion]
    let truncated: Bool
    let recursionDesired: Bool
    let recursionAvailable: Bool
    let authenticData: Bool
    let checkingDisabled: Bool
    let answers: [ConcordDnsRecord]
    let authorities: [ConcordDnsRecord]
    let additionals: [ConcordDnsRecord]
}

/// One routing decision a probe recorded (upstream
/// crates/proto RouteHit). `proxy` is a plain string on the wire —
/// the core omits it when empty and rejects JSON null — so it
/// defaults to "" here instead of being Optional.
struct ConcordRouteHit: Codable {
    let host: String
    var proxy: String = ""
    let exit: String
}

/// The answer to route.check (upstream crates/proto RouteCheckResult).
/// `held[i]` says route i still leaves where it did; `epoch` and
/// `version` are the stamp the answers were checked against.
struct ConcordRouteCheckResult: Codable {
    let epoch: UInt64
    let version: UInt64
    let held: [Bool]
}

struct ConcordServiceItem: Codable, Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let region: String?
    let delay: Int64?
    let chains: [String]?
    let checkedAt: Int64
    let epoch: UInt64
    let version: UInt64
    let hits: [ConcordRouteHit]?
}

struct ConcordServiceList: Codable {
    let items: [ConcordServiceItem]
}

// MARK: - Remaining APIs, batch 2 (profile.outbounds / clearEffect,
// convert.encodeLinks / decodeLinks, provider.get / sideLoad /
// healthCheck, route.watch / events.watch / engine.state,
// network.update)

/// One outbound (proxy or proxy-group) a profile declares
/// (profile.outbounds result).
struct ConcordOutboundRef: Codable {
    let name: String
    let type: String
}

struct ConcordProfileOutbounds: Codable {
    let proxies: [ConcordOutboundRef]
    let proxyGroups: [ConcordOutboundRef]
}

/// Encoded share links (convert.encodeLinks result).
struct ConcordLinkList: Codable {
    let links: [String]
}

/// Decoded links (convert.decodeLinks result): one entry per input
/// line, empty when the line is not a link.
struct ConcordDecodedLinks: Codable {
    let results: [[JSONValue]]
}

/// The live routing stamp (route.watch snapshot + events).
/// `epoch`/`version` move whenever the routing table changes;
/// `running` says whether the listeners were running when `epoch`
/// last moved. No default on `running` on purpose: the core always
/// serializes it (serde `default`, no skip), and a `let` with a
/// default is excluded from the memberwise initializer on this
/// toolchain (see run #69).
struct ConcordRouteStamp: Codable {
    let epoch: UInt64
    let version: UInt64
    let running: Bool
}

/// One core event (events.watch). A `oneOf` in the schema — decoded
/// here as one struct with the fields of every variant; only the
/// fields of the event's `type` are set.
struct ConcordCoreEvent: Codable {
    let type: String
    let kind: String?
    let name: String?
    let phase: String?
    let error: String?
    let url: String?
    let value: Int32?
    let message: String?
    let seq: Int64?
    let origin: String?
    let change: JSONValue?

    /// One-line summary for the events feed.
    var summary: String {
        switch type {
        case "resourceUpdate":
            let base = "提供方更新：\(name ?? "—")（\(phase ?? "—")）"
            if let error, !error.isEmpty { return base + "：\(error)" }
            return base
        case "dialerLoop":
            return "拨号循环：\(name ?? "—")"
        case "delay":
            return "测速：\(name ?? "—") \(url ?? "") \(value.map { "\($0) ms" } ?? "—")"
        case "fatal":
            return "致命错误：\(message ?? "—")"
        case "stateChanged":
            return "状态变化 #\(seq.map { "\($0)" } ?? "—")（来自 \(origin ?? "—")）"
        default:
            return type
        }
    }
}

/// The events.watch snapshot file: the buffered CoreEvent items.
/// Codable (not just Decodable): the sample transport wraps it in
/// AnyEncodable, which requires Encodable.
struct ConcordEventSnapshot: Codable {
    let entries: [ConcordCoreEvent]
}

/// One service that did not start (engine.state faults).
struct ConcordServiceFault: Codable {
    let service: String
    let address: String?
    let reason: String
    let message: String
}

/// The engine status (engine.state snapshot + events). `state` is
/// one of created / initialized / configured / running / failed;
/// `kind` says why it is `failed`.
struct ConcordEngineStatus: Codable {
    let state: String
    let kind: String?
    let faults: [ConcordServiceFault]?
}

struct ConcordRuleSetInfo: Codable {
    let behavior: String
    let format: String
}

/// The service names the core's prober knows (upstream
/// crates/engine/src/probe/services.rs `default_checkers`, in the
/// order the FlClash UI expects).
let concordProbeServiceNames = [
    "google", "github", "youtube", "chatgpt", "claude", "gemini",
    "netflix", "disney-plus", "prime-video", "spotify", "tiktok",
    "discord", "bilibili",
]

// MARK: - MITM capture types (mitm.exchanges / exchange / body)
//
// Wire keys are kebab-case ("request-size", "original-url",
// "request-header") — spelled out, NOT the snake_case the live
// encoder would produce (upstream crates/mitm/src/capture.rs).

struct MitmExchangeSummary: Codable, Identifiable {
    var id: Int64 { exchangeId }
    let exchangeId: Int64
    /// RFC 3339 timestamp.
    let start: String
    let pending: Bool?
    /// Milliseconds.
    let duration: Int64
    let method: String
    let url: String
    let status: Int32
    let requestSize: Int64
    let responseSize: Int64
    let error: String?

    enum CodingKeys: String, CodingKey {
        case exchangeId = "id"
        case start, pending, duration, method, url, status
        case requestSize = "request-size"
        case responseSize = "response-size"
        case error
    }
}

struct MitmExchangeList: Codable {
    let capturing: Bool
    let since: String?
    let exchanges: [MitmExchangeSummary]
}

struct MitmBody: Codable {
    /// Base64-encoded body bytes.
    let data: String
    let truncated: Bool?
    let encoding: String?

    /// Decoded body as text when it is valid UTF-8, else nil.
    var text: String? {
        guard let bytes = Data(base64Encoded: data) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

extension JSONValue {
    /// Re-decodes this open JSON value as a typed struct (used for
    /// mitm.exchanges / exchange, whose results are open JSON).
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Pretty-printed JSON for the detail views.
    var prettyPrinted: String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return displayString
        }
        return text
    }
}

// MARK: - Transports

protocol ConcordTransport {
    func send<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result
}

/// Sample transport: answers from built-in sample data. The sample structs
/// are encoded to JSON and decoded again through the normal JSON-RPC path,
/// so Codable errors in the real types surface here too.
struct MockConcordTransport: ConcordTransport {
    func send<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
        let data = try ConcordSampleData.jsonResponse(for: method, paramsData: paramsData)
        let envelope = try JSONDecoder().decode(JSONRPCResponse<Result>.self, from: data)
        if let error = envelope.error {
            throw ConcordClientError.transport(error.message)
        }
        guard let result = envelope.result else {
            throw ConcordClientError.decode("empty result for \(method)")
        }
        return result
    }
}

/// Live transport: talks to the real core in the PacketTunnel extension
/// process (see the header comment). Unary methods are one JSON-RPC
/// request per sendProviderMessage; the stream methods read the
/// snapshot files the extension writes to the App Group container.
///
/// The extension owns the stream subscriptions, so the app never sends
/// a traffic.watch / connection.watch / log.watch / dns.watch request
/// itself — `send` intercepts those methods and reads the file instead.
final class ExtensionConcordTransport: ConcordTransport {
    private let lock = NSLock()
    private var nextID = 1

    private func takeNextID() -> Int {
        // Plain lock/unlock rather than `NSLock.withLock`, which needs
        // a newer toolchain than this project's Xcode 15.0 baseline.
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private static let liveDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Stream methods and the snapshot file + freshness rule for each.
    /// Traffic / connections go stale fast (10 s); logs / dns only
    /// change when an event arrives, so any existing file is the latest
    /// known buffer (a missing file means the tunnel never wrote one).
    /// proxy.watch is the same: groups change rarely, and the extension
    /// rewrites the file on every subscribe, so any existing file is
    /// the last known table. delay.run.poll reads the run accumulator
    /// the extension writes while a batch delay test is in flight.
    /// route.watch / engine.state are latest-policy streams too — the
    /// file only changes when the stamp/state moves, so any existing
    /// file is the last known value. events.watch accumulates into a
    /// buffer like log/dns.watch.
    private static let streamSnapshots: [String: (file: String, maxAgeSeconds: TimeInterval?)] = [
        "traffic.watch": ("traffic", 10),
        "connection.watch": ("connections", 10),
        "log.watch": ("logs", nil),
        "dns.watch": ("dns", nil),
        // proxy.watch used to have no max-age, so a stale
        // proxies.json (written by a previous tunnel run, or an
        // empty one from a run whose core had not finished
        // applying) was served as current forever — the v0.2.31
        // "节点也看不见" report. 10 s, like traffic/connections:
        // a stale snapshot throws and the caller falls back to
        // proxy.groups, then to the local YAML.
        "proxy.watch": ("proxies", 10),
        "delay.run.poll": ("delay", nil),
        "route.watch": ("route", nil),
        "events.watch": ("events", nil),
        "engine.state": ("engine", nil),
    ]

    private struct SnapshotFile<Payload: Decodable>: Decodable {
        let updatedAt: Int64
        let data: Payload
    }

    func send<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
        if let snapshot = Self.streamSnapshots[method] {
            return try readSnapshot(file: snapshot.file, maxAgeSeconds: snapshot.maxAgeSeconds, resultType: resultType)
        }
        let id = takeNextID()
        // Assemble the envelope by hand so paramsData (already JSON) is
        // embedded verbatim instead of being re-encoded.
        var envelope = Data()
        envelope.append(contentsOf: "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":".utf8)
        envelope.append(try JSONEncoder().encode(method))
        envelope.append(contentsOf: ",\"params\":".utf8)
        envelope.append(paramsData)
        envelope.append(contentsOf: "}".utf8)

        let reply = try await TunnelManager.shared.sendProviderMessage(envelope)
        let decoded = try Self.liveDecoder.decode(JSONRPCResponse<Result>.self, from: reply)
        if let error = decoded.error {
            throw ConcordClientError.transport(error.message)
        }
        guard let result = decoded.result else {
            throw ConcordClientError.decode("empty result for \(method)")
        }
        return result
    }

    private func readSnapshot<Result: Decodable>(file: String, maxAgeSeconds: TimeInterval?, resultType: Result.Type) throws -> Result {
        guard let url = ConfigStore.snapshotURL(name: file),
              let data = try? Data(contentsOf: url) else {
            throw TunnelError.notRunning
        }
        let snapshot = try Self.liveDecoder.decode(SnapshotFile<Result>.self, from: data)
        if let maxAgeSeconds {
            let age = Date().timeIntervalSince1970 * 1000 - Double(snapshot.updatedAt)
            if age > maxAgeSeconds * 1000 {
                throw ConcordClientError.transport("实时快照已过期（\(file)，\(Int(age / 1000))s 前）：隧道可能已断开")
            }
        }
        return snapshot.data
    }
}

// MARK: - Client

final class ConcordClient: ObservableObject {
    /// `.live` is the default: real core data via the extension. The
    /// user's explicit choice is persisted; `.sample` is only an
    /// explicit fallback and stays labelled "示例数据" everywhere.
    @Published var mode: ConcordMode = .live {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeStorageKey)
        }
    }
    @Published var lastError: String?

    private static let modeStorageKey = "ConcordiOS.mode.v1"

    private static let requestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Wire keys are snake_case (see the header comment). The sample
        // transport only reads the "proxy" key out of paramsData, so
        // this encoding is safe for both modes.
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let sampleTransport = MockConcordTransport()
    private let liveTransport = ExtensionConcordTransport()

    private var transport: ConcordTransport {
        switch mode {
        case .sample: return sampleTransport
        case .live: return liveTransport
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.modeStorageKey),
           let savedMode = ConcordMode(rawValue: saved) {
            mode = savedMode
        }
    }

    /// Re-read the persisted core mode (used after a backup restore:
    /// the restore writes the key behind this client's back).
    func reloadMode() {
        if let saved = UserDefaults.standard.string(forKey: Self.modeStorageKey),
           let savedMode = ConcordMode(rawValue: saved) {
            mode = savedMode
        }
    }

    func call<Result: Decodable>(method: String, params: Encodable, resultType: Result.Type) async throws -> Result {
        let paramsData = try Self.requestEncoder.encode(AnyEncodable(params))
        return try await transport.send(method: method, paramsData: paramsData, resultType: resultType)
    }

    func call<Result: Decodable>(method: String, resultType: Result.Type) async throws -> Result {
        try await call(method: method, params: EmptyParams(), resultType: resultType)
    }

    // MARK: Core lifecycle (core.init -> config.apply -> engine.start -> tun.start)
    // In live mode these run in the extension process (the app sends
    // them over IPC); core.init / tun.start are normally driven by the
    // extension's own startTunnel, not by the UI.

    func coreInit(home: String) async throws {
        _ = try await call(method: "core.init", params: ConcordCoreInitParams(home: home, sdkInt: nil), resultType: EmptyResult.self)
    }

    func coreCapabilities() async throws -> ConcordCapabilities {
        try await call(method: "core.capabilities", resultType: ConcordCapabilities.self)
    }

    func configApply(profilePath: String?, selection: [String: String] = [:], overlay: JSONValue? = nil) async throws -> ConcordConfigApplyResult {
        try await call(method: "config.apply", params: ConcordConfigApplyParams(profile: profilePath.map { ConcordProfileRef(path: $0) }, overlay: overlay, selection: selection), resultType: ConcordConfigApplyResult.self)
    }

    func configGeneral() async throws -> ConcordGeneralState {
        try await call(method: "config.general", resultType: ConcordGeneralState.self)
    }

    func configPatch(_ params: ConcordConfigPatchParams) async throws {
        _ = try await call(method: "config.patch", params: params, resultType: EmptyResult.self)
    }

    func engineStart() async throws {
        _ = try await call(method: "engine.start", resultType: EmptyResult.self)
    }

    func engineStop() async throws {
        _ = try await call(method: "engine.stop", resultType: EmptyResult.self)
    }

    func tunStart(source: ConcordTunSource, stack: String? = nil, mtu: UInt32? = nil, address: [String] = [], dns: [String] = []) async throws {
        _ = try await call(method: "tun.start", params: ConcordTunStartParams(source: source, stack: stack, mtu: mtu, address: address, dns: dns, congestionController: nil), resultType: EmptyResult.self)
    }

    func tunStop() async throws {
        _ = try await call(method: "tun.stop", resultType: EmptyResult.self)
    }

    // MARK: Proxies / delay

    func proxyGroups() async throws -> ConcordProxyGroups {
        try await call(method: "proxy.groups", resultType: ConcordProxyGroups.self)
    }

    /// proxy.watch as the extension serves it: the extension subscribes
    /// once at startup and writes snapshots/proxies.json on every
    /// snapshot / delta; this reads that file (see
    /// ExtensionConcordTransport.streamSnapshots). Use it for refreshes;
    /// fall back to proxy.groups when the file is missing.
    func proxyWatchSnapshot() async throws -> ConcordProxyGroups {
        try await call(method: "proxy.watch", resultType: ConcordProxyGroups.self)
    }

    func proxySelect(group: String, proxy: String) async throws -> ConcordProxySelectResult {
        try await call(method: "proxy.select", params: ConcordProxySelectParams(group: group, proxy: proxy), resultType: ConcordProxySelectResult.self)
    }

    /// The node definition as the profile wrote it (proxy.definition
    /// returns the configured mapping as open JSON).
    func proxyDefinition(name: String) async throws -> JSONValue {
        struct ProxyDefinitionParams: Encodable { let name: String }
        return try await call(method: "proxy.definition", params: ProxyDefinitionParams(name: name), resultType: ConcordProxyDefinition.self).proxy
    }

    /// Liveness / delay history per node (proxy.states). `names` nil
    /// lists every name proxy.groups lists.
    func proxyStates(names: [String]? = nil) async throws -> [ConcordProxyState] {
        struct ProxyStatesParams: Encodable { let names: [String]? }
        return try await call(method: "proxy.states", params: ProxyStatesParams(names: names), resultType: ConcordProxyStates.self).proxies
    }

    func delayTest(proxy: String, url: String? = nil, timeout: UInt64? = nil) async throws -> ConcordDelayResult {
        try await call(method: "delay.test", params: ConcordDelayTestParams(proxy: proxy, url: url, timeout: timeout, expected: nil), resultType: ConcordDelayResult.self)
    }

    /// Starts a batch delay test (delay.run, a stream). The reply is
    /// the subscription ({sub, snapshot}); the results arrive as events
    /// the extension accumulates into snapshots/delay.json — poll them
    /// with delayRunPoll(). The run ends by itself with a `done` event.
    func delayRunStart(proxies: [String], url: String? = nil, timeout: UInt64? = nil, concurrency: UInt32? = nil) async throws -> DelayRunStart {
        struct DelayRunParams: Encodable {
            let proxies: [String]
            let url: String?
            let timeout: UInt64?
            let concurrency: UInt32?
        }
        return try await call(method: "delay.run", params: DelayRunParams(proxies: proxies, url: url, timeout: timeout, concurrency: concurrency), resultType: DelayRunStart.self)
    }

    /// Polls the delay.run accumulator file (see delayRunStart). Throws
    /// TunnelError.notRunning while the extension has not written the
    /// file yet — the caller should keep polling briefly, not fail.
    func delayRunPoll() async throws -> DelayRunSnapshot {
        try await call(method: "delay.run.poll", resultType: DelayRunSnapshot.self)
    }

    // MARK: Profiles / providers / rules

    /// Validates a profile file (config.validate). The core only parses
    /// the file, so the result is at most one issue: the parse error as
    /// a plain message. `profilePath` must be absolute: the core reads
    /// it with a plain fs::read in the extension process, where a
    /// relative path would resolve against an undocumented working
    /// directory (upstream crates/engine/src/ops.rs).
    func configValidate(profilePath: String) async throws -> [ConcordIssue] {
        struct ConfigValidateParams: Encodable { let profile: ConcordProfileRef }
        return try await call(method: "config.validate", params: ConfigValidateParams(profile: ConcordProfileRef(path: profilePath)), resultType: ConcordConfigValidateResult.self).issues
    }

    /// Reads a profile file back as parsed JSON (config.read). Used to
    /// fetch the `proxies` array for validate.proxies.
    func configRead(profilePath: String) async throws -> ConcordConfigReadResult {
        struct ConfigReadParams: Encodable {
            let profile: ConcordProfileRef
            let output: ConcordOutputInline
        }
        return try await call(method: "config.read", params: ConfigReadParams(profile: ConcordProfileRef(path: profilePath), output: ConcordOutputInline(inline: true)), resultType: ConcordConfigReadResult.self)
    }

    /// Converts a subscription file into its proxy definitions
    /// (convert.subscription) — the node list a profile actually yields.
    func convertSubscription(profilePath: String) async throws -> [JSONValue] {
        struct ConvertSubscriptionParams: Encodable { let profile: ConcordProfileRef }
        return try await call(method: "convert.subscription", params: ConvertSubscriptionParams(profile: ConcordProfileRef(path: profilePath)), resultType: ConcordProxyList.self).proxies
    }

    /// Validates proxy mappings (validate.proxies). The mappings come
    /// from config.read's `proxies` array.
    func validateProxies(proxies: [JSONValue]) async throws -> [ConcordIssue] {
        struct ValidateProxiesParams: Encodable { let proxies: [JSONValue] }
        return try await call(method: "validate.proxies", params: ValidateProxiesParams(proxies: proxies), resultType: ConcordIssueList.self).issues
    }

    // MARK: - Remaining APIs (validate.filters / route.check /
    // core.setPressure / debug.crash / config.decrypt)

    /// Validates proxy-group filter expressions (validate.filters).
    /// A filter is one backtick-separated regex list, e.g.
    /// `(?i)港|hk` or `hk`jp` (upstream crates/config/src/filter.rs
    /// CompiledFilter). Returns one issue per invalid expression.
    func validateFilters(filters: [String]) async throws -> [ConcordIssue] {
        struct ValidateFiltersParams: Encodable { let filters: [String] }
        return try await call(method: "validate.filters", params: ValidateFiltersParams(filters: filters), resultType: ConcordIssueList.self).issues
    }

    /// Re-validates previously probed routes (route.check). Each route
    /// is one probe answer's hits (see ConcordRouteHit); `held[i]`
    /// says route i still leaves where it did, against the returned
    /// epoch/version stamp. A route.check is not a URL tester — the
    /// hits must come from an earlier probe (probe.services /
    /// probe.outboundIp record them).
    func routeCheck(routes: [[ConcordRouteHit]]) async throws -> ConcordRouteCheckResult {
        struct RouteCheckParams: Encodable { let routes: [[ConcordRouteHit]] }
        return try await call(method: "route.check", params: RouteCheckParams(routes: routes), resultType: ConcordRouteCheckResult.self)
    }

    /// Raises the MITM memory-pressure level (core.setPressure).
    /// Levels are 0 (none) … 3 (relay); the core clamps to 0…3 and
    /// only ever raises — the level lifts itself after a hold
    /// (upstream crates/mitm/src/limits.rs PRESSURE_*). Shedding only
    /// applies while MITM captures are active.
    func coreSetPressure(level: Int32) async throws {
        struct SetPressureParams: Encodable { let level: Int32 }
        _ = try await call(method: "core.setPressure", params: SetPressureParams(level: level), resultType: EmptyResult.self)
    }

    /// Intentionally aborts the core process (debug.crash). Only built
    /// into debug cores (concord-api `debug` feature, off in release
    /// packages); the iOS staticlib does NOT enable it, so the core
    /// answers "method not found" and nothing crashes. The UI
    /// surfaces that error instead of crashing anything.
    func debugCrash() async throws {
        _ = try await call(method: "debug.crash", resultType: EmptyResult.self)
    }

    /// Decrypts an encrypted profile with its key (config.decrypt).
    /// `profilePath` must be an absolute path inside the core's home
    /// directory; the key is passed for this one call and never
    /// stored. Returns the plaintext (inline output).
    func configDecrypt(profilePath: String, key: String) async throws -> String {
        struct ConfigDecryptParams: Encodable {
            let profile: ConcordProfileRef
            let key: String
            let output: ConcordOutputInline
        }
        let result = try await call(method: "config.decrypt", params: ConfigDecryptParams(profile: ConcordProfileRef(path: profilePath), key: key, output: ConcordOutputInline(inline: true)), resultType: ConcordTextResult.self)
        return result.text ?? ""
    }

    // MARK: - Remaining APIs, batch 2 (profile.outbounds /
    // clearEffect, convert.encodeLinks / decodeLinks, provider.get /
    // sideLoad / healthCheck, network.update)

    /// Lists the outbounds (proxies + proxy-groups) a profile
    /// declares (profile.outbounds). Same ProfileParams shape as
    /// profile.inspect: an absolute path inside the core's home.
    func profileOutbounds(profilePath: String) async throws -> ConcordProfileOutbounds {
        struct ProfileOutboundsParams: Encodable { let profile: ConcordProfileRef }
        return try await call(method: "profile.outbounds", params: ProfileOutboundsParams(profile: ConcordProfileRef(path: profilePath)), resultType: ConcordProfileOutbounds.self)
    }

    /// Clears the downloaded provider files of one core-side profile
    /// (profile.clearEffect). `profileId` is the numeric id the host
    /// assigned that profile (must be positive); the core deletes
    /// `profiles/providers/<id>` — a missing directory is not an
    /// error. On iOS the app never assigns numeric profile ids and
    /// the core keeps its own provider downloads under `providers/`,
    /// so this usually finds nothing to clear; the call itself is
    /// still the real upstream method.
    func profileClearEffect(profileId: Int64) async throws {
        struct ClearEffectParams: Encodable { let profileId: Int64 }
        _ = try await call(method: "profile.clearEffect", params: ClearEffectParams(profileId: profileId), resultType: EmptyResult.self)
    }

    /// Encodes proxy definitions into share links
    /// (convert.encodeLinks). `proxies` are the open proxy mappings
    /// (as in config.read's `proxies` list).
    func convertEncodeLinks(proxies: [JSONValue]) async throws -> [String] {
        struct EncodeLinksParams: Encodable { let proxies: [JSONValue] }
        return try await call(method: "convert.encodeLinks", params: EncodeLinksParams(proxies: proxies), resultType: ConcordLinkList.self).links
    }

    /// Decodes pasted share links into proxy definitions
    /// (convert.decodeLinks). One result entry per input line, empty
    /// when the line is not a link. The lines are only sent to the
    /// core for decoding — nowhere else.
    func convertDecodeLinks(lines: [String]) async throws -> [[JSONValue]] {
        struct DecodeLinksParams: Encodable { let lines: [String] }
        return try await call(method: "convert.decodeLinks", params: DecodeLinksParams(lines: lines), resultType: ConcordDecodedLinks.self).results
    }

    /// Fetches one provider's full detail (provider.get). Unlike
    /// provider.list, the result carries `subscriptionInfo` when the
    /// provider is a subscription.
    func providerGet(name: String) async throws -> ConcordProviderInfo {
        struct ProviderNameParams: Encodable { let name: String }
        return try await call(method: "provider.get", params: ProviderNameParams(name: name), resultType: ConcordProviderInfo.self)
    }

    /// Loads a provider from inline content (provider.sideLoad).
    /// `data` is the provider file's text (YAML / MRS / text),
    /// stored by the core under `name`. Local content only — the
    /// method itself does no network fetch.
    func providerSideLoad(name: String, data: String) async throws {
        struct ProviderSideLoadParams: Encodable { let name: String; let data: String }
        _ = try await call(method: "provider.sideLoad", params: ProviderSideLoadParams(name: name, data: data), resultType: EmptyResult.self)
    }

    /// Triggers a provider's health check (provider.healthCheck).
    /// The check runs in the background; the call only reports
    /// whether it could be started (upstream
    /// crates/api/src/control.rs provider_health_check).
    func providerHealthCheck(name: String) async throws {
        struct ProviderNameParams: Encodable { let name: String }
        _ = try await call(method: "provider.healthCheck", params: ProviderNameParams(name: name), resultType: EmptyResult.self)
    }

    /// Tells the core the system network changed (network.update).
    /// `dnsServers` are the socket addresses of the resolvers the
    /// system now uses (nil = unchanged); `interfaceChanged` means
    /// the default network changed, so connections over the old one
    /// are closed (upstream crates/api/src/control.rs
    /// network_update).
    func networkUpdate(dnsServers: [String]? = nil, interfaceChanged: Bool = false) async throws {
        struct NetworkUpdateParams: Encodable { let dnsServers: [String]?; let interfaceChanged: Bool }
        _ = try await call(method: "network.update", params: NetworkUpdateParams(dnsServers: dnsServers, interfaceChanged: interfaceChanged), resultType: EmptyResult.self)
    }

    /// Builds the effective config text from a profile + overlay
    /// (profile.build) — the merged YAML the core would apply.
    func profileBuild(profilePath: String, overlay: JSONValue = .object([:])) async throws -> String {
        struct ProfileBuildParams: Encodable {
            let profile: ConcordProfileRef
            let overlay: JSONValue
            let output: ConcordOutputInline
        }
        return try await call(method: "profile.build", params: ProfileBuildParams(profile: ConcordProfileRef(path: profilePath), overlay: overlay, output: ConcordOutputInline(inline: true)), resultType: ConcordTextResult.self).text ?? ""
    }

    func profileInspect(path: String) async throws -> ConcordProfileInspect {
        // profile.inspect takes ProfileParams { path } in the schema.
        struct ProfileParams: Encodable { let path: String }
        return try await call(method: "profile.inspect", params: ProfileParams(path: path), resultType: ConcordProfileInspect.self)
    }

    func providerList() async throws -> ConcordProviderList {
        try await call(method: "provider.list", resultType: ConcordProviderList.self)
    }

    func providerUpdate(name: String) async throws {
        struct ProviderUpdateParams: Encodable { let name: String }
        _ = try await call(method: "provider.update", params: ProviderUpdateParams(name: name), resultType: EmptyResult.self)
    }

    func ruleList() async throws -> ConcordRuleList {
        try await call(method: "rule.list", resultType: ConcordRuleList.self)
    }

    /// Dumps one rule-set file's rules as text (ruleSet.dump).
    /// `path` is the provider file inside the core's home directory —
    /// pass an absolute path, as for config.validate.
    func ruleSetDump(path: String) async throws -> String {
        struct RuleSetDumpParams: Encodable {
            let profile: ConcordProfileRef
            let output: ConcordOutputInline
        }
        return try await call(method: "ruleSet.dump", params: RuleSetDumpParams(profile: ConcordProfileRef(path: path), output: ConcordOutputInline(inline: true)), resultType: ConcordTextResult.self).text ?? ""
    }

    /// Recompiles a stored rule-set (ruleSet.compile). `url` empty
    /// compiles the file already stored under that name.
    func ruleSetCompile(name: String, url: String? = nil) async throws -> ConcordRuleSetInfo {
        struct RuleSetCompileParams: Encodable { let name: String; let url: String? }
        return try await call(method: "ruleSet.compile", params: RuleSetCompileParams(name: name, url: url), resultType: ConcordRuleSetInfo.self)
    }

    /// Updates a geo database (geo.update). `kind` is one of "MMDB",
    /// "ASN", "GEOSITE" (upstream crates/engine/src/resources.rs).
    func geoUpdate(kind: String) async throws {
        struct GeoUpdateParams: Encodable { let type: String }
        _ = try await call(method: "geo.update", params: GeoUpdateParams(type: kind), resultType: EmptyResult.self)
    }

    // MARK: Traffic / connections / logs / DNS
    // Live mode reads the extension's snapshot files (see
    // ExtensionConcordTransport); sample mode reads the mock snapshots.

    func trafficSnapshot() async throws -> ConcordTraffic {
        try await call(method: "traffic.watch", resultType: ConcordTraffic.self)
    }

    func trafficReset() async throws {
        _ = try await call(method: "traffic.reset", resultType: EmptyResult.self)
    }

    func connectionSnapshot() async throws -> ConcordConnectionSnapshot {
        try await call(method: "connection.watch", resultType: ConcordConnectionSnapshot.self)
    }

    func connectionClose(id: UInt64) async throws {
        // connection.close takes {ids: [...], all: bool} (upstream
        // crates/proto/src/types/live.rs: ConnectionCloseParams) — NOT
        // a single `id` field.
        struct ConnectionCloseParams: Encodable {
            let ids: [UInt64]?
            let all: Bool
        }
        _ = try await call(method: "connection.close", params: ConnectionCloseParams(ids: [id], all: false), resultType: EmptyResult.self)
    }

    func connectionCloseAll() async throws {
        struct ConnectionCloseParams: Encodable {
            let ids: [UInt64]?
            let all: Bool
        }
        _ = try await call(method: "connection.close", params: ConnectionCloseParams(ids: nil, all: true), resultType: EmptyResult.self)
    }

    func logEntries() async throws -> [ConcordLogEntry] {
        // log.watch is a stream of LogEntry events; the extension
        // accumulates them into the snapshot file, the mock returns
        // the buffered sample entries as a snapshot list.
        try await call(method: "log.watch", resultType: ConcordLogSnapshot.self).entries
    }

    func dnsEntries() async throws -> [ConcordDnsEntry] {
        try await call(method: "dns.watch", resultType: ConcordDnsSnapshot.self).entries
    }

    func dnsClearCache() async throws {
        _ = try await call(method: "dns.clearCache", resultType: EmptyResult.self)
    }

    // MARK: Route / events / engine streams (batch 2)
    // Like the other streams these read the snapshot files the
    // extension writes (route.json / events.json / engine.json).

    /// The latest routing stamp (route.watch). Latest-policy: the
    /// extension rewrites the file only when the stamp moves.
    func routeSnapshot() async throws -> ConcordRouteStamp {
        try await call(method: "route.watch", resultType: ConcordRouteStamp.self)
    }

    /// The buffered core events (events.watch). The extension
    /// accumulates events into the snapshot file (cap 500) because
    /// the app only reads the file when the Events tab is opened.
    func eventEntries() async throws -> [ConcordCoreEvent] {
        try await call(method: "events.watch", resultType: ConcordEventSnapshot.self).entries
    }

    /// The live engine status (engine.state). Latest-policy: the
    /// file is rewritten whenever the state or its faults change.
    func engineSnapshot() async throws -> ConcordEngineStatus {
        try await call(method: "engine.state", resultType: ConcordEngineStatus.self)
    }

    func dnsFlushFakeIp() async throws {
        _ = try await call(method: "dns.flushFakeIp", resultType: EmptyResult.self)
    }

    /// Runs one DNS query through the core's resolver (dns.query).
    /// `qtype` is a record type such as "A" or "AAAA" (default "A").
    func dnsQuery(name: String, qtype: String? = nil) async throws -> ConcordDnsQueryResult {
        struct DnsQueryParams: Encodable { let name: String; let qtype: String? }
        return try await call(method: "dns.query", params: DnsQueryParams(name: name, qtype: qtype), resultType: ConcordDnsQueryResult.self)
    }

    /// Resets the resolver connections (network.reset) — drops the
    /// core's open resolver connections so the next lookup re-dials.
    func networkReset() async throws {
        _ = try await call(method: "network.reset", resultType: EmptyResult.self)
    }

    // MARK: Dashboard helpers

    func coreStats() async throws -> ConcordCoreStats {
        try await call(method: "core.stats", resultType: ConcordCoreStats.self)
    }

    /// Asks the core to release cached memory (core.releaseMemory).
    /// Worth a button in Resources: the NetworkExtension process runs
    /// under a tight memory limit.
    func coreReleaseMemory() async throws {
        _ = try await call(method: "core.releaseMemory", resultType: EmptyResult.self)
    }

    func probeOutboundIp(url: String? = nil) async throws -> ConcordOutboundIp {
        struct OutboundIpParams: Encodable { let url: String? }
        return try await call(method: "probe.outboundIp", params: OutboundIpParams(url: url), resultType: ConcordOutboundIp.self)
    }

    /// Checks the known services through one proxy (probe.services).
    /// `names` are the registry names in concordProbeServiceNames.
    func probeServices(proxy: String, names: [String] = concordProbeServiceNames, timeout: UInt64? = nil) async throws -> [ConcordServiceItem] {
        struct ServicesParams: Encodable {
            let proxy: String
            let names: [String]
            let timeout: UInt64?
        }
        return try await call(method: "probe.services", params: ServicesParams(proxy: proxy, names: names, timeout: timeout), resultType: ConcordServiceList.self).items
    }

    func lastWarnings() async throws -> [ConcordWarning] {
        struct WarningsResult: Decodable { let warnings: [ConcordWarning] }
        return try await call(method: "core.lastWarnings", resultType: WarningsResult.self).warnings
    }

    // MARK: MITM (capability `mitm`; see core.capabilities features.mitm)
    //
    // The CA itself lives in the core's home directory; the app only
    // ever sees the certificate info / PEM over RPC. Installing the CA
    // into the iOS trust store is a manual user step in Settings (no
    // API exists for an app to install a trusted CA) — see SettingsView.

    func mitmCertificate() async throws -> ConcordMitmCertificate {
        try await call(method: "mitm.certificate", resultType: ConcordMitmCertificate.self)
    }

    func mitmGenerateCertificate() async throws -> ConcordMitmCertificate {
        try await call(method: "mitm.generateCertificate", resultType: ConcordMitmCertificate.self)
    }

    func mitmValidate(config: MitmConfig) async throws -> ConcordMitmValidateResult {
        struct MitmValidateParams: Encodable { let config: MitmConfig }
        return try await call(method: "mitm.validate", params: MitmValidateParams(config: config), resultType: ConcordMitmValidateResult.self)
    }

    /// Reads a module with the core (upstream 165154c): Surge,
    /// Loon, Quantumult X or Stash, as its author wrote it.
    /// `arguments` are the user-set values (an omitted argument
    /// takes its default); `attachments` are local files by the
    /// relative path the module names; `language` is the language
    /// requirement expressions read, as `zh-Hans`.
    func mitmReadModule(text: String, arguments: [String: String] = [:], attachments: [String: String] = [:], language: String = "") async throws -> ConcordMitmModuleView {
        struct MitmReadModuleParams: Encodable {
            let text: String
            let arguments: [String: String]
            let attachments: [String: String]
            let language: String
        }
        return try await call(method: "mitm.readModule", params: MitmReadModuleParams(text: text, arguments: arguments, attachments: attachments, language: language), resultType: ConcordMitmModuleView.self)
    }

    func mitmIssueCertificate(host: String) async throws -> ConcordMitmPem {
        struct MitmIssueParams: Encodable { let host: String }
        return try await call(method: "mitm.issueCertificate", params: MitmIssueParams(host: host), resultType: ConcordMitmPem.self)
    }

    func mitmRunScript(name: String) async throws -> ConcordMitmResult {
        struct MitmScriptParams: Encodable { let name: String }
        return try await call(method: "mitm.runScript", params: MitmScriptParams(name: name), resultType: ConcordMitmResult.self)
    }

    func mitmExchanges(connection: UInt64) async throws -> ConcordMitmResult {
        struct MitmExchangesParams: Encodable { let connection: UInt64 }
        return try await call(method: "mitm.exchanges", params: MitmExchangesParams(connection: connection), resultType: ConcordMitmResult.self)
    }

    func mitmExchange(id: Int64) async throws -> ConcordMitmResult {
        struct MitmExchangeParams: Encodable { let id: Int64 }
        return try await call(method: "mitm.exchange", params: MitmExchangeParams(id: id), resultType: ConcordMitmResult.self)
    }

    func mitmBody(id: Int64, response: Bool = false) async throws -> ConcordMitmResult {
        struct MitmBodyParams: Encodable { let id: Int64; let response: Bool }
        return try await call(method: "mitm.body", params: MitmBodyParams(id: id, response: response), resultType: ConcordMitmResult.self)
    }
}

/// Type-erased Encodable wrapper so `call` can take any params struct.
struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init(_ value: Encodable) {
        encodeImpl = { try value.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
