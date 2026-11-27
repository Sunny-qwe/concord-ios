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
    /// Per-provider detail cache for the detail sheet's rows
    /// (provider.get carries subscriptionInfo; provider.list
    /// omits it). Keyed by provider name; a missing entry means
    /// "not fetched" — the traffic meter and expiry chip simply
    /// stay hidden, never a fabricated zero.
    @Published var providerDetails: [String: ConcordProviderInfo] = [:]
    /// Names of providers currently updating, for the per-row
    /// spinner (upstream ProviderItem watches isUpdatingProvider).
    @Published var updatingProviderNames: Set<String> = []
    /// Local file kind per provider, probed from the provider file
    /// (upstream _probeProviderFile): text / .mrs rule set (zstd
    /// magic) / binary (NUL byte). Drives tap-to-preview, edit and
    /// the preview path in the detail sheet.
    @Published var providerFileKinds: [String: ProviderFileKind] = [:]

    /// Names of rule providers backed by a remote subscription
    /// (upstream remoteProviderOf's ClashProvider rows). Cached
    /// as a name set: the detail sheet calls
    /// isAppRuleSetProvider from every row body, so it must be a
    /// cheap lookup, never a store load per row. Refreshed on
    /// refresh() and on init.
    @Published var appRuleSetNames: Set<String> = []

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        // Direct assignment: init is not actor-isolated, so it
        // cannot call the @MainActor refresh below.
        self.appRuleSetNames = Self.remoteRuleProviderNames()
    }

    /// The remote-backed rule-provider names, read straight from
    /// the custom subscriptions. Static + non-isolated so init
    /// can use it; the file read is one small JSON decode.
    private static func remoteRuleProviderNames() -> Set<String> {
        let store = CustomSubscriptionStore()
        return Set(store.subscriptions.flatMap { $0.ruleProviders }
            .filter { $0.kind == "http" && !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.name })
    }

    /// Re-reads the remote-backed rule-provider names from the
    /// custom subscriptions (their ruleProviders with kind http
    /// and a URL — the ClashProvider equivalent).
    @MainActor
    func refreshAppRuleSetNames() {
        appRuleSetNames = Self.remoteRuleProviderNames()
    }

    /// Upstream _ProviderFile (providers.dart), same probe rules.
    enum ProviderFileKind {
        case text
        case ruleSet
        case binary
    }

    /// Probes one provider's local file and caches the kind.
    /// A missing file reads as text (upstream: not exists → text),
    /// so a not-yet-downloaded provider still offers preview/edit.
    /// Sync + tiny (first 512 bytes); the sheet calls it from a
    /// row .task so the list's first frame is never held up.
    @MainActor
    func probeProviderFile(_ provider: ConcordProviderInfo) -> ProviderFileKind {
        if let cached = providerFileKinds[provider.name] { return cached }
        let kind: ProviderFileKind
        if let path = ConfigStore.absolutePath(relative: provider.path),
           FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 512)) ?? Data()
            let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
            if head.count >= 4, Array(head.prefix(4)) == zstdMagic {
                kind = .ruleSet
            } else if head.contains(0) {
                kind = .binary
            } else {
                kind = .text
            }
        } else {
            kind = .text
        }
        providerFileKinds[provider.name] = kind
        return kind
    }

    /// Fetches one provider's detail (provider.get) when it is not
    /// cached yet, for the traffic meter / expiry chip. Only while
    /// a core is reachable: provider.get has no AppCore
    /// counterpart, so with the VPN off there is nothing to fetch
    /// and the meter stays hidden. Failures are silent on purpose
    /// — a missing detail must never paint a red error on the
    /// detail sheet.
    @MainActor
    func loadProviderDetailIfNeeded(_ provider: ConcordProviderInfo) async {
        if providerDetails[provider.name] != nil { return }
        guard client.mode == .sample || TunnelManager.shared.isRunning else { return }
        do {
            providerDetails[provider.name] = try await client.providerGet(name: provider.name)
        } catch {
            // Silent: the row falls back to the count line.
        }
    }

    /// Re-reads one provider after an update (upstream
    /// updateProvider → getExternalProvider) instead of
    /// re-listing everything. VPN-off reads the in-app core's
    /// list; any failure falls back to a full refresh.
    @MainActor
    func refreshSingleProvider(_ provider: ConcordProviderInfo) async {
        do {
            let detail: ConcordProviderInfo
            if client.mode == .live, !TunnelManager.shared.isRunning {
                try await AppCore.shared.ensureStarted()
                let list = try await AppCore.shared.providerList()
                guard let found = list.providers.first(where: { $0.name == provider.name }) else {
                    await refresh()
                    return
                }
                detail = found
            } else {
                detail = try await client.providerGet(name: provider.name)
            }
            if let index = providers.firstIndex(where: { $0.name == provider.name }) {
                providers[index] = detail
            } else {
                await refresh()
                return
            }
            providerDetails[provider.name] = detail
        } catch {
            await refresh()
        }
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
        refreshAppRuleSetNames()
        do {
            rules = try await client.ruleList().rules
            providers = try await client.providerList().providers
            seedProviderDetails()
            lastUpdated = Date()
            lastError = nil
        } catch {
            // VPN-off fallback (same pattern as ProxyStore's
            // loadedInventory): the extension core is gone, but
            // the in-app core can still list providers after a
            // boot-on-demand. AppCore has no rule.list, so the
            // rules keep their last value instead of clearing —
            // the detail sheet's rule count comes from the local
            // config parse, not from here.
            if client.mode == .live, !TunnelManager.shared.isRunning {
                do {
                    try await AppCore.shared.ensureStarted()
                    providers = try await AppCore.shared.providerList().providers
                    seedProviderDetails()
                    lastUpdated = Date()
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                }
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// Seeds the detail cache from any list entry that already
    /// carries subscriptionInfo (defensive: provider.list is
    /// documented to omit it, but a core that reports it saves a
    /// provider.get round-trip per row).
    private func seedProviderDetails() {
        for provider in providers where provider.subscriptionInfo != nil {
            providerDetails[provider.name] = provider
        }
    }

    /// Whether this provider is an app rule set (upstream
    /// proxies.dart _isAppRuleSet via clashProvidersAction
    /// .remoteProviderOf): a Rule-type, File-vehicle provider
    /// backed by a remote subscription. Our ClashProvider
    /// equivalent is a CustomProvider in a custom subscription
    /// (kind http, with a URL), matched by provider name — the
    /// bake linkage is name-based, so the match is too. Plain
    /// (not @MainActor): the sheet reads it synchronously from
    /// row bodies, and it only reads the cached name set (all
    /// writes go through the @MainActor refresh).
    func isAppRuleSetProvider(_ provider: ConcordProviderInfo) -> Bool {
        provider.type == "rule" && provider.vehicleType == "File" && appRuleSetNames.contains(provider.name)
    }

    private func remoteRuleProviderSource(for provider: ConcordProviderInfo) -> CustomProvider? {
        guard provider.type == "rule", provider.vehicleType == "File",
              appRuleSetNames.contains(provider.name) else { return nil }
        let store = CustomSubscriptionStore()
        return store.subscriptions.flatMap { $0.ruleProviders }
            .first { $0.name == provider.name && $0.kind == "http" && !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Upstream proxies.dart updateProvider + clashProvidersAction
    /// .syncRemote: re-downloads the remote rule set, then loads
    /// it into the core (provider.sideLoad — the core's
    /// compileRules path has no iOS RPC, so side-load is the
    /// available equivalent). The caller then refreshes the single
    /// provider and the groups; no core provider.update follows
    /// a successful sync (upstream returns early in that case).
    /// Throws before downloading when the VPN is off: side-load
    /// runs through the extension core, and AppCore exposes no
    /// sideLoad — downloading without a place to load it would
    /// only waste the fetch.
    @MainActor
    private func syncRemoteRuleProvider(_ provider: ConcordProviderInfo) async throws {
        guard let source = remoteRuleProviderSource(for: provider),
              let url = URL(string: source.url) else {
            throw NSError(domain: "ConcordRuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "该规则提供方没有可同步的远程订阅"])
        }
        guard client.mode == .sample || TunnelManager.shared.isRunning else {
            throw NSError(domain: "ConcordRuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新远程规则集「\(provider.name)」需先启动 VPN：内容要载入扩展内的核心，应用内核心没有载入接口"])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ConcordRuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "远程规则集下载失败：服务器返回异常状态"])
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NSError(domain: "ConcordRuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "远程规则集内容为空或不是文本"])
        }
        try await client.providerSideLoad(name: provider.name, data: text)
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

    /// Updates one provider from its source, then refreshes just
    /// that provider so the new count / time shows (upstream
    /// proxies.dart updateProvider: remote sync first for an app
    /// rule set, then core updateProvider, then a single-provider
    /// refresh). VPN-off runs through the in-app core
    /// (AppCore.providerUpdate), like the delay-test preload;
    /// HTTP providers pull over the network, File providers are
    /// re-read by the core. The row spinner is driven by
    /// updatingProviderNames; the caller refreshes the proxy
    /// groups afterwards (upstream updateGroupsDebounce).
    @MainActor
    func updateProvider(_ provider: ConcordProviderInfo) async {
        do {
            try await updateProviderThrowing(provider)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Throwing core of updateProvider, for the parallel
    /// update-all: the caller collects one error per provider
    /// instead of sharing lastError across concurrent children
    /// (the old sequential loop overwrote it, so only the last
    /// failure survived).
    @MainActor
    func updateProviderThrowing(_ provider: ConcordProviderInfo) async throws {
        guard !updatingProviderNames.contains(provider.name) else { return }
        updatingProviderNames.insert(provider.name)
        defer { updatingProviderNames.remove(provider.name) }
        if isAppRuleSetProvider(provider) {
            try await syncRemoteRuleProvider(provider)
            providerActionMessage = "已同步远程规则集 \(provider.name)"
            lastError = nil
            await refreshSingleProvider(provider)
            return
        }
        // HTTP providers pull from their URL; File providers
        // re-read their file in the core. The upstream menu only
        // OFFERS sync for HTTP / app-rule-set providers — that
        // gating lives in the sheet's menu, not here, so
        // RulesView's swipe-update on a file provider keeps
        // working exactly as before.
        if client.mode == .live, !TunnelManager.shared.isRunning {
            try await AppCore.shared.ensureStarted()
            try await AppCore.shared.providerUpdate(name: provider.name)
        } else {
            try await client.providerUpdate(name: provider.name)
        }
        providerActionMessage = "已更新提供方 \(provider.name)"
        lastError = nil
        await refreshSingleProvider(provider)
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
}
