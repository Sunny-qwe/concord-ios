import SwiftUI

// MARK: - Shared UI pieces
// Used by several FlClash-like pages. Sample data is always labelled:
// every page that shows mock data carries a "示例数据" badge so it is
// never mistaken for live core data.

/// Small badge shown on any card/section that displays sample data.
struct SampleDataBadge: View {
    var body: some View {
        Text("示例数据")
            .font(.system(size: 10))
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// A card with a title and a value, as on FlClash's dashboard.
struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String?

    init(title: String, value: String, subtitle: String? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
        .shadow(color: ConcordTheme.cardShadow, radius: 8, x: 0, y: 2)
    }
}

/// Live traffic sparkline (FlClash dashboard network-speed card).
/// Draws up (green) and down (blue) rates from the history buffer.
struct TrafficChartView: View {
    let history: [TrafficPoint]

    private func path(for values: [Int64], maxValue: Int64, in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1, maxValue > 0 else { return path }
        let stepX = size.width / CGFloat(Swift.max(values.count - 1, 1))
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * stepX
            let y = size.height - (CGFloat(value) / CGFloat(maxValue)) * size.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                path(for: history.map { $0.down }, maxValue: Swift.max(history.map { $0.down }.max() ?? 1, 1), in: geometry.size)
                    .stroke(Color.blue, lineWidth: 1.5)
                path(for: history.map { $0.up }, maxValue: Swift.max(history.map { $0.down }.max() ?? 1, 1), in: geometry.size)
                    .stroke(Color.green, lineWidth: 1.5)
            }
        }
        .frame(height: 64)
    }
}

/// Latency chip used on proxy cards (FlClash proxy card delay badge).
struct LatencyChip: View {
    let latencyMs: Int32?

    var body: some View {
        Text(ConcordFormat.latency(latencyMs))
            .font(.system(size: 10))
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(latencyColor.opacity(0.15), in: Capsule())
            .foregroundStyle(latencyColor)
    }

    private var latencyColor: Color {
        guard let latencyMs, latencyMs >= 0 else { return .gray }
        if latencyMs < 150 { return .green }
        if latencyMs < 400 { return .orange }
        return .red
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
