import Foundation
import Combine

// MARK: - Rule store (FlClash: rules list + rule providers)
// Backed by Concord rule.list, ruleSet.dump/compile, provider.list
// (rule providers) and validate.filters. Rules are read-only here —
// FlClash edits rules through the config editor, which on iOS is the
// profile YAML file itself (see ProfilesView).

final class RuleStore: ObservableObject {
    @Published var rules: [ConcordRuleEntry] = []
    @Published var providers: [ConcordProviderInfo] = []
    @Published var searchText = ""
    @Published var typeFilter = "全部"
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    /// Result message of a provider action (update / dump / compile /
    /// geo update), shown on the Providers page.
    @Published var providerActionMessage: String?
    /// Dumped rules of one rule-set provider (ruleSet.dump).
    @Published var dumpedRuleSetText: String?
    @Published var dumpedRuleSetName: String?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var ruleTypes: [String] {
        var types = ["全部"]
        types.append(contentsOf: Set(rules.map { $0.type }).sorted())
        return types
    }

    var filtered: [ConcordRuleEntry] {
        rules.filter { rule in
            let typeOK = typeFilter == "全部" || rule.type == typeFilter
            let textOK = searchText.isEmpty
                || rule.payload.localizedCaseInsensitiveContains(searchText)
                || rule.target.localizedCaseInsensitiveContains(searchText)
            return typeOK && textOK
        }
    }

    var ruleProviders: [ConcordProviderInfo] {
        providers.filter { $0.type == "rule" }
    }

    @MainActor
    func refresh() async {
        do {
            rules = try await client.ruleList().rules
            providers = try await client.providerList().providers
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Dumps one rule provider's rules as text (ruleSet.dump). The
    /// provider path is relative to the core's home directory, so it
    /// is resolved to an absolute path first (see ConfigStore).
    @MainActor
    func dumpRuleSet(_ provider: ConcordProviderInfo) async {
        guard let absolutePath = ConfigStore.absolutePath(relative: provider.path) else {
            lastError = "App Group 容器不可用"
            return
        }
        do {
            dumpedRuleSetText = try await client.ruleSetDump(path: absolutePath)
            dumpedRuleSetName = provider.name
            providerActionMessage = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Recompiles a stored rule-set (ruleSet.compile).
    @MainActor
    func compileRuleSet(_ provider: ConcordProviderInfo) async {
        do {
            let info = try await client.ruleSetCompile(name: provider.name)
            providerActionMessage = "已重新编译 \(provider.name)：\(info.behavior) / \(info.format)"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Updates one geo database (geo.update). `kind` is "MMDB"
    /// (GeoIP), "ASN" or "GEOSITE".
    @MainActor
    func geoUpdate(kind: String) async {
        do {
            try await client.geoUpdate(kind: kind)
            providerActionMessage = "地理数据库 \(kind) 更新已开始（后台进行）"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
