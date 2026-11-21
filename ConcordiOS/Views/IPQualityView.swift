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
    /// ip-api.com type signals (decoded only from that source's
    /// JSON; other sources derive the type in their parser).
    let mobile: Bool?
    let proxyFlag: Bool?
    let hosting: Bool?
    /// Upstream IpQuality type + flags (lib/models/ip_quality.dart,
    /// lib/common/ip_quality.dart): what the feature is actually
    /// about. Derived per source by the parser; nil when no source
    /// has stated a type yet.
    let qualityType: IpQualityType?
    /// Defaults on the declarations (not just the init): the
    /// synthesized Decodable falls back to them when an old cache
    /// or an ip-api.com answer carries no quality keys. `var`
    /// (not `let`): the memberwise init below also assigns them,
    /// and a `let` with a default may only be initialized once.
    var isProxy: Bool = false
    var isVpn: Bool = false
    var isTor: Bool = false
    var isAbuser: Bool = false
    /// The type was inferred (a source silent about hosting/mobile
    /// reads as residential) — upstream keeps such an answer only
    /// as a fallback while a stated type is still awaited.
    var typeInferred: Bool = false

    /// ip-api.com calls the ASN field `as`, not `asn` — without
    /// this mapping `asn` never decoded and the page always showed
    /// "—" (audit B13).
    enum CodingKeys: String, CodingKey {
        case status, message, country, countryCode, city, regionName
        case isp, org, timezone, query, lat, lon
        case asn = "as"
        case mobile
        case proxyFlag = "proxy"
        case hosting
        case qualityType, isProxy, isVpn, isTor, isAbuser, typeInferred
    }

    init(status: String, message: String?, country: String?, countryCode: String?,
         city: String?, regionName: String?, isp: String?, org: String?,
         asn: String?, timezone: String?, query: String?, lat: Double?, lon: Double?,
         mobile: Bool? = nil, proxyFlag: Bool? = nil, hosting: Bool? = nil,
         qualityType: IpQualityType? = nil, isProxy: Bool = false, isVpn: Bool = false,
         isTor: Bool = false, isAbuser: Bool = false, typeInferred: Bool = false) {
        self.status = status
        self.message = message
        self.country = country
        self.countryCode = countryCode
        self.city = city
        self.regionName = regionName
        self.isp = isp
        self.org = org
        self.asn = asn
        self.timezone = timezone
        self.query = query
        self.lat = lat
        self.lon = lon
        self.mobile = mobile
        self.proxyFlag = proxyFlag
        self.hosting = hosting
        self.qualityType = qualityType
        self.isProxy = isProxy
        self.isVpn = isVpn
        self.isTor = isTor
        self.isAbuser = isAbuser
        self.typeInferred = typeInferred
    }

    /// A copy of this answer with the upstream quality assessment
    /// attached (the parser derives it from the source's
    /// type/flag fields).
    func assessed(type: IpQualityType, inferred: Bool,
                  isProxy: Bool = false, isVpn: Bool = false,
                  isTor: Bool = false, isAbuser: Bool = false) -> IPQualityInfo {
        IPQualityInfo(
            status: status, message: message, country: country,
            countryCode: countryCode, city: city, regionName: regionName,
            isp: isp, org: org, asn: asn, timezone: timezone, query: query,
            lat: lat, lon: lon, mobile: mobile, proxyFlag: proxyFlag,
            hosting: hosting, qualityType: type, isProxy: isProxy,
            isVpn: isVpn, isTor: isTor, isAbuser: isAbuser,
            typeInferred: inferred)
    }

    /// Quality level (upstream IpQualityExt.level): Tor/abuser is
    /// risky, a hosting IP is normal, residential/mobile/business
    /// is good.
    var qualityLevel: IpQualityLevel? {
        guard let qualityType else { return nil }
        if isTor || isAbuser { return .risky }
        return qualityType == .hosting ? .normal : .good
    }
}

/// Upstream IpType (lib/models/ip_quality.dart): residential /
/// mobile / business / hosting.
enum IpQualityType: String, Codable {
    case residential
    case mobile
    case business
    case hosting

    /// Upstream labels (messages_zh_CN ipTypeResidential etc.).
    var label: String {
        switch self {
        case .residential: return "住宅"
        case .mobile: return "移动网络"
        case .business: return "商业"
        case .hosting: return "机房"
        }
    }
}

/// Upstream IpQualityLevel (lib/models/ip_quality.dart).
enum IpQualityLevel {
    case good
    case normal
    case risky

    /// Upstream labels (messages_zh_CN ipQualityGood etc.).
    var label: String {
        switch self {
        case .good: return "优"
        case .normal: return "普通"
        case .risky: return "风险"
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .normal: return .secondary
        case .risky: return .red
        }
    }
}

/// Per-source failure status (upstream IpQualitySourceStatus).
enum IPQualitySourceStatus: String {
    case noType = "无法判定类型"
    case timeout = "超时"
    case rateLimited = "限流"
    case failed = "失败"
    case ipMismatch = "出站 IP 不一致"
}

struct IPQualityFailure: Identifiable {
    var id: String { source }
    let source: String
    let status: IPQualitySourceStatus
}

/// One cached answer: the egress IP it was checked for, whether the
/// VPN was on, when it was checked, and which source answered.
private struct CachedIPQuality: Codable {
    let checkedAt: Date
    let viaVPN: Bool
    let source: String
    let info: IPQualityInfo
    /// The IP the check was for; nil means "the caller's egress
    /// IP at the time". A cache entry only matches a later check
    /// for the same target — a cached check of 1.2.3.4 must never
    /// answer a later egress check. Old caches (no key) decode as
    /// nil, i.e. egress checks, which is what they were.
    let targetIp: String?
}

struct IPQualityView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var settingsStore: SettingsStore

    /// A specific IP to check (upstream showIpQualitySheet is always
    /// opened for one IP); nil checks the caller's current egress IP.
    @State private var explicitIp: String?
    @State private var ipFieldText: String
    @State private var failures: [IPQualityFailure] = []

    init(ip: String? = nil) {
        let cleaned = ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        _explicitIp = State(initialValue: cleaned?.isEmpty == true ? nil : cleaned)
        _ipFieldText = State(initialValue: cleaned ?? "")
    }

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
                        Text(explicitIp != nil ? "指定 IP" : (isViaVPN ? "代理出口 IP" : "本机直连 IP"))
                            .font(.caption.weight(.semibold))
                        Text(explicitIp != nil
                             ? "正在查询 \(explicitIp!) 的 IP 质量。"
                             : (isViaVPN
                             ? "VPN 正在运行：下面是代理出口的 IP 质量。"
                             : "VPN 未运行：下面是你手机直连网络的 IP 质量，不是代理出口。开启 VPN 后再刷新，看到的才是代理出口。"))
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
                // Hide-IP switch (upstream ip_quality_sheet ends
                // with one); the dashboard's status card masks the
                // IP the same way.
                Toggle("隐藏 IP", isOn: $settingsStore.hideIp)
                    .onChange(of: settingsStore.hideIp) { _, _ in settingsStore.save() }
            }

            Section("指定 IP") {
                HStack {
                    TextField("输入要查询的 IP（如 1.2.3.4）", text: $ipFieldText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.decimalPad)
                    Button("查询") {
                        let cleaned = ipFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                        explicitIp = cleaned.isEmpty ? nil : cleaned
                        Task { await fetch(forceRefresh: true) }
                    }
                    .disabled(isLoading)
                }
                if explicitIp == nil {
                    Text("留空查询当前出口 IP；输入一个 IP 可查询任意 IP 的质量（上游的 IP 质量表总是针对某个具体 IP 打开）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && info == nil {
                // Skeleton rows while loading (upstream
                // ip_quality_sheet lays out the quality/network rows
                // as skeletons so the page keeps its height).
                Section("质量") {
                    skeletonRow("质量等级", width: 40)
                    skeletonRow("IP 类型", width: 64)
                    skeletonRow("标志", width: 40)
                }
                Section("网络归属") {
                    skeletonRow("组织", width: 120)
                    skeletonRow("ASN", width: 56)
                    skeletonRow("数据来源", width: 72)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            // Per-source failure breakdown (upstream
            // ip_quality_sheet: on total failure every source is
            // listed with its status).
            if info == nil, !failures.isEmpty {
                Section("查询源") {
                    ForEach(failures) { failure in
                        LabeledContent(failure.source, value: failure.status.rawValue)
                    }
                }
            }

            if let info, info.status == "success" {
                Section("IP 地址") {
                    LabeledContent("IP", value: settingsStore.hideIp ? "*****" : (info.query ?? "—"))
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
                // The page's actual point upstream (Q-M1/Q-M2): IP
                // type, quality level and Tor/abuser/VPN/proxy
                // flags — derived from the answering source's
                // type/flag fields, not from geography.
                Section("质量") {
                    if info.qualityType == nil {
                        LabeledContent("IP 类型", value: "类型查询失败")
                            .foregroundStyle(.red)
                    } else {
                        if let level = info.qualityLevel {
                            LabeledContent("质量等级", value: level.label + (info.typeInferred ? "（推断）" : ""))
                                .foregroundStyle(level.color)
                        }
                        LabeledContent("IP 类型", value: info.qualityType!.label + (info.typeInferred ? "（推断）" : ""))
                        let flags = [
                            info.isTor ? "Tor" : nil,
                            info.isAbuser ? "滥用记录" : nil,
                            info.isVpn ? "VPN" : nil,
                            info.isProxy ? "代理" : nil,
                        ].compactMap { $0 }
                        LabeledContent("标志", value: flags.isEmpty ? "无" : flags.joined(separator: " · "))
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
                Text("多源查询（ident.me、ip-api.com、ipquery.io、iplocate.io、ipapi.is、proxycheck.io，配额最紧的源最后问），每个源 8 秒超时；同一出口 IP 的结果缓存 3 天，全部失败后 5 分钟内不再自动重试（点「刷新」可立即重试）。它只判断出口 IP 的类型（住宅 / 移动网络 / 商业 / 机房）与质量等级，并标注 Tor、VPN、代理、滥用标志——判断依赖第三方 API，仅供参考；不做测速、不判断节点能不能解锁流媒体。")
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

    /// A skeleton row while the lookup runs (upstream SkeletonText):
    /// a grey bar where the value will land, so the page keeps its
    /// height when the values arrive.
    private func skeletonRow(_ title: String, width: CGFloat) -> some View {
        HStack {
            Text(title)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: width, height: 14)
        }
    }

    // MARK: - Fetch (cache -> cooldown -> waves)

    private func fetch(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        failures = []
        let started = Date()
        defer { isLoading = false }
        let viaVPN = isViaVPN
        let targetIp = explicitIp
        // 1. Fresh cache (automatic fetches only): same VPN state,
        // checked within 3 days — and the same target (a cached
        // check of a specific IP never answers an egress check).
        if !forceRefresh, let cached = Self.loadCache(),
           cached.viaVPN == viaVPN,
           cached.targetIp == targetIp,
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
        let result = await lookupWaves(targetIp: targetIp)
        failures = result.failures
        if let (answer, source) = result.answer {
            latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            fetchedViaVPN = viaVPN
            info = answer
            sourceName = source
            Self.saveCache(CachedIPQuality(checkedAt: Date(), viaVPN: viaVPN, source: source, info: answer, targetIp: targetIp))
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
    /// sources have all answered-or-failed. A stated type wins
    /// immediately; an inferred (residential-by-silence) answer is
    /// kept only as a fallback while a stated type is still awaited
    /// (upstream _Lookup._onAnswer/_settle). On total failure the
    /// per-source statuses come back for the breakdown section.
    private func lookupWaves(targetIp: String?) async -> (answer: (IPQualityInfo, String)?, failures: [IPQualityFailure]) {
        var launchedWave = 0
        var inFlight = 0
        var fallback: (IPQualityInfo, String)?
        var failures: [IPQualityFailure] = []
        let answer = await withTaskGroup(of: WaveOutcome.self, returning: (IPQualityInfo, String)?.self) { group in
            func addWave(_ index: Int) {
                launchedWave = index
                for source in Self.waves[index] {
                    inFlight += 1
                    group.addTask { await Self.query(source: source, targetIp: targetIp) }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return .hedge(index)
                }
            }
            addWave(0)
            for await outcome in group {
                switch outcome {
                case .answer(let info, let name, let inferred):
                    if inferred {
                        if fallback == nil { fallback = (info, name) }
                    } else {
                        group.cancelAll()
                        return (info, name)
                    }
                case .failed(let source, let status):
                    inFlight -= 1
                    failures.append(IPQualityFailure(source: source, status: status))
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
            return fallback
        }
        return (answer, failures.sorted { $0.source < $1.source })
    }

    /// One source, 8 s timeout. Success needs a resolved IP and a
    /// stated (or inferred) type; a 429 is rate-limited, a
    /// proxycheck `denied` is rate-limited, an ident.me answer for
    /// another IP is an IP mismatch, and a parse with no type is a
    /// no-type failure (upstream _query/_statusOf).
    private static func query(source: IPQualitySource, targetIp: String?) async -> WaveOutcome {
        do {
            let (data, response) = try await Self.timedSession.data(from: source.url(for: targetIp))
            guard let http = response as? HTTPURLResponse else {
                return .failed(source.label, .failed)
            }
            if http.statusCode == 429 {
                return .failed(source.label, .rateLimited)
            }
            guard http.statusCode == 200 else {
                return .failed(source.label, .failed)
            }
            switch source.parse(data, targetIp: targetIp) {
            case .answer(let info, let inferred):
                return .answer(info, source.label, inferred)
            case .failure(let status):
                return .failed(source.label, status)
            }
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                return .failed(source.label, .timeout)
            }
            return .failed(source.label, .failed)
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
        /// An answer: the info, the source label, and whether the
        /// type was inferred (residential-by-silence) rather than
        /// stated — inferred answers are only a fallback.
        case answer(IPQualityInfo, String, Bool)
        case failed(String, IPQualitySourceStatus)
        case hedge(Int)
    }
}

/// One source's parse outcome: an answer (with its inferred
/// flag) or a classified failure.
private enum SourceParseResult {
    case answer(IPQualityInfo, inferred: Bool)
    case failure(IPQualitySourceStatus)
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

    /// The source URL for one IP (upstream ip_quality.dart
    /// _urlOf): ip-api.com takes the IP in the path with
    /// type-relevant fields; the others take it in the path or a
    /// query parameter. ident.me has no IP parameter — it always
    /// answers the caller's IP, and a mismatch is a failure (Q-M6).
    /// Nil IP means "the caller's IP", the egress IP the page is
    /// about.
    func url(for ip: String?) -> URL {
        switch self {
        case .identMe: return URL(string: "https://ident.me/json")!
        // ip-api.com serves HTTPS only on its paid plan.
        case .ipApiCom:
            if let ip {
                return URL(string: "http://ip-api.com/json/\(ip)?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting")!
            }
            return URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting")!
        case .ipQuery:
            if let ip { return URL(string: "https://api.ipquery.io/\(ip)?format=json")! }
            return URL(string: "https://api.ipquery.io/?format=json")!
        case .ipLocate:
            if let ip { return URL(string: "https://iplocate.io/api/lookup/\(ip)")! }
            return URL(string: "https://iplocate.io/api/lookup/")!
        case .ipApiIs:
            if let ip { return URL(string: "https://api.ipapi.is/?q=\(ip)")! }
            return URL(string: "https://api.ipapi.is/")!
        case .proxyCheck:
            if let ip { return URL(string: "https://proxycheck.io/v3/\(ip)")! }
            return URL(string: "https://proxycheck.io/v3/")!
        }
    }

    /// Parses one source's JSON into the display model, deriving
    /// the upstream IP type + flags from the source's type/flag
    /// fields (lib/common/ip_quality.dart _parse). A payload that
    /// states no type is a no-type failure; an inferred type
    /// (residential-by-silence) is an answer flagged as inferred.
    /// Fields a source does not provide stay nil and show "—".
    func parse(_ data: Data, targetIp: String?) -> SourceParseResult {
        switch self {
        case .ipApiCom:
            guard let decoded = try? JSONDecoder().decode(IPQualityInfo.self, from: data),
                  decoded.status == "success" else { return .failure(.failed) }
            let type = Self.pickType(hosting: decoded.hosting == true, mobile: decoded.mobile == true)
            return .answer(
                decoded.assessed(type: type ?? .residential, inferred: type == nil,
                                 isProxy: decoded.proxyFlag == true),
                inferred: type == nil)
        default:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.failed)
            }
            return Self.fromGenericJSON(self, json, targetIp: targetIp)
        }
    }

    /// Upstream _pickType: hosting wins, then mobile, then a
    /// declared type; nil when nothing was stated.
    private static func pickType(hosting: Bool, mobile: Bool = false,
                                 declared: IpQualityType? = nil) -> IpQualityType? {
        if hosting || declared == .hosting { return .hosting }
        if mobile { return .mobile }
        return declared
    }

    /// Upstream _declaredType: a source's declared network type
    /// string mapped to IpQualityType.
    private static func declaredType(_ value: Any?) -> IpQualityType? {
        switch value as? String {
        case "isp": return .residential
        case "business", "education", "government", "banking": return .business
        case "hosting": return .hosting
        default: return nil
        }
    }

    /// A proxycheck-style network type string ("Residential" /
    /// "Business" / "Hosting" / "Wireless").
    private static func networkType(_ value: Any?) -> IpQualityType? {
        switch value as? String {
        case "Residential": return .residential
        case "Business": return .business
        case "Hosting": return .hosting
        case "Wireless": return .mobile
        default: return nil
        }
    }

    /// A flag that may be a JSON bool or a "yes"/"no" string
    /// (proxycheck.io uses both shapes).
    private static func flag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String { return value.lowercased() == "yes" }
        return false
    }

    /// Parses one source's JSON into the display model, deriving
    /// the upstream IP type + flags (lib/common/ip_quality.dart
    /// _fromIdentMe/_fromIpQuery/_fromIpLocate/_fromProxyCheck/
    /// _fromIpApiIs). A source that states no type is a no-type
    /// failure; ip-api.com and ipquery.io read silence about
    /// hosting/mobile as residential, flagged inferred.
    private static func fromGenericJSON(_ source: IPQualitySource, _ json: [String: Any], targetIp: String?) -> SourceParseResult {
        switch source {
        case .identMe:
            // {"ip","type","continent","country","asn","aso","city",
            //  "latitude","longitude","timezone"} — asn may be a
            //  string ("AS13335") or a number.
            guard let ip = text(json["ip"]) else { return .failure(.failed) }
            // An ident.me answer for another IP is a mismatch.
            if let targetIp, ip != targetIp { return .failure(.ipMismatch) }
            guard let type = declaredType(json["type"]) else { return .failure(.noType) }
            return .answer(IPQualityInfo(
                status: "success", message: nil,
                country: text(json["country"]), countryCode: nil,
                city: text(json["city"]), regionName: nil,
                isp: text(json["aso"]), org: text(json["aso"]),
                asn: asnText(json["asn"]), timezone: text(json["timezone"]),
                query: ip, lat: number(json["latitude"]), lon: number(json["longitude"]))
                .assessed(type: type, inferred: false), inferred: false)
        case .ipQuery:
            // {"ip","isp":{"asn","org","isp"},
            //  "location":{"country","country_code","city","state",
            //  "timezone","latitude","longitude"},"risk":{...}}
            guard let ip = text(json["ip"]) else { return .failure(.failed) }
            let isp = object(json["isp"])
            let location = object(json["location"])
            let risk = object(json["risk"])
            let type = pickType(hosting: flag(risk["is_datacenter"]), mobile: flag(risk["is_mobile"]))
            return .answer(IPQualityInfo(
                status: "success", message: nil,
                country: text(location["country"]), countryCode: text(location["country_code"]),
                city: text(location["city"]), regionName: text(location["state"]),
                isp: text(isp["isp"]), org: text(isp["org"]) ?? text(isp["isp"]),
                asn: asnText(isp["asn"]), timezone: text(location["timezone"]),
                query: ip, lat: number(location["latitude"]), lon: number(location["longitude"]))
                .assessed(type: type ?? .residential, inferred: type == nil,
                          isProxy: flag(risk["is_proxy"]), isVpn: flag(risk["is_vpn"]),
                          isTor: flag(risk["is_tor"])),
                inferred: type == nil)
        case .ipLocate:
            // {"ip","country","country_code","city","time_zone",
            //  "latitude","longitude","asn":{"asn","name"},
            //  "company":{"name"},"privacy":{...}}
            guard let ip = text(json["ip"]) else { return .failure(.failed) }
            let asn = object(json["asn"])
            let company = object(json["company"])
            let privacy = object(json["privacy"])
            guard let type = pickType(
                hosting: flag(privacy["is_hosting"]),
                declared: declaredType(company["type"]) ?? declaredType(asn["type"])) else {
                return .failure(.noType)
            }
            return .answer(IPQualityInfo(
                status: "success", message: nil,
                country: text(json["country"]), countryCode: text(json["country_code"]),
                city: text(json["city"]), regionName: nil,
                isp: text(company["name"]) ?? text(asn["name"]), org: text(company["name"]) ?? text(asn["name"]),
                asn: asnText(asn["asn"]), timezone: text(json["time_zone"]),
                query: ip, lat: number(json["latitude"]), lon: number(json["longitude"]))
                .assessed(type: type, inferred: false,
                          isProxy: flag(privacy["is_proxy"]), isVpn: flag(privacy["is_vpn"]),
                          isTor: flag(privacy["is_tor"]), isAbuser: flag(privacy["is_abuser"])),
                inferred: false)
        case .ipApiIs:
            // {"ip","company":{"name"},"asn":{"asn","org"},
            //  "location":{"country","country_code","city","state",
            //  "timezone","latitude","longitude"}}
            guard let ip = text(json["ip"]) else { return .failure(.failed) }
            let company = object(json["company"])
            let asn = object(json["asn"])
            let location = object(json["location"])
            guard let type = pickType(
                hosting: flag(json["is_datacenter"]), mobile: flag(json["is_mobile"]),
                declared: declaredType(company["type"]) ?? declaredType(asn["type"])) else {
                return .failure(.noType)
            }
            return .answer(IPQualityInfo(
                status: "success", message: nil,
                country: text(location["country"]), countryCode: text(location["country_code"]),
                city: text(location["city"]), regionName: text(location["state"]),
                isp: text(company["name"]) ?? text(asn["org"]), org: text(company["name"]) ?? text(asn["org"]),
                asn: asnText(asn["asn"]), timezone: text(location["timezone"]),
                query: ip, lat: number(location["latitude"]), lon: number(location["longitude"]))
                .assessed(type: type, inferred: false,
                          isProxy: flag(json["is_proxy"]), isVpn: flag(json["is_vpn"]),
                          isTor: flag(json["is_tor"]), isAbuser: flag(json["is_abuser"])),
                inferred: false)
        case .proxyCheck:
            // {"status":"ok","<ip>":{"asn","provider","organisation",
            //  "country","isocode","city","latitude","longitude",
            //  "timezone",...}} — the result is keyed by the IP.
            // A `denied` status is rate-limiting (upstream).
            if text(json["status"]) == "denied" { return .failure(.rateLimited) }
            guard text(json["status"]) == "ok" || text(json["status"]) == "warning" else {
                return .failure(.failed)
            }
            // With a target IP the result is that key; otherwise
            // find the entry (and its key, the IP) in one pass.
            let found: (String, [String: Any])?
            if let targetIp, let dict = json[targetIp] as? [String: Any] {
                found = (targetIp, dict)
            } else {
                found = json.compactMap({ pair -> (String, [String: Any])? in
                    guard let dict = pair.value as? [String: Any],
                          dict["asn"] != nil || dict["provider"] != nil else { return nil }
                    return (pair.key, dict)
                }).first
            }
            guard let (ip, entry) = found else { return .failure(.noType) }
            // Type/flags live in nested network/detections when
            // present, else in the flat per-IP fields.
            let network = object(entry["network"])
            let detections = object(entry["detections"])
            let netType = networkType(network["type"]) ?? networkType(entry["type"])
            guard let type = pickType(
                hosting: flag(detections["hosting"]) || netType == .hosting || flag(entry["hosting"]),
                mobile: netType == .mobile,
                declared: netType) else {
                return .failure(.noType)
            }
            return .answer(IPQualityInfo(
                status: "success", message: nil,
                country: text(entry["country"]), countryCode: text(entry["isocode"]),
                city: text(entry["city"]), regionName: nil,
                isp: text(entry["provider"]) ?? text(network["organisation"]),
                org: text(entry["organisation"]) ?? text(entry["provider"]) ?? text(network["organisation"]),
                asn: asnText(entry["asn"]) ?? asnText(network["asn"]),
                timezone: text(entry["timezone"]),
                query: ip, lat: number(entry["latitude"]), lon: number(entry["longitude"]))
                .assessed(type: type, inferred: false,
                          isProxy: flag(detections["proxy"]) || flag(entry["proxy"]),
                          isVpn: flag(detections["vpn"]) || flag(entry["vpn"]),
                          isTor: flag(detections["tor"]) || flag(entry["tor"])),
                inferred: false)
        case .ipApiCom:
            return .failure(.failed)
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
