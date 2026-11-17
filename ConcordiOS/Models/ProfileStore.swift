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

    let client: ConcordClient
    private let storageKey = "ConcordiOS.profiles.v1"
    private var cancellables = Set<AnyCancellable>()

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

    // MARK: Import / update / delete

    @MainActor
    func addFromURL(name: String, urlString: String) async {
        guard let url = URL(string: urlString) else {
            lastError = "订阅链接无效"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let problem = Self.localSanityCheck(data) {
                lastError = "订阅内容异常：\(problem)"
                return
            }
            var profile = Profile(name: name.isEmpty ? url.host ?? "订阅" : name, kind: .url, urlString: urlString, updatedAt: Date())
            profiles.append(profile)
            try saveProfileFile(profile: profile, data: data)
            statusMessage = "已导入订阅 \(profile.name)"
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
            let (data, _) = try await URLSession.shared.data(from: url)
            if let problem = Self.localSanityCheck(data) {
                lastError = "更新 \(profile.name) 失败：订阅内容异常：\(problem)"
                return
            }
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

    private func markActive(_ profile: Profile) {
        for index in profiles.indices {
            profiles[index].isActive = profiles[index].id == profile.id
        }
        save()
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
}
