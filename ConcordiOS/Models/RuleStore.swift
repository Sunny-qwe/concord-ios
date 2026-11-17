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
    /// Route re-check (route.check): the last answer, the service name
    /// of each route (aligned with `held`), and a summary line.
    @Published var routeCheckResult: ConcordRouteCheckResult?
    @Published var routeCheckLabels: [String] = []
    @Published var routeCheckMessage: String?

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

    /// Re-validates probed routes (route.check). Each route is one
    /// probe answer's hits — `labels[i]` names the route (a service
    /// name) and `held[i]` says whether it still leaves where it did,
    /// against the returned epoch/version stamp. A route.check is not
    /// a URL tester: the hits must come from an earlier probe, so the
    /// caller passes the services probe.services just returned.
    @MainActor
    func routeCheck(routes: [[ConcordRouteHit]], labels: [String]) async {
        guard !routes.isEmpty else {
            routeCheckMessage = "暂无可复核的路由：先在仪表盘运行服务检测（probe.services），探测会记录路由命中"
            return
        }
        do {
            routeCheckResult = try await client.routeCheck(routes: routes)
            routeCheckLabels = labels
            if let result = routeCheckResult {
                let held = result.held.filter { $0 }.count
                routeCheckMessage = "已复核 \(result.held.count) 条路由：\(held) 条仍有效，\(result.held.count - held) 条已变化（epoch \(result.epoch) / version \(result.version)）"
            }
            lastError = nil
        } catch {
            routeCheckMessage = nil
            lastError = error.localizedDescription
        }
    }
}
