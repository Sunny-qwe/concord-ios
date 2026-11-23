import SwiftUI

// MARK: - Config warnings deck (FlClash v0.9.5-rs.1, item 10)
//
// Upstream: lib/views/dashboard/widgets/live_status_deck.dart
// (_WarningsHero, the warnings card of the live-status deck)
// and lib/views/dashboard/widgets/live_status.dart
// (WarningsStatus). The warnings come from controller.dart
// getConfigWarnings -> api.lastWarnings(), mapped by
// mapping.dart warningOf (level "warning" vs everything
// else -> info; path; message). The card's title is l10n
// configWarnings ("配置警告") and its body is
// configWarningsCount(n) ("加载配置时有 N 条警告").
//
// Row layout mirrors upstream's expanded list: a warning
// glyph, then the message in full with the path underneath
// (caption, secondary). Upstream's model has no `code` —
// the core's Warning carries one, a stable identifier such
// as `unknown_key` (proto types/common.rs), so it rides
// along after the path when present.
//
// A plain deck: no navigation, no actions, no scrolling of
// its own — the presenter decides the container.

struct ConfigWarningsDeck: View {
    let warnings: [ConcordWarning]

    init(warnings: [ConcordWarning]) {
        self.warnings = warnings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if warnings.isEmpty {
                Text("暂无配置警告")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(warnings.indices, id: \.self) { index in
                    warningRow(warnings[index])
                    if index < warnings.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("配置警告")
                    .font(.headline)
                Text("加载配置时有 \(warnings.count) 条警告")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func warningRow(_ warning: ConcordWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning.level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(warning.level == "warning" ? .orange : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.message)
                    .font(.subheadline)
                if let detail = warningDetail(warning) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Path first, then the core's stable code when the warning
    /// carries one ("proxies[12] · unknown_key"). Upstream shows
    /// the path only — its model has no code.
    private func warningDetail(_ warning: ConcordWarning) -> String? {
        let path = warning.path
        let code = warning.code ?? ""
        if path.isEmpty && code.isEmpty { return nil }
        if path.isEmpty { return code }
        if code.isEmpty { return path }
        return "\(path) · \(code)"
    }
}
