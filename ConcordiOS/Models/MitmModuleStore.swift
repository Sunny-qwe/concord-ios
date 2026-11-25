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
//
// Consent is three-state in the row (fork 2d31f10, 7140e37):
// `accepted` is nil until asked, false once declined or turned
// off, true once agreed; `asksConsent` records whether the content
// asks about anything besides scripts. A module awaits consent
// when it is off, never answered, and asks about something — that
// state lives in the row, so it survives app restart (see
// awaitsConsent / modulesAwaitingConsent). A module whose file
// cannot be read counts as asking (7140e37): the prompt says so
// instead of enabling blindly.

struct MitmModuleError: Error {
    let message: String
}

struct MitmModule: Codable, Equatable, Hashable, Identifiable {
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
    /// Whether the content asks about network changes, skipped
    /// verification or limited clients (fork 2d31f10 `asksConsent`),
    /// judged when the content is saved.
    var asksConsent: Bool
    /// The user's answer to what turning it on asks about: true
    /// once agreed, false once declined or turned off, nil until
    /// asked — and nil again once an update turns it off for
    /// something it was never agreed to (fork 2d31f10 `accepted`).
    var accepted: Bool?
    var lastUpdateTime: Date

    init(id: String = UUID().uuidString, name: String, description: String = "",
         url: String? = nil, enabled: Bool = true, order: Int = 0,
         arguments: [String: String] = [:], resources: [String: String] = [:],
         system: String? = nil, scripts: Int = 0, asksConsent: Bool = false,
         accepted: Bool? = nil, lastUpdateTime: Date = Date()) {
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
        self.asksConsent = asksConsent
        self.accepted = accepted
        self.lastUpdateTime = lastUpdateTime
    }

    /// Tolerates rows written by older builds (new keys default).
    private enum CodingKeys: String, CodingKey {
        case id, name, description, url, enabled, order, arguments
        case resources, system, scripts, asksConsent, accepted, lastUpdateTime
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
        asksConsent = try c.decodeIfPresent(Bool.self, forKey: .asksConsent) ?? false
        accepted = try c.decodeIfPresent(Bool.self, forKey: .accepted)
        lastUpdateTime = try c.decodeIfPresent(Date.self, forKey: .lastUpdateTime) ?? Date()
    }

    var isRemote: Bool { url != nil }
    var fileName: String { "\(id).txt" }

    /// True when turning this module on asks first: it declares
    /// scripts the user has not accepted yet, or its content asks
    /// about something else (fork `asksBeforeTurningOn`).
    func asksBeforeTurningOn(declaredScripts: Int) -> Bool {
        declaredScripts > scripts || asksConsent
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
    /// The module name the core-unavailable guard last refused, and
    /// a counter that ticks on every refusal. Upstream every
    /// add/edit/update path goes through readMitmModule → core RPC,
    /// which throws core_unavailable when the core is not connected,
    /// and safeRun(silence: false) shows a confirm dialog titled
    /// with the module name. Views watch the counter — a plain
    /// String would not re-fire for the same module twice — and show
    /// that dialog (title = the name, content = the sentence below).
    @Published var coreUnavailableName = ""
    @Published private(set) var coreUnavailableCount = 0
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
        migrateConsentIfNeeded()
    }

    /// One-time settlement of rows written before consent was
    /// recorded (fork v26 `_recordMitmConsent`): on with something
    /// to ask about counts as agreed, on with nothing as not yet
    /// asked, off as declined — except an off module whose update
    /// already paused it for scripts it never accepted, which
    /// awaits consent so the pause survives as the persistent
    /// badge (the fork's migration would record declined there,
    /// which would drop the pending state).
    private func migrateConsentIfNeeded() {
        let key = "ConcordiOS.mitm.consentMigrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !modules.isEmpty else { return }
        for i in modules.indices {
            let module = modules[i]
            let content = parsedContent(for: module)
            let declared = content?.declaredScripts ?? 0
            // A file that cannot be read counts as asking nothing
            // here (like the fork's migration); the prompt still
            // asks about it when it is turned on (7140e37).
            let asks = content.map { asksConsent(of: $0) } ?? false
            modules[i].asksConsent = asks
            if module.enabled {
                modules[i].accepted = (declared > 0 || asks) ? true : nil
            } else if declared > module.scripts {
                modules[i].accepted = nil
            } else {
                modules[i].accepted = false
            }
        }
        persist()
    }

    /// Whether `content` asks about something besides scripts:
    /// network changes, skipped server verification or limited
    /// clients (fork `MitmModuleContent.asksConsent`, upstream
    /// ModuleDef::asks_consent: network non-empty, skip-verify
    /// set, or clients limited). The parser carries the network
    /// edits (MitmModuleNetwork), so they set this directly; the
    /// core's mitm.readModule reports them as `coreAsksConsent`
    /// too, which the module detail page shows.
    func asksConsent(of content: MitmModuleContent) -> Bool {
        !content.network.isEmpty
            || !content.skipVerifyHostname.isEmpty
            || !content.clientSourceAddress.isEmpty
            || content.coreAsksConsent
    }

    /// Whether this module awaits consent (fork `awaitsConsent`):
    /// off, never answered, and asking about something. A file
    /// that cannot be read counts as asking (7140e37). The state
    /// lives in the row, so it survives app restart.
    func awaitsConsent(_ module: MitmModule) -> Bool {
        guard !module.enabled, module.accepted == nil else { return false }
        guard let content = parsedContent(for: module) else { return true }
        return module.asksBeforeTurningOn(declaredScripts: content.declaredScripts)
    }

    /// Every module awaiting consent, in list order (fork
    /// `mitmModulesToAgree`).
    var modulesAwaitingConsent: [MitmModule] {
        modules.filter { awaitsConsent($0) }
    }

    func firstAwaitingConsent() -> MitmModule? {
        modulesAwaitingConsent.first
    }

    /// The consent prompt for a module (fork `answerMitmModule`):
    /// what turning it on asks about. Nil when nothing asks, so
    /// the caller enables directly. A file that cannot be read
    /// counts as asking, and the prompt says so first (7140e37).
    ///
    /// The script line differs from the fork's in one clause: the
    /// fork says an agreed module's later updates take effect
    /// without asking again, but this build keeps pausing on new
    /// scripts (see save()), so the prompt says so instead.
    ///
    /// Pass the core's parse when the caller already has it (the
    /// module detail page loads mitm.readModule while the tunnel
    /// runs): the declared-script count then comes from the core
    /// instead of the Swift parser (audit B42). The list has no
    /// core parse, so it keeps the Swift one.
    func consentPrompt(for module: MitmModule, content: MitmModuleContent? = nil) -> (title: String, message: String)? {
        let content = content ?? parsedContent(for: module)
        let declared = content?.declaredScripts ?? 0
        let asks = content.map { asksConsent(of: $0) } ?? true
        let unreadable = content == nil
        let unacceptedScripts = declared > module.scripts
        guard unreadable || unacceptedScripts || asks else { return nil }
        let title = (asks || unreadable) ? "启用此模块？" : "运行此模块的脚本？"
        var parts: [String] = []
        if let content, !content.skipVerifyHostname.isEmpty {
            parts.append("开启后，将不再校验下列主机的服务器证书，冒充这些服务器的连接不会被发现：\(content.skipVerifyHostname.joined(separator: "、"))")
        }
        if unreadable {
            parts.append("无法读取模块文件，不清楚它会改动什么。只在信任其来源时开启。")
        }
        if unacceptedScripts {
            parts.append("它的脚本能读取并修改所匹配主机的流量，包括 Cookie 和令牌，还能自行发送请求。只在信任其来源时开启；带新脚本的更新会先暂停，等你再确认。")
        }
        if let content, !content.clientSourceAddress.isEmpty {
            parts.append("它只为这些客户端解密：\(content.clientSourceAddress.joined(separator: "、"))。开启 TUN 时，本机应用经 TUN 地址连入，可能因此不再解密。")
        }
        if let content, !content.network.isEmpty {
            parts.append("它还会改动网络设置：\(networkConsentSummary(content.network))。")
        }
        return (title, parts.joined(separator: "\n\n"))
    }

    /// One line naming the network changes a module asks for, for
    /// the consent prompt. Bypass has no host list on iOS (a packet
    /// tunnel, not a proxy), so it is named as not taking effect.
    private func networkConsentSummary(_ network: MitmModuleNetwork) -> String {
        var kinds: [String] = []
        if network.nameserver != nil || network.defaultNameserver != nil || network.fakeIpFilter != nil {
            kinds.append("DNS 服务器")
        }
        if !network.nameserverPolicy.isEmpty || !network.hosts.isEmpty {
            kinds.append("hosts 解析")
        }
        if !network.routeAddress.isEmpty || network.routeExcludeAddress != nil {
            kinds.append("TUN 路由")
        }
        if network.bypassDomain != nil {
            kinds.append("代理绕过（iOS 上不生效）")
        }
        return kinds.joined(separator: "、")
    }

    /// Records the answer to the consent prompt (fork
    /// `recordConsent`): agreeing enables the module and accepts
    /// the scripts it declares now; declining leaves it off and
    /// records the decline, so it stops awaiting consent.
    /// `content` is the core's parse when the caller has it (see
    /// consentPrompt): the accepted script count then comes from
    /// the core instead of the Swift parser (audit B42).
    @MainActor
    func answerConsent(_ module: MitmModule, agreed: Bool, content: MitmModuleContent? = nil) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        let content = content ?? parsedContent(for: modules[index])
        modules[index].asksConsent = content.map { asksConsent(of: $0) } ?? true
        if agreed {
            modules[index].accepted = true
            modules[index].enabled = true
            if let content {
                modules[index].scripts = content.declaredScripts
            }
        } else {
            modules[index].accepted = false
        }
        persist()
        await refreshModuleFiles()
        statusMessage = agreed ? "已启用模块 \(module.name)" : "已拒绝模块 \(module.name)，保持关闭"
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

    /// Parses a module with the core (mitm.readModule, upstream
    /// 165154c) when the tunnel is running; nil when the core cannot
    /// be reached, and the caller falls back to the Swift parser —
    /// the same pattern as convert.decodeLinks: the core does it
    /// when live, the Swift parser when not. The module's own
    /// arguments are passed, so an argument left unset takes its
    /// default; local-file attachments ride along as `attachments`
    /// (name → stored file), as the core's readModule takes them.
    func coreParsedContent(for module: MitmModule) async -> MitmModuleContent? {
        guard let client, client.mode == .live, TunnelManager.shared.isRunning,
              let text = readText(module) else { return nil }
        do {
            let language = Locale.preferredLanguages.first ?? "zh-Hans"
            let view = try await client.mitmReadModule(text: text, arguments: module.arguments, attachments: attachmentsParam(for: module), language: language)
            var content = MitmModuleParser.parseWithCore(view: view, text: text, values: module.arguments, resources: module.resources)
            // The core's rules name its rule sets `mitm-<sha256[0:12]>`
            // (upstream rule.rs set_name) while the Swift parser names
            // them `mitm-<sha1[0:12]>` — on this path the Swift
            // providers would name sets no rule references, and
            // config.apply would fail with `rule set [mitm-…] not
            // found`. The view carries the core's definitions
            // (ruleSets), so the providers come from there; the Swift
            // parse's providers stay for the offline path, where its
            // own rules name them.
            if !view.ruleSets.isEmpty {
                content.ruleProviders = coreRuleProviders(view.ruleSets)
            }
            return content
        } catch {
            return nil
        }
    }

    /// The core's rule-set definitions (mitm.readModule `ruleSets`)
    /// as profile rule-providers, in the profile's map form. The
    /// view's `source` is the core's RuleSetSource JSON (internally
    /// tagged `type`); the key sets mirror the Swift parser's per
    /// type, so the two paths' providers differ only in the name
    /// hash. A set whose source does not read is skipped — its rule
    /// then fails at config.apply with the core's own error, as it
    /// would with no provider at all.
    private func coreRuleProviders(_ sets: [JSONValue]) -> [String: [String: JSONValue]] {
        var out: [String: [String: JSONValue]] = [:]
        for set in sets {
            guard let obj = set.objectValue,
                  let name = obj["name"]?.stringValue, !name.isEmpty,
                  let source = obj["source"]?.objectValue,
                  let type = source["type"]?.stringValue else { continue }
            let domain = obj["domain"] == .bool(true)
            let behavior: JSONValue = .string(domain ? "domain" : "classical")
            switch type {
            case "url":
                guard let url = source["url"]?.stringValue else { continue }
                var provider: [String: JSONValue] = [
                    "type": .string("http"), "behavior": behavior,
                    "format": .string(domain ? "domain-set" : "text"),
                    "url": .string(url),
                ]
                // No interval given means the host's default (the
                // Swift parser writes 86400); a given one is a number.
                if let interval = source["interval"], case .int(let seconds) = interval {
                    provider["interval"] = .int(seconds)
                } else {
                    provider["interval"] = .int(86_400)
                }
                out[name] = provider
            case "inline", "builtin":
                guard let rules = source["rules"]?.arrayValue else { continue }
                let payload: [JSONValue]
                if type == "inline" {
                    payload = rules.compactMap { $0.objectValue?["rule"]?.stringValue }.map { .string($0) }
                } else {
                    payload = rules.compactMap { $0.stringValue }.map { .string($0) }
                }
                out[name] = ["type": .string("inline"), "behavior": behavior, "payload": .array(payload)]
            case "file":
                guard let file = source["file"]?.stringValue else { continue }
                out[name] = [
                    "type": .string("file"), "behavior": behavior,
                    "format": .string(domain ? "domain-set" : "text"),
                    "path": .string("mitm/resources/\(file)"),
                ]
            default:
                continue
            }
        }
        return out
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

    /// The merged module lists + rules, with the core's parse where
    /// the tunnel is running.
    func mergedListsLive() async -> MitmModuleMerged {
        mergeMitmModules(hostname: [], modules: await enabledContentsLive())
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
        // h2: a module asking for HTTP/2 turns it on (OR with the
        // user's own switch — the module's ask wins, like its lists).
        // Rule providers have no MitmConfig field: mitm.validate
        // takes only the mitm section, so the providers travel via
        // module-mitm.json -> the extension overlay and are checked
        // at config.apply, where the core resolves the module rules.
        config.h2 = userMitm.h2 || merged.h2
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

    /// Recompute module-mitm.json (and sweep resources) WITHOUT
    /// triggering a live re-apply. For ProfileStore.applyProfile,
    /// which applies live itself right after writing the new shared
    /// config.yaml — calling refreshModuleFiles there would apply
    /// the same profile twice (its onModulesChanged → reapplyActive
    /// runs configApply). Kept separate so the switch stays a
    /// single live apply.
    @MainActor
    func refreshMergedFileOnly() async {
        await writeMergedFile()
        sweepResources()
    }

    private func writeMergedFile() async {
        // Inline payload scripts of already-saved modules (imported
        // before materialisation existed) are written out here, so
        // the merge below resolves them instead of skipping them.
        materializeInlineResourcesForEnabledModules()
        let merged = await mergedListsLive()
        var json = merged.mitmJSON
        if !merged.rules.isEmpty { json["rules"] = merged.rules }
        if merged.h2 { json["h2"] = true }
        // Rule providers: the overlay replaces the profile's
        // rule-providers wholesale (upstream merge.rs), so the file
        // carries the profile's providers merged with the modules'
        // (a module wins on a name clash — its rules name it), plus
        // the module-only map the extension falls back to when the
        // profile has since changed. Interval strings (Stash
        // providers arrive via MiniYAML as all-strings) are coerced
        // back to numbers on the way out (see ruleProvidersJSON).
        let moduleProviders = ruleProvidersJSON(merged.ruleProviders)
        let (profileProviders, digest) = profileRuleProviders()
        var allProviders = ruleProvidersJSON(profileProviders)
        for (name, provider) in moduleProviders { allProviders[name] = provider }
        if !allProviders.isEmpty { json["rule-providers"] = allProviders }
        if !moduleProviders.isEmpty { json["module-rule-providers"] = moduleProviders }
        if let digest { json["profileDigest"] = digest }
        // Network edits, raw: the extension applies them onto the
        // effective dns / hosts / tun it already builds for the
        // overlay (those ARE the profile's lists as the core sees
        // them — the overlay replaces the profile's sections).
        if !merged.network.isEmpty { json["network"] = moduleNetworkJSON(merged.network) }
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.moduleMitmFileName),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Merged file: providers, network, digests

    /// JSONValue as JSONSerialization's Any (mirror of
    /// OverrideStore.jsonValueToAny, which is private there).
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }

    /// Rule providers as the profile's `rule-providers` map. The
    /// profile reads `interval` as a number, so a string interval
    /// (Stash providers: MiniYAML stores every scalar as a string)
    /// is coerced back when it parses as one; anything else stays
    /// a string, and the core rejects it with its own error.
    private func ruleProvidersJSON(_ providers: [String: [String: JSONValue]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, provider) in providers {
            var dict: [String: Any] = [:]
            for (key, value) in provider {
                if key == "interval", case .string(let text) = value,
                   let seconds = Int64(text) {
                    dict[key] = seconds
                } else {
                    dict[key] = jsonValueToAny(value)
                }
            }
            out[name] = dict
        }
        return out
    }

    /// The merged network edits as the extension reads them
    /// (kebab-case keys, the profile's own names): list edits as
    /// {replace, before, after}, domain entries as
    /// [{domain, values}], included routes as a plain list.
    private func moduleNetworkJSON(_ network: MitmModuleNetwork) -> [String: Any] {
        var out: [String: Any] = [:]
        if let value = network.nameserver { out["nameserver"] = listEditJSON(value) }
        if let value = network.defaultNameserver { out["default-nameserver"] = listEditJSON(value) }
        if let value = network.fakeIpFilter { out["fake-ip-filter"] = listEditJSON(value) }
        if !network.nameserverPolicy.isEmpty { out["nameserver-policy"] = domainEntriesJSON(network.nameserverPolicy) }
        if !network.hosts.isEmpty { out["hosts"] = domainEntriesJSON(network.hosts) }
        if !network.routeAddress.isEmpty { out["route-address"] = network.routeAddress }
        if let value = network.routeExcludeAddress { out["route-exclude-address"] = listEditJSON(value) }
        if let value = network.bypassDomain { out["bypass-domain"] = listEditJSON(value) }
        return out
    }

    private func listEditJSON(_ edit: MitmListEdit) -> [String: Any] {
        ["replace": edit.replace, "before": edit.before, "after": edit.after]
    }

    private func domainEntriesJSON(_ entries: [MitmDomainEntry]) -> [[String: Any]] {
        entries.map { ["domain": $0.domain, "values": $0.values] }
    }

    /// FNV-1a 64-bit, hex — MUST match
    /// PacketTunnelProvider.fnv1aHex: the digest tags a merged
    /// rule-provider map with the profile bytes it was computed
    /// against, and the extension compares it with the config.yaml
    /// it is about to apply.
    private func fnv1aHex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// The active profile's `rule-providers:`, read out of the
    /// shared config.yaml (the file ProfileStore copies the active
    /// profile to), with the digest of the profile bytes. The
    /// profile has no YAML parser in this target (MiniYAML is
    /// private to MitmModuleParser.swift), so this is a targeted
    /// block scan in the shape subscriptions emit — the same
    /// precedent as HostsView.subscriptionHosts. Returns no
    /// providers (but still the digest) when the section is absent
    /// or unreadable; the merged map then holds the module
    /// providers only, which is the same fallback the extension
    /// uses for a changed profile.
    private func profileRuleProviders() -> (providers: [String: [String: JSONValue]], digest: String?) {
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.configFileName),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return ([:], nil) }
        return (scanRuleProviders(in: text) ?? [:], fnv1aHex(data))
    }

    /// The `rule-providers:` block as provider maps. Nil when the
    /// block uses YAML the scanner does not read (anchors, aliases,
    /// block scalars, one-line flow maps of providers); [:] when
    /// the section is absent or empty. Indentation is relative:
    /// the first indented level under the key holds the provider
    /// names, the next holds `key: value` entries, and `payload:`
    /// lists hold `- item` lines one level deeper.
    private func scanRuleProviders(in yaml: String) -> [String: [String: JSONValue]]? {
        let lines = yaml.components(separatedBy: "\n")
        guard let keyIndex = lines.firstIndex(where: {
            $0 == "rule-providers:" || $0.hasPrefix("rule-providers: ")
        }) else { return [:] }
        let rest = lines[keyIndex].dropFirst("rule-providers:".count)
            .trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            // Block style below.
        } else if rest == "{}" || rest == "null" || rest == "~" {
            return [:]
        } else {
            return nil
        }
        var providers: [String: [String: JSONValue]] = [:]
        var current: String?
        var providerIndent: Int?
        var entryIndent: Int?
        var payloadName: String?
        var i = keyIndex + 1
        func indent(of line: String) -> Int {
            line.prefix(while: { $0 == " " }).count
        }
        while i < lines.count {
            let raw = lines[i]
            i += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let ind = indent(of: raw)
            if ind == 0 { break }
            if trimmed.hasPrefix("&") || trimmed.hasPrefix("*") || trimmed.hasPrefix("? ") { return nil }
            if let providerIndent, ind < providerIndent { return nil }
            if providerIndent == nil {
                providerIndent = ind
            }
            if ind == providerIndent {
                // A provider name: `Name:` or `Name: {…}`. A
                // `- item` here means the block is a sequence,
                // not a provider map — unreadable, not a provider.
                guard !trimmed.hasPrefix("- ") else { return nil }
                payloadName = nil
                entryIndent = nil
                if trimmed.hasSuffix(":") {
                    let name = yamlUnquote(String(trimmed.dropLast()))
                    guard !name.isEmpty else { return nil }
                    current = name
                    providers[name] = [:]
                } else if let map = yamlFlowMap(trimmed) {
                    current = map.name
                    providers[map.name] = map.values
                } else {
                    return nil
                }
                continue
            }
            guard let name = current else { return nil }
            if entryIndent == nil {
                entryIndent = ind
            }
            if ind < entryIndent! { return nil }
            if ind == entryIndent! {
                payloadName = nil
                if trimmed.hasSuffix(":") && !trimmed.contains(": ") {
                    // `payload:` (or another nested key): only
                    // payload lists are read; anything else ends
                    // the provider's readable entries.
                    let key = yamlUnquote(String(trimmed.dropLast()))
                    if key == "payload" {
                        payloadName = name
                        providers[name]?["payload"] = .array([])
                    } else {
                        return nil
                    }
                    continue
                }
                guard let (key, value) = yamlKeyValue(trimmed) else { return nil }
                if value.hasPrefix("[") {
                    guard let items = yamlFlowList(value) else { return nil }
                    providers[name]?[key] = .array(items.map { .string($0) })
                } else if value.hasPrefix("{") {
                    return nil
                } else {
                    guard let scalar = yamlScalar(value) else { return nil }
                    providers[name]?[key] = scalar
                }
                continue
            }
            // A list item under `payload:`.
            guard payloadName == name, trimmed.hasPrefix("- ") else { return nil }
            let item = yamlUnquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            if case .array(var items) = providers[name]?["payload"] {
                items.append(.string(item))
                providers[name]?["payload"] = .array(items)
            } else {
                return nil
            }
        }
        return providers
    }

    /// `Name: {k: v, …}` on one line: the name and its flat
    /// entries. Nil when the line is not that shape.
    private func yamlFlowMap(_ line: String) -> (name: String, values: [String: JSONValue])? {
        guard let colon = line.firstIndex(of: ":"),
              line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).hasPrefix("{") else { return nil }
        let name = yamlUnquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
        let inner = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{"), inner.hasSuffix("}") else { return nil }
        let body = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if body.isEmpty { return (name, [:]) }
        var values: [String: JSONValue] = [:]
        for part in yamlTopLevelSplit(body) {
            guard let (key, value) = yamlKeyValue(part) else { return nil }
            if value.hasPrefix("[") || value.hasPrefix("{") { return nil }
            guard let scalar = yamlScalar(value) else { return nil }
            values[key] = scalar
        }
        return (name, values)
    }

    /// `[a, b]` on one line, as plain or quoted scalars.
    private func yamlFlowList(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return yamlTopLevelSplit(inner).map { yamlUnquote($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Splits on top-level commas (commas inside quotes or
    /// brackets do not split; a backslash escapes the next char
    /// inside double quotes).
    private func yamlTopLevelSplit(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var single = false
        var double = false
        var escaped = false
        var current = ""
        for char in text {
            if single {
                current.append(char)
                if char == "'" { single = false }
            } else if double {
                current.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    double = false
                }
            } else if char == "'" {
                single = true
                current.append(char)
            } else if char == "\"" {
                double = true
                current.append(char)
            } else if char == "[" || char == "{" {
                depth += 1
                current.append(char)
            } else if char == "]" || char == "}" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                out.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        out.append(current)
        return out
    }

    /// `key: value` split on the first colon that ends the key
    /// (a colon followed by a space, or at end of line).
    private func yamlKeyValue(_ line: String) -> (key: String, value: String)? {
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " {
                    let key = yamlUnquote(String(line[..<index]).trimmingCharacters(in: .whitespaces))
                    let value = String(line[next...]).trimmingCharacters(in: .whitespaces)
                    return key.isEmpty ? nil : (key, value)
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// A scalar: quotes stripped, a trailing `# comment` outside
    /// quotes stripped, booleans and integers typed, the rest a
    /// string. Nil for YAML the scanner does not read (anchors,
    /// aliases, block scalars).
    private func yamlScalar(_ text: String) -> JSONValue? {
        let stripped = yamlStripComment(text).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty || stripped == "null" || stripped == "~" { return .null }
        if stripped.hasPrefix("&") || stripped.hasPrefix("*")
            || stripped.hasPrefix("|") || stripped.hasPrefix(">") { return nil }
        let unquoted = yamlUnquote(stripped)
        switch unquoted.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        if let number = Int64(unquoted) { return .int(number) }
        return .string(unquoted)
    }

    /// Strips a ` # comment` outside quotes; a `#` inside quotes
    /// or without a space before it is kept.
    private func yamlStripComment(_ text: String) -> String {
        var single = false
        var double = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if single {
                if char == "'" { single = false }
            } else if double {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    double = false
                }
            } else if char == "'" {
                single = true
            } else if char == "\"" {
                double = true
            } else if char == "#", index > text.startIndex, text[text.index(before: index)] == " " {
                return String(text[..<index])
            }
            index = text.index(after: index)
        }
        return text
    }

    /// Removes one pair of surrounding quotes (single: '' is an
    /// escaped quote; double: \" and \\ are unescaped).
    private func yamlUnquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }

    /// Removes every resource file no module names, so a deleted
    /// module or an updated script does not leave files behind. Only
    /// touches <AppGroup>/mitm/resources — the CA store lives in
    /// <AppGroup>/mitm/ itself and is never swept.
    ///
    /// Standalone scripts' runnable copies live in the same
    /// directory (MitmScriptStore.writeResourceCopy, content-hash
    /// name), so the retain set also includes every
    /// `resourceName` in the scripts registry
    /// (<AppGroup>/mitm/scripts/scripts.json): toggling, updating
    /// or deleting any module must not break a running standalone
    /// script (audit B39).
    private func sweepResources() {
        guard let dir = resourcesDirectoryURL else { return }
        var referenced = Set(modules.flatMap { $0.resources.values })
        referenced.formUnion(standaloneScriptResourceNames())
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The content-hash resource names of the standalone scripts
    /// (MitmScriptStore registry), so sweepResources() keeps their
    /// runnable copies. Read straight from the registry file: the
    /// module store must not depend on the script store's live
    /// instance (Shortcuts / background refresh may not have one).
    private func standaloneScriptResourceNames() -> Set<String> {
        guard let container = containerURL else { return [] }
        let registry = container.appendingPathComponent("mitm")
            .appendingPathComponent("scripts")
            .appendingPathComponent("scripts.json")
        guard let data = try? Data(contentsOf: registry),
              let scripts = try? JSONDecoder().decode([MitmScript].self, from: data) else { return [] }
        return Set(scripts.compactMap(\.resourceName))
    }

    // MARK: - Resources

    /// Writes each `inline:` script text into the resources
    /// directory and records the filename under its key, so a
    /// later parse resolves it (the parser's resource() inline:
    /// branch looks the key up in the module's resources). Files
    /// are content-hash named (mitmResourceName), like downloads,
    /// so the same text always maps to the same file and
    /// sweepResources keeps it while the module names it.
    private func materializeInlineResources(_ content: MitmModuleContent, into resources: inout [String: String]) {
        guard !content.inlineResources.isEmpty, let dir = resourcesDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (key, text) in content.inlineResources {
            if let existing = resources[key],
               FileManager.default.fileExists(atPath: dir.appendingPathComponent(existing).path) { continue }
            let name = mitmResourceName(source: key, bytes: Data(text.utf8))
            do {
                try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
                resources[key] = name
            } catch {
                continue
            }
        }
    }

    /// Materialises the inline scripts of the enabled modules
    /// (modules imported before materialisation existed never had
    /// their payload scripts written out). Called from
    /// writeMergedFile, before the merge parses them.
    private func materializeInlineResourcesForEnabledModules() {
        var changed = false
        for i in modules.indices where modules[i].enabled {
            guard let content = parsedContent(for: modules[i]),
                  !content.inlineResources.isEmpty else { continue }
            var resources = modules[i].resources
            materializeInlineResources(content, into: &resources)
            if resources != modules[i].resources {
                modules[i].resources = resources
                changed = true
            }
        }
        if changed { persist() }
    }

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
                let data = try await mitmDownloadValidated(from: url)
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

    /// True when the core can read a module right now: the client is
    /// live AND the tunnel is running. Upstream every add/edit/update
    /// path goes through readMitmModule → core RPC, which throws
    /// core_unavailable when the core is not connected; the local
    /// Swift parse never calls the core, so without this guard an
    /// add/edit/update succeeds with the VPN off — the opposite of
    /// upstream. AppCore.isRunning does NOT count (the live transport
    /// is only ExtensionConcordTransport, so with the VPN off a unary
    /// call fails) and sample mode does NOT count (a Mock transport
    /// would fake success). On refusal records the sentence
    /// (l10n_zh coreUnavailableTip, verbatim) in lastError and ticks
    /// coreUnavailableCount so the views show the confirm dialog
    /// titled with the module name; nothing is written and the row is
    /// untouched — the same "keep as-is" as upstream's _save exiting
    /// on a readMitmModule throw before File.write.
    @MainActor
    private func guardCoreRunning(named name: String) -> Bool {
        guard client?.mode == .live, TunnelManager.shared.isRunning else {
            lastError = "核心未运行，请在核心启动后重试"
            coreUnavailableName = name
            coreUnavailableCount += 1
            return false
        }
        return true
    }

    // MARK: - Add / edit / update

    /// Imports from a URL or another app's install link
    /// (surge://install-module, loon://import, shadowrocket://install,
    /// stash://install-override, quantumult-x add-resource).
    /// Returns the saved module, or nil when the import failed.
    @MainActor
    @discardableResult
    func addFromURL(_ text: String) async -> MitmModule? {
        let urls = mitmModuleUrls(text)
        guard let urlString = urls.first, let url = URL(string: urlString) else {
            lastError = "不是有效的模块链接"
            return nil
        }
        guard guardCoreRunning(named: moduleName(from: urlString)) else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await mitmDownloadValidated(from: url)
            guard let moduleText = String(data: data, encoding: .utf8), !moduleText.isEmpty else {
                lastError = "下载的模块内容为空"
                return nil
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
            return module
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Imports pasted text or a local file's contents. Returns the
    /// saved module, or nil when the import failed.
    @MainActor
    @discardableResult
    func addFromText(_ text: String, fileName: String?) async -> MitmModule? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "模块内容为空"
            return nil
        }
        guard guardCoreRunning(named: moduleName(from: fileName)) else { return nil }
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
            return module
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            return nil
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
    /// Returns the saved module, or nil when the save failed.
    @MainActor
    @discardableResult
    func edit(_ module: MitmModule, text: String) async -> MitmModule? {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return nil }
        guard guardCoreRunning(named: module.name) else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let previousText = readText(module)
            var updated = try await save(module, text: text, added: false, previousText: previousText, edited: true)
            updated.lastUpdateTime = Date()
            modules[index] = updated
            persist()
            await refreshModuleFiles()
            statusMessage = updated.enabled ? "已保存模块 \(updated.name)" : "已保存模块 \(updated.name)（含新脚本，已暂停，需手动开启）"
            lastError = nil
            return updated
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Re-downloads a remote module, or re-reads a local module's
    /// text file and re-parses it. Returns the saved module, or nil
    /// when the update failed.
    @MainActor
    @discardableResult
    func update(_ module: MitmModule) async -> MitmModule? {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return nil }
        guard guardCoreRunning(named: module.name) else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let previousText = readText(module)
            let text: String
            if let urlString = module.url, let url = URL(string: urlString) {
                let data = try await mitmDownloadValidated(from: url)
                guard let downloaded = String(data: data, encoding: .utf8), !downloaded.isEmpty else {
                    lastError = "更新失败：下载内容为空"
                    return nil
                }
                text = downloaded
            } else if let local = previousText {
                text = local
            } else {
                lastError = "更新失败：模块文件丢失，请重新导入"
                return nil
            }
            var updated = try await save(module, text: text, added: false, previousText: previousText)
            updated.lastUpdateTime = Date()
            modules[index] = updated
            persist()
            await refreshModuleFiles()
            statusMessage = updated.enabled ? "已更新模块 \(updated.name)" : "已更新模块 \(updated.name)（含新脚本，已暂停，需手动开启）"
            lastError = nil
            return updated
        } catch {
            lastError = "更新失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Moves a subscribed module to a new URL (upstream
    /// MitmModulesAction.changeUrl → _refresh + _save): the new URL
    /// is downloaded first — on download failure the old URL is kept
    /// and only lastError is set — then the text is saved through
    /// save(url:), so the row takes the new url/name/desc/system and
    /// a move while enabled resets `accepted`. Returns the saved
    /// module, or nil when the move failed.
    @MainActor
    @discardableResult
    func changeUrl(_ module: MitmModule, url: String) async -> MitmModule? {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return nil }
        // Upstream _editModuleUrl checks this before the core call,
        // so a duplicate wins over the core-down error too.
        if modules.contains(where: { $0.id != module.id && $0.url == url }) {
            lastError = "模块当前已存在"
            return nil
        }
        guard guardCoreRunning(named: module.name) else { return nil }
        guard let downloadURL = URL(string: url) else {
            lastError = "不是有效的模块链接"
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await mitmDownloadValidated(from: downloadURL)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                lastError = "更新失败：下载内容为空"
                return nil
            }
            let previousText = readText(module)
            var updated = try await save(module, text: text, added: false, previousText: previousText, url: url)
            updated.lastUpdateTime = Date()
            modules[index] = updated
            persist()
            await refreshModuleFiles()
            statusMessage = updated.enabled ? "已更新模块 \(updated.name)" : "已更新模块 \(updated.name)（含新脚本，已暂停，需手动开启）"
            lastError = nil
            return updated
        } catch {
            lastError = "更新失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// The core of add/edit/update: parse, download the resources the
    /// new content names, write the text file, and decide the enabled
    /// flag by the script-consent rules. Returns the saved row.
    /// Upstream `_save` rejects an empty module on add but allows
    /// editing one down to empty (`content.isEmpty && !edited`) —
    /// the blank template still needs a line before it can be
    /// created, exactly as upstream rejects it.
    private func save(_ module: MitmModule, text: String, added: Bool, previousText: String?, edited: Bool = false, url: String? = nil) async throws -> MitmModule {
        let firstContent = MitmModuleParser.parse(text: text, values: module.arguments, resources: module.resources)
        if firstContent.isEmpty && !edited {
            throw MitmModuleError(message: "模块内容为空或无法识别")
        }
        let resources = await downloadResources(firstContent.resourceUrls, previous: module.resources)
        // Non-URL resources are local-file attachments; the
        // downloaded ones replace the previous set for these URLs.
        var mergedResources = module.resources.filter { !isMitmResourceUrl($0.key) }
        for (url, name) in resources { mergedResources[url] = name }
        // Stash payload scripts live in the module text itself
        // (inline:<hash>.js): write each into the resources
        // directory and re-parse, or the first parse skips them as
        // .notDownloaded and the merged script list loses them.
        materializeInlineResources(firstContent, into: &mergedResources)
        let content = MitmModuleParser.parse(text: text, values: module.arguments, resources: mergedResources)
        try writeText(module, text: text)
        var saved = module
        saved.name = content.name ?? module.name
        saved.description = content.description ?? ""
        saved.system = content.system
        // A move to a new subscription URL (changeUrl) takes the new
        // url; every other save keeps the module's own (upstream
        // _save: url: url ?? current.url).
        saved.url = url ?? module.url
        saved.resources = mergedResources
        saved.lastUpdateTime = Date()
        // Whether the new content asks about anything besides
        // scripts (fork `_withContent` records this on every save).
        saved.asksConsent = asksConsent(of: content)
        if added {
            // A module added with scripts — or with other asks —
            // starts off until the user accepts them; `scripts`
            // stays 0 (nothing accepted yet) and `accepted` stays
            // nil, so it awaits consent (fork `_save` + `awaitsConsent`).
            saved.enabled = content.declaredScripts == 0 && !saved.asksConsent
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
                // on still asks for consent. Unlike the fork, this
                // build pauses even a module the user already agreed
                // to (the agreed source's later updates are not
                // trusted blindly); the pause is now persistent —
                // an update that actually turned the module off
                // leaves it awaiting consent (accepted nil) instead
                // of silently off. A module that was already off
                // keeps its answer (a declined module does not
                // start awaiting again).
                if module.enabled {
                    saved.enabled = false
                    saved.accepted = nil
                } else {
                    saved.enabled = false
                }
                saved.scripts = module.scripts
            } else {
                saved.enabled = module.enabled
                saved.scripts = content.declaredScripts
            }
        }
        // Upstream _save: a move to a new URL while enabled resets
        // `accepted` (re-consent on next enable) — even when the
        // scripts are unchanged, so this sits outside the
        // brings-new-scripts branch above (which only pauses when
        // scripts actually changed).
        if let url, url != module.url, module.enabled {
            saved.accepted = nil
        }
        return saved
    }

    // MARK: - Arguments

    /// Saves new argument values, downloading any resources the new
    /// values bring in. A module whose file cannot be read fails the
    /// change instead of returning nothing (fork `setArguments`).
    /// Turning the module off when the values declare more scripts
    /// than the user accepted leaves it awaiting consent.
    @MainActor
    func setArguments(_ module: MitmModule, values: [String: String]) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        guard guardCoreRunning(named: module.name) else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        // The new values are read and judged before they are saved,
        // so a module never agreed to does not run with them even
        // for a moment — and a file that cannot be read fails the
        // change instead of saving arguments for content that was
        // never parsed (fork `setArguments`).
        guard let text = readText(module) else {
            lastError = "模块文件丢失，参数未保存，请重新导入"
            return
        }
        modules[index].arguments = values
        persist()
        // New argument values can bring Stash payload scripts: write
        // them out before judging the content, or they read as
        // .notDownloaded and the scripts / consent state is wrong.
        var content = MitmModuleParser.parse(text: text, values: values, resources: module.resources)
        var updatedResources = modules[index].resources
        materializeInlineResources(content, into: &updatedResources)
        if updatedResources != modules[index].resources {
            modules[index].resources = updatedResources
            persist()
            content = MitmModuleParser.parse(text: text, values: values, resources: updatedResources)
        }
        modules[index].asksConsent = asksConsent(of: content)
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
            // back on still asks for consent — and the module now
            // awaits consent (accepted nil) instead of silently off.
            modules[index].enabled = false
            modules[index].accepted = nil
            persist()
            statusMessage = "参数使模块声明了新脚本，已暂停，需手动开启"
        }
        await refreshModuleFiles()
    }

    // MARK: - Toggle / reorder / delete

    /// Turns a module on or off. The view asks for consent before
    /// calling this with `on: true` for a module that asks (see
    /// consentPrompt). Turning off counts as declining until it is
    /// turned on again (fork `turnOff`): a never-asked module
    /// records the decline; an agreed module keeps its answer.
    @MainActor
    func setEnabled(_ module: MitmModule, on: Bool) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index].enabled = on
        if on, let content = parsedContent(for: modules[index]) {
            modules[index].scripts = content.declaredScripts
            modules[index].asksConsent = asksConsent(of: content)
        }
        if !on, modules[index].accepted == nil {
            modules[index].accepted = false
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

    // MARK: - Local-file attachments (upstream mitm_modules.dart
    // _attachmentItems / attach / detach)
    //
    // A local module's attachments are the non-URL entries of its
    // `resources`: the file name the module text names → the
    // content-hash file in the core's resources directory. The
    // parser resolves a map-local `data=<name>` through exactly
    // that map (see MitmModuleParser.resource), and save() already
    // keeps non-URL resources across edits and updates — only the
    // UI and these two calls were missing. Remote modules have no
    // attachments (upstream mitmAttachments filters them out).

    /// This module's attachments: the file name the module names,
    /// in the order they were attached.
    func attachments(of module: MitmModule) -> [String] {
        module.resources.keys.filter { !isMitmResourceUrl($0) }.sorted()
    }

    /// The `attachments` map mitm.readModule takes: the file name
    /// the module names → the stored file in the resources dir.
    private func attachmentsParam(for module: MitmModule) -> [String: String] {
        module.resources.filter { !isMitmResourceUrl($0.key) }
    }

    /// Attaches a local file to a local module: writes the bytes
    /// into the resources directory under their content-hash name
    /// and records the name the module text will use. A file the
    /// same name was attached under is replaced, as upstream does.
    @MainActor
    func attachFile(_ module: MitmModule, fileName: String, data: Data) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        guard modules[index].url == nil else {
            lastError = "远程模块不能添加本地附件"
            return
        }
        guard data.count <= maxMitmResourceSize else {
            lastError = "文件过大（最大 \(maxMitmResourceSize / 1_048_576) MB）"
            return
        }
        guard let dir = resourcesDirectoryURL else {
            lastError = "App Group 容器不可用"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stored = mitmResourceName(source: fileName, bytes: data)
            try data.write(to: dir.appendingPathComponent(stored), options: .atomic)
            modules[index].resources[fileName] = stored
            persist()
            await refreshModuleFiles()
            statusMessage = "已为模块 \(module.name) 添加附件 \(fileName)"
            lastError = nil
        } catch {
            lastError = "添加附件失败：\(error.localizedDescription)"
        }
    }

    /// Detaches a local file from a local module: drops the mapping
    /// (the next sweep removes the stored file when nothing names
    /// it any more) and re-applies the merged config.
    @MainActor
    func detachAttachment(_ module: MitmModule, name: String) async {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index].resources.removeValue(forKey: name)
        persist()
        await refreshModuleFiles()
        statusMessage = "已从模块 \(module.name) 移除附件 \(name)"
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

// MARK: - Validated downloads (audit B40)
//
// Module / script downloads used to ignore the HTTP response, so a
// dead link's 404 HTML error page was stored as a module or a .js
// resource for the core to run. Every download in this file,
// MitmScriptStore and ScriptsView goes through here: non-2xx
// and HTML error pages fail with an honest error and are never
// stored.

/// Downloads `url` and rejects anything that is not a successful
/// (2xx) non-HTML response. Throws MitmModuleError with the real
/// reason (HTTP status or "HTML error page").
func mitmDownloadValidated(from url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse else {
        throw MitmModuleError(message: "下载失败：服务器没有返回 HTTP 响应")
    }
    guard (200...299).contains(http.statusCode) else {
        throw MitmModuleError(message: "下载失败：HTTP \(http.statusCode)")
    }
    if let mimeType = http.mimeType, mimeType.lowercased().contains("html") {
        throw MitmModuleError(message: "下载失败：服务器返回了 HTML 错误页（HTTP \(http.statusCode)），不是模块/脚本")
    }
    if mitmDataLooksLikeHTML(data) {
        throw MitmModuleError(message: "下载失败：内容是 HTML 错误页，不是模块/脚本")
    }
    return data
}

/// True when the bytes start with an HTML document marker
/// (after whitespace / a UTF-8 BOM): a 404 page served with a
/// 200 status and a generic content type.
func mitmDataLooksLikeHTML(_ data: Data) -> Bool {
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    let prefix = bytes.prefix(256)
    guard let head = String(bytes: prefix, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() else { return false }
    return head.hasPrefix("<!doctype") || head.hasPrefix("<html")
        || head.hasPrefix("<head") || head.hasPrefix("<title")
}
