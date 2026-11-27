import SwiftUI

// MARK: - IP quality sheet (FlClash: lib/features/ip_quality/ip_quality_sheet.dart)
// Upstream's per-IP sheet: opened for one specific IP (showIpQualitySheet),
// titled 出站 IP, with a refresh action, the detection tip, 基本信息
// (IP + 等级/类型/命中标记）, 网络 （组织/ASN/采用来源）, 各来源 on total
// failure, and 其他 (hide IP). No geography, no VPN-vs-direct header,
// no query latency, no cache age, no explanatory footer, no ad-hoc
// IP field — the sheet answers one question about one IP.
//
// Lookup (lib/common/ip_quality.dart + lib/providers/ip_quality.dart):
// several sources in waves — the tightest-quota sources last,
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
// in one shape, so it is the primary display source — the others
// fill what they have and show "—" for the rest.
//
// URLSession follows the system's default route, so when the VPN is
// on the answer IS the proxy egress IP, and when it is off it is the
// phone's direct IP.
//
// The cache is keyed by the resolved IP and whether the VPN was on
// (the egress IP changes when the VPN toggles). Automatic fetches
// use the cache and respect the 5-minute failure cooldown; the
// 刷新 button always goes to the network.

struct IPQualityInfo: Codable {
    /// v0.2.121: optional — the phone received an HTTP 200 body
    /// with no `status` key (not a genuine ip-api.com answer), and
    /// the single required field made the whole decode throw, so
    /// the enrichment failed and the chips/org skeletoned forever.
    /// With every field optional-or-defaulted, any body decodes
    /// and the status guard below decides success/failure.
    let status: String?
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

    /// v0.2.122: explicit lenient decoding — the synthesized init
    /// throws keyNotFound for the defaulted `var` flags (isProxy
    /// et al.) when the body carries no such keys, so a genuine
    /// ip-api.com success answer (which returns `proxy`/`hosting`,
    /// never `isProxy`/`isVpn`/`isTor`/`isAbuser`) failed to
    /// decode on-device (keyNotFound "isProxy", 00:06:51 +
    /// 00:11:29). Every field is decodeIfPresent; the flags
    /// default to false. This fixes every IPQualityInfo decode
    /// site (Dashboard enrichment, the IPQuality page parser,
    /// the cache) at once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        regionName = try container.decodeIfPresent(String.self, forKey: .regionName)
        isp = try container.decodeIfPresent(String.self, forKey: .isp)
        org = try container.decodeIfPresent(String.self, forKey: .org)
        asn = try container.decodeIfPresent(String.self, forKey: .asn)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        mobile = try container.decodeIfPresent(Bool.self, forKey: .mobile)
        proxyFlag = try container.decodeIfPresent(Bool.self, forKey: .proxyFlag)
        hosting = try container.decodeIfPresent(Bool.self, forKey: .hosting)
        qualityType = try container.decodeIfPresent(IpQualityType.self, forKey: .qualityType)
        isProxy = try container.decodeIfPresent(Bool.self, forKey: .isProxy) ?? false
        isVpn = try container.decodeIfPresent(Bool.self, forKey: .isVpn) ?? false
        isTor = try container.decodeIfPresent(Bool.self, forKey: .isTor) ?? false
        isAbuser = try container.decodeIfPresent(Bool.self, forKey: .isAbuser) ?? false
        typeInferred = try container.decodeIfPresent(Bool.self, forKey: .typeInferred) ?? false
    }

    /// v0.2.121: `status` is optional here too — the property is
    /// `String?` (a body with no `status` key must still decode),
    /// and `assessed(...)` passes the property straight through.
    init(status: String?, message: String?, country: String?, countryCode: String?,
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

/// The IP this sheet was opened for (upstream showIpQualitySheet is
/// always opened for one IP); nil checks the caller's current egress IP.
struct IpQualitySheetTarget: Identifiable {
    let ip: String
    var id: String { ip }
}

struct IPQualityView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// A specific IP to check (upstream showIpQualitySheet is always
    /// opened for one IP); nil checks the caller's current egress IP.
    @State private var explicitIp: String?
    @State private var failures: [IPQualityFailure] = []

    init(ip: String? = nil) {
        let cleaned = ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        _explicitIp = State(initialValue: cleaned?.isEmpty == true ? nil : cleaned)
    }

    @State private var info: IPQualityInfo?
    @State private var sourceName: String?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var isViaVPN: Bool { tunnelManager.isRunning }

    /// Total failure: no answer and not loading (upstream
    /// `_IpQualityDetail.failed`: quality == null && !isLoading).
    private var failed: Bool { info == nil && !isLoading }

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
        NavigationStack {
            List {
                // Detection tip (upstream ip_quality_sheet: the tip
                // sits at the top of the sheet, above the sections;
                // l10n_zh detectionTip, verbatim).
                Section {
                    Text("依赖第三方api，仅供参考")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                // 基本信息 (upstream _IpQualityDetail): the IP row,
                // then the quality rows — or the failed type row on
                // total failure, skeletons while loading.
                Section("基本信息") {
                    LabeledContent("IP 地址", value: settingsStore.hideIp ? "*****" : (explicitIp ?? info?.query ?? "—"))
                    if failed {
                        LabeledContent("类型", value: "类型查询失败")
                            .foregroundStyle(.red)
                    } else if let info {
                        qualityRows(info)
                    } else {
                        skeletonRow("等级", width: 40)
                        skeletonRow("类型", width: 64)
                        skeletonRow("命中标记", width: 40)
                    }
                }

                // The failure-cooldown message has no other surface:
                // on total failure the 各来源 section below says
                // why (per source), so this shows only when there
                // are no per-source failures to list.
                if let errorMessage, failures.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                // 网络 (upstream _networkRows): organisation, ASN,
                // source — skeletons while loading; omitted entirely
                // on total failure, like upstream.
                if !failed {
                    Section("网络") {
                        if let info {
                            LabeledContent("组织", value: info.org ?? "—")
                            LabeledContent("ASN", value: info.asn ?? "—")
                            LabeledContent("采用来源", value: sourceName ?? "—")
                        } else {
                            skeletonRow("组织", width: 120)
                            skeletonRow("ASN", width: 56)
                            skeletonRow("采用来源", width: 72)
                        }
                    }
                }

                // Per-source failure breakdown (upstream
                // ip_quality_sheet: on total failure every source is
                // listed with its status).
                if failed, !failures.isEmpty {
                    Section("各来源") {
                        ForEach(failures) { failure in
                            LabeledContent(failure.source, value: failure.status.rawValue)
                        }
                    }
                }

                // 其他 (upstream: the sheet ends with the hide-IP
                // switch row).
                Section("其他") {
                    Toggle("隐藏 IP", isOn: $settingsStore.hideIp)
                        .onChange(of: settingsStore.hideIp) { _, _ in settingsStore.save() }
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("出站 IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Refresh (upstream _IpQualitySheet: the app-bar
                    // refresh action, with a loading state).
                    if isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await fetch(forceRefresh: true) }
                        } label: {
                            Label("重新查询", systemImage: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await fetch() }
        }
    }

    /// The sheet's actual point (upstream _qualityRows): IP type,
    /// quality level and Tor/abuser/VPN/proxy flags — derived from
    /// the answering source's type/flag fields, not from geography.
    /// Flags render as chips (upstream MetaChip) or 无.
    @ViewBuilder
    private func qualityRows(_ info: IPQualityInfo) -> some View {
        if info.qualityType == nil {
            LabeledContent("类型", value: "类型查询失败")
                .foregroundStyle(.red)
        } else {
            if let level = info.qualityLevel {
                LabeledContent("等级", value: level.label)
                    .foregroundStyle(level.color)
            }
            LabeledContent("类型", value: info.qualityType!.label)
            let flags = [
                info.isTor ? "Tor" : nil,
                info.isAbuser ? "滥用记录" : nil,
                info.isVpn ? "VPN" : nil,
                info.isProxy ? "代理" : nil,
            ].compactMap { $0 }
            if flags.isEmpty {
                LabeledContent("命中标记", value: "无")
            } else {
                LabeledContent("命中标记") {
                    HStack(spacing: 6) {
                        ForEach(flags, id: \.self) { flag in
                            Text(flag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
        }
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
        let result = await Self.lookupWaves(targetIp: targetIp)
        failures = result.failures
        if let (answer, source) = result.answer {
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
    ///
    /// Static so the Dashboard's status card can run the same
    /// fan-out for its IP enrichment (D-60): `sessions` defaults
    /// to the sheet's own direct session; the dashboard passes
    /// [proxy, direct] so each source is tried through the tunnel
    /// first and directly second, like its old ip-api.com code.
    static func lookupWaves(targetIp: String?, sessions: [URLSession]? = nil) async -> (answer: (IPQualityInfo, String)?, failures: [IPQualityFailure]) {
        let sessions = sessions ?? [timedSession]
        var launchedWave = 0
        var inFlight = 0
        var fallback: (IPQualityInfo, String)?
        var failures: [IPQualityFailure] = []
        let answer = await withTaskGroup(of: WaveOutcome.self, returning: (IPQualityInfo, String)?.self) { group in
            func addWave(_ index: Int) {
                launchedWave = index
                for source in Self.waves[index] {
                    inFlight += 1
                    group.addTask { await Self.query(source: source, targetIp: targetIp, sessions: sessions) }
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

    /// One source, 8 s per attempt. Tries each session in order
    /// (the dashboard passes [proxy, direct]); a 429 is
    /// rate-limited on the first session that answers it and is
    /// not retried on the next one — the quota is per source, not
    /// per egress. Success needs a resolved IP and a stated (or
    /// inferred) type; a proxycheck `denied` is rate-limited, an
    /// ident.me answer for another IP is an IP mismatch, and a
    /// parse with no type is a no-type failure (upstream
    /// _query/_statusOf). The timeout is set on the request so
    /// every session — including URLSession.shared, whose own
    /// timeout is 60 s — is bounded at 8 s.
    private static func query(source: IPQualitySource, targetIp: String?, sessions: [URLSession]? = nil) async -> WaveOutcome {
        guard let url = source.url(for: targetIp) else {
            return .failed(source.label, .failed)
        }
        let request = URLRequest(url: url, timeoutInterval: 8)
        var sawTimeout = false
        for session in sessions ?? [timedSession] {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    continue
                }
                if http.statusCode == 429 {
                    return .failed(source.label, .rateLimited)
                }
                guard http.statusCode == 200 else {
                    continue
                }
                switch source.parse(data, targetIp: targetIp) {
                case .answer(let info, let inferred):
                    return .answer(info, source.label, inferred)
                case .failure(let status):
                    return .failed(source.label, status)
                }
            } catch {
                if (error as NSError).code == NSURLErrorTimedOut {
                    // A slow proxy path still gets the direct
                    // attempt; the timeout is only reported if
                    // every session timed out.
                    sawTimeout = true
                    continue
                }
                continue
            }
        }
        return .failed(source.label, sawTimeout ? .timeout : .failed)
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
    /// about. The IP comes from a free-text field, so it is
    /// percent-encoded (a mistyped IP with a space used to crash
    /// here: URL(string:) returns nil and the old code force-
    /// unwrapped it) and a still-unbuildable URL returns nil,
    /// which the caller reports as a per-source failure.
    func url(for ip: String?) -> URL? {
        let encoded: String?
        if let ip {
            // Only the characters a literal IPv4/IPv6 address may
            // contain pass through unescaped; anything else (space,
            // `/`, `?`, `#`, `&`) is encoded so it cannot rewrite
            // the request path or query.
            guard let e = ip.addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-:")) else { return nil }
            encoded = e
        } else {
            encoded = nil
        }
        switch self {
        case .identMe: return URL(string: "https://ident.me/json")
        // ip-api.com serves HTTPS only on its paid plan.
        case .ipApiCom:
            if let ip = encoded {
                return URL(string: "http://ip-api.com/json/\(ip)?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting")
            }
            return URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon,mobile,proxy,hosting")
        case .ipQuery:
            if let ip = encoded { return URL(string: "https://api.ipquery.io/\(ip)?format=json") }
            return URL(string: "https://api.ipquery.io/?format=json")
        case .ipLocate:
            if let ip = encoded { return URL(string: "https://iplocate.io/api/lookup/\(ip)") }
            return URL(string: "https://iplocate.io/api/lookup/")
        case .ipApiIs:
            if let ip = encoded { return URL(string: "https://api.ipapi.is/?q=\(ip)") }
            return URL(string: "https://api.ipapi.is/")
        case .proxyCheck:
            if let ip = encoded { return URL(string: "https://proxycheck.io/v3/\(ip)") }
            return URL(string: "https://proxycheck.io/v3/")
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
