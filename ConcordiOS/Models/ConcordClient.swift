import Foundation
import Combine

// MARK: - Concord JSON-RPC 2.0 client
//
// Types are modelled on upstream Concord's schema/api.json (68 methods,
// checked 2026-11-16 against commit 187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6).
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
//                             delay.test / delay.run, validate.proxies
//   Profiles                  config.apply, config.validate, profile.inspect,
//                             convert.subscription, provider.list/update
//   Rules                     rule.list, provider.list
//   Connections               connection.watch, connection.close, network.reset
//   Logs                      log.watch, core.lastWarnings
//   DNS queries               dns.watch, dns.query, dns.clearCache,
//                             dns.flushFakeIp
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
struct EmptyResult: Decodable {}

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

struct MitmConfig: Codable {
    var enable: Bool = false
    var hostname: [String] = []
    var skipServerCertVerify: Bool = false
    var decryptTls: Bool = true
    var caFingerprint: String = ""
    var h2: Bool = false

    enum CodingKeys: String, CodingKey {
        case enable, hostname
        case skipServerCertVerify = "skip-server-cert-verify"
        case decryptTls = "decrypt-tls"
        case caFingerprint = "ca-fingerprint"
        case h2
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

struct ConcordMitmPem: Codable {
    let pem: String
}

struct ConcordMitmResult: Codable {
    let result: JSONValue
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
/// request per sendProviderMessage; the four stream methods read the
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
    private static let streamSnapshots: [String: (file: String, maxAgeSeconds: TimeInterval?)] = [
        "traffic.watch": ("traffic", 10),
        "connection.watch": ("connections", 10),
        "log.watch": ("logs", nil),
        "dns.watch": ("dns", nil),
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

    func proxySelect(group: String, proxy: String) async throws -> ConcordProxySelectResult {
        try await call(method: "proxy.select", params: ConcordProxySelectParams(group: group, proxy: proxy), resultType: ConcordProxySelectResult.self)
    }

    func delayTest(proxy: String, url: String? = nil, timeout: UInt64? = nil) async throws -> ConcordDelayResult {
        try await call(method: "delay.test", params: ConcordDelayTestParams(proxy: proxy, url: url, timeout: timeout, expected: nil), resultType: ConcordDelayResult.self)
    }

    // MARK: Profiles / providers / rules

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

    func dnsFlushFakeIp() async throws {
        _ = try await call(method: "dns.flushFakeIp", resultType: EmptyResult.self)
    }

    // MARK: Dashboard helpers

    func coreStats() async throws -> ConcordCoreStats {
        try await call(method: "core.stats", resultType: ConcordCoreStats.self)
    }

    func probeOutboundIp(url: String? = nil) async throws -> ConcordOutboundIp {
        struct OutboundIpParams: Encodable { let url: String? }
        return try await call(method: "probe.outboundIp", params: OutboundIpParams(url: url), resultType: ConcordOutboundIp.self)
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
