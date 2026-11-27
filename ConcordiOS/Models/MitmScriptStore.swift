import Foundation
import Combine

// MARK: - Standalone MITM scripts (FlClash: lib/views/config/scripts.dart
// + lib/models/common.dart Script)
//
// FlClash keeps a library of standalone scripts — each with a name,
// an optional source URL and a last-update time, stored as
// `<id>.js` — separate from the scripts modules declare. A script
// in this library is a file the core can run, not a script line: the
// core only compiles scripts a `script` list names, so each script
// is also copied into the core's resources directory
// (<AppGroup>/mitm/resources/, content-hash name, the same
// convention modules use) and the page offers the `generic` script
// line to paste into a module's [Script] section. Once a module
// references it, mitm.runScript runs it by its label.
//
// Files live in <AppGroup>/mitm/scripts/ (NOT mitm/resources/):
// the module store sweeps unreferenced files out of resources, and
// a standalone script must survive that sweep.

struct MitmScript: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var label: String
    var url: String?
    var lastUpdateTime: Date
    var order: Int
    /// Content-hash file in mitm/resources/, for the core script line.
    var resourceName: String?

    var isRemote: Bool { url != nil && !(url?.isEmpty ?? true) }
    var fileName: String { "\(id).js" }
}

final class MitmScriptStore: ObservableObject {
    @Published private(set) var scripts: [MitmScript] = []
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published private(set) var updatingIds: Set<String> = []

    static let template = """
        const main = (config) => {
          return config;
        }
        """

    private let directoryName = "mitm"
    private let scriptsDirectoryName = "scripts"
    private let registryFileName = "scripts.json"

    init() {
        load()
    }

    // MARK: - Paths (App Group shared container)

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
    }

    private var scriptsDirectoryURL: URL? {
        containerURL?.appendingPathComponent(directoryName).appendingPathComponent(scriptsDirectoryName)
    }

    private var registryURL: URL? {
        scriptsDirectoryURL?.appendingPathComponent(registryFileName)
    }

    private var resourcesDirectoryURL: URL? {
        containerURL?.appendingPathComponent(directoryName).appendingPathComponent("resources")
    }

    private func fileURL(for script: MitmScript) -> URL? {
        scriptsDirectoryURL?.appendingPathComponent(script.fileName)
    }

    // MARK: - Persistence

    private func load() {
        guard let url = registryURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MitmScript].self, from: data) else { return }
        scripts = decoded.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Re-read the script registry from disk (used after a backup
    /// restore). Note: ScriptsView owns a private
    /// MitmScriptStore instance, so BackupView cannot reach it —
    /// the page re-loads from disk the next time it opens.
    func reload() {
        load()
    }

    private func persist() {
        guard let dir = scriptsDirectoryURL, let url = registryURL,
              let data = try? JSONEncoder().encode(scripts) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func content(of script: MitmScript) -> String? {
        guard let url = fileURL(for: script) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func hasLabel(_ label: String, except: MitmScript? = nil) -> Bool {
        scripts.contains { $0.id != except?.id && $0.label == label }
    }

    func uniqueLabel(_ name: String, fallback: String = "脚本") -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? fallback : base
        if !hasLabel(stem) { return stem }
        var n = 2
        while hasLabel("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }

    // MARK: - Mutations

    /// Saves content for a script (new or existing): writes the
    /// `<id>.js` file and its content-hash copy in resources, so the
    /// core script line names a file that exists. The resource copy
    /// is written FIRST: a failed copy must not leave the registry
    /// naming a copy older than `<id>.js` (audit B44) — on failure
    /// nothing is saved at all.
    @MainActor
    func save(_ script: MitmScript, content: String) async {
        lastError = nil
        guard let dir = scriptsDirectoryURL, let url = fileURL(for: script),
              let data = content.data(using: .utf8) else {
            lastError = "App Group 容器不可用"
            return
        }
        guard let resourceName = writeResourceCopy(data: data, source: script.fileName) else {
            lastError = "保存失败：无法写入核心资源副本，内容未改动"
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
            return
        }
        // Only now, with both files written, drop the previous
        // resource copy — deleting it earlier would leave the
        // registry naming a file that no longer exists.
        if let previous = script.resourceName, previous != resourceName,
           let resourcesDir = resourcesDirectoryURL {
            try? FileManager.default.removeItem(at: resourcesDir.appendingPathComponent(previous))
        }
        var updated = script
        updated.lastUpdateTime = Date()
        updated.resourceName = resourceName
        upsert(updated)
        statusMessage = "已保存“\(updated.label)”"
    }

    /// Creates a script with this label. A label already in use is
    /// rejected with an error instead of silently renamed (upstream
    /// scripts.dart `_validateName`): imports pass a unique label
    /// from `uniqueLabel` first, so they still land.
    @MainActor
    func create(label: String, url: String?, content: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            lastError = "名字不能为空"
            return
        }
        guard !hasLabel(label) else {
            lastError = "已存在同名脚本"
            return
        }
        let script = MitmScript(
            id: UUID().uuidString, label: label,
            url: url?.isEmpty == true ? nil : url,
            lastUpdateTime: Date(), order: (scripts.map(\.order).max() ?? -1) + 1)
        await save(script, content: content)
    }

    /// Downloads the script's URL over the old content (FlClash:
    /// Script.update). A failed download keeps the old file.
    @MainActor
    func update(_ script: MitmScript) async {
        guard let urlString = script.url, let url = URL(string: urlString) else {
            lastError = "“\(script.label)”没有来源链接"
            return
        }
        updatingIds.insert(script.id)
        defer { updatingIds.remove(script.id) }
        do {
            let data = try await mitmDownloadValidated(from: url)
            guard data.count <= maxMitmResourceSize else {
                lastError = "“\(script.label)”超过 \(maxMitmResourceSize / 1_048_576) MB，放弃更新"
                return
            }
            guard let content = String(data: data, encoding: .utf8) else {
                lastError = "“\(script.label)”不是 UTF-8 文本"
                return
            }
            await save(script, content: content)
            statusMessage = "“\(script.label)”已从链接更新"
        } catch {
            lastError = "更新“\(script.label)”失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func setURL(_ script: MitmScript, url: String) async {
        var updated = script
        updated.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.url?.isEmpty == true { updated.url = nil }
        upsert(updated)
        if updated.url != nil {
            await update(updated)
        }
    }

    @MainActor
    func rename(_ script: MitmScript, label: String) {
        lastError = nil
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            lastError = "名字不能为空"
            return
        }
        guard !hasLabel(label, except: script) else {
            lastError = "已存在同名脚本"
            return
        }
        var updated = script
        updated.label = label
        upsert(updated)
    }

    @MainActor
    func delete(_ script: MitmScript) {
        if let url = fileURL(for: script) {
            try? FileManager.default.removeItem(at: url)
        }
        if let resource = script.resourceName,
           let dir = resourcesDirectoryURL {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(resource))
        }
        scripts.removeAll { $0.id == script.id }
        persist()
        statusMessage = "已删除“\(script.label)”"
    }

    @MainActor
    func move(from source: IndexSet, to destination: Int) {
        scripts.move(fromOffsets: source, toOffset: destination)
        for (index, script) in scripts.enumerated() {
            scripts[index].order = index
        }
        persist()
    }

    private func upsert(_ script: MitmScript) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
        } else {
            scripts.append(script)
        }
        scripts.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        persist()
    }

    /// Writes the content-hash copy in the core's resources
    /// directory and returns the file name the core script line
    /// names, or nil when the copy could not be written — the
    /// caller then saves nothing, so the registry never names a
    /// stale copy (audit B44). The previous copy is removed by the
    /// caller, only after the `<id>.js` write succeeds.
    private func writeResourceCopy(data: Data, source: String) -> String? {
        guard let dir = resourcesDirectoryURL else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = mitmResourceName(source: source, bytes: data)
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        return name
    }
}

