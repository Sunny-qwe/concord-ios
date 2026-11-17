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
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
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
            .font(.caption)
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
