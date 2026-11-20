import Foundation
import Combine
import JavaScriptCore

// MARK: - Extend config (FlClash: lib/views/profiles/extend/)
// Per-profile extension: standard mode = added rules (the shared
// AddedRulesStore, merged by the extension into config.apply's
// overlay) + a match target baked as a final MATCH rule; script
// mode = a JavaScript config transform, evaluated locally with
// JavaScriptCore against the config the core itself parsed
// (config.read) and written back through the existing profile
// apply path. FlClash evaluates its script through a Rust helper
// (rust_api evaluateScript); the iOS core exposes no such call, so
// the script runs in-process here instead — the convention is the
// same: define `function main(config) { …; return config; }` and
// return the new config object.

enum ExtendMode: String, Codable, CaseIterable {
    case standard = "standard"
    case script = "script"

    var label: String {
        switch self {
        case .standard: return "标准"
        case .script: return "脚本"
        }
    }

    var description: String {
        switch self {
        case .standard: return "附加规则 + 匹配目标，规则由扩展合并进配置"
        case .script: return "用 JavaScript 改写整个配置后应用"
        }
    }
}

struct ExtendSettings: Codable, Equatable {
    var mode: ExtendMode
    var matchTarget: String
    var scriptText: String
    var scriptEnabled: Bool

    init(mode: ExtendMode = .standard, matchTarget: String = "",
         scriptText: String = "", scriptEnabled: Bool = false) {
        self.mode = mode
        self.matchTarget = matchTarget
        self.scriptText = scriptText
        self.scriptEnabled = scriptEnabled
    }

    static let defaultScript = """
        // 改写配置：config 是核心解析后的配置对象，返回新配置。
        // 例如：给所有分组加上测速地址
        function main(config) {
          return config;
        }
        """
}

final class ExtendConfigStore: ObservableObject {
    @Published var settingsByProfile: [String: ExtendSettings] = [:]

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: "extend-config.json")
    }

    init() { load() }

    func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ExtendSettings].self, from: data) else { return }
        settingsByProfile = decoded
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(settingsByProfile) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func settings(for profileID: UUID) -> ExtendSettings {
        settingsByProfile[profileID.uuidString] ?? ExtendSettings()
    }

    func update(_ settings: ExtendSettings, for profileID: UUID) {
        settingsByProfile[profileID.uuidString] = settings
        save()
    }

    // MARK: - Match target

    static let matchTargetBegin = "# concord-ios 扩展匹配目标 开始"
    static let matchTargetEnd = "# concord-ios 扩展匹配目标 结束"

    /// Bake the match target as a final `MATCH,<target>` rule at
    /// the end of the profile's `rules:` section (marker-delimited,
    /// so re-applying replaces it). An empty target removes it.
    /// First match wins in Clash-style rule evaluation, so the
    /// MATCH MUST be last: baking it first (as this used to do)
    /// swallowed all traffic into the target and made every other
    /// rule dead (config B21). FlClash appends the match target as
    /// the final rule.
    static func bakeMatchTarget(_ target: String, into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // Remove a previous bake. Two shapes exist: the block
        // form (marker lines around a `  - MATCH,…` item) and the
        // flow form (markers wrapped around a `rules: […]` line
        // whose list gained a trailing MATCH item).
        if let begin = lines.firstIndex(of: matchTargetBegin),
           let end = lines.firstIndex(of: matchTargetEnd), end >= begin {
            if end == begin + 2,
               lines[begin + 1].trimmingCharacters(in: .whitespaces).hasPrefix("rules:"),
               lines[begin + 1].contains("[") {
                // Flow form: clean the baked MATCH out of the
                // rules line, then drop just the marker lines
                // (the rules line itself must stay).
                lines[begin + 1] = Self.flowRulesLineRemovingMatch(lines[begin + 1])
                lines.remove(at: end)
                lines.remove(at: begin)
            } else {
                lines.removeSubrange(begin...end)
            }
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines.joined(separator: "\n") }
        let block = [matchTargetBegin, "  - MATCH,\(trimmed)", matchTargetEnd]
        if let keyIndex = lines.firstIndex(where: { $0 == "rules:" || $0.hasPrefix("rules: ") }) {
            let rulesLine = lines[keyIndex]
            if rulesLine == "rules:" {
                // Block-style section: append at its END — the
                // section runs to the next top-level key (a
                // non-indented, non-empty line containing ":") or
                // EOF. Everything after that key belongs to another
                // section and must keep following the MATCH.
                var insertAt = lines.count
                var i = keyIndex + 1
                while i < lines.count {
                    let line = lines[i]
                    if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty && line.contains(":") {
                        insertAt = i
                        break
                    }
                    i += 1
                }
                lines.insert(contentsOf: block, at: insertAt)
            } else if rulesLine.contains("[") && rulesLine.contains("]") {
                // Flow-style `rules: […]`: append the MATCH inside
                // the brackets, wrapped in the markers so a re-bake
                // can find and replace it.
                lines[keyIndex] = Self.flowRulesLineAddingMatch(rulesLine, target: trimmed)
                lines.insert(matchTargetBegin, at: keyIndex)
                lines.insert(matchTargetEnd, at: keyIndex + 2)
            } else {
                // A `rules:` line with other trailing content we
                // cannot parse: leave the target unbaked rather
                // than emit invalid YAML.
                return lines.joined(separator: "\n")
            }
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("rules:")
            lines.append(contentsOf: block)
        }
        return lines.joined(separator: "\n")
    }

    /// Append `, MATCH,<target>` inside a flow-style `rules: […]`
    /// line, just before the closing bracket.
    private static func flowRulesLineAddingMatch(_ line: String, target: String) -> String {
        guard let close = line.lastIndex(of: "]") else { return line }
        let inner = line[line.startIndex..<close].trimmingCharacters(in: .whitespaces)
        let separator = inner.hasSuffix("[") ? "" : ", "
        return line.replacingCharacters(in: close..<line.index(after: close),
                                        with: "\(separator)MATCH,\(target)]")
    }

    /// Remove a trailing `, MATCH,…` item from a flow-style
    /// `rules: […]` line (only called when our markers prove the
    /// item is one we baked — never touches a user's own MATCH).
    /// Also handles the empty-list bake (`rules: [MATCH,…]`).
    private static func flowRulesLineRemovingMatch(_ line: String) -> String {
        if let matchRange = line.range(of: ", MATCH,", options: .backwards),
           let close = line[matchRange.upperBound...].firstIndex(of: "]") {
            return line.replacingCharacters(in: matchRange.lowerBound..<close, with: "")
        }
        if let open = line.firstIndex(of: "["),
           line[line.index(after: open)...].hasPrefix("MATCH,"),
           let close = line[line.index(after: open)...].firstIndex(of: "]") {
            return line.replacingCharacters(in: line.index(after: open)..<close, with: "")
        }
        return line
    }

    // MARK: - Script mode

    /// Run the profile's script against the config the core parsed
    /// (config.read) and write the result back through the profile
    /// apply path. Needs the core reachable (tunnel running in live
    /// mode, or sample mode). Returns a message for the UI.
    @MainActor
    func runScript(profileStore: ProfileStore) async -> String {
        guard let profile = profileStore.activeProfile else {
            return "没有已激活的订阅"
        }
        let settings = settings(for: profile.id)
        guard settings.scriptEnabled else { return "脚本未启用：先打开「启用脚本」" }
        guard !settings.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "脚本为空：先写一个 main(config) 函数"
        }
        guard let path = profileStore.absolutePathForPreflight(profile) else {
            return "该订阅没有本地文件"
        }
        let configJSON: JSONValue
        do {
            let read = try await profileStore.client.configRead(profilePath: path)
            configJSON = read.config
        } catch {
            return "读取当前配置失败（需先启动 VPN）：\(error.localizedDescription)"
        }
        guard let configData = try? JSONEncoder().encode(configJSON),
              let configString = String(data: configData, encoding: .utf8) else {
            return "配置序列化失败"
        }
        let result: String
        do {
            result = try Self.evaluateScript(settings.scriptText, configJSON: configString)
        } catch {
            return "脚本执行失败：\(error.localizedDescription)"
        }
        guard let resultData = result.data(using: .utf8),
              let resultValue = try? JSONDecoder().decode(JSONValue.self, from: resultData) else {
            return "脚本没有返回一个配置对象"
        }
        let yaml = Self.yaml(for: resultValue)
        return await profileStore.saveActiveProfileYAML(yaml)
    }

    /// Evaluate `main(config)` with JavaScriptCore. The script must
    /// define `function main(config)` and return the new config
    /// object; the returned object is serialised back to JSON.
    static func evaluateScript(_ script: String, configJSON: String) throws -> String {
        guard let context = JSContext() else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 JS 环境"])
        }
        var jsError: JSValue?
        context.exceptionHandler = { _, error in jsError = error }
        context.evaluateScript(script)
        if let jsError {
            throw NSError(domain: "ConcordiOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "脚本错误：\(jsError.toString() ?? "")"])
        }
        context.setObject(configJSON, forKeyedSubscript: "__configJson" as NSString)
        guard let json = context.evaluateScript("JSON.stringify(main(JSON.parse(__configJson)))")?.toString(),
              json != "undefined" else {
            throw NSError(domain: "ConcordiOS", code: 4, userInfo: [NSLocalizedDescriptionKey: "脚本没有返回一个配置对象"])
        }
        if let jsError {
            throw NSError(domain: "ConcordiOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "脚本错误：\(jsError.toString() ?? "")"])
        }
        return json
    }

    // MARK: - Generic JSON -> YAML

    /// Render a whole config object as YAML. Keys are sorted for
    /// stable output; strings are quoted when they need it.
    static func yaml(for value: JSONValue) -> String {
        lines(for: value, indent: 0).joined(separator: "\n") + "\n"
    }

    private static func lines(for value: JSONValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return ["\(pad)null"]
        case .bool(let b):
            return ["\(pad)\(b ? "true" : "false")"]
        case .int(let i):
            return ["\(pad)\(i)"]
        case .double(let d):
            return ["\(pad)\(d)"]
        case .string(let s):
            return ["\(pad)\(CustomProxy.quote(s))"]
        case .array(let items):
            if items.isEmpty { return ["\(pad)[]"] }
            var out: [String] = []
            for item in items {
                switch item {
                case .object(let dict):
                    let sub = mappingLines(dict, indent: indent + 2)
                    if let first = sub.first {
                        out.append("\(pad)- " + String(first.dropFirst(indent + 2)))
                        out.append(contentsOf: sub.dropFirst())
                    } else {
                        out.append("\(pad)- {}")
                    }
                case .array(let nested):
                    if nested.isEmpty {
                        out.append("\(pad)- []")
                    } else {
                        out.append("\(pad)-")
                        out.append(contentsOf: lines(for: item, indent: indent + 2))
                    }
                default:
                    out.append("\(pad)- \(scalar(item) ?? "null")")
                }
            }
            return out
        case .object(let dict):
            if dict.isEmpty { return ["\(pad){}"] }
            return mappingLines(dict, indent: indent)
        }
    }

    private static func mappingLines(_ dict: [String: JSONValue], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        for key in dict.keys.sorted() {
            let value = dict[key]!
            switch value {
            case .object(let nested):
                if nested.isEmpty {
                    out.append("\(pad)\(key): {}")
                } else {
                    out.append("\(pad)\(key):")
                    out.append(contentsOf: lines(for: value, indent: indent + 2))
                }
            case .array(let items):
                if items.isEmpty {
                    out.append("\(pad)\(key): []")
                } else {
                    out.append("\(pad)\(key):")
                    out.append(contentsOf: lines(for: value, indent: indent + 2))
                }
            default:
                out.append("\(pad)\(key): \(scalar(value) ?? "null")")
            }
        }
        return out
    }

    private static func scalar(_ value: JSONValue) -> String? {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return CustomProxy.quote(s)
        case .array, .object: return nil
        }
    }
}
