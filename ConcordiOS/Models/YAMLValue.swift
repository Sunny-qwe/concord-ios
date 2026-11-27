// MARK: - JSONValue -> YAML (for baking full node definitions)
// Renders a JSONValue as YAML lines. Used to bake a node's full
// definition (proxy.definition) into the active profile's
// `proxies:` block when the user adds it to the local proxies from
// the 代理 page: unlike CustomProxy (a form subset), the definition
// keeps every key — ws-opts, grpc-opts, reality-opts, flow, alpn —
// so the baked node behaves exactly like the original. Strings are
// quoted with CustomProxy.quote (same rule as the form proxies).
// Mapping keys are emitted sorted (name first for a proxy item) —
// YAML mappings are unordered, so this only affects readability.

enum YAMLValue {
    private static func scalar(_ value: JSONValue) -> String? {
        switch value {
        case .null: return "~"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .string(let value): return CustomProxy.quote(value)
        case .array, .object: return nil
        }
    }

    private static func mappingLines(_ dict: [String: JSONValue], indent: Int, firstKey: String? = nil) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var keys = dict.keys.sorted()
        if let firstKey, let index = keys.firstIndex(of: firstKey) {
            keys.remove(at: index)
            keys.insert(firstKey, at: 0)
        }
        var out: [String] = []
        for key in keys {
            let child = dict[key]!
            if let text = scalar(child) {
                out.append("\(pad)\(key): \(text)")
            } else if case .object(let inner) = child, inner.isEmpty {
                out.append("\(pad)\(key): {}")
            } else if case .array(let inner) = child, inner.isEmpty {
                out.append("\(pad)\(key): []")
            } else {
                out.append("\(pad)\(key):")
                out.append(contentsOf: lines(for: child, indent: indent + 2))
            }
        }
        return out
    }

    /// Lines for `value` at `indent` spaces. Scalars render on one
    /// line; collections render as nested blocks (empty ones as {}
    /// / []). A mapping's first line is never prefixed here — see
    /// proxyItemLines for the list-item form.
    static func lines(for value: JSONValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .object(let dict):
            if dict.isEmpty { return ["\(pad){}"] }
            return mappingLines(dict, indent: indent)
        case .array(let items):
            if items.isEmpty { return ["\(pad)[]"] }
            var out: [String] = []
            for item in items {
                if let text = scalar(item) {
                    out.append("\(pad)- \(text)")
                } else if case .object(let inner) = item, inner.isEmpty {
                    out.append("\(pad)- {}")
                } else if case .array(let inner) = item, inner.isEmpty {
                    out.append("\(pad)- []")
                } else {
                    var nested = lines(for: item, indent: indent + 2)
                    nested[0] = "\(pad)- " + String(nested[0].dropFirst(indent + 2))
                    out.append(contentsOf: nested)
                }
            }
            return out
        default:
            return ["\(pad)\(scalar(value) ?? "~")"]
        }
    }

    /// One proxy definition as a `proxies:` list item at `indent`
    /// spaces: the `name:` line shares the "- " line, the rest of
    /// the keys align under it.
    static func proxyItemLines(for definition: JSONValue, indent: Int) -> [String] {
        guard case .object(let dict) = definition, !dict.isEmpty else { return [] }
        var body = mappingLines(dict, indent: indent + 2, firstKey: "name")
        body[0] = String(repeating: " ", count: indent) + "- " + String(body[0].dropFirst(indent + 2))
        return body
    }
}
