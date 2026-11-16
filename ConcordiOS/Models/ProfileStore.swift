import Foundation
import Combine

// MARK: - Profile store (FlClash: Profiles page)
// A profile is a Clash/mihomo YAML subscription (remote URL) or a local
// file. Applying a profile = writing its YAML to the App Group shared
// config and calling Concord config.apply + profile.inspect.
// FlClash also supports "extend" / custom profiles; those are represented
// here as local files with a note, not as a separate editor.

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

    let client: ConcordClient
    private let storageKey = "ConcordiOS.profiles.v1"

    var activeProfile: Profile? {
        profiles.first { $0.isActive }
    }

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
        if profiles.isEmpty {
            profiles = [
                Profile(name: "示例订阅", kind: .url, urlString: "https://example.com/subscribe.yaml", updatedAt: Date().addingTimeInterval(-3600), isActive: true, note: "示例数据：这是一条示例订阅，不是真实订阅")
            ]
            save()
        }
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

    // MARK: Import / update / delete

    @MainActor
    func addFromURL(name: String, urlString: String) async {
        guard let url = URL(string: urlString) else {
            lastError = "订阅链接无效"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            try saveProfileFile(profile: profile, data: data)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].updatedAt = Date()
            }
            save()
            statusMessage = "已更新 \(profile.name)"
            lastError = nil
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

    // MARK: Activate + inspect (config.apply / profile.inspect)

    @MainActor
    func activate(_ profile: Profile) async {
        do {
            guard let source = fileURL(for: profile),
                  let data = try? Data(contentsOf: source),
                  let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
                    .appendingPathComponent(ConfigStore.configFileName) else {
                // Sample profile has no file on disk yet: apply by name only.
                let result = try await client.configApply(profilePath: nil)
                applyWarnings = result.warnings
                markActive(profile)
                statusMessage = "已切换到 \(profile.name)（示例数据）"
                return
            }
            try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: shared, options: .atomic)
            let result = try await client.configApply(profilePath: ConfigStore.configFileName)
            applyWarnings = result.warnings
            inspect = try await client.profileInspect(path: ConfigStore.configFileName)
            markActive(profile)
            statusMessage = "已切换到 \(profile.name)"
            lastError = nil
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
        }
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
}
