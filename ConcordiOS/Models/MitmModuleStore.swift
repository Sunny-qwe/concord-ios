import Foundation
import Combine

// MARK: - MITM module store (FlClash: lib/database/mitm_modules.dart +
// lib/providers/actions/mitm_modules.dart)
//
// One row per module. The module text lives in the App Group shared
// container (mitm-modules/<id>.txt) so the app can parse it; the
// downloaded script / map-local files live in the core's own
// resources directory (<AppGroup>/mitm/resources/, content-hash
// named like FlClash's mitmResourceName), so the extension's core
// reads them when it applies the merged config. The merged module
// lists + rules are written to module-mitm.json; the extension
// merges that file into config.apply's overlay next to the user's
// own mitm.json (see PacketTunnelProvider.mergedMitmOverlay).
//
// Scripts are code the core runs: like FlClash, a module that
// declares scripts starts disabled until the user explicitly turns
// it on, and an update that brings new or changed scripts turns it
// off again until re-accepted. `scripts` counts the declared
// scripts the user has accepted.

struct MitmModuleError: Error {
    let message: String
}

/// One module's parse report for the 可靠性中心 -> 模块审计 page
/// (FlClash: DiagnosticsView ModuleAudit).
struct ModuleAudit: Identifiable {
    var id: String { module.id }
    let module: MitmModule
    let rules: Int
    let scripts: Int
    let hostnames: Int
    let skipped: [String]
    let missingResources: [String]
}

struct MitmModule: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var url: String?
    var enabled: Bool
    var order: Int
    var arguments: [String: String]
    var resources: [String: String]
    var system: String?
    var scripts: Int
    var lastUpdateTime: Date

    init(id: String = UUID().uuidString, name: String, description: String = "",
         url: String? = nil, enabled: Bool = true, order: Int = 0,
         arguments: [String: String] = [:], resources: [String: String] = [:],
         system: String? = nil, scripts: Int = 0, lastUpdateTime: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.url = url
        self.enabled = enabled
        self.order = order
        self.arguments = arguments
        self.resources = resources
        self.system = system
        self.scripts = scripts
        self.lastUpdateTime = lastUpdateTime
    }

    /// Tolerates rows written by older builds (new keys default).
    private enum CodingKeys: String, CodingKey {
        case id, name, description, url, enabled, order, arguments
        case resources, system, scripts, lastUpdateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "模块"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        arguments = try c.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        resources = try c.decodeIfPresent([String: String].self, forKey: .resources) ?? [:]
        system = try c.decodeIfPresent(String.self, forKey: .system)
        scripts = try c.decodeIfPresent(Int.self, forKey: .scripts) ?? 0
        lastUpdateTime = try c.decodeIfPresent(Date.self, forKey: .lastUpdateTime) ?? Date()
    }

    var isRemote: Bool { url != nil }
    var fileName: String { "\(id).txt" }

    /// True when turning this module on needs the script-consent
    /// alert: it declares scripts the user has not accepted yet.
    func needsScriptConsent(declaredScripts: Int) -> Bool {
        declaredScripts > scripts
    }

    /// A module written for Apple systems still applies, so this only
    /// warns. (FlClash's system list has no iOS entry; here "ios" is
    /// this device's system name.)
    var systemTip: String? {
        guard let system, !system.lowercased().contains("ios") else { return nil }
        return "该模块声明面向 \(system)，在 iOS 上可能不完全适用"
    }
}

final class MitmModuleStore: ObservableObject {
    @Published var modules: [MitmModule] = []
    @Published var statusMessage: String?
    @Published var lastError: String?
    /// Result of the live re-apply after a module change (nil while
    /// the tunnel is stopped: the merge takes effect at next start).
    @Published var applyMessage: String?
    @Published var isBusy = false

    /// Called after the merged files are rewritten, so the app can
    /// re-apply the active profile live. Wired in ConcordiOSApp to
    /// ProfileStore.reapplyActive; returns a message to show, or nil
    /// when the tunnel is stopped.
    var onModulesChanged: (() async -> String?)?

    /// The live client, wired in ConcordiOSApp. Nil (or a stopped
    /// tunnel) means the Swift parser reads modules; with a live
    /// tunnel the core's mitm.readModule reads them instead (see
    /// coreParsedContent).
    var client: ConcordClient?

    private let modulesDirectoryName = "mitm-modules"
    private let modulesFileName = "modules.json"

    init() {
        load()
    }

    // MARK: - Paths (App Group shared container)

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
    }

    private var modulesDirectoryURL: URL? {
        containerURL?.appendingPathComponent(modulesDirectoryName)
    }

    private var modulesFileURL: URL? {
        modulesDirectoryURL?.appendingPathComponent(modulesFileName)
    }

    /// The core's resources directory: <home>/mitm/resources, where
    /// home is the App Group container (core.init {"home": ...}).
    private var resourcesDirectoryURL: URL? {
        containerURL?.appendingPathComponent("mitm").appendingPathComponent("resources")
    }

    private func textURL(for module: MitmModule) -> URL? {
        modulesDirectoryURL?.appendingPathComponent(module.fileName)
    }

    // MARK: - Persistence

    private func load() {
        guard let url = modulesFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MitmModule].self, from: data) else { return }
        modules = decoded.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Re-read the module list from disk (used after a backup
    /// restore so the page shows the restored modules without
    /// restarting the app).
    func reload() {
        load()
    }

    private func persist() {
        guard let dir = modulesDirectoryURL, let url = modulesFileURL,
              let data = try? JSONEncoder().encode(modules) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func readText(_ module: MitmModule) -> String? {
        guard let url = textURL(for: module) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The module's stored text, for the editor. Nil when the file is
    /// missing (re-import it).
    func text(of module: MitmModule) -> String? {
        readText(module)
    }

    private func writeText(_ module: MitmModule, text: String) throws {
        guard let dir = modulesDirectoryURL, let url = textURL(for: module) else {
            throw MitmModuleError(message: "App Group 容器不可用")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing (current arguments + resources)

    /// Parses a module's stored text with its current arguments and
    /// downloaded resources. Nil when the text file is missing.
    func parsedContent(for module: MitmModule) -> MitmModuleContent? {
        guard let text = readText(module) else { return nil }
        return MitmModuleParser.parse(text: text, values: module.arguments, resources: module.resources)
    }

    /// A per-module parse report (FlClash: 可靠性中心 -> 模块审计）:
    /// how many rules / scripts / hostnames the module contributes,
    /// what the parser skipped, and which downloaded resources are
    /// missing from disk. Nil when the module's text file is missing.
    func audit(module: MitmModule) -> ModuleAudit? {
        guard let content = parsedContent(for: module) else { return nil }
        let missingResources = module.resources.filter { _, hash in
            guard let dir = resourcesDirectoryURL else { return true }
            return !FileManager.default.fileExists(atPath: dir.appendingPathComponent(hash).path)
        }.map(\.key)
        return ModuleAudit(
            module: module,
            rules: content.rules.count,
            scripts: content.declaredScripts,
            hostnames: content.hostname.count + content.insertedHostname.count,
            skipped: content.skipped.map { "\($0.section)：\($0.line)（\($0.reason.label)）" },
            missingResources: missingResources
        )
    }

    /// Parses a module with the core (mitm.readModule, upstream
    /// 165154c) when the tunnel is running; nil when the core cannot
    /// be reached, and the caller falls back to the Swift parser —
    /// the same pattern as convert.decodeLinks: the core does it
    /// when live, the Swift parser when not. The module's own
    /// arguments are passed, so an argument left unset takes its
    /// default; attachments are none in this build (the app has no
    /// local-file attachments — see MitmModuleParser).
    func coreParsedContent(for module: MitmModule) async -> MitmModuleContent? {
        guard let client, client.mode == .live, TunnelManager.shared.isRunning,
              let text = readText(module) else { return nil }
        do {
            let language = Locale.preferredLanguages.first ?? "zh-Hans"
            let view = try await client.mitmReadModule(text: text, arguments: module.arguments, attachments: [:], language: language)
            return MitmModuleParser.parseWithCore(view: view, text: text, values: module.arguments, resources: module.resources)
        } catch {
            return nil
        }
    }

    /// Enabled modules in order, parsed. A module whose text is
    /// missing adds nothing until it is re-imported.
    func enabledContents() -> [MitmModuleContent] {
        modules.filter(\.enabled).compactMap { parsedContent(for: $0) }
    }

    /// Enabled modules in order, parsed with the core where the
    /// tunnel is running (mitm.readModule) and the Swift parser
    /// otherwise. One RPC per module; modules are few.
    func enabledContentsLive() async -> [MitmModuleContent] {
        var out: [MitmModuleContent] = []
        for module in modules.filter(\.enabled) {
            if let core = await coreParsedContent(for: module) {
                out.append(core)
            } else if let swift = parsedContent(for: module) {
                out.append(swift)
            }
        }
        return out
    }

    /// The merged module lists + rules (user hostnames are NOT in
    /// here — the extension prepends mitm.json's hostnames first).
    func mergedLists() -> MitmModuleMerged {
        mergeMitmModules(hostname: [], modules: enabledContents())
    }

    /// The merged module lists + rules, with the core's parse where
    /// the tunnel is running.
    func mergedListsLive() async -> MitmModuleMerged {
        mergeMitmModules(hostname: [], modules: await enabledContentsLive())
    }

    /// The merged MITM config for mitm.validate: the user's own
    /// choices first, then the enabled modules' lists.
    func mergedConfig(userMitm: MitmConfig) -> MitmConfig {
        applyMerged(mergedLists(), to: userMitm)
    }

    /// The merged MITM config, with the core's parse where the
    /// tunnel is running.
    func mergedConfigLive(userMitm: MitmConfig) async -> MitmConfig {
        applyMerged(await mergedListsLive(), to: userMitm)
    }

    private func applyMerged(_ merged: MitmModuleMerged, to userMitm: MitmConfig) -> MitmConfig {
        var config = userMitm
        config.hostname = userMitm.hostname + merged.hostname
        config.urlRewrite = merged.urlRewrite
        config.headerRewrite = merged.headerRewrite
        config.bodyRewrite = merged.bodyRewrite
        config.mapLocal = merged.mapLocal
        config.script = merged.script
        config.skipVerifyHostname = merged.skipVerifyHostname
        config.clientSourceAddress = merged.clientSourceAddress
        config.requestBodyMock = merged.requestBodyMock
        return config
    }

    // MARK: - Merged files + live re-apply

    /// Writes module-mitm.json (merged lists + rules) and sweeps
    /// resource files no module names any more, then asks the app to
    /// re-apply the active profile live when the tunnel is running.
    @MainActor
    func refreshModuleFiles() async {
        await writeMergedFile()
        sweepResources()
        if let onModulesChanged {
            applyMessage = await onModulesChanged()
        }
    }

    private func writeMergedFile() async {
        let merged = await mergedListsLive()
        var json = merged.mitmJSON
        if !merged.rules.isEmpty { json["rules"] = merged.rules }
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.moduleMitmFileName),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Removes every resource file no module names, so a deleted
    /// module or an updated script does not leave files behind. Only
    /// touches <AppGroup>/mitm/resources — the CA store lives in
    /// <AppGroup>/mitm/ itself and is never swept.
    private func sweepResources() {
        guard let dir = resourcesDirectoryURL else { return }
        let referenced = Set(modules.flatMap { $0.resources.values })
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Resources

    /// Downloads every URL in `urls` into the core's resources
    /// directory, named by content hash. A URL that fails to download
    /// keeps the copy an earlier update left, if its file still
    /// exists.
    private func downloadResources(_ urls: Set<String>, previous: [String: String]) async -> [String: String] {
        guard let dir = resourcesDirectoryURL else { return [:] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String: String] = [:]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard data.count <= maxMitmResourceSize else { continue }
                let name = mitmResourceName(source: urlString, bytes: data)
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                out[urlString] = name
            } catch {
                if let name = previous[urlString],
                   FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                    out[urlString] = name
                }
            }
        }
        return out
    }

    // MARK: - Add / edit / update

    /// Imports from a URL or another app's install link
    /// (surge://install-module, loon://import, shadowrocket://install,
    /// stash://install-override, quantumult-x add-resource).
    @MainActor
    func addFromURL(_ text: String) async {
        let urls = mitmModuleUrls(text)
        guard let urlString = urls.first, let url = URL(string: urlString) else {
            lastError = "不是有效的模块链接"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let moduleText = String(data: data, encoding: .utf8), !moduleText.isEmpty else {
                lastError = "下载的模块内容为空"
                return
            }
            let name = moduleName(from: urlString)
            var module = MitmModule(name: name, url: urlString, order: nextOrder())
            module = try await save(module, text: moduleText, added: true, previousText: nil)
            modules.append(module)
            sortModules()
            persist()
            await refreshModuleFiles()
            statusMessage = "已导入模块 \(module.name)"
            lastError = nil
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Imports pasted text or a local file's contents.
    @MainActor
    func addFromText(_ text: String, fileName: String?) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "模块内容为空"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            var module = MitmModule(name: moduleName(from: fileName), order: nextOrder())
            module = try await save(module, text: text, added: true, previousText: nil)
            modules.append(module)
            sortModules()
            persist()
            await refreshModuleFiles()
            statusMessage = "已导入模块 \(module.name)"
            lastError = nil
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// The editor template, like FlClash's: name + desc + one URL
    /// rewrite section + an (initially empty) MITM hostname line.
    static func blankTemplate(name: String) -> String {
        "#!name=\(name)\n#!desc=\n\n[URL Rewrite]\n\n[MITM]\nhostname = %APPEND%\n"
    }

    /// Saves edited text over a module, re-parsing and re-downloading
    /// its resources. An update that brings new or changed scripts
    /// turns the module off until the user accepts them again.
    @MainActor
    func edit(_ module: MitmModule, text: String) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let previousText = readText(module)
            var updated = try await save(module, text: text, added: false, previousText: previousText)
            updated.lastUpdateTime = Date()
            modules[index] = updated
            persist()
            await refreshModuleFiles()
            statusMessage = updated.enabled ? "已保存模块 \(updated.name)" : "已保存模块 \(updated.name)（含新脚本，已暂停，需手动开启）"
            lastError = nil
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// Re-downloads a remote module, or re-reads a local module's
    /// text file and re-parses it.
    @MainActor
    func update(_ module: MitmModule) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let previousText = readText(module)
            let text: String
            if let urlString = module.url, let url = URL(string: urlString) {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let downloaded = String(data: data, encoding: .utf8), !downloaded.isEmpty else {
                    lastError = "更新失败：下载内容为空"
                    return
                }
                text = downloaded
            } else if let local = previousText {
                text = local
            } else {
                lastError = "更新失败：模块文件丢失，请重新导入"
                return
            }
            var updated = try await save(module, text: text, added: false, previousText: previousText)
            updated.lastUpdateTime = Date()
            modules[index] = updated
            persist()
            await refreshModuleFiles()
            statusMessage = updated.enabled ? "已更新模块 \(updated.name)" : "已更新模块 \(updated.name)（含新脚本，已暂停，需手动开启）"
            lastError = nil
        } catch {
            lastError = "更新失败：\(error.localizedDescription)"
        }
    }

    /// The core of add/edit/update: parse, download the resources the
    /// new content names, write the text file, and decide the enabled
    /// flag by the script-consent rules. Returns the saved row.
    private func save(_ module: MitmModule, text: String, added: Bool, previousText: String?) async throws -> MitmModule {
        let content = MitmModuleParser.parse(text: text, values: module.arguments, resources: module.resources)
        if content.isEmpty {
            throw MitmModuleError(message: "模块内容为空或无法识别")
        }
        let resources = await downloadResources(content.resourceUrls, previous: module.resources)
        // Non-URL resources are attachments (none in this build); the
        // downloaded ones replace the previous set for these URLs.
        var mergedResources = module.resources.filter { !isMitmResourceUrl($0.key) }
        for (url, name) in resources { mergedResources[url] = name }
        try writeText(module, text: text)
        var saved = module
        saved.name = content.name ?? module.name
        saved.description = content.description ?? ""
        saved.system = content.system
        saved.resources = mergedResources
        saved.lastUpdateTime = Date()
        if added {
            // A module added with scripts starts off until the user
            // accepts them; `scripts` stays 0 (nothing accepted yet).
            saved.enabled = content.declaredScripts == 0
            saved.scripts = 0
        } else {
            let bringsNew: Bool
            if let previousText, module.enabled {
                let before = mitmScriptScope(text: previousText, values: module.arguments, resources: module.resources)
                let after = mitmScriptScope(text: text, values: module.arguments, resources: mergedResources)
                bringsNew = !after.isSubset(of: before)
            } else {
                bringsNew = false
            }
            if bringsNew || content.declaredScripts > module.scripts {
                // New or changed scripts: turn off until re-accepted,
                // and keep the old accepted count so turning it back
                // on still asks for consent.
                saved.enabled = false
                saved.scripts = module.scripts
            } else {
                saved.enabled = module.enabled
                saved.scripts = content.declaredScripts
            }
        }
        return saved
    }

    // MARK: - Arguments

    /// Saves new argument values, downloading any resources the new
    /// values bring in. Turning the module off when the values
    /// declare more scripts than the user accepted is handled by the
    /// caller (see setArguments below).
    @MainActor
    func setArguments(_ module: MitmModule, values: [String: String]) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        isBusy = true
        defer { isBusy = false }
        modules[index].arguments = values
        persist()
        guard let text = readText(module) else { return }
        let content = MitmModuleParser.parse(text: text, values: values, resources: module.resources)
        let missing = content.resourceUrls.subtracting(module.resources.keys)
        if !missing.isEmpty {
            let fetched = await downloadResources(missing, previous: module.resources)
            if !fetched.isEmpty {
                modules[index].resources.merge(fetched) { _, new in new }
                persist()
            }
        }
        if module.enabled && content.declaredScripts > module.scripts {
            // New scripts from the new values: turn off until
            // re-accepted; the accepted count stays, so turning it
            // back on still asks for consent.
            modules[index].enabled = false
            persist()
            statusMessage = "参数使模块声明了新脚本，已暂停，需手动开启"
        }
        await refreshModuleFiles()
    }

    // MARK: - Toggle / reorder / delete

    /// Turns a module on or off. The view asks for script consent
    /// before calling this with `on: true` for a module whose
    /// declared scripts exceed the accepted count.
    @MainActor
    func setEnabled(_ module: MitmModule, on: Bool) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index].enabled = on
        if on, let content = parsedContent(for: modules[index]) {
            modules[index].scripts = content.declaredScripts
        }
        persist()
        await refreshModuleFiles()
        statusMessage = on ? "已启用模块 \(module.name)" : "已停用模块 \(module.name)"
    }

    @MainActor
    func moveUp(_ module: MitmModule) async {
        move(module, by: -1)
        await refreshModuleFiles()
    }

    @MainActor
    func moveDown(_ module: MitmModule) async {
        move(module, by: 1)
        await refreshModuleFiles()
    }

    private func move(_ module: MitmModule, by delta: Int) {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        let target = index + delta
        guard target >= 0, target < modules.count else { return }
        modules.swapAt(index, target)
        for (i, _) in modules.enumerated() { modules[i].order = i }
        persist()
    }

    @MainActor
    func delete(_ module: MitmModule) async {
        modules.removeAll { $0.id == module.id }
        for (i, _) in modules.enumerated() { modules[i].order = i }
        persist()
        if let url = textURL(for: module) {
            try? FileManager.default.removeItem(at: url)
        }
        await refreshModuleFiles()
        statusMessage = "已删除模块 \(module.name)"
    }

    // MARK: - Helpers

    private func nextOrder() -> Int {
        (modules.map(\.order).max() ?? -1) + 1
    }

    private func sortModules() {
        modules.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    private func moduleName(from urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString) else { return "模块" }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host ?? "模块" }
        let name = (last as NSString).deletingPathExtension
        return name.isEmpty ? "模块" : name
    }
}
