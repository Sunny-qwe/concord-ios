import Foundation

// MARK: - Sample data for ConcordClient in `.sample` mode
//
// Every value below is SAMPLE data, clearly labelled "示例数据" in the UI.
// It exists so the FlClash-like pages can be used and tested before the
// real Concord core is linked. It is NOT live core data and must never be
// presented as such. When the client switches to `.live`, this file is
// unused.

enum ConcordSampleData {

    static func jsonResponse(for method: String, paramsData: Data) throws -> Data {
        let result: AnyEncodable
        switch method {
        case "core.init", "engine.start", "engine.stop", "tun.start", "tun.stop",
             "traffic.reset", "dns.clearCache", "dns.flushFakeIp", "provider.update",
             "config.patch", "network.reset", "core.releaseMemory", "geo.update",
             "core.setPressure", "debug.crash", "mitm.fetchModule":
            result = AnyEncodable(EmptyResultJSON())
        case "config.validate":
            result = AnyEncodable(ConcordConfigValidateResult(issues: []))
        case "config.read":
            result = AnyEncodable(ConcordConfigReadResult(
                config: .object([
                    "mode": .string("rule"),
                    "proxies": .array(sampleProxyObjects),
                    "proxy-groups": .array([.string("GLOBAL"), .string("PROXY")]),
                    "rules": .array(sampleRules.map { .string("\($0.type),\($0.payload),\($0.target)") }),
                ]),
                file: nil, size: nil))
        case "convert.subscription":
            result = AnyEncodable(ConcordProxyList(proxies: sampleProxyObjects))
        case "validate.proxies":
            result = AnyEncodable(ConcordIssueList(issues: []))
        case "validate.filters":
            result = AnyEncodable(ConcordIssueList(issues: []))
        case "config.decrypt":
            result = AnyEncodable(ConcordTextResult(
                text: "# 示例解密配置（config.decrypt）\nmode: rule\nproxies: []\nproxy-groups: []\nrules: []\n",
                file: nil, size: nil))
        case "profile.build":
            result = AnyEncodable(ConcordTextResult(
                text: "# 示例生效配置（profile.build）\nmode: rule\nmixed-port: 7890\nproxies: 4 个节点\nproxy-groups: GLOBAL / PROXY / Streaming / DIRECT\nrules: 20 条\n",
                file: nil, size: nil))
        case "ruleSet.dump":
            result = AnyEncodable(ConcordTextResult(
                text: sampleRules.map { "\($0.type),\($0.payload),\($0.target)" }.joined(separator: "\n"),
                file: nil, size: nil))
        case "ruleSet.compile":
            result = AnyEncodable(ConcordRuleSetInfo(behavior: "domain", format: "yaml"))
        case "proxy.definition":
            result = AnyEncodable(ConcordProxyDefinition(proxy: sampleProxyDefinition(paramsData: paramsData)))
        case "proxy.states":
            result = AnyEncodable(ConcordProxyStates(proxies: sampleProxyStates))
        case "proxy.watch":
            result = AnyEncodable(sampleProxyGroups)
        case "delay.run":
            result = AnyEncodable(DelayRunStart(sub: 1, snapshot: nil))
        case "delay.run.poll":
            result = AnyEncodable(DelayRunSnapshot(runId: 1, done: true, results: sampleProxyGroups.nodes.map {
                ConcordDelayResult(name: $0.name, url: "http://www.gstatic.com/generate_204", value: sampleLatency(for: $0.name))
            }))
        case "dns.query":
            result = AnyEncodable(sampleDnsQuery(paramsData: paramsData))
        case "probe.services":
            result = AnyEncodable(ConcordServiceList(items: sampleServices))
        case "core.capabilities":
            result = AnyEncodable(ConcordCapabilities(
                version: "示例", ruleTypes: [],
                congestionControllers: [],
                features: ConcordFeatures(mitm: false)))
        case "mitm.certificate", "mitm.generateCertificate":
            result = AnyEncodable(ConcordMitmCertificate(certificate: nil))
        case "mitm.validate":
            result = AnyEncodable(ConcordMitmValidateResult(issues: [:]))
        case "mitm.readModule":
            result = AnyEncodable(ConcordMitmModuleView(
                format: "surge",
                meta: ConcordMitmModuleMeta(name: "示例模块", desc: nil, system: nil),
                off: nil, arguments: [], resources: [], declaredScripts: [], asksConsent: false,
                issues: [:], views: [:], rules: [], ruleSets: [], network: .object([:]), ignored: []))
        case "mitm.moduleStatus":
            result = AnyEncodable(ConcordMitmModuleStatusList(modules: [
                ConcordMitmModuleStatus(
                    name: "示例模块", enabled: true, inForce: true, problem: nil, off: nil,
                    resources: [ConcordMitmModuleResourceStatus(
                        url: "https://example.com/module/script.js", kind: "script", lines: [4, 5],
                        file: "script.js", state: "ok", error: nil)],
                    refusedRules: [ConcordMitmRefusedRule(line: 12, detail: "示例：策略无对应出站，已跳过")],
                    hostNetwork: .object([:])),
                ConcordMitmModuleStatus(
                    name: "示例模块-重复", enabled: false, inForce: false,
                    problem: ConcordMitmModuleProblem(reason: "duplicate", detail: nil),
                    off: ConcordMitmModuleOff(reason: "requirement"),
                    resources: [], refusedRules: [], hostNetwork: .object([:])),
            ]))
        case "mitm.issueCertificate":
            result = AnyEncodable(ConcordMitmPem(pem: ""))
        case "mitm.runScript":
            result = AnyEncodable(MitmScriptResult(result: MitmScriptOutput(
                logs: ["示例脚本输出：规则已应用（示例数据）"], result: nil, error: nil)))
        case "mitm.exchanges":
            result = AnyEncodable(MitmExchangesResult(result: sampleExchangeList))
        case "mitm.query":
            result = AnyEncodable(sampleMitmQuery(paramsData: paramsData))
        case "mitm.exchange":
            result = AnyEncodable(MitmExchangeResult(result: sampleExchangeDetailTyped))
        case "mitm.body":
            result = AnyEncodable(MitmBodyResult(result: MitmBody(
                data: Data("示例响应正文：{\"ok\":true}".utf8).base64EncodedString(),
                truncated: false, encoding: "")))
        case "config.apply":
            result = AnyEncodable(ConcordConfigApplyResult(warnings: [
                ConcordWarning(level: "warning", code: "unknown_key", path: "proxies[0]", message: "示例警告：某个节点类型在当前核心版本不受支持，已跳过")
            ]))
        case "config.general":
            result = AnyEncodable(sampleGeneral)
        case "core.stats":
            result = AnyEncodable(ConcordCoreStats(rss: 18_432_000))
        case "proxy.groups":
            result = AnyEncodable(sampleProxyGroups)
        case "proxy.select":
            result = AnyEncodable(ConcordProxySelectResult(changed: true, seq: 42))
        case "delay.test":
            result = AnyEncodable(sampleDelay(paramsData: paramsData))
        case "profile.inspect":
            result = AnyEncodable(ConcordProfileInspect())
        case "provider.list":
            result = AnyEncodable(ConcordProviderList(providers: sampleProviders))
        case "rule.list":
            result = AnyEncodable(ConcordRuleList(rules: sampleRules))
        case "traffic.watch":
            result = AnyEncodable(sampleTraffic)
        case "connection.watch":
            result = AnyEncodable(ConcordConnectionSnapshot(connections: sampleConnections, ended: sampleEndedConnections))
        case "connection.close":
            result = AnyEncodable(EmptyResultJSON())
        case "log.watch":
            result = AnyEncodable(LogSnapshot(entries: sampleLogs))
        case "dns.watch":
            result = AnyEncodable(DnsSnapshot(entries: sampleDns))
        case "probe.outboundIp":
            result = AnyEncodable(ConcordOutboundIp(url: "https://api.ip.sb/ip", body: "203.0.113.42", delay: 87, chains: ["示例节点-香港-01"], error: nil, epoch: 1, version: 1))
        case "core.lastWarnings":
            result = AnyEncodable(WarningsResult(warnings: []))
        case "profile.outbounds":
            result = AnyEncodable(ConcordProfileOutbounds())
        case "profile.clearEffect":
            result = AnyEncodable(EmptyResultJSON())
        case "convert.encodeLinks":
            result = AnyEncodable(ConcordLinkList())
        case "convert.decodeLinks":
            result = AnyEncodable(ConcordDecodedLinks(results: [
                [.object(["name": .string("示例节点-香港-01"), "type": .string("vless"), "server": .string("hk.example.com"), "port": .int(443)])],
                [],
            ]))
        case "provider.get":
            result = AnyEncodable(ConcordProviderInfo(
                name: "airport", type: "proxy", vehicleType: "http", count: 42, path: "airport.yaml", updatedAt: 1763430000,
                testUrl: "http://www.gstatic.com/generate_204", expectedStatus: "204", behavior: nil, format: nil,
                subscriptionInfo: ConcordSubscriptionInfo(upload: 123_456_789, download: 9_876_543_210, total: 107_374_182_400, expire: 1796064000)))
        case "provider.sideLoad", "provider.healthCheck", "network.update":
            result = AnyEncodable(EmptyResultJSON())
        case "events.watch":
            result = AnyEncodable(ConcordEventSnapshot(entries: [
                ConcordCoreEvent(type: "resourceUpdate", kind: "proxyProvider", name: "airport", phase: "updated", error: nil, url: nil, value: nil, message: nil, seq: nil, origin: nil, change: nil),
                ConcordCoreEvent(type: "delay", kind: nil, name: "示例节点-香港-01", phase: nil, error: nil, url: "https://www.google.com/generate_204", value: 87, message: nil, seq: nil, origin: nil, change: nil),
            ]))
        case "engine.state":
            result = AnyEncodable(ConcordEngineStatus(state: "running", kind: nil, faults: nil))
        default:
            result = AnyEncodable(EmptyResultJSON())
        }
        let envelope = JSONRPCEnvelope(result: result)
        return try JSONEncoder().encode(envelope)
    }

    private struct EmptyResultJSON: Encodable {}
    private struct LogSnapshot: Encodable { let entries: [ConcordLogEntry] }
    private struct DnsSnapshot: Encodable { let entries: [ConcordDnsEntry] }
    private struct WarningsResult: Encodable { let warnings: [ConcordWarning] }
    private struct JSONRPCEnvelope: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let result: AnyEncodable
    }

    /// Re-encodes a typed value as open JSON (used for the MITM mock
    /// results, whose client type is JSONValue).
    static func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }

    /// The sample nodes as open JSON proxy mappings (config.read /
    /// convert.subscription shape).
    static var sampleProxyObjects: [JSONValue] {
        [
            .object(["name": .string("示例节点-香港-01"), "type": .string("vless"), "server": .string("hk.example.com"), "port": .int(443)]),
            .object(["name": .string("示例节点-日本-02"), "type": .string("trojan"), "server": .string("jp.example.com"), "port": .int(443)]),
            .object(["name": .string("示例节点-美国-03"), "type": .string("ss"), "server": .string("us.example.com"), "port": .int(8388)]),
            .object(["name": .string("示例节点-新加坡-04"), "type": .string("vmess"), "server": .string("sg.example.com"), "port": .int(443)]),
        ]
    }

    static func sampleProxyDefinition(paramsData: Data) -> JSONValue {
        struct P: Decodable { let name: String }
        let name = (try? JSONDecoder().decode(P.self, from: paramsData))?.name ?? "示例节点"
        let base = sampleProxyObjects.first { $0.objectValue?["name"]?.stringValue == name }
            ?? .object(["name": .string(name), "type": .string("vless"), "server": .string("example.com"), "port": .int(443)])
        var object = base.objectValue ?? [:]
        object["udp"] = .bool(true)
        object["skip-cert-verify"] = .bool(false)
        return .object(object)
    }

    static var sampleProxyStates: [ConcordProxyState] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return sampleProxyGroups.nodes.filter { $0.type != "DIRECT" }.map { node in
            let alive = node.name != "示例节点-新加坡-04"
            return ConcordProxyState(
                name: node.name, udp: true, alive: alive,
                history: [ConcordDelayRecord(time: now - 60_000, delay: UInt16(sampleLatency(for: node.name)))],
                extra: [ConcordUrlHealth(url: "http://www.gstatic.com/generate_204", alive: alive, history: [])])
        }
    }

    static func sampleDnsQuery(paramsData: Data) -> ConcordDnsQueryResult {
        _ = paramsData
        return ConcordDnsQueryResult()
    }

    static var sampleServices: [ConcordServiceItem] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            ConcordServiceItem(name: "google", status: "available", region: "US", delay: 132, chains: ["示例节点-香港-01"], checkedAt: now, epoch: 1, version: 1, hits: [ConcordRouteHit(host: "www.google.com:443", exit: "\"示例节点-香港-01\" Shadowsocks 203.0.113.42")]),
            ConcordServiceItem(name: "github", status: "available", region: "", delay: 98, chains: ["示例节点-香港-01"], checkedAt: now, epoch: 1, version: 1, hits: nil, ip: "20.205.243.166"),
            ConcordServiceItem(name: "youtube", status: "restricted", region: "HK", delay: 210, chains: ["示例节点-香港-01"], checkedAt: now, epoch: 1, version: 1, hits: nil),
            ConcordServiceItem(name: "netflix", status: "blocked", region: nil, delay: nil, chains: nil, checkedAt: now, epoch: 1, version: 1, hits: nil),
        ]
    }

    static var sampleExchangeList: MitmExchangeList {
        MitmExchangeList(capturing: true, since: nil, exchanges: [
            MitmExchangeSummary(exchangeId: 1, start: "2026-11-17T09:00:00Z", pending: false, duration: 87, method: "GET", url: "https://www.google.com/", status: 200, requestSize: 512, responseSize: 2048, error: nil, host: "www.google.com", path: "/?gws_rd=ssl", contentType: "text/html", statusClass: "2xx", kind: "html", connectionId: 1, app: ConcordMitmApp(process: "Safari", processPath: nil, uid: nil)),
            MitmExchangeSummary(exchangeId: 2, start: "2026-11-17T09:00:05Z", pending: true, duration: 0, method: "POST", url: "https://api.github.com/user", status: 0, requestSize: 128, responseSize: 0, error: nil, host: "api.github.com", path: "/user", contentType: nil, statusClass: "pending", kind: "other", connectionId: 2, app: ConcordMitmApp(process: "Safari", processPath: nil, uid: nil)),
        ])
    }

    /// Sample mitm.query answer (upstream 0c9788f): the sample
    /// exchanges filtered by the query text, like the core filters
    /// by filter.text (without case, in the URL / method / content
    /// type / error / app).
    static func sampleMitmQuery(paramsData: Data) -> ConcordMitmQueryAnswer {
        let params = (try? JSONDecoder().decode(ConcordMitmQueryParams.self, from: paramsData)) ?? ConcordMitmQueryParams()
        let all = sampleExchangeList.exchanges
        let text = (params.filter.text ?? "").lowercased()
        let matched: [MitmExchangeSummary]
        if text.isEmpty {
            matched = all
        } else {
            matched = all.filter {
                $0.url.lowercased().contains(text)
                    || $0.method.lowercased().contains(text)
                    || ($0.contentType?.lowercased().contains(text) ?? false)
                    || ($0.error?.lowercased().contains(text) ?? false)
                    || ($0.app?.process.lowercased().contains(text) ?? false)
            }
        }
        return ConcordMitmQueryAnswer(
            capturing: true, since: sampleExchangeList.since, version: 42,
            oldest: 1, held: UInt64(all.count), matched: UInt64(matched.count),
            exchanges: matched, next: nil, facets: nil, rate: nil, medianDuration: 87)
    }

    /// Sample ended connections (upstream 0c9788f): one failed dial
    /// (refused, zero traffic) and one finished connection with
    /// final totals, for the 最近请求 feed in sample mode.
    static var sampleEndedConnections: [ConcordEndedConnection] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let failed = ConcordConnection(
            connectionId: 5, start: now - 9000, network: "tcp",
            sourceIp: "10.0.0.2", sourcePort: 51238,
            destinationIp: "5.6.7.8", destinationPort: 443,
            host: "bad.example.com", sniffHost: "bad.example.com",
            inboundType: "tun", inboundIp: nil, inboundPort: nil,
            inboundName: nil, inboundUser: nil, dnsMode: "fake-ip",
            uid: nil, process: "Safari", processPath: nil,
            upload: 0, download: 0, rule: "PROXY", proxy: "示例节点-香港-01",
            failure: ConcordConnectionFailure(kind: "refused", message: "连接被拒：5.6.7.8:443"))
        return [
            ConcordEndedConnection(connection: failed, reason: "failed", endedAt: now - 8000, message: "连接被拒：5.6.7.8:443"),
            ConcordEndedConnection(connection: sampleConnections[0], reason: "finished", endedAt: now - 5000, message: nil),
        ]
    }

    /// Sample full exchange (upstream 646f8c9 MitmExchange): the
    /// same values the old open-JSON sample carried, as a typed
    /// MitmExchangeDetail.
    static var sampleExchangeDetailTyped: MitmExchangeDetail {
        MitmExchangeDetail(
            exchangeId: 1, start: "2026-11-17T09:00:00Z", pending: false, duration: 87,
            ttfb: 42, method: "GET", url: "https://www.google.com/", originalUrl: nil,
            proto: "HTTP/1.1", status: 200, requestSize: 512, responseSize: 2048,
            error: nil, connection: nil,
            requestHeader: ["user-agent": ["示例"], "accept": ["*/*"]],
            responseHeader: ["content-type": ["text/html"]],
            actions: [MitmExchangeAction(kind: "allow", phase: "request", detail: "")])
    }

    // MARK: Sample values

    static var sampleGeneral: ConcordGeneralState {
        var g = ConcordGeneralState()
        g.mode = "rule"; g.unifiedDelay = false
        return g
    }

    static var sampleProxyGroups: ConcordProxyGroups {
        ConcordProxyGroups(
            order: ["GLOBAL", "PROXY", "Streaming", "DIRECT"],
            groups: [
                ConcordGroupInfo(name: "GLOBAL", type: "select", now: "示例节点-香港-01", all: ["示例节点-香港-01", "示例节点-日本-02", "示例节点-美国-03"], testUrl: "http://www.gstatic.com/generate_204", expectedStatus: nil, fixed: nil, hidden: false, icon: "", emptyFallback: ""),
                ConcordGroupInfo(name: "PROXY", type: "url-test", now: "示例节点-香港-01", all: ["示例节点-香港-01", "示例节点-日本-02", "示例节点-美国-03", "示例节点-新加坡-04"], testUrl: "http://www.gstatic.com/generate_204", expectedStatus: nil, fixed: nil, hidden: false, icon: "", emptyFallback: ""),
                ConcordGroupInfo(name: "Streaming", type: "select", now: "示例节点-日本-02", all: ["示例节点-日本-02", "示例节点-美国-03"], testUrl: "http://www.gstatic.com/generate_204", expectedStatus: nil, fixed: nil, hidden: false, icon: "", emptyFallback: ""),
                ConcordGroupInfo(name: "DIRECT", type: "select", now: "DIRECT", all: ["DIRECT"], testUrl: "", expectedStatus: nil, fixed: nil, hidden: false, icon: "", emptyFallback: ""),
            ],
            nodes: [
                ConcordNodeInfo(name: "示例节点-香港-01", type: "VLESS", provider: "示例订阅"),
                ConcordNodeInfo(name: "示例节点-日本-02", type: "Trojan", provider: "示例订阅"),
                ConcordNodeInfo(name: "示例节点-美国-03", type: "Shadowsocks", provider: "示例订阅"),
                ConcordNodeInfo(name: "示例节点-新加坡-04", type: "VMess", provider: "示例订阅"),
                ConcordNodeInfo(name: "DIRECT", type: "DIRECT", provider: nil),
            ]
        )
    }

    /// Deterministic sample latency per node name (stable across runs).
    static func sampleLatency(for name: String) -> Int32 {
        let base = abs(name.unicodeScalars.reduce(0) { $0 &+ Int32($1.value) }) % 220
        return 28 + base
    }

    static func sampleDelay(paramsData: Data) -> ConcordDelayResult {
        struct P: Decodable { let proxy: String }
        let proxy = (try? JSONDecoder().decode(P.self, from: paramsData))?.proxy ?? "示例节点"
        return ConcordDelayResult(name: proxy, url: "http://www.gstatic.com/generate_204", value: sampleLatency(for: proxy))
    }

    static var sampleRules: [ConcordRuleEntry] {
        [
            ConcordRuleEntry(type: "GEOSITE", payload: "category-ads-all", target: "REJECT"),
            ConcordRuleEntry(type: "GEOSITE", payload: "private", target: "DIRECT"),
            ConcordRuleEntry(type: "GEOSITE", payload: "cn", target: "DIRECT"),
            ConcordRuleEntry(type: "GEOIP", payload: "CN", target: "DIRECT"),
            ConcordRuleEntry(type: "GEOIP", payload: "private", target: "DIRECT"),
            ConcordRuleEntry(type: "DOMAIN-SUFFIX", payload: "google.com", target: "PROXY"),
            ConcordRuleEntry(type: "DOMAIN-SUFFIX", payload: "youtube.com", target: "Streaming"),
            ConcordRuleEntry(type: "DOMAIN-SUFFIX", payload: "netflix.com", target: "Streaming"),
            ConcordRuleEntry(type: "DOMAIN-KEYWORD", payload: "github", target: "PROXY"),
            ConcordRuleEntry(type: "DOMAIN", payload: "example.com", target: "DIRECT"),
            ConcordRuleEntry(type: "IP-CIDR", payload: "192.168.0.0/16", target: "DIRECT"),
            ConcordRuleEntry(type: "IP-CIDR", payload: "10.0.0.0/8", target: "DIRECT"),
            ConcordRuleEntry(type: "DST-PORT", payload: "22", target: "DIRECT"),
            ConcordRuleEntry(type: "SRC-PORT", payload: "53", target: "DIRECT"),
            ConcordRuleEntry(type: "GEOSITE", payload: "apple", target: "DIRECT"),
            ConcordRuleEntry(type: "GEOSITE", payload: "microsoft", target: "DIRECT"),
            ConcordRuleEntry(type: "DOMAIN-SUFFIX", payload: "openai.com", target: "PROXY"),
            ConcordRuleEntry(type: "DOMAIN-SUFFIX", payload: "cloudflare.com", target: "PROXY"),
            ConcordRuleEntry(type: "IP-CIDR6", payload: "fc00::/7", target: "DIRECT"),
            ConcordRuleEntry(type: "MATCH", payload: "", target: "PROXY"),
        ]
    }

    static var sampleProviders: [ConcordProviderInfo] {
        [
            ConcordProviderInfo(name: "示例订阅", type: "proxy", vehicleType: "HTTP", count: 4, path: "providers/example.yaml", updatedAt: 1_764_000_000, testUrl: "http://www.gstatic.com/generate_204", expectedStatus: nil, behavior: nil, format: nil, subscriptionInfo: nil),
            ConcordProviderInfo(name: "GeoSite-CN", type: "rule", vehicleType: "File", count: 1280, path: "rules/geosite-cn.yaml", updatedAt: 1_764_000_000, testUrl: nil, expectedStatus: nil, behavior: "domain", format: "yaml", subscriptionInfo: nil),
            ConcordProviderInfo(name: "GeoIP-CN", type: "rule", vehicleType: "File", count: 512, path: "rules/geoip-cn.mrs", updatedAt: 1_764_000_000, testUrl: nil, expectedStatus: nil, behavior: "ipcidr", format: "mrs", subscriptionInfo: nil),
        ]
    }

    static var sampleTraffic: ConcordTraffic {
        ConcordTraffic(up: 128_000, down: 1_024_000, totalUp: 45_000_000, totalDown: 380_000_000)
    }

    static var sampleConnections: [ConcordConnection] {
        let now = Int64(Date().timeIntervalSince1970)
        return [
            ConcordConnection(connectionId: 1, start: now - 42, network: "tcp", sourceIp: "10.0.0.2", sourcePort: 51234, destinationIp: "142.250.72.14", destinationPort: 443, host: "www.google.com", sniffHost: "www.google.com", inboundType: "tun", inboundIp: nil, inboundPort: nil, inboundName: nil, inboundUser: nil, dnsMode: "fake-ip", uid: nil, process: "Safari", processPath: nil, upload: 12_400, download: 480_000, rule: "GEOSITE,google", proxy: "示例节点-香港-01", ruleIndex: 3, timing: ConcordConnectionTiming(accepted: (now - 42) * 1000, dnsStart: 1200, dnsEnd: 5400, routed: 6100, dialStart: 6200, connected: 45000, tls: 90000, dialEnd: 91000), dnsQueries: [1]),
            ConcordConnection(connectionId: 2, start: now - 180, network: "tcp", sourceIp: "10.0.0.2", sourcePort: 51235, destinationIp: "104.18.32.7", destinationPort: 443, host: "github.com", sniffHost: "github.com", inboundType: "tun", inboundIp: nil, inboundPort: nil, inboundName: nil, inboundUser: nil, dnsMode: "fake-ip", uid: nil, process: "Safari", processPath: nil, upload: 8_200, download: 210_000, rule: "DOMAIN-KEYWORD,github", proxy: "示例节点-香港-01"),
            ConcordConnection(connectionId: 3, start: now - 12, network: "udp", sourceIp: "10.0.0.2", sourcePort: 51236, destinationIp: "8.8.8.8", destinationPort: 53, host: nil, sniffHost: nil, inboundType: "tun", inboundIp: nil, inboundPort: nil, inboundName: nil, inboundUser: nil, dnsMode: "normal", uid: nil, process: nil, processPath: nil, upload: 512, download: 1_024, rule: "GEOIP,private", proxy: "DIRECT"),
            ConcordConnection(connectionId: 4, start: now - 300, network: "tcp", sourceIp: "10.0.0.2", sourcePort: 51237, destinationIp: "151.101.1.140", destinationPort: 443, host: "www.youtube.com", sniffHost: "www.youtube.com", inboundType: "tun", inboundIp: nil, inboundPort: nil, inboundName: nil, inboundUser: nil, dnsMode: "fake-ip", uid: nil, process: "YouTube", processPath: nil, upload: 22_000, download: 2_400_000, rule: "DOMAIN-SUFFIX,youtube.com", proxy: "示例节点-日本-02"),
        ]
    }

    static var sampleLogs: [ConcordLogEntry] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            ConcordLogEntry(level: "info", time: now - 5000, text: "示例日志：核心已启动（示例数据，非真实核心日志）"),
            ConcordLogEntry(level: "info", time: now - 4000, text: "示例日志：已应用配置，节点 4 个，代理组 4 个，规则 20 条"),
            ConcordLogEntry(level: "warning", time: now - 3000, text: "示例日志：节点 示例节点-新加坡-04 延迟测试超时"),
            ConcordLogEntry(level: "info", time: now - 2000, text: "示例日志：TUN 未启动（示例数据）"),
            ConcordLogEntry(level: "debug", time: now - 1000, text: "示例日志：DNS 查询 www.google.com -> 142.250.72.14"),
        ]
    }

    static var sampleDns: [ConcordDnsEntry] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            ConcordDnsEntry(domain: "www.google.com", type: "A", initiator: "10.0.0.2:51234", upstream: "8.8.8.8", cached: false, answers: ["142.250.72.14"], rcode: "NOERROR", error: "", delay: 24, time: now - 4000, dnsId: 1),
            ConcordDnsEntry(domain: "github.com", type: "A", initiator: "10.0.0.2:51235", upstream: "1.1.1.1", cached: true, answers: ["140.82.112.4"], rcode: "NOERROR", error: "", delay: 3, time: now - 3000, dnsId: 2),
            ConcordDnsEntry(domain: "www.youtube.com", type: "AAAA", initiator: "10.0.0.2:51237", upstream: "8.8.4.4", cached: false, answers: ["2607:f8b0:4004:800::200e"], rcode: "NOERROR", error: "", delay: 41, time: now - 2000, dnsId: 3),
            ConcordDnsEntry(domain: "ads.example.com", type: "A", initiator: "10.0.0.2:51238", upstream: "fake-ip", cached: false, answers: ["198.18.0.1"], rcode: "NOERROR", error: "", delay: 1, time: now - 1000, dnsId: 4),
        ]
    }
}

// MARK: - Shared formatting helpers

enum ConcordFormat {
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        // Video format: one decimal, strip a trailing ".0"
        // ("540 KB", "170 GB"; "1.1 GB" keeps the .1).
        var number = String(format: "%.1f", v)
        if number.hasSuffix(".0") { number.removeLast(2) }
        return "\(number) \(units[i])"
    }

    /// Zero-padded HH:MM:SS uptime ("00:00:37"); hours may exceed 24
    /// ("27:15:00"). Used by the Dashboard status card.
    static func uptimeHMS(seconds: Int64) -> String {
        let total = max(seconds, 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, secs)
    }

    static func rate(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func latency(_ ms: Int32?) -> String {
        guard let ms else { return "未测" }
        if ms < 0 { return "失败" }
        return "\(ms) ms"
    }

    static func time(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Parses an RFC 3339 timestamp (mitm exchange `start`, upstream
    /// crates/mitm/src/capture.rs ExchangeSummary) and formats it
    /// exactly like `time(_:)` ("HH:mm:ss", local time); falls back
    /// to the raw string when it cannot be parsed.
    static func time(rfc3339: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: rfc3339) else { return rfc3339 }
        return time(Int64(date.timeIntervalSince1970 * 1000))
    }

    static func duration(seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
