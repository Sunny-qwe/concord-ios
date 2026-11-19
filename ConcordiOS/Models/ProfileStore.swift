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

    init(id: UUID = UUID(), name: String, kind: ProfileKind, urlString: String? = nil, fileName: String? = nil, updatedAt: Date? = nil, isActive: Bool = false, note: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.urlString = urlString
        self.fileName = fileName
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.note = note
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
        URLSession(configuration: .default, delegate: InsecureCertificateDelegate(), delegateQueue: nil)
    }()

    private var subscriptionSession: URLSession {
        checkCertificate ? URLSession.shared : insecureSession
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
            Profile(name: "示例订阅", kind: .url, urlString: "https://example.com/subscribe.yaml", updatedAt: Date().addingTimeInterval(-3600), isActive: true, note: "示例数据：这是一条示例订阅，不是真实订阅")
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
            for line in linkLines {
                switch NodeLinkParser.parse(line) {
                case .success(let node): proxies.append(node.jsonValue)
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
            let note = "识别到 \(proxies.count) 个节点" + (failedCount > 0 ? "，\(failedCount) 行解析失败" : "")
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

    @MainActor
    func addFromURL(name: String, urlString: String) async {
        guard let url = URL(string: urlString) else {
            lastError = "订阅链接无效"
            return
        }
        do {
            let (data, _) = try await subscriptionSession.data(from: url)
            let normalized: (data: Data, note: String?)
            switch await normalizedSubscriptionData(data) {
            case .success(let value):
                normalized = value
            case .failure(let reason):
                lastError = "订阅内容异常：\(reason.message)"
                return
            }
            var profile = Profile(name: name.isEmpty ? url.host ?? "订阅" : name, kind: .url, urlString: urlString, updatedAt: Date())
            profiles.append(profile)
            try saveProfileFile(profile: profile, data: normalized.data)
            statusMessage = "已导入订阅 \(profile.name)" + (normalized.note.map { "（\($0)）" } ?? "")
            save()
            lastError = nil
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
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

    @MainActor
    func update(_ profile: Profile) async {
        guard let urlString = profile.urlString, let url = URL(string: urlString) else { return }
        do {
            let (downloaded, _) = try await subscriptionSession.data(from: url)
            let normalized: Data
            switch await normalizedSubscriptionData(downloaded) {
            case .success(let value):
                normalized = value.data
            case .failure(let reason):
                lastError = "更新 \(profile.name) 失败：订阅内容异常：\(reason.message)"
                return
            }
            // A fresh download would wipe the user's local additions
            // (custom proxies, filter overrides) that live baked into
            // the active profile's YAML: re-apply them before saving.
            let data = profile.isActive ? reapplyLocalOverrides(to: normalized) : normalized
            try saveProfileFile(profile: profile, data: data)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].updatedAt = Date()
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
            lastError = "更新 \(profile.name) 失败：\(error.localizedDescription)"
        }
    }

    func delete(_ profile: Profile) {
        if let url = fileURL(for: profile) {
            try? FileManager.default.removeItem(at: url)
        }
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    // MARK: Activate + inspect (config.validate / config.apply /
    // profile.inspect)

    @MainActor
    func activate(_ profile: Profile) async {
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
    /// activate and update (of the active profile).
    @MainActor
    private func applyProfile(_ profile: Profile, data: Data) async {
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

    /// Re-bake the user's local additions (custom proxies, filter
    /// overrides) into freshly downloaded profile data. Used when a
    /// subscription update replaces the active profile's file, so the
    /// update never silently drops them.
    func reapplyLocalOverrides(to data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        var result = CustomProxyStore.bakeCurrent(into: text)
        let store = CustomProxyStore()
        result = CustomProxyStore.bakeFilterOverrides(store.filterOverrides, into: result)
        return result.data(using: .utf8) ?? data
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
