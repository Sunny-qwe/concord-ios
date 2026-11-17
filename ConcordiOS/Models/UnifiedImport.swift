import Foundation
import Combine

// MARK: - Unified import (batch orchestrator)
// One entry point for every import: subscription links, node share
// links and whole YAML text. It wraps ONLY existing ProfileStore
// methods (addFromURL / addFromFile / delete / activate / decodeLinks)
// — no existing method was changed for this feature.
//
// Batch rules (per the user's request):
//  - every pasted line is handled independently and gets its own
//    result, so a failure never hides behind a later success;
//  - node lines are collected and saved once as the "我的节点"
//    config (replacing an old one of the same name);
//  - the FIRST successful import is activated once at the end —
//    never once per line.
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

final class UnifiedImporter: ObservableObject {
    @Published var results: [ImportLineResult] = []
    @Published var isImporting = false
    @Published var summaryText: String?
    @Published var activatedName: String?

    let profileStore: ProfileStore

    /// Profiles imported successfully, in pasted-line order — the
    /// first one is activated when the batch finishes.
    private var successProfiles: [(order: Int, profile: Profile)] = []

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    // MARK: - Classification

    /// Schemes the local parser handles (no core, no VPN).
    static let localNodeSchemes = ["ss://", "vmess://", "trojan://", "vless://"]
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

    /// True when the text contains anything importable (for the
    /// clipboard prefill on open).
    static func looksImportable(_ text: String) -> Bool {
        if looksLikeYamlDocument(text) { return true }
        return nonEmptyLines(text).contains { kind(of: $0) != .unknown }
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
    func importText(_ text: String, yamlName: String? = nil) async {
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
            await importYamlDocument(trimmed, yamlName: yamlName)
        } else {
            await importLines(trimmed)
        }
        results.sort { $0.order < $1.order }
        // Activate the FIRST success once (not once per line).
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

    @MainActor
    func importFileData(_ data: Data, fileName: String) async {
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
    private func importSubscriptionURL(_ urlString: String) async -> Result<Profile, String> {
        let beforeCount = profileStore.profiles.count
        await profileStore.addFromURL(name: "", urlString: urlString)
        if profileStore.profiles.count > beforeCount,
           profileStore.lastError == nil,
           let created = profileStore.profiles.last {
            return .success(created)
        }
        return .failure(profileStore.lastError ?? "导入失败（原因未知）")
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

    // MARK: - Mixed lines (batch)

    @MainActor
    private func importLines(_ text: String) async {
        let lines = Self.nonEmptyLines(text)
        var nodeLines: [(index: Int, line: String)] = []
        for (index, line) in lines.enumerated() {
            switch Self.kind(of: line) {
            case .subscription:
                switch await importSubscriptionURL(line) {
                case .success(let profile):
                    results.append(ImportLineResult(order: index, line: line, kind: .subscription, succeeded: true, message: "已导入订阅「\(profile.name)」"))
                    successProfiles.append((order: index, profile: profile))
                case .failure(let reason):
                    results.append(ImportLineResult(order: index, line: line, kind: .subscription, succeeded: false, message: "导入失败：\(reason)"))
                }
            case .nodeLink:
                nodeLines.append((index: index, line: line))
            case .unknown:
                results.append(ImportLineResult(order: index, line: line, kind: .unknown, succeeded: false, message: "无法识别这一行：不是订阅链接、节点链接或 YAML（整段 YAML 请单独粘贴导入）"))
            }
        }
        if !nodeLines.isEmpty {
            await importNodeLines(nodeLines, totalLines: lines.count)
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
            case .failure(let reason):
                failed.append((index: index, line: line, reason: reason))
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
            results.append(ImportLineResult(order: index, line: line, kind: .nodes, succeeded: true, message: "已解析节点「\(node.name)」"))
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
        if let existing = profileStore.profiles.first(where: { $0.name == DefaultConfig.profileName }) {
            profileStore.delete(existing)
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
