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
    /// Filter validation (validate.filters): the issues of the last
    /// check, plus a one-line summary for the Rules page.
    @Published var filterIssues: [ConcordIssue] = []
    @Published var filterCheckMessage: String?
    /// One provider's full detail (provider.get), incl.
    /// `subscriptionInfo` when it is a subscription.
    @Published var providerDetail: ConcordProviderInfo?

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

    /// Updates one rule provider from its source
    /// (provider.update), then refreshes the list so the new
    /// count / time shows.
    @MainActor
    func updateProvider(_ provider: ConcordProviderInfo) async {
        do {
            try await client.providerUpdate(name: provider.name)
            providerActionMessage = "已更新提供方 \(provider.name)"
            lastError = nil
            await refresh()
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

    /// Validates filter expressions (validate.filters). A filter is
    /// one backtick-separated regex list, the `filter:` value proxy
    /// groups use (e.g. `(?i)港|hk`, `hk`jp`). Empty strings are
    /// valid. Issues carry the index of the offending expression.
    @MainActor
    func validateFilters(_ filters: [String]) async {
        do {
            filterIssues = try await client.validateFilters(filters: filters)
            filterCheckMessage = filterIssues.isEmpty
                ? "全部 \(filters.count) 条过滤表达式有效"
                : "发现 \(filterIssues.count) 个问题"
            lastError = nil
        } catch {
            filterCheckMessage = nil
            lastError = error.localizedDescription
        }
    }

    /// Fetches one provider's full detail (provider.get). Unlike
    /// provider.list, the result carries `subscriptionInfo` when the
    /// provider is a subscription.
    @MainActor
    func loadProviderDetail(_ provider: ConcordProviderInfo) async {
        do {
            providerDetail = try await client.providerGet(name: provider.name)
            providerActionMessage = nil
            lastError = nil
        } catch {
            providerDetail = nil
            lastError = error.localizedDescription
        }
    }

    /// Loads a provider from inline content (provider.sideLoad).
    /// `data` is the provider file's text (YAML / MRS / text),
    /// stored by the core under `name`. Local content only — the
    /// method itself does no network fetch.
    @MainActor
    func sideLoadProvider(name: String, data: String) async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            providerActionMessage = "请先输入提供方名称"
            return
        }
        guard !data.isEmpty else {
            providerActionMessage = "请先粘贴提供方内容"
            return
        }
        do {
            try await client.providerSideLoad(name: name, data: data)
            providerActionMessage = "已载入提供方 \(name)（本地内容）"
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Triggers a provider's health check (provider.healthCheck).
    /// The check runs in the background; the call only reports
    /// whether it could be started.
    @MainActor
    func healthCheckProvider(_ provider: ConcordProviderInfo) async {
        do {
            try await client.providerHealthCheck(name: provider.name)
            providerActionMessage = "健康检查已触发，但核心不返回提供方健康状态，无法显示结果"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
