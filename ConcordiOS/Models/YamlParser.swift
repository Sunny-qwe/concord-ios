import Foundation

// MARK: - YAML 解析器（Clash 风格 YAML -> JSONValue）
//
// v0.2.55 新增：App 内第一份 YAML 解析器。解析结果复用已有的
// JSONValue（ConcordClient.swift）——YAML 的标量/集合类型与 JSON
// 完全对应（null/bool/int/double/string/array/object），不需要新
// 的值枚举；锚点解析后也是 JSONValue（值类型，alias 取用即深拷贝）。
//
// 支持：块映射/序列、流式映射/序列（{...}、[...]，可跨行）、单/双
// 引号字符串、 plain 标量、注释（#）、嵌套缩进、文档标记（---）、
// 块标量（|、>，含 +/- 截断指示）、锚点/别名（&、*，含合并键 <<）。
// 数字/布尔/null 按 YAML 1.2 core schema 解析（true/false 才是布
// 尔；yes/no/on/off 是字符串——与核心的 serde_yaml 一致）。
// 重复键是硬错误（核心会拒绝重复键）。不支持的构造（标签 !、显式
// 键 ?、多文档、Tab 缩进）一律报错，绝不静默丢弃。
//
// 实现是纯函数式递归下降解析（无正则、无第三方依赖），算法与
// ~/workspace/scratch/yaml-0.2.55/yaml_port.py 逐行对应——该 Python
// 移植版已对两份夹具 + 单元夹具 + 9 个错误夹具跑过测试（与 PyYAML
// 全量比对一致），见同目录 test_yaml.py。Swift 版无法在 VM 上编译，
// 唯一验证是 macOS runner；写 Swift 时请对照 Python 移植版。

/// 一行解析失败：`line` 为原文行号（1-based），`message` 为中文说明。
struct YamlParserError: LocalizedError {
    let line: Int?
    let message: String

    var errorDescription: String? {
        if let line {
            return "第 \(line) 行：\(message)"
        }
        return message
    }
}

/// 流式值内部信号：输入耗尽但结构未闭合（调用方据此续接下一行重试）。
private struct YamlIncomplete: Error {}

enum YamlParser {

    // MARK: - 入口

    static func parse(_ text: String) throws -> JSONValue {
        var parser = try Parser(text: text)
        return try parser.parse()
    }

    // MARK: - 行

    private struct Line {
        let indent: Int
        let text: String
        let num: Int
    }

    // MARK: - 文档解析器

    private struct Parser {
        private var rawLines: [String]
        private var lines: [Line] = []
        private var index: Int = 0
        private var anchors: [String: JSONValue] = [:]

        init(text: String) throws {
            rawLines = text.components(separatedBy: "\n")
            var seenDocStart = false
            for (offset, rawWithCR) in rawLines.enumerated() {
                let num = offset + 1
                let raw = rawWithCR.hasSuffix("\r") ? String(rawWithCR.dropLast()) : rawWithCR
                var leadCount = 0
                for ch in raw {
                    if ch == " " || ch == "\t" { leadCount += 1 } else { break }
                }
                if raw.prefix(leadCount).contains("\t") {
                    throw YamlParserError(line: num, message: "缩进不能使用 Tab，请改用空格")
                }
                let content = YamlParser.stripComment(raw)
                if content.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let indent = content.prefix(while: { $0 == " " }).count
                let body = String(content.dropFirst(indent))
                if body == "---" {
                    if seenDocStart || !lines.isEmpty {
                        throw YamlParserError(line: num, message: "不支持多文档 YAML（文件中有多个 ---）")
                    }
                    seenDocStart = true
                    continue
                }
                if body.hasPrefix("--- ") {
                    throw YamlParserError(line: num, message: "文档标记 --- 后不能有行内内容")
                }
                if body == "..." { break }
                if body.hasPrefix("... ") {
                    throw YamlParserError(line: num, message: "文档结束标记 ... 后不能有行内内容")
                }
                lines.append(Line(indent: indent, text: body, num: num))
            }
        }

        private func peek() -> Line? {
            guard index < lines.count else { return nil }
            return lines[index]
        }

        mutating func parse() throws -> JSONValue {
            guard !lines.isEmpty else { return .null }
            let value = try parseBlock(lines[0].indent)
            if index < lines.count {
                let ln = lines[index]
                throw YamlParserError(line: ln.num, message: "意外的缩进或多余内容：\(String(ln.text.prefix(40)))")
            }
            return value
        }

        // MARK: 块结构

        private mutating func parseBlock(_ indent: Int) throws -> JSONValue {
            guard let ln = peek() else { return .null }
            if YamlParser.isSequenceItem(ln.text) { return try parseSequence(indent) }
            if YamlParser.isMappingEntry(ln.text) { return try parseMapping(indent) }
            // 孤立的标量文档
            index += 1
            return try parseInlineValue(ln.text, indent: indent, line: ln.num)
        }

        private mutating func parseMapping(_ indent: Int) throws -> JSONValue {
            var out: [String: JSONValue] = [:]
            var merged: [String: JSONValue] = [:]
            var seen: Set<String> = []
            while let ln = peek(), ln.indent == indent {
                guard YamlParser.isMappingEntry(ln.text) else {
                    throw YamlParserError(line: ln.num, message: "此处应为 key: value，实际是：\(String(ln.text.prefix(40)))")
                }
                let (key, rest) = try YamlParser.splitKey(ln.text, line: ln.num)
                index += 1
                let value = try parseValueAfterKey(rest, indent: indent, line: ln.num)
                if key == "<<" {
                    switch value {
                    case .object(let dict):
                        for (k, v) in dict where merged[k] == nil { merged[k] = v }
                    case .array(let items):
                        for item in items {
                            guard case .object(let dict) = item else {
                                throw YamlParserError(line: ln.num, message: "合并键 << 的列表项必须是映射")
                            }
                            for (k, v) in dict where merged[k] == nil { merged[k] = v }
                        }
                    default:
                        throw YamlParserError(line: ln.num, message: "合并键 << 的值必须是映射或映射列表")
                    }
                    continue
                }
                if seen.contains(key) {
                    throw YamlParserError(line: ln.num, message: "重复的键：\(key)（核心会拒绝重复键）")
                }
                seen.insert(key)
                out[key] = value
            }
            for (k, v) in merged where out[k] == nil { out[k] = v }
            return .object(out)
        }

        private mutating func parseSequence(_ indent: Int) throws -> JSONValue {
            var out: [JSONValue] = []
            while let ln = peek(), ln.indent == indent {
                guard YamlParser.isSequenceItem(ln.text) else {
                    throw YamlParserError(line: ln.num, message: "此处应为 - 列表项，实际是：\(String(ln.text.prefix(40)))")
                }
                let body = String(ln.text.dropFirst().drop(while: { $0 == " " }))
                if body.isEmpty {
                    index += 1
                    if let nxt = peek(), nxt.indent > indent {
                        out.append(try parseBlock(nxt.indent))
                    } else {
                        out.append(.null)
                    }
                    continue
                }
                // 把当前行改写为 indent+2 的虚拟行，再按映射/序列/标量递归
                lines[index] = Line(indent: indent + 2, text: body, num: ln.num)
                if YamlParser.isSequenceItem(body) {
                    out.append(try parseSequence(indent + 2))
                } else if YamlParser.isMappingEntry(body) {
                    out.append(try parseMapping(indent + 2))
                } else {
                    index += 1
                    out.append(try parseInlineValue(body, indent: indent, line: ln.num))
                }
            }
            return .array(out)
        }

        // MARK: 值

        private mutating func parseValueAfterKey(_ rest: String, indent: Int, line: Int) throws -> JSONValue {
            if rest.isEmpty {
                guard let nxt = peek() else { return .null }
                if nxt.indent > indent { return try parseBlock(nxt.indent) }
                if nxt.indent == indent && YamlParser.isSequenceItem(nxt.text) {
                    return try parseSequence(indent)
                }
                return .null
            }
            return try parseInlineValue(rest, indent: indent, line: line)
        }

        private mutating func parseInlineValue(_ text: String, indent: Int, line: Int) throws -> JSONValue {
            let stripped = YamlParser.stripComment(text).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { return .null }
            if stripped.hasPrefix("!") {
                let tag = stripped.split(separator: " ", maxSplits: 1).first.map(String.init) ?? stripped
                throw YamlParserError(line: line, message: "不支持标签：\(tag)")
            }
            if stripped.hasPrefix("&") {
                let after = String(stripped.dropFirst())
                let parts = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let name = parts.first.map(String.init), !name.isEmpty else {
                    throw YamlParserError(line: line, message: "锚点 & 后面缺少名称")
                }
                let value: JSONValue
                if parts.count == 1 {
                    if let nxt = peek(), nxt.indent > indent {
                        value = try parseBlock(nxt.indent)
                    } else {
                        value = .null
                    }
                } else {
                    value = try parseInlineValue(String(parts[1]), indent: indent, line: line)
                }
                anchors[name] = value
                return value
            }
            if stripped.hasPrefix("*") {
                let name = String(stripped.dropFirst()).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                guard let value = anchors[name] else {
                    throw YamlParserError(line: line, message: "未定义的别名：*\(name)")
                }
                return value
            }
            if stripped.hasPrefix("|") || stripped.hasPrefix(">") {
                return try parseBlockScalar(stripped, indent: indent, line: line)
            }
            if stripped.hasPrefix("{") || stripped.hasPrefix("[") {
                return try parseFlowValueMultiline(stripped, indent: indent, line: line)
            }
            if stripped.hasPrefix("\"") || stripped.hasPrefix("'") {
                var acc = stripped
                while true {
                    do {
                        let chars = Array(acc)
                        var pos = 0
                        let value: String
                        if acc.hasPrefix("\"") {
                            value = try YamlParser.parseDoubleQuoted(chars, pos: &pos, line: line)
                        } else {
                            value = try YamlParser.parseSingleQuoted(chars, pos: &pos, line: line)
                        }
                        let rest = YamlParser.stripComment(String(chars[pos...])).trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty {
                            throw YamlParserError(line: line, message: "引用字符串后有多余内容：\(String(rest.prefix(30)))")
                        }
                        return .string(value)
                    } catch is YamlIncomplete {
                        guard let nxt = peek() else {
                            throw YamlParserError(line: line, message: "引用的字符串没有闭合")
                        }
                        acc += "\n" + nxt.text
                        index += 1
                    }
                }
            }
            // plain 标量；后续更深缩进的行是它的续行（按 YAML 规则以空格连接）
            var value = YamlParser.resolveScalar(stripped, line: line)
            while let nxt = peek(), nxt.indent > indent {
                let cont = YamlParser.stripComment(nxt.text).trimmingCharacters(in: .whitespaces)
                index += 1
                guard !cont.isEmpty else { continue }
                switch value {
                case .string(let s):
                    value = .string(s + " " + cont)
                default:
                    value = .string(value.displayString + " " + cont)
                }
            }
            return value
        }

        private mutating func parseFlowValueMultiline(_ text: String, indent: Int, line: Int) throws -> JSONValue {
            var accumulated = text
            while true {
                do {
                    let chars = Array(accumulated)
                    var pos = 0
                    let value = try flowValue(chars, pos: &pos, line: line)
                    flowSkipWhitespace(chars, pos: &pos)
                    if pos < chars.count {
                        let rest = YamlParser.stripComment(String(chars[pos...])).trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty {
                            throw YamlParserError(line: line, message: "流式值后有多余内容：\(String(rest.prefix(30)))")
                        }
                    }
                    return value
                } catch is YamlIncomplete {
                    guard let nxt = peek() else {
                        throw YamlParserError(line: line, message: "流式值（{...} 或 [...]）没有闭合")
                    }
                    accumulated += "\n" + nxt.text
                    index += 1
                }
            }
        }

        private mutating func parseBlockScalar(_ header: String, indent: Int, line: Int) throws -> JSONValue {
            let style = header.first!
            var chomping: Character? = nil
            var explicitIndent: Int? = nil
            for ch in header.dropFirst() {
                if ch == "+" || ch == "-" {
                    chomping = ch
                } else if let digit = ch.wholeNumberValue {
                    explicitIndent = digit
                } else if ch == "#" {
                    break
                } else {
                    throw YamlParserError(line: line, message: "块标量头无效：\(header)")
                }
            }
            var collected: [String] = []
            var base: Int? = nil
            var j = line // rawLines 的下标：header 行的下一行（line 是 1-based）
            while j < rawLines.count {
                let rawWithCR = rawLines[j]
                let raw = rawWithCR.hasSuffix("\r") ? String(rawWithCR.dropLast()) : rawWithCR
                if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    collected.append("")
                    j += 1
                    continue
                }
                var leadCount = 0
                for ch in raw {
                    if ch == " " || ch == "\t" { leadCount += 1 } else { break }
                }
                if raw.prefix(leadCount).contains("\t") {
                    throw YamlParserError(line: j + 1, message: "缩进不能使用 Tab，请改用空格")
                }
                let ind = raw.prefix(while: { $0 == " " }).count
                if ind <= indent { break }
                if base == nil {
                    base = explicitIndent.map { $0 + indent } ?? ind
                }
                let strip = base ?? 0
                collected.append(String(raw.dropFirst(min(strip, raw.count))))
                j += 1
            }
            var trailingBlanks = 0
            while collected.last == "" {
                collected.removeLast()
                trailingBlanks += 1
            }
            while index < lines.count && lines[index].num <= j {
                index += 1
            }
            let body: String
            if style == "|" {
                body = collected.joined(separator: "\n")
            } else {
                var parts: [String] = []
                for piece in collected {
                    if piece.isEmpty {
                        parts.append("\n")
                    } else {
                        if let last = parts.last, !last.hasSuffix("\n") { parts.append(" ") }
                        parts.append(piece)
                    }
                }
                body = parts.joined()
            }
            if chomping == "-" {
                return .string(body)
            }
            if chomping == "+" {
                if collected.isEmpty && trailingBlanks == 0 { return .string("") }
                return .string(body + String(repeating: "\n", count: trailingBlanks + 1))
            }
            return .string(collected.isEmpty ? "" : body + "\n")
        }

        // MARK: 流式值（在 chars 数组上用下标游标解析）

        private mutating func flowValue(_ chars: [Character], pos: inout Int, line: Int) throws -> JSONValue {
            flowSkipWhitespace(chars, pos: &pos)
            guard pos < chars.count else { throw YamlIncomplete() }
            let c = chars[pos]
            switch c {
            case "{":
                return try flowMapping(chars, pos: &pos, line: line)
            case "[":
                return try flowSequence(chars, pos: &pos, line: line)
            case "\"":
                return .string(try YamlParser.parseDoubleQuoted(chars, pos: &pos, line: line))
            case "'":
                return .string(try YamlParser.parseSingleQuoted(chars, pos: &pos, line: line))
            case "&":
                pos += 1
                let start = pos
                while pos < chars.count && !" \t\n,]}".contains(chars[pos]) { pos += 1 }
                let name = String(chars[start..<pos])
                let value = try flowValue(chars, pos: &pos, line: line)
                anchors[name] = value
                return value
            case "*":
                pos += 1
                let start = pos
                while pos < chars.count && !" \t\n,]}".contains(chars[pos]) { pos += 1 }
                let name = String(chars[start..<pos])
                guard let value = anchors[name] else {
                    throw YamlParserError(line: line, message: "未定义的别名：*\(name)")
                }
                return value
            case "!":
                throw YamlParserError(line: line, message: "不支持标签")
            case ",", "]", "}":
                throw YamlParserError(line: line, message: "流式值中出现意外的字符：\(c)")
            default:
                return flowPlainScalar(chars, pos: &pos, line: line)
            }
        }

        private mutating func flowMapping(_ chars: [Character], pos: inout Int, line: Int) throws -> JSONValue {
            pos += 1 // {
            var out: [String: JSONValue] = [:]
            flowSkipWhitespace(chars, pos: &pos)
            if pos < chars.count && chars[pos] == "}" {
                pos += 1
                return .object(out)
            }
            while true {
                flowSkipWhitespace(chars, pos: &pos)
                guard pos < chars.count else { throw YamlIncomplete() }
                if chars[pos] == "}" {
                    pos += 1
                    return .object(out)
                }
                let key: String
                let kc = chars[pos]
                if kc == "{" || kc == "[" {
                    let keyValue = try flowValue(chars, pos: &pos, line: line)
                    key = keyValue.displayString
                } else if kc == "\"" || kc == "'" {
                    if kc == "\"" {
                        key = try YamlParser.parseDoubleQuoted(chars, pos: &pos, line: line)
                    } else {
                        key = try YamlParser.parseSingleQuoted(chars, pos: &pos, line: line)
                    }
                } else {
                    let rawKey = flowPlainScalar(chars, pos: &pos, line: line)
                    key = rawKey.displayString
                }
                flowSkipWhitespace(chars, pos: &pos)
                guard pos < chars.count else { throw YamlIncomplete() }
                guard chars[pos] == ":" else {
                    throw YamlParserError(line: line, message: "流式映射的键后面缺少冒号")
                }
                pos += 1
                flowSkipWhitespace(chars, pos: &pos)
                let value: JSONValue
                if pos < chars.count && (chars[pos] == "," || chars[pos] == "}") {
                    value = .null
                } else {
                    value = try flowValue(chars, pos: &pos, line: line)
                }
                if out[key] != nil {
                    throw YamlParserError(line: line, message: "重复的键：\(key)（核心会拒绝重复键）")
                }
                out[key] = value
                flowSkipWhitespace(chars, pos: &pos)
                guard pos < chars.count else { throw YamlIncomplete() }
                if chars[pos] == "," {
                    pos += 1
                    continue
                }
                if chars[pos] == "}" {
                    pos += 1
                    return .object(out)
                }
                throw YamlParserError(line: line, message: "流式映射中出现意外的字符：\(chars[pos])")
            }
        }

        private mutating func flowSequence(_ chars: [Character], pos: inout Int, line: Int) throws -> JSONValue {
            pos += 1 // [
            var out: [JSONValue] = []
            flowSkipWhitespace(chars, pos: &pos)
            if pos < chars.count && chars[pos] == "]" {
                pos += 1
                return .array(out)
            }
            while true {
                flowSkipWhitespace(chars, pos: &pos)
                guard pos < chars.count else { throw YamlIncomplete() }
                if chars[pos] == "]" {
                    pos += 1
                    return .array(out)
                }
                out.append(try flowValue(chars, pos: &pos, line: line))
                flowSkipWhitespace(chars, pos: &pos)
                guard pos < chars.count else { throw YamlIncomplete() }
                if chars[pos] == "," {
                    pos += 1
                    continue
                }
                if chars[pos] == "]" {
                    pos += 1
                    return .array(out)
                }
                throw YamlParserError(line: line, message: "流式序列中出现意外的字符：\(chars[pos])")
            }
        }

        private func flowPlainScalar(_ chars: [Character], pos: inout Int, line: Int) -> JSONValue {
            let start = pos
            while pos < chars.count {
                let c = chars[pos]
                if c == "," || c == "]" || c == "}" { break }
                if c == ":" && (pos + 1 >= chars.count || " \t\n,]}".contains(chars[pos + 1])) { break }
                if c == "#" && pos > start && (chars[pos - 1] == " " || chars[pos - 1] == "\t") { break }
                pos += 1
            }
            let raw = String(chars[start..<pos]).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty {
                // 调用方只在确定有值时调用；空值由调用方处理，这里返回 null
                return .null
            }
            return YamlParser.resolveScalar(raw, line: line)
        }

        private func flowSkipWhitespace(_ chars: [Character], pos: inout Int) {
            while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t" || chars[pos] == "\n" || chars[pos] == "\r") {
                pos += 1
            }
            if pos < chars.count && chars[pos] == "#" {
                while pos < chars.count && chars[pos] != "\n" { pos += 1 }
                flowSkipWhitespace(chars, pos: &pos)
            }
        }
    }

    // MARK: - 行级辅助（静态、无状态）

    /// 去掉行尾注释（# 在行首或空白之后才开始注释；引号内的 # 保留）。
    private static func stripComment(_ text: String) -> String {
        var out: [Character] = []
        let chars = Array(text)
        var i = 0
        var quote: Character? = nil
        while i < chars.count {
            let c = chars[i]
            if quote == "'" {
                out.append(c)
                if c == "'" {
                    if i + 1 < chars.count && chars[i + 1] == "'" {
                        out.append("'")
                        i += 2
                        continue
                    }
                    quote = nil
                }
                i += 1
                continue
            }
            if quote == "\"" {
                out.append(c)
                if c == "\\" {
                    if i + 1 < chars.count {
                        out.append(chars[i + 1])
                        i += 2
                        continue
                    }
                } else if c == "\"" {
                    quote = nil
                }
                i += 1
                continue
            }
            if c == "'" {
                quote = "'"
                out.append(c)
                i += 1
                continue
            }
            if c == "\"" {
                quote = "\""
                out.append(c)
                i += 1
                continue
            }
            if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
                break
            }
            out.append(c)
            i += 1
        }
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return String(out)
    }

    /// plain 键的结尾冒号下标（冒号后是空格或行尾，且不在引号内）。
    private static func findKeyColon(_ chars: [Character]) -> Int? {
        var i = 0
        var quote: Character? = nil
        while i < chars.count {
            let c = chars[i]
            if quote == "'" {
                if c == "'" {
                    if i + 1 < chars.count && chars[i + 1] == "'" { i += 2; continue }
                    quote = nil
                }
                i += 1
                continue
            }
            if quote == "\"" {
                if c == "\\" { i += 2; continue }
                if c == "\"" { quote = nil }
                i += 1
                continue
            }
            if c == "'" { quote = "'"; i += 1; continue }
            if c == "\"" { quote = "\""; i += 1; continue }
            if c == ":" && (i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\t") {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func splitKey(_ text: String, line: Int) throws -> (String, String) {
        let chars = Array(text)
        var start = 0
        while start < chars.count && chars[start] == " " { start += 1 }
        if start < chars.count && (chars[start] == "\"" || chars[start] == "'") {
            var pos = start
            let key: String
            if chars[start] == "\"" {
                key = try parseDoubleQuoted(chars, pos: &pos, line: line)
            } else {
                key = try parseSingleQuoted(chars, pos: &pos, line: line)
            }
            var rest = pos
            while rest < chars.count && chars[rest] == " " { rest += 1 }
            guard rest < chars.count && chars[rest] == ":" else {
                throw YamlParserError(line: line, message: "引用的键后面缺少冒号")
            }
            let value = String(chars[(rest + 1)...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("? ") || text.trimmingCharacters(in: .whitespaces) == "?" {
            throw YamlParserError(line: line, message: "不支持显式键（? key），请写成 key: value 形式")
        }
        guard let idx = findKeyColon(chars) else {
            throw YamlParserError(line: line, message: "无法解析这一行（缺少冒号）：\(String(text.prefix(40)))")
        }
        let key = String(chars[..<idx]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            throw YamlParserError(line: line, message: "键为空")
        }
        if key.hasPrefix("!") || key.hasPrefix("&") || key.hasPrefix("*") || key.hasPrefix("|")
            || key.hasPrefix(">") || key.hasPrefix("%") || key.hasPrefix("@") || key.hasPrefix("`") {
            throw YamlParserError(line: line, message: "不支持的键起始字符：\(String(key.prefix(1)))")
        }
        let value = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func isMappingEntry(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " })
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return false }
        if trimmed.hasPrefix("? ") || trimmed == "?" { return true }
        let chars = Array(text)
        if let first = trimmed.first, first == "\"" || first == "'" {
            var pos = 0
            while pos < chars.count && chars[pos] == " " { pos += 1 }
            do {
                if first == "\"" {
                    _ = try parseDoubleQuoted(chars, pos: &pos, line: 0)
                } else {
                    _ = try parseSingleQuoted(chars, pos: &pos, line: 0)
                }
                var rest = pos
                while rest < chars.count && chars[rest] == " " { rest += 1 }
                return rest < chars.count && chars[rest] == ":"
            } catch is YamlIncomplete {
                return true
            } catch {
                return false
            }
        }
        return findKeyColon(chars) != nil
    }

    private static func isSequenceItem(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " })
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return false }
        return trimmed == "-" || trimmed.hasPrefix("- ")
    }

    /// plain 标量 -> JSONValue（YAML 1.2 core schema）。
    private static func resolveScalar(_ text: String, line: Int) -> JSONValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        let sign: Int64 = text.hasPrefix("-") ? -1 : 1
        let unsigned = text.hasPrefix("+") || text.hasPrefix("-") ? String(text.dropFirst()) : text
        if unsigned.hasPrefix("0x") || unsigned.hasPrefix("0X") {
            if let value = Int64(unsigned.dropFirst(2), radix: 16) { return .int(sign * value) }
        }
        if unsigned.hasPrefix("0o") || unsigned.hasPrefix("0O") {
            if let value = Int64(unsigned.dropFirst(2), radix: 8) { return .int(sign * value) }
        }
        if let value = Int64(text) { return .int(value) }
        switch text {
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .double(Double.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-Double.infinity)
        case ".nan", ".NaN", ".NAN": return .double(Double.nan)
        default: break
        }
        if (text.contains(".") || text.contains("e") || text.contains("E")),
           let value = Double(text) {
            return .double(value)
        }
        return .string(text)
    }

    private static func hexValue(_ c: Character) -> Int? {
        switch c {
        case "0"..."9": return c.wholeNumberValue
        case "a"..."f": return 10 + Int(c.asciiValue! - Character("a").asciiValue!)
        case "A"..."F": return 10 + Int(c.asciiValue! - Character("A").asciiValue!)
        default: return nil
        }
    }

    private static let doubleEscapes: [Character: Character] = [
        "0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "\t": "\t",
        "n": "\n", "v": "\u{b}", "f": "\u{c}", "r": "\r", "e": "\u{1b}",
        "\"": "\"", "\\": "\\", "/": "/", " ": " ",
        "N": "\u{85}", "_": "\u{a0}", "L": "\u{2028}", "P": "\u{2029}",
    ]

    /// chars[pos] 必须是开引号；返回后 pos 在闭引号之后。引号未闭合抛 YamlIncomplete。
    private static func parseDoubleQuoted(_ chars: [Character], pos: inout Int, line: Int) throws -> String {
        pos += 1
        var out: [Character] = []
        while true {
            guard pos < chars.count else { throw YamlIncomplete() }
            let c = chars[pos]
            if c == "\"" {
                pos += 1
                return String(out)
            }
            if c == "\\" {
                guard pos + 1 < chars.count else { throw YamlIncomplete() }
                let e = chars[pos + 1]
                if let mapped = doubleEscapes[e] {
                    out.append(mapped)
                    pos += 2
                    continue
                }
                let digits: Int
                switch e {
                case "x": digits = 2
                case "u": digits = 4
                case "U": digits = 8
                default:
                    throw YamlParserError(line: line, message: "不支持的转义 \\\(e)")
                }
                guard pos + 1 + digits < chars.count else { throw YamlIncomplete() }
                var code = 0
                for k in 0..<digits {
                    guard let digit = hexValue(chars[pos + 2 + k]) else {
                        throw YamlParserError(line: line, message: "转义 \\(e) 后不是十六进制数字")
                    }
                    code = code * 16 + digit
                }
                guard let scalar = Unicode.Scalar(code) else {
                    throw YamlParserError(line: line, message: "转义 \\(e) 的码位无效")
                }
                out.append(Character(scalar))
                pos += 2 + digits
                continue
            }
            out.append(c)
            pos += 1
        }
    }

    private static func parseSingleQuoted(_ chars: [Character], pos: inout Int, line: Int) throws -> String {
        pos += 1
        var out: [Character] = []
        while true {
            guard pos < chars.count else { throw YamlIncomplete() }
            let c = chars[pos]
            if c == "'" {
                if pos + 1 < chars.count && chars[pos + 1] == "'" {
                    out.append("'")
                    pos += 2
                    continue
                }
                pos += 1
                return String(out)
            }
            out.append(c)
            pos += 1
        }
    }
}
