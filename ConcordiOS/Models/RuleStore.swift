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
}
