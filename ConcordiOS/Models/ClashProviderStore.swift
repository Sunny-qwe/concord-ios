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
    /// mihomo format: yaml / text / mrs / domain-set (v0.2.157:
    /// domain-set is only valid with behavior domain — the core
    /// rejects the whole config otherwise, provider.rs
    /// parse_rule_provider). Nil = unset (the core auto-detects;
    /// "" means yaml).
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
    /// The last scheduled auto-update failure summary, if any
    /// (v0.2.157; same shape as ProfileStore.updateDueProfiles'
    /// lastError — "自动更新失败（N 个）：…" — shown on the
    /// Providers page; nil after a clean run).
    @Published var lastAutoUpdateError: String?
    /// A scheduled run is in flight (v0.2.157, logic-audit B2):
    /// the 20-minute timer can fire while a long run (many
    /// providers × up-to-30 s each) is still going; without this
    /// the second run would race the first on `providers` /
    /// `lastAutoUpdateError` and double-download. @MainActor
    /// serialises the flag with the runs.
    private var isAutoUpdating = false

    private static let fileName = "clash-providers.json"
    private static let contentDirectoryName = "clash-providers"
    private static let maxDownloadBytes = 2 * 1024 * 1024
    /// Serialises the load → mutate → save windows (v0.2.157,
    /// B1 final re-audit residual): writers are separate ad-hoc
    /// instances, so the lock must be static to be shared. It
    /// is recursive because update()/delete() lock internally
    /// while the download functions hold it across their
    /// post-download segment. No await ever runs under it
    /// (it is only taken after the download await), so it can
    /// neither deadlock nor stall a download; the held window
    /// is a synchronous disk read + write (~1 ms).
    private static let ioLock = NSRecursiveLock()

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

    /// Replaces the record with the same id, or appends it when
    /// it is new — then saves the whole list. Reloads from disk
    /// first (v0.2.157, B1 re-audit hole 2): writers are ad-hoc
    /// instances with init-time snapshots, and their saves run
    /// off the MainActor after a download await — without this,
    /// a record added by a concurrent writer (e.g. an import
    /// finishing while an update-all download is in flight)
    /// would be clobbered by this save. No caller depends on
    /// overwriting disk with a stale snapshot (there is no
    /// whole-list restore path for this store).
    func update(_ provider: ClashProvider) {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        load()
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    func delete(_ provider: ClashProvider) {
        // Same reload-first as update() (B1 re-audit hole 2):
        // a delete must not drop records added concurrently.
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        load()
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
        let data = try await Self.downloadBytes(for: provider)
        // v0.2.157, B1 re-audit hole 1: refresh from disk after
        // the download await — a rename made mid-download must
        // not be reverted by writing back this stale parameter
        // struct (label is user-editable; url is not). Only
        // updatedAt is refreshed. The `?? provider` fallback is
        // findOrCreate's new record, which is not on disk yet.
        // The segment runs under ioLock (recursive — update()
        // locks again inside) so the fresh read, the write and
        // the save are one atomic window against concurrent
        // writers; no await runs under the lock.
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        load()
        let current = providers.first(where: { $0.id == provider.id }) ?? provider
        try writeContent(data, for: current)
        var updated = current
        updated.updatedAt = Date()
        update(updated)
        return updated
    }

    /// Scheduled-run download (v0.2.157, logic re-audit B1):
    /// like downloadContent, but the record must still exist
    /// on disk when the download finishes. A record deleted
    /// mid-run (ad-hoc delete during the up-to-30 s download)
    /// stays deleted instead of being resurrected by
    /// update()'s append fallback — returns nil in that case
    /// and the caller skips it (not a failure). `updated` is
    /// built from the FRESH record (B1 re-audit hole 1), not
    /// the stale parameter: a rename made mid-download would
    /// otherwise be silently reverted by the save. The
    /// load → exists-check → write → update → save segment is
    /// synchronous with no await; update()/delete() also
    /// reload first (hole 2), because saves from the manual
    /// path run off the MainActor after a download await and
    /// must not clobber concurrent writers either. The whole
    /// segment runs under the static ioLock (recursive —
    /// update() locks again inside), so the existence guard
    /// cannot go stale between the check and the save. The content
    /// file is written only AFTER the existence check, so a
    /// vanished record leaves no orphan file.
    @MainActor
    func downloadContentIfStillExists(for provider: ClashProvider) async throws -> ClashProvider? {
        let data = try await Self.downloadBytes(for: provider)
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        load()
        guard let current = providers.first(where: { $0.id == provider.id }) else { return nil }
        try writeContent(data, for: current)
        var updated = current
        updated.updatedAt = Date()
        update(updated)
        return updated
    }

    /// The network half of downloadContent, shared by both
    /// variants: fetches the bytes with the 30 s timeout and
    /// 2 MB cap, rejecting non-2xx. No disk or store state is
    /// touched here.
    private static func downloadBytes(for provider: ClashProvider) async throws -> Data {
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
        return data
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

    // MARK: - Scheduled auto-update (v0.2.157)

    /// The global geo auto-update switch (v0.2.157): upstream
    /// gates provider auto-update on the SAME switch as the geo
    /// databases (PatchClashConfig.geoAutoUpdate, default on —
    /// resources.dart autoUpdate). Read from the same
    /// UserDefaults keys SettingsView writes.
    private static var geoAutoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: "ConcordiOS.geoAutoUpdate") as? Bool ?? true
    }

    /// The global geo update interval in hours (v0.2.157):
    /// upstream's geoUpdateInterval, default 24 — the same
    /// interval the geo databases use (SettingsView writes
    /// "ConcordiOS.geoAutoUpdateHours").
    private static var geoUpdateIntervalHours: Double {
        UserDefaults.standard.object(forKey: "ConcordiOS.geoAutoUpdateHours") as? Double ?? 24.0
    }

    /// Scheduled auto-update for ClashProvider records
    /// (v0.2.157; upstream resources.dart autoUpdate, triggered
    /// at app start + on core connect — the app runs it at launch
    /// and on the same 20-minute timer as updateDueProfiles).
    /// Upstream has NO per-record interval or toggle: the gate is
    /// the global geo switch + interval above, and a record is
    /// due when its cached content is older than the interval
    /// (upstream uses the cache file's lastModified; ours uses
    /// updatedAt, set by downloadContent on every successful
    /// download — the same instant). Only remote records (a
    /// non-empty url) are candidates; a never-updated record is
    /// due. Returns the ids whose content actually changed, so
    /// the caller can re-apply the active profile for each
    /// (ProfileStore.reapplyActiveForClashProvider — a no-op when
    /// the active profile does not bake that record). The
    /// confined files are re-created at bake time from the new
    /// content, so no separate re-confine step exists.
    /// Per-record failures are collected into
    /// lastAutoUpdateError (upstream logs them as warnings
    /// only); the old content stays in place on failure.
    /// Deliberate deviation from the 157 brief's "per-record
    /// interval, persisted" suggestion: upstream has no such
    /// field, and the standing rule is to replicate upstream
    /// first — a per-record interval would be our own feature.
    /// @MainActor like ProfileStore.updateDueProfiles: the
    /// 20-minute-timer Task is not MainActor-isolated, and the
    /// @Published lastAutoUpdateError write must land on the
    /// main thread (compile-audit nit).
    @MainActor
    func updateDueProviders() async -> [UUID] {
        // v0.2.157, logic-audit B2: a second run (timer firing
        // during a long first run) returns immediately instead
        // of racing the first on `providers` /
        // `lastAutoUpdateError` and double-downloading.
        guard !isAutoUpdating else { return [] }
        isAutoUpdating = true
        defer { isAutoUpdating = false }
        // v0.2.157, logic-audit B1: this shared instance loads
        // clash-providers.json once at launch and never reloads,
        // while every other writer (import, editor update,
        // cleanupDeletedProviders) uses a fresh ad-hoc instance
        // that saves the whole array. Without this reload, a
        // successful download here would save the stale
        // launch-time snapshot and silently DELETE records added
        // (or resurrect records deleted) since launch.
        load()
        lastAutoUpdateError = nil
        guard Self.geoAutoUpdateEnabled else { return [] }
        // v0.2.157, logic-audit 1(a): the Settings UI requires
        // hours > 0, but a backup restore writes the interval
        // unvalidated — a restored 0 would make every provider
        // due on every run. Treat non-positive as the default.
        let intervalHours = Self.geoUpdateIntervalHours > 0 ? Self.geoUpdateIntervalHours : 24.0
        let intervalSeconds = intervalHours * 3600
        var changed: [UUID] = []
        var failures: [(label: String, error: String)] = []
        for record in providers where !record.url.trimmingCharacters(in: .whitespaces).isEmpty {
            // v0.2.157, logic re-audit B1: reload before each
            // record — an ad-hoc writer may have saved during
            // the previous download's await, and this iteration's
            // save must not clobber it. (The loop iterates the
            // pre-run snapshot — value semantics — so reloading
            // here can't skip or repeat records.) The FRESH
            // record drives the rest: a manual update mid-run
            // refreshes updatedAt, and a record deleted since
            // the snapshot is skipped without a pointless
            // download.
            load()
            guard let fresh = providers.first(where: { $0.id == record.id }) else { continue }
            if let last = fresh.updatedAt {
                guard Date() >= last.addingTimeInterval(intervalSeconds) else { continue }
            }
            do {
                // nil = deleted mid-download (stays deleted,
                // not a failure); see downloadContentIfStillExists.
                if try await downloadContentIfStillExists(for: fresh) != nil {
                    changed.append(record.id)
                }
            } catch {
                failures.append((fresh.label, error.localizedDescription))
            }
        }
        if failures.isEmpty {
            lastAutoUpdateError = nil
        } else {
            lastAutoUpdateError = "自动更新失败（\(failures.count) 个）：\n"
                + failures.map { "· \($0.label)：\($0.error)" }.joined(separator: "\n")
        }
        return changed
    }
}
