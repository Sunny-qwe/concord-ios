import Foundation
import Combine

// MARK: - Unified import (batch orchestrator)
// One entry point for every import: subscription links, node share
// links and whole YAML text. It wraps ONLY existing ProfileStore
// methods (addFromURL / addFromFile / delete / activate / decodeLinks)
// — no existing method was changed for this feature.
//
// Batch rules (upstream add.dart showNamedUrlsForm +
// addProfilesFromLinks, restored in v0.2.146 — the earlier
// one-item-per-tap direction is superseded by the user's
// "全部按照上游" order):
//  - a whole YAML document counts as one item;
//  - every subscription link becomes its own profile;
//  - ALL node share links together become one profile (the
//    generated "我的节点" config), in the place of the first;
//  - lines that are neither are reported as unrecognised, never
//    silently dropped;
//  - the first successfully imported profile is activated once at
//    the end.
// Success detection is by snapshot: ProfileStore appends the profile
// BEFORE writing its file, so a save failure leaves the profile in
// the list with lastError set. A call only counts as success when
// the count grew AND lastError is nil.

/// One pasted line's import outcome (shown in the import sheet).
struct ImportLineResult: Identifiable {
    let id = UUID()
    /// Original line order; the generated-config row sorts last.
    let order: Int
    let line: String
    let kind: ImportKind
    let succeeded: Bool
    let message: String
}

enum ImportKind: String {
    case subscription = "订阅"
    case nodes = "节点"
    case yaml = "配置"
    case unknown = "未知"
}

enum ImportLineKind {
    case subscription
    case nodeLink
    case unknown
}

/// An age-encrypted file waiting for its decryption key.
struct PendingAgeFile {
    let data: Data
    let fileName: String
}

final class UnifiedImporter: ObservableObject {
    @Published var results: [ImportLineResult] = []
    @Published var isImporting = false
    @Published var summaryText: String?
    @Published var activatedName: String?
    /// An age-encrypted file waiting for its key (upstream
    /// _withAgeSecretKey): the + menu file path sets this when
    /// the picked file is age-encrypted and no key was given,
    /// and ProfilesView shows the key prompt for it. Cleared as
    /// soon as a key is supplied (success or failure).
    @Published var pendingAgeFile: PendingAgeFile?

    let profileStore: ProfileStore

    /// Profiles imported successfully, in pasted-line order — the
    /// first one is activated when the batch finishes.
    private var successProfiles: [(order: Int, profile: Profile)] = []

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    // MARK: - Classification

    /// All node-link schemes the core can decode (convert.decodeLinks).
    static let nodeSchemes = ["ss://", "vmess://", "trojan://", "vless://", "ssr://", "hysteria2://", "hysteria://",
                              "tuic://", "mieru://", "anytls://", "snell://", "wireguard://", "wg://",
                              "ssh://", "socks5://", "socks://"]

    static func kind(of line: String) -> ImportLineKind {
        let lower = line.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return .subscription }
        if nodeSchemes.contains(where: { lower.hasPrefix($0) }) { return .nodeLink }
        return .unknown
    }

    /// True when the whole text is one YAML document: no link lines,
    /// and it declares proxies / proxy-groups / proxy-providers.
    static func looksLikeYamlDocument(_ text: String) -> Bool {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else { return false }
        guard !lines.contains(where: { kind(of: $0) != .unknown }) else { return false }
        return lines.contains {
            $0.hasPrefix("proxies:") || $0.hasPrefix("proxy-groups:") || $0.hasPrefix("proxy-providers:")
        }
    }

    /// Detected kind of the first item (for the UI's type chip).
    static func singleItemKind(_ text: String) -> ImportKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if looksLikeYamlDocument(trimmed) { return .yaml }
        guard let first = nonEmptyLines(trimmed).first(where: { kind(of: $0) != .unknown }) else { return .unknown }
        switch kind(of: first) {
        case .subscription: return .subscription
        case .nodeLink: return .nodes
        case .unknown: return .unknown
        }
    }

    static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Core-side decoding (convert.decodeLinks) needs the tunnel
    /// running in live mode; in sample mode the mock answers.
    private var canUseCoreDecode: Bool {
        profileStore.client.mode == .sample || TunnelManager.shared.isRunning
    }

    // MARK: - Entry points

    @MainActor
    func importText(_ text: String, name: String? = nil, yamlName: String? = nil, ageSecretKey: String? = nil) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        results = []
        summaryText = nil
        activatedName = nil
        successProfiles = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            summaryText = "请先粘贴内容"
            return
        }
        var activationFailure: String?
        if Self.looksLikeYamlDocument(trimmed) {
            await importYamlDocument(trimmed, yamlName: yamlName ?? name)
        } else {
            await importLines(trimmed, name: name, ageSecretKey: ageSecretKey)
        }
        results.sort { $0.order < $1.order }
        // Activate the first imported profile once at the end.
        if let first = successProfiles.sorted(by: { $0.order < $1.order }).first {
            await profileStore.activate(first.profile)
            if profileStore.lastError == nil {
                activatedName = first.profile.name
            } else {
                activationFailure = "切换到「\(first.profile.name)」失败：\(profileStore.lastError ?? "")"
            }
        }
        let ok = results.filter { $0.succeeded }.count
        let failed = results.count - ok
        var summary = "导入完成：成功 \(ok) 个，失败 \(failed) 个"
        if let activated = activatedName {
            summary += "；已切换到「\(activated)」，去仪表盘点播放键启动即可"
        }
        if let activationFailure {
            summary += "；\(activationFailure)"
        }
        summaryText = summary
    }

    /// The + menu's 文件 item, with the age path (upstream
    /// addProfileFormFile → _withAgeSecretKey): an age-encrypted
    /// file first asks for the key (pendingAgeFile, shown by
    /// ProfilesView), then decrypts when a core is reachable.
    /// With no core reachable the ciphertext is saved WITH the
    /// key — the link flow's fallback — so a later 更新 decrypts
    /// it instead of the import failing outright.
    @MainActor
    func importFileData(_ data: Data, fileName: String, ageSecretKey: String? = nil) async {
        if ProfileStore.isAgeEncrypted(data) {
            let key = ageSecretKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty else {
                results = []
                pendingAgeFile = PendingAgeFile(data: data, fileName: fileName)
                summaryText = "该文件是 age 加密的，请填写私钥"
                return
            }
            pendingAgeFile = nil
            let base = (fileName as NSString).deletingPathExtension
            let yamlBase = base.isEmpty ? "导入的配置" : base
            if profileStore.client.mode == .live, TunnelManager.shared.isRunning {
                switch await profileStore.decryptAgeData(data, key: key) {
                case .success(let plain):
                    guard let text = String(data: plain, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        results = [ImportLineResult(order: 0, line: fileName, kind: .unknown, succeeded: false, message: "解密成功，但内容不是有效的 UTF-8 文本")]
                        summaryText = "解密成功，但内容无法识别"
                        return
                    }
                    await importText(text, yamlName: yamlBase)
                    return
                case .failure(let message):
                    results = [ImportLineResult(order: 0, line: fileName, kind: .unknown, succeeded: false, message: message)]
                    summaryText = "解密失败：\(message)"
                    return
                }
            }
            // No core reachable (VPN off / sample mode): save the
            // ciphertext with the key, like the link flow.
            let name = uniqueYamlName(base: yamlBase)
            let beforeCount = profileStore.profiles.count
            profileStore.addFromFile(name: name, data: data, ageSecretKey: key)
            if profileStore.profiles.count > beforeCount, profileStore.lastError == nil,
               let created = profileStore.profiles.last {
                results = [ImportLineResult(order: 0, line: name, kind: .yaml, succeeded: true, message: "已保存加密文件「\(name)」（未启动 VPN，无法当场解密；已保存私钥，更新时解密）")]
                successProfiles = [(order: 0, profile: created)]
                // No activation here: an age ciphertext cannot be
                // applied yet (applyProfile refuses it until it is
                // decrypted). The user taps 更新 on the card, which
                // decrypts with the stored key.
                summaryText = "导入完成：成功 1 个，失败 0 个；已保存加密文件「\(name)」，请点「更新」解密后再切换"
            } else {
                results = [ImportLineResult(order: 0, line: name, kind: .yaml, succeeded: false, message: "保存失败：\(profileStore.lastError ?? "原因未知")")]
                summaryText = "导入失败：\(profileStore.lastError ?? "原因未知")"
            }
            return
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryText = "文件不是 UTF-8 文本，无法导入"
            return
        }
        let base = (fileName as NSString).deletingPathExtension
        await importText(text, yamlName: base.isEmpty ? nil : base)
    }

    // MARK: - Single subscription (reuses addFromURL)

    @MainActor
    private func importSubscriptionURL(_ urlString: String, name: String? = nil, ageSecretKey: String? = nil) async -> Result<Profile, NodeLinkError> {
        let beforeCount = profileStore.profiles.count
        await profileStore.addFromURL(name: name ?? "", urlString: urlString, ageSecretKey: ageSecretKey)
        if profileStore.profiles.count > beforeCount,
           profileStore.lastError == nil,
           let created = profileStore.profiles.last {
            return .success(created)
        }
        return .failure(NodeLinkError(message: profileStore.lastError ?? "导入失败（原因未知）"))
    }

    // MARK: - Whole YAML document

    @MainActor
    private func importYamlDocument(_ text: String, yamlName: String?) async {
        let name = uniqueYamlName(base: yamlName ?? "导入的配置")
        let beforeCount = profileStore.profiles.count
        profileStore.addFromFile(name: name, data: Data(text.utf8))
        if profileStore.profiles.count > beforeCount,
           profileStore.lastError == nil,
           let created = profileStore.profiles.last {
            results.append(ImportLineResult(order: 0, line: name, kind: .yaml, succeeded: true, message: "已保存为本地配置「\(name)」"))
            successProfiles.append((order: 0, profile: created))
        } else {
            results.append(ImportLineResult(order: 0, line: name, kind: .yaml, succeeded: false, message: "保存失败：\(profileStore.lastError ?? "原因未知")"))
        }
    }

    // MARK: - Lines (batch: every subscription link is its own
    // profile, ALL node links together are one profile)

    /// Imports every importable line (upstream
    /// addProfilesFromLinks): subscription links each become
    /// their own profile; all node share links together become
    /// the one generated "我的节点" config; lines that are
    /// neither get an unrecognised row instead of being dropped
    /// silently.
    @MainActor
    private func importLines(_ text: String, name: String?, ageSecretKey: String? = nil) async {
        let lines = Self.nonEmptyLines(text)
        let importable = lines.enumerated().filter { Self.kind(of: $0.element) != .unknown }
        guard !importable.isEmpty else {
            results.append(ImportLineResult(order: 0, line: lines.first ?? text, kind: .unknown, succeeded: false, message: "无法识别：不是订阅链接、节点链接或 YAML（整段 YAML 请单独粘贴导入）"))
            return
        }
        for (offset, line) in lines.enumerated() where Self.kind(of: line) == .unknown {
            results.append(ImportLineResult(order: offset, line: line, kind: .unknown, succeeded: false, message: "无法识别：不是订阅链接、节点链接或 YAML，已跳过"))
        }
        // The form's name field names ONE profile: with several
        // subscription links it applies to none of them (each
        // derives its name from its own download, like upstream's
        // per-link labels); with exactly one it names that one.
        let subscriptionLines = importable.filter { Self.kind(of: $0.element) == .subscription }
        let singleName = subscriptionLines.count == 1 ? name : nil
        for (index, line) in subscriptionLines {
            switch await importSubscriptionURL(line, name: singleName, ageSecretKey: ageSecretKey) {
            case .success(let profile):
                results.append(ImportLineResult(order: index, line: line, kind: .subscription, succeeded: true, message: "已导入订阅「\(profile.name)」"))
                successProfiles.append((order: index, profile: profile))
            case .failure(let error):
                results.append(ImportLineResult(order: index, line: line, kind: .subscription, succeeded: false, message: "导入失败：\(error.message)"))
            }
        }
        let nodeLines = importable.filter { Self.kind(of: $0.element) == .nodeLink }
        if !nodeLines.isEmpty {
            await importNodeLines(nodeLines.map { (index: $0.offset, line: $0.element) }, totalLines: lines.count)
        }
    }

    // MARK: - Node lines (local parse + core fallback + default config)

    @MainActor
    private func importNodeLines(_ nodeLines: [(index: Int, line: String)], totalLines: Int) async {
        var localParsed: [(index: Int, line: String, node: ParsedNode)] = []
        var failed: [(index: Int, line: String, reason: String)] = []
        for (index, line) in nodeLines {
            switch NodeLinkParser.parse(line) {
            case .success(let node):
                localParsed.append((index: index, line: line, node: node))
            case .failure(let error):
                failed.append((index: index, line: line, reason: error.message))
            }
        }
        // Core fallback (convert.decodeLinks) for lines the local
        // parser could not handle — only when the core is reachable
        // (tunnel running, or sample mode). decodeLinks takes the
        // lines in order and returns one [JSONValue] per line, so
        // results line up with `failed` by index.
        var coreDecoded: [JSONValue] = []
        var coreSucceeded: Set<Int> = []
        if !failed.isEmpty, canUseCoreDecode {
            await profileStore.decodeLinks(failed.map { $0.line })
            for (j, entry) in profileStore.decodedResults.enumerated() where j < failed.count {
                if !entry.isEmpty {
                    coreDecoded.append(contentsOf: entry)
                    coreSucceeded.insert(failed[j].index)
                }
            }
        }
        for (index, line, node) in localParsed {
            // Surface parser warnings (e.g. a transport option the
            // local model cannot represent, kept with a warning) so
            // the import does not look cleaner than it is.
            let warning = node.warnings.first.map { "（\($0)）" } ?? ""
            results.append(ImportLineResult(order: index, line: line, kind: .nodes, succeeded: true, message: "已解析节点「\(node.name)」\(warning)"))
        }
        for (index, line, reason) in failed {
            if coreSucceeded.contains(index) {
                results.append(ImportLineResult(order: index, line: line, kind: .nodes, succeeded: true, message: "本地解析不了，已通过核心解析"))
            } else {
                let extra = canUseCoreDecode
                    ? "；核心解析也没有结果"
                    : "；需启动 VPN 后再导入一次，会自动改用核心解析"
                results.append(ImportLineResult(order: index, line: line, kind: .nodes, succeeded: false, message: "解析失败：\(reason)\(extra)"))
            }
        }
        let allProxies = localParsed.map { $0.node.jsonValue } + coreDecoded
        guard !allProxies.isEmpty else { return }
        let yaml = DefaultConfig.yaml(proxies: allProxies)
        // Replace semantics: a previous "我的节点" is overwritten.
        // deleteProfile (audit B1) handles the active case: if the
        // old "我的节点" was the active profile it switches away /
        // stops the VPN instead of leaving the tunnel running a
        // deleted config — the new profile is activated at the end
        // of importText anyway.
        if let existing = profileStore.profiles.first(where: { $0.name == DefaultConfig.profileName }) {
            await profileStore.deleteProfile(existing)
        }
        let beforeCount = profileStore.profiles.count
        profileStore.addFromFile(name: DefaultConfig.profileName, data: Data(yaml.utf8))
        if profileStore.profiles.count > beforeCount, profileStore.lastError == nil,
           let created = profileStore.profiles.last {
            results.append(ImportLineResult(order: totalLines, line: DefaultConfig.profileName, kind: .nodes, succeeded: true, message: "已生成「我的节点」配置（\(allProxies.count) 个节点 + 节点选择分组 + 基础规则）"))
            successProfiles.append((order: totalLines, profile: created))
        } else {
            results.append(ImportLineResult(order: totalLines, line: DefaultConfig.profileName, kind: .nodes, succeeded: false, message: "生成配置失败：\(profileStore.lastError ?? "原因未知")"))
        }
    }

    // MARK: - Helpers

    private func uniqueYamlName(base: String) -> String {
        let existing = Set(profileStore.profiles.map { $0.name })
        guard existing.contains(base) else { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
