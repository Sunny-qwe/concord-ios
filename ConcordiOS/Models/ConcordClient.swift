import Foundation
import Combine

// MARK: - Concord JSON-RPC 2.0 client
//
// Types are modelled on upstream Concord's schema/api.json (68 methods,
// checked 2026-11-16 against commit 187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6).
// See TUN_INVESTIGATION.md for the full method map.
//
// Two modes:
//   - `.sample`: the client answers from built-in sample data, encoded to
//     JSON and decoded again, so the Codable request/response path is the
//     same code the live path uses. Sample data is labelled "示例数据" in
//     the UI wherever it is shown. It is NOT real core data.
//   - `.live`: the client talks to the real core over the C FFI
//     (concord_open / concord_send / concord_adopt_fd, see
//     crates/ffi/src/abi.rs) — NOT linked yet. Every live call currently
//     throws ConcordClientError.coreNotLinked. When the staticlib is
//     linked, LiveConcordTransport is the single place to wire it in.
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
//   Rules                     rule.list, ruleSet.dump/compile, validate.filters
//   Connections               connection.watch, connection.close, network.reset
//   Logs                      log.watch, core.lastWarnings
//   DNS queries               dns.watch, dns.query, dns.clearCache,
//                             dns.flushFakeIp
//   Settings (general)        config.general, config.patch
//   MITM                      mitm.certificate / generateCertificate /
//                             validate / issueCertificate / runScript /
//                             exchanges / exchange / body — these need the
//                             `mitm` capability, unverified on iOS, so the
//                             UI marks MITM as unavailable for now.
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
    case coreNotLinked
    case transport(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .coreNotLinked:
            return "Concord 核心尚未链接（静态库 / TUN 桥接仍是 TODO，见 TUN_INVESTIGATION.md）"
        case .transport(let message):
            return "传输错误：\(message)"
        case .decode(let message):
            return "解析错误：\(message)"
        }
    }
}

// MARK: JSON-RPC envelope

struct JSONRPCRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

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

// MARK: - Concord types (field names follow schema/api.json $defs)

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

struct ConcordConfigApplyParams: Encodable {
    var profile: ConcordProfileRef?
    var overlay: [String: String]?
    var selection: [String: String] = [:]
    var options: ConcordConfigOptions = ConcordConfigOptions()
}

struct ConcordConfigApplyResult: Codable {
    let warnings: [ConcordWarning]
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

    enum CodingKeys: String, CodingKey {
        case connectionId = "id"
        case start, network, sourceIp, sourcePort, destinationIp, destinationPort
        case host, sniffHost, inboundType, inboundIp, inboundPort, inboundName
        case inboundUser, dnsMode, uid, process, processPath, upload, download
        case rule, proxy
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

    enum CodingKeys: String, CodingKey { case kind, name, handle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "device": self = .device(name: try c.decodeIfPresent(String.self, forKey: .name))
        case "inherited": self = .inherited(handle: try c.decode(UInt64.self, forKey: .handle))
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

/// Live transport: the single place to wire the real core in. It talks to
/// the in-process core through the C FFI (concord_open / concord_send).
/// Not linked yet — see TUN_INVESTIGATION.md §3 and §7.
struct LiveConcordTransport: ConcordTransport {
    func send<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
        // TODO: replace with concord_open / concord_send once
        // rust/concord-ios-ffi exposes the real concord-ffi entry points
        // (concord_start / concord_open / concord_send / concord_adopt_fd)
        // instead of the concord_ios_init/start/stop stubs.
        throw ConcordClientError.coreNotLinked
    }
}

// MARK: - Client

final class ConcordClient: ObservableObject {
    @Published var mode: ConcordMode = .sample
    @Published var lastError: String?

    private var transport: ConcordTransport {
        switch mode {
        case .sample: return MockConcordTransport()
        case .live: return LiveConcordTransport()
        }
    }

    private var nextID = 1

    func call<Result: Decodable>(method: String, params: Encodable, resultType: Result.Type) async throws -> Result {
        let id = nextID
        nextID += 1
        let paramsData = try JSONEncoder().encode(AnyEncodable(params))
        return try await transport.send(method: method, paramsData: paramsData, resultType: resultType)
    }

    func call<Result: Decodable>(method: String, resultType: Result.Type) async throws -> Result {
        try await call(method: method, params: EmptyParams(), resultType: resultType)
    }

    // MARK: Core lifecycle (core.init -> config.apply -> engine.start -> tun.start)

    func coreInit(home: String) async throws {
        _ = try await call(method: "core.init", params: ConcordCoreInitParams(home: home, sdkInt: nil), resultType: EmptyResult.self)
    }

    func configApply(profilePath: String?, selection: [String: String] = [:]) async throws -> ConcordConfigApplyResult {
        try await call(method: "config.apply", params: ConcordConfigApplyParams(profile: profilePath.map { ConcordProfileRef(path: $0) }, selection: selection), resultType: ConcordConfigApplyResult.self)
    }

    func configGeneral() async throws -> ConcordGeneralState {
        try await call(method: "config.general", resultType: ConcordGeneralState.self)
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

    // MARK: Traffic / connections / logs / DNS (streams in the schema;
    // the client polls the latest snapshot until the live stream transport
    // is wired — see MockConcordTransport for the sample snapshots)

    func trafficSnapshot() async throws -> ConcordTraffic {
        // traffic.watch is a stream; snapshot is the latest Traffic value.
        try await call(method: "traffic.watch", resultType: ConcordTraffic.self)
    }

    func trafficReset() async throws {
        _ = try await call(method: "traffic.reset", resultType: EmptyResult.self)
    }

    func connectionSnapshot() async throws -> ConcordConnectionSnapshot {
        try await call(method: "connection.watch", resultType: ConcordConnectionSnapshot.self)
    }

    func connectionClose(id: UInt64) async throws {
        struct ConnectionCloseParams: Encodable { let id: UInt64 }
        _ = try await call(method: "connection.close", params: ConnectionCloseParams(id: id), resultType: EmptyResult.self)
    }

    func logEntries() async throws -> [ConcordLogEntry] {
        // log.watch is a stream of LogEntry events; the mock returns the
        // buffered sample entries as a snapshot list.
        struct LogSnapshot: Decodable { let entries: [ConcordLogEntry] }
        return try await call(method: "log.watch", resultType: LogSnapshot.self).entries
    }

    func dnsEntries() async throws -> [ConcordDnsEntry] {
        struct DnsSnapshot: Decodable { let entries: [ConcordDnsEntry] }
        return try await call(method: "dns.watch", resultType: DnsSnapshot.self).entries
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
}

/// Type-erased Encodable wrapper so `call` can take any params struct.
struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init(_ value: Encodable) {
        encodeImpl = { try value.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
