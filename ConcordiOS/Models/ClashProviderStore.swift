import Combine
import Foundation

// MARK: - Rule providers as app-level records (v0.2.148)
//
// Upstream (FlClash lib/models/common.dart ClashProvider,
// lib/database/clash_providers.dart): a rule provider with a URL
// is a ClashProvider record — id, label, url, behavior, format —
// whose downloaded content lives in a cache file named
// md5('$id@$url'). The custom subscription keeps its own
// CustomProvider entry (with the bake-time options); the record
// is the download/update unit, linked from the subscription by
// RuleProviderRef (clashProviderId). At bake time the record's
// content is confined under providers/<sub-id>/rules/.
//
// The core needs no compile step here: unlike upstream's
// compileRules (.mrs), Concord reads rule files directly
// (RuleSet::parse auto-detects the format), so the stored
// content is the downloaded bytes verbatim.

/// One rule provider record (upstream ClashProvider).
struct ClashProvider: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var url: String
    /// mihomo behavior: domain / ipcidr / classical. Nil = unset
    /// (the baked entry defaults to classical).
    var behavior: String?
    /// mihomo format: yaml / text / mrs. Nil = unset (the core
    /// auto-detects).
    var format: String?
    var updatedAt: Date?

    init(id: UUID = UUID(), label: String = "", url: String = "",
         behavior: String? = nil, format: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.url = url
        self.behavior = behavior
        self.format = format
        self.updatedAt = updatedAt
    }

    /// Upstream ClashProvider.fileName: '$id@$url'.toMd5() — the
    /// downloaded content's stable file name.
    var fileName: String {
        FlClashHash.md5Hex("\(id.uuidString)@\(url)")
    }
}

/// JSON store for ClashProvider records + their downloaded
/// content files. Same persistence pattern as
/// CustomSubscriptionStore (ConfigStore.sharedFileURL + atomic
/// JSON write); content files live beside it under
/// clash-providers/<fileName>.
final class ClashProviderStore: ObservableObject {
    @Published var providers: [ClashProvider] = []

    private static let fileName = "clash-providers.json"
    private static let contentDirectoryName = "clash-providers"
    private static let maxDownloadBytes = 2 * 1024 * 1024

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: Self.fileName)
    }

    /// The downloaded content file for one record.
    static func contentFileURL(for provider: ClashProvider) -> URL? {
        ConfigStore.sharedFileURL(name: "\(contentDirectoryName)/\(provider.fileName)")
    }

    init() { load() }

    func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ClashProvider].self, from: data) else { return }
        providers = decoded
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(providers) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func provider(id: UUID) -> ClashProvider? {
        providers.first { $0.id == id }
    }

    func update(_ provider: ClashProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    func delete(_ provider: ClashProvider) {
        providers.removeAll { $0.id == provider.id }
        save()
        if let url = Self.contentFileURL(for: provider) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes downloaded bytes as the record's content file.
    private func writeContent(_ data: Data, for provider: ClashProvider) throws {
        guard let url = Self.contentFileURL(for: provider) else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Downloads a provider URL's content (HTTP non-2xx, non-UTF-8
    /// is NOT required — rule files are bytes; only the 2 MB cap
    /// and the 30 s timeout apply) and stores it as the record's
    /// content file. Returns the record with updatedAt set. Throws
    /// with a Chinese message on failure; the record itself is
    /// untouched on failure.
    func downloadContent(for provider: ClashProvider) async throws -> ClashProvider {
        guard let url = URL(string: provider.url), !provider.url.isEmpty else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "规则提供方「\(provider.label)」没有可下载的链接"])
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("ConcordiOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "ConcordiOS", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "规则提供方「\(provider.label)」下载失败：HTTP \(http.statusCode)"])
        }
        guard data.count <= Self.maxDownloadBytes else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "规则提供方「\(provider.label)」文件过大（超过 2MB），无法下载"])
        }
        try writeContent(data, for: provider)
        var updated = provider
        updated.updatedAt = Date()
        update(updated)
        return updated
    }

    /// Finds the record for a URL (dedup by url — the same bytes
    /// serve every subscription using it; behavior/format live on
    /// each subscription's own CustomProvider entry, not here) or
    /// creates + downloads it. The label is only used for a new
    /// record; an existing record keeps its first label. Throws
    /// when the download fails; nothing is stored then.
    func findOrCreate(label: String, url: String, behavior: String?, format: String?) async throws -> ClashProvider {
        let normalized = url.trimmingCharacters(in: .whitespaces)
        if let existing = providers.first(where: { $0.url.trimmingCharacters(in: .whitespaces) == normalized }) {
            return existing
        }
        let record = ClashProvider(label: label, url: normalized, behavior: behavior, format: format)
        return try await downloadContent(for: record)
    }

    /// Re-downloads an existing record's content. Returns true on
    /// success; false leaves the old content in place. The caller
    /// (the editor's update button) re-applies referencing
    /// profiles afterwards via ProfileStore.
    func updateContent(for provider: ClashProvider) async -> Bool {
        do {
            _ = try await downloadContent(for: provider)
            return true
        } catch {
            return false
        }
    }
}
