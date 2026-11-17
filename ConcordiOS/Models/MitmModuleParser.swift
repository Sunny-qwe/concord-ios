import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

// MARK: - MITM module parser (FlClash: lib/common/mitm_module.dart)
//
// Ports FlClash's module parsing to Swift: a Surge .sgmodule, Loon
// .plugin, Quantumult X snippet or Stash override is read into a
// MitmModuleContent — the same lists the Concord core's MITM config
// takes (hostname, url/header/body rewrite, mapLocal, script) plus
// Clash rules — in the core's own line syntax, so the core judges
// each line. Lines FlClash cannot carry over are recorded in
// `skipped` with the same reasons, never silently dropped.
//
// Deliberate simplifications vs FlClash (see README):
//   - Stash overrides are parsed by a small YAML-subset reader
//     (MiniYAML, block maps/lists/scalars, flow collections, quoted
//     scalars, literal blocks). Anything it cannot parse falls back
//     to the section parser instead of failing the whole module.
//   - No `mitmAddLine`: the app edits module text wholesale.
//   - No local-file attachments: a map-local `data` that is neither
//     a downloaded URL nor a known resource skips as .relativeData.
//   - `system` is advisory only: a module naming another system
//     still applies (FlClash only warns too).

// MARK: - Arguments

enum MitmModuleArgumentType: String, Codable {
    case input, select, toggle
}

struct MitmModuleArgument: Codable, Equatable {
    var name: String
    var defaultValue: String
    var type: MitmModuleArgumentType = .input
    var options: [String] = []
    var label: String?
    var description: String?
    var number: Bool = false

    var title: String { label ?? name }
}

// MARK: - Skips

enum MitmModuleSkipReason: String, Codable, CaseIterable {
    case section, setting, scriptType, event, disabled, rule, policy
    case jq, jsonBody, rawHeader, conditional, relativeData
    case notDownloaded, unreadable

    /// Chinese label shown in the module detail view.
    var label: String {
        switch self {
        case .section: return "不支持的段"
        case .setting: return "不支持的设置"
        case .scriptType: return "不支持的脚本类型"
        case .event: return "不支持的事件"
        case .disabled: return "脚本已禁用"
        case .rule: return "无法转换的规则"
        case .policy: return "不支持的策略"
        case .jq: return "不支持 jq 改写"
        case .jsonBody: return "不支持 JSON 正文改写"
        case .rawHeader: return "不支持原始头改写"
        case .conditional: return "不支持条件写法"
        case .relativeData: return "本地数据文件未附加"
        case .notDownloaded: return "资源尚未下载"
        case .unreadable: return "无法解析的行"
        }
    }
}

struct MitmModuleSkip: Codable, Equatable {
    var section: String
    var line: String
    var reason: MitmModuleSkipReason
}

// MARK: - Parsed content

/// What a Surge module, a Loon plugin, a Quantumult X snippet or a
/// Stash override adds, in the syntax of FlClash's own lists; the
/// core still judges each line.
struct MitmModuleContent {
    var name: String?
    var description: String?
    var system: String?
    var argumentsDescription: String?
    var arguments: [MitmModuleArgument] = []
    /// Placed by `%INSERT%`, ahead of what other modules append.
    var insertedHostname: [String] = []
    var hostname: [String] = []
    var urlRewrite: [String] = []
    var headerRewrite: [String] = []
    var bodyRewrite: [String] = []
    var mapLocal: [String] = []
    var script: [String] = []
    /// The scripts it declares that FlClash runs, whatever its
    /// arguments leave on.
    var declaredScriptLines: [String] = []
    var declaredScripts: Int { declaredScriptLines.count }
    var rules: [String] = []
    var resourceUrls: Set<String> = []
    var skipped: [MitmModuleSkip] = []

    var isEmpty: Bool {
        hostname.isEmpty && insertedHostname.isEmpty
            && urlRewrite.isEmpty && headerRewrite.isEmpty
            && bodyRewrite.isEmpty && mapLocal.isEmpty && script.isEmpty
            && rules.isEmpty && resourceUrls.isEmpty && skipped.isEmpty
    }

    /// The MITM lists as the core takes them: inserted hostnames
    /// first, then appended ones.
    var mitmLists: MitmModuleMerged {
        MitmModuleMerged(
            hostname: insertedHostname + hostname,
            urlRewrite: urlRewrite,
            headerRewrite: headerRewrite,
            bodyRewrite: bodyRewrite,
            mapLocal: mapLocal,
            script: script,
            rules: rules
        )
    }
}

/// The merged result of several modules: the MITM lists plus the
/// Clash rules (which go first in the profile's rule list).
struct MitmModuleMerged {
    var hostname: [String] = []
    var urlRewrite: [String] = []
    var headerRewrite: [String] = []
    var bodyRewrite: [String] = []
    var mapLocal: [String] = []
    var script: [String] = []
    var rules: [String] = []

    var isEmpty: Bool {
        hostname.isEmpty && urlRewrite.isEmpty && headerRewrite.isEmpty
            && bodyRewrite.isEmpty && mapLocal.isEmpty && script.isEmpty
            && rules.isEmpty
    }

    /// RawConfig wire keys (kebab-case), for module-mitm.json and
    /// mitm.validate. `rules` is kept separate: it travels as the
    /// overlay's top-level `rules`, not inside `mitm`.
    var mitmJSON: [String: Any] {
        var out: [String: Any] = [:]
        if !hostname.isEmpty { out["hostname"] = hostname }
        if !urlRewrite.isEmpty { out["url-rewrite"] = urlRewrite }
        if !headerRewrite.isEmpty { out["header-rewrite"] = headerRewrite }
        if !bodyRewrite.isEmpty { out["body-rewrite"] = bodyRewrite }
        if !mapLocal.isEmpty { out["map-local"] = mapLocal }
        if !script.isEmpty { out["script"] = script }
        return out
    }
}

// MARK: - Small helpers (mirroring FlClash's private functions)

/// The Core's own limit on a map-local file.
let maxMitmResourceSize = 16 << 20

func isMitmResourceUrl(_ text: String) -> Bool {
    text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://")
}

private enum RX {
    static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let sr = Range(r, in: text) else { return nil }
            return String(text[sr])
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        match(pattern, text) != nil
    }

    static func replace(_ pattern: String, _ text: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Replaces each match by running `build` on its capture groups.
    static func replaceMapped(_ pattern: String, _ text: String, build: ([String?]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var out = ""
        var cursor = text.startIndex
        for m in re.matches(in: text, range: range) {
            guard let mr = Range(m.range, in: text) else { continue }
            out += text[cursor..<mr.lowerBound]
            let groups = (0..<m.numberOfRanges).map { i -> String? in
                let r = m.range(at: i)
                guard r.location != NSNotFound, let sr = Range(r, in: text) else { return nil }
                return String(text[sr])
            }
            out += build(groups)
            cursor = mr.upperBound
        }
        out += text[cursor...]
        return out
    }
}

private func isCommentLine(_ line: String) -> Bool {
    line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//")
}

private func unquote(_ text: String) -> String {
    if text.count >= 2
        && ((text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("'") && text.hasSuffix("'"))) {
        return String(text.dropFirst().dropLast())
    }
    return text
}

private func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func field(_ text: String) -> String {
    if !text.isEmpty && text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        && !text.contains("\"") {
        return text
    }
    return quoted(text)
}

private func scriptValue(_ value: String) -> String {
    if value.rangeOfCharacter(from: CharacterSet(charactersIn: " ,\"=[](){}")) != nil {
        return quoted(value)
    }
    return value
}

private func splitLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines)
}

/// Splits on commas outside double quotes, and with `nested` outside
/// parentheses, which only a logical rule can count on to be balanced.
private func splitRule(_ text: String, nested: Bool = false) -> [String] {
    var parts: [String] = []
    var depth = 0
    var quoted = false
    var start = text.startIndex
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        switch c {
        case "\"":
            quoted.toggle()
        case "(" where nested && !quoted:
            depth += 1
        case ")" where nested && !quoted:
            depth -= 1
        case "," where !quoted && depth == 0:
            parts.append(String(text[start..<i]).trimmingCharacters(in: .whitespaces))
            start = text.index(after: i)
        default:
            break
        }
        i = text.index(after: i)
    }
    parts.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
    return parts
}

private let logicalRules: Set<String> = ["AND", "OR", "NOT"]

private func ruleParts(_ text: String) -> [String] {
    let comma = text.firstIndex(of: ",")
    let type = (comma == nil ? text : String(text[..<comma!])).trimmingCharacters(in: .whitespaces)
    return splitRule(text, nested: logicalRules.contains(type.uppercased()))
}

private func splitArguments(_ text: String) -> [String] {
    var parts: [String] = []
    var quoted = false
    var start = text.startIndex
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\"" {
            quoted.toggle()
        } else if c == "," && !quoted {
            parts.append(String(text[start..<i]).trimmingCharacters(in: .whitespaces))
            start = text.index(after: i)
        }
        i = text.index(after: i)
    }
    parts.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
    return parts.filter { !$0.isEmpty }
}

// MARK: - Tokenizers (ported from Dart's _Token / _tokens / _scriptParams)

private struct LineToken {
    let text: String
    /// Character offset into the original line where the token ended.
    let end: Int
}

/// Splits on spaces, keeping a double-quoted run, or a single-quoted
/// one that opens a value as in data='{}', in one token without its
/// quotes. Nil when a quote never closes.
private func lineTokens(_ line: String) -> [LineToken]? {
    let chars = Array(line)
    var tokens: [LineToken] = []
    var i = 0
    while i < chars.count {
        if chars[i] == " " || chars[i] == "\t" { i += 1; continue }
        let start = i
        var text = ""
        var quote: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"" && c == "\\" && i + 1 < chars.count && chars[i + 1] == "\"" {
                    text.append("\"")
                    i += 1
                } else if c == q {
                    quote = nil
                } else {
                    text.append(c)
                }
                i += 1
                continue
            }
            if c == " " || c == "\t" { break }
            if c == "\"" || (c == "'" && (i == start || chars[i - 1] == "=")) {
                quote = c
            } else {
                text.append(c)
            }
            i += 1
        }
        if quote != nil { return nil }
        tokens.append(LineToken(text: text, end: i))
    }
    return tokens
}

/// Splits `key=value,...` as the core does: on the commas outside
/// quotes, groups and character classes, `\"` being the one escape
/// inside quotes. Keys are lowercased.
private func scriptParams(_ text: String) -> [String: String]? {
    var params: [String: String] = [:]
    func add(_ item: String) {
        guard let equals = item.firstIndex(of: "="), equals != item.startIndex else { return }
        var value = String(item[item.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        params[String(item[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()] = value
    }
    let chars = Array(text)
    var quoted = false
    var characterClass = false
    var depth = 0
    var start = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\\" && i + 1 < chars.count && chars[i + 1] == "\"" {
                i += 1
            } else if c == "\"" {
                quoted = false
            }
        } else if c == "\\" {
            i += 1
        } else if c == "\"" {
            quoted = true
        } else if characterClass {
            characterClass = c != "]"
        } else if c == "[" {
            characterClass = true
        } else if c == "(" || c == "{" {
            depth += 1
        } else if (c == ")" || c == "}") && depth > 0 {
            depth -= 1
        } else if c == "," && depth == 0 {
            add(String(chars[start..<i]))
            start = i + 1
        }
        i += 1
    }
    if quoted { return nil }
    add(String(chars[start..<chars.count]))
    return params
}

private let scriptTypes: Set<String> = [
    "http-request", "http-response", "cron", "event",
    "generic", "dns", "rule", "network-changed",
]
private let runnableScriptTypes: Set<String> = [
    "http-request", "http-response", "cron", "event", "generic",
]
private let scriptEvents: Set<String> = [
    "network-changed", "engine-started", "profile-reloaded",
]
private let scriptValueKeys = ["pattern", "cronexp", "event-name"]
private let scriptKeys = [
    "requires-body", "binary-body-mode", "max-size", "timeout", "full-header-mode",
]

/// A Loon cron expression an argument fills in, so without its
/// quotes: every word before the first `key=value`.
private let unquotedCronPattern = #"^[^"\s=]+(?:\s+[^"\s=]+)+(?=\s+[\w-]+\s*=)"#

/// A line with a type parameter is Surge's form, so a name may start
/// with a type; the core reads it the same way, and files a legacy
/// line's value where Surge's form keeps it.
private func scriptLine(_ line: String) -> (name: String, type: String, params: [String: String])? {
    let equals = line.firstIndex(of: "=")
    let params: [String: String]?
    if let equals {
        params = scriptParams(String(line[line.index(after: equals)...]))
    } else {
        params = nil
    }
    let space = line.firstIndex(where: { $0 == " " || $0 == "\t" })
    let keyword = space.map { _ in String(line[..<space!]).lowercased() } ?? ""
    if params?["type"] == nil && scriptTypes.contains(keyword) {
        guard let space else { return nil }
        let rest = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        let cron = keyword == "cron" ? RX.match(unquotedCronPattern, rest) : nil
        let first: LineToken?
        if let cron, let expr = cron[0] {
            first = LineToken(text: expr, end: expr.count)
        } else {
            first = lineTokens(rest)?.first
        }
        let http = keyword.hasPrefix("http-")
        let valued = first != nil && (http || !first!.text.contains("="))
        let legacy = scriptParams(valued ? String(rest.dropFirst(first!.end)) : rest)
        guard var legacy, !(http && !valued) else { return nil }
        let value = valued ? first!.text : ""
        var type = keyword
        var name = legacy["tag"] ?? ""
        switch keyword {
        case "http-request", "http-response":
            legacy["pattern"] = value
        case "cron":
            legacy["cronexp"] = value
        case "event":
            legacy["event-name"] = value
        case "network-changed":
            type = "event"
            legacy["event-name"] = "network-changed"
        default:
            if name.isEmpty { name = value }
        }
        return (name: name, type: type, params: legacy)
    }
    guard let params, let equals else { return nil }
    return (
        name: String(line[..<equals]).trimmingCharacters(in: .whitespaces),
        type: (params["type"] ?? "generic").lowercased(),
        params: params
    )
}

/// Named by content, so a resource that changes changes the line
/// naming it and the core reads it again.
func mitmResourceName(source: String, bytes: Data) -> String {
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let path = URL(string: source)?.path ?? source
    let ext = (path as NSString).pathExtension
    let suffix = ext.count >= 1 && ext.count <= 8
        && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? "." + ext.lowercased() : ""
    return String(digest.prefix(32)) + suffix
}

private func cidr(_ text: String) -> String? {
    if text.contains("%") { return nil }
    let slash = text.firstIndex(of: "/")
    let address = slash.map { _ in String(text[..<slash!]) } ?? text
    let max = address.contains(":") ? 128 : 32
    var prefix = max
    if let slash {
        guard let p = Int(String(text[text.index(after: slash)...])), (0...max).contains(p) else { return nil }
        prefix = p
    }
    var buffer = [UInt8](repeating: 0, count: address.contains(":") ? 16 : 4)
    let family: Int32 = address.contains(":") ? AF_INET6 : AF_INET
    let ok = address.withCString { cstr in
        inet_pton(family, cstr, &buffer)
    }
    guard ok == 1 else { return nil }
    return "\(address)/\(prefix)"
}

private func validPorts(_ text: String) -> Bool {
    guard RX.matches(#"^\d{1,5}(-\d{1,5})?(/\d{1,5}(-\d{1,5})?)*$"#, text) else { return false }
    return text.split(whereSeparator: { $0 == "/" || $0 == "-" })
        .allSatisfy { part in (Int(part) ?? 65_536) <= 65_535 }
}

/// A Quantumult X task line: a cron expression of five or six fields,
/// then the script.
private func qxCron(_ line: String) -> (expression: String, rest: String)? {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    for count in [5, 6] {
        guard fields.count > count,
              fields.prefix(count).allSatisfy({ RX.matches(#"^[\d*?/,\-A-Za-z#]+$"#, $0) }),
              fields[count].contains("://") || fields[count].contains(".js") else { continue }
        let pattern = "^(?:\\S+\\s+){\(count)}"
        guard let m = RX.match(pattern, line),
              let whole = m[0] else { continue }
        return (expression: fields.prefix(count).joined(separator: " "),
                rest: String(line.dropFirst(whole.count)))
    }
    return nil
}

// MARK: - Install links

/// The module URLs a web URL or another app's install link names.
func mitmModuleUrls(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uri = URL(string: trimmed),
          let scheme = uri.scheme?.lowercased() else { return [] }
    let action = (uri.host ?? "") + uri.path
    let actionFlat = action.replacingOccurrences(of: "/", with: "")
    let query = URLComponents(string: trimmed)?.queryItems ?? []
    func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }
    var urls: [String] = []
    switch scheme {
    case "http", "https":
        if uri.host == "link.stash.ws" {
            urls = stashLinkUrls(uri)
        } else {
            urls = [trimmed]
        }
    case "surge" where actionFlat == "install-module":
        if let url = queryValue("url") { urls = [url] }
    case "loon" where actionFlat == "import":
        if let url = queryValue("plugin") { urls = [url] }
    case "shadowrocket" where actionFlat == "install":
        if let url = queryValue("module") { urls = [url] }
    case "stash", "clash" where actionFlat == "install-override":
        if let url = queryValue("url") { urls = [url] }
    case "quantumult-x" where actionFlat == "add-resource" || actionFlat == "update-configuration":
        urls = quantumultXRewrites(queryValue("remote-resource"))
    default:
        break
    }
    return urls.filter { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
}

/// Its URL has no scheme: https unless `?scheme=` names another.
private func stashLinkUrls(_ uri: URL) -> [String] {
    let segments = uri.pathComponents.filter { $0 != "/" }
    guard segments.count >= 2, segments[0] == "install-override" else { return [] }
    let query = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let scheme = query.first { $0.name == "scheme" }?.value ?? "https"
    return ["\(scheme)://" + segments.dropFirst().joined(separator: "/")]
}

private func quantumultXRewrites(_ resource: String?) -> [String] {
    guard let resource,
          let data = resource.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rewrites = json["rewrite_remote"] as? [String] else { return [] }
    return rewrites.map { $0.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "" }
        .filter { !$0.isEmpty }
}

/// What consent to a module's scripts covers; a line run names its
/// content's hash.
func mitmScriptScope(text: String, values: [String: String] = [:], resources: [String: String] = [:]) -> Set<String> {
    let content = MitmModuleParser.parse(text: text, values: values, resources: resources)
    return Set(content.declaredScriptLines + content.script)
}

// MARK: - Parser engine (mirrors Dart's _ModuleParser)

private let sectionPattern = #"^\[([^\]]+)\]$"#
private let conditionalPattern = #"^(request|response)\s+if\s"#
private let loonScriptCallPattern = #"\bthen\s+script\s*\("#
private let domainPattern = #"^[^\s,()]+$"#

private let rejectActions: [String: String] = [
    "REJECT": "reject", "REJECT-DROP": "reject", "REJECT-NO-DROP": "reject",
    "REJECT-TINYGIF": "reject-img", "REJECT-IMG": "reject-img",
    "REJECT-DICT": "reject-dict", "REJECT-ARRAY": "reject-array",
    "REJECT-200": "reject-200",
]
private let rejectRewrites: Set<String> = ["reject", "reject-img", "reject-dict", "reject-array", "reject-200"]

private let ruleTypes: [String: String] = [
    "DOMAIN": "DOMAIN", "DOMAIN-SUFFIX": "DOMAIN-SUFFIX",
    "DOMAIN-KEYWORD": "DOMAIN-KEYWORD", "DOMAIN-WILDCARD": "DOMAIN-WILDCARD",
    "IP-CIDR": "IP-CIDR", "IP-CIDR6": "IP-CIDR6",
    "SRC-IP": "SRC-IP-CIDR", "SRC-IP-CIDR": "SRC-IP-CIDR",
    "DEST-PORT": "DST-PORT", "DST-PORT": "DST-PORT",
    "SRC-PORT": "SRC-PORT", "IN-PORT": "IN-PORT",
    "PROCESS-NAME": "PROCESS-NAME",
]

private let loonContentTypes: [String: String] = [
    "text": "text/plain; charset=utf-8", "json": "application/json",
    "html": "text/html; charset=utf-8", "javascript": "application/javascript",
    "css": "text/css", "xml": "application/xml",
    "png": "image/png", "jpg": "image/jpeg", "gif": "image/gif",
]

private let qxFilterTypes: [String: String] = [
    "host": "DOMAIN", "host-suffix": "DOMAIN-SUFFIX",
    "host-keyword": "DOMAIN-KEYWORD", "host-wildcard": "DOMAIN-WILDCARD",
    "ip-cidr": "IP-CIDR", "ip6-cidr": "IP-CIDR6",
]
private let qxFilterPattern = #"^(host|host-suffix|host-keyword|host-wildcard|ip-cidr|ip6-cidr|user-agent|geoip|ip-asn|final)\s*,"#
private let qxRewritePattern = #"^\S+\s+url\s+\S|\surl-and-header\s"#
private let qxScripts: [String: (phase: String, body: Bool)] = [
    "script-request-header": ("http-request", false),
    "script-request-body": ("http-request", true),
    "script-response-header": ("http-response", false),
    "script-response-body": ("http-response", true),
    "script-echo-response": ("http-request", false),
    "script-analyze-echo-response": ("http-request", true),
]
private let qxTaskTimeout = "120"

private final class MitmModuleParserEngine {
    let values: [String: String]
    let resources: [String: String]

    var meta: [String: String] = [:]
    var surgeArguments: [MitmModuleArgument] = []
    var loonArguments: [MitmModuleArgument] = []
    var stashArguments: [MitmModuleArgument] = []
    var insertedHostname: [String] = []
    var hostname: [String] = []
    var urlRewrite: [String] = []
    var headerRewrite: [String] = []
    var bodyRewrite: [String] = []
    var mapLocal: [String] = []
    var script: [String] = []
    var declaredScriptLines: [String] = []
    var rules: [String] = []
    var resourceUrls: Set<String> = []
    var skipped: [MitmModuleSkip] = []

    init(values: [String: String], resources: [String: String]) {
        self.values = values
        self.resources = resources
    }

    func parse(_ text: String) -> MitmModuleContent {
        let lines = splitLines(text)
        readDeclarations(lines)
        var section: String?
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let header = RX.match(sectionPattern, trimmed) {
                section = header[1]?.trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty || isCommentLine(trimmed) { continue }
            guard let section else {
                _ = readQuantumultX(trimmed)
                continue
            }
            if section.lowercased() == "script" {
                if trimmed.contains("{") {
                    declaredScriptLines.append(trimmed)
                } else {
                    declareScript(scriptLine(trimmed)?.type, line: trimmed)
                }
            }
            let line = substitute(trimmed).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isCommentLine(line) { continue }
            readLine(section, line: line, raw: trimmed)
        }
        return content()
    }

    func content() -> MitmModuleContent {
        func metaValue(_ key: String) -> String? {
            guard let value = meta[key]?.replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        return MitmModuleContent(
            name: metaValue("name"),
            description: metaValue("desc"),
            system: metaValue("system"),
            argumentsDescription: metaValue("arguments-desc"),
            arguments: surgeArguments + loonArguments + stashArguments,
            insertedHostname: insertedHostname,
            hostname: hostname,
            urlRewrite: urlRewrite,
            headerRewrite: headerRewrite,
            bodyRewrite: bodyRewrite,
            mapLocal: mapLocal,
            script: script,
            declaredScriptLines: declaredScriptLines,
            rules: rules,
            resourceUrls: resourceUrls,
            skipped: skipped
        )
    }

    func readDeclarations(_ lines: [String]) {
        var section: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let header = RX.match(sectionPattern, line) {
                section = header[1]?.trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            if line.hasPrefix("#!") {
                readMeta(String(line.dropFirst(2)))
            } else if section == "argument" && !line.isEmpty && !isCommentLine(line) {
                if let argument = loonArgument(line) { loonArguments.append(argument) }
            }
        }
        for item in splitArguments(meta["arguments"] ?? "") {
            let colon = item.firstIndex(of: ":")
            let name = (colon.map { _ in String(item[..<colon!]) } ?? item).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            let defaultValue = colon.map { _ in unquote(String(item[item.index(after: colon!)...]).trimmingCharacters(in: .whitespaces)) } ?? ""
            surgeArguments.append(MitmModuleArgument(
                name: name, defaultValue: defaultValue,
                type: defaultValue == "true" || defaultValue == "false" ? .toggle : .input
            ))
        }
    }

    func readMeta(_ entry: String) {
        guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { return }
        let key = String(entry[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(entry[entry.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "input":
            loonArguments.append(MitmModuleArgument(name: value, defaultValue: ""))
        case "select":
            let options = splitArguments(value).map(unquote)
            if options.count > 1 {
                loonArguments.append(MitmModuleArgument(
                    name: options[0], defaultValue: options[1],
                    type: .select, options: Array(options.dropFirst())
                ))
            }
        default:
            if meta[key] == nil { meta[key] = value }
        }
    }

    /// Reads Loon's `name = input|select|switch,values...,tag=...,desc=...`.
    func loonArgument(_ line: String) -> MitmModuleArgument? {
        guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { return nil }
        let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
        let parts = splitArguments(String(line[line.index(after: equals)...]))
        guard !name.isEmpty, !parts.isEmpty else { return nil }
        let kind = parts[0].lowercased()
        var options: [String] = []
        var label: String?
        var description: String?
        var number = false
        for part in parts.dropFirst() {
            if let m = RX.match(#"^(tag|desc|type)\s*=\s*(.*)$"#, part) {
                switch m[1] {
                case "tag": label = unquote((m[2] ?? "").trimmingCharacters(in: .whitespaces))
                case "desc": description = unquote((m[2] ?? "").trimmingCharacters(in: .whitespaces))
                case "type": number = (m[2] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "number"
                default: break
                }
            } else {
                options.append(unquote(part))
            }
        }
        let type: MitmModuleArgumentType
        switch kind {
        case "select": type = .select
        case "switch": type = .toggle
        default: type = .input
        }
        let defaultValue: String
        switch type {
        case .toggle:
            defaultValue = options.first { $0 == "true" || $0 == "false" } ?? "false"
        default:
            defaultValue = options.first ?? ""
        }
        return MitmModuleArgument(
            name: name, defaultValue: defaultValue, type: type,
            options: type == .select ? options : [],
            label: label.flatMap { $0.isEmpty ? nil : $0 },
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            number: number
        )
    }

    func valueOf(_ argument: MitmModuleArgument) -> String {
        values[argument.name] ?? argument.defaultValue
    }

    func substitute(_ line: String) -> String {
        if !line.contains("{") { return line }
        var line = line
        for argument in surgeArguments {
            line = line.replacingOccurrences(of: "{{{\(argument.name)}}}", with: valueOf(argument))
        }
        for argument in loonArguments {
            let value = valueOf(argument)
            line = line.replacingOccurrences(of: "${\(argument.name)}", with: value)
            line = line.replacingOccurrences(of: "{\(argument.name)}", with: value)
        }
        return line
    }

    func skip(_ section: String, _ line: String, _ reason: MitmModuleSkipReason) {
        skipped.append(MitmModuleSkip(section: section, line: line, reason: reason))
    }

    func readLine(_ section: String, line: String, raw: String) {
        switch section.lowercased() {
        case "argument":
            break
        case "rule":
            readRule(section, line: line)
        case "url rewrite":
            urlRewrite.append(line)
        case "header rewrite":
            headerRewrite.append(line)
        case "body rewrite":
            if RX.matches(#"^http-(request|response)-jq\s"#, line) {
                skip(section, line, .jq)
            } else {
                bodyRewrite.append(line)
            }
        case "map local":
            readMapLocal(section, line: line)
        case "rewrite":
            readLoonRewrite(section, line: line)
        case "mitm":
            readMitm(section, line: line)
        case "script":
            readScript(section, line: line, raw: raw)
        case "rewrite_local", "filter_local", "task_local":
            if !readQuantumultX(line) { skip(section, line, .unreadable) }
        default:
            skip(section, line, .section)
        }
    }

    /// Reads Surge's `name = type=...,...` and the legacy `type pattern ...`
    /// Loon writes, into the form the core's script list takes.
    func readScript(_ section: String, line: String, raw: String) {
        if RX.matches(conditionalPattern, line) || RX.matches(loonScriptCallPattern, line) {
            skip(section, line, .conditional)
            return
        }
        guard let parsed = scriptLine(line) else {
            skip(section, line, .unreadable)
            return
        }
        let (name, type, params) = parsed
        if !runnableScriptTypes.contains(type) {
            skip(section, line, .scriptType)
            return
        }
        if type == "event" && !scriptEvents.contains(params["event-name"] ?? "") {
            skip(section, line, .event)
            return
        }
        if params["enable"]?.lowercased() == "false" {
            skip(section, line, .disabled)
            return
        }
        var after: [(String, String)] = []
        for key in scriptKeys {
            if let value = params[key] { after.append((key, value)) }
        }
        if let object = objectArgument(scriptLine(raw)?.params["argument"]) {
            if let data = try? JSONSerialization.data(withJSONObject: object),
               let json = String(data: data, encoding: .utf8) {
                after.append(("argument-json", json))
            }
        } else if let argument = params["argument"] {
            after.append(("argument", argument))
        }
        var fields: [(String, String)] = [("type", type)]
        for key in scriptValueKeys {
            if let value = params[key] { fields.append((key, value)) }
        }
        addScript(section, line: line, name: name, path: params["script-path"] ?? "", fields: fields, after: after)
    }

    func declareScript(_ type: String?, line: String) {
        if let type, runnableScriptTypes.contains(type) || type.contains("{") {
            declaredScriptLines.append(line)
        }
    }

    /// The resources directory's file for [url], or nil once the line is
    /// skipped for a file the module does not download or the app has not.
    func resource(_ section: String, line: String, url: String) -> String? {
        if !isMitmResourceUrl(url) {
            let attachment = resources[url]
            if attachment == nil { skip(section, line, .relativeData) }
            return attachment
        }
        resourceUrls.insert(url)
        let file = resources[url]
        if file == nil { skip(section, line, .notDownloaded) }
        return file
    }

    /// Writes a script line in the form the core's list takes, its
    /// downloaded file between [fields] and [after].
    func addScript(_ section: String, line: String, name: String, path: String,
                   fields: [(String, String)], after: [(String, String)] = []) {
        guard let file = resource(section, line: line, url: path) else { return }
        let title = name.replacingOccurrences(of: "=", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let display = title.isEmpty
            ? (path.split(separator: "/").last.map(String.init) ?? path)
            : title
        let all = fields + [("script-path", file)] + after
        script.append(display + " = " + all.map { "\($0.0)=\(scriptValue($0.1))" }.joined(separator: ","))
    }

    /// Loon's `argument=[{a},{b}]`, which hands the script an object of
    /// the arguments it names, each keeping its type.
    func objectArgument(_ text: String?) -> [String: Any]? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              let m = RX.match(#"^\[(.*)\]$"#, text), let inner = m[1] else { return nil }
        var object: [String: Any] = [:]
        for item in inner.split(separator: ",") {
            let item = item.trimmingCharacters(in: .whitespaces)
            guard let nameMatch = RX.match(#"^\{([^{}]+)\}$"#, item),
                  let name = nameMatch[1] else { return nil }
            let argument = loonArguments.first { $0.name == name }
            let value = argument.map { valueOf($0) }
            if let argument, let value {
                switch argument.type {
                case .toggle: object[name] = value == "true"
                default:
                    if argument.number, let number = Int(value) {
                        object[name] = number
                    } else if argument.number, let number = Double(value) {
                        object[name] = number
                    } else {
                        object[name] = value
                    }
                }
            } else {
                object[name] = NSNull()
            }
        }
        return object.isEmpty ? nil : object
    }

    func readMitm(_ section: String, line: String) {
        guard let equals = line.firstIndex(of: "=") else {
            skip(section, line, .setting)
            return
        }
        let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "hostname" else {
            skip(section, line, .setting)
            return
        }
        var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        var inserted = false
        if value.hasPrefix("%INSERT%") {
            inserted = true
            value = String(value.dropFirst("%INSERT%".count))
        } else if value.hasPrefix("%APPEND%") {
            value = String(value.dropFirst("%APPEND%".count))
        }
        let hosts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if inserted {
            insertedHostname.append(contentsOf: hosts)
        } else {
            hostname.append(contentsOf: hosts)
        }
    }

    func readRule(_ section: String, line: String, shown: String? = nil) {
        let parts = ruleParts(line)
        guard let first = parts.first else { return }
        let type = first.uppercased()
        let policy = parts.count > 2 ? parts[2].uppercased() : nil
        if type == "URL-REGEX" {
            if let policy, let action = rejectActions[policy] {
                urlRewrite.append("\(field(unquote(parts.count > 1 ? parts[1] : ""))) \(action)")
            } else {
                skip(section, shown ?? line, .policy)
            }
            return
        }
        let target: String?
        switch policy {
        case "DIRECT": target = "DIRECT"
        case "REJECT-DROP": target = "REJECT-DROP"
        case let policy? where rejectActions[policy] != nil: target = "REJECT"
        default: target = nil
        }
        guard let target else {
            skip(section, shown ?? line, .policy)
            return
        }
        guard let rule = translateRule(parts.first ?? "", payload: parts.count > 1 ? parts[1] : "", options: Array(parts.dropFirst(3))) else {
            skip(section, shown ?? line, .rule)
            return
        }
        var out = "\(rule.body),\(target)"
        if rule.noResolve { out += ",no-resolve" }
        rules.append(out)
    }

    func translateRule(_ rawType: String, payload: String, options: [String], nested: Bool = false) -> (body: String, noResolve: Bool)? {
        let type = rawType.trimmingCharacters(in: .whitespaces).uppercased()
        switch type {
        case "AND", "OR", "NOT":
            guard let operands = operands(payload),
                  !(type == "NOT" && operands.count != 1) else { return nil }
            var translated: [String] = []
            for operand in operands {
                let parts = ruleParts(operand)
                guard let rule = translateRule(parts.first ?? "", payload: parts.count > 1 ? parts[1] : "", options: [], nested: true) else { return nil }
                translated.append("(\(rule.body))")
            }
            return (body: "\(type),(\(translated.joined(separator: ",")))", noResolve: false)
        case "PROTOCOL" where nested:
            let network: String?
            switch payload.trimmingCharacters(in: .whitespaces).uppercased() {
            case "TCP": network = "TCP"
            case "UDP", "QUIC": network = "UDP"
            default: network = nil
            }
            guard let network else { return nil }
            return (body: "NETWORK,\(network)", noResolve: false)
        default:
            break
        }
        guard let target = ruleTypes[type] else { return nil }
        var value = unquote(payload.trimmingCharacters(in: .whitespaces))
        switch target {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD":
            guard RX.matches(domainPattern, value) else { return nil }
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            guard let parsed = cidr(value) else { return nil }
            value = parsed
        case "DST-PORT", "SRC-PORT", "IN-PORT":
            guard validPorts(value) else { return nil }
        default:
            if value.isEmpty || value.contains(",") { return nil }
        }
        return (
            body: "\(target),\(value)",
            noResolve: target.hasPrefix("IP-CIDR")
                && options.contains { $0.lowercased() == "no-resolve" }
        )
    }

    func operands(_ payload: String) -> [String]? {
        let text = payload.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("("), text.hasSuffix(")") else { return nil }
        let inner = String(text.dropFirst().dropLast())
        var out: [String] = []
        for part in splitRule(inner, nested: true) {
            guard part.hasPrefix("("), part.hasSuffix(")") else { return nil }
            out.append(String(part.dropFirst().dropLast()))
        }
        return out.isEmpty ? nil : out
    }

    func readMapLocal(_ section: String, line: String) {
        guard let tokens = lineTokens(line), !tokens.isEmpty else {
            skip(section, line, .unreadable)
            return
        }
        var params: [(String, String)] = []
        for token in tokens.dropFirst() {
            guard let equals = token.text.firstIndex(of: "="), equals != token.text.startIndex else {
                skip(section, line, .unreadable)
                return
            }
            params.append((
                String(token.text[..<equals]).lowercased(),
                String(token.text[token.text.index(after: equals)...])
            ))
        }
        addMapLocal(section, line: line, pattern: tokens[0].text, params: params)
    }

    func addMapLocal(_ section: String, line: String, pattern: String, params: [(String, String)]) {
        var params = params
        let dataType = params.first { $0.0 == "data-type" }?.1 ?? "file"
        if dataType == "file" {
            let data = params.first { $0.0 == "data" }?.1 ?? ""
            guard let file = resource(section, line: line, url: data) else { return }
            if let index = params.firstIndex(where: { $0.0 == "data" }) {
                params[index] = ("data", file)
            } else {
                params.append(("data", file))
            }
        }
        mapLocal.append(([field(pattern)] + params.map { "\($0.0)=\(quoted($0.1))" }).joined(separator: " "))
    }

    /// Loon's legacy `pattern action ...`, which spreads over Surge's lists.
    func readLoonRewrite(_ section: String, line: String) {
        if RX.matches(conditionalPattern, line) {
            skip(section, line, .conditional)
            return
        }
        guard let tokens = lineTokens(line), tokens.count >= 2 else {
            skip(section, line, .unreadable)
            return
        }
        let pattern = field(tokens[0].text)
        var action = tokens[1].text.lowercased()
        var rest = String(line.dropFirst(tokens[1].end)).trimmingCharacters(in: .whitespaces)
        if (action == "-" || action == "_") && tokens.count > 2 {
            action = tokens[2].text.lowercased()
            rest = String(line.dropFirst(tokens[2].end)).trimmingCharacters(in: .whitespaces)
        }
        if let reject = rejectActions[action.uppercased()] {
            urlRewrite.append("\(pattern) \(reject)")
            return
        }
        if ["302", "307", "header"].contains(action) && tokens.count > 2 {
            urlRewrite.append("\(pattern) \(field(tokens[2].text)) \(action)")
            return
        }
        if isMitmResourceUrl(tokens[1].text) && tokens.count > 2 {
            let type = tokens[2].text.lowercased()
            if ["302", "307", "header"].contains(type) {
                urlRewrite.append("\(pattern) \(field(tokens[1].text)) \(type)")
                return
            }
        }
        if action == "url" {
            urlRewrite.append(line)
            return
        }
        if tokens.count == 2 && !action.contains("-") {
            urlRewrite.append("\(pattern) \(field(tokens[1].text))")
            return
        }
        if let header = RX.match(#"^(request-|response-)?(header-(add|del|replace|replace-regex))$"#, action) {
            let phase = header[1] == "response-" ? "http-response" : "http-request"
            headerRewrite.append("\(phase) \(pattern) \(header[2] ?? "") \(rest)".trimmingCharacters(in: .whitespaces))
            return
        }
        switch action {
        case "request-body-replace-regex":
            bodyRewrite.append("http-request \(pattern) \(rest)")
        case "response-body-replace-regex":
            bodyRewrite.append("http-response \(pattern) \(rest)")
        case "mock-response-body":
            readLoonMock(section, line: line, pattern: tokens[0].text, tokens: Array(tokens.dropFirst(2)))
        default:
            skip(section, line,
                 RX.matches(#"^(request|response)-body-json-"#, action) ? .jsonBody : .unreadable)
        }
    }

    func readLoonMock(_ section: String, line: String, pattern: String, tokens: [LineToken]) {
        var params: [String: String] = [:]
        for token in tokens {
            if let equals = token.text.firstIndex(of: "="), equals != token.text.startIndex {
                params[String(token.text[..<equals]).lowercased()] =
                    String(token.text[token.text.index(after: equals)...])
            }
        }
        let dataType = params["data-type"]?.lowercased() ?? "text"
        var mapped: [(String, String)] = []
        if let path = params["data-path"] {
            mapped.append(("data-type", "file"))
            mapped.append(("data", path))
        } else if dataType == "tiny-gif" {
            mapped.append(("data-type", "tiny-gif"))
        } else {
            mapped.append(("data-type", params["mock-data-is-base64"] == "true" ? "base64" : "text"))
            mapped.append(("data", params["data"] ?? ""))
        }
        if let status = params["status-code"] { mapped.append(("status-code", status)) }
        if dataType != "tiny-gif", let contentType = loonContentTypes[dataType] {
            mapped.append(("header", "Content-Type:\(contentType)"))
        }
        addMapLocal(section, line: line, pattern: pattern, params: mapped)
    }

    /// Reads a line of a Quantumult X snippet, which may stand outside
    /// any section; a line of no form it has is left to the caller.
    func readQuantumultX(_ line: String) -> Bool {
        let lower = line.lowercased()
        if RX.matches(#"^hostname\s*="#, lower) {
            readMitm("mitm", line: line)
        } else if RX.matches(qxFilterPattern, lower) {
            readQxFilter(line)
        } else if lower.hasPrefix("event-") || qxCron(line) != nil {
            readQxTask(line)
        } else if RX.matches(qxRewritePattern, line) {
            readQxRewrite(line)
        } else {
            return false
        }
        return true
    }

    func readQxFilter(_ line: String) {
        let section = "filter_local"
        let parts = ruleParts(line)
        guard let type = qxFilterTypes[parts.first?.lowercased() ?? ""], parts.count >= 3 else {
            skip(section, line, .rule)
            return
        }
        readRule(section, line: ([type] + Array(parts.dropFirst())).joined(separator: ","), shown: line)
    }

    /// Reads `pattern url type ...`, where a body or echo rewrite
    /// repeats its type between the two values it takes.
    func readQxRewrite(_ line: String) {
        let section = "rewrite_local"
        if RX.matches(#"\surl-and-header\s"#, line) {
            skip(section, line, .conditional)
            return
        }
        guard let m = RX.match(#"^(\S+)\s+url\s+(\S+)\s*(.*)$"#, line),
              let pattern = m[1], let rawType = m[2] else {
            skip(section, line, .unreadable)
            return
        }
        let type = rawType.lowercased()
        let rest = (m[3] ?? "").trimmingCharacters(in: .whitespaces)
        let repeated = rest.range(of: type).map { rest.distance(from: rest.startIndex, to: $0.lowerBound) } ?? -1
        if let (phase, body) = qxScripts[type] {
            declareScript(phase, line: line)
            var fields: [(String, String)] = [("type", phase), ("pattern", pattern)]
            if body { fields.append(("requires-body", "true")) }
            addScript(section, line: line, name: "", path: rest, fields: fields)
            return
        }
        if rejectRewrites.contains(type) {
            urlRewrite.append("\(field(pattern)) \(type)")
        } else if (type == "302" || type == "307") && !rest.isEmpty && !rest.contains(" ") {
            urlRewrite.append("\(field(pattern)) \(field(rest)) \(type)")
        } else if (type == "request-body" || type == "response-body") && repeated > 0 {
            let phase = type == "request-body" ? "http-request" : "http-response"
            let first = String(rest.prefix(repeated)).trimmingCharacters(in: .whitespaces)
            let second = String(rest.dropFirst(repeated + type.count)).trimmingCharacters(in: .whitespaces)
            bodyRewrite.append([phase, field(pattern), field(first), field(second)].joined(separator: " "))
        } else if type == "request-header" || type == "response-header" {
            skip(section, line, .rawHeader)
        } else if type == "jsonjq-request-body" || type == "jsonjq-response-body" {
            skip(section, line, .jq)
        } else if type == "echo-response" && repeated > 0 {
            let headers = String(rest.prefix(repeated)).trimmingCharacters(in: .whitespaces)
                .components(separatedBy: "\\r\\n")
            var headerValue = "Content-Type:\(headers.first ?? "")"
            for header in headers.dropFirst() {
                if let colon = header.firstIndex(of: ":"), colon != header.startIndex {
                    headerValue += "|\(header[..<colon].trimmingCharacters(in: .whitespaces)):\(header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces))"
                }
            }
            addMapLocal(section, line: line, pattern: pattern, params: [
                ("data-type", "file"),
                ("data", String(rest.dropFirst(repeated + type.count)).trimmingCharacters(in: .whitespaces)),
                ("header", headerValue),
            ])
        } else {
            skip(section, line, .unreadable)
        }
    }

    func readQxTask(_ line: String) {
        let section = "task_local"
        let lower = line.lowercased()
        let cron = qxCron(line)
        let rest: String
        if lower.hasPrefix("event-network") {
            rest = String(line.dropFirst("event-network".count)).trimmingCharacters(in: .whitespaces)
        } else if let cron {
            rest = cron.rest
        } else {
            skip(section, line, lower.hasPrefix("event-") ? .scriptType : .unreadable)
            return
        }
        declareScript(cron != nil ? "cron" : "event", line: line)
        let comma = rest.firstIndex(of: ",")
        let params: [String: String]
        if let comma {
            params = scriptParams(String(rest[rest.index(after: comma)...])) ?? [:]
        } else {
            params = [:]
        }
        if params["enabled"]?.lowercased() == "false" {
            skip(section, line, .disabled)
            return
        }
        var fields: [(String, String)]
        if let cron {
            fields = [("type", "cron"), ("cronexp", cron.expression)]
        } else {
            fields = [("type", "event"), ("event-name", "network-changed")]
        }
        addScript(section, line: line, name: params["tag"] ?? "",
                  path: (comma.map { _ in String(rest[..<comma!]) } ?? rest).trimmingCharacters(in: .whitespaces),
                  fields: fields, after: [("timeout", qxTaskTimeout)])
    }
}

// MARK: - MiniYAML (subset reader for Stash overrides)
//
// Stash overrides are YAML, not sections. This reader covers the
// shapes Stash actually writes — block maps/lists, scalars, flow
// collections, quoted scalars, literal blocks — and fails (nil)
// on anything else instead of guessing. A failed parse means the
// text is not treated as a Stash override at all and falls through
// to the section parser.

private indirect enum MiniYAMLValue {
    case string(String)
    case list([MiniYAMLValue])
    case map([String: MiniYAMLValue])
    case null

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var list: [MiniYAMLValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
    var map: [String: MiniYAMLValue]? {
        if case .map(let m) = self { return m }
        return nil
    }
    /// Display form for skip lines (a string as-is, anything else
    /// JSON-like).
    var display: String {
        switch self {
        case .string(let s): return s
        case .null: return ""
        case .list(let items): return "[" + items.map(\.display).joined(separator: ", ") + "]"
        case .map(let m):
            return "{" + m.map { "\($0.key): \($0.value.display)" }.joined(separator: ", ") + "}"
        }
    }
}

private enum MiniYAML {
    struct Line {
        let indent: Int
        let content: String
    }

    static func parse(_ text: String) -> [String: MiniYAMLValue]? {
        var lines: [Line] = []
        for raw in splitLines(text) {
            var indent = 0
            for c in raw {
                if c == " " { indent += 1 } else { break }
            }
            if indent < raw.count && raw[raw.index(raw.startIndex, offsetBy: indent)] == "\t" {
                return nil
            }
            let content = stripComment(String(raw.dropFirst(indent)))
                .trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            lines.append(Line(indent: indent, content: content))
        }
        guard !lines.isEmpty else { return nil }
        var index = 0
        guard let value = parseBlock(lines, &index, indent: lines[0].indent),
              case .map(let map) = value, index == lines.count else { return nil }
        return map
    }

    /// A `#` preceded by whitespace (or at the start) outside quotes
    /// starts a comment.
    static func stripComment(_ text: String) -> String {
        let chars = Array(text)
        var single = false
        var double = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if single {
                if c == "'" {
                    if i + 1 < chars.count && chars[i + 1] == "'" { i += 1 } else { single = false }
                }
            } else if double {
                if c == "\\" { i += 1 } else if c == "\"" { double = false }
            } else if c == "'" {
                single = true
            } else if c == "\"" {
                double = true
            } else if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
                return String(chars[..<i])
            }
            i += 1
        }
        return text
    }

    /// The key of a `key:` / `key: value` line, or nil.
    static func mapKey(_ content: String) -> (key: String, rest: String)? {
        let chars = Array(content)
        var i = 0
        var inSingle = false
        var inDouble = false
        while i < chars.count {
            let c = chars[i]
            if inSingle {
                if c == "'" { inSingle = false }
            } else if inDouble {
                if c == "\\" { i += 1 } else if c == "\"" { inDouble = false }
            } else if c == "'" {
                inSingle = true
            } else if c == "\"" {
                inDouble = true
            } else if c == ":" && (i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t") {
                let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                return (key: unquote(key), rest: rest)
            }
            i += 1
        }
        return nil
    }

    static func parseBlock(_ lines: [Line], _ index: inout Int, indent: Int) -> MiniYAMLValue? {
        guard index < lines.count, lines[index].indent == indent else { return nil }
        let content = lines[index].content
        if content == "-" || content.hasPrefix("- ") {
            return parseList(lines, &index, indent: indent)
        }
        if mapKey(content) != nil {
            return parseMap(lines, &index, indent: indent)
        }
        index += 1
        return parseScalar(content)
    }

    static func parseMap(_ lines: [Line], _ index: inout Int, indent: Int) -> MiniYAMLValue? {
        var map: [String: MiniYAMLValue] = [:]
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent, let (key, rest) = mapKey(line.content) else { break }
            index += 1
            if rest.isEmpty {
                // Nested block, a block list at the same indent, or an
                // empty value.
                if index < lines.count && lines[index].indent > indent {
                    guard let nested = parseBlock(lines, &index, indent: lines[index].indent) else { return nil }
                    map[key] = nested
                } else if index < lines.count && lines[index].indent == indent
                            && (lines[index].content == "-" || lines[index].content.hasPrefix("- ")) {
                    guard let nested = parseList(lines, &index, indent: indent) else { return nil }
                    map[key] = nested
                } else {
                    map[key] = .null
                }
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                var parts: [String] = []
                while index < lines.count && lines[index].indent > indent {
                    parts.append(String(lines[index].content))
                    index += 1
                }
                map[key] = .string(parts.joined(separator: "\n"))
            } else {
                guard let value = parseInline(rest) else { return nil }
                map[key] = value
            }
        }
        return .map(map)
    }

    static func parseList(_ lines: [Line], _ index: inout Int, indent: Int) -> MiniYAMLValue? {
        var items: [MiniYAMLValue] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content == "-" || line.content.hasPrefix("- ") else { break }
            let remainder = line.content == "-" ? "" : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
            if remainder.isEmpty {
                guard index < lines.count && lines[index].indent > indent,
                      let nested = parseBlock(lines, &index, indent: lines[index].indent) else { return nil }
                items.append(nested)
            } else if mapKey(remainder) != nil {
                // A map starting on the dash line: re-read it (plus the
                // deeper lines that belong to it) as a map at indent+2.
                var sub = [Line(indent: indent + 2, content: remainder)]
                while index < lines.count && lines[index].indent > indent {
                    sub.append(lines[index])
                    index += 1
                }
                var subIndex = 0
                guard let nested = parseMap(sub, &subIndex, indent: indent + 2),
                      subIndex == sub.count else { return nil }
                items.append(nested)
            } else {
                guard let value = parseInline(remainder) else { return nil }
                items.append(value)
            }
        }
        return .list(items)
    }

    /// An inline value: flow collection, quoted scalar, or plain scalar.
    static func parseInline(_ text: String) -> MiniYAMLValue? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .null }
        if text == "null" || text == "~" { return .null }
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .list([]) }
            var items: [MiniYAMLValue] = []
            for part in splitFlow(inner) {
                guard let value = parseInline(part) else { return nil }
                items.append(value)
            }
            return .list(items)
        }
        if text.hasPrefix("{") && text.hasSuffix("}") {
            let inner = String(text.dropFirst().dropLast())
            var map: [String: MiniYAMLValue] = [:]
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .map(map) }
            for part in splitFlow(inner) {
                guard let (key, rest) = mapKey(part), let value = parseInline(rest) else { return nil }
                map[key] = value
            }
            return .map(map)
        }
        return parseScalar(text)
    }

    static func parseScalar(_ text: String) -> MiniYAMLValue {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") {
            var out = ""
            let chars = Array(text.dropFirst().dropLast())
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" && i + 1 < chars.count {
                    switch chars[i + 1] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(chars[i + 1])
                    }
                    i += 2
                } else {
                    out.append(chars[i])
                    i += 1
                }
            }
            return .string(out)
        }
        if text.count >= 2 && text.hasPrefix("'") && text.hasSuffix("'") {
            return .string(String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        return .string(text)
    }

    /// Splits a flow collection on top-level commas.
    static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var single = false
        var double = false
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if single {
                if c == "'" { single = false }
            } else if double {
                if c == "\\" { i = text.index(after: i) } else if c == "\"" { double = false }
            } else if c == "'" {
                single = true
            } else if c == "\"" {
                double = true
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
            } else if c == "," && depth == 0 {
                parts.append(String(text[start..<i]).trimmingCharacters(in: .whitespaces))
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        parts.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
        return parts
    }
}

// MARK: - Stash overrides

private let stashKeys: Set<String> = ["http", "script-providers", "cron", "rules", "tiles"]
private let stashMetaKeys: Set<String> = [
    "name", "desc", "icon", "category", "author", "homepage", "openUrl",
    "manual", "date", "version", "arguments", "arguments-version", "script-providers",
]
private let stashHttpLists: Set<String> = [
    "mitm", "url-rewrite", "rewrite", "header-rewrite", "body-rewrite", "mock", "script",
]
private let stashScriptTypes: [String: String] = [
    "request": "http-request", "response": "http-response",
]
private let stashReferencePattern = #"(\$?)\$\{args\.(\w+)(\|json)?\}"#

extension MitmModuleParserEngine {
    func parseStash(_ override: [String: MiniYAMLValue], text: String) -> MitmModuleContent {
        for key in ["name", "desc"] {
            if let value = override[key] {
                meta[key] = stashText(value)
            }
        }
        readDeclarations(splitLines(text))
        readStashArguments(override["arguments"])
        let providers = override["script-providers"]?.map ?? [:]
        for (key, value) in override {
            if key == "http", let http = value.map {
                readStashHttp(http, providers: providers)
            } else if key == "cron", let cron = value.map {
                for (name, item) in cron {
                    if name == "script", let list = item.list {
                        for entry in list { readStashScript("cron", item: entry, providers: providers) }
                    } else {
                        skip("cron", name, .setting)
                    }
                }
            } else if key == "rules", let list = value.list {
                for rule in list {
                    readRule("rules", line: stashText(rule), shown: stashLine(rule))
                }
            } else if !stashMetaKeys.contains(key) {
                skip(key, key, .section)
            }
        }
        return content()
    }

    func readStashHttp(_ http: [String: MiniYAMLValue], providers: [String: MiniYAMLValue]) {
        for (key, value) in http {
            guard let list = value.list, stashHttpLists.contains(key) else {
                skip("http", key, .setting)
                continue
            }
            for item in list {
                let line = stashText(item)
                switch key {
                case "mitm":
                    var host = line
                    if host.hasSuffix(":*") { host = String(host.dropLast(2)) }
                    if !host.trimmingCharacters(in: .whitespaces).isEmpty {
                        hostname.append(host.trimmingCharacters(in: .whitespaces))
                    }
                case "url-rewrite", "rewrite":
                    readStashUrlRewrite(key, line: line)
                case "header-rewrite":
                    readStashHeaderRewrite(key, line: line)
                case "body-rewrite":
                    readStashBodyRewrite(key, line: line)
                case "mock":
                    readStashMock(key, item: item)
                case "script":
                    readStashScript(key, item: item, providers: providers)
                default:
                    break
                }
            }
        }
    }

    /// Reads `pattern replacement type`, where a rejection names no
    /// replacement or a placeholder.
    func readStashUrlRewrite(_ section: String, line: String) {
        guard let tokens = lineTokens(line), tokens.count >= 2,
              let type = tokens.last?.text.lowercased() else {
            skip(section, line, .unreadable)
            return
        }
        if rejectRewrites.contains(type) {
            urlRewrite.append("\(field(tokens[0].text)) \(type)")
        } else if tokens.count == 3 && ["302", "307", "transparent"].contains(type) {
            urlRewrite.append("\(field(tokens[0].text)) \(field(tokens[1].text)) \(type == "transparent" ? "header" : type)")
        } else {
            skip(section, line, .unreadable)
        }
    }

    func readStashHeaderRewrite(_ section: String, line: String) {
        guard let m = RX.match(#"^(\S+)\s+(request|response)-(add|del|replace|replace-regex)\s+(.+)$"#, line),
              let pattern = m[1], let phase = m[2], let action = m[3], let rest = m[4] else {
            skip(section, line, .unreadable)
            return
        }
        headerRewrite.append("http-\(phase) \(field(pattern)) header-\(action) \(rest)")
    }

    func readStashBodyRewrite(_ section: String, line: String) {
        guard let m = RX.match(#"^(\S+)\s+(request|response)-(\S+)\s+(.+)$"#, line),
              let pattern = m[1], let phase = m[2], let action = m[3], let rest = m[4] else {
            skip(section, line, .unreadable)
            return
        }
        switch action {
        case "replace-regex":
            bodyRewrite.append("http-\(phase) \(field(pattern)) \(rest)")
        case "jq":
            skip(section, line, .jq)
        default:
            skip(section, line, action.hasPrefix("json-") ? .jsonBody : .unreadable)
        }
    }

    /// A mock body of more than one line goes over as base64, as each
    /// line of the core's lists is one entry.
    func readStashMock(_ section: String, item: MiniYAMLValue) {
        let shown = stashLine(item)
        guard let map = item.map, map["match"] != nil else {
            skip(section, shown, .unreadable)
            return
        }
        let text = stashText(map["text"])
        let headers = map["headers"]?.map ?? [:]
        var mapped: [(String, String)] = []
        if let base64 = map["base64"] {
            mapped.append(("data-type", "base64"))
            mapped.append(("data", stashText(base64)))
        } else if text.contains("\r") || text.contains("\n") {
            mapped.append(("data-type", "base64"))
            mapped.append(("data", Data(text.utf8).base64EncodedString()))
        } else {
            mapped.append(("data-type", "text"))
            mapped.append(("data", text))
        }
        if let status = map["status-code"] {
            mapped.append(("status-code", stashText(status)))
        }
        if !headers.isEmpty {
            mapped.append(("header", headers.map { "\($0.key):\(stashText($0.value))" }.joined(separator: "|")))
        }
        addMapLocal(section, line: shown, pattern: stashText(map["match"]), params: mapped)
    }

    /// Reads an http script, or with [section] `cron` a scheduled one,
    /// whose file a script provider of the same name downloads.
    func readStashScript(_ section: String, item: MiniYAMLValue, providers: [String: MiniYAMLValue]) {
        let shown = stashLine(item)
        guard let map = item.map else {
            skip(section, shown, .unreadable)
            return
        }
        func field(_ key: String) -> String? {
            guard let value = map[key] else { return nil }
            let text = stashText(value)
            return text.isEmpty ? nil : text
        }
        let cron = section == "cron"
        let declared = (map["type"]?.string ?? "").lowercased()
        declareScript(cron ? "cron" : stashScriptTypes[declared] ?? declared, line: shown)
        let type: String?
        if cron {
            type = "cron"
        } else {
            type = stashScriptTypes[field("type")?.lowercased() ?? ""]
        }
        guard let type else {
            skip(section, shown, .scriptType)
            return
        }
        let name = field("name") ?? ""
        let provider = providers[name]
        let argument = field("argument")
        var fields: [(String, String)] = [("type", type)]
        if cron {
            if let cronexp = field("cron") { fields.append(("cronexp", cronexp)) }
        } else if let pattern = field("match") {
            fields.append(("pattern", pattern))
        }
        var after: [(String, String)] = []
        for key in ["require-body", "binary-mode", "max-size", "timeout"] {
            if let value = field(key) { after.append((key, value)) }
        }
        if let argument, !argument.isEmpty { after.append(("argument", argument)) }
        let providerURL: String
        if let providerMap = provider?.map, let url = providerMap["url"] {
            providerURL = stashText(url)
        } else {
            providerURL = ""
        }
        addScript(section, line: shown, name: name, path: providerURL,
                  fields: fields, after: after)
    }

    func readStashArguments(_ arguments: MiniYAMLValue?) {
        guard let map = arguments?.map else { return }
        for (name, value) in map {
            guard let value = value.map else { continue }
            let type: MitmModuleArgumentType
            switch value["type"]?.string {
            case "select": type = .select
            case "switch": type = .toggle
            default: type = .input
            }
            var choices: [String] = []
            if let options = value["options"]?.list {
                for option in options {
                    if let map = option.map, let v = map["value"] {
                        choices.append(stashText(v))
                    } else if let s = option.string {
                        choices.append(s)
                    }
                }
            }
            let options = choices
            let defaultValue: String
            if let fallback = value["default"] {
                defaultValue = stashText(fallback)
            } else if type == .toggle {
                defaultValue = "false"
            } else {
                defaultValue = options.first ?? ""
            }
            stashArguments.append(MitmModuleArgument(
                name: name, defaultValue: defaultValue, type: type,
                options: type == .select ? options : [],
                label: value["title"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                description: value["description"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                number: value["value-type"]?.string == "integer"
                    || (!choices.isEmpty && choices.allSatisfy { Int($0) != nil })
            ))
        }
    }

    /// A scalar of the override with its `${args.name}` references
    /// filled in; `|json` writes the value as JSON and `$$` escapes a
    /// reference.
    func stashText(_ value: MiniYAMLValue?) -> String {
        guard let value else { return "" }
        guard let text = value.string else { return value.display }
        if !text.contains("${args.") { return text }
        return RX.replaceMapped(stashReferencePattern, text) { groups in
            let whole = groups[0] ?? ""
            let escaped = groups[1] ?? ""
            let name = groups[2] ?? ""
            let json = groups[3]
            let foundArgument = stashArguments.first { $0.name == name }
            if !escaped.isEmpty || foundArgument == nil {
                return String(whole.dropFirst(escaped.count))
            }
            let argument = foundArgument!
            let value = valueOf(argument)
            if json == nil { return value }
            if argument.type == .toggle { return value == "true" ? "true" : "false" }
            if argument.number, Double(value) != nil { return value }
            if let data = try? JSONEncoder().encode(value),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return quoted(value)
        }
    }

    func stashLine(_ item: MiniYAMLValue) -> String {
        item.display
    }
}

// MARK: - Public entry points

/// The user's own hostnames come first, so an exclusion they wrote
/// holds against any module.
func mergeMitmModules(hostname: [String], modules: [MitmModuleContent]) -> MitmModuleMerged {
    var out = MitmModuleMerged(hostname: hostname)
    for module in modules {
        let lists = module.mitmLists
        out.hostname += lists.hostname
        out.urlRewrite += lists.urlRewrite
        out.headerRewrite += lists.headerRewrite
        out.bodyRewrite += lists.bodyRewrite
        out.mapLocal += lists.mapLocal
        out.script += lists.script
        out.rules += module.rules
    }
    return out
}

enum MitmModuleParser {
    static func parse(text: String, values: [String: String] = [:], resources: [String: String] = [:]) -> MitmModuleContent {
        let engine = MitmModuleParserEngine(values: values, resources: resources)
        if let override = stashOverride(text) {
            return engine.parseStash(override, text: text)
        }
        return engine.parse(text)
    }

    /// Keys at the top of a Stash override that a Surge module or a
    /// Quantumult X snippet read as YAML never has.
    private static func stashOverride(_ text: String) -> [String: MiniYAMLValue]? {
        let lines = splitLines(text)
        if lines.contains(where: { RX.match(sectionPattern, $0.trimmingCharacters(in: .whitespaces)) != nil }) {
            return nil
        }
        guard let document = MiniYAML.parse(text),
              stashKeys.contains(where: { document[$0] != nil }) else { return nil }
        return document
    }
}
