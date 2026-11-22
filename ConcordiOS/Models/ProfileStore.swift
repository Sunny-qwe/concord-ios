import Foundation
import Combine

// MARK: - Profile store (FlClash: Profiles page)
// A profile is a Clash/mihomo YAML subscription (remote URL) or a local
// file. Applying a profile = writing its YAML to the App Group shared
// config and calling Concord config.apply + profile.inspect.
// FlClash also supports "extend" / custom profiles; those are represented
// here as local files with a note, not as a separate editor.
//
// Switching really takes effect:
//   - The profile YAML is copied to the shared config.yaml, which the
//     PacketTunnel extension reads at startTunnel and applies at boot —
//     so switching works even while the VPN is stopped, and takes
//     effect at the next VPN start.
//   - While the VPN is running, the switch is also applied live via
//     config.apply + profile.inspect, and validated first with
//     config.validate (a parse error aborts the switch before anything
//     is copied). Updating the active profile re-applies it the same way.
// Profile paths sent to the core are absolute (see ConfigStore).

/// Subscription traffic + expiry, parsed from the provider's
/// `subscription-userinfo` response header (FlClash
/// models/profile.dart `SubscriptionInfo`: upload / download /
/// total are bytes, expire is a unix timestamp in seconds, 0 =
/// absent). Stored on the Profile so the card and the dashboard
/// can show it offline — the core's provider info needs the
/// tunnel running and matches by name, which breaks on rename.
struct SubscriptionInfo: Codable, Equatable {
    var upload: Int64
    var download: Int64
    var total: Int64
    var expire: Int64

    init(upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0, expire: Int64 = 0) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    var usedBytes: Int64 { upload + download }

    var usageFraction: Double? {
        total > 0 ? min(1.0, Double(usedBytes) / Double(total)) : nil
    }

    var expireDate: Date? {
        expire > 0 ? Date(timeIntervalSince1970: TimeInterval(expire)) : nil
    }

    /// "1.2 GB / 10 GB" — bare numbers only (MuYu profile card,
    /// v0.2.68): no "已用"/"共" prefixes. The Dashboard card builds
    /// its own bare "X / Y" line (DashboardView trafficText), so
    /// this helper is only used by the Profiles card.
    var usageLine: String? {
        guard total > 0 else { return usedBytes > 0 ? Self.byteCount(usedBytes) : nil }
        return "\(Self.byteCount(usedBytes)) / \(Self.byteCount(total))"
    }

    /// Expiry as a plain date pill ("2026-12-03", MuYu profile
    /// card, v0.2.68); nil when the provider sent no expiry.
    /// The old "剩余 N 天" text (expiryLine below) is kept for
    /// callers that still need the countdown.
    var expiryDateString: String? {
        guard let date = expireDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// ("剩余 12 天", warning) — warning when ≤ 7 days left or
    /// already expired; nil when the provider sent no expiry.
    func expiryLine(now: Date = Date()) -> (text: String, warning: Bool)? {
        guard let date = expireDate else { return nil }
        let days = Int(ceil(date.timeIntervalSince(now) / 86400))
        if days < 0 { return ("已过期", true) }
        if days == 0 { return ("今天到期", true) }
        return ("剩余 \(days) 天", days <= 7)
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Parses `upload=..; download=..; total=..; expire=..`
    /// (FlClash `SubscriptionInfo.formHString`). Returns nil when
    /// the header is absent or carries none of the four keys.
    static func parse(header: String?) -> SubscriptionInfo? {
        guard let header, !header.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var map: [String: Int64] = [:]
        for field in header.split(separator: ";") {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = field[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let value = Int64(raw) {
                map[key] = value
            } else if let decimal = Double(raw), decimal.isFinite {
                map[key] = Int64(decimal)
            }
        }
        guard !map.isEmpty else { return nil }
        return SubscriptionInfo(
            upload: map["upload"] ?? 0,
            download: map["download"] ?? 0,
            total: map["total"] ?? 0,
            expire: map["expire"] ?? 0
        )
    }
}

enum ProfileKind: String, Codable, CaseIterable {
    case url = "订阅链接"
    case file = "本地文件"
}

struct Profile: Identifiable, Codable {
    let id: UUID
    var name: String
    var kind: ProfileKind
    var urlString: String?
    var fileName: String?
    var updatedAt: Date?
    var isActive: Bool
    var note: String?
    /// age private key for age-encrypted subscription files
    /// (FlClash edit page; stored per profile, never logged).
    var ageSecretKey: String?
    /// Auto-update switch + interval in minutes (FlClash edit page).
    /// Wired by updateDueProfiles(): a profile is due when the
    /// global auto-update switch is on, its own switch is on, and
    /// lastUpdateDate + interval has passed. The 20-minute timer
    /// that calls updateDueProfiles lives outside this store.
    var autoUpdate: Bool
    var autoUpdateIntervalMinutes: Int?
    /// Traffic + expiry from the last download's
    /// `subscription-userinfo` header (FlClash SubscriptionInfo).
    /// Nil when the provider sends no such header; persisted in
    /// profiles.v1 so cards show it offline. DashboardView reads
    /// this same field (integration pass) instead of matching
    /// providers by name.
    var subscriptionInfo: SubscriptionInfo?

    init(id: UUID = UUID(), name: String, kind: ProfileKind, urlString: String? = nil, fileName: String? = nil, updatedAt: Date? = nil, isActive: Bool = false, note: String? = nil, ageSecretKey: String? = nil, autoUpdate: Bool = false, autoUpdateIntervalMinutes: Int? = nil, subscriptionInfo: SubscriptionInfo? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.urlString = urlString
        self.fileName = fileName
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.note = note
        self.ageSecretKey = ageSecretKey
        self.autoUpdate = autoUpdate
        self.autoUpdateIntervalMinutes = autoUpdateIntervalMinutes
        self.subscriptionInfo = subscriptionInfo
    }
}

// MARK: - Rule-set repair plan (v0.2.46 ITEM 1)
//
// A repair plan for one missing rule-set (see the engine in
// ProfileStore, "Rule-set repair"). `newText` is nil exactly
// when the plan is unrepairable — nothing can be written from
// such a plan; the sheet only shows its reason.

/// One missing rule-set's repair plan. Identifiable so the
/// Proxies page can present it with `.sheet(item:)`.
struct RuleSetRepairPlan: Identifiable {
    enum Kind: Equatable {
        /// Inferred from `templateProvider`; `siblingCount` is
        /// how many siblings share the winning template (the
        /// template sibling included).
        case complete(templateProvider: String, siblingCount: Int)
        /// `ruleCount` RULE-SET lines will be removed.
        case delete(ruleCount: Int)
        case unrepairable
    }

    let id = UUID()
    let missingName: String
    let kind: Kind
    /// Exact lines to add (complete) or remove (delete); empty
    /// when unrepairable. Shown verbatim in the confirmation.
    let previewLines: [String]
    /// Full new file text; nil when unrepairable.
    let newText: String?
    /// One-line explanation shown above the preview.
    let summary: String

    var isRepairable: Bool { newText != nil }

    var previewTitle: String {
        switch kind {
        case .complete:
            return "将追加到当前订阅的 rule-providers："
        case .delete:
            return "将从当前订阅的 rules 里删除："
        case .unrepairable:
            return ""
        }
    }

    var confirmTitle: String {
        switch kind {
        case .complete: return "补全并重新应用"
        case .delete: return "删除规则并重新应用"
        case .unrepairable: return ""
        }
    }

    /// Banner line after a successful repair + re-test.
    var successMessage: String {
        switch kind {
        case .complete(let template, let count):
            return "已补全规则集「\(missingName)」的定义（参照「\(template)」等 \(count) 个同类提供方），配置已重新应用，测速已恢复。"
        case .delete(let count):
            return "已删除引用规则集「\(missingName)」的 \(count) 条规则，配置已重新应用，测速已恢复。"
        case .unrepairable:
            return ""
        }
    }
}

/// One missing rule set inside a repair-all plan: what the
/// text scan found missing, what will be done about it, and the
/// exact lines.
struct RuleSetRepairItem: Identifiable {
    let id = UUID()
    let missingName: String
    let kind: RuleSetRepairPlan.Kind
    let previewLines: [String]

    var actionTitle: String {
        switch kind {
        case .complete: return "补全定义"
        case .delete: return "删除引用规则"
        case .unrepairable: return "无法处理"
        }
    }

    var previewTitle: String {
        switch kind {
        case .complete: return "将追加到当前订阅的 rule-providers："
        case .delete: return "将从当前订阅的 rules 里删除："
        case .unrepairable: return ""
        }
    }
}

/// The repair-ALL plan (v0.2.49, detector rewritten v0.2.58):
/// every missing rule set, collected in one pass by TEXT (see
/// collectMissingRuleSets — the core's config.validate only
/// parses YAML and never reports a missing set), each with its
/// own action — so one confirmation fixes the whole config
/// instead of the old one-at-a-time whack-a-mole (fix TikTok →
/// the next error is Disney → the sheet pops again). `newText`
/// is the full repaired file; `blockingIssue` names a non-rule-set
/// problem found while collecting (e.g. another parse error),
/// if any. `completedCount` / `deletedCount` summarise the
/// actions for the sheet.
struct RuleSetRepairAllPlan: Identifiable {
    let id = UUID()
    let profileName: String
    let items: [RuleSetRepairItem]
    let newText: String?
    let summary: String
    let blockingIssue: String?
    /// True when the combined text had to fall back to
    /// delete-everything (a completion did not validate).
    let fellBackToDeleteAll: Bool

    var isRepairable: Bool { newText != nil && !items.isEmpty && items.contains(where: { $0.kind != .unrepairable }) }
    var confirmTitle: String { "全部修复并重新应用" }
    var completedCount: Int { items.filter { if case .complete = $0.kind { return true }; return false }.count }
    var deletedCount: Int { items.filter { if case .delete = $0.kind { return true }; return false }.count }
    var unrepairableCount: Int { items.filter { if case .unrepairable = $0.kind { return true }; return false }.count }

    var successMessage: String {
        var bits: [String] = []
        if completedCount > 0 { bits.append("补全了 \(completedCount) 个规则集的定义") }
        if deletedCount > 0 { bits.append("删除了 \(deletedCount) 个规则集的引用规则") }
        let done = bits.joined(separator: "，")
        return done.isEmpty
            ? "配置已重新应用。"
            : "已\(done)，配置已重新应用，测速已恢复。"
    }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var statusMessage = "尚未导入订阅"
    @Published var lastError: String?
    @Published var inspect: ConcordProfileInspect?
    @Published var applyWarnings: [ConcordWarning] = []
    @Published var validationIssues: [ConcordIssue] = []
    /// Decrypted text of the last config.decrypt call (never persisted;
    /// the key is never stored either). Saved as a new profile only
    /// through saveDecryptedAsProfile, an explicit user action.
    @Published var decryptResult: String?
    @Published var decryptMessage: String?
    /// Outbounds of the last profile.outbounds call.
    @Published var outbounds: ConcordProfileOutbounds?
    @Published var outboundsMessage: String?
    @Published var clearEffectMessage: String?
    /// Share links of the last convert.encodeLinks call.
    @Published var encodedLinks: [String] = []
    @Published var encodeMessage: String?
    /// Decoded proxies of the last convert.decodeLinks call: one
    /// entry per input line, empty when the line is not a link.
    @Published var decodedResults: [[JSONValue]] = []
    /// All decoded proxies flattened (for the save-as-profile action).
    @Published var decodedProxies: [JSONValue] = []
    @Published var decodeMessage: String?

    let client: ConcordClient
    /// Called after applyProfile writes the new shared config.yaml
    /// (before the live apply). The app wires it to
    /// MitmModuleStore.refreshMergedFileOnly, so module-mitm.json
    /// (profileDigest + merged profile providers) is recomputed
    /// against the NEW profile instead of staying stale — otherwise
    /// the extension falls back to module-only providers after a
    /// profile switch and the profile's own RULE-SET rules lose
    /// their providers. Same callback pattern as
    /// MitmModuleStore.onModulesChanged.
    var onProfileApplied: (() async -> Void)?
    private let storageKey = "ConcordiOS.profiles.v1"
    private var cancellables = Set<AnyCancellable>()

    /// The session used for subscription downloads. When 校验证书 is
    /// on (default) this is the shared session; when the user turns it
    /// off, a session whose delegate trusts any server certificate
    /// (FlClash: 常规 -> 校验订阅证书）. Synced from SettingsStore by
    /// ContentView on launch and by the 常规 page when toggled.
    var checkCertificate: Bool = true
    /// Close all live connections after a profile switch (FlClash:
    /// 常规 -> 自动关闭连接）. Synced from SettingsStore the same way.
    var autoCloseConnections: Bool = false

    private lazy var insecureSession: URLSession = {
        URLSession(configuration: Self.subscriptionSessionConfiguration, delegate: InsecureCertificateDelegate(), delegateQueue: nil)
    }()

    private lazy var secureSubscriptionSession: URLSession = {
        URLSession(configuration: Self.subscriptionSessionConfiguration)
    }()

    /// Subscription downloads (FlClash request.dart: 20 s timeout,
    /// `clash-verge/... Clash.Meta` User-Agent — many providers
    /// refuse requests with no UA or with a bare URLSession UA).
    /// The shared session's defaults (60 s request / 7 day
    /// resource, no UA) let a trickling connection stall a launch
    /// auto-update for hours and 404/403 HTML pages through.
    private static var subscriptionSessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": "clash-verge/v2.4.2 ClashforWindows/0.20.39 Clash.Meta"]
        return config
    }

    /// Global auto-update switch (SettingsStore.autoUpdateProfiles),
    /// synced from SettingsStore by ContentView the same way
    /// checkCertificate / autoCloseConnections are. updateDueProfiles
    /// refuses to update anything while this is off.
    var globalAutoUpdateEnabled: Bool = true

    private var subscriptionSession: URLSession {
        checkCertificate ? secureSubscriptionSession : insecureSession
    }

    /// Downloads one subscription: 20 s timeout, User-Agent set,
    /// HTTP status checked (a non-2xx is an honest error — an HTML
    /// error page must never reach the YAML parser), and the
    /// `subscription-userinfo` header + `content-disposition`
    /// filename parsed (FlClash profile.update).
    private func downloadSubscription(from url: URL) async throws -> (data: Data, info: SubscriptionInfo?, fileName: String?) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("clash-verge/v2.4.2 ClashforWindows/0.20.39 Clash.Meta", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await subscriptionSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "订阅服务器没有返回 HTTP 响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ConcordiOS", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "订阅服务器返回 HTTP \(http.statusCode)（\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))），没有拿到配置"])
        }
        // HTML guard (FIX 3b): some links answer HTTP 200 with a web
        // page instead of subscription content — a Cloudflare
        // "Just a moment..." challenge, a Telegram web page, or an
        // error page. That HTML must never be saved as a profile:
        // fail here with a precise message instead of a generic
        // parse failure downstream (normalizedSubscriptionData
        // would only reject it as "订阅内容无法识别"). Same
        // sniffing as the module downloads (audit B40:
        // mitmDataLooksLikeHTML — BOM / leading whitespace
        // tolerated, case-insensitive `<!doctype` / `<html`).
        // downloadSubscription is the single download funnel for
        // both import (addFromURL) and update, so both benefit.
        if mitmDataLooksLikeHTML(data) {
            throw NSError(domain: "ConcordiOS", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "下载到的是一张网页（可能是验证 / 人机验证页面），不是订阅内容：请在浏览器里打开链接完成验证，或确认该链接是订阅链接后再试"])
        }
        let info = SubscriptionInfo.parse(header: http.value(forHTTPHeaderField: "subscription-userinfo"))
        return (data, info, Self.dispositionFileName(http.value(forHTTPHeaderField: "content-disposition")))
    }

    /// `attachment; filename="sub.yaml"` → `sub.yaml`
    /// (FlClash getFileNameForDisposition). Nil when absent.
    private static func dispositionFileName(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("filename=") else { continue }
            var value = String(trimmed.dropFirst("filename=".count))
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("UTF-8''") { value = String(value.dropFirst("UTF-8''".count)) }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            let decoded = value.removingPercentEncoding ?? value
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }

    // MARK: - age-encrypted subscriptions (FlClash validateProfile)

    /// An age-encrypted file starts with the `age-encryption.org/v1`
    /// header line. FlClash decrypts it with the profile's
    /// ageSecretKey (core config.decrypt) and rewrites the plaintext
    /// in place before validating. config.decrypt takes
    /// `{profile: {path}, key, output: {inline: true}}`
    /// (165154c schema ConfigDecryptParams — config.validate takes
    /// only `{profile}`, no key) and runs in the extension core, so
    /// it needs live mode + a running tunnel. The sample mock
    /// returns fixed sample text, so sample mode must never
    /// decrypt. Returns `.success(data)` unchanged when the data
    /// is not age-encrypted, `.success(plaintext)` after a
    /// decrypt, or `.failure(reason)` with the honest reason the
    /// download / save cannot proceed.
    /// Error wrapper so the age-decrypt helper can return a plain
    /// message in a `Result`: `String` itself does not conform to
    /// `Error`, so `Result<Data, String>` does not compile.
    private struct AgeDecryptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func decryptAgeDataIfNeeded(_ data: Data, key: String?) async -> Result<Data, AgeDecryptError> {
        guard Self.looksAgeEncrypted(data) else { return .success(data) }
        guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(AgeDecryptError(message: "该订阅是 age 加密的，但没有填写 age 私钥：请在编辑页填写后再更新"))
        }
        guard client.mode == .live, TunnelManager.shared.isRunning else {
            return .failure(AgeDecryptError(message: "该订阅是 age 加密的，需先启动 VPN 才能解密（解密由扩展内的核心执行）"))
        }
        guard let dir = profilesDirectory else {
            return .failure(AgeDecryptError(message: "App Group 容器不可用，无法解密 age 订阅"))
        }
        let tempURL = dir.appendingPathComponent(".age-decrypt.yaml")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)
            let plain = try await client.configDecrypt(profilePath: tempURL.path, key: key)
            guard !plain.isEmpty else {
                return .failure(AgeDecryptError(message: "age 解密结果为空：请检查私钥是否正确"))
            }
            return .success(Data(plain.utf8))
        } catch {
            return .failure(AgeDecryptError(message: "age 解密失败：\(error.localizedDescription)"))
        }
    }

    private static func looksAgeEncrypted(_ data: Data) -> Bool {
        let head = data.prefix(64)
        guard let text = String(data: head, encoding: .ascii) else { return false }
        return text.contains("age-encryption.org/v1")
    }

    var activeProfile: Profile? {
        profiles.first { $0.isActive }
    }

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
        // The sample profile is sample-mode data: seed it only while
        // the client is in .sample mode, never in .live mode.
        seedSampleIfNeeded()
        // Switching to .sample later seeds it too (only when the list
        // is empty, so real profiles are never disturbed).
        client.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                if mode == .sample { self?.seedSampleIfNeeded() }
            }
            .store(in: &cancellables)
    }

    /// Appends the labelled sample profile when the list is empty and
    /// the client is in .sample mode. Never touches a non-empty list.
    func seedSampleIfNeeded() {
        guard client.mode == .sample, profiles.isEmpty else { return }
        profiles = [
            Profile(name: "示例订阅", kind: .url, urlString: "https://example.com/subscribe.yaml", updatedAt: Date().addingTimeInterval(-3600), isActive: true)
        ]
        save()
    }

    // MARK: Persistence (metadata only; YAML lives in the App Group)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private var profilesDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
            .appendingPathComponent("profiles")
    }

    private func fileURL(for profile: Profile) -> URL? {
        profilesDirectory?.appendingPathComponent("\(profile.id.uuidString).yaml")
    }

    /// Absolute path of a profile's YAML file, for the core's
    /// profile-ref calls (config.validate / config.apply / ...).
    /// The absolute path of a profile's file, for pages that hand a
    /// path to the core (e.g. the 配置预检 page's profile.build).
    func absolutePathForPreflight(_ profile: Profile) -> String? {
        absolutePath(for: profile)
    }

    private func absolutePath(for profile: Profile) -> String? {
        fileURL(for: profile)?.path
    }

    /// A config file is only worth applying when it looks like a Clash /
    /// mihomo document at all. The core re-validates at apply time; this
    /// local check catches empty / truncated / wrong files before they
    /// are copied over the active config.
    private static func localSanityCheck(_ data: Data) -> String? {
        guard !data.isEmpty else { return "配置文件为空" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "配置文件不是 UTF-8 文本"
        }
        let keys = ["proxies:", "proxy-groups:", "rules:", "proxy-providers:", "rule-providers:"]
        guard keys.contains(where: { text.contains($0) }) else {
            return "配置文件里没有 proxies / proxy-groups / rules 等配置项，可能不是 Clash / mihomo 配置"
        }
        return nil
    }

    /// A subscription download is not always a Clash YAML file: many
    /// providers return a base64 blob (or plain lines) of node share
    /// links instead — e.g. the user's own subscription returns
    /// base64 of REMARKS/STATUS headers + vless:// links. The old
    /// code rejected those at localSanityCheck ("配置文件里没有
    /// proxies …"), so a link subscription could never be imported:
    /// the download succeeded and the import still failed. Normalise
    /// before saving: real YAML passes through untouched; a link
    /// subscription is decoded, its links parsed (locally, core
    /// fallback when reachable) and rebuilt into a ready-to-use
    /// Clash config with DefaultConfig — exactly like a pasted node
    /// link import. Returns the data to save plus a short note
    /// ("识别到 N 个节点") when a conversion happened.
    @MainActor
    private func normalizedSubscriptionData(_ data: Data) async -> Result<(data: Data, note: String?), NodeLinkError> {
        if Self.localSanityCheck(data) == nil {
            return .success((data, nil))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(NodeLinkError(message: "订阅内容不是 UTF-8 文本"))
        }
        // Candidate bodies: the raw text, plus a base64-decoded whole
        // body when it decodes to readable text (standard or URL-safe
        // alphabet, with or without padding, line-wrapped or not).
        var candidates: [String] = [text]
        if let decoded = Self.looseBase64Decode(text),
           let decodedText = String(data: decoded, encoding: .utf8),
           decodedText != text {
            candidates.insert(decodedText, at: 0)
        }
        for candidate in candidates {
            if Self.localSanityCheck(Data(candidate.utf8)) == nil {
                return .success((Data(candidate.utf8), nil))
            }
            let linkLines = Self.nonEmptyLines(candidate)
                .filter { UnifiedImporter.kind(of: $0) == .nodeLink }
            guard !linkLines.isEmpty else { continue }
            var proxies: [JSONValue] = []
            var failedCount = 0
            var warnings: [String] = []
            for line in linkLines {
                switch NodeLinkParser.parse(line) {
                case .success(let node):
                    proxies.append(node.jsonValue)
                    warnings.append(contentsOf: node.warnings)
                case .failure: failedCount += 1
                }
            }
            // Core fallback for lines the local parser could not
            // handle — only when the core is reachable (tunnel
            // running, or sample mode).
            if proxies.isEmpty, client.mode == .sample || TunnelManager.shared.isRunning {
                await decodeLinks(linkLines)
                proxies = decodedProxies
                failedCount = max(0, linkLines.count - proxies.count)
            }
            guard !proxies.isEmpty else { continue }
            let yaml = DefaultConfig.yaml(proxies: proxies)
            var note = "识别到 \(proxies.count) 个节点" + (failedCount > 0 ? "，\(failedCount) 行解析失败" : "")
            // Transport warnings (e.g. a link's ws/grpc/http option
            // the parser could not represent) are part of the
            // import result, not silent: surface the first one.
            if let firstWarning = warnings.first {
                note += "（注意：\(firstWarning)\(warnings.count > 1 ? " 等 \(warnings.count) 处" : "")）"
            }
            return .success((Data(yaml.utf8), note))
        }
        return .failure(NodeLinkError(message: Self.localSanityCheck(data) ?? "订阅内容无法识别：既不是 Clash 配置，也没有可识别的节点链接"))
    }

    /// Base64 decode that tolerates what providers actually send:
    /// URL-safe alphabet (-/_), missing padding, wrapped lines.
    private static func looseBase64Decode(_ text: String) -> Data? {
        var cleaned = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleaned.isEmpty else { return nil }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder != 0 {
            cleaned += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: cleaned)
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Import / update / delete

    /// A t.me link (bot / channel / join link, any path — e.g. a
    /// bot link with `?start=`) is not a subscription link.
    /// Returns the actionable hint when `urlString` points at
    /// t.me, nil otherwise. Host match only: `t.me` or a subdomain
    /// of it.
    static func telegramLinkHint(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(),
              host == "t.me" || host.hasSuffix(".t.me") else { return nil }
        return "这是 Telegram 链接（t.me），不是订阅链接：请在 Telegram 里打开它，从机器人或频道里获取真正的订阅链接，再粘贴到这里导入"
    }

    /// Classifies a subscription download/save failure into a
    /// specific, actionable message (FIX 3 diagnostics): TLS vs
    /// timeout vs HTTP status vs network — instead of a bare
    /// wrapped `error.localizedDescription`, which says what
    /// happened ("请求超时") but not why, and which the import
    /// row then wraps in a second "导入失败：". NSError values
    /// thrown by downloadSubscription already carry a specific
    /// message (HTTP status, HTML page, no HTTP response) and pass
    /// through unchanged via localizedDescription; URLError is
    /// mapped by code below; anything else (e.g. a save failure)
    /// also passes its localizedDescription through. No
    /// "导入失败：" prefix here — the caller (UnifiedImporter's
    /// row, update's "更新 … 失败：") adds its own. Diagnose
    /// only: download behaviour is unchanged (no fallback, no
    /// retry, no timeout change).
    static func subscriptionFailureMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "下载超时（20 秒内没有完成）：请检查网络后重试"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed:
            return "证书校验失败：订阅服务器的证书不受信任（校园网等网络可能替换了证书）。请检查网络，或在设置里关闭「校验订阅证书」后重试"
        case .notConnectedToInternet:
            return "没有网络连接：请检查网络后重试"
        case .networkConnectionLost:
            return "网络连接中断：请检查网络后重试"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接订阅服务器：请检查链接是否正确、网络是否正常"
        case .cancelled:
            return "下载已取消"
        case .unsupportedURL:
            return "不支持的 URL：请确认链接以 http:// 或 https:// 开头"
        default:
            return "下载失败（\(urlError.code.rawValue)）：\(urlError.localizedDescription)"
        }
    }

    @MainActor
    func addFromURL(name: String, urlString: String, ageSecretKey: String? = nil) async {
        // Telegram links are not subscriptions (FIX 3a): a t.me
        // bot / channel link serves a Telegram web page, never
        // Clash YAML. Intercept before any download: on-device the
        // URLSession failure surfaced as the bare system error
        // "不支持的 URL" (URLError.unsupportedURL, -1002 — that
        // string lives in iOS, not in this repo), with no hint
        // why. This is the single funnel (both the unified import
        // page and the Profiles "+" menu come through here), so
        // every entry point gets the hint.
        if let hint = Self.telegramLinkHint(for: urlString) {
            lastError = hint
            return
        }
        // Duplicate-URL guard (FlClash add.dart:76-79): the same
        // subscription URL must not create a second profile. This
        // is the single funnel — both the Profiles "+" menu and the
        // unified import page (UnifiedImporter.importSubscriptionURL)
        // come through here.
        let normalized = urlString.trimmingCharacters(in: .whitespaces)
        if let existing = profiles.first(where: { $0.kind == .url && $0.urlString?.trimmingCharacters(in: .whitespaces) == normalized }) {
            lastError = "该订阅链接已存在（「\(existing.name)」）：请直接更新该订阅，或先删除它再导入"
            return
        }
        guard let url = URL(string: urlString) else {
            lastError = "订阅链接无效"
            return
        }
        do {
            let downloaded = try await downloadSubscription(from: url)
            // Age-encrypted body (FlClash validateProfile): when the
            // import carried an age key (UnifiedImportView age field,
            // FlClash add.dart withAgeSecretKey), decrypt in this one
            // step when the core is reachable; otherwise save the
            // ciphertext as-is WITH the key stored on the profile, so
            // 更新 decrypts it with the stored key (see update()).
            // Activating before that fails with the age-specific
            // message in applyProfile, never with a generic parse
            // error. (FlClash's Profile model has no note field, so
            // no note is stored on the card.)
            let trimmedKey = ageSecretKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            var downloadedData = downloaded.data
            if Self.looksAgeEncrypted(downloadedData), let key = trimmedKey, !key.isEmpty {
                switch await decryptAgeDataIfNeeded(downloadedData, key: key) {
                case .success(let plain):
                    downloadedData = plain
                case .failure:
                    break // keep ciphertext; the stored key decrypts it on update
                }
            }
            if Self.looksAgeEncrypted(downloadedData) {
                var profile = Profile(name: name.isEmpty ? (downloaded.fileName ?? url.host ?? "订阅") : name, kind: .url, urlString: urlString, updatedAt: Date(), subscriptionInfo: downloaded.info)
                profile.ageSecretKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
                profiles.append(profile)
                try saveProfileFile(profile: profile, data: downloadedData)
                statusMessage = "已导入订阅 \(profile.name)（age 加密，待填写私钥后更新解密）"
                save()
                lastError = nil
                return
            }
            let normalized: (data: Data, note: String?)
            switch await normalizedSubscriptionData(downloadedData) {
            case .success(let value):
                normalized = value
            case .failure(let reason):
                lastError = "订阅内容异常：\(reason.message)"
                return
            }
            var profile = Profile(name: name.isEmpty ? (downloaded.fileName ?? url.host ?? "订阅") : name, kind: .url, urlString: urlString, updatedAt: Date(), subscriptionInfo: downloaded.info)
            profile.ageSecretKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
            profiles.append(profile)
            try saveProfileFile(profile: profile, data: normalized.data)
            statusMessage = "已导入订阅 \(profile.name)" + (normalized.note.map { "（\($0)）" } ?? "")
            save()
            lastError = nil
        } catch {
            // Specific cause, no "导入失败：" prefix here — the
            // UnifiedImporter row adds the single "导入失败：" in
            // front of lastError (previously this produced the
            // doubled "导入失败：导入失败：…" with only the bare
            // system string behind it).
            lastError = Self.subscriptionFailureMessage(error)
        }
    }

    @MainActor
    func addFromFile(name: String, data: Data) {
        if let problem = Self.localSanityCheck(data) {
            lastError = "文件内容异常：\(problem)"
            return
        }
        let profile = Profile(name: name, kind: .file, fileName: name, updatedAt: Date())
        profiles.append(profile)
        do {
            try saveProfileFile(profile: profile, data: data)
            statusMessage = "已导入本地配置 \(name)"
            save()
            lastError = nil
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func updateAll() async {
        for profile in profiles where profile.kind == .url {
            await update(profile)
        }
    }

    /// FlClash autoUpdateProfiles (providers/actions/profiles.dart):
    /// update only URL profiles where the global switch is on AND
    /// the profile's own autoUpdate is on AND lastUpdateDate +
    /// autoUpdateDuration has passed (a profile never updated is
    /// due). Per-profile failures are collected into lastError
    /// ("更新失败（N 个）：…" with each name + reason) instead of
    /// being overwritten by the next profile's success; a fully
    /// successful run clears lastError.
    /// Exact signature for the timer worker (20-minute timer +
    /// replacing the launch blanket updateAll() in ContentView):
    ///   `await profileStore.updateDueProfiles()`
    /// The global switch is read from `globalAutoUpdateEnabled`,
    /// synced from SettingsStore.autoUpdateProfiles by ContentView.
    @MainActor
    func updateDueProfiles() async {
        guard globalAutoUpdateEnabled else { return }
        var failures: [(name: String, error: String)] = []
        for profile in profiles where profile.kind == .url {
            guard profile.autoUpdate else { continue }
            let intervalMinutes = profile.autoUpdateIntervalMinutes ?? 1440
            if let last = profile.updatedAt {
                guard Date() >= last.addingTimeInterval(TimeInterval(intervalMinutes * 60)) else { continue }
            }
            await update(profile)
            if let error = lastError {
                failures.append((profile.name, error))
                lastError = nil
            }
        }
        if failures.isEmpty {
            lastError = nil
        } else {
            lastError = "自动更新失败（\(failures.count) 个）：\n"
                + failures.map { "· \($0.name)：\($0.error)" }.joined(separator: "\n")
        }
    }

    @MainActor
    func update(_ profile: Profile) async {
        guard let urlString = profile.urlString, let url = URL(string: urlString) else { return }
        do {
            let downloaded = try await downloadSubscription(from: url)
            // Age-encrypted download: decrypt with the stored key
            // before any YAML check (FlClash validateProfile).
            let plainData: Data
            switch await decryptAgeDataIfNeeded(downloaded.data, key: profile.ageSecretKey) {
            case .success(let data): plainData = data
            case .failure(let reason):
                lastError = "更新 \(profile.name) 失败：\(reason)"
                return
            }
            let normalized: Data
            switch await normalizedSubscriptionData(plainData) {
            case .success(let value):
                normalized = value.data
            case .failure(let reason):
                lastError = "更新 \(profile.name) 失败：订阅内容异常：\(reason.message)"
                return
            }
            // A fresh download would wipe the user's local additions
            // (custom proxies, filter overrides, custom-subscription
            // blocks) that live baked into the profile's YAML: re-
            // apply them before saving. This runs for EVERY profile,
            // not just the active one — a non-active profile's bake
            // blocks must survive its own update too (B10).
            let data = reapplyLocalOverrides(to: normalized, for: profile)
            try saveProfileFile(profile: profile, data: data)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].updatedAt = Date()
                // The header may be absent on this download: then the
                // old info is stale and must go, not linger.
                profiles[index].subscriptionInfo = downloaded.info
            }
            save()
            // Updating the active profile must take effect: re-apply it
            // (validate + copy + live-apply when the tunnel runs).
            if profile.isActive {
                await applyProfile(profile, data: data)
                if lastError == nil {
                    statusMessage = "已更新并应用 \(profile.name)"
                }
            } else {
                statusMessage = "已更新 \(profile.name)"
                lastError = nil
            }
        } catch {
            lastError = "更新 \(profile.name) 失败：\(Self.subscriptionFailureMessage(error))"
        }
    }

    /// Removes one profile's file + list entry. This is the
    /// low-level primitive: deleting the ACTIVE profile must go
    /// through deleteProfile(_:) instead, which switches to the
    /// next profile (or stops the VPN when none remain) — deleting
    /// here alone would leave the tunnel running deleted config.
    /// Kept synchronous because UnifiedImport replaces the
    /// "我的节点" profile through it; that call site still needs
    /// migrating to deleteProfile (open seam, see report).
    func delete(_ profile: Profile) {
        if let url = fileURL(for: profile) {
            try? FileManager.default.removeItem(at: url)
        }
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    /// Deletes a profile the FlClash way (profiles.dart
    /// deleteProfile): remove it, then — when it was active —
    /// switch to the first remaining profile (and apply it); when
    /// none remain, clear the current config + inspect and stop
    /// the VPN. The tunnel never keeps running deleted config.
    /// profile.clearEffect cannot be called: it takes the numeric
    /// id the host assigned the profile, and this app never learns
    /// one (profiles are UUIDs; the core keeps its provider
    /// downloads under <home>/profiles/providers/<numeric-id>,
    /// unreachable from here). The orphaned core-side provider
    /// cache for the deleted profile is therefore left to the
    /// core, not deleted.
    @MainActor
    func deleteProfile(_ profile: Profile) async {
        let wasActive = profile.isActive
        let name = profile.name
        delete(profile)
        guard wasActive else {
            statusMessage = "已删除 \(name)"
            return
        }
        if let next = profiles.first {
            await activate(next)
            if let error = lastError {
                // The fallback switch failed: the tunnel would still
                // be running the deleted config in memory, so stop
                // it rather than leave it running with no profile.
                await TunnelManager.shared.stop()
                lastError = "已删除 \(name)，但切换到 \(next.name) 失败，已停止 VPN：\(error)"
            } else {
                statusMessage = "已删除 \(name)，已切换到 \(next.name)"
            }
            return
        }
        // No profiles remain: clear the stale shared config + the
        // stale inspect, and stop the VPN (FlClash setRunning(false)).
        inspect = nil
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
            .appendingPathComponent(ConfigStore.configFileName) {
            try? FileManager.default.removeItem(at: shared)
        }
        await TunnelManager.shared.stop()
        statusMessage = "已删除 \(name)，没有剩余订阅，VPN 已停止"
        lastError = nil
    }

    /// Persist a drag-reordered profile list (ProfilesView onMove).
    /// The array order IS the display order; it is saved with the
    /// metadata in UserDefaults like every other list change.
    func moveProfiles(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// Persist a reordered list built outside the List (the FlClash
    /// ReorderableProfilesSheet keeps a local copy and saves once).
    /// Profiles missing from the new order keep their relative order
    /// at the end, so a concurrent add is never dropped.
    func reorderProfiles(_ newOrder: [Profile]) {
        let ids = Set(newOrder.map(\.id))
        profiles = newOrder + profiles.filter { !ids.contains($0.id) }
        save()
    }

    /// Save the FlClash edit page's fields (name / URL / age key /
    /// auto-update). Returns true when the URL of a URL profile
    /// changed, so the caller can re-download it (FlClash does the
    /// same after an edit that changes the URL).
    @discardableResult
    func updateProfileMeta(_ profile: Profile, name: String, urlString: String?, ageSecretKey: String?, autoUpdate: Bool, autoUpdateIntervalMinutes: Int?) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        let urlChanged = profiles[index].kind == .url && profiles[index].urlString != urlString
        profiles[index].name = name
        profiles[index].urlString = urlString
        profiles[index].ageSecretKey = ageSecretKey
        profiles[index].autoUpdate = autoUpdate
        profiles[index].autoUpdateIntervalMinutes = autoUpdateIntervalMinutes
        save()
        return urlChanged
    }

    /// File size + last-modified of a profile's YAML, for the edit
    /// page's file row (FlClash shows the same two facts).
    func profileFileInfo(_ profile: Profile) -> (size: Int, lastModified: Date?)? {
        guard let url = fileURL(for: profile),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (size: attrs[.size] as? Int ?? 0, lastModified: attrs[.modificationDate] as? Date)
    }

    /// Replace a profile's YAML file (FlClash edit page's upload).
    /// An age-encrypted upload is decrypted FIRST with the given
    /// key (falling back to the profile's stored key) — the YAML
    /// sanity check runs on the plaintext, not the ciphertext
    /// (FlClash saveFile validates with the key). When the tunnel
    /// is stopped the core cannot decrypt, so the save fails
    /// honestly instead of storing ciphertext that can never apply.
    /// Validates locally first; when the profile is active the new
    /// file is re-applied like an update, so it takes effect.
    /// @MainActor: the age-decrypt await and the applyProfile await
    /// below suspend, so without this the lastError / profiles
    /// writes after them would publish from a background thread.
    @MainActor
    func updateProfileFile(_ profile: Profile, data: Data, ageSecretKey: String? = nil) async {
        var data = data
        if Self.looksAgeEncrypted(data) {
            switch await decryptAgeDataIfNeeded(data, key: ageSecretKey ?? profile.ageSecretKey) {
            case .success(let plain): data = plain
            case .failure(let reason):
                lastError = "文件内容异常：\(reason)"
                return
            }
        }
        if let problem = Self.localSanityCheck(data) {
            lastError = "文件内容异常：\(problem)"
            return
        }
        do {
            try saveProfileFile(profile: profile, data: data)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].updatedAt = Date()
            }
            save()
            lastError = nil
            if profile.isActive {
                await applyProfile(profile, data: data)
            }
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// A shareable copy of a profile's YAML (FlClash exportFile):
    /// the on-disk file is named by UUID, so the export is copied
    /// to tmp under the profile's name.
    func exportFileURL(for profile: Profile) -> URL? {
        guard let source = fileURL(for: profile),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let safeName = profile.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeName.isEmpty ? "配置" : safeName) + ".yaml"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return nil }
        return dest
    }

    /// Local provenance for NodeSourcesView: the proxy names a
    /// profile's own YAML file declares under `proxies:` (a line
    /// scan — no core needed, so it works with the tunnel stopped).
    /// Provider-fetched nodes are not in `proxies:`; those come
    /// from the core via convertProfile instead.
    func localNodeNames(for profile: Profile) -> [String] {
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names: [String] = []
        var inProxies = false
        for line in text.components(separatedBy: "\n") {
            if line == "proxies:" || line.hasPrefix("proxies: ") {
                inProxies = true
                continue
            }
            if inProxies {
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- {"), trimmed.hasSuffix("}") {
                    // Flow mapping: "- { name: X, type: ... }"
                    // (subscription files written entirely in flow
                    // style have no "- name:" lines at all).
                    let inner = String(trimmed.dropFirst(3).dropLast())
                    for kv in Self.flowMappingPairs(inner) where kv.key == "name" {
                        if !kv.value.isEmpty { names.append(kv.value) }
                    }
                    continue
                }
                guard trimmed.hasPrefix("- name:") else { continue }
                var value = String(trimmed.dropFirst("- name:".count))
                    .trimmingCharacters(in: .whitespaces)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                    (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { names.append(value) }
            }
        }
        return names
    }

    // MARK: - Local proxy/group parse (Proxies page offline fallback)
    //
    // The core only knows groups while the VPN runs (proxy.watch /
    // proxy.groups need a loaded config), but FlClash shows the
    // profile's groups/nodes before the VPN starts — and the user
    // rightly expects to pick a node first, then start. So the
    // Proxies page falls back to parsing the ACTIVE profile's local
    // YAML when the core is unreachable (ProxyStore.refresh).
    // Same line-scan approach as localNodeNames: no core needed, so
    // it works with the tunnel stopped. Provider-fetched nodes are
    // not in `proxies:` (they come from the core), and group members
    // that are other groups or built-ins resolve as DIRECT/REJECT or
    // "unknown" — the live path does the same for nested groups.

    struct LocalProxyNode {
        let name: String
        let type: String
        /// Name of the proxy-provider this node came from, when it
        /// did not come from the profile's own `proxies:` section.
        /// Nil for literal nodes. ProxyStore.loadLocalGroups must
        /// pass this through to ProxyNode.provider (open seam: that
        /// file belongs to another worker) for the Proxies page to
        /// show it; NodeSourcesView already displays it.
        let provider: String?

        init(name: String, type: String, provider: String? = nil) {
            self.name = name
            self.type = type
            self.provider = provider
        }
    }

    struct LocalProxyGroup {
        let name: String
        let type: String
        let nodeNames: [String]
        let testURL: String
        /// The group's `icon:` from the subscription YAML
        /// (v0.2.57): a URL in practice (mihomo / FlClash custom
        /// groups bake an icon URL), or a name — never invented
        /// here. "" = the group defines none; the Proxies page
        /// then falls back to the user-imported icon pack (matched
        /// by group name) and finally the monogram. No built-in
        /// brand icons.
        let icon: String
        /// Raw filter expressions, kept so callers can see why a
        /// group has the members it has; nodeNames already has the
        /// filter evaluated against the parsed node list.
        let filter: String
        let excludeFilter: String
        /// Provider names from the group's `use:` list.
        let useProviders: [String]
        /// Hidden from the Proxies page in rule mode (Clash
        /// `hidden: true`); carried so the offline list filters
        /// exactly like the live one (v0.2.53 mode filtering).
        /// Defaults to false — most groups do not set it.
        let hidden: Bool

        init(name: String, type: String, nodeNames: [String], testURL: String,
             icon: String = "", filter: String = "", excludeFilter: String = "", useProviders: [String] = [],
             hidden: Bool = false) {
            self.name = name
            self.type = type
            self.nodeNames = nodeNames
            self.testURL = testURL
            self.icon = icon
            self.filter = filter
            self.excludeFilter = excludeFilter
            self.useProviders = useProviders
            self.hidden = hidden
        }
    }

    /// One proxy-provider declaration from the profile's
    /// `proxy-providers:` section.
    struct LocalProxyProvider {
        let name: String
        let type: String
        let url: String
        let path: String
        let filter: String
        let excludeFilter: String
    }

    struct LocalProxyGroups {
        let nodes: [LocalProxyNode]
        let groups: [LocalProxyGroup]
        let providers: [LocalProxyProvider]
    }

    /// Parse `proxies:` (name + type), `proxy-groups:` (name, type,
    /// member list, `use:`, filter / exclude-filter, url) and
    /// `proxy-providers:` from a profile's local YAML. Provider
    /// nodes are resolved offline: `file` providers are read from
    /// their file, `http` providers from the core's cached copy
    /// (their `path:`, relative to the profile or the App Group
    /// container, which is the core's home). An http provider with
    /// no cached file cannot be resolved offline — its nodes stay
    /// unknown until the tunnel runs, and the group keeps only its
    /// literal / other members rather than inventing any.
    /// Group members are literal `proxies:` + `use:` provider
    /// nodes, filtered by the group's filter / exclude-filter
    /// (mihomo regex over the node name; a group with a filter but
    /// no literal / `use:` members filters the whole node pool).
    /// Returns nil when the file is missing or has neither section.
    /// A config with proxies but no groups gets one synthesized
    /// "GLOBAL" select group holding all of them (what the core
    /// synthesizes too).
    func localProxyGroups(for profile: Profile) -> LocalProxyGroups? {
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var nodes: [LocalProxyNode] = []
        var groups: [LocalProxyGroup] = []
        var providers: [LocalProxyProvider] = []
        var section: String? = nil
        // Current list item being collected, with its indent.
        var itemIndent = -1
        var item: [String: String] = [:]
        var itemMembers: [String] = []
        var itemMembersFlow: [String]? = nil
        var itemUse: [String] = []
        var itemUseFlow: [String]? = nil
        var listKey: String? = nil
        var listIndent = -1
        // Current proxy-provider mapping entry being collected.
        var providerName: String? = nil
        var providerFields: [String: String] = [:]
        func flushProvider() {
            guard let name = providerName else { return }
            providers.append(LocalProxyProvider(
                name: name, type: providerFields["type"] ?? "http",
                url: providerFields["url"] ?? "", path: providerFields["path"] ?? "",
                filter: providerFields["filter"] ?? "",
                excludeFilter: providerFields["exclude-filter"] ?? ""))
            providerName = nil
            providerFields = [:]
        }
        func flushItem() {
            guard section != nil, !item.isEmpty else { return }
            if section == "proxies" {
                if let name = item["name"] {
                    nodes.append(LocalProxyNode(name: name, type: item["type"] ?? "unknown"))
                }
            } else if section == "proxy-groups" {
                if let name = item["name"] {
                    let members = itemMembersFlow ?? itemMembers
                    groups.append(LocalProxyGroup(
                        name: name, type: item["type"] ?? "select",
                        nodeNames: members, testURL: item["url"] ?? "",
                        icon: item["icon"] ?? "",
                        filter: item["filter"] ?? "", excludeFilter: item["exclude-filter"] ?? "",
                        useProviders: itemUseFlow ?? itemUse,
                        hidden: item["hidden"]?.lowercased() == "true"))
                }
            }
            item = [:]
            itemMembers = []
            itemMembersFlow = nil
            itemUse = []
            itemUseFlow = nil
            listKey = nil
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent == 0 {
                flushItem()
                flushProvider()
                itemIndent = -1
                if trimmed == "proxies:" || trimmed.hasPrefix("proxies: ") {
                    section = "proxies"
                } else if trimmed == "proxy-groups:" || trimmed.hasPrefix("proxy-groups: ") {
                    section = "proxy-groups"
                } else if trimmed == "proxy-providers:" || trimmed.hasPrefix("proxy-providers: ") {
                    section = "proxy-providers"
                } else {
                    section = nil
                }
                continue
            }
            guard section != nil else { continue }
            if section == "proxy-providers" {
                // Mapping style: "  name:" starts a provider,
                // deeper "key: value" lines are its fields. A flow
                // mapping ("  name: {type: http, ...}") is not
                // handled — the live core path stays authoritative.
                if indent == 2, trimmed.hasSuffix(":"), !trimmed.hasPrefix("- ") {
                    flushProvider()
                    providerName = Self.unquote(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
                } else if providerName != nil, indent > 2, let kv = Self.yamlKeyValue(trimmed) {
                    providerFields[kv.key] = kv.value
                }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                // A deeper-indented "- " while collecting a member
                // list is a member, not a new item.
                if let key = listKey, indent > listIndent {
                    let value = Self.unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    if !value.isEmpty {
                        if key == "proxies" { itemMembers.append(value) } else { itemUse.append(value) }
                    }
                    continue
                }
                flushItem()
                itemIndent = indent
                listKey = nil
                let rest = trimmed == "-" ? "" : String(trimmed.dropFirst(2))
                if !rest.isEmpty {
                    if rest.hasPrefix("{"), rest.hasSuffix("}") {
                        // Flow mapping: "- { name: X, type: y,
                        // proxies: [...] }" — one line holds the
                        // whole item. Split on top-level commas
                        // (flowMappingPairs), then feed each pair
                        // through the same handling as the
                        // block-style fields below.
                        for kv in Self.flowMappingPairs(String(rest.dropFirst().dropLast())) {
                            if section == "proxy-groups" && (kv.key == "proxies" || kv.key == "use"),
                               let flow = Self.flowList(kv.value) {
                                if kv.key == "proxies" { itemMembersFlow = flow } else { itemUseFlow = flow }
                            } else {
                                item[kv.key] = kv.value
                            }
                        }
                    } else if let kv = Self.yamlKeyValue(rest) {
                        if kv.key == "proxies", let flow = Self.flowList(kv.value) {
                            itemMembersFlow = flow
                        } else {
                            item[kv.key] = kv.value
                        }
                    }
                }
                continue
            }
            guard itemIndent >= 0, indent > itemIndent else { continue }
            if listKey != nil, indent <= listIndent { listKey = nil }
            if let key = listKey, indent > listIndent {
                if trimmed.hasPrefix("- ") {
                    let value = Self.unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    if !value.isEmpty {
                        if key == "proxies" { itemMembers.append(value) } else { itemUse.append(value) }
                    }
                }
                continue
            }
            guard let kv = Self.yamlKeyValue(trimmed) else { continue }
            if section == "proxy-groups" && (kv.key == "proxies" || kv.key == "use") {
                if let flow = Self.flowList(kv.value) {
                    if kv.key == "proxies" { itemMembersFlow = flow } else { itemUseFlow = flow }
                } else if kv.value.isEmpty {
                    listKey = kv.key
                    listIndent = indent
                } else {
                    item[kv.key] = kv.value
                }
            } else {
                item[kv.key] = kv.value
            }
        }
        flushItem()
        flushProvider()
        if nodes.isEmpty && groups.isEmpty && providers.isEmpty { return nil }
        // Resolve provider nodes offline (C1).
        let profileDir = url.deletingLastPathComponent()
        var providerNodes: [LocalProxyNode] = []
        for provider in providers {
            providerNodes.append(contentsOf: Self.resolveProviderNodes(provider, profileDirectory: profileDir))
        }
        var allNodes = nodes
        var seenNames = Set(nodes.map(\.name))
        for node in providerNodes where !seenNames.contains(node.name) {
            allNodes.append(node)
            seenNames.insert(node.name)
        }
        // Evaluate group filters (C2): literal members + `use:`
        // provider nodes, filtered by filter / exclude-filter. A
        // group with a filter but no literal / `use:` source
        // filters the whole node pool instead of showing 0.
        let nodeNames = Set(allNodes.map(\.name))
        let resolvedGroups = groups.map { group -> LocalProxyGroup in
            var members: [String] = []
            var seen: Set<String> = []
            func add(_ name: String) {
                guard !name.isEmpty, !seen.contains(name) else { return }
                seen.insert(name)
                members.append(name)
            }
            for name in group.nodeNames { add(name) }
            for providerName in group.useProviders {
                for node in providerNodes where node.provider == providerName { add(node.name) }
            }
            if !group.filter.isEmpty || !group.excludeFilter.isEmpty {
                if members.isEmpty {
                    for node in allNodes where Self.matchesFilter(node.name, filter: group.filter, excludeFilter: group.excludeFilter) {
                        add(node.name)
                    }
                } else {
                    members = members.filter { name in
                        // Nested-group names and built-ins are not
                        // nodes: they pass through unfiltered.
                        guard nodeNames.contains(name) else { return true }
                        return Self.matchesFilter(name, filter: group.filter, excludeFilter: group.excludeFilter)
                    }
                }
            }
            return LocalProxyGroup(
                name: group.name, type: group.type, nodeNames: members,
                testURL: group.testURL, icon: group.icon, filter: group.filter,
                excludeFilter: group.excludeFilter, useProviders: group.useProviders,
                hidden: group.hidden)
        }
        groups = resolvedGroups
        if groups.isEmpty {
            groups = [LocalProxyGroup(name: "GLOBAL", type: "select",
                                      nodeNames: allNodes.map(\.name), testURL: "")]
        }
        return LocalProxyGroups(nodes: allNodes, groups: groups, providers: providers)
    }

    /// mihomo group filter: `filter` is a regex the node name must
    /// match, `exclude-filter` one it must not match. An invalid
    /// regex falls back to a plain substring match instead of
    /// dropping every member.
    private static func matchesFilter(_ name: String, filter: String, excludeFilter: String) -> Bool {
        if !filter.isEmpty, !matchesRegex(filter, in: name) { return false }
        if !excludeFilter.isEmpty, matchesRegex(excludeFilter, in: name) { return false }
        return true
    }

    private static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range) != nil
        }
        return text.contains(pattern)
    }

    /// Reads one provider's nodes from its local file. `file`
    /// providers use their `path:`; `http` providers use their
    /// cached `path:` (mihomo writes the download there, relative
    /// to the config dir) or the conventional cache locations
    /// under the App Group container (the core's home). Returns []
    /// when no file is found — the nodes stay unknown offline.
    private static func resolveProviderNodes(_ provider: LocalProxyProvider, profileDirectory: URL) -> [LocalProxyNode] {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
        var candidates: [URL] = []
        func addCandidate(_ path: String) {
            guard !path.isEmpty else { return }
            if path.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: path))
            } else {
                candidates.append(profileDirectory.appendingPathComponent(path))
                if let container { candidates.append(container.appendingPathComponent(path)) }
            }
        }
        addCandidate(provider.path)
        if provider.type == "http" {
            if let container {
                candidates.append(container.appendingPathComponent("providers/\(provider.name).yaml"))
                candidates.append(container.appendingPathComponent("providers/proxies/\(provider.name).yaml"))
                candidates.append(container.appendingPathComponent("providers/\(provider.name)"))
            }
            candidates.append(profileDirectory.appendingPathComponent("\(provider.name).yaml"))
        }
        for candidate in candidates {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let parsed = parseProxyListItems(text)
            guard !parsed.isEmpty else { continue }
            return parsed
                .filter { Self.matchesFilter($0.name, filter: provider.filter, excludeFilter: provider.excludeFilter) }
                .map { LocalProxyNode(name: $0.name, type: $0.type, provider: provider.name) }
        }
        return []
    }

    /// Scans a provider file's `proxies:` section for name + type
    /// (same line-scan approach as localProxyGroups, no core).
    private static func parseProxyListItems(_ text: String) -> [(name: String, type: String)] {
        var out: [(name: String, type: String)] = []
        var inProxies = false
        var item: [String: String] = [:]
        var itemIndent = -1
        func flush() {
            if let name = item["name"] {
                out.append((name: name, type: item["type"] ?? "unknown"))
            }
            item = [:]
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent == 0 {
                flush()
                itemIndent = -1
                inProxies = trimmed == "proxies:" || trimmed.hasPrefix("proxies: ")
                continue
            }
            guard inProxies else { continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                flush()
                itemIndent = indent
                let rest = trimmed == "-" ? "" : String(trimmed.dropFirst(2))
                if !rest.isEmpty, let kv = yamlKeyValue(rest) { item[kv.key] = kv.value }
                continue
            }
            guard itemIndent >= 0, indent > itemIndent, let kv = yamlKeyValue(trimmed) else { continue }
            item[kv.key] = kv.value
        }
        flush()
        return out
    }

    /// "key: value" split for one YAML scalar line; strips matching
    /// quotes from the value. Returns nil for lines without a colon.
    private static func yamlKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Strip a trailing inline comment (only when the # is not
        // inside quotes — good enough for name/type/url lines).
        if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\""), !value.hasPrefix("'") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty else { return nil }
        return (key, unquote(value))
    }

    /// "[a, b, c]" flow list → members. Names containing commas do
    /// not survive this (documented: the core path stays
    /// authoritative while running); quoted members are unquoted.
    private static func flowList(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = value.dropFirst().dropLast()
        return inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// Split a flow mapping's inner content ("name: X, type: y,
    /// proxies: [...]") on top-level commas — commas inside nested
    /// [] / {} or quotes do not split — then parse each
    /// "key: value" pair with yamlKeyValue. Used for one-line
    /// "- { ... }" items. Escaped quotes inside quoted values are
    /// not handled (same documented limit as flowList); the core
    /// path stays authoritative while running.
    private static func flowMappingPairs(_ inner: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        var depth = 0
        var quote: Character? = nil
        var current = ""
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case "[", "{":
                depth += 1
                current.append(ch)
            case "]", "}":
                depth = max(0, depth - 1)
                current.append(ch)
            case "," where depth == 0:
                if let kv = yamlKeyValue(current.trimmingCharacters(in: .whitespaces)) {
                    pairs.append(kv)
                }
                current = ""
            default:
                current.append(ch)
            }
        }
        if let kv = yamlKeyValue(current.trimmingCharacters(in: .whitespaces)) {
            pairs.append(kv)
        }
        return pairs
    }

    private static func unquote(_ value: String) -> String {
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
            (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Rule-set repair (v0.2.46 ITEM 1)
    //
    // The core refuses the WHOLE config at compile time when a
    // rule references a rule-set no `rule-providers:` entry
    // defines ("rules[0] [RULE-SET, Apple, …] error: rule set
    // [Apple] not found", upstream crates/config/src/profile.rs).
    // The delay test then cannot run at all (AppCoreError
    // .configApplyFailed). This engine builds a repair plan for
    // the ACTIVE profile's YAML — never applied automatically,
    // never written without the user's confirmation (the Proxies
    // banner offers it, the sheet shows the exact lines,
    // ProxyStore applies it through updateProfileFile).
    //
    // COMPLETION (primary): the missing definition is inferred
    // from the profile's other rule-providers. Siblings are
    // grouped by (behavior, URL template, path template,
    // interval) after the sibling's own name is replaced by a
    // placeholder; the most common combination wins, but only
    // on a strict majority — a tie or a scatter means "no
    // pattern", and the plan falls back to DELETE. The new block
    // copies the template sibling's field lines verbatim (full
    // fidelity: type, format, proxy, filter, … — not just the
    // four grouped fields), with the missing name substituted
    // for the sibling's name in the header and in every field
    // value that contains it (URL + path), preserving the
    // siblings' indent style and quoting.
    // DELETE (fallback): when no pattern can be inferred (no
    // section, flow-style section, zero siblings, no majority),
    // remove the RULE-SET lines that reference the missing set
    // from `rules:` (block lines and quoted lines alike).
    // Everything is line-based and preserves the rest of the
    // file byte-for-byte; a section the parser cannot read
    // safely yields .unrepairable with the reason, and nothing
    // is written. A flow-style provider entry (`  Name: {…}`)
    // is simply skipped by the parser (its fields are never
    // guessed at); a mapping-style sibling next to it can still
    // serve as the template.

    /// The missing rule-set name in a core error, if it names
    /// one: "… rule set [Apple] not found". Nil for any other
    /// error — the repair offer only appears for this exact
    /// failure.
    static func missingRuleSetName(from message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"rule set \[([^\]]+)\] not found"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: message) else { return nil }
        let name = String(message[range]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Builds the repair plan for one profile's file. Nil only
    /// when the file cannot be read at all; an unreadable
    /// section or an uninferable pattern still returns a plan
    /// (delete or unrepairable with the reason).
    func ruleSetRepairPlan(for profile: Profile, missingName: String) -> RuleSetRepairPlan? {
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.ruleSetRepairPlan(text: text, missingName: missingName)
    }

    /// Validates one candidate config text with the core
    /// (config.validate on a temp file in the App Group — the core
    /// reads it with a plain fs::read in the extension process, so
    /// a path in the app's own tmp would be invisible to it; same
    /// pattern as validateYAMLText). The candidate is baked first
    /// (reapplyLocalOverrides), because the core applies the BAKED
    /// bytes, not the raw profile file — validating the raw text
    /// would miss exactly the divergence behind the TikTok
    /// paradox. VPN on: the extension's core validates; VPN off:
    /// the app-side core validates (ensureValidationSession
    /// first — a broken config leaves no session behind).
    /// Returns the core's issues (at most one: the first parse
    /// error). Throws when no core is reachable at all.
    @MainActor
    func validateCandidateText(_ text: String, for profile: Profile) async throws -> [ConcordIssue] {
        guard let dir = profilesDirectory else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        let baked = reapplyLocalOverrides(to: Data(text.utf8), for: profile)
        let bakedText = String(data: baked, encoding: .utf8) ?? text
        let tempURL = dir.appendingPathComponent(".repair-validate.yaml")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bakedText.write(to: tempURL, atomically: true, encoding: .utf8)
        if TunnelManager.shared.isRunning {
            return try await client.configValidate(profilePath: tempURL.path)
        }
        try await AppCore.shared.ensureValidationSession()
        return try await AppCore.shared.configValidate(profilePath: tempURL.path)
    }

    /// Validates one custom subscription's baked candidate for a
    /// profile with the core (config.validate on a temp file in
    /// the App Group) — the same path validateCandidateText uses
    /// for the repair flow, but for an EXPLICIT subscription
    /// instead of the bake-map entry: bake the subscription (plus
    /// the other local overrides, in the same order as
    /// reapplyLocalOverrides) into the profile's on-disk text,
    /// then validate the baked bytes, because the core applies the
    /// BAKED bytes, not the raw profile file. Returns the core's
    /// issues (empty = clean). Throws when no core is reachable
    /// at all. VPN on: the extension's core validates; VPN off:
    /// the app-side core validates (ensureValidationSession
    /// first — a broken config leaves no session behind).
    /// Wiring point for the "应用到当前配置" flow: validate the
    /// bake BEFORE noteBaked + saveActiveProfileYAML, and refuse
    /// to save when issues come back. Currently uncalled —
    /// NodeSourcesView.applyNow owns that call site.
    @MainActor
    func validateBakedSubscription(_ sub: CustomSubscription, for profile: Profile) async throws -> [ConcordIssue] {
        guard let dir = profilesDirectory else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法读取订阅「\(profile.name)」的文件"])
        }
        var result = CustomProxyStore.bakeCurrent(into: text)
        let store = CustomProxyStore()
        result = CustomProxyStore.bakeFilterOverrides(store.filterOverrides, into: result)
        result = CustomSubscriptionStore.bake(sub, into: result)
        let tempURL = dir.appendingPathComponent(".scoped-validate.yaml")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try result.write(to: tempURL, atomically: true, encoding: .utf8)
        if TunnelManager.shared.isRunning {
            return try await client.configValidate(profilePath: tempURL.path)
        }
        try await AppCore.shared.ensureValidationSession()
        return try await AppCore.shared.configValidate(profilePath: tempURL.path)
    }

    /// Collects EVERY rule set missing for one profile, by TEXT
    /// (v0.2.58): the rule-set names referenced in `rules:` minus
    /// the names defined in `rule-providers:`, computed on the
    /// BAKED bytes (reapplyLocalOverrides — what the core actually
    /// applies, so a rule re-inserted by a baked custom
    /// subscription counts). The old loop used config.validate as
    /// the oracle, but validate only parses YAML and never checks
    /// cross-references — `rule set [X] not found` is raised at
    /// compile time (load_raw), which validate never calls — so
    /// the loop always found nothing and the repair never opened.
    /// validateCandidateText is kept only as a YAML-parse sanity
    /// check: any issue it reports is a parse error (never a
    /// rule-set verdict) and becomes the blockingIssue, while the
    /// text-computed missing list is still returned. Returns the
    /// missing names in first-reference order, the final candidate
    /// (the baked text with every referencing line deleted), the
    /// rule lines deleted per name (for the all-delete fallback
    /// preview), and a blocking issue when the sanity check
    /// failed.
    @MainActor
    func collectMissingRuleSets(for profile: Profile) async -> (missing: [String], finalCandidate: String, deletedLines: [String: [String]], blockingIssue: String?) {
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], "", [:], "无法读取当前订阅「\(profile.name)」的文件")
        }
        // Discover on the baked bytes, not the raw file: a rule
        // re-inserted by a baked custom subscription is missing
        // in the baked text even when the file's own rules are
        // clean, and a provider defined only in a baked block
        // counts as defined.
        let bakedText = String(data: reapplyLocalOverrides(to: Data(text.utf8), for: profile), encoding: .utf8) ?? text
        let missing = Self.missingRuleSetNames(in: bakedText)
        let bakedLines = bakedText.components(separatedBy: "\n")
        var deletedLines: [String: [String]] = [:]
        var toDelete = Set<Int>()
        if let rulesSection = Self.topLevelSection(named: "rules", in: bakedLines), !rulesSection.isFlowStyle {
            for name in missing {
                let matched = Self.ruleSetRuleLineIndices(in: bakedLines, section: rulesSection, missingName: name)
                deletedLines[name] = matched.map { bakedLines[$0] }
                toDelete.formUnion(matched)
            }
        }
        var candidateLines = bakedLines
        for index in toDelete.sorted().reversed() { candidateLines.remove(at: index) }
        let finalCandidate = candidateLines.joined(separator: "\n")
        // YAML-parse sanity check only (see the doc comment):
        // validateCandidateText bakes the candidate itself, so
        // the raw text is the right input here.
        do {
            let issues = try await validateCandidateText(text, for: profile)
            if let first = issues.first {
                return (missing, finalCandidate, deletedLines, first.message)
            }
        } catch {
            return (missing, finalCandidate, deletedLines, "校验失败：\(error.localizedDescription)")
        }
        return (missing, finalCandidate, deletedLines, nil)
    }

    /// Which of `missing` originate in the custom subscription
    /// baked into this profile (bake map → CustomSubscriptionStore):
    /// the referencing RULE-SET rule lives in that subscription's
    /// `rules`, so the file alone cannot fix it — the next bake
    /// (switch / update / re-apply) re-inserts it. Read-only; the
    /// confirmed repair removes these via removeBakedRuleSetRules.
    /// Empty when nothing is baked into this profile, or when the
    /// baked subscription holds no such rule. A rule whose line is
    /// also in the profile file (the baked marker block) is still
    /// listed here: the file delete alone would be resurrected.
    @MainActor
    func bakeSourceInfo(for profile: Profile, missing: [String]) -> [(name: String, subscriptionName: String, ruleCount: Int)] {
        guard !missing.isEmpty,
              let subID = CustomSubscriptionStore.bakedSubscriptionID(for: profile.id) else { return [] }
        let store = CustomSubscriptionStore()
        guard let sub = store.subscriptions.first(where: { $0.id == subID }) else { return [] }
        var out: [(name: String, subscriptionName: String, ruleCount: Int)] = []
        for name in missing {
            let count = sub.rules.filter { $0.type.uppercased() == "RULE-SET" && $0.content == name }.count
            if count > 0 { out.append((name: name, subscriptionName: sub.name, ruleCount: count)) }
        }
        return out
    }

    /// Removes the RULE-SET rules for `names` from the custom
    /// subscription baked into this profile, persisted via
    /// CustomSubscriptionStore.update (the store's JSON file).
    /// Only call for names the confirmed plan DELETES — a
    /// completed name's rule must stay, its provider is now
    /// defined. Returns what was removed, per name, for the sheet
    /// outcome + the repair log. Empty when nothing is baked, or
    /// when the baked subscription holds no such rule.
    @MainActor
    func removeBakedRuleSetRules(_ names: [String], for profile: Profile) -> [(name: String, subscriptionName: String, removedCount: Int)] {
        guard !names.isEmpty else { return [] }
        let store = CustomSubscriptionStore()
        guard let subID = CustomSubscriptionStore.bakedSubscriptionID(for: profile.id),
              var sub = store.subscriptions.first(where: { $0.id == subID }) else { return [] }
        var removed: [(name: String, subscriptionName: String, removedCount: Int)] = []
        for name in names {
            let count = sub.rules.filter { $0.type.uppercased() == "RULE-SET" && $0.content == name }.count
            guard count > 0 else { continue }
            sub.rules.removeAll { $0.type.uppercased() == "RULE-SET" && $0.content == name }
            removed.append((name: name, subscriptionName: sub.name, removedCount: count))
        }
        guard !removed.isEmpty else { return [] }
        store.update(sub)
        return removed
    }

    /// Builds the repair-ALL plan for a profile (v0.2.49,
    /// detector rewritten v0.2.58, core-invisible fix v0.2.59):
    /// collect every missing set by TEXT (collectMissingRuleSets),
    /// then decide each one's action against the ORIGINAL text.
    /// `coreReportedMissing` is the set the core's current error
    /// names (ProxyStore.missingRuleSetName, from testError): a
    /// set the text already defines is core-invisible — the core
    /// still reports it missing (v0.2.58 150G/TikTok: the core
    /// said "rule set [TikTok] not found" while the text detector
    /// found nothing missing, so the plan came back nil and the
    /// banner could only say "未找到缺失的规则集"). A
    /// textually-missing set can never also be defined, so the
    /// invisible case can only enter through this parameter —
    /// without it the `invisible` branch below is dead code. An
    /// invisible set is deleted with an explanation instead of
    /// completed (completion would only add a duplicate key); the
    /// rest are completed from sibling templates when inferable,
    /// else deleted. A name whose rule lives only in the baked
    /// custom subscription (no line in the file) is offered as a
    /// delete of the subscription's rule — the repair is the store
    /// removal at confirm, not a file edit. The combined text
    /// (all edits applied) is re-checked TEXTUALLY on the
    /// simulated post-confirm bytes (baked, minus the bake-source
    /// lines confirm will delete from the subscription); when
    /// anything is still missing, the plan falls back to the
    /// all-deleted candidate. Nil when the file cannot be read
    /// or nothing is missing (and the core named nothing the
    /// text defines).
    @MainActor
    func ruleSetRepairAllPlan(for profile: Profile, coreReportedMissing: String? = nil) async -> RuleSetRepairAllPlan? {
        guard let url = fileURL(for: profile),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let collected = await collectMissingRuleSets(for: profile)
        // Names the BAKED text defines (textual scan on what the
        // core applies — a provider defined only in a baked block
        // counts) and references: the core-reported set is
        // core-invisible exactly when it is referenced AND defined
        // here — the core says "not found" anyway (dead URL,
        // invalid/empty fetched content, fetch failure, or a
        // definition the core cannot load), so it is repaired by
        // deleting the referencing rule(s), not by completing a
        // definition that already exists. Without this step the
        // plan is nil for exactly the case the user is hitting.
        let bakedText = String(data: reapplyLocalOverrides(to: Data(text.utf8), for: profile), encoding: .utf8) ?? text
        let definedNames = Self.definedRuleProviderNames(in: bakedText)
        let referencedNames = Self.referencedRuleSetNames(in: bakedText)
        var allMissing = collected.missing
        var invisibleNames: [String] = []
        if let coreName = coreReportedMissing?.trimmingCharacters(in: .whitespaces),
           !coreName.isEmpty, !allMissing.contains(coreName),
           referencedNames.contains(coreName), definedNames.contains(coreName) {
            allMissing.append(coreName)
            invisibleNames.append(coreName)
        }
        guard !allMissing.isEmpty else { return nil }
        // Deleted lines / all-deleted candidate for EVERY name in
        // the plan, not just the textually-missing ones: the
        // collected maps only cover collected.missing, so an
        // invisible name's lines are computed here from the baked
        // bytes (the fallback writes the baked candidate).
        var deletedLines = collected.deletedLines
        var finalCandidate = collected.finalCandidate
        if !invisibleNames.isEmpty {
            let bakedLines = bakedText.components(separatedBy: "\n")
            if let rulesSection = Self.topLevelSection(named: "rules", in: bakedLines), !rulesSection.isFlowStyle {
                var toDelete = Set<Int>()
                for name in allMissing {
                    let matched = Self.ruleSetRuleLineIndices(in: bakedLines, section: rulesSection, missingName: name)
                    deletedLines[name] = matched.map { bakedLines[$0] }
                    toDelete.formUnion(matched)
                }
                var candidateLines = bakedLines
                for index in toDelete.sorted().reversed() { candidateLines.remove(at: index) }
                finalCandidate = candidateLines.joined(separator: "\n")
            }
        }
        var combinedText = text
        var items: [RuleSetRepairItem] = []
        for name in allMissing {
            let invisible = definedNames.contains(name)
            let plan = Self.ruleSetRepairPlan(text: combinedText, missingName: name, coreInvisibleNames: invisible ? [name] : [])
            items.append(RuleSetRepairItem(missingName: name, kind: plan.kind, previewLines: plan.previewLines))
            if let newText = plan.newText { combinedText = newText }
        }
        // Bake-source names (v0.2.58): their rule lives in the
        // custom subscription baked into this profile. Confirm
        // removes those rules from the subscription
        // (removeBakedRuleSetRules), so they must not count as
        // "still missing" in the re-check below — and a name with
        // no line in the file at all (rule only in the
        // subscription) is unrepairable as a file edit, but
        // repairable as a store removal: offer it as a delete of
        // the subscription's rule lines.
        let bakeSources = bakeSourceInfo(for: profile, missing: allMissing)
        let bakeSourceNames = Set(bakeSources.map { $0.name })
        for (index, item) in items.enumerated() where bakeSourceNames.contains(item.missingName) {
            if case .unrepairable = item.kind,
               bakeSources.contains(where: { $0.name == item.missingName }) {
                items[index] = RuleSetRepairItem(
                    missingName: item.missingName,
                    kind: .delete(ruleCount: deletedLines[item.missingName]?.count ?? 0),
                    previewLines: deletedLines[item.missingName] ?? [])
            }
        }
        // Re-check the combined text: completions add new provider
        // definitions, so the result must be checked again before
        // it is offered for writing. The verdict is TEXTUAL —
        // config.validate only parses YAML and cannot see a
        // missing rule-set — on the simulated post-confirm bytes
        // (baked, minus the bake-source lines confirm deletes
        // from the subscription). A parse check runs alongside it
        // (a completion that broke the YAML must still be caught).
        // Any failure falls back to the all-deleted candidate.
        var fellBackToDeleteAll = false
        var finalText: String? = combinedText
        var blockingIssue = collected.blockingIssue
        func applyDeleteAllFallback(reason: String) {
            fellBackToDeleteAll = true
            finalText = finalCandidate
            blockingIssue = reason
            items = items.map { item in
                if case .complete = item.kind,
                   let deleted = deletedLines[item.missingName], !deleted.isEmpty {
                    return RuleSetRepairItem(missingName: item.missingName, kind: .delete(ruleCount: deleted.count), previewLines: deleted)
                }
                return item
            }
        }
        do {
            let parseIssues = try await validateCandidateText(combinedText, for: profile)
            if let first = parseIssues.first {
                applyDeleteAllFallback(reason: "补全的定义未通过校验（\(first.message)），已改为删除全部引用规则")
            } else {
                let bakedCombined = String(data: reapplyLocalOverrides(to: Data(combinedText.utf8), for: profile), encoding: .utf8) ?? combinedText
                var simulatedLines = bakedCombined.components(separatedBy: "\n")
                if let rulesSection = Self.topLevelSection(named: "rules", in: simulatedLines), !rulesSection.isFlowStyle {
                    var drop = Set<Int>()
                    for name in bakeSourceNames {
                        drop.formUnion(Self.ruleSetRuleLineIndices(in: simulatedLines, section: rulesSection, missingName: name))
                    }
                    for index in drop.sorted().reversed() { simulatedLines.remove(at: index) }
                }
                let remaining = Self.missingRuleSetNames(in: simulatedLines.joined(separator: "\n"))
                if !remaining.isEmpty {
                    let remainingNames = remaining.map { "「\($0)」" }.joined(separator: "、")
                    applyDeleteAllFallback(reason: "修复后仍缺失规则集\(remainingNames)，已改为删除全部引用规则")
                }
            }
        } catch {
            applyDeleteAllFallback(reason: "修复后校验失败（\(error.localizedDescription)），已改为删除全部引用规则")
        }
        let names = allMissing.map { "「\($0)」" }.joined(separator: "、")
        // An invisible set is NOT "未定义" — the definition is
        // in the text, the core just cannot load it — so the
        // summary must not call it undefined, or the sheet
        // contradicts what the user sees in their own file.
        var summary: String
        if invisibleNames.count == allMissing.count {
            summary = "核心拒绝配置，因为核心加载不到规则集\(names)：订阅里虽然写了它的定义，但链接失效、内容无效或拉取失败时核心认不到它，删掉引用它的规则后配置才能生效。下面是一次修复全部的方案。"
        } else if !invisibleNames.isEmpty {
            let missingBits = allMissing.filter { !invisibleNames.contains($0) }.map { "「\($0)」" }.joined(separator: "、")
            let invisibleBits = invisibleNames.map { "「\($0)」" }.joined(separator: "、")
            summary = "核心拒绝配置：规则引用了未定义的规则集\(missingBits)，且核心加载不到\(invisibleBits)（订阅里有定义，链接失效、内容无效或拉取失败都有可能，对它只删引用、不补定义）。核心一次只报第一个，下面的列表是按规则文本收集到的全部缺失项，一次修复全部。"
        } else if allMissing.count == 1 {
            summary = "核心拒绝配置，因为规则引用了未定义的规则集\(names)。下面是按规则文本收集到的全部缺失项，一次修复全部。"
        } else {
            summary = "核心拒绝配置，因为规则引用了 \(allMissing.count) 个未定义的规则集（\(names)）。核心一次只报第一个，下面的列表是按规则文本收集到的全部缺失项，一次修复全部。"
        }
        if !bakeSources.isEmpty {
            let bits = bakeSources.map { "「\($0.name)」来自自定义订阅「\($0.subscriptionName)」" }.joined(separator: "、")
            summary += "其中\(bits)：确认后将同时从该订阅里删除这条规则，否则下次切换或更新订阅时会把它重新补回来。"
        }
        return RuleSetRepairAllPlan(
            profileName: profile.name,
            items: items,
            newText: finalText,
            summary: summary,
            blockingIssue: blockingIssue,
            fellBackToDeleteAll: fellBackToDeleteAll)
    }

    /// Pure core: completion first, delete fallback,
    /// unrepairable last. Line-based; the rest of the file is
    /// preserved byte-for-byte. `coreInvisibleNames` (v0.2.49)
    /// names the sets the CORE reports missing even though the
    /// text defines them (the TikTok paradox: the sheet used to
    /// claim "已在 rule-providers 中定义" while the core said
    /// "not found" — one of the two checks was wrong, and the
    /// core's verdict governs): for those, completion is not
    /// offered at all — adding a second definition would only
    /// create a duplicate key — the plan deletes the referencing
    /// rules and says plainly that the core does not recognise
    /// the existing definition.
    static func ruleSetRepairPlan(text: String, missingName: String, coreInvisibleNames: Set<String> = []) -> RuleSetRepairPlan {
        let lines = text.components(separatedBy: "\n")
        // --- Completion ---
        var completionBlocker: String? = nil
        if let section = topLevelSection(named: "rule-providers", in: lines) {
            if section.isFlowStyle {
                completionBlocker = "rule-providers 是单行 flow 写法，无法安全补全"
            } else {
                let entries = ruleProviderEntries(in: lines, section: section)
                if entries.contains(where: { $0.name == missingName }) {
                    if coreInvisibleNames.contains(missingName) {
                        completionBlocker = "「\(missingName)」在 rule-providers 里有一条，但核心加载不到它（链接失效、内容无效或拉取失败），无法通过补全修复"
                    } else {
                        completionBlocker = "「\(missingName)」已在 rule-providers 中定义，无法再补全"
                    }
                } else if entries.isEmpty {
                    completionBlocker = "rule-providers 一节是空的，没有可参照的提供方"
                } else {
                    let pool = entries.filter { !$0.fieldLines.isEmpty }
                    if pool.isEmpty {
                        completionBlocker = "现有的提供方都没有字段，无法推断定义"
                    } else {
                        var groups: [String: [RuleProviderEntry]] = [:]
                        for entry in pool {
                            groups[templateKey(for: entry.fields, name: entry.name), default: []].append(entry)
                        }
                        if let winners = groups.values.max(by: { $0.count < $1.count }),
                           winners.count * 2 > pool.count,
                           let template = winners.first {
                            let headerLine = lines[template.headerIndex]
                                .replacingOccurrences(of: template.name, with: missingName)
                            let fieldLines = template.fieldLines.map { raw -> String in
                                // Substitute only in the value part
                                // (after the first colon): a key never
                                // holds the provider name, and a nested
                                // list item without a colon is left
                                // untouched rather than guessed at.
                                guard let colon = raw.firstIndex(of: ":") else { return raw }
                                let prefix = raw[..<colon]
                                let valuePart = raw[raw.index(after: colon)...]
                                return String(prefix) + ":" + valuePart.replacingOccurrences(of: template.name, with: missingName)
                            }
                            let blockLines = [headerLine] + fieldLines
                            var newLines = lines
                            let insertAt = entries.last?.endIndex ?? section.endIndex
                            newLines.insert(contentsOf: blockLines, at: insertAt)
                            let behavior = template.fields["behavior"] ?? ""
                            let behaviorNote = behavior.isEmpty ? "" : "（相同的 \(behavior) 模板）"
                            return RuleSetRepairPlan(
                                missingName: missingName,
                                kind: .complete(templateProvider: template.name, siblingCount: winners.count),
                                previewLines: blockLines,
                                newText: newLines.joined(separator: "\n"),
                                summary: "核心拒绝配置，因为规则引用了未定义的规则集「\(missingName)」。「\(template.name)」等 \(winners.count) 个同类提供方使用相同的地址模板\(behaviorNote)，已据此推断出定义。")
                        } else {
                            completionBlocker = "现有的 \(pool.count) 个提供方没有形成多数共识的地址模板（各用各的地址），无法推断「\(missingName)」的定义"
                        }
                    }
                }
            }
        } else {
            completionBlocker = "配置文件里没有 rule-providers 一节"
        }
        // --- Delete fallback ---
        let blockerPrefix = completionBlocker ?? "无法推断「\(missingName)」的定义"
        if let rulesSection = topLevelSection(named: "rules", in: lines) {
            if rulesSection.isFlowStyle {
                return RuleSetRepairPlan(
                    missingName: missingName, kind: .unrepairable, previewLines: [], newText: nil,
                    summary: "\(blockerPrefix)；且 rules 是单行 flow 写法，无法安全删除引用它的规则。请在配置编辑页手动处理。")
            }
            let matched = ruleSetRuleLineIndices(in: lines, section: rulesSection, missingName: missingName)
            if !matched.isEmpty {
                var newLines = lines
                for index in matched.reversed() { newLines.remove(at: index) }
                return RuleSetRepairPlan(
                    missingName: missingName,
                    kind: .delete(ruleCount: matched.count),
                    previewLines: matched.map { lines[$0] },
                    newText: newLines.joined(separator: "\n"),
                    summary: "\(blockerPrefix)，改为删除引用「\(missingName)」的 \(matched.count) 条规则。")
            }
            return RuleSetRepairPlan(
                missingName: missingName, kind: .unrepairable, previewLines: [], newText: nil,
                summary: "\(blockerPrefix)；且 rules 里没有引用「\(missingName)」的 RULE-SET 规则行，无从删除。请在配置编辑页手动处理。")
        }
        return RuleSetRepairPlan(
            missingName: missingName, kind: .unrepairable, previewLines: [], newText: nil,
            summary: "\(blockerPrefix)；且配置文件里没有 rules 一节。请在配置编辑页手动处理。")
    }

    /// One top-level `name:` section: its header line, the line
    /// just past it, and whether the header line itself carries
    /// a value (flow style — not safely editable line-by-line).
    private struct TopLevelSection {
        let headerIndex: Int
        let endIndex: Int
        let isFlowStyle: Bool
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    private static func topLevelSection(named name: String, in lines: [String]) -> TopLevelSection? {
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            guard indent(of: line) == 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // A same-named key with more text after the colon
            // (e.g. `rule-providers-extra:`) is not this section.
            guard trimmed == "\(name):" || trimmed.hasPrefix("\(name): ") || trimmed.hasPrefix("\(name):\t") else { continue }
            let rest = String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            let isFlow = !rest.isEmpty && !rest.hasPrefix("#")
            var end = lines.count
            for j in (index + 1)..<lines.count {
                let next = lines[j].replacingOccurrences(of: "\r", with: "")
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("#") { continue }
                if indent(of: next) == 0 { end = j; break }
            }
            return TopLevelSection(headerIndex: index, endIndex: end, isFlowStyle: isFlow)
        }
        return nil
    }

    /// One mapping-style `rule-providers:` entry: its `  Name:`
    /// header plus its deeper field lines, in file order.
    private struct RuleProviderEntry {
        let name: String
        let headerIndex: Int
        let fieldLines: [String]
        /// Index just past the last field line.
        let endIndex: Int
        let fields: [String: String]
        let headerIndent: Int
    }

    private static func ruleProviderEntries(in lines: [String], section: TopLevelSection) -> [RuleProviderEntry] {
        var entries: [RuleProviderEntry] = []
        var currentName: String? = nil
        var currentHeaderIndex = -1
        var currentHeaderIndent = 2
        var currentFields: [(lineIndex: Int, raw: String)] = []
        func flush() {
            guard let name = currentName else { return }
            var fields: [String: String] = [:]
            for pair in currentFields.compactMap({ yamlKeyValue($0.raw.trimmingCharacters(in: .whitespaces)) }) {
                if fields[pair.key] == nil { fields[pair.key] = pair.value }
            }
            let endIndex = currentFields.last.map { $0.lineIndex + 1 } ?? (currentHeaderIndex + 1)
            entries.append(RuleProviderEntry(
                name: name, headerIndex: currentHeaderIndex,
                fieldLines: currentFields.map(\.raw), endIndex: endIndex,
                fields: fields, headerIndent: currentHeaderIndent))
            currentName = nil
            currentFields = []
        }
        for index in (section.headerIndex + 1)..<section.endIndex {
            let raw = lines[index]
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let lineIndent = indent(of: line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if currentName == nil {
                // First header sets the section's header indent;
                // a header is an indent->0 line ending in ":".
                if lineIndent > 0, trimmed.hasSuffix(":"), !trimmed.hasPrefix("- ") {
                    currentName = unquote(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
                    currentHeaderIndex = index
                    currentHeaderIndent = lineIndent
                }
                continue
            }
            if lineIndent == currentHeaderIndent, trimmed.hasSuffix(":"), !trimmed.hasPrefix("- ") {
                flush()
                currentName = unquote(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
                currentHeaderIndex = index
                continue
            }
            if lineIndent > currentHeaderIndent {
                currentFields.append((lineIndex: index, raw: raw))
            }
            // A stray line at/below the header indent that is not
            // a header is ignored, never treated as a field.
        }
        flush()
        return entries
    }

    /// (behavior, URL template, path template, interval) with the
    /// sibling's own name replaced by a placeholder in the
    /// name-bearing values, so siblings that differ only by name
    /// group together.
    private static func templateKey(for fields: [String: String], name: String) -> String {
        func templated(_ value: String) -> String {
            value.replacingOccurrences(of: name, with: "§")
        }
        return [
            templated(fields["behavior"] ?? ""),
            templated(fields["url"] ?? ""),
            templated(fields["path"] ?? ""),
            fields["interval"] ?? "",
        ].joined(separator: "\n")
    }

    /// The rule-set name on one `rules:` line, when the line is
    /// a RULE-SET rule (`- RULE-SET,<name>,…`, quoted or not).
    /// Nil otherwise. Shared by the line matcher below and the
    /// reference scanner (missingRuleSetNames) so the two can
    /// never drift apart: the name is exactly the second comma
    /// field, compared exactly.
    private static func ruleSetNameOnLine(_ rawLine: String) -> String? {
        let trimmed = rawLine.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed == "-" else { return nil }
        var rest = trimmed == "-" ? "" : String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if (rest.hasPrefix("\"") && rest.hasSuffix("\"") && rest.count >= 2) ||
            (rest.hasPrefix("'") && rest.hasSuffix("'") && rest.count >= 2) {
            rest = String(rest.dropFirst().dropLast())
        }
        let fields = rest.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2,
              fields[0].uppercased() == "RULE-SET" else { return nil }
        let name = fields[1]
        return name.isEmpty ? nil : name
    }

    /// Every rule-set name referenced by `rules:` in `text`, in
    /// first-reference order, deduped. A flow-style `rules:` line
    /// yields nothing (it is not safely editable line-by-line).
    private static func referencedRuleSetNames(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let section = topLevelSection(named: "rules", in: lines), !section.isFlowStyle else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for index in (section.headerIndex + 1)..<section.endIndex {
            guard let name = ruleSetNameOnLine(lines[index]), !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
    }

    /// Rule-set names referenced by `rules:` but never defined in
    /// `rule-providers:` — the missing sets, by pure text
    /// (v0.2.58). `text` must be the BAKED bytes (what the core
    /// applies): a reference re-inserted by a baked custom
    /// subscription counts, and a provider defined only in a
    /// baked block counts as defined.
    private static func missingRuleSetNames(in text: String) -> [String] {
        let defined = definedRuleProviderNames(in: text)
        return referencedRuleSetNames(in: text).filter { !defined.contains($0) }
    }

    /// Rule-provider names defined in `rule-providers:` in `text`
    /// (mapping-style entries; a flow-style section yields none).
    private static func definedRuleProviderNames(in text: String) -> Set<String> {
        let lines = text.components(separatedBy: "\n")
        guard let section = topLevelSection(named: "rule-providers", in: lines), !section.isFlowStyle else { return [] }
        return Set(ruleProviderEntries(in: lines, section: section).map { $0.name })
    }

    /// Indices of the `rules:` lines that reference the missing
    /// set: `- RULE-SET,<name>,…` block lines and quoted lines
    /// (`- 'RULE-SET,<name>,…'` / `- "…"`). The name must match
    /// exactly as the second comma field.
    private static func ruleSetRuleLineIndices(in lines: [String], section: TopLevelSection, missingName: String) -> [Int] {
        var matched: [Int] = []
        for index in (section.headerIndex + 1)..<section.endIndex {
            if ruleSetNameOnLine(lines[index]) == missingName { matched.append(index) }
        }
        return matched
    }

    // MARK: Activate + inspect (config.validate / config.apply /
    // profile.inspect)

    @MainActor
    func activate(_ profile: Profile) async {
        // The override framework keys per-profile overrides off the
        // active profile: record the switch before anything applies,
        // so the extension's config.apply merge already sees it.
        OverrideStore.noteActiveProfile(profile.id)
        guard let source = fileURL(for: profile),
              let data = try? Data(contentsOf: source) else {
            // The sample profile has no file on disk.
            if client.mode == .live {
                lastError = "该订阅没有本地文件：请先点「更新」重新下载，或重新导入"
                return
            }
            do {
                let result = try await client.configApply(profilePath: nil)
                applyWarnings = result.warnings
                markActive(profile)
                statusMessage = "已切换到 \(profile.name)（示例数据）"
                lastError = nil
            } catch {
                lastError = "切换失败：\(error.localizedDescription)"
            }
            return
        }
        await applyProfile(profile, data: data)
    }

    /// Validates, copies and applies one profile's YAML. Used by both
    /// activate and update (of the active profile). Switching to a
    /// profile re-bakes its local overrides first (B10): a profile
    /// whose custom-subscription blocks were wiped by an earlier
    /// update gets them back from the store / its on-disk file.
    @MainActor
    private func applyProfile(_ profile: Profile, data: Data) async {
        // An age-encrypted file is not a config yet: point at the
        // key + 更新 instead of a generic parse error.
        if Self.looksAgeEncrypted(data) {
            lastError = "切换失败：该订阅是 age 加密的，请先在编辑页填写 age 私钥并点「更新」解密"
            return
        }
        let data = reapplyLocalOverrides(to: data, for: profile)
        if let problem = Self.localSanityCheck(data) {
            lastError = "切换失败：\(problem)"
            return
        }
        guard let absolutePath = absolutePath(for: profile),
              let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
                .appendingPathComponent(ConfigStore.configFileName) else {
            lastError = "App Group 容器不可用，请检查 entitlements 与 App Group 配置"
            return
        }
        let tunnelRunning = TunnelManager.shared.isRunning
        // 1. Validate with the core while it is reachable. A parse error
        // aborts the switch before the broken file replaces the active
        // config. When the tunnel is stopped the core is unreachable;
        // the extension validates again at the next VPN start.
        if client.mode == .live, tunnelRunning {
            do {
                let issues = try await client.configValidate(profilePath: absolutePath)
                if !issues.isEmpty {
                    validationIssues = issues
                    lastError = "配置校验未通过：\(issues[0].message)"
                    return
                }
                validationIssues = []
            } catch {
                // Validation unavailable (core busy, IPC hiccup): proceed
                // — config.apply below reports the real error, if any.
            }
        }
        // 2. Copy to the shared config.yaml: this is what the extension
        // reads at startTunnel, so the switch takes effect at the next
        // VPN start even when the tunnel is stopped right now.
        do {
            try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: shared, options: .atomic)
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
            return
        }
        // 2b. Recompute the merged module files against the new
        // shared config.yaml (profileDigest + merged profile
        // providers). This hook only rewrites the file — it does NOT
        // apply live, so the step-3 apply below is still the single
        // live apply (no double config.apply).
        await onProfileApplied?()
        // 3. Apply live when the tunnel is running, so the switch takes
        // effect without a VPN restart.
        if client.mode == .live, tunnelRunning {
            do {
                let result = try await client.configApply(profilePath: absolutePath)
                applyWarnings = result.warnings
                inspect = try await client.profileInspect(path: absolutePath)
                markActive(profile)
                statusMessage = "已切换到 \(profile.name)（已立即生效）"
                lastError = nil
                await closeAllConnectionsIfNeeded()
            } catch {
                lastError = "切换失败：\(error.localizedDescription)（文件已复制，下次启动 VPN 时会使用新配置）"
            }
            return
        }
        if client.mode == .sample {
            // Sample transport: apply + inspect against the mock core.
            do {
                let result = try await client.configApply(profilePath: absolutePath)
                applyWarnings = result.warnings
                inspect = try await client.profileInspect(path: absolutePath)
            } catch {
                // The mock never throws; ignore.
            }
        }
        inspect = client.mode == .live ? nil : inspect
        markActive(profile)
        statusMessage = "已切换到 \(profile.name)（下次启动 VPN 时生效）"
        lastError = nil
    }

    /// Close every live connection (connection.closeAll) when
    /// 自动关闭连接 is on. Called after a profile switch that took
    /// effect live.
    @MainActor
    private func closeAllConnectionsIfNeeded() async {
        guard autoCloseConnections, client.mode == .live, TunnelManager.shared.isRunning else { return }
        try? await client.connectionCloseAll()
    }

    /// Re-bake the user's local additions into freshly downloaded
    /// (or newly switched-to) profile data, so a subscription
    /// update never silently drops them:
    ///  - form + raw custom proxies (CustomProxyStore, global)
    ///  - per-group filter overrides (global)
    ///  - custom-subscription blocks (groups / providers / rules /
    ///    dialers): the store is the source of truth, found through
    ///    the bake map (which custom subscription was last applied
    ///    to this profile); when there is no map entry, the blocks
    ///    already in this profile's on-disk file are carried over
    ///    verbatim, so bakes made before the map existed survive.
    /// Baking is idempotent (markers are removed before re-insert),
    /// so calling it twice on the same text is safe.
    func reapplyLocalOverrides(to data: Data, for profile: Profile) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        var result = CustomProxyStore.bakeCurrent(into: text)
        let store = CustomProxyStore()
        result = CustomProxyStore.bakeFilterOverrides(store.filterOverrides, into: result)
        let customStore = CustomSubscriptionStore()
        if let subID = CustomSubscriptionStore.bakedSubscriptionID(for: profile.id) {
            if let sub = customStore.subscriptions.first(where: { $0.id == subID }) {
                result = CustomSubscriptionStore.bake(sub, into: result)
            } else {
                // The mapped custom subscription was deleted: drop
                // the stale mapping, but keep whatever blocks the
                // profile file already has (deleting the list entry
                // alone must never wipe a profile's baked content).
                CustomSubscriptionStore.clearBakedSubscription(for: profile.id)
                if let oldText = oldProfileText(for: profile) {
                    result = CustomSubscriptionStore.reapplyBakedBlocks(from: oldText, into: result)
                }
            }
        } else if let oldText = oldProfileText(for: profile) {
            result = CustomSubscriptionStore.reapplyBakedBlocks(from: oldText, into: result)
        }
        return result.data(using: .utf8) ?? data
    }

    /// The active profile's current built bytes — the exact bytes
    /// applyProfile writes to the shared config.yaml: the profile
    /// file on disk with local overrides re-baked (custom proxies,
    /// filter overrides, custom-subscription blocks). AppCore's
    /// FIX 2 stale-config heal compares the shared file against
    /// these bytes. Nil when there is no active profile, no file
    /// on disk, or the file cannot be applied as-is: an
    /// age-encrypted file (applyProfile refuses it too) or one
    /// that fails the local sanity check — the caller then keeps
    /// the existing shared config and the boot proceeds as before.
    func builtActiveProfileData() -> (profile: Profile, data: Data)? {
        guard let profile = activeProfile,
              let url = fileURL(for: profile),
              let data = try? Data(contentsOf: url) else { return nil }
        if Self.looksAgeEncrypted(data) { return nil }
        let built = reapplyLocalOverrides(to: data, for: profile)
        guard Self.localSanityCheck(built) == nil else { return nil }
        return (profile, built)
    }

    /// The profile's current on-disk YAML text, if it has a file.
    private func oldProfileText(for profile: Profile) -> String? {
        guard let url = fileURL(for: profile) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Re-applies the active profile live (config.apply with no
    /// overlay — the extension merges the fresh mitm.json /
    /// module-mitm.json / dns.json overlays). Used when something
    /// other than a profile switch changes what the core should
    /// receive, e.g. a MITM module toggle. Returns a message to show,
    /// or nil when the tunnel is stopped: the files are already
    /// written, so the change takes effect at the next VPN start.
    @MainActor
    func reapplyActive() async -> String? {
        guard client.mode == .live, TunnelManager.shared.isRunning,
              let profile = activeProfile, let path = absolutePath(for: profile) else {
            return nil
        }
        do {
            let result = try await client.configApply(profilePath: path)
            applyWarnings = result.warnings
            return "已重新应用（含模块改动）"
        } catch {
            return "重新应用失败：\(error.localizedDescription)（文件已保存，下次启动 VPN 时生效）"
        }
    }

    private func markActive(_ profile: Profile) {
        for index in profiles.indices {
            profiles[index].isActive = profiles[index].id == profile.id
        }
        save()
    }

    /// Re-read the profile list from UserDefaults (used after a
    /// backup restore so the page shows the restored profiles
    /// without restarting the app).
    func reload() {
        load()
        seedSampleIfNeeded()
    }

    // MARK: Config editor (ConfigEditorView)

    /// The active profile's YAML text, if it has a file.
    func activeProfileYAML() -> String? {
        guard let profile = activeProfile, let url = fileURL(for: profile) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The editor's local sanity check (same bar as import): the text
    /// must be non-empty UTF-8 and look like a Clash / mihomo
    /// document at all. Returns the problem, or nil when it passes.
    static func localSanityCheckText(_ text: String) -> String? {
        localSanityCheck(Data(text.utf8))
    }

    /// Validates edited YAML with the core (config.validate). The
    /// text goes to a temporary file inside the App Group — the core
    /// reads it with a plain fs::read in the extension process, so a
    /// path in the app's own tmp would be invisible to it. The temp
    /// file is deleted on return. Only call when live + tunnel
    /// running; otherwise the core is unreachable.
    @MainActor
    func validateYAMLText(_ text: String) async throws -> [ConcordIssue] {
        guard let dir = profilesDirectory else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        let tempURL = dir.appendingPathComponent(".editor-validate.yaml")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: tempURL, atomically: true, encoding: .utf8)
        return try await client.configValidate(profilePath: tempURL.path)
    }

    /// Saves edited YAML over the active profile's file AND the
    /// shared config.yaml, then re-applies live when the tunnel is
    /// running. Call only after validation (see ConfigEditorView).
    /// Returns a message for the editor to show.
    @MainActor
    func saveActiveProfileYAML(_ text: String) async -> String {
        guard let profile = activeProfile, let url = fileURL(for: profile) else {
            return "没有已激活的订阅，无法保存"
        }
        guard let data = text.data(using: .utf8) else {
            return "配置不是有效的 UTF-8 文本"
        }
        do {
            try saveProfileFile(profile: profile, data: data)
            if let shared = ConfigStore.sharedFileURL(name: ConfigStore.configFileName) {
                try FileManager.default.createDirectory(
                    at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: shared, options: .atomic)
            }
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
        if client.mode == .live, TunnelManager.shared.isRunning {
            do {
                let result = try await client.configApply(profilePath: absolutePath(for: profile))
                applyWarnings = result.warnings
                return "已保存并立即应用到核心"
            } catch {
                return "已保存到文件，但实时应用失败：\(error.localizedDescription)（下次启动 VPN 时生效）"
            }
        }
        return "已保存，下次启动 VPN 时生效"
    }

    private func saveProfileFile(profile: Profile, data: Data) throws {
        guard let dir = profilesDirectory, let url = fileURL(for: profile) else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Preview helpers (profile.build / convert.subscription /
    // config.read + validate.proxies)

    /// The merged effective config text (profile.build).
    @MainActor
    func buildProfileText(_ profile: Profile) async -> Result<String, Error> {
        guard let absolutePath = absolutePath(for: profile) else {
            return .failure(NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "该订阅没有本地文件"]))
        }
        do {
            return .success(try await client.profileBuild(profilePath: absolutePath))
        } catch {
            return .failure(error)
        }
    }

    /// The node list a profile actually yields (convert.subscription).
    @MainActor
    func convertProfile(_ profile: Profile) async -> Result<[JSONValue], Error> {
        guard let absolutePath = absolutePath(for: profile) else {
            return .failure(NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "该订阅没有本地文件"]))
        }
        do {
            return .success(try await client.convertSubscription(profilePath: absolutePath))
        } catch {
            return .failure(error)
        }
    }

    /// Validates the active profile's nodes (config.read +
    /// validate.proxies). Returns the issues, if any.
    @MainActor
    func validateActiveProfileProxies() async -> Result<[ConcordIssue], Error> {
        guard let profile = activeProfile,
              let absolutePath = absolutePath(for: profile) else {
            return .failure(NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有已激活的订阅"]))
        }
        do {
            let config = try await client.configRead(profilePath: absolutePath)
            guard let proxies = config.config.objectValue?["proxies"]?.arrayValue else {
                return .failure(NSError(domain: "ConcordiOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "配置里没有 proxies"]))
            }
            return .success(try await client.validateProxies(proxies: proxies))
        } catch {
            return .failure(error)
        }
    }

    /// Validates the active profile file itself (config.validate).
    @MainActor
    func validateActiveProfile() async -> Result<[ConcordIssue], Error> {
        guard let profile = activeProfile,
              let absolutePath = absolutePath(for: profile) else {
            return .failure(NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有已激活的订阅"]))
        }
        do {
            return .success(try await client.configValidate(profilePath: absolutePath))
        } catch {
            return .failure(error)
        }
    }

    /// Extracts every proxy-group `filter:` expression from the active
    /// profile's effective config (config.read). No read API exposes
    /// filter lists directly, so they are derived from the config the
    /// core itself parsed: each pair is (group name, filter). An
    /// empty result just means this config has no group filters.
    @MainActor
    func extractActiveProfileFilters() async -> Result<[(group: String, filter: String)], Error> {
        guard let profile = activeProfile,
              let absolutePath = absolutePath(for: profile) else {
            return .failure(NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有已激活的订阅"]))
        }
        do {
            let config = try await client.configRead(profilePath: absolutePath)
            guard let groups = config.config.objectValue?["proxy-groups"]?.arrayValue else {
                return .success([])
            }
            var out: [(group: String, filter: String)] = []
            for group in groups {
                guard let obj = group.objectValue,
                      let name = obj["name"]?.stringValue,
                      let filter = obj["filter"]?.stringValue,
                      !filter.isEmpty else { continue }
                out.append((group: name, filter: filter))
            }
            return .success(out)
        } catch {
            return .failure(error)
        }
    }

    /// Decrypts an encrypted profile file with its key
    /// (config.decrypt). The key is passed for this one call and never
    /// stored; the plaintext is kept only in memory until the user
    /// saves it as a new profile. The core runs in the extension, so
    /// the tunnel must be running in live mode.
    @MainActor
    func decryptProfile(_ profile: Profile, key: String) async {
        guard let absolutePath = absolutePath(for: profile) else {
            decryptMessage = "该订阅没有本地文件"
            return
        }
        guard !key.isEmpty else {
            decryptMessage = "请先输入解密密钥"
            return
        }
        if client.mode == .live, !TunnelManager.shared.isRunning {
            decryptMessage = "需先启动 VPN：解密由扩展内的核心执行"
            return
        }
        do {
            decryptResult = try await client.configDecrypt(profilePath: absolutePath, key: key)
            decryptMessage = decryptResult?.isEmpty == true ? "解密结果为空" : "解密成功，可另存为新订阅"
            lastError = nil
        } catch {
            decryptResult = nil
            decryptMessage = "解密失败：\(error.localizedDescription)"
        }
    }

    /// Saves the last decrypted text as a new local profile. The
    /// decrypted text is a plain Clash / mihomo YAML document, so it
    /// goes through the same sanity check as any other import.
    @MainActor
    func saveDecryptedAsProfile(name: String) {
        guard let text = decryptResult, !text.isEmpty else { return }
        addFromFile(name: name, data: Data(text.utf8))
        decryptResult = nil
        decryptMessage = "已保存为新订阅「\(name)」"
    }

    // MARK: - Remaining APIs, batch 2 (profile.outbounds /
    // clearEffect, convert.encodeLinks / decodeLinks)

    /// Lists the outbounds (proxies + proxy-groups) a profile
    /// declares (profile.outbounds). The core runs in the extension,
    /// so the tunnel must be running in live mode.
    @MainActor
    func loadOutbounds(_ profile: Profile) async {
        guard let absolutePath = absolutePath(for: profile) else {
            outboundsMessage = "该订阅没有本地文件"
            return
        }
        if client.mode == .live, !TunnelManager.shared.isRunning {
            outboundsMessage = "需先启动 VPN：出站列表由扩展内的核心读取"
            return
        }
        do {
            outbounds = try await client.profileOutbounds(profilePath: absolutePath)
            outboundsMessage = nil
            lastError = nil
        } catch {
            outbounds = nil
            outboundsMessage = "读取出站列表失败：\(error.localizedDescription)"
        }
    }

    /// Clears the downloaded provider files of one core-side profile
    /// (profile.clearEffect). `profileId` is the numeric id the host
    /// assigned that profile — the app never assigns numeric ids and
    /// the core keeps its own provider downloads under `providers/`,
    /// so on iOS this usually finds nothing to clear. The call
    /// itself is the real upstream method.
    @MainActor
    func clearEffect(profileId: Int64) async {
        if client.mode == .live, !TunnelManager.shared.isRunning {
            clearEffectMessage = "需先启动 VPN：清除操作由扩展内的核心执行"
            return
        }
        do {
            try await client.profileClearEffect(profileId: profileId)
            clearEffectMessage = "已清除订阅 #\(profileId) 的已下载提供方文件（若无此订阅则无事可做）"
            lastError = nil
        } catch {
            clearEffectMessage = "清除失败：\(error.localizedDescription)"
        }
    }

    /// Encodes the profile's proxies into share links
    /// (convert.encodeLinks). The links are built from the effective
    /// config's `proxies` list (config.read), so the profile must be
    /// readable by the core.
    @MainActor
    func encodeLinks(_ profile: Profile) async {
        guard let absolutePath = absolutePath(for: profile) else {
            encodeMessage = "该订阅没有本地文件"
            return
        }
        if client.mode == .live, !TunnelManager.shared.isRunning {
            encodeMessage = "需先启动 VPN：分享链接由扩展内的核心生成"
            return
        }
        do {
            let read = try await client.configRead(profilePath: absolutePath)
            let proxies = read.config.objectValue?["proxies"]?.arrayValue ?? []
            encodedLinks = try await client.convertEncodeLinks(proxies: proxies)
            encodeMessage = encodedLinks.isEmpty ? "该订阅没有可分享的节点" : nil
            lastError = nil
        } catch {
            encodedLinks = []
            encodeMessage = "生成分享链接失败：\(error.localizedDescription)"
        }
    }

    /// Decodes pasted share links into proxy definitions
    /// (convert.decodeLinks). The pasted lines are only sent to the
    /// core for decoding — nowhere else. Decoded nodes can be saved
    /// as a new local profile via `saveDecodedAsProfile`.
    @MainActor
    func decodeLinks(_ lines: [String]) async {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else {
            decodeMessage = "请先粘贴至少一行分享链接"
            return
        }
        if client.mode == .live, !TunnelManager.shared.isRunning {
            decodeMessage = "需先启动 VPN：链接解析由扩展内的核心执行"
            return
        }
        do {
            decodedResults = try await client.convertDecodeLinks(lines: trimmed)
            decodedProxies = decodedResults.flatMap { $0 }
            decodeMessage = decodedProxies.isEmpty ? "没有解析出任何节点（请检查链接格式）" : nil
            lastError = nil
        } catch {
            decodedResults = []
            decodedProxies = []
            decodeMessage = "解析链接失败：\(error.localizedDescription)"
        }
    }

    /// Saves the decoded proxies as a new local profile YAML file
    /// (through the same sanity check as any other import).
    @MainActor
    func saveDecodedAsProfile(name: String) {
        guard !decodedProxies.isEmpty else { return }
        let yaml = "proxies:\n" + decodedProxies.map { "  - " + jsonValueToYaml($0, indent: 4) }.joined(separator: "\n") + "\n"
        let fileName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "导入的节点" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        addFromFile(name: fileName, data: Data(yaml.utf8))
        if lastError == nil {
            decodeMessage = "已保存为新订阅「\(fileName)」"
        }
    }

    /// Minimal JSON → YAML rendering for one decoded proxy mapping.
    /// Nested mappings are indented; arrays become `- item` lines.
    /// Values are quoted when they need it (strings containing
    /// YAML-significant characters), numbers/bools are bare.
    private func jsonValueToYaml(_ value: JSONValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return "\(i)"
        case .double(let d):
            return "\(d)"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "\n" + items.map { "\(pad)- \(jsonValueToYaml($0, indent: indent + 2))" }.joined(separator: "\n")
        case .string(let s):
            return yamlQuoted(s)
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            return "\n" + dict.sorted(by: { $0.key < $1.key }).map { key, val in
                "\(pad)\(key): \(jsonValueToYaml(val, indent: indent + 2))"
            }.joined(separator: "\n")
        }
    }

    private func yamlQuoted(_ string: String) -> String {
        let needsQuotes = string.isEmpty
            || string.contains(": ") || string.contains(" #")
            || string.hasPrefix("-") || string.hasPrefix("#")
            || string.hasPrefix("[") || string.hasPrefix("{")
            || string.contains("\n")
            || Double(string) != nil
            || string == "true" || string == "false" || string == "null" || string == "~"
        guard needsQuotes else { return string }
        return "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Insecure certificate delegate (FlClash: 校验订阅证书 off)
// Trusts any server certificate for subscription downloads. Used
// only when the user turns 校验证书 off in 常规 — the default
// session (shared, system trust) is used otherwise.
private final class InsecureCertificateDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
