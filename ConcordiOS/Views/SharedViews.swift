import SwiftUI

// MARK: - Shared UI pieces
// Used by several FlClash-like pages. Sample data is always labelled:
// every page that shows mock data carries a "示例数据" badge so it is
// never mistaken for live core data.

/// Small badge shown on any card/section that displays sample data.
struct SampleDataBadge: View {
    var body: some View {
        Text("示例数据")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}

// MARK: - String list editor (DNS / sniffer / override pages)
// A compact add-row + per-row delete list bound to a [String].
// Used wherever a config list (nameservers, skip-domains, …) is
// edited inline inside a Form/List section. Deletion is an explicit
// button, not swipe-to-delete: onDelete does not fire when the
// ForEach lives inside a custom subview.

struct StringListEditor: View {
    @Binding var items: [String]
    var placeholder: String
    var onChange: (() -> Void)? = nil
    @State private var newItem = ""
    @State private var error: String?

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button {
                    items.removeAll { $0 == item }
                    onChange?()
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            TextField(placeholder, text: $newItem)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") {
                let value = newItem.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return }
                guard !items.contains(value) else {
                    error = "这条已存在"
                    return
                }
                error = nil
                items.append(value)
                onChange?()
                newItem = ""
            }
            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Key=value map editor (DNS policy maps)
// Edits a [String: String] as "key = value" lines, one row per
// entry plus an add row with separate key / value fields.

struct KeyValueListEditor: View {
    @Binding var items: [String: String]
    var keyPlaceholder: String
    var valuePlaceholder: String
    var onChange: (() -> Void)? = nil
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var error: String?

    private var sortedKeys: [String] { items.keys.sorted() }

    var body: some View {
        ForEach(sortedKeys, id: \.self) { key in
            HStack {
                Text(key)
                    .font(.system(.body, design: .monospaced))
                Text("=")
                    .foregroundStyle(.secondary)
                Text(items[key] ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    items.removeValue(forKey: key)
                    onChange?()
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            TextField(keyPlaceholder, text: $newKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("=")
                .foregroundStyle(.secondary)
            TextField(valuePlaceholder, text: $newValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") {
                let key = newKey.trimmingCharacters(in: .whitespaces)
                let value = newValue.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !value.isEmpty else { return }
                guard items[key] == nil else {
                    error = "这个键已存在"
                    return
                }
                error = nil
                items[key] = value
                onChange?()
                newKey = ""
                newValue = ""
            }
            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty
                      || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
