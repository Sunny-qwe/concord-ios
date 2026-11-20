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
//     (MiniYAML, block maps/lists/scalars, flow collections,
//     quoted scalars, literal and folded blocks, anchors and
//     aliases, multi-line flow collections, document markers).
//     Anything it cannot parse falls back to the section parser
//     instead of failing the whole module.
//   - No `mitmAddLine`: the app edits module text wholesale.
//   - No local-file attachments: a map-local `data` that is neither
//     a downloaded URL nor a known resource skips as .relativeData.
//     A bare file name does resolve, by basename, against the
//     resources the module downloaded.
//   - `system` is advisory only: a module naming another system
//     still applies (FlClash only warns too).
//   - dns / rule scripts are not supported by the core itself
//     (parse_script answers "dns scripts are not supported"), and
//     JSON-body rewrites have no core line form (BodyActionDef is
//     Replace or Jq only), so those still skip. Loon
//     `request if … then reject(…)` / `response if …` conditionals
//     ARE read (condition.rs: the condition folds into one URL
//     regex and one lookahead per head; a reject answers with a
//     map-local, or with a url-rewrite reject line for a bare 200);
//     `then script(…)` calls and any other `then` action still skip,
//     as do conditions the core itself refuses. QX
//     `url-and-header` and whole-head `request-header` /
//     `response-header` rewrites do have one (parse_url_rewrite's
//     `head`, `header-text-replace`) and are emitted.
//   - Loon's legacy `pattern replacement 302` (action last) reads
//     like the core's (legacy.rs: three tokens, last one named).
//   - `[General]` reads `force-http-engine-hosts` into
//     forceHttpHostname (core `force_http_hostname`); other keys
//     still skip as settings.

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
    /// Hosts whose servers' certificates go unchecked while the
    /// global skip switch is off (core
    /// `skip-server-cert-verify-hostname`, from the [MITM] section).
    var skipVerifyHostname: [String] = []
    /// The clients decrypted for, in Surge's syntax (core
    /// `client-source-address`, from the [MITM] section); empty
    /// means all of them.
    var clientSourceAddress: [String] = []
    /// Request-body mocks, in map-local line syntax (core
    /// `request-body-mock`, from [Request Body Mock] or Stash
    /// `http.request-body-mock`).
    var requestBodyMock: [String] = []
    /// Surge's `force-http-engine-hosts` ([General] section): plain
    /// HTTP these hosts carry goes through the HTTP engine and their
    /// TLS is not decrypted (core `force_http_hostname`). The core
    /// has no runtime mitm key for it — it is module metadata the
    /// module view reports — so it is carried here for display and
    /// deliberately NOT put into mitmJSON.
    var forceHttpHostname: [String] = []
    var resourceUrls: Set<String> = []
    var skipped: [MitmModuleSkip] = []

    // MARK: - Core report (mitm.readModule, upstream 165154c)
    //
    /// Set by parseWithCore: the core read this module while the VPN
    /// was running. False means the Swift parser alone read it (VPN
    /// off, or the core call failed) — the lists below are the same
    /// either way; only the report fields differ.
    var coreParsed: Bool = false
    /// The format the core read: surge | loon | quantumult-x | stash.
    var coreFormat: String?
    /// Why the module takes no effect as a whole (requirement /
    /// requirementUnreadable); nil when it takes effect.
    var coreOffReason: String?
    /// Whether the module changes things the user did not set for
    /// traffic it does not itself rewrite (DNS, hosts, routes,
    /// verifying servers, the clients decrypted for).
    var coreAsksConsent: Bool = false
    /// Lines the core does not take, as "第 N 行（原因）：文本".
    var coreIgnored: [String] = []
    /// How many lines the core could not read.
    var coreIssueCount: Int = 0

    var isEmpty: Bool {
        hostname.isEmpty && insertedHostname.isEmpty
            && urlRewrite.isEmpty && headerRewrite.isEmpty
            && bodyRewrite.isEmpty && mapLocal.isEmpty && script.isEmpty
            && rules.isEmpty && skipVerifyHostname.isEmpty
            && clientSourceAddress.isEmpty && requestBodyMock.isEmpty
            && forceHttpHostname.isEmpty
            && resourceUrls.isEmpty && skipped.isEmpty
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
            rules: rules,
            skipVerifyHostname: skipVerifyHostname,
            clientSourceAddress: clientSourceAddress,
            requestBodyMock: requestBodyMock,
            forceHttpHostname: forceHttpHostname
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
    var skipVerifyHostname: [String] = []
    var clientSourceAddress: [String] = []
    var requestBodyMock: [String] = []
    /// Surge's `force-http-engine-hosts`, carried for display (see
    /// MitmModuleContent); the core has no mitm wire key for it.
    var forceHttpHostname: [String] = []

    var isEmpty: Bool {
        hostname.isEmpty && urlRewrite.isEmpty && headerRewrite.isEmpty
            && bodyRewrite.isEmpty && mapLocal.isEmpty && script.isEmpty
            && rules.isEmpty && skipVerifyHostname.isEmpty
            && clientSourceAddress.isEmpty && requestBodyMock.isEmpty
            && forceHttpHostname.isEmpty
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
        if !skipVerifyHostname.isEmpty { out["skip-server-cert-verify-hostname"] = skipVerifyHostname }
        if !clientSourceAddress.isEmpty { out["client-source-address"] = clientSourceAddress }
        if !requestBodyMock.isEmpty { out["request-body-mock"] = requestBodyMock }
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
    case "stash" where actionFlat == "install-override",
         "clash" where actionFlat == "install-override":
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
    // Upstream 165154c: URL-REGEX (a regex over the request URL)
    // and USER-AGENT (a *? glob, case-sensitive, over the
    // User-Agent header). Both are undecided before the request is
    // read — they do not match a fresh connection, and NOT around
    // them does not turn them into a match; inside a decrypted
    // session each request is routed on URL + UA after rewrites.
    // The payload passes through as-is when non-empty (the core's
    // module reader does the same); quotes come off first, since a
    // regex or glob may contain commas.
    "URL-REGEX": "URL-REGEX", "USER-AGENT": "USER-AGENT",
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
    // Upstream 165154c: QX user-agent filters are USER-AGENT rules.
    "user-agent": "USER-AGENT",
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
    var skipVerifyHostname: [String] = []
    var clientSourceAddress: [String] = []
    var requestBodyMock: [String] = []
    var forceHttpHostname: [String] = []
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
            skipVerifyHostname: skipVerifyHostname,
            clientSourceAddress: clientSourceAddress,
            requestBodyMock: requestBodyMock,
            forceHttpHostname: forceHttpHostname,
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
            // Surge passes its lines through, jq included: the core
            // reads `http-request-jq` / `http-response-jq` lines
            // (parse_body_rewrite). FlClash does the same.
            bodyRewrite.append(line)
        case "map local":
            readMapLocal(section, line: line)
        case "request body mock":
            // Same line syntax as map-local, but the answer mocks
            // the request body the client sends (core
            // `request-body-mock`, compiled like map-local).
            readMapLocal(section, line: line, intoRequestMock: true)
        case "rewrite":
            readLoonRewrite(section, line: line, raw: raw)
        case "general":
            readGeneral(section, line: line)
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

    /// Reads a `[General]` line. The core reads only
    /// `force-http-engine-hosts` from this section (surge.rs
    /// read_general: `%APPEND%`/`%INSERT%` stripped, comma-separated
    /// host items into `force_http_hostname`); every other key goes
    /// to the network settings, which this parser does not carry, so
    /// it skips as a setting — the core's reason for it.
    func readGeneral(_ section: String, line: String) {
        guard let equals = line.firstIndex(of: "=") else {
            skip(section, line, .unreadable)
            return
        }
        let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard key == "force-http-engine-hosts" else {
            skip(section, line, .setting)
            return
        }
        var hosts = value
        if hosts.hasPrefix("%APPEND%") {
            hosts = String(hosts.dropFirst("%APPEND%".count))
        } else if hosts.hasPrefix("%INSERT%") {
            hosts = String(hosts.dropFirst("%INSERT%".count))
        }
        forceHttpHostname.append(contentsOf: hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
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
    /// A `data` that is not a URL resolves in three ways: the exact
    /// resource URL the module downloaded, the bare file name of a
    /// downloaded resource (`data=a.json` for a `https://…/a.json`
    /// the module fetched), or an already hash-named file. Anything
    /// else still skips as .relativeData: the core can only read a
    /// file that is in its resources directory.
    func resource(_ section: String, line: String, url: String) -> String? {
        if !isMitmResourceUrl(url) {
            if let attachment = resources[url] { return attachment }
            let base = URL(fileURLWithPath: url).lastPathComponent
            if let match = resources.first(where: {
                URL(string: $0.key)?.lastPathComponent == base
            }) {
                return match.value
            }
            if resources.values.contains(url) { return url }
            skip(section, line, .relativeData)
            return nil
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
        let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "skip-server-cert-verify-hostname":
            // Hosts whose servers' certificates go unchecked while
            // the global skip switch is off; the core reads each
            // item as a hostname entry.
            skipVerifyHostname.append(contentsOf: value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        case "client-source-address":
            // The clients decrypted for, in Surge's syntax
            // (IP/CIDR items, `-` excludes); the core judges each
            // item, so they pass through verbatim.
            clientSourceAddress.append(contentsOf: value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        case "hostname":
            readMitmHostname(section, line: line, value: value)
        default:
            skip(section, line, .setting)
        }
    }

    private func readMitmHostname(_ section: String, line: String, value: String) {
        var value = value
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
        guard parts.first != nil else { return }
        let policy = parts.count > 2 ? parts[2].uppercased() : nil
        // NOTE (upstream 165154c): URL-REGEX used to map to a
        // url-rewrite reject here (FlClash-era, from before the core
        // had URL-REGEX rules). The core now keeps it as a profile
        // rule with any policy, so this parser does the same — the
        // two parsers agree line for line. A URL-REGEX rule only
        // matches inside a decrypted session (or plain HTTP), which
        // is where the module's MITM hostnames put the traffic.
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
        case "URL-REGEX", "USER-AGENT":
            // Upstream 165154c: the payload passes through as-is
            // when non-empty (quotes already off — a regex or glob
            // may contain commas, which splitRule keeps together
            // inside quotes).
            guard !value.isEmpty else { return nil }
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

    func readMapLocal(_ section: String, line: String, intoRequestMock: Bool = false) {
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
        addMapLocal(section, line: line, pattern: tokens[0].text, params: params, intoRequestMock: intoRequestMock)
    }

    func addMapLocal(_ section: String, line: String, pattern: String, params: [(String, String)], intoRequestMock: Bool = false, requestHead: String? = nil) {
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
        // A condition's request head rides as a bare `request-head`
        // field between the pattern and the key=value params
        // (parse_map_local reads HeadConditionsDef first).
        var fields = [field(pattern)]
        if let head = requestHead {
            fields.append("request-head")
            fields.append(field(head))
        }
        let rendered = (fields + params.map { "\($0.0)=\(quoted($0.1))" }).joined(separator: " ")
        if intoRequestMock {
            requestBodyMock.append(rendered)
        } else {
            mapLocal.append(rendered)
        }
    }

    /// Loon's legacy `pattern action ...`, which spreads over Surge's lists.
    /// `raw` is the line before argument substitution: a conditional
    /// reads its `${…}` variables itself (an argument test is decided
    /// from the argument's value, as the core does), so it must see
    /// them unsubstituted.
    func readLoonRewrite(_ section: String, line: String, raw: String) {
        if RX.matches(conditionalPattern, line) {
            readLoonConditional(section, line: line, raw: raw)
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
        // The action last (`pattern replacement 302`, legacy.rs:
        // three tokens, the last one named) — the two Bilibili
        // international region lines in AllInOne read this way.
        if tokens.count == 3, ["302", "307", "header"].contains(tokens[2].text.lowercased()) {
            urlRewrite.append("\(pattern) \(field(tokens[1].text)) \(tokens[2].text.lowercased())")
            return
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

    // MARK: - Loon conditionals (`request if … then …`, core condition.rs + action.rs)
    //
    // A Loon new-syntax rewrite line, read the way the core reads it
    // (loon/mod.rs read_new): the condition (any/all/test over
    // ${url}, ${request.method}, ${response.status} and
    // ${….header['Name']}, with == / ~=, && / || and parentheses; a
    // test on a plugin argument is decided now from the argument's
    // value) folds into one URL regex and one lookahead per head
    // (condition.rs translate/test_piece). `then reject(N)` answers
    // with a map-local (action.rs reject: a bare 200 with no body
    // answers with a url-rewrite reject line instead); any other
    // `then` action — url.replace, redirect, header/body edits,
    // mocks, `then script(…)` — still skips as .conditional.
    // A line whose arguments rule it out takes no effect at all
    // (no output, no skip), as the core's Ok(None).

    private enum LoonTemplatePart: Equatable {
        case text(String)
        case variable(String)
    }

    private enum LoonCondToken: Equatable {
        case word(String)
        case variable(String)
        case template([LoonTemplatePart])
        case raw(String)
        case regex(source: String, flags: String)
        case number(String)
        case symbol(String)
        case object([String])
    }

    /// The core's condition lexer (loon/lexer.rs): `${…}` variables,
    /// double-quoted templates (escapes read, `${…}` filled),
    /// backquoted raw strings, `/regex/flags` (a slash inside a
    /// class or after a backslash is the regex's own), numbers,
    /// words (letters, digits, `_`, `.`, `-`) and the symbols
    /// == ~= && || ( ) , [ ] | =.
    private struct LoonCondLexer {
        private let chars: [Character]
        private var at = 0

        init(_ text: String) { chars = Array(text) }

        private func peek(_ offset: Int = 0) -> Character? {
            let i = at + offset
            return i < chars.count ? chars[i] : nil
        }

        private func startsWith(_ s: String) -> Bool {
            let cs = Array(s)
            guard at + cs.count <= chars.count else { return false }
            for (i, c) in cs.enumerated() where chars[at + i] != c { return false }
            return true
        }

        private func isAsciiDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        private func isAsciiAlpha(_ c: Character) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
        }

        mutating func lex() -> [LoonCondToken]? {
            var tokens: [LoonCondToken] = []
            while let c = peek() {
                if c == " " || c == "\t" { at += 1; continue }
                guard let token = next(c) else { return nil }
                tokens.append(token)
            }
            return tokens
        }

        private mutating func next(_ c: Character) -> LoonCondToken? {
            if startsWith("${") { return variable().map { .variable($0) } }
            switch c {
            case "\"": return template()
            case "`": return rawString()
            case "/": return regex()
            case "{": return object()
            case _ where c == "-" || isAsciiDigit(c): return number()
            case _ where isAsciiAlpha(c) || c == "_": return .word(word())
            default:
                for symbol in ["==", "~=", "&&", "||", "(", ")", ",", "[", "]", "|", "="] {
                    if startsWith(symbol) { at += symbol.count; return .symbol(symbol) }
                }
                return nil
            }
        }

        private mutating func variable() -> String? {
            var i = at + 2
            while i < chars.count && chars[i] != "}" { i += 1 }
            guard i < chars.count else { return nil }
            let name = String(chars[(at + 2)..<i]).trimmingCharacters(in: .whitespaces)
            at = i + 1
            return name.isEmpty ? nil : name
        }

        private mutating func template() -> LoonCondToken? {
            at += 1
            var parts: [LoonTemplatePart] = []
            var text = ""
            var closed = false
            while let c = peek() {
                if c == "\"" { at += 1; closed = true; break }
                if startsWith("${") {
                    if !text.isEmpty { parts.append(.text(text)); text = "" }
                    guard let name = variable() else { return nil }
                    parts.append(.variable(name))
                    continue
                }
                if c == "\\" {
                    if startsWith("\\${") { text += "${"; at += 3; continue }
                    guard let e = peek(1) else { return nil }
                    switch e {
                    case "n": text += "\n"
                    case "r": text += "\r"
                    case "t": text += "\t"
                    default: text.append(e)
                    }
                    at += 2
                    continue
                }
                text.append(c)
                at += 1
            }
            guard closed else { return nil }
            if !text.isEmpty || parts.isEmpty { parts.append(.text(text)) }
            return .template(parts)
        }

        private mutating func rawString() -> LoonCondToken? {
            at += 1
            var text = ""
            while let c = peek() {
                if startsWith("``") { text += "`"; at += 2; continue }
                at += 1
                if c == "`" { return .raw(text) }
                text.append(c)
            }
            return nil
        }

        private mutating func regex() -> LoonCondToken? {
            var i = at + 1
            var inClass = false
            var escaped = false
            var end: Int?
            while i < chars.count {
                let c = chars[i]
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "[" { inClass = true }
                else if c == "]" { inClass = false }
                else if c == "/" && !inClass { end = i; break }
                i += 1
            }
            guard let end else { return nil }
            let source = String(chars[(at + 1)..<end])
            var j = end + 1
            var flags = ""
            while j < chars.count && (chars[j] == "i" || chars[j] == "m" || chars[j] == "s") {
                flags.append(chars[j]); j += 1
            }
            at = j
            return .regex(source: source, flags: flags)
        }

        private mutating func object() -> LoonCondToken? {
            at += 1
            var names: [String] = []
            while true {
                skipSpaces()
                guard startsWith("${") else { return nil }
                guard let name = variable() else { return nil }
                names.append(name)
                skipSpaces()
                if peek() == "," { at += 1; continue }
                if peek() == "}" { at += 1; return .object(names) }
                return nil
            }
        }

        private mutating func skipSpaces() {
            while peek() == " " || peek() == "\t" { at += 1 }
        }

        private mutating func number() -> LoonCondToken? {
            let start = at
            var i = at
            while i < chars.count {
                let c = chars[i]
                let rel = i - start
                if isAsciiDigit(c) || c == "." || c == "e" || c == "E" || c == "+" {
                    i += 1; continue
                }
                if c == "-" && (rel == 0 || (i > start && (chars[i - 1] == "e" || chars[i - 1] == "E"))) {
                    i += 1; continue
                }
                break
            }
            let text = String(chars[start..<i])
            guard Double(text) != nil else { return nil }
            at = i
            return .number(text)
        }

        private mutating func word() -> String {
            let start = at
            while let c = peek(),
                  isAsciiAlpha(c) || isAsciiDigit(c) || c == "_" || c == "." || c == "-" {
                at += 1
            }
            return String(chars[start..<at])
        }
    }

    private struct LoonCondCursor {
        var tokens: [LoonCondToken]
        var at = 0

        func peek() -> LoonCondToken? { at < tokens.count ? tokens[at] : nil }

        mutating func next() -> LoonCondToken? {
            guard at < tokens.count else { return nil }
            defer { at += 1 }
            return tokens[at]
        }

        mutating func symbol(_ s: String) -> Bool {
            if peek() == .symbol(s) { at += 1; return true }
            return false
        }

        mutating func word(_ w: String) -> Bool {
            if peek() == .word(w) { at += 1; return true }
            return false
        }
    }

    private indirect enum LoonCond {
        case any([LoonCond])
        case all([LoonCond])
        case test(LoonCondTest)
        case known(Bool)
    }

    private struct LoonCondTest {
        enum Subject {
            case url
            case method
            case status
            case header(response: Bool, name: String)
        }
        enum Check {
            case equals(String?)
            case finds(String)
        }
        var subject: Subject
        var check: Check
        var capture: String?
    }

    /// What a condition matches: a regex over the URL, and over
    /// each head a regex of lookaheads (condition.rs Match).
    private struct LoonMatch {
        var url: String
        var request: String?
        var response: String?
    }

    private enum LoonPiece {
        case url(regex: String, plain: Bool)
        case head(response: Bool, lookahead: String)
    }

    func readLoonConditional(_ section: String, line: String, raw: String) {
        var lexer = LoonCondLexer(raw)
        guard let tokens = lexer.lex() else {
            skip(section, line, .conditional)
            return
        }
        var cursor = LoonCondCursor(tokens: tokens)
        let response: Bool
        if cursor.word("request") { response = false }
        else if cursor.word("response") { response = true }
        else { skip(section, line, .conditional); return }
        guard cursor.word("if") else { skip(section, line, .conditional); return }
        guard let tree = loonParseAny(&cursor, response: response) else {
            skip(section, line, .conditional)
            return
        }
        let matched: LoonMatch
        switch loonFold(tree) {
        case .known(false):
            return // the arguments rule the line out: no effect, no skip
        case .known(true):
            matched = LoonMatch(url: "^", request: nil, response: nil)
        case let folded:
            guard let translated = loonTranslate(folded) else {
                skip(section, line, .conditional)
                return
            }
            matched = translated
        }
        guard cursor.word("then") else { skip(section, line, .conditional); return }
        if !loonEmitConditionalActions(&cursor, section: section, line: line, matched: matched) {
            skip(section, line, .conditional)
        }
    }

    private func loonParseAny(_ cursor: inout LoonCondCursor, response: Bool) -> LoonCond? {
        guard let first = loonParseAll(&cursor, response: response) else { return nil }
        var branches = [first]
        while cursor.symbol("||") {
            guard let next = loonParseAll(&cursor, response: response) else { return nil }
            branches.append(next)
        }
        return branches.count == 1 ? branches[0] : .any(branches)
    }

    private func loonParseAll(_ cursor: inout LoonCondCursor, response: Bool) -> LoonCond? {
        var items: [LoonCond] = []
        while true {
            if cursor.symbol("(") {
                guard let inner = loonParseAny(&cursor, response: response) else { return nil }
                guard cursor.symbol(")") else { return nil }
                items.append(inner)
            } else {
                guard let test = loonParseTest(&cursor, response: response) else { return nil }
                items.append(test)
            }
            if !cursor.symbol("&&") { break }
        }
        return items.count == 1 ? items[0] : .all(items)
    }

    private func loonParseTest(_ cursor: inout LoonCondCursor, response: Bool) -> LoonCond? {
        guard case .variable(let name)? = cursor.next() else { return nil }
        let op: String
        if cursor.symbol("==") { op = "==" }
        else if cursor.symbol("~=") { op = "~=" }
        else { return nil }
        guard let value = cursor.next() else { return nil }
        var capture: String?
        if cursor.word("as") {
            guard op == "~=" else { return nil }
            guard case .word(let captureName)? = cursor.next() else { return nil }
            capture = captureName
        }
        let subject: LoonCondTest.Subject
        switch name {
        case "url": subject = .url
        case "request.method": subject = .method
        case "response.status": subject = .status
        default:
            if let header = loonHeaderVariable(name) {
                subject = .header(response: header.response, name: header.name)
            } else {
                // A test on a plugin argument, decided now.
                return loonArgumentTest(name: name, op: op, value: value).map { .known($0) }
            }
        }
        let onResponse: Bool
        switch subject {
        case .status: onResponse = true
        case .header(let isResponse, _): onResponse = isResponse
        default: onResponse = false
        }
        if onResponse && !response { return nil }
        let check: LoonCondTest.Check
        if op == "~=" {
            guard let regex = loonRegexValue(value) else { return nil }
            check = .finds(regex)
        } else {
            switch (subject, value) {
            case (.status, .number(let status)):
                check = .equals(status)
            case (.header, .word("null")):
                check = .equals(nil)
            case (.status, _):
                return nil
            default:
                guard let string = loonStringValue(value) else { return nil }
                check = .equals(string)
            }
        }
        return .test(LoonCondTest(subject: subject, check: check, capture: capture))
    }

    private func loonHeaderVariable(_ name: String) -> (response: Bool, name: String)? {
        guard let range = name.range(of: ".header[") else { return nil }
        let side = String(name[..<range.lowerBound])
        var rest = String(name[range.upperBound...])
        guard rest.hasSuffix("]") else { return nil }
        rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        switch side {
        case "request": return (false, rest)
        case "response": return (true, rest)
        default: return nil
        }
    }

    private func loonDeclaredArgument(_ name: String) -> MitmModuleArgument? {
        (surgeArguments + loonArguments + stashArguments).first { $0.name == name }
    }

    /// A test on a plugin argument, decided now as the argument's
    /// value is known (condition.rs argument_test).
    private func loonArgumentTest(name: String, op: String, value: LoonCondToken) -> Bool? {
        guard let argument = loonDeclaredArgument(name) else { return nil }
        let actual = valueOf(argument)
        if op == "~=" {
            guard let source = loonRegexValue(value) else { return nil }
            guard let re = try? NSRegularExpression(pattern: source) else { return nil }
            let range = NSRange(actual.startIndex..., in: actual)
            return re.firstMatch(in: actual, range: range) != nil
        }
        switch value {
        case .number(let text):
            if let a = Double(actual), let b = Double(text) { return a == b }
            return actual == text
        case .word("true"): return actual == "true"
        case .word("false"): return actual == "false"
        case .word("null"): return false
        case .word: return nil
        default:
            guard let expected = loonStringValue(value) else { return nil }
            return actual == expected
        }
    }

    /// The right of `~=`: a regex as written, or a string argument holding one.
    private func loonRegexValue(_ token: LoonCondToken) -> String? {
        switch token {
        case .regex(let source, let flags):
            return loonScoped(source, flags: flags)
        case .variable(let name):
            guard let argument = loonDeclaredArgument(name) else { return nil }
            return valueOf(argument)
        default:
            return nil
        }
    }

    private func loonStringValue(_ token: LoonCondToken) -> String? {
        switch token {
        case .template(let parts):
            var out = ""
            for part in parts {
                switch part {
                case .text(let text): out += text
                case .variable(let name):
                    guard let filled = loonFillVariable(name) else { return nil }
                    out += filled
                }
            }
            return out
        case .raw(let text):
            return text
        case .variable(let name):
            guard let argument = loonDeclaredArgument(name) else { return nil }
            return valueOf(argument)
        default:
            return nil
        }
    }

    private func loonFillVariable(_ name: String) -> String? {
        if name == "url" || name.hasPrefix("request.") || name.hasPrefix("response.") {
            return nil
        }
        guard let argument = loonDeclaredArgument(name) else { return nil }
        return valueOf(argument)
    }

    private func loonScoped(_ source: String, flags: String) -> String {
        flags.isEmpty ? source : "(?\(flags):\(source))"
    }

    private func loonRegexEscape(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }

    /// `regex` with its `^` and `$` outside classes standing for the
    /// start and end of the value it is found in (condition.rs
    /// anchored).
    private func loonAnchored(_ regex: String, start: String, end: String) -> String {
        var out = ""
        var inClass = false
        let chars = Array(regex)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                out.append(c)
                if i + 1 < chars.count { out.append(chars[i + 1]); i += 1 }
            } else if c == "[" && !inClass {
                inClass = true; out.append(c)
            } else if c == "]" && inClass {
                inClass = false; out.append(c)
            } else if c == "^" && !inClass {
                out += start
            } else if c == "$" && !inClass {
                out += end
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    private func loonFold(_ cond: LoonCond) -> LoonCond {
        switch cond {
        case .all(let items):
            var kept: [LoonCond] = []
            for item in items.map(loonFold) {
                if case .known(let value) = item {
                    if !value { return .known(false) }
                } else {
                    kept.append(item)
                }
            }
            if kept.isEmpty { return .known(true) }
            if kept.count == 1 { return kept[0] }
            return .all(kept)
        case .any(let branches):
            var kept: [LoonCond] = []
            for branch in branches.map(loonFold) {
                if case .known(let value) = branch {
                    if value { return .known(true) }
                } else {
                    kept.append(branch)
                }
            }
            if kept.isEmpty { return .known(false) }
            if kept.count == 1 { return kept[0] }
            return .any(kept)
        default:
            return cond
        }
    }

    private func loonTranslate(_ tree: LoonCond) -> LoonMatch? {
        let items: [LoonCond]
        if case .all(let all) = tree { items = all } else { items = [tree] }
        var urls: [String] = []
        var plainUrls = 0
        var request: [String] = []
        var response: [String] = []
        var captures: [String] = []
        for item in items {
            if case .test(let test) = item, let capture = test.capture {
                // Captures only feed a url.replace replacement, which
                // this reader does not emit, so the name is only
                // checked (a declared argument, or a repeat, is an
                // error in the core) and never used.
                if loonDeclaredArgument(capture) != nil || captures.contains(capture) {
                    return nil
                }
                captures.append(capture)
            }
            guard let piece = loonPiece(item) else { return nil }
            switch piece {
            case .url(let regex, let plain):
                plainUrls += plain ? 1 : 0
                urls.append(regex)
            case .head(let isResponse, let lookahead):
                if isResponse { response.append(lookahead) } else { request.append(lookahead) }
            }
        }
        let head = { (lookaheads: [String]) -> String? in
            lookaheads.isEmpty ? nil : "^" + lookaheads.joined()
        }
        let url: String
        switch urls.count {
        case 0: url = "^"
        case 1: url = urls[0]
        default: url = loonAllOf(urls)
        }
        return LoonMatch(url: url, request: head(request), response: head(response))
    }

    private func loonAllOf(_ regexes: [String]) -> String {
        "^" + regexes.map { "(?=[\\s\\S]*?(?:\($0)))" }.joined()
    }

    private func loonPiece(_ cond: LoonCond) -> LoonPiece? {
        switch cond {
        case .test(let test):
            return loonTestPiece(test)
        case .all(let items):
            var pieces: [LoonPiece] = []
            for item in items {
                guard let piece = loonPiece(item) else { return nil }
                pieces.append(piece)
            }
            return loonJoin(pieces, any: false)
        case .any(let branches):
            var pieces: [LoonPiece] = []
            for branch in branches {
                guard let piece = loonPiece(branch) else { return nil }
                pieces.append(piece)
            }
            return loonJoin(pieces, any: true)
        case .known:
            return nil
        }
    }

    /// Pieces that must all pass, or with `any` that one must, as
    /// one: the core tests the URL and each head apart, so the
    /// pieces must all be on one of them (condition.rs join).
    private func loonJoin(_ pieces: [LoonPiece], any: Bool) -> LoonPiece? {
        if pieces.allSatisfy({ if case .url = $0 { return true }; return false }) {
            let regexes = pieces.compactMap { piece -> String? in
                if case .url(let regex, _) = piece { return regex }
                return nil
            }
            if any {
                return .url(regex: regexes.map { "(?:\($0))" }.joined(separator: "|"), plain: false)
            }
            return .url(regex: loonAllOf(regexes), plain: false)
        }
        var side: Bool?
        var lookaheads: [String] = []
        for piece in pieces {
            guard case .head(let response, let lookahead) = piece else { return nil }
            if let side, side != response { return nil }
            side = response
            lookaheads.append(lookahead)
        }
        let lookahead = any ? "(?:\(lookaheads.joined(separator: "|")))" : lookaheads.joined()
        return .head(response: side ?? false, lookahead: lookahead)
    }

    private func loonTestPiece(_ test: LoonCondTest) -> LoonPiece {
        switch test.subject {
        case .url:
            switch test.check {
            case .equals(let value):
                return .url(regex: "^\(loonRegexEscape(value ?? ""))$", plain: true)
            case .finds(let regex):
                return .url(regex: regex, plain: true)
            }
        case .method:
            switch test.check {
            case .equals(let value):
                return .head(response: false, lookahead: "(?=\(loonRegexEscape(value ?? "")) )")
            case .finds(let regex):
                return .head(response: false, lookahead: "(?=[^ ]*?(?:\(loonAnchored(regex, start: "^", end: "(?= )")))[^ ]* )")
            }
        case .status:
            switch test.check {
            case .equals(let value):
                return .head(response: true, lookahead: "(?=\\S+ \(loonRegexEscape(value ?? ""))(?: |\\r\\n))")
            case .finds(let regex):
                return .head(response: true, lookahead: "(?=\\S+ \\d*?(?:\(loonAnchored(regex, start: "(?<= )", end: "(?=[ \\r])")))\\d*(?: |\\r\\n))")
            }
        case .header(let response, let name):
            let namePattern = "(?i:\(loonRegexEscape(name)))"
            switch test.check {
            case .equals(nil):
                return .head(response: response, lookahead: "(?![\\s\\S]*\\r\\n\(namePattern):)")
            case .equals(let value):
                return .head(response: response, lookahead: "(?=[\\s\\S]*\\r\\n\(namePattern): \(loonRegexEscape(value ?? ""))\\r\\n)")
            case .finds(let regex):
                return .head(response: response, lookahead: "(?=[\\s\\S]*\\r\\n\(namePattern): [^\\r\\n]*?(?:\(loonAnchored(regex, start: "(?<=\\n\(namePattern): )", end: "(?=\\r\\n)")))[^\\r\\n]*\\r\\n)")
            }
        }
    }

    /// The `then …` actions, `|`-separated; only the reject family
    /// has a line form here. False means the line does not read.
    private func loonEmitConditionalActions(_ cursor: inout LoonCondCursor, section: String, line: String, matched: LoonMatch) -> Bool {
        while true {
            guard case .word(let name)? = cursor.next() else { return false }
            guard cursor.symbol("(") else { return false }
            var status: String?
            var body: String?
            if !cursor.symbol(")") {
                guard case .number(let number)? = cursor.next() else { return false }
                status = number
                if cursor.symbol(",") {
                    guard let bodyToken = cursor.next() else { return false }
                    guard let string = loonStringValue(bodyToken) else { return false }
                    body = string
                }
                guard cursor.symbol(")") else { return false }
            }
            guard let status,
                  loonEmitConditionalReject(name: name, status: status, body: body, section: section, line: line, matched: matched) else {
                return false
            }
            if cursor.symbol("|") { continue }
            return cursor.at == cursor.tokens.count
        }
    }

    /// One `then reject(…)` action (action.rs reject): a bare 200
    /// with no body answers with a url-rewrite reject line; anything
    /// else answers with a map-local. A response-side condition
    /// cannot answer here — the action runs before the response it
    /// tests — so such a line does not read.
    private func loonEmitConditionalReject(name: String, status: String, body: String?, section: String, line: String, matched: LoonMatch) -> Bool {
        if matched.response != nil { return false }
        guard let code = UInt16(status), (100...599).contains(code) else { return false }
        if code < 200 { return false }
        let quick: String?
        switch name {
        case "reject": quick = "reject-200"
        case "reject_img": quick = "reject-img"
        case "reject_dict": quick = "reject-dict"
        case "reject_array": quick = "reject-array"
        case "reject_video": quick = nil
        default: return false
        }
        if code == 200, body == nil, let quick {
            // The request-head condition, if any, rides as
            // `url-and-header` (parse_url_rewrite).
            if let head = matched.request {
                urlRewrite.append("\(field(matched.url)) \(field(head)) url-and-header \(quick)")
            } else {
                urlRewrite.append("\(field(matched.url)) \(quick)")
            }
            return true
        }
        let (dataType, data, contentType): (String, String, String)
        switch name {
        case "reject_img":
            (dataType, data, contentType) = ("tiny-gif", "", "image/gif")
        case "reject_dict":
            (dataType, data, contentType) = ("json", "{}", "application/json")
        case "reject_array":
            (dataType, data, contentType) = ("json", "[]", "application/json")
        case "reject_video":
            (dataType, data, contentType) = ("text", "", "video/mp4")
        default:
            (dataType, data, contentType) = ("text", body ?? "", "text/plain; charset=utf-8")
        }
        addMapLocal(
            section, line: line, pattern: matched.url,
            params: [
                ("data-type", dataType),
                ("data", data),
                ("status-code", "\(code)"),
                ("header", "Content-Type:\(contentType)"),
            ],
            requestHead: matched.request
        )
        return true
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
            // A URL rewrite conditioned on the request head: the
            // core reads it verbatim (`pattern head url-and-header
            // action`, parse_url_rewrite), so it is emitted as-is
            // rather than skipped as a conditional.
            urlRewrite.append(line)
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
        } else if (type == "request-header" || type == "response-header") && repeated > 0 {
            // A replacement over the whole head, its first line
            // included: the core reads it as `header-text-replace`
            // (HeaderEditDef::Text). The two values repeat the type
            // between them, as a body rewrite does; anything else
            // keeps the rawHeader skip.
            let phase = type == "request-header" ? "http-request" : "http-response"
            let first = String(rest.prefix(repeated)).trimmingCharacters(in: .whitespaces)
            let second = String(rest.dropFirst(repeated + type.count)).trimmingCharacters(in: .whitespaces)
            headerRewrite.append([phase, field(pattern), "header-text-replace", field(first), field(second)].joined(separator: " "))
        } else if type == "request-header" || type == "response-header" {
            skip(section, line, .rawHeader)
        } else if type == "jsonjq-request-body" || type == "jsonjq-response-body" {
            // The core reads jq rewrites (parse_body_rewrite);
            // FlClash emits the same form.
            let phase = type == "jsonjq-request-body" ? "http-request" : "http-response"
            bodyRewrite.append("\(phase)-jq \(field(pattern)) \(rest)")
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
        let rawLines = splitLines(text)
        var lines: [Line] = []
        var anchors: [String: MiniYAMLValue] = [:]
        var i = 0
        while i < rawLines.count {
            let raw = rawLines[i]
            i += 1
            var indent = 0
            for c in raw {
                if c == " " { indent += 1 } else { break }
            }
            if indent < raw.count && raw[raw.index(raw.startIndex, offsetBy: indent)] == "\t" {
                return nil
            }
            var content = stripComment(String(raw.dropFirst(indent)))
                .trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            // A document marker: Stash overrides sometimes open with it.
            if content == "---" || content == "..." { continue }
            // A flow collection split over lines: join until its
            // brackets balance, so the value parses as one.
            while flowDepth(content) > 0 && i < rawLines.count {
                let next = stripComment(rawLines[i]).trimmingCharacters(in: .whitespaces)
                i += 1
                if next.isEmpty { continue }
                content += " " + next
            }
            if flowDepth(content) > 0 { return nil }
            lines.append(Line(indent: indent, content: content))
        }
        guard !lines.isEmpty else { return nil }
        var index = 0
        guard let value = parseBlock(lines, &index, indent: lines[0].indent, anchors: &anchors),
              case .map(let map) = value, index == lines.count else { return nil }
        return map
    }

    /// Open brackets minus closed ones, outside quotes: > 0 while
    /// a flow collection runs over several lines.
    static func flowDepth(_ text: String) -> Int {
        let chars = Array(text)
        var depth = 0
        var single = false
        var double = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if single {
                if c == "'" { single = false }
            } else if double {
                if c == "\\" { i += 1 } else if c == "\"" { double = false }
            } else if c == "'" {
                single = true
            } else if c == "\"" {
                double = true
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
            }
            i += 1
        }
        return depth
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

    static func parseBlock(_ lines: [Line], _ index: inout Int, indent: Int, anchors: inout [String: MiniYAMLValue]) -> MiniYAMLValue? {
        guard index < lines.count, lines[index].indent == indent else { return nil }
        let content = lines[index].content
        if content == "-" || content.hasPrefix("- ") {
            return parseList(lines, &index, indent: indent, anchors: &anchors)
        }
        if mapKey(content) != nil {
            return parseMap(lines, &index, indent: indent, anchors: &anchors)
        }
        index += 1
        return parseInline(content, anchors: &anchors)
    }

    static func parseMap(_ lines: [Line], _ index: inout Int, indent: Int, anchors: inout [String: MiniYAMLValue]) -> MiniYAMLValue? {
        var map: [String: MiniYAMLValue] = [:]
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent, let (key, restText) = mapKey(line.content) else { break }
            index += 1
            // An anchor on the value (`key: &name value`, or `key:
            // &name` over a nested block): peel it, store the value
            // under it once it is read.
            var rest = restText
            var anchor: String?
            if rest.hasPrefix("&") {
                let after = String(rest.dropFirst())
                if let space = after.firstIndex(of: " ") {
                    anchor = String(after[..<space])
                    rest = String(after[after.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    anchor = after
                    rest = ""
                }
            }
            let value: MiniYAMLValue
            if rest.isEmpty {
                // Nested block, a block list at the same indent, or an
                // empty value.
                if index < lines.count && lines[index].indent > indent {
                    guard let nested = parseBlock(lines, &index, indent: lines[index].indent, anchors: &anchors) else { return nil }
                    value = nested
                } else if index < lines.count && lines[index].indent == indent
                            && (lines[index].content == "-" || lines[index].content.hasPrefix("- ")) {
                    guard let nested = parseList(lines, &index, indent: indent, anchors: &anchors) else { return nil }
                    value = nested
                } else {
                    value = .null
                }
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                // A literal block keeps its line breaks; a folded
                // block folds them to spaces. `+` keeps a trailing
                // break, `-` (and the default here) drops it.
                let folded = rest.hasPrefix(">")
                let keepBreak = rest.contains("+")
                var parts: [String] = []
                while index < lines.count && lines[index].indent > indent {
                    parts.append(String(lines[index].content))
                    index += 1
                }
                var joined = parts.joined(separator: folded ? " " : "\n")
                if keepBreak && !joined.isEmpty { joined += "\n" }
                value = .string(joined)
            } else {
                guard let parsed = parseInline(rest, anchors: &anchors) else { return nil }
                value = parsed
            }
            if let anchor { anchors[anchor] = value }
            map[key] = value
        }
        return .map(map)
    }

    static func parseList(_ lines: [Line], _ index: inout Int, indent: Int, anchors: inout [String: MiniYAMLValue]) -> MiniYAMLValue? {
        var items: [MiniYAMLValue] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content == "-" || line.content.hasPrefix("- ") else { break }
            let remainder = line.content == "-" ? "" : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
            if remainder.isEmpty {
                guard index < lines.count && lines[index].indent > indent,
                      let nested = parseBlock(lines, &index, indent: lines[index].indent, anchors: &anchors) else { return nil }
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
                guard let nested = parseMap(sub, &subIndex, indent: indent + 2, anchors: &anchors),
                      subIndex == sub.count else { return nil }
                items.append(nested)
            } else {
                guard let value = parseInline(remainder, anchors: &anchors) else { return nil }
                items.append(value)
            }
        }
        return .list(items)
    }

    /// An inline value: flow collection, quoted scalar, or plain scalar.
    static func parseInline(_ text: String, anchors: inout [String: MiniYAMLValue]) -> MiniYAMLValue? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .null }
        if text == "null" || text == "~" { return .null }
        if text.hasPrefix("*") {
            // An alias: the anchored value, or nothing when the
            // anchor was never defined.
            return anchors[String(text.dropFirst())]
        }
        if text.hasPrefix("&") {
            // An anchor on an inline value: store the value and
            // return it without the anchor.
            let after = String(text.dropFirst())
            guard let space = after.firstIndex(of: " ") else { return nil }
            let name = String(after[..<space])
            guard let value = parseInline(String(after[after.index(after: space)...]), anchors: &anchors) else { return nil }
            anchors[name] = value
            return value
        }
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .list([]) }
            var items: [MiniYAMLValue] = []
            for part in splitFlow(inner) {
                guard let value = parseInline(part, anchors: &anchors) else { return nil }
                items.append(value)
            }
            return .list(items)
        }
        if text.hasPrefix("{") && text.hasSuffix("}") {
            let inner = String(text.dropFirst().dropLast())
            var map: [String: MiniYAMLValue] = [:]
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .map(map) }
            for part in splitFlow(inner) {
                guard let (key, rest) = mapKey(part), let value = parseInline(rest, anchors: &anchors) else { return nil }
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
    "mitm", "url-rewrite", "rewrite", "header-rewrite", "body-rewrite", "mock", "request-body-mock", "script",
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
                case "request-body-mock":
                    readStashMock(key, item: item, intoRequestMock: true)
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
            // The core reads jq rewrites (parse_body_rewrite);
            // FlClash emits the same form.
            bodyRewrite.append("http-\(phase)-jq \(field(pattern)) \(field(unquote(rest)))")
        default:
            skip(section, line, action.hasPrefix("json-") ? .jsonBody : .unreadable)
        }
    }

    /// A mock body of more than one line goes over as base64, as each
    /// line of the core's lists is one entry.
    func readStashMock(_ section: String, item: MiniYAMLValue, intoRequestMock: Bool = false) {
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
        addMapLocal(section, line: shown, pattern: stashText(map["match"]), params: mapped, intoRequestMock: intoRequestMock)
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
        out.skipVerifyHostname += lists.skipVerifyHostname
        out.clientSourceAddress += lists.clientSourceAddress
        out.requestBodyMock += lists.requestBodyMock
        out.forceHttpHostname += lists.forceHttpHostname
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

    /// Builds module content from the core's mitm.readModule view
    /// (upstream 165154c). The core is authoritative for the meta,
    /// the declared arguments, the Clash rules, the declared scripts
    /// and the resources — and for which lines it cannot read
    /// (`issues`) or does not take (`ignored`). The MITM line lists
    /// still come from the Swift parser: the core's views are the
    /// parsed forms of those lines and have no line form to send
    /// back, so only the Swift parser produces the syntax the core's
    /// config takes. The two read the same text line for line; where
    /// they differ — a line the core takes that the Swift parser
    /// skips, or the other way round — the core's report
    /// (issues/ignored, shown in the module detail view) is what the
    /// user sees. `values` / `resources` are the module's current
    /// arguments and downloaded resources, as for parse.
    static func parseWithCore(view: ConcordMitmModuleView, text: String, values: [String: String] = [:], resources: [String: String] = [:]) -> MitmModuleContent {
        var content = parse(text: text, values: values, resources: resources)
        content.coreParsed = true
        content.coreFormat = view.format
        content.coreOffReason = view.off?.reason
        content.coreAsksConsent = view.asksConsent
        content.coreIssueCount = view.issues.values.reduce(0) { $0 + $1.count }
        content.coreIgnored = view.ignored.map { ignored in
            var line = "第 \(ignored.line) 行（\(coreIgnoreLabel(ignored.reason))）"
            if let detail = ignored.detail, !detail.isEmpty { line += "：\(detail)" }
            return line
        }
        if let name = view.meta.name { content.name = name }
        if let desc = view.meta.desc { content.description = desc }
        if let system = view.meta.system { content.system = system }
        if !view.arguments.isEmpty {
            content.arguments = view.arguments.map { arg in
                MitmModuleArgument(
                    name: arg.name,
                    defaultValue: arg.`default`,
                    type: arg.kind.type == "select" ? .select : (arg.kind.type == "switch" ? .toggle : .input),
                    options: arg.kind.options ?? [],
                    label: arg.label,
                    description: arg.desc,
                    number: arg.number)
            }
        }
        // The core's rule + policy, in profile rule-line form
        // ("TYPE,VALUE,POLICY" plus ",no-resolve" when set).
        content.rules = view.rules.map { rule in
            var line = "\(rule.rule),\(rule.policy.display)"
            if rule.noResolve { line += ",no-resolve" }
            return line
        }
        // Declared scripts: the core gives 1-based line indices;
        // the lines themselves are the declaration text, as the
        // Swift parser records them.
        let lines = text.components(separatedBy: .newlines)
        content.declaredScriptLines = view.declaredScripts.compactMap { index in
            let i = Int(index) - 1
            guard lines.indices.contains(i) else { return nil }
            return lines[i].trimmingCharacters(in: .whitespaces)
        }
        content.resourceUrls.formUnion(view.resources.map(\.url))
        return content
    }

    /// The core's ignore reasons, in the user's words (upstream
    /// crates/config/src/mitm/module.rs IgnoreReason).
    private static func coreIgnoreLabel(_ reason: String) -> String {
        switch reason {
        case "section": return "不支持的段"
        case "appOnly": return "仅原 App 支持"
        case "proxies": return "模块不能改代理"
        case "setting": return "不支持的设置"
        case "managedCa": return "CA 由系统管理"
        case "requirement": return "前置条件不满足"
        case "requirementUnreadable": return "前置条件无法读取"
        case "scriptType": return "不支持的脚本类型"
        case "event": return "不支持的事件"
        case "disabled": return "行内已禁用"
        case "finalRule": return "FINAL 规则不生效"
        case "deviceRule": return "仅设备自身规则"
        case "ruleType": return "无对应的规则类型"
        case "policy": return "策略无对应出口"
        case "nestedRuleSet": return "嵌套规则集"
        case "reflect": return "不支持 reflect"
        case "skipVerifyAll": return "跳过全部验证"
        case "noAttachment": return "本地文件未附加"
        case "unreadable": return "无法解析的行"
        case "condition": return "不支持的条件"
        case "runtimeValue": return "运行时才有的值"
        default: return reason
        }
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
