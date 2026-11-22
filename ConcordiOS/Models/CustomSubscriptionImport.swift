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
//   * proxies（节点定义）是硬错误——模型存不下节点，静默丢弃 41 个节点
//     会让导入看起来成功实则内容全失；错误信息指引用户改到「配置」页
//     导入为普通订阅；
//   * 分组/提供方对象里的未知字段是硬错误（列出字段名）；
//   * rule-providers 的 behavior 只有 classical 可接受：它是核心默认值，
//     未保存也不改变行为（记入 notes 向用户展示）；domain/ipcidr 会改变
//     路由语义且模型存不下，是硬错误；
//   * mixed-port、dns、mode 等顶层配置键与自定义订阅无关，不进模型，
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
    /// 已接受但未存入模型的说明（如 behavior=classical 按核心默认值处理）。
    let notes: [String]
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
        if let proxies = top["proxies"] {
            let count: Int
            if case .array(let items) = proxies {
                count = items.count
            } else {
                count = 0
            }
            throw CustomSubscriptionImportError(
                message: "文件包含 \(count) 个节点定义（proxies），自定义订阅模型无法保存节点；请改到「配置」页用链接/文件导入为普通订阅")
        }
        let knownKeys: Set<String> = ["proxy-groups", "proxy-providers", "rule-providers", "rules"]
        let ignored = top.keys.filter { !knownKeys.contains($0) }.sorted()

        var groups: [CustomGroup] = []
        var notes: [String] = []
        if let rawGroups = top["proxy-groups"] {
            guard case .array(let items) = rawGroups else {
                throw CustomSubscriptionImportError(message: "proxy-groups 必须是列表")
            }
            for (idx, item) in items.enumerated() {
                let (group, groupNotes) = try mapGroup(item, index: idx)
                groups.append(group)
                notes.append(contentsOf: groupNotes)
            }
        }
        var proxyProviders: [CustomProvider] = []
        if let rawProviders = top["proxy-providers"] {
            guard case .object(let dict) = rawProviders else {
                throw CustomSubscriptionImportError(message: "proxy-providers 必须是映射")
            }
            for name in dict.keys.sorted() {
                let (provider, providerNotes) = try mapProvider(name: name, value: dict[name]!)
                proxyProviders.append(provider)
                notes.append(contentsOf: providerNotes)
            }
        }
        var ruleProviders: [CustomProvider] = []
        if let rawProviders = top["rule-providers"] {
            guard case .object(let dict) = rawProviders else {
                throw CustomSubscriptionImportError(message: "rule-providers 必须是映射")
            }
            for name in dict.keys.sorted() {
                let (provider, providerNotes) = try mapProvider(name: name, value: dict[name]!)
                ruleProviders.append(provider)
                notes.append(contentsOf: providerNotes)
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
                rules.append(try mapRule(text, index: idx))
            }
        }
        if groups.isEmpty && proxyProviders.isEmpty && ruleProviders.isEmpty && rules.isEmpty {
            throw CustomSubscriptionImportError(message: "文件中没有找到分组、提供方或规则，无法导入为空订阅")
        }
        let subscription = CustomSubscription(
            name: name, groups: groups, dialers: [],
            proxyProviders: proxyProviders, ruleProviders: ruleProviders, rules: rules)
        return CustomSubscriptionImportResult(
            subscription: subscription, ignoredTopLevelKeys: ignored, notes: notes)
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

    private static func mapGroup(_ value: JSONValue, index: Int) throws -> (CustomGroup, [String]) {
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
            name: name, type: type,
            members: try stringListField(dict, key: "proxies", context: "分组「\(name)」的 proxies"),
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
            group.defaultSelected = selected
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

    private static func mapProvider(name: String, value: JSONValue) throws -> (CustomProvider, [String]) {
        guard case .object(let dict) = value else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」必须是映射")
        }
        let unknown = dict.keys.filter { !providerKeys.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CustomSubscriptionImportError(message: "提供方「\(name)」含有无法识别的字段：\(unknown.joined(separator: "、"))")
        }
        var notes: [String] = []
        if let behavior = dict["behavior"] {
            guard case .string(let behaviorText) = behavior else {
                throw CustomSubscriptionImportError(message: "提供方「\(name)」的 behavior 必须是字符串")
            }
            if behaviorText == "classical" {
                notes.append("提供方「\(name)」的 behavior=classical 未保存（核心默认值即 classical）")
            } else {
                throw CustomSubscriptionImportError(
                    message: "提供方「\(name)」的 behavior=\(behaviorText) 无法表示（自定义订阅不保存 behavior，只有 classical 可按核心默认值处理）")
            }
        }
        let kind = try stringField(dict, key: "type", context: "提供方「\(name)」的 type", default: "http")
        guard kind == "http" || kind == "file" else {
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
        var provider = CustomProvider(
            name: name, kind: kind, url: url, path: path,
            interval: try intField(dict, key: "interval", context: "提供方「\(name)」的 interval"),
            healthCheck: false,
            filter: try stringField(dict, key: "filter", context: "提供方「\(name)」的 filter"),
            excludeFilter: try stringField(dict, key: "exclude-filter", context: "提供方「\(name)」的 exclude-filter"))
        if let healthCheck = dict["health-check"] {
            try parseHealthCheck(healthCheck, provider: &provider, name: name)
        }
        if let override = dict["proxy-override"] {
            try parseProxyOverride(override, provider: &provider, name: name)
        }
        return (provider, notes)
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
