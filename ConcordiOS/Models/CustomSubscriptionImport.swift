import Foundation

// MARK: - 自定义订阅 YAML 导入（v0.2.55）
//
// 把一份 Clash 风格 YAML 解析（YamlParser）后映射到 CustomSubscription
// （CustomSubscriptionStore.swift 的模型），复用 store 已有的
// update(_:) 保存——本文件不复制存储逻辑。
//
// 映射规则（与 ~/workspace/scratch/yaml-0.2.55/test_import.py 逐项对应，
// 该测试已对两份夹具跑过）：
//   * proxy-groups / proxy-providers / rule-providers / rules 映射到模型；
//   * proxies（节点定义）现在完整导入（v0.2.147，上游
//     readCustomProfileImport 的 _importProxies）：整条定义存入
//     CustomProxyStore.rawProxies（结果的 proxies），重名按
//     已有节点 / 分组去重改名，相同定义复用已有节点；每条的
//     `dialer-proxy:` 抽成拨号器（CustomDialer），定义本身去掉
//     该键；分组的 proxies 成员、规则的目标、拨号器的两端都
//     跟随改名；导入统计记入 notes；
//   * dns / ntp / sniffer / tun 四个顶层区映射到自定义订阅已有的
//     per-profile 区（CustomDnsSection 等，上游 _importOverrides）；
//     区内无法表示的键记入 notes；
//   * 分组/提供方对象里的未知字段是硬错误（列出字段名）；
//   * rule-providers 的 behavior / format / payload 现在存入模型
//     （v0.2.148：CustomProvider.behavior / .format / .payload；
//     behavior 接受 domain / ipcidr / classical，format 接受
//     yaml / text / mrs，type: inline 时 payload 存规则行）。
//     此前只有 classical 可接受，domain/ipcidr 是硬错误——那时
//     模型存不下 behavior；现在存下了，硬错误取消。注意：bake
//     时 rule provider 一律带 behavior（核心 parse_rule_provider
//     要求 type+behavior，缺了会被核心拒绝）。
//   * mixed-port、mode 等其余顶层配置键与自定义订阅无关，不进模型，
//     但会列入结果的 ignoredTopLevelKeys，由导入界面向用户展示——
//     不是静默丢弃；
//   * 规则按逗号切分（引号内的逗号保留），未知类型、缺少目标、无法识别
//     的标志一律报错。

struct CustomSubscriptionImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CustomSubscriptionImportResult {
    let subscription: CustomSubscription
    /// 顶层配置键（mixed-port、dns……）：与自定义订阅无关，未导入。
    let ignoredTopLevelKeys: [String]
    /// 已接受但未存入模型的说明（如代理提供方的 behavior=classical
    /// 按核心默认值处理）。
    let notes: [String]
    /// Imported node definitions (upstream CustomProfileImport
    /// proxies): the full `proxies:` entries, renamed where they
    /// collided and stripped of `dialer-proxy:` (dialers live
    /// per-profile in CustomDialer). The caller stores them in
    /// CustomProxyStore.rawProxies — the v0.2.146 drop-with-note
    /// ends here: nodes now survive the import.
    let proxies: [JSONValue]
    /// Proxy providers with a URL whose real URL Profile still
    /// needs creating (v0.2.148): the importer has no age-key
    /// context and no ProfileStore access, so the view layer
    /// find-or-creates the Profile from these and fills
    /// providerProfileMap. The CustomProvider entry stays in the
    /// subscription (all options survive); bake falls back to
    /// http until the map entry lands.
    let pendingProviderProfiles: [PendingProviderProfile]
    /// Rule providers with a URL whose ClashProvider record still
    /// needs creating + downloading (v0.2.148): same hand-off as
    /// pendingProviderProfiles, for ruleProviderMap.
    let pendingRuleProviders: [PendingRuleProvider]
}

/// One proxy provider awaiting its real URL Profile (v0.2.148).
struct PendingProviderProfile {
    var providerName: String
    var label: String
    var url: String
    /// The provider's own age key (its `age-secret-key` field,
    /// when present) — nil when the provider has none.
    var ageSecretKey: String?
}

/// One rule provider awaiting its ClashProvider record (v0.2.148).
struct PendingRuleProvider {
    var providerName: String
    var label: String
    var url: String
    var behavior: String?
    var format: String?
}

enum CustomSubscriptionImporter {

    private static let maxDownloadBytes = 2 * 1024 * 1024

    /// 从 URL 下载 YAML 并导入。HTTP 非 2xx、非 UTF-8、超过 2MB 均报错。
    static func fetchAndImport(name: String, from url: URL) async throws -> CustomSubscriptionImportResult {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("ConcordiOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CustomSubscriptionImportError(message: "下载失败：HTTP \(http.statusCode)")
        }
        guard data.count <= maxDownloadBytes else {
            throw CustomSubscriptionImportError(message: "文件过大（超过 2MB），无法导入")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CustomSubscriptionImportError(message: "文件不是 UTF-8 编码，无法导入")
        }
        return try importSubscription(name: name, yamlText: text)
    }

    /// 从 YAML 文本导入。解析失败时抛 YamlParserError（带行号的中文说明）。
    static func importSubscription(name: String, yamlText: String) throws -> CustomSubscriptionImportResult {
        let doc = try YamlParser.parse(yamlText)
        guard case .object(let top) = doc else {
            throw CustomSubscriptionImportError(message: "文件顶层必须是映射（key: value 形式）")
        }
        var dialers: [CustomDialer] = []
        var notes: [String] = []
        // Names the core registers before any proxy is parsed
        // (FlClash reservedCustomProxyNames, providers/state/
        // custom.dart:110-121): neither a proxy nor a group can
        // take one — a file node named DIRECT would shadow the
        // DIRECT action.
        let reservedNames: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL"]
        // This file's group names (pre-pass): nodes must not
        // shadow them, and the reference resolver below needs
        // them to tell a group reference from a node reference.
        var fileGroupNames: Set<String> = []
        if case .array(let groupItems) = top["proxy-groups"] {
            for item in groupItems {
                if case .object(let dict) = item, case .string(let name) = dict["name"], !name.isEmpty {
                    fileGroupNames.insert(name)
                }
            }
        }
        let proxyStore = CustomProxyStore()
        // Proxy renames (upstream _importProxies): original name ->
        // final name, for every `proxies:` entry. Applied below to
        // group members, rule targets and dialer names, so a renamed
        // node stays referenced. Built here, before groups are
        // mapped (they run after this block).
        var proxyRenames: [String: String] = [:]
        var importedProxies: [JSONValue] = []
        if let proxies = top["proxies"] {
            guard case .array(let items) = proxies else {
                throw CustomSubscriptionImportError(message: "proxies 必须是列表")
            }
            // Names already taken: the app's stored custom proxies
            // (form + raw), the reserved names, this file's group
            // names, and the groups of OTHER stored subscriptions
            // (upstream groupNames, profiles.dart:238-262) — a node
            // must not shadow any of them (upstream: proxies and
            // groups share one namespace in mihomo).
            var taken: Set<String> = reservedNames
            taken.formUnion(proxyStore.proxies.map { $0.name })
            for raw in proxyStore.rawProxies {
                if case .object(let dict) = raw, case .string(let name) = dict["name"] {
                    taken.insert(name)
                }
            }
            taken.formUnion(CustomSubscriptionStore().subscriptions.flatMap { $0.groups.map { $0.name } })
            taken.formUnion(fileGroupNames)
            // Definitions already held (raw store, exact match):
            // re-importing the same file reuses the stored node
            // instead of storing a duplicate. Compared WITHOUT
            // the name (upstream _comparable) and with numbers
            // canonicalised (an int port and a double port are
            // the same value — JSONValue keeps them apart): a
            // node renamed on the first import ("name 2") must
            // still match on re-import, or it would be stored
            // again as "name 3". The match yields the STORED
            // name, so references follow the rename.
            var heldComparables: [(name: String, comparable: JSONValue)] = proxyStore.rawProxies.compactMap { held in
                guard case .object(var dict) = held,
                      case .string(let name) = dict["name"] else { return nil }
                dict.removeValue(forKey: "name")
                return (name, Self.canonicalNumber(.object(dict)))
            }
            var importedCount = 0
            var reusedCount = 0
            var renamedCount = 0
            var skippedCount = 0
            for item in items {
                guard case .object(var dict) = item,
                      case .string(let proxyName) = dict["name"],
                      !proxyName.trimmingCharacters(in: .whitespaces).isEmpty else {
                    skippedCount += 1
                    continue
                }
                // The dialer lives per-profile (CustomDialer), not
                // on the stored node (upstream _withoutDialer).
                let dialerName: String?
                if case .string(let dialer) = dict["dialer-proxy"], !dialer.isEmpty {
                    dialerName = dialer
                } else {
                    dialerName = nil
                }
                dict.removeValue(forKey: "dialer-proxy")
                var comparableDict = dict
                comparableDict.removeValue(forKey: "name")
                let comparable = Self.canonicalNumber(.object(comparableDict))
                // The final name for THIS occurrence. proxyRenames
                // keeps the FIRST occurrence's mapping (upstream
                // names.putIfAbsent): a later same-name node with
                // a different definition gets its own final name
                // and its own dialer, but group/rule references
                // can only name one node, so they keep pointing
                // at the first — overwriting the map would orphan
                // the first stored node.
                let finalNameForItem: String
                // Identical definition already stored (raw store,
                // or a form proxy with the same name/type/server/
                // port plus account keys — upstream _identityOf
                // includes uuid/password/…; name/type/server/port
                // alone would silently map a node onto a form
                // proxy with different credentials and drop its
                // definition): reuse the existing name, store
                // nothing.
                if let held = heldComparables.first(where: { $0.comparable == comparable }) {
                    finalNameForItem = held.name
                    if proxyRenames[proxyName] == nil { proxyRenames[proxyName] = held.name }
                    reusedCount += 1
                } else if proxyStore.proxies.contains(where: {
                    $0.name == proxyName
                    && $0.type == Self.proxyStringField(dict, "type")
                    && $0.server == Self.proxyStringField(dict, "server")
                    && $0.port == Self.proxyIntField(dict, "port")
                    && $0.password == Self.proxyStringField(dict, "password")
                    && $0.uuid == Self.proxyStringField(dict, "uuid")
                    && $0.cipher == Self.proxyStringField(dict, "cipher")
                }) {
                    finalNameForItem = proxyName
                    if proxyRenames[proxyName] == nil { proxyRenames[proxyName] = proxyName }
                    reusedCount += 1
                } else if taken.contains(proxyName) {
                    // Same name, different node: rename ("name 2",
                    // "name 3", …) and keep going.
                    var n = 2
                    var finalName = "\(proxyName) \(n)"
                    while taken.contains(finalName) {
                        n += 1
                        finalName = "\(proxyName) \(n)"
                    }
                    taken.insert(finalName)
                    dict["name"] = .string(finalName)
                    if proxyRenames[proxyName] == nil { proxyRenames[proxyName] = finalName }
                    finalNameForItem = finalName
                    importedProxies.append(.object(dict))
                    heldComparables.append((finalName, comparable))
                    importedCount += 1
                    renamedCount += 1
                } else {
                    taken.insert(proxyName)
                    if proxyRenames[proxyName] == nil { proxyRenames[proxyName] = proxyName }
                    finalNameForItem = proxyName
                    importedProxies.append(.object(dict))
                    heldComparables.append((proxyName, comparable))
                    importedCount += 1
                }
                // Dialer for this occurrence (upstream
                // _importProxies' dialers map, per-index
                // proxyNames): the proxy side is this occurrence's
                // own final name; the dialer side is stored raw
                // and mapped in the post-pass below — a dialer may
                // name a node defined LATER in the file, whose
                // rename does not exist yet here.
                if let dialerName {
                    if !dialers.contains(where: { $0.proxy == finalNameForItem }) {
                        dialers.append(CustomDialer(proxy: finalNameForItem, dialer: dialerName))
                    }
                }
            }
            // Post-pass: every dialer's target through the finished
            // rename map (forward references included). Runs once,
            // so a target already renamed is not re-mapped.
            for i in dialers.indices {
                dialers[i].dialer = proxyRenames[dialers[i].dialer] ?? dialers[i].dialer
            }
            if importedCount > 0 || reusedCount > 0 || skippedCount > 0 {
                var note = "已导入 \(importedCount) 个节点到本地节点"
                if reusedCount > 0 { note += "，\(reusedCount) 个与已有节点相同，未重复导入" }
                if renamedCount > 0 { note += "，\(renamedCount) 个重命名" }
                if skippedCount > 0 { note += "，\(skippedCount) 个无名称，跳过" }
                if !dialers.isEmpty { note += "；其中 \(dialers.count) 个拨号器已导入" }
                notes.append(note)
            }
        }
        let knownKeys: Set<String> = ["proxy-groups", "proxy-providers", "rule-providers", "rules",
                                      "proxies", "dns", "ntp", "sniffer", "tun"]
        let ignored = top.keys.filter { !knownKeys.contains($0) }.sorted()

        // Group renames (upstream freeName for groups): a group
        // whose name collides with a stored proxy, an imported
        // node's final name, or a reserved name is renamed ("name
        // 2", …) — otherwise a member naming it could not tell
        // the group from the node. Finals avoid every taken name,
        // so they never equal another group's original name.
        var proxyNameSpace: Set<String> = reservedNames
        proxyNameSpace.formUnion(proxyStore.proxies.map { $0.name })
        for raw in proxyStore.rawProxies {
            if case .object(let dict) = raw, case .string(let name) = dict["name"] {
                proxyNameSpace.insert(name)
            }
        }
        proxyNameSpace.formUnion(importedProxies.compactMap { def -> String? in
            guard case .object(let dict) = def, case .string(let name) = dict["name"] else { return nil }
            return name
        })
        var groupRenames: [String: String] = [:]
        if !fileGroupNames.isEmpty {
            var groupTaken = proxyNameSpace
            groupTaken.formUnion(fileGroupNames)
            groupTaken.formUnion(CustomSubscriptionStore().subscriptions.flatMap { $0.groups.map { $0.name } })
            for name in fileGroupNames.sorted() where proxyNameSpace.contains(name) {
                var n = 2
                var finalName = "\(name) \(n)"
                while groupTaken.contains(finalName) {
                    n += 1
                    finalName = "\(name) \(n)"
                }
                groupTaken.insert(finalName)
                groupRenames[name] = finalName
            }
        }
        // Reference resolver: what a group member / rule target /
        // default-selected string names. Reserved action names are
        // never references; a name that is a group in this file
        // refers to the group (renamed if it was); anything else
        // that was renamed is a node. Without the group check, a
        // member naming a group that shares a node's name would be
        // rewritten to the node's rename.
        let resolveReference: (String) -> String = { name in
            if reservedNames.contains(name) { return name }
            if fileGroupNames.contains(name) { return groupRenames[name] ?? name }
            return proxyRenames[name] ?? name
        }
        var groups: [CustomGroup] = []
        if let rawGroups = top["proxy-groups"] {
            guard case .array(let items) = rawGroups else {
                throw CustomSubscriptionImportError(message: "proxy-groups 必须是列表")
            }
            for (idx, item) in items.enumerated() {
                let (group, groupNotes) = try mapGroup(item, index: idx, resolve: resolveReference)
                groups.append(group)
                notes.append(contentsOf: groupNotes)
            }
        }
        var proxyProviders: [CustomProvider] = []
        var pendingProviderProfiles: [PendingProviderProfile] = []
        if let rawProviders = top["proxy-providers"] {
            guard case .object(let dict) = rawProviders else {
                throw CustomSubscriptionImportError(message: "proxy-providers 必须是映射")
            }
            for name in dict.keys.sorted() {
                let (provider, providerNotes, ageSecretKey) = try mapProvider(name: name, value: dict[name]!, isRuleProvider: false)
                proxyProviders.append(provider)
                notes.append(contentsOf: providerNotes)
                // A proxy provider with a URL becomes a real URL
                // Profile at import (upstream _importProviders
                // bySource); the view layer creates it and fills
                // providerProfileMap. Only http providers carry a
                // URL (upstream: url = type == 'http' ? … : '') —
                // a file provider with a stray url keeps its file
                // path and gets no map entry. URL-less providers
                // (file) keep the CustomProvider path.
                let trimmedURL = provider.url.trimmingCharacters(in: .whitespaces)
                if provider.kind == "http", !trimmedURL.isEmpty {
                    pendingProviderProfiles.append(PendingProviderProfile(
                        providerName: provider.name, label: provider.name,
                        url: trimmedURL, ageSecretKey: ageSecretKey))
                }
            }
        }
        var ruleProviders: [CustomProvider] = []
        var pendingRuleProviders: [PendingRuleProvider] = []
        if let rawProviders = top["rule-providers"] {
            guard case .object(let dict) = rawProviders else {
                throw CustomSubscriptionImportError(message: "rule-providers 必须是映射")
            }
            for name in dict.keys.sorted() {
                let (provider, providerNotes, _) = try mapProvider(name: name, value: dict[name]!, isRuleProvider: true)
                ruleProviders.append(provider)
                notes.append(contentsOf: providerNotes)
                // Only http rule providers carry a URL (an inline
                // provider with a stray url gets no record — bake
                // never consults the map for inline entries).
                let trimmedURL = provider.url.trimmingCharacters(in: .whitespaces)
                if provider.kind == "http", !trimmedURL.isEmpty {
                    pendingRuleProviders.append(PendingRuleProvider(
                        providerName: provider.name, label: provider.name,
                        url: trimmedURL, behavior: provider.behavior,
                        format: provider.format))
                }
            }
        }
        var rules: [CustomRule] = []
        if let rawRules = top["rules"] {
            guard case .array(let items) = rawRules else {
                throw CustomSubscriptionImportError(message: "rules 必须是列表")
            }
            for (idx, item) in items.enumerated() {
                guard case .string(let text) = item else {
                    throw CustomSubscriptionImportError(message: "规则 #\(idx + 1) 必须是字符串")
                }
                var rule = try mapRule(text, index: idx)
                // A rule target naming an imported node or a group
                // follows its rename (the resolver tells the two
                // apart; reserved actions pass through untouched).
                rule.target = resolveReference(rule.target)
                rules.append(rule)
            }
        }
        // Per-profile scoped sections (upstream _importOverrides):
        // only the keys the model can hold are mapped; anything
        // else in the section is listed in notes, never silently
        // kept or dropped without a trace.
        var dns: CustomDnsSection?
        var ntp: CustomNtpSection?
        var sniffer: CustomSnifferSection?
        var tun: CustomTunSection?
        if let rawDns = top["dns"] {
            guard case .object(let dict) = rawDns else {
                throw CustomSubscriptionImportError(message: "dns 必须是映射")
            }
            let (section, unknown) = mapDnsSection(dict)
            dns = section
            if !unknown.isEmpty {
                notes.append("dns 区有 \(unknown.count) 个无法表示的键未导入：\(unknown.joined(separator: "、"))")
            }
        }
        if let rawNtp = top["ntp"] {
            guard case .object(let dict) = rawNtp else {
                throw CustomSubscriptionImportError(message: "ntp 必须是映射")
            }
            let (section, unknown) = mapNtpSection(dict)
            ntp = section
            if !unknown.isEmpty {
                notes.append("ntp 区有 \(unknown.count) 个无法表示的键未导入：\(unknown.joined(separator: "、"))")
            }
        }
        if let rawSniffer = top["sniffer"] {
            guard case .object(let dict) = rawSniffer else {
                throw CustomSubscriptionImportError(message: "sniffer 必须是映射")
            }
            let (section, unknown) = mapSnifferSection(dict)
            sniffer = section
            if !unknown.isEmpty {
                notes.append("sniffer 区有 \(unknown.count) 个无法表示的键未导入：\(unknown.joined(separator: "、"))")
            }
        }
        if let rawTun = top["tun"] {
            guard case .object(let dict) = rawTun else {
                throw CustomSubscriptionImportError(message: "tun 必须是映射")
            }
            let (section, unknown) = mapTunSection(dict)
            tun = section
            if !unknown.isEmpty {
                notes.append("tun 区有 \(unknown.count) 个无法表示的键未导入：\(unknown.joined(separator: "、"))")
            }
        }
        if groups.isEmpty && proxyProviders.isEmpty && ruleProviders.isEmpty && rules.isEmpty
            && dialers.isEmpty && dns == nil && ntp == nil && sniffer == nil && tun == nil {
            throw CustomSubscriptionImportError(message: "文件中没有找到分组、提供方、规则、拨号器或配置区，无法导入为空订阅")
        }
        let subscription = CustomSubscription(
            name: name, groups: groups, dialers: dialers,
            proxyProviders: proxyProviders, ruleProviders: ruleProviders, rules: rules,
            dns: dns, ntp: ntp, sniffer: sniffer, tun: tun)
        return CustomSubscriptionImportResult(
            subscription: subscription, ignoredTopLevelKeys: ignored, notes: notes,
            proxies: importedProxies,
            pendingProviderProfiles: pendingProviderProfiles,
            pendingRuleProviders: pendingRuleProviders)
    }

    // MARK: - 分组

    private static let groupKeys: Set<String> = [
        "name", "type", "proxies", "use", "url", "interval", "timeout",
        "tolerance", "lazy", "hidden", "disable-udp", "filter",
        "exclude-filter", "strategy", "icon", "max-failed-times",
        "expected-status", "empty-fallback", "default-selected", "hash-key",
        // Smart groups (v0.2.60, upstream c4bc31d): policy-priority
        // is stored; the model keys are core-warn-only (the core
        // notes them and ignores them), so they are accepted and
        // reported in notes, never stored and never a hard error.
        "policy-priority", "uselightgbm", "collectdata", "sample-rate",
        "prefer-asn",
    ]

    /// Mirrors upstream crates/config/src/raw.rs asks_for_something:
    /// null / empty string / empty list / empty map ask for nothing;
    /// any bool or number asks for something. The core's
    /// ignore_switch additionally stays silent for exactly `false`.
    private static func asksForSomething(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return false
        case .string(let text): return !text.isEmpty
        case .array(let items): return !items.isEmpty
        case .object(let map): return !map.isEmpty
        case .bool, .int, .double: return true
        }
    }

    /// Canonicalise a JSON value for identity comparison: numbers
    /// compare by value, not representation (.int(443) ==
    /// .double(443.0) — upstream _comparable stringifies numbers,
    /// custom_import.dart:326-330). Only used for the comparable
    /// form, never for storage.
    private static func canonicalNumber(_ value: JSONValue) -> JSONValue {
        switch value {
        case .int(let n): return .double(Double(n))
        case .array(let items): return .array(items.map(canonicalNumber))
        case .object(let dict): return .object(dict.mapValues(canonicalNumber))
        default: return value
        }
    }

    /// A string field of a proxy definition, "" when absent or not
    /// a string — for the form-proxy identity check.
    private static func proxyStringField(_ dict: [String: JSONValue], _ key: String) -> String {
        if case .string(let s) = dict[key] { return s } else { return "" }
    }

    /// An int field of a proxy definition, 0 when absent — accepts
    /// .int and .double (a YAML `port: 443.0` is still port 443).
    private static func proxyIntField(_ dict: [String: JSONValue], _ key: String) -> Int {
        if case .int(let p) = dict[key] { return Int(p) }
        if case .double(let d) = dict[key] { return Int(d) }
        return 0
    }

    private static func mapGroup(_ value: JSONValue, index: Int, resolve: (String) -> String) throws -> (CustomGroup, [String]) {
        guard case .object(let dict) = value else {
            throw CustomSubscriptionImportError(message: "分组 #\(index + 1) 必须是映射")
        }
        let unknown = dict.keys.filter { !groupKeys.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CustomSubscriptionImportError(message: "分组 #\(index + 1) 含有无法识别的字段：\(unknown.joined(separator: "、"))")
        }
        let name = try stringField(dict, key: "name", context: "分组 #\(index + 1) 的 name")
        guard !name.isEmpty else {
            throw CustomSubscriptionImportError(message: "分组 #\(index + 1) 缺少 name")
        }
        let type = try stringField(dict, key: "type", context: "分组「\(name)」的 type", default: "select")
        guard CustomGroup.types.contains(type) else {
            throw CustomSubscriptionImportError(message: "分组「\(name)」的类型「\(type)」不受支持")
        }
        var group = CustomGroup(
            // The group's own name follows its rename too (a group
            // colliding with a stored proxy / node final was
            // renamed by the groupRenames pass); error contexts
            // below keep the original name so the file is
            // recognisable.
            name: resolve(name), type: type,
            // Members naming an imported node or another group
            // follow its rename (upstream _importGroup renames
            // group members through the same names map); the
            // resolver tells a group reference from a node one.
            members: try stringListField(dict, key: "proxies", context: "分组「\(name)」的 proxies").map(resolve),
            useProviders: try stringListField(dict, key: "use", context: "分组「\(name)」的 use"),
            url: try stringField(dict, key: "url", context: "分组「\(name)」的 url"),
            interval: try intField(dict, key: "interval", context: "分组「\(name)」的 interval"),
            timeout: try intField(dict, key: "timeout", context: "分组「\(name)」的 timeout"),
            tolerance: try intField(dict, key: "tolerance", context: "分组「\(name)」的 tolerance"),
            lazy: try boolField(dict, key: "lazy", context: "分组「\(name)」的 lazy"),
            hidden: try boolField(dict, key: "hidden", context: "分组「\(name)」的 hidden"),
            disableUDP: try boolField(dict, key: "disable-udp", context: "分组「\(name)」的 disable-udp"),
            filter: try stringField(dict, key: "filter", context: "分组「\(name)」的 filter"),
            excludeFilter: try stringField(dict, key: "exclude-filter", context: "分组「\(name)」的 exclude-filter"),
            strategy: try stringField(dict, key: "strategy", context: "分组「\(name)」的 strategy"),
            icon: try stringField(dict, key: "icon", context: "分组「\(name)」的 icon"))
        if let maxFailed = try optionalIntField(dict, key: "max-failed-times", context: "分组「\(name)」的 max-failed-times") {
            group.maxFailedTimes = maxFailed
        }
        if let expected = try optionalStringField(dict, key: "expected-status", context: "分组「\(name)」的 expected-status") {
            group.expectedStatus = expected
        }
        if let fallback = try optionalStringField(dict, key: "empty-fallback", context: "分组「\(name)」的 empty-fallback") {
            group.emptyFallback = fallback
        }
        if let selected = try optionalStringField(dict, key: "default-selected", context: "分组「\(name)」的 default-selected") {
            group.defaultSelected = resolve(selected)
        }
        if let hashKey = try optionalStringField(dict, key: "hash-key", context: "分组「\(name)」的 hash-key") {
            group.hashKey = hashKey
        }
        if let policyPriority = try optionalStringField(dict, key: "policy-priority", context: "分组「\(name)」的 policy-priority") {
            group.policyPriority = policyPriority
        }
        // Smart model keys (upstream read_smart / ignore_switch):
        // noted only when they ask for something (`false` stays
        // silent, like the core); never stored, never an error.
        var notes: [String] = []
        let ignoredModelKeys = ["uselightgbm", "collectdata", "sample-rate", "prefer-asn"].filter { key in
            guard let value = dict[key] else { return false }
            return value != .bool(false) && asksForSomething(value)
        }
        if !ignoredModelKeys.isEmpty {
            notes.append("分组「\(name)」的 \(ignoredModelKeys.joined(separator: "、")) 未保存（核心不支持模型训练，仅作提示）")
        }
        return (group, notes)
    }

    // MARK: - 提供方

    private static let providerKeys: Set<String> = [
        "type", "behavior", "url", "path", "interval", "health-check",
        "proxy-override", "filter", "exclude-filter",
    ]

    private static func mapProvider(name: String, value: JSONValue, isRuleProvider: Bool) throws -> (CustomProvider, [String], String?) {
        guard case .object(let dict) = value else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」必须是映射")
        }
        // format / payload are rule-provider-only keys (mihomo has
        // no format on proxy providers); age-secret-key is a
        // proxy-provider-only key (the core's proxy parse reads
        // it; rule providers have no age key — upstream
        // readsAgeSecretKey is false for them). A proxy provider
        // carrying payload is accepted but noted (the core keeps a
        // payload fallback for proxy providers, but the
        // custom-subscription model cannot hold it — upstream
        // ignores it too).
        var allowedKeys = providerKeys
        if isRuleProvider {
            allowedKeys.formUnion(["format", "payload"])
        } else {
            allowedKeys.formUnion(["age-secret-key", "payload"])
        }
        let unknown = dict.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」含有无法识别的字段：\(unknown.joined(separator: "、"))")
        }
        var notes: [String] = []
        // age-secret-key (v0.2.148): proxy providers only. The
        // third return value carries it to the pending list, so
        // the created URL Profile stores it (findOrCreateProvider-
        // Profile) — the key is NEVER stored on the CustomProvider
        // itself or baked into the config. Upstream reads it the
        // same way (custom_import.dart readsAgeSecretKey).
        var ageSecretKey: String? = nil
        if !isRuleProvider, let ageValue = dict["age-secret-key"] {
            guard case .string(let ageText) = ageValue else {
                throw CustomSubscriptionImportError(message: "提供方「\(name)」的 age-secret-key 必须是字符串")
            }
            ageSecretKey = ageText.isEmpty ? nil : ageText
        }
        if !isRuleProvider, let payloadValue = dict["payload"] {
            guard case .array = payloadValue else {
                throw CustomSubscriptionImportError(message: "提供方「\(name)」的 payload 必须是列表")
            }
            notes.append("提供方「\(name)」的 payload 未保存（代理提供方的内容不在自定义订阅中保存）")
        }
        // behavior: stored for rule providers (v0.2.148 — the
        // model now holds it); for proxy providers the old rule
        // stands (classical is a no-op note, anything else is a
        // hard error — mihomo proxy providers have no behavior).
        var behavior: String? = nil
        if let behaviorValue = dict["behavior"] {
            guard case .string(let behaviorText) = behaviorValue else {
                throw CustomSubscriptionImportError(message: "提供方「\(name)」的 behavior 必须是字符串")
            }
            if isRuleProvider {
                guard ["domain", "ipcidr", "classical"].contains(behaviorText) else {
                    throw CustomSubscriptionImportError(
                        message: "提供方「\(name)」的 behavior=\(behaviorText) 不受支持（domain / ipcidr / classical）")
                }
                behavior = behaviorText
            } else if behaviorText == "classical" {
                notes.append("提供方「\(name)」的 behavior=classical 未保存（代理提供方没有 behavior 字段）")
            } else {
                throw CustomSubscriptionImportError(
                    message: "提供方「\(name)」的 behavior=\(behaviorText) 无法表示（自定义订阅不保存 behavior，只有 classical 可按核心默认值处理）")
            }
        }
        // format / payload: rule providers only.
        var format: String? = nil
        var payload: [String] = []
        if isRuleProvider {
            if let formatValue = dict["format"] {
                guard case .string(let formatText) = formatValue else {
                    throw CustomSubscriptionImportError(message: "提供方「\(name)」的 format 必须是字符串")
                }
                // "" means yaml in the core (provider.rs:
                // "" | "yaml" => Yaml) — treat it as unset rather
                // than an error.
                if !formatText.isEmpty {
                    guard ["yaml", "text", "mrs", "domain-set"].contains(formatText) else {
                        throw CustomSubscriptionImportError(
                            message: "提供方「\(name)」的 format=\(formatText) 不受支持（yaml / text / mrs / domain-set）")
                    }
                    // v0.2.157 (domain-set decision): the core
                    // accepts format=domain-set ONLY with
                    // behavior=domain (provider.rs
                    // parse_rule_provider: "the domain-set format
                    // needs the domain behavior") — a mismatched
                    // pair makes the core reject the WHOLE config,
                    // so fail the import here with the reason
                    // instead of baking a broken config. The
                    // payload is Surge DOMAIN-SET text, one domain
                    // per line; ".example.com" also covers
                    // "example.com" (core RuleFormat::DomainSet).
                    if formatText == "domain-set" && behavior != "domain" {
                        throw CustomSubscriptionImportError(
                            message: "提供方「\(name)」的 format=domain-set 需要 behavior=domain（当前为 \(behavior ?? "未设置")），否则核心会拒绝整个配置")
                    }
                    format = formatText
                }
            }
            if let payloadValue = dict["payload"] {
                guard case .array(let items) = payloadValue else {
                    throw CustomSubscriptionImportError(message: "提供方「\(name)」的 payload 必须是列表")
                }
                for item in items {
                    guard case .string(let line) = item else {
                        throw CustomSubscriptionImportError(message: "提供方「\(name)」的 payload 里的每一项都必须是字符串")
                    }
                    payload.append(line)
                }
            }
        }
        let kind = try stringField(dict, key: "type", context: "提供方「\(name)」的 type", default: "http")
        guard kind == "http" || kind == "file" || (isRuleProvider && kind == "inline") else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」的 type「\(kind)」不受支持")
        }
        let url = try stringField(dict, key: "url", context: "提供方「\(name)」的 url")
        let path = try stringField(dict, key: "path", context: "提供方「\(name)」的 path")
        if kind == "http" && url.isEmpty {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」缺少 url")
        }
        if kind == "file" && path.isEmpty {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」缺少 path")
        }
        if kind == "inline" && payload.isEmpty {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」是 inline 类型但缺少 payload")
        }
        var provider = CustomProvider(
            name: name, kind: kind, url: url, path: path,
            interval: try intField(dict, key: "interval", context: "提供方「\(name)」的 interval"),
            healthCheck: false,
            filter: try stringField(dict, key: "filter", context: "提供方「\(name)」的 filter"),
            excludeFilter: try stringField(dict, key: "exclude-filter", context: "提供方「\(name)」的 exclude-filter"),
            behavior: behavior, format: format, payload: payload)
        if let healthCheck = dict["health-check"] {
            try parseHealthCheck(healthCheck, provider: &provider, name: name)
        }
        if let override = dict["proxy-override"] {
            try parseProxyOverride(override, provider: &provider, name: name)
        }
        return (provider, notes, ageSecretKey)
    }

    private static let healthCheckKeys: Set<String> = ["enable", "url", "timeout", "lazy", "expected-status"]

    private static func parseHealthCheck(_ value: JSONValue, provider: inout CustomProvider, name: String) throws {
        switch value {
        case .bool(let enabled):
            provider.healthCheck = enabled
        case .object(let dict):
            let unknown = dict.keys.filter { !healthCheckKeys.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw CustomSubscriptionImportError(message: "提供方「\(name)」的 health-check 含有无法识别的字段：\(unknown.joined(separator: "、"))")
            }
            provider.healthCheck = try boolField(dict, key: "enable", context: "提供方「\(name)」的 health-check.enable")
            provider.healthCheckURL = try optionalStringField(dict, key: "url", context: "提供方「\(name)」的 health-check.url")
            provider.healthCheckTimeout = try optionalIntField(dict, key: "timeout", context: "提供方「\(name)」的 health-check.timeout")
            provider.healthCheckLazy = try optionalBoolField(dict, key: "lazy", context: "提供方「\(name)」的 health-check.lazy")
            provider.expectedStatus = try optionalStringField(dict, key: "expected-status", context: "提供方「\(name)」的 health-check.expected-status")
        default:
            throw CustomSubscriptionImportError(message: "提供方「\(name)」的 health-check 必须是 true/false 或映射")
        }
    }

    private static let proxyOverrideKeys: Set<String> = [
        "udp", "skip-cert-verify", "ip-version", "additional-prefix", "additional-suffix",
    ]

    private static func parseProxyOverride(_ value: JSONValue, provider: inout CustomProvider, name: String) throws {
        guard case .object(let dict) = value else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」的 proxy-override 必须是映射")
        }
        let unknown = dict.keys.filter { !proxyOverrideKeys.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」的 proxy-override 含有无法识别的字段：\(unknown.joined(separator: "、"))")
        }
        provider.udp = try optionalBoolField(dict, key: "udp", context: "提供方「\(name)」的 proxy-override.udp")
        provider.skipCertVerify = try optionalBoolField(dict, key: "skip-cert-verify", context: "提供方「\(name)」的 proxy-override.skip-cert-verify")
        provider.ipVersion = try optionalStringField(dict, key: "ip-version", context: "提供方「\(name)」的 proxy-override.ip-version")
        provider.additionalPrefix = try optionalStringField(dict, key: "additional-prefix", context: "提供方「\(name)」的 proxy-override.additional-prefix")
        provider.additionalSuffix = try optionalStringField(dict, key: "additional-suffix", context: "提供方「\(name)」的 proxy-override.additional-suffix")
    }

    // MARK: - 规则

    /// 按逗号切分一条规则（引号内的逗号保留），返回 CustomRule。
    private static func mapRule(_ text: String, index: Int) throws -> CustomRule {
        var parts: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        guard parts.count >= 2 else {
            throw CustomSubscriptionImportError(message: "规则 #\(index + 1) 格式不对：\(text)")
        }
        let type = parts[0]
        guard CustomRule.types.contains(type) else {
            throw CustomSubscriptionImportError(message: "规则 #\(index + 1) 的类型「\(type)」不受支持：\(text)")
        }
        if type == "MATCH" || type == "FINAL" {
            guard parts.count == 2 else {
                throw CustomSubscriptionImportError(message: "规则 #\(index + 1)（\(type)）应为「\(type),目标」：\(text)")
            }
            return CustomRule(type: type, content: "", target: parts[1])
        }
        guard parts.count >= 3 else {
            throw CustomSubscriptionImportError(message: "规则 #\(index + 1) 缺少目标：\(text)")
        }
        let flags = Array(parts.dropFirst(3))
        for flag in flags where flag != "no-resolve" && flag != "src" {
            throw CustomSubscriptionImportError(message: "规则 #\(index + 1) 有无法识别的标志「\(flag)」：\(text)")
        }
        var content = parts[1]
        if content.count >= 2 && content.hasPrefix("\"") && content.hasSuffix("\"") {
            content = String(content.dropFirst().dropLast())
        }
        if content.contains(",") && type != "URL-REGEX" && type != "USER-AGENT" {
            throw CustomSubscriptionImportError(message: "规则 #\(index + 1) 的内容含逗号，无法表示：\(text)")
        }
        return CustomRule(type: type, content: content, target: parts[2],
                          noResolve: flags.contains("no-resolve"), src: flags.contains("src"))
    }

    // MARK: - 配置区（dns / ntp / sniffer / tun）

    /// Lenient readers for the override sections: a wrong-typed
    /// value maps to nil (the key then lands in `unknown`) instead
    /// of failing the whole import — upstream _knownKeys drops
    /// what the override decoders cannot hold, the same way.
    private static func lenientString(_ dict: [String: JSONValue], key: String) -> String? {
        guard case .string(let text) = dict[key], !text.isEmpty else { return nil }
        return text
    }

    private static func lenientBool(_ dict: [String: JSONValue], key: String) -> Bool? {
        guard case .bool(let flag) = dict[key] else { return nil }
        return flag
    }

    private static func lenientInt(_ dict: [String: JSONValue], key: String) -> Int? {
        switch dict[key] {
        case .int(let number): return Int(number)
        case .double(let number) where number == number.rounded(): return Int(number)
        default: return nil
        }
    }

    private static func lenientStringList(_ dict: [String: JSONValue], key: String) -> [String]? {
        guard case .array(let items) = dict[key] else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let text) = item else { return nil }
            out.append(text)
        }
        return out
    }

    private static func lenientStringMap(_ dict: [String: JSONValue], key: String) -> [String: String]? {
        guard case .object(let map) = dict[key] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in map {
            guard case .string(let text) = value else { return nil }
            out[key] = text
        }
        return out
    }

    private static func lenientIntList(_ dict: [String: JSONValue], key: String) -> [Int]? {
        guard case .array(let items) = dict[key] else { return nil }
        var out: [Int] = []
        for item in items {
            switch item {
            case .int(let number): out.append(Int(number))
            case .double(let number) where number == number.rounded(): out.append(Int(number))
            default: return nil
            }
        }
        return out
    }

    private static let dnsKeys: Set<String> = [
        "enable", "listen", "listen-routing-mark", "prefer-h3", "use-hosts",
        "use-system-hosts", "respect-rules", "ipv6", "ipv6-timeout",
        "cache-algorithm", "cache-max-size", "default-nameserver",
        "enhanced-mode", "fake-ip-range", "fake-ip-range6", "fake-ip-filter",
        "fake-ip-filter-mode", "fake-ip-ttl", "nameserver-policy",
        "nameserver", "fallback", "fallback-lazy-query",
        "proxy-server-nameserver", "proxy-server-nameserver-policy",
        "direct-nameserver", "direct-nameserver-follow-policy",
        "fallback-filter",
    ]

    /// Maps a `dns:` section (keys are the bake spellings in
    /// CustomSubscriptionStore.dnsYAML). Returns nil when the
    /// section sets nothing, plus the keys it could not hold.
    private static func mapDnsSection(_ dict: [String: JSONValue]) -> (CustomDnsSection?, [String]) {
        var filter: CustomDnsFallbackFilter?
        if case .object(let filterDict) = dict["fallback-filter"] {
            let mapped = CustomDnsFallbackFilter(
                geoip: lenientBool(filterDict, key: "geoip"),
                geoipCode: lenientString(filterDict, key: "geoip-code"),
                geosite: lenientStringList(filterDict, key: "geosite"),
                ipcidr: lenientStringList(filterDict, key: "ipcidr"),
                domain: lenientStringList(filterDict, key: "domain"))
            if mapped != CustomDnsFallbackFilter() { filter = mapped }
        }
        let section = CustomDnsSection(
            enable: lenientBool(dict, key: "enable"),
            listen: lenientString(dict, key: "listen"),
            listenRoutingMark: lenientInt(dict, key: "listen-routing-mark"),
            preferH3: lenientBool(dict, key: "prefer-h3"),
            useHosts: lenientBool(dict, key: "use-hosts"),
            useSystemHosts: lenientBool(dict, key: "use-system-hosts"),
            respectRules: lenientBool(dict, key: "respect-rules"),
            ipv6: lenientBool(dict, key: "ipv6"),
            ipv6Timeout: lenientInt(dict, key: "ipv6-timeout"),
            cacheAlgorithm: lenientString(dict, key: "cache-algorithm"),
            cacheMaxSize: lenientInt(dict, key: "cache-max-size"),
            defaultNameserver: lenientStringList(dict, key: "default-nameserver"),
            enhancedMode: lenientString(dict, key: "enhanced-mode"),
            fakeIpRange: lenientString(dict, key: "fake-ip-range"),
            fakeIpRange6: lenientString(dict, key: "fake-ip-range6"),
            fakeIpFilter: lenientStringList(dict, key: "fake-ip-filter"),
            fakeIpFilterMode: lenientString(dict, key: "fake-ip-filter-mode"),
            fakeIpTtl: lenientInt(dict, key: "fake-ip-ttl"),
            nameserverPolicy: lenientStringMap(dict, key: "nameserver-policy"),
            nameserver: lenientStringList(dict, key: "nameserver"),
            fallback: lenientStringList(dict, key: "fallback"),
            fallbackLazyQuery: lenientBool(dict, key: "fallback-lazy-query"),
            proxyServerNameserver: lenientStringList(dict, key: "proxy-server-nameserver"),
            proxyServerNameserverPolicy: lenientStringMap(dict, key: "proxy-server-nameserver-policy"),
            directNameserver: lenientStringList(dict, key: "direct-nameserver"),
            directNameserverFollowPolicy: lenientBool(dict, key: "direct-nameserver-follow-policy"),
            fallbackFilter: filter)
        let unknown = dict.keys.filter { !dnsKeys.contains($0) }.sorted()
        return (section == CustomDnsSection() ? nil : section, unknown)
    }

    private static let ntpKeys: Set<String> = [
        "enable", "server", "port", "interval", "dialer-proxy", "write-to-system",
    ]

    private static func mapNtpSection(_ dict: [String: JSONValue]) -> (CustomNtpSection?, [String]) {
        let section = CustomNtpSection(
            enable: lenientBool(dict, key: "enable"),
            server: lenientString(dict, key: "server"),
            port: lenientInt(dict, key: "port"),
            interval: lenientInt(dict, key: "interval"),
            dialerProxy: lenientString(dict, key: "dialer-proxy"),
            writeToSystem: lenientBool(dict, key: "write-to-system"))
        let unknown = dict.keys.filter { !ntpKeys.contains($0) }.sorted()
        return (section == CustomNtpSection() ? nil : section, unknown)
    }

    private static let snifferKeys: Set<String> = [
        "enable", "override-destination", "force-dns-mapping", "parse-pure-ip",
        "force-domain", "skip-domain", "skip-src-address", "skip-dst-address", "sniff",
    ]

    private static func mapSniffProtocol(_ dict: [String: JSONValue], key: String) -> SniffProtocolConfig {
        let candidates = [key, key.lowercased()]
        for candidate in candidates {
            guard case .object(let proto) = dict[candidate] else { continue }
            return SniffProtocolConfig(
                ports: lenientStringList(proto, key: "ports") ?? [],
                overrideDest: lenientBool(proto, key: "override-destination"))
        }
        return SniffProtocolConfig()
    }

    private static func mapSnifferSection(_ dict: [String: JSONValue]) -> (CustomSnifferSection?, [String]) {
        var sniffHttp = SniffProtocolConfig()
        var sniffTls = SniffProtocolConfig()
        var sniffQuic = SniffProtocolConfig()
        if case .object(let sniff) = dict["sniff"] {
            sniffHttp = mapSniffProtocol(sniff, key: "HTTP")
            sniffTls = mapSniffProtocol(sniff, key: "TLS")
            sniffQuic = mapSniffProtocol(sniff, key: "QUIC")
        }
        let section = CustomSnifferSection(
            enable: lenientBool(dict, key: "enable"),
            overrideDestination: lenientBool(dict, key: "override-destination"),
            forceDnsMapping: lenientBool(dict, key: "force-dns-mapping"),
            parsePureIp: lenientBool(dict, key: "parse-pure-ip"),
            forceDomain: lenientStringList(dict, key: "force-domain"),
            skipDomain: lenientStringList(dict, key: "skip-domain"),
            skipSrcAddress: lenientStringList(dict, key: "skip-src-address"),
            skipDstAddress: lenientStringList(dict, key: "skip-dst-address"),
            sniffHttp: sniffHttp, sniffTls: sniffTls, sniffQuic: sniffQuic)
        let unknown = dict.keys.filter { !snifferKeys.contains($0) }.sorted()
        return (section == CustomSnifferSection() ? nil : section, unknown)
    }

    private static let tunKeys: Set<String> = [
        "enable", "stack", "mtu", "congestion-controller", "strict-route",
        "route-address", "route-exclude-address", "dns-hijack", "udp-timeout",
        "disable-icmp-forwarding", "gso", "include-interface",
        "exclude-interface", "include-uid", "exclude-uid",
        "exclude-src-port", "exclude-dst-port", "loopback-address",
    ]

    private static func mapTunSection(_ dict: [String: JSONValue]) -> (CustomTunSection?, [String]) {
        let section = CustomTunSection(
            enable: lenientBool(dict, key: "enable"),
            stack: lenientString(dict, key: "stack"),
            mtu: lenientInt(dict, key: "mtu"),
            congestionController: lenientString(dict, key: "congestion-controller"),
            strictRoute: lenientBool(dict, key: "strict-route"),
            routeAddress: lenientStringList(dict, key: "route-address"),
            routeExcludeAddress: lenientStringList(dict, key: "route-exclude-address"),
            dnsHijack: lenientStringList(dict, key: "dns-hijack"),
            udpTimeout: lenientInt(dict, key: "udp-timeout"),
            disableIcmpForwarding: lenientBool(dict, key: "disable-icmp-forwarding"),
            gso: lenientBool(dict, key: "gso"),
            includeInterface: lenientStringList(dict, key: "include-interface"),
            excludeInterface: lenientStringList(dict, key: "exclude-interface"),
            includeUid: lenientIntList(dict, key: "include-uid"),
            excludeUid: lenientIntList(dict, key: "exclude-uid"),
            excludeSrcPort: lenientIntList(dict, key: "exclude-src-port"),
            excludeDstPort: lenientIntList(dict, key: "exclude-dst-port"),
            loopbackAddress: lenientStringList(dict, key: "loopback-address"))
        let unknown = dict.keys.filter { !tunKeys.contains($0) }.sorted()
        return (section == CustomTunSection() ? nil : section, unknown)
    }

    // MARK: - 字段读取（缺失给默认，类型不对报错）

    private static func stringField(_ dict: [String: JSONValue], key: String, context: String, default defaultValue: String = "") throws -> String {
        guard let value = dict[key] else { return defaultValue }
        guard case .string(let text) = value else {
            throw CustomSubscriptionImportError(message: "\(context) 必须是字符串")
        }
        return text
    }

    private static func optionalStringField(_ dict: [String: JSONValue], key: String, context: String) throws -> String? {
        guard let value = dict[key] else { return nil }
        guard case .string(let text) = value else {
            throw CustomSubscriptionImportError(message: "\(context) 必须是字符串")
        }
        return text.isEmpty ? nil : text
    }

    private static func intField(_ dict: [String: JSONValue], key: String, context: String) throws -> Int {
        guard let value = dict[key] else { return 0 }
        return try intValue(value, context: context)
    }

    private static func optionalIntField(_ dict: [String: JSONValue], key: String, context: String) throws -> Int? {
        guard let value = dict[key] else { return nil }
        return try intValue(value, context: context)
    }

    private static func intValue(_ value: JSONValue, context: String) throws -> Int {
        switch value {
        case .int(let number):
            return Int(number)
        case .double(let number):
            guard number == number.rounded(), number >= Double(Int.min), number <= Double(Int.max) else {
                throw CustomSubscriptionImportError(message: "\(context) 必须是整数")
            }
            return Int(number)
        default:
            throw CustomSubscriptionImportError(message: "\(context) 必须是整数")
        }
    }

    private static func boolField(_ dict: [String: JSONValue], key: String, context: String) throws -> Bool {
        guard let value = dict[key] else { return false }
        guard case .bool(let flag) = value else {
            throw CustomSubscriptionImportError(message: "\(context) 必须是 true/false")
        }
        return flag
    }

    private static func optionalBoolField(_ dict: [String: JSONValue], key: String, context: String) throws -> Bool? {
        guard let value = dict[key] else { return nil }
        guard case .bool(let flag) = value else {
            throw CustomSubscriptionImportError(message: "\(context) 必须是 true/false")
        }
        return flag
    }

    private static func stringListField(_ dict: [String: JSONValue], key: String, context: String) throws -> [String] {
        guard let value = dict[key] else { return [] }
        guard case .array(let items) = value else {
            throw CustomSubscriptionImportError(message: "\(context) 必须是列表")
        }
        var out: [String] = []
        for item in items {
            guard case .string(let text) = item else {
                throw CustomSubscriptionImportError(message: "\(context) 里的每一项都必须是字符串")
            }
            out.append(text)
        }
        return out
    }
}
