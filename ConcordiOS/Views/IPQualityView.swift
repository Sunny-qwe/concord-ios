import SwiftUI

// MARK: - IP quality (Tools -> IP 质量)
// Shows the CURRENT egress IP's quality: address, country, city,
// ISP, ASN and timezone.
//
// FlClash (lib/common/ip_quality.dart + lib/providers/ip_quality.dart)
// asks several sources in waves — the tightest-quota sources last,
// a 1 s hedge between waves, 8 s per source — caches the answer
// per IP for up to 3 days, and cools down 5 minutes after a total
// failure. Same here:
//
//   wave 1: ident.me, ip-api.com, ipquery.io
//   wave 2: iplocate.io
//   wave 3: api.ipapi.is
//   wave 4: proxycheck.io
//
// The first source that answers wins; the rest are cancelled.
// ip-api.com is the only source that returns every displayed field
// (country, city, ISP, ASN, timezone) in one shape, so it is the
// primary display source — the others fill what they have and show
// "—" for the rest.
//
// URLSession follows the system's default route, so when the VPN is
// on the answer IS the proxy egress IP, and when it is off it is the
// phone's direct IP. The page says which one it is, in the header
// and next to the result — the two must never be confused.
//
// The cache is keyed by the resolved IP and whether the VPN was on
// (the egress IP changes when the VPN toggles). Automatic fetches
// use the cache and respect the 5-minute failure cooldown; the
// 刷新 button always goes to the network.

struct IPQualityInfo: Codable {
    let status: String
    let message: String?
    let country: String?
    let countryCode: String?
    let city: String?
    let regionName: String?
    let isp: String?
    let org: String?
    let asn: String?
    let timezone: String?
    let query: String?
    let lat: Double?
    let lon: Double?

    /// ip-api.com calls the ASN field `as`, not `asn` — without
    /// this mapping `asn` never decoded and the page always showed
    /// "—" (audit B13).
    enum CodingKeys: String, CodingKey {
        case status, message, country, countryCode, city, regionName
        case isp, org, timezone, query, lat, lon
        case asn = "as"
    }
}

/// One cached answer: the egress IP it was checked for, whether the
/// VPN was on, when it was checked, and which source answered.
private struct CachedIPQuality: Codable {
    let checkedAt: Date
    let viaVPN: Bool
    let source: String
    let info: IPQualityInfo
}

struct IPQualityView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var info: IPQualityInfo?
    @State private var sourceName: String?
    @State private var fromCache = false
    @State private var cacheAge: String?
    @State private var latencyMs: Int?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var fetchedViaVPN: Bool?

    private var isViaVPN: Bool { tunnelManager.isRunning }

    /// 8 s per source, like FlClash's lookup timeout (interface B3:
    /// the old fetch had no explicit timeout at all).
    private static let timedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    private static let cacheKey = "ConcordiOS.ipQuality.cache.v1"
    private static let failedAtKey = "ConcordiOS.ipQuality.failedAt.v1"
    private static let cacheMaxAge: TimeInterval = 3 * 24 * 3600
    private static let failureCooldown: TimeInterval = 5 * 60

    /// FlClash's waves (ip_quality.dart `_waves`): tightest free
    /// quotas last, so they are rarely asked.
    private static let waves: [[IPQualitySource]] = [
        [.identMe, .ipApiCom, .ipQuery],
        [.ipLocate],
        [.ipApiIs],
        [.proxyCheck],
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    BlobIcon(
                        systemName: isViaVPN ? "shield.lefthalf.filled" : "house.fill",
                        iconColor: .white,
                        blobColor: isViaVPN ? ConcordTheme.accent : .gray,
                        size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isViaVPN ? "代理出口 IP" : "本机直连 IP")
                            .font(.caption.weight(.semibold))
                        Text(isViaVPN
                             ? "VPN 正在运行：下面是代理出口的 IP 质量。"
                             : "VPN 未运行：下面是你手机直连网络的 IP 质量，不是代理出口。开启 VPN 后再刷新，看到的才是代理出口。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button {
                    Task { await fetch(forceRefresh: true) }
                } label: {
                    Label(isLoading ? "查询中…" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            if isLoading {
                Section { ProgressView("正在查询出口 IP…") }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let info, info.status == "success" {
                Section("IP 地址") {
                    LabeledContent("IP", value: info.query ?? "—")
                    if let latencyMs {
                        LabeledContent("查询延迟", value: "\(latencyMs) ms")
                    }
                    if let fetchedViaVPN {
                        LabeledContent("查询时 VPN", value: fetchedViaVPN ? "开启（代理出口）" : "关闭（本机直连）")
                    }
                    if let sourceName {
                        LabeledContent("数据来源", value: sourceName + (fromCache ? "（缓存\(cacheAge ?? "")）" : ""))
                    }
                    if let lat = info.lat, let lon = info.lon {
                        LabeledContent("经纬度", value: "\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))")
                    }
                }
                Section("地理位置") {
                    LabeledContent("国家", value: [info.country, info.countryCode.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                    LabeledContent("城市", value: [info.regionName, info.city].compactMap { $0 }.joined(separator: " · ").isEmpty ? "—" : [info.regionName, info.city].compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("时区", value: info.timezone ?? "—")
                }
                Section("网络归属") {
                    LabeledContent("运营商", value: info.isp ?? "—")
                    LabeledContent("组织", value: info.org ?? "—")
                    LabeledContent("ASN", value: info.asn ?? "—")
                }
            } else if info != nil {
                Section {
                    Text("查询服务返回失败：\(info?.message ?? "未知错误")")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("多源查询（ident.me、ip-api.com、ipquery.io、iplocate.io、ipapi.is、proxycheck.io，配额最紧的源最后问），每个源 8 秒超时；同一出口 IP 的结果缓存 3 天，全部失败后 5 分钟内不再自动重试（点「刷新」可立即重试）。它只告诉你出口 IP 是谁、在哪里、属于哪个运营商，不做测速、不判断节点能不能解锁流媒体。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("IP 质量")
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetch() }
    }

    // MARK: - Fetch (cache -> cooldown -> waves)

    private func fetch(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        let started = Date()
        defer { isLoading = false }
        let viaVPN = isViaVPN
        // 1. Fresh cache (automatic fetches only): same VPN state,
        // checked within 3 days.
        if !forceRefresh, let cached = Self.loadCache(),
           cached.viaVPN == viaVPN,
           Date().timeIntervalSince(cached.checkedAt) < Self.cacheMaxAge {
            info = cached.info
            sourceName = cached.source
            fromCache = true
            cacheAge = Self.ageString(since: cached.checkedAt)
            fetchedViaVPN = cached.viaVPN
            latencyMs = nil
            return
        }
        // 2. Failure cooldown (automatic fetches only): a total
        // failure within the last 5 minutes is not retried.
        if !forceRefresh, let failedAt = Self.loadFailureAt(),
           Date().timeIntervalSince1970 - failedAt < Self.failureCooldown {
            let remaining = Int(Self.failureCooldown - (Date().timeIntervalSince1970 - failedAt))
            errorMessage = "上次查询全部失败，\(remaining) 秒后再自动重试（点「刷新」可立即重试）。"
            return
        }
        // 3. Network: FlClash's waves.
        fromCache = false
        cacheAge = nil
        if let (answer, source) = await lookupWaves() {
            latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            fetchedViaVPN = viaVPN
            info = answer
            sourceName = source
            Self.saveCache(CachedIPQuality(checkedAt: Date(), viaVPN: viaVPN, source: source, info: answer))
            Self.clearFailure()
        } else {
            Self.recordFailure()
            errorMessage = "全部查询源都失败了（\(Self.waves.flatMap { $0 }.map(\.label).joined(separator: "、"))），请检查网络后点「刷新」重试。"
        }
    }

    /// Runs the source waves with a 1 s hedge between them: a wave
    /// only starts while the earlier ones are still unanswered, so
    /// the tightest-quota sources are rarely asked. Like FlClash,
    /// the next wave also starts as soon as the current wave's
    /// sources have all answered-or-failed. First answer wins; the
    /// rest are cancelled.
    private func lookupWaves() async -> (IPQualityInfo, String)? {
        var launchedWave = 0
        var inFlight = 0
        return await withTaskGroup(of: WaveOutcome.self) { group in
            func addWave(_ index: Int) {
                launchedWave = index
                for source in Self.waves[index] {
                    inFlight += 1
                    group.addTask { await Self.query(source: source) }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return .hedge(index)
                }
            }
            addWave(0)
            for await outcome in group {
                switch outcome {
                case .answer(let info, let name):
                    group.cancelAll()
                    return (info, name)
                case .failed:
                    inFlight -= 1
                    if inFlight == 0, launchedWave < Self.waves.count - 1 {
                        addWave(launchedWave + 1)
                    }
                case .hedge(let index):
                    // Only the hedge of the latest launched wave may
                    // advance; an earlier hedge firing after an
                    // early advance is stale.
                    if index == launchedWave, launchedWave < Self.waves.count - 1 {
                        addWave(launchedWave + 1)
                    }
                }
            }
            return nil
        }
    }

    /// One source, 8 s timeout. Success needs a resolved IP;
    /// ip-api.com additionally needs status == "success" — a
    /// `status: "fail"` payload (private IP, rate limit) is a
    /// failure, not a result.
    private static func query(source: IPQualitySource) async -> WaveOutcome {
        do {
            let (data, response) = try await Self.timedSession.data(from: source.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(source.label)
            }
            guard let answer = source.parse(data), !(answer.query ?? "").isEmpty else {
                return .failed(source.label)
            }
            return .answer(answer, source.label)
        } catch {
            return .failed(source.label)
        }
    }

    // MARK: - Cache / cooldown persistence

    private static func loadCache() -> CachedIPQuality? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedIPQuality.self, from: data) else { return nil }
        return cached
    }

    private static func saveCache(_ cached: CachedIPQuality) {
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private static func loadFailureAt() -> TimeInterval? {
        let value = UserDefaults.standard.double(forKey: failedAtKey)
        return value > 0 ? value : nil
    }

    private static func recordFailure() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: failedAtKey)
    }

    private static func clearFailure() {
        UserDefaults.standard.removeObject(forKey: failedAtKey)
    }

    private static func ageString(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }

    private enum WaveOutcome {
        case answer(IPQualityInfo, String)
        case failed(String)
        case hedge(Int)
    }
}

// MARK: - Sources

private enum IPQualitySource: CaseIterable {
    case identMe
    case ipApiCom
    case ipQuery
    case ipLocate
    case ipApiIs
    case proxyCheck

    var label: String {
        switch self {
        case .identMe: return "ident.me"
        case .ipApiCom: return "ip-api.com"
        case .ipQuery: return "ipquery.io"
        case .ipLocate: return "iplocate.io"
        case .ipApiIs: return "ipapi.is"
        case .proxyCheck: return "proxycheck.io"
        }
    }

    /// No IP in the path: every source answers the caller's IP,
    /// which is the egress IP the page is about.
    var url: URL {
        switch self {
        case .identMe: return URL(string: "https://ident.me/json")!
        // ip-api.com serves HTTPS only on its paid plan.
        case .ipApiCom: return URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon")!
        case .ipQuery: return URL(string: "https://api.ipquery.io/?format=json")!
        case .ipLocate: return URL(string: "https://iplocate.io/api/lookup/")!
        case .ipApiIs: return URL(string: "https://api.ipapi.is/")!
        case .proxyCheck: return URL(string: "https://proxycheck.io/v3/")!
        }
    }

    /// Parses one source's JSON into the display model. Nil when
    /// the payload is unusable (ip-api.com: status != "success").
    /// Fields a source does not provide stay nil and show "—".
    func parse(_ data: Data) -> IPQualityInfo? {
        switch self {
        case .ipApiCom:
            guard let decoded = try? JSONDecoder().decode(IPQualityInfo.self, from: data),
                  decoded.status == "success" else { return nil }
            return decoded
        default:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Self.fromGenericJSON(self, json)
        }
    }

    private static func fromGenericJSON(_ source: IPQualitySource, _ json: [String: Any]) -> IPQualityInfo? {
        switch source {
        case .identMe:
            // {"ip","type","continent","country","asn","aso","city",
            //  "latitude","longitude","timezone"} — asn may be a
            //  string ("AS13335") or a number.
            guard let ip = text(json["ip"]) else { return nil }
            return IPQualityInfo(
                status: "success", message: nil,
                country: text(json["country"]), countryCode: nil,
                city: text(json["city"]), regionName: nil,
                isp: text(json["aso"]), org: text(json["aso"]),
                asn: asnText(json["asn"]), timezone: text(json["timezone"]),
                query: ip, lat: number(json["latitude"]), lon: number(json["longitude"]))
        case .ipQuery:
            // {"ip","isp":{"asn","org","isp"},
            //  "location":{"country","country_code","city","state",
            //  "timezone","latitude","longitude"},"risk":{...}}
            guard let ip = text(json["ip"]) else { return nil }
            let isp = object(json["isp"])
            let location = object(json["location"])
            return IPQualityInfo(
                status: "success", message: nil,
                country: text(location["country"]), countryCode: text(location["country_code"]),
                city: text(location["city"]), regionName: text(location["state"]),
                isp: text(isp["isp"]), org: text(isp["org"]) ?? text(isp["isp"]),
                asn: asnText(isp["asn"]), timezone: text(location["timezone"]),
                query: ip, lat: number(location["latitude"]), lon: number(location["longitude"]))
        case .ipLocate:
            // {"ip","country","country_code","city","time_zone",
            //  "latitude","longitude","asn":{"asn","name"},
            //  "company":{"name"},"privacy":{...}}
            guard let ip = text(json["ip"]) else { return nil }
            let asn = object(json["asn"])
            let company = object(json["company"])
            return IPQualityInfo(
                status: "success", message: nil,
                country: text(json["country"]), countryCode: text(json["country_code"]),
                city: text(json["city"]), regionName: nil,
                isp: text(company["name"]) ?? text(asn["name"]), org: text(company["name"]) ?? text(asn["name"]),
                asn: asnText(asn["asn"]), timezone: text(json["time_zone"]),
                query: ip, lat: number(json["latitude"]), lon: number(json["longitude"]))
        case .ipApiIs:
            // {"ip","company":{"name"},"asn":{"asn","org"},
            //  "location":{"country","country_code","city","state",
            //  "timezone","latitude","longitude"}}
            guard let ip = text(json["ip"]) else { return nil }
            let company = object(json["company"])
            let asn = object(json["asn"])
            let location = object(json["location"])
            return IPQualityInfo(
                status: "success", message: nil,
                country: text(location["country"]), countryCode: text(location["country_code"]),
                city: text(location["city"]), regionName: text(location["state"]),
                isp: text(company["name"]) ?? text(asn["org"]), org: text(company["name"]) ?? text(asn["org"]),
                asn: asnText(asn["asn"]), timezone: text(location["timezone"]),
                query: ip, lat: number(location["latitude"]), lon: number(location["longitude"]))
        case .proxyCheck:
            // {"status":"ok","<ip>":{"asn","provider","organisation",
            //  "country","isocode","city","latitude","longitude",
            //  "timezone",...}} — the result is keyed by the IP.
            guard text(json["status"]) == "ok" || text(json["status"]) == "warning" else { return nil }
            // The result is keyed by the IP itself; find the entry
            // (and its key, the IP) in one pass.
            guard let (ip, entry) = json.compactMap({ pair -> (String, [String: Any])? in
                guard let dict = pair.value as? [String: Any],
                      dict["asn"] != nil || dict["provider"] != nil else { return nil }
                return (pair.key, dict)
            }).first else { return nil }
            return IPQualityInfo(
                status: "success", message: nil,
                country: text(entry["country"]), countryCode: text(entry["isocode"]),
                city: text(entry["city"]), regionName: nil,
                isp: text(entry["provider"]), org: text(entry["organisation"]) ?? text(entry["provider"]),
                asn: asnText(entry["asn"]), timezone: text(entry["timezone"]),
                query: ip, lat: number(entry["latitude"]), lon: number(entry["longitude"]))
        case .ipApiCom:
            return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    /// "AS13335", "AS13335 Cloudflare, Inc.", or 13335 — kept as
    /// the display string, like ip-api.com's `as` field.
    private static func asnText(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? Int, value != 0 { return "AS\(value)" }
        return nil
    }
}
