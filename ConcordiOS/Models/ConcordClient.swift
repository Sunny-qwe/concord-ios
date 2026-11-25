import Foundation
import Combine

// MARK: - Concord JSON-RPC 2.0 client
//
// Types are modelled on upstream Concord's schema/api.json (72 methods,
// checked 2026-11-22 against commit 0c9788f — mitm.query added as the
// 72nd method; ConnectionInfo gains ruleIndex / failure / timing /
// dnsQueries, ConnectionDelta gains ended with final counters,
// CoreEvent.scriptNotification gains at / connection / exchange,
// DnsEntry gains id, ServiceItem gains ip).
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
//                             validate / readModule / moduleStatus /
//                             fetchModule / issueCertificate / runScript /
//                             exchanges / exchange / body / query — live when the
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
    /// The extension core answered `config is not applied` (wire
    /// code -32603): the call raced ahead of config.apply — the
    /// same call succeeds once apply finishes, so callers swallow
    /// + retry this one error only. Same wire note as
    /// AppCoreError.configNotApplied: the engine's string code
    /// `core_error` never reaches the wire (api_error maps it to
    /// ApiError::internal), so the match is on the wire code +
    /// the exact message.
    case configNotApplied

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "传输错误：\(message)"
        case .decode(let message):
            return "解析错误：\(message)"
        case .configNotApplied:
            return "核心还在启动，请稍后再试"
        }
    }

    /// Maps one wire error object to the error the caller sees.
    /// Only the exact cold-start pair (code -32603, message
    /// `config is not applied`) becomes .configNotApplied; every
    /// other error keeps the old .transport(message) verbatim.
    static func fromRPCError(_ error: JSONRPCError) -> ConcordClientError {
        if error.code == -32603 && error.message == "config is not applied" {
            return .configNotApplied
        }
        return .transport(error.message)
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
    /// The wire `data` is always an OBJECT ({"kind": ...} —
    /// proto ErrorData, e.g. {"kind": "internal"}). It was
    /// `String?`, so decoding ANY error response threw a
    /// DecodingError here and the core's message never reached
    /// the caller (the tunnel path could not even recognise
    /// `config is not applied`). JSONValue holds the object;
    /// no caller reads it today.
    let data: JSONValue?
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
    /// Find-process mode ("strict"/"always"/"off"; core
    /// ConfigPatchParams `find_process_mode`, wire key snake_case
    /// like the other fields — the Rust struct's fields are
    /// snake_case and the client's encoder converts to snake_case).
    var findProcessMode: String?
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
    /// Audit A4: the five schema-required fields config.general
    /// used to drop (upstream crates/proto/src/types/state.rs,
    /// GeneralState): disable_keep_alive (bool), geo_auto_update
    /// (bool), geo_update_interval (u32 seconds), geox_url (map
    /// keyed mmdb/asn/geosite) and selections (group -> picked
    /// proxy). All optional: older cores may omit them.
    var disableKeepAlive: Bool?
    var geoAutoUpdate: Bool?
    var geoUpdateInterval: UInt32?
    var geoxUrl: [String: String]?
    /// The pick of each group that has one.
    var selections: [String: String]?
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

/// Why a connection's dial failed (upstream 0c9788f
/// ConnectionFailure). Present only on a connection whose dial
/// failed; `connection.watch` sends it in `opened` and `closed` of
/// the same delta, with zero traffic. `kind` is one of timeout /
/// refused / unreachable / dns / handshake / other.
struct ConcordConnectionFailure: Codable {
    let kind: String
    let message: String

    var kindLabel: String { Self.label(for: kind) }

    static func label(for kind: String) -> String {
        switch kind {
        case "timeout": return "连接超时"
        case "refused": return "连接被拒"
        case "unreachable": return "目标不可达"
        case "dns": return "DNS 失败"
        case "handshake": return "握手失败"
        default: return "其他错误"
        }
    }
}

/// When each step of setting a connection up happened, in
/// microseconds after `accepted` (upstream 0c9788f
/// ConnectionTiming). A step the connection did not take is absent;
/// all are fixed by the time it is opened.
struct ConcordConnectionTiming: Codable {
    let accepted: Int64
    var dnsStart: UInt32? = nil
    var dnsEnd: UInt32? = nil
    var routed: UInt32? = nil
    var dialStart: UInt32? = nil
    var connected: UInt32? = nil
    var tls: UInt32? = nil
    var dialEnd: UInt32? = nil
    var targetTls: UInt32? = nil
    var decrypted: UInt32? = nil
}

/// Why a connection ended and when (upstream 0c9788f ConnectionEnd,
/// the `ended` list of a ConnectionDelta). Every id in `closed` has
/// one. `reason` is one of local / remote / finished / timeout /
/// reset / core / error / failed; `message` is the error's text for
/// timeout, reset and error, for display only.

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
    /// A `var` on purpose: on this toolchain a `let` with a default
    /// is never decoded from the wire (Swift 6.2: "immutable
    /// property will not be decoded because it is declared with an
    /// initial value which cannot be overwritten"), so every
    /// optional-with-default field below is a `var` — the same
    /// applies to the new 0c9788f fields.
    var rematchName: String? = nil
    /// Audit A5: the fields below were decoded out of
    /// ConnectionInfo (upstream crates/proto/src/types/live.rs).
    /// All optional-with-default so older cores / sample data that
    /// omit them still decode; the display side (connection rows)
    /// can now show the exit chain, MITM flags and geo/ASN.
    /// `chains` is the exit chain (Vec<String>); `rulePayload` is
    /// the matched rule's payload; `mitm`/`mitmRefused` are bools.
    /// (v0.2.60: these were `let`s and therefore never decoded —
    /// see the note on `rematchName` — hence `var` now.)
    var chains: [String]? = nil
    var providerChains: [String]? = nil
    var rulePayload: String? = nil
    var mitm: Bool? = nil
    var mitmRefused: Bool? = nil
    var remoteDestination: String? = nil
    var sourceGeoIp: [String]? = nil
    var destinationGeoIp: [String]? = nil
    var sourceAsn: String? = nil
    var destinationAsn: String? = nil
    var specialRules: String? = nil
    var specialProxy: String? = nil
    /// Upstream 0c9788f (ConnectionInfo): the deciding rule's
    /// position, from 0, in the list `rule.list` gave for the config
    /// the connection was routed by. Absent when no rule decided
    /// (the final fallback, a global or direct mode, a named proxy)
    /// or when matching started in a sub-rule list.
    var ruleIndex: UInt32? = nil
    /// Upstream 0c9788f: why this connection's dial failed. Only
    /// on a failed dial (opened + closed in the same delta).
    var failure: ConcordConnectionFailure? = nil
    /// Upstream 0c9788f: per-step setup timing, microseconds after
    /// `accepted`.
    var timing: ConcordConnectionTiming? = nil
    /// Upstream 0c9788f: the `id`s of the `dns.watch` entries that
    /// gave out the destination's address (every lookup the core
    /// made for it, cache hits included). Resolve them against
    /// DnsStore entries by their numeric `id`.
    var dnsQueries: [UInt64]? = nil

    // Wire keys are snake_case (upstream crates/proto/src/types/live.rs:
    // ConnectionInfo). The raw values below are camelCase on purpose:
    // the live decoder uses .convertFromSnakeCase, which converts
    // "source_ip" to "sourceIp" BEFORE matching — a snake_case raw
    // value never matches and the whole entry silently fails to
    // decode (the tolerant snapshot then drops it). Verified on
    // Swift 6.2: explicit snake_case CodingKeys + convertFromSnakeCase
    // = keyNotFound for every snake_case field. The sample path
    // encodes this struct with a plain encoder, so camelCase keys
    // round-trip there too. Only `id` needs a rename (the property
    // is connectionId, the wire key is "id").
    enum CodingKeys: String, CodingKey {
        case connectionId = "id"
        case start, network, sourceIp, sourcePort, destinationIp,
             destinationPort, host, sniffHost, inboundType, inboundIp,
             inboundPort, inboundName, inboundUser, dnsMode, uid,
             process, processPath, upload, download, rule, proxy,
             rematchName, chains, providerChains, rulePayload, mitm,
             mitmRefused, remoteDestination, sourceGeoIp,
             destinationGeoIp, sourceAsn, destinationAsn, specialRules,
             specialProxy, ruleIndex, failure, timing, dnsQueries
    }
}

/// One entry of the `ended` list the extension forwards in the
/// connections snapshot: the connection's final ConnectionInfo
/// (with the core's final totals already applied) plus why and
/// when it ended. The extension writes it nested — the ConnectionInfo
/// under `connection`, the end fields as `end_reason` / `ended_at` /
/// `end_message` — so both the live (convertFromSnakeCase) and the
/// sample (plain) decoders read it with these camelCase keys.
struct ConcordEndedConnection: Codable {
    let connection: ConcordConnection
    let reason: String
    let endedAt: Int64
    let message: String?

    static func label(for reason: String) -> String {
        switch reason {
        case "local": return "本地先结束"
        case "remote": return "远端先结束"
        case "finished": return "双方结束"
        case "timeout": return "超时"
        case "reset": return "被重置"
        case "core": return "核心关闭"
        case "error": return "出错"
        case "failed": return "拨号失败"
        default: return reason
        }
    }

    enum CodingKeys: String, CodingKey {
        case connection
        case reason = "endReason"
        case endedAt
        case message = "endMessage"
    }
}

struct ConcordConnectionSnapshot: Codable {
    let connections: [ConcordConnection]
    /// Recently ended connections with their final totals and end
    /// reason (upstream 0c9788f ConnectionDelta.ended, forwarded by
    /// the extension — see PacketTunnelProvider.applyConnectionDelta).
    /// Optional: old snapshots have no such key, and on this
    /// toolchain a non-optional `var` with a default still requires
    /// the key to decode (see the note on
    /// ConcordConnection.rematchName).
    var ended: [ConcordEndedConnection]? = nil
}

/// connection.watch decoded leniently (C9): each entry is decoded
/// on its own and a malformed one is skipped, so one bad entry
/// cannot fail the whole snapshot. JSONDecoder's unkeyed container
/// advances past each element whether or not its decode succeeds,
/// so a failure here cannot desync the following entries.
private struct TolerantConnectionSnapshot: Decodable {
    let connections: [ConcordConnection]
    /// Ended connections with final totals (upstream 0c9788f
    /// ConnectionDelta.ended, forwarded by the extension). Absent
    /// in snapshots from older extensions; a malformed entry is
    /// skipped like a malformed connection.
    let ended: [ConcordEndedConnection]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([LossyConnection].self, forKey: .connections)
        connections = entries.compactMap(\.connection)
        let endedEntries = try container.decodeIfPresent([LossyEndedConnection].self, forKey: .ended) ?? []
        ended = endedEntries.compactMap(\.ended)
    }

    enum CodingKeys: String, CodingKey { case connections, ended }

    private struct LossyConnection: Decodable {
        let connection: ConcordConnection?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            connection = try? container.decode(ConcordConnection.self)
        }
    }

    private struct LossyEndedConnection: Decodable {
        let ended: ConcordEndedConnection?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            ended = try? container.decode(ConcordEndedConnection.self)
        }
    }
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
    /// Upstream 0c9788f (DnsEntry.id): counts up from 1 over the
    /// core process; a connection's `dnsQueries` names entries by
    /// it. 0 when the core omits it (older cores, sample data).
    /// A `var` so it actually decodes (see the note on
    /// ConcordConnection.rematchName: a `let` with a default is
    /// never decoded on this toolchain).
    var dnsId: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case domain, type, initiator, upstream, cached, answers,
             rcode, error, delay, time
        case dnsId = "id"
    }
}

/// The core omits `upstream` when it is empty (upstream
/// crates/proto/src/types/live.rs: `#[serde(default,
/// skip_serializing_if = "String::is_empty")]`), so a missing key
/// decodes as "" instead of failing the whole dns.watch snapshot.
/// The property stays a plain String (not String?) so DnsStore /
/// SettingsView, which read `.upstream` directly, need no change.
/// The decoder lives in an extension on purpose: a custom init in
/// the struct body would suppress the memberwise initializer that
/// ConcordSampleData builds sample entries with.
extension ConcordDnsEntry {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        type = try container.decode(String.self, forKey: .type)
        initiator = try container.decode(String.self, forKey: .initiator)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream) ?? ""
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached)
        answers = try container.decode([String].self, forKey: .answers)
        rcode = try container.decodeIfPresent(String.self, forKey: .rcode)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        delay = try container.decode(Int64.self, forKey: .delay)
        time = try container.decode(Int64.self, forKey: .time)
        dnsId = try container.decodeIfPresent(UInt64.self, forKey: .dnsId) ?? 0
    }
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
    /// `var`, not `let`: a defaulted `let` is never decoded on
    /// Swift 6.2, so these stayed nil even when the core sent them.
    var hits: [ConcordRouteHit]? = nil
    var nodeHits: [ConcordRouteHit]? = nil
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
    /// (MitmModuleStore.mergedConfigLive) fill these for mitm.validate.
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
    /// What kind of line problem this is (upstream MitmIssueKind:
    /// syntax, missing, unknown, unsupported, invalid, pattern, jq,
    /// resource, script). The core returns it since 01d7a13; optional
    /// so a result that omits it still decodes.
    /// `var`, not `let`: a defaulted `let` is never decoded on Swift 6.2.
    var kind: String? = nil
    let message: String
}

struct ConcordMitmValidateResult: Codable {
    let issues: [String: [ConcordMitmIssue]]
    /// The lines that take effect, by list — the same shape as
    /// ConcordMitmModuleView.views (upstream MitmValidateResult.views,
    /// default {}). Optional: the core returns it since 01d7a13 and
    /// older results omit it.
    /// `var`, not `let`: a defaulted `let` is never decoded on Swift 6.2.
    var views: [String: [ConcordMitmLineEntry]]? = nil
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
    /// A SCRIPT rule's script reads the address the host resolves to
    /// (upstream b0806a8). The core serializes it only when true, so
    /// the false default keeps decoding working when it is absent.
    /// `var`, not `let`: a defaulted `let` is never decoded on Swift 6.2,
    /// so a SCRIPT rule the core sent with requiresResolve: true was
    /// read back as false and lost the flag when re-emitted.
    var requiresResolve: Bool = false
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

// MARK: - mitm.moduleStatus / mitm.fetchModule (upstream b0806a8, the 70th and 71st methods)
//
// mitm.moduleStatus reports, for each module the `mitm` section of the
// profile in force names, whether it is enabled and in force, why it
// could not be taken at all (problem), why its own requirement turns
// it off (off), the state of each remote file it reads (resources),
// the rules left out of the profile (refusedRules) and the network
// edits it asks the host to apply (hostNetwork, kept as JSON like
// ConcordMitmModuleView.network — the app does not apply them yet).
// The handler is gated by mitm_enabled(): call it only when the core
// is ready and MITM is on — like the other mitm.* calls it errors
// when MITM is off or no config is applied.
// mitm.fetchModule re-fetches a module's remote files (name nil =
// every module's); it returns {}.

struct ConcordMitmModuleStatusList: Codable {
    let modules: [ConcordMitmModuleStatus]
}

struct ConcordMitmModuleStatus: Codable {
    let name: String
    let enabled: Bool
    let inForce: Bool
    let problem: ConcordMitmModuleProblem?
    /// Why the module takes no effect as a whole (requirement /
    /// requirementUnreadable) — the pre-existing def, reused.
    let off: ConcordMitmModuleOff?
    let resources: [ConcordMitmModuleResourceStatus]
    let refusedRules: [ConcordMitmRefusedRule]
    /// The routes and proxy bypass entries the module asks for, which
    /// the host applies; kept as JSON like ConcordMitmModuleView.network.
    let hostNetwork: JSONValue
}

/// Why a module could not be taken at all (upstream MitmModuleProblem,
/// untagged on `reason`): unreadable carries a `detail`, duplicate
/// does not.
struct ConcordMitmModuleProblem: Codable {
    let reason: String
    let detail: String?
}

extension ConcordMitmModuleProblem {
    /// Decodes `reason` first; only the unreadable variant carries a
    /// `detail`, so a duplicate problem decodes with detail nil even
    /// if the wire ever sent one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try container.decode(String.self, forKey: .reason)
        self.reason = reason
        self.detail = reason == "unreadable"
            ? try container.decodeIfPresent(String.self, forKey: .detail)
            : nil
    }
}

struct ConcordMitmModuleResourceStatus: Codable {
    let url: String
    /// script | map-local | jq.
    let kind: String
    let lines: [UInt32]
    /// The file in the MITM resources directory the lines read; nil
    /// when the file was never stored (the core also omits it then).
    let file: String?
    /// ok | fetching | failed | missing.
    let state: String
    /// Why the last fetch failed; nil when it did not fail.
    let error: ConcordMitmFetchFailure?
}

struct ConcordMitmFetchFailure: Codable {
    /// dns | tls | timeout | connection | other | http.
    let reason: String
    /// The HTTP status of an `http` failure; nil otherwise.
    let status: UInt16?
    let detail: String
}

struct ConcordMitmRefusedRule: Codable {
    let line: UInt32
    let detail: String
}

struct ConcordMitmPem: Codable {
    let pem: String
}

// MARK: - MITM capture results (upstream 646f8c9)
//
// The 4 capture methods used to return the generic MitmResult
// (`{result: <untyped JSON>}`); at 646f8c9 each returns its own
// strong type, still wrapped in `{result: ...}`. The client
// decodes the typed shape directly — no open-JSON re-decode.
// mitm.exchange / mitm.body return `result: null` when the
// capture no longer holds the exchange / body.

/// What a script the user ran wrote, and its `$done` value as JSON
/// (upstream MitmScriptOutput). `logs` is always present; `result`
/// / `error` are absent when the script wrote nothing / did not fail.
struct MitmScriptOutput: Codable {
    let logs: [String]
    var result: String? = nil
    var error: String? = nil
}

struct MitmScriptResult: Codable {
    let result: MitmScriptOutput
}

struct MitmExchangesResult: Codable {
    let result: MitmExchangeList
}

struct MitmExchangeResult: Codable {
    let result: MitmExchangeDetail?
}

struct MitmBodyResult: Codable {
    let result: MitmBody?
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
    /// `var`, not `let`: a defaulted `let` is never decoded on Swift 6.2,
    /// so RulesView always showed "？" instead of the position number.
    var index: UInt32? = nil
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
    /// Upstream c7aa654: the address the service saw the check come
    /// from, which a node that sends the service out another way
    /// does not share with its other traffic. Only checks whose
    /// answer names it carry one. A `var` so it actually decodes
    /// (see the note on ConcordConnection.rematchName).
    var ip: String? = nil
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
    /// scriptNotification only (upstream b0806a8): what a MITM script
    /// posted with `$notification.post`. `url` above is what opening
    /// it opens. All default nil so existing memberwise
    /// constructions keep compiling unchanged. `var`, not `let`:
    /// on this toolchain a `let` with a default is never decoded
    /// (see the note on ConcordConnection.rematchName) — as `let`s
    /// these four never carried the script's title at all.
    /// Upstream 0c9788f adds `at` (when the script posted it, unix
    /// millis), `connection` (the connection.watch id of the
    /// upstream connection the request went out on) and `exchange`
    /// (the mitm.exchanges id of the request, while capture is on).
    var script: String? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var body: String? = nil
    var at: Int64? = nil
    var connection: UInt64? = nil
    var exchange: Int64? = nil

    /// One-line summary for the events feed.
    var summary: String {
        switch type {
        case "resourceUpdate":
            // kind mitmModule names a module, not a provider.
            let label = kind == "mitmModule" ? "模块更新" : "提供方更新"
            let base = "\(label)：\(name ?? "—")（\(phase ?? "—")）"
            if let error, !error.isEmpty { return base + "：\(error)" }
            return base
        case "dialerLoop":
            return "拨号循环：\(name ?? "—")"
        case "delay":
            return "测速：\(name ?? "—") \(url ?? "") \(value.map { "\($0) ms" } ?? "—")"
        case "fatal":
            return "致命错误：\(message ?? "—")"
        case "scriptNotification":
            // Upstream 0c9788f: the notification names the connection
            // and exchange it came from, when the core knows them.
            var base = "脚本通知：\(title ?? "—")"
            if let connection {
                base += "（连接 #\(connection)"
                if let exchange { base += "，请求 #\(exchange)" }
                base += "）"
            }
            return base
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

/// The IP-info sources FlClash races for probe.outboundIp
/// (FlClash lib/common/service_probe.dart `ipInfoSources`): the core
/// takes the first source whose body mentions a public IP, so several
/// sources make the probe survive any one of them being blocked.
let concordOutboundIpUrls = [
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://api.ip.sb/geoip",
    "https://ipinfo.io/json",
    "https://ipwho.is",
    "https://get.geojs.io/v1/ip/geo.json",
    "https://api.country.is",
    "https://api.ipquery.io/?format=json",
    "https://ident.me/json",
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
    /// Upstream 0c9788f: the schema now names this shape
    /// (MitmExchangeSummary) with the fields the core already sent
    /// for `mitm.exchanges` plus the app behind the exchange. All
    /// optional-with-default so older cores / sample data that omit
    /// them still decode. `var`, not `let`: a `let` with a default
    /// is never decoded on this toolchain (see the note on
    /// ConcordConnection.rematchName).
    var host: String? = nil
    /// With its query.
    var path: String? = nil
    /// The response's content type, without parameters, in lower case.
    var contentType: String? = nil
    /// 1xx / 2xx / 3xx / 4xx / 5xx, or failed / pending.
    var statusClass: String? = nil
    /// json / html / script / css / image / font / media / text / other.
    var kind: String? = nil
    /// A rewrite, a local map or a script acted on it.
    var rewritten: Bool? = nil
    /// The kinds of the actions that acted on it, each once, in
    /// the order they first acted (upstream 9d1f485, b678d79).
    /// Omitted when none acted.
    var actionKinds: [String]? = nil
    /// What answered it in place of its server; nil when the
    /// request went to the server (upstream 9d1f485, b678d79).
    var answer: ConcordMitmAnswer? = nil
    /// The connection it went out on, as `connection.watch` numbers it.
    var connectionId: UInt64? = nil
    /// The process behind that connection, kept after it closed.
    var app: ConcordMitmApp? = nil

    enum CodingKeys: String, CodingKey {
        case exchangeId = "id"
        case start, pending, duration, method, url, status
        case requestSize = "request-size"
        case responseSize = "response-size"
        case error
        case host, path
        case contentType = "content-type"
        case statusClass = "status-class"
        case kind, rewritten
        case actionKinds = "action-kinds"
        case answer
        case connectionId = "connection-id"
        case app
    }
}

/// What answered a request in place of its server (upstream
/// 9d1f485 MitmAnswer, kebab-case): reject = the rules rejected
/// it, redirect = a url-rewrite 302/307 line, map-local = a local
/// map, script = a request script answered or aborted it.
enum ConcordMitmAnswer: String, Codable {
    case reject
    case redirect
    case mapLocal = "map-local"
    case script

    var label: String {
        switch self {
        case .reject: return "本地拒绝"
        case .redirect: return "本地重定向"
        case .mapLocal: return "本地映射"
        case .script: return "脚本应答"
        }
    }
}

/// The process behind the connection an exchange went out on
/// (upstream 0c9788f MitmApp). `process-path` is empty when the
/// core does not know it; `uid` is absent for a connection the
/// core never attributed.
struct ConcordMitmApp: Codable {
    let process: String
    var processPath: String? = nil
    let uid: UInt32?

    enum CodingKeys: String, CodingKey {
        case process
        case processPath = "process-path"
        case uid
    }
}

struct MitmExchangeList: Codable {
    let capturing: Bool
    let since: String?
    let exchanges: [MitmExchangeSummary]
    /// The connection had closed when its list was taken, so the
    /// list is whole (upstream 646f8c9 MitmExchangeList.closed).
    /// Optional-with-default so sample data that omits it still decodes.
    var closed: Bool? = nil
}

// MARK: - MITM query types (mitm.query, upstream 0c9788f)
//
// One page of the capture across connections, newest first, with
// what a view of the capture needs besides. The filter and params
// wire keys are camelCase (upstream crates/proto/src/types/probe.rs:
// the `dto!` macro applies `rename_all = "camelCase"`), so the
// params must be encoded with a PLAIN encoder — the client's shared
// requestEncoder (.convertToSnakeCase) would turn `slowMs` into
// `slow_ms` and `rateFrom` into `rate_from`, which the core
// silently drops as unknown fields. mitmQuery therefore goes
// through callRaw (see below). The answer's keys are kebab-case
// for the multi-word ones ("median-duration") and plain words
// otherwise, so both decoders read them.

/// Which exchanges a mitm.query keeps. An empty list or an absent
/// field lets every exchange through; a list keeps the exchanges
/// that match any of its items. All lists default empty, all
/// scalars default nil — an empty filter matches everything.
struct ConcordMitmFilter: Codable {
    var statuses: [String] = []
    /// Compared without case.
    var methods: [String] = []
    var kinds: [String] = []
    /// The URL's host, without its port, compared whole and without case.
    var hosts: [String] = []
    /// The `process` of the exchange's connection as
    /// `connection.watch` lists it, compared without case; `""` for none.
    var apps: [String] = []
    /// Whether a rewrite, a local map or a script acted on it.
    var rewritten: Bool? = nil
    /// Took at least this long, in milliseconds.
    var slowMs: Int64? = nil
    /// Found without case in the URL, method, content type, error or app.
    var text: String? = nil
    /// Started at or after, in Unix milliseconds.
    var from: Int64? = nil
    /// Started before, in Unix milliseconds.
    var to: Int64? = nil
}

/// Params for mitm.query. To page through the capture, pass each
/// answer's `next` as `before`. To follow it, pass the `version` of
/// the first page of a pass as `since` with no `before`.
struct ConcordMitmQueryParams: Codable {
    var filter: ConcordMitmFilter = ConcordMitmFilter()
    /// Only exchanges with a lower id: the `next` of the page before.
    var before: Int64? = nil
    /// At most this many, from 1 to 64; absent, 64.
    var limit: UInt32? = nil
    /// Only exchanges added or changed after the `version` of an
    /// earlier answer, and every exchange still in progress.
    var since: UInt64? = nil
    /// Also count the held exchanges by status, method, kind and app.
    var facets: Bool = false
    /// Also count the matches by the second they started in, from
    /// this time on (Unix milliseconds).
    var rateFrom: Int64? = nil
}

/// One page of mitm.query.
struct ConcordMitmQueryAnswer: Codable {
    let capturing: Bool
    /// When the oldest held exchange started, or capture was turned
    /// on (RFC 3339).
    let since: String?
    /// The `since` that asks for what is added or changed after this answer.
    let version: UInt64
    /// The lowest id held; a client keeping earlier answers drops the ids below it.
    let oldest: Int64
    let held: UInt64
    /// How many held exchanges match the filter.
    let matched: UInt64
    let exchanges: [MitmExchangeSummary]
    /// The `before` of the next page; absent when this page holds the last match.
    let next: Int64?
    /// Changed since `since` and no longer matching, so a client drops them.
    /// Optional (not a defaulted array): the core omits the key when
    /// it is empty, and on this toolchain a non-optional `var` with a
    /// default still requires the key to decode — see the note on
    /// ConcordConnection.rematchName.
    var unmatched: [Int64]? = nil
    let facets: ConcordMitmFacets?
    let rate: [ConcordMitmRateBucket]?
    /// Of the finished matches, in milliseconds.
    let medianDuration: Int64?

    enum CodingKeys: String, CodingKey {
        case capturing, since, version, oldest, held, matched,
             exchanges, next, unmatched, facets, rate
        case medianDuration = "median-duration"
    }
}

/// Counts of the held matches by status, method, kind and app
/// (upstream 0c9788f MitmFacets). Status keys are MitmStatus names,
/// method keys upper case, kind keys MitmKind names, app keys are
/// process names ("" holds the exchanges of no known app).
struct ConcordMitmFacets: Codable {
    let status: [String: UInt64]
    let method: [String: UInt64]
    let kind: [String: UInt64]
    let app: [String: UInt64]
}

/// Matches by the second they started in (upstream 0c9788f
/// MitmRateBucket). `errors` are the failed ones, or the ones
/// answered 4xx or 5xx.
struct ConcordMitmRateBucket: Codable {
    let t: Int64
    let requests: UInt64
    let errors: UInt64
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
            throw ConcordClientError.fromRPCError(error)
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
    /// Every snapshot expires after 10 s, like traffic/connections:
    /// the extension only rewrites a file while the tunnel is alive,
    /// so a file older than that is a previous run's stale data, not
    /// current state. log / dns / route / events / engine used to
    /// have no max-age, so after the VPN stopped the app kept showing
    /// the last run's logs, DNS entries, events and engine status as
    /// if they were live. delay.run.poll is the one exception: it
    /// reads the run accumulator the extension writes while a batch
    /// delay test is in flight, and a missing file there means "not
    /// started yet", which the poller already handles by retrying.
    private static let streamSnapshots: [String: (file: String, maxAgeSeconds: TimeInterval?)] = [
        "traffic.watch": ("traffic", 10),
        "connection.watch": ("connections", 10),
        "log.watch": ("logs", 10),
        "dns.watch": ("dns", 10),
        // proxy.watch used to have no max-age, so a stale
        // proxies.json (written by a previous tunnel run, or an
        // empty one from a run whose core had not finished
        // applying) was served as current forever — the v0.2.31
        // "节点也看不见" report. 10 s, like traffic/connections:
        // a stale snapshot throws and the caller falls back to
        // proxy.groups, then to the local YAML.
        "proxy.watch": ("proxies", 10),
        "delay.run.poll": ("delay", nil),
        "route.watch": ("route", 10),
        "events.watch": ("events", 10),
        "engine.state": ("engine", 10),
    ]

    private struct SnapshotFile<Payload: Decodable>: Decodable {
        let updatedAt: Int64
        let data: Payload
    }

    func send<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
        if let snapshot = Self.streamSnapshots[method] {
            return try await readSnapshot(file: snapshot.file, maxAgeSeconds: snapshot.maxAgeSeconds, resultType: resultType)
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
            throw ConcordClientError.fromRPCError(error)
        }
        guard let result = decoded.result else {
            throw ConcordClientError.decode("empty result for \(method)")
        }
        return result
    }

    // v0.2.103: async with a background hop — the file read +
    // JSON decode used to run synchronously on the caller's
    // executor (the main actor, via the stores' refresh), so a
    // large snapshot (dns/connections/logs) stalled the main
    // thread. The read + decode now run in a detached task on
    // the cooperative pool; the max-age staleness rule and the
    // error behaviour are unchanged.
    private func readSnapshot<Result: Decodable>(file: String, maxAgeSeconds: TimeInterval?, resultType: Result.Type) async throws -> Result {
        return try await Task.detached(priority: .userInitiated) {
            guard let url = ConfigStore.snapshotURL(name: file),
                  let data = try? Data(contentsOf: url) else {
                throw TunnelError.notRunning
            }
            // Fresh decoder per call: Self.liveDecoder is shared,
            // and JSONDecoder is not thread-safe, so the background
            // decode must not use it while send()'s RPC path
            // decodes on another thread. Same strategy as
            // liveDecoder (.convertFromSnakeCase).
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let snapshot = try decoder.decode(SnapshotFile<Result>.self, from: data)
            if let maxAgeSeconds {
                let age = Date().timeIntervalSince1970 * 1000 - Double(snapshot.updatedAt)
                if age > maxAgeSeconds * 1000 {
                    throw ConcordClientError.transport("实时快照已过期（\(file)，\(Int(age / 1000))s 前）：隧道可能已断开")
                }
            }
            return snapshot.data
        }.value
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

    /// Like `call`, but the params are already encoded — for methods
    /// whose wire keys are camelCase, which the shared
    /// .convertToSnakeCase requestEncoder would mangle (mitm.query:
    /// `slowMs`, `rateFrom`). The caller encodes with a plain
    /// JSONEncoder so the keys go over verbatim.
    func callRaw<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
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
        // Keep legacy encoding for other settings; only repair this field.
        let encoded = try Self.requestEncoder.encode(AnyEncodable(params))
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw NSError(domain: "ConcordConfigPatch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法编码通用设置"])
        }
        if let unifiedDelay = params.unifiedDelay {
            object.removeValue(forKey: "unified_delay")
            object["unifiedDelay"] = unifiedDelay
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let _: EmptyResult = try await callRaw(method: "config.patch", paramsData: data, resultType: EmptyResult.self)
    }

    func setUnifiedDelay(_ enabled: Bool) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["unifiedDelay": enabled])
        let _: EmptyResult = try await callRaw(method: "config.patch", paramsData: data, resultType: EmptyResult.self)
    }

    /// Patches only the core's mode (config.patch with just `mode`).
    /// Added for the SSID direct override mirror (SsidDirectStore):
    /// ConcordConfigPatchParams has no per-field defaults, so a
    /// mode-only patch needs the full memberwise init spelled out;
    /// this helper keeps that in one place.
    func configPatchMode(_ mode: String) async throws {
        try await configPatch(ConcordConfigPatchParams(
            mode: mode, logLevel: nil, mixedPort: nil, allowLan: nil,
            ipv6: nil, tcpConcurrent: nil, unifiedDelay: nil,
            findProcessMode: nil, secret: nil, authentication: nil,
            externalController: nil))
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

    /// Tests one proxy's delay (delay.test). `timeout` defaults to
    /// 8000 ms — FlClash's defaultDelayTestTimeout (lib/common/
    /// constant.dart); passing nil used to leave the core default of
    /// 5 s in force, so nodes slower than 5 s always showed "超时".
    func delayTest(proxy: String, url: String? = nil, timeout: UInt64? = 8000) async throws -> ConcordDelayResult {
        try await call(method: "delay.test", params: ConcordDelayTestParams(proxy: proxy, url: url, timeout: timeout, expected: nil), resultType: ConcordDelayResult.self)
    }

    /// Starts a batch delay test (delay.run, a stream). The reply is
    /// the subscription ({sub, snapshot}); the results arrive as events
    /// the extension accumulates into snapshots/delay.json — poll them
    /// with delayRunPoll(). The run ends by itself with a `done` event.
    /// `timeout` defaults to 8000 ms, as in delayTest.
    func delayRunStart(proxies: [String], url: String? = nil, timeout: UInt64? = 8000, concurrency: UInt32? = nil) async throws -> DelayRunStart {
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
        // profile.inspect takes ProfileParams { profile: ProfileRef }
        // (schema/api.json + crates/api/src/control.rs:750). The flat
        // {"path": ...} this sent before is rejected with
        // invalid_params (missing `profile`) — same nested shape as
        // profile.outbounds above.
        struct ProfileParams: Encodable { let profile: ConcordProfileRef }
        return try await call(method: "profile.inspect", params: ProfileParams(profile: ConcordProfileRef(path: path)), resultType: ConcordProfileInspect.self)
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
        // C9: one malformed entry must not drop the whole list —
        // decode each entry on its own and skip the ones that fail,
        // instead of failing the whole refresh (which left the list
        // stale). The ConcordConnection model is unchanged. The
        // `ended` list rides along: recently ended connections with
        // their final totals and end reason (upstream 0c9788f).
        let tolerant = try await call(method: "connection.watch", resultType: TolerantConnectionSnapshot.self)
        return ConcordConnectionSnapshot(connections: tolerant.connections, ended: tolerant.ended)
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

    /// Asks the core for the exit IP through one proxy
    /// (probe.outboundIp). Schema OutboundIpParams (upstream
    /// crates/proto/src/types/probe.rs:18): {proxy: String, urls:
    /// Vec<String>, timeout?: u64 ms} — the old {"url": "<single>"}
    /// shape was rejected with invalid_params (missing `proxy`,
    /// wrong `url` key). `proxy` "" means unpinned: the core routes
    /// the probe like normal traffic (upstream crates/engine/src/
    /// probe/fetch.rs: only a non-empty proxy pins the dial) — that
    /// is FlClash's `routedOutbound` case, what the no-arg callers
    /// (TrafficStore, DiagnosticsView) want. `urls` nil races
    /// FlClash's ip-info sources (concordOutboundIpUrls); `timeout`
    /// defaults to FlClash's 6 s (outboundIpTimeoutDuration).
    func probeOutboundIp(proxy: String = "", urls: [String]? = nil, timeout: UInt64? = 6000) async throws -> ConcordOutboundIp {
        struct OutboundIpParams: Encodable {
            let proxy: String
            let urls: [String]
            let timeout: UInt64?
        }
        return try await call(method: "probe.outboundIp", params: OutboundIpParams(proxy: proxy, urls: urls ?? concordOutboundIpUrls, timeout: timeout), resultType: ConcordOutboundIp.self)
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

    /// Module status from the core (upstream b0806a8): which modules
    /// the profile in force names, whether each is enabled and in
    /// force, and why not. Gated by mitm_enabled() in the core — call
    /// only when the core is ready and MITM is on, like the other
    /// mitm.* calls; it errors when MITM is off or no config is applied.
    func mitmModuleStatus() async throws -> ConcordMitmModuleStatusList {
        try await call(method: "mitm.moduleStatus", params: EmptyParams(), resultType: ConcordMitmModuleStatusList.self)
    }

    /// Re-fetches a module's remote files (upstream b0806a8). `name`
    /// nil re-fetches every module's remote files. Same mitm_enabled()
    /// gate as mitm.moduleStatus. Returns nothing (the core answers
    /// {}), like the other empty-result calls in this client.
    func mitmFetchModule(name: String?) async throws {
        struct MitmFetchModuleParams: Encodable {
            let name: String?
        }
        _ = try await call(method: "mitm.fetchModule", params: MitmFetchModuleParams(name: name), resultType: EmptyResult.self)
    }

    /// Queries the MITM capture across connections (upstream
    /// 0c9788f, the 72nd method): one page of exchanges, newest
    /// first, with what a view of the capture needs besides
    /// (matched / held counts, the `next` page cursor, facets and
    /// rate buckets when asked). Pass each answer's `next` as
    /// `before` to page; pass a first page's `version` as `since`
    /// with no `before` to follow new and changed exchanges. The
    /// params go over with a plain encoder (see callRaw): their
    /// wire keys are camelCase, not snake_case.
    func mitmQuery(filter: ConcordMitmFilter = ConcordMitmFilter(), before: Int64? = nil, limit: UInt32? = nil, since: UInt64? = nil, facets: Bool = false, rateFrom: Int64? = nil) async throws -> ConcordMitmQueryAnswer {
        let params = ConcordMitmQueryParams(filter: filter, before: before, limit: limit, since: since, facets: facets, rateFrom: rateFrom)
        let paramsData = try JSONEncoder().encode(params)
        return try await callRaw(method: "mitm.query", paramsData: paramsData, resultType: ConcordMitmQueryAnswer.self)
    }

    func mitmIssueCertificate(host: String) async throws -> ConcordMitmPem {
        struct MitmIssueParams: Encodable { let host: String }
        return try await call(method: "mitm.issueCertificate", params: MitmIssueParams(host: host), resultType: ConcordMitmPem.self)
    }

    func mitmRunScript(name: String) async throws -> MitmScriptResult {
        struct MitmScriptParams: Encodable { let name: String }
        return try await call(method: "mitm.runScript", params: MitmScriptParams(name: name), resultType: MitmScriptResult.self)
    }

    func mitmExchanges(connection: UInt64) async throws -> MitmExchangesResult {
        struct MitmExchangesParams: Encodable { let connection: UInt64 }
        return try await call(method: "mitm.exchanges", params: MitmExchangesParams(connection: connection), resultType: MitmExchangesResult.self)
    }

    func mitmExchange(id: Int64) async throws -> MitmExchangeResult {
        struct MitmExchangeParams: Encodable { let id: Int64 }
        return try await call(method: "mitm.exchange", params: MitmExchangeParams(id: id), resultType: MitmExchangeResult.self)
    }

    func mitmBody(id: Int64, response: Bool = false) async throws -> MitmBodyResult {
        struct MitmBodyParams: Encodable { let id: Int64; let response: Bool }
        return try await call(method: "mitm.body", params: MitmBodyParams(id: id, response: response), resultType: MitmBodyResult.self)
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
