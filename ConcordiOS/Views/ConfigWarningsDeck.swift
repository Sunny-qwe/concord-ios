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

// MARK: - Live status deck (FlClash v0.9.5-rs.1, item 12 / D-51)
//
// Upstream: lib/views/dashboard/widgets/live_status_deck.dart
// (LiveStatusDeck) and lib/views/dashboard/widgets/live_status.dart
// (LiveStatusButton + the status models). One sheet, one card per
// live status, in upstream's order: core disconnected/connecting
// first, update ready/downloading, MITM consent, warnings, core
// running last. Each card is a tinted hero (icon circle), title,
// body, and action button. The 3D flip-stack animation of
// upstream's deck is NOT reproduced — this is a plain scrollable
// sheet with one card per status.
//
// This replaces the split presentation (warnings pill ->
// ConfigWarningsDeck plus the pinned pendingModulesCard):
// warnings and MITM consent are entries here, and so is update
// status. ConfigWarningsDeck itself is unchanged — DeveloperView
// still uses it for the live-status preview sheet — the warnings
// entry here wraps it in the same card frame as the other entries.
//
// The restart-core confirm alert lives inside the deck: the
// presenter passes onRestartCore (stop, wait, start) and the deck
// asks before running it.

/// What the deck needs to know about update status. Nil update
/// (in the deck's `update` param) means no update entry at all —
/// not new and not checking. The message is the latest commit
/// message; the sha/date stay in AppStorage for the About page.
struct LiveStatusUpdateInfo {
    let isNew: Bool
    let isChecking: Bool
    let message: String?
}

struct LiveStatusDeck: View {
    enum CorePhase {
        case running
        case starting
        case stopped
    }

    let corePhase: CorePhase
    let coreError: String?
    let warnings: [ConcordWarning]
    let update: LiveStatusUpdateInfo?
    /// Names of MITM modules awaiting consent, in prompt order.
    /// Empty means no MITM entry.
    let mitmPending: [String]
    let onStartCore: () -> Void
    let onRestartCore: () -> Void
    let onReviewMitm: () -> Void
    let onOpenReleases: () -> Void
    let onCheckUpdate: () -> Void

    @State private var showRestartConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if corePhase != .running { coreCard }
                if let update { updateCard(update) }
                if !mitmPending.isEmpty { mitmCard }
                if !warnings.isEmpty { warningsCard }
                if corePhase == .running { coreCard }
            }
            .padding(16)
        }
        .alert("重启核心", isPresented: $showRestartConfirm) {
            Button("重启", role: .destructive) { onRestartCore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启核心会断开当前连接，确定继续吗？")
        }
    }

    /// Each phase wears a different action (restart / none /
    /// start), so the branches are different LiveStatusCard
    /// instantiations — @ViewBuilder erases them into one type.
    @ViewBuilder
    private var coreCard: some View {
        switch corePhase {
        case .running:
            LiveStatusCard(tint: .green, icon: "checkmark.circle.fill", title: "核心运行中", bodyText: "核心正在运行。") {
                Button { showRestartConfirm = true } label: {
                    Text("重启核心").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        case .starting:
            LiveStatusCard(tint: .blue, icon: "arrow.triangle.2.circlepath", title: "核心启动中", bodyText: "核心正在启动，请稍候。") {
                EmptyView()
            }
        case .stopped:
            LiveStatusCard(tint: .secondary, icon: "power", title: "核心已停止", bodyText: coreError ?? "核心未运行。") {
                Button(action: onStartCore) {
                    Text("启动核心").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Checking wears no action, a new version wears two buttons
    /// — different LiveStatusCard instantiations, so @ViewBuilder
    /// (as on coreCard above).
    @ViewBuilder
    private func updateCard(_ update: LiveStatusUpdateInfo) -> some View {
        if update.isChecking {
            LiveStatusCard(tint: .blue, icon: "arrow.down.circle", title: "正在检查更新", bodyText: "正在检查是否有新版本…") {
                EmptyView()
            }
        } else {
            LiveStatusCard(tint: .blue, icon: "arrow.down.circle.fill", title: "有新版本可用", bodyText: update.message ?? "发现新版本。") {
                HStack(spacing: 10) {
                    Button(action: onOpenReleases) {
                        Text("查看发布").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onCheckUpdate) {
                        Text("重新检查").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var mitmCard: some View {
        let bodyText: String
        if mitmPending.count == 1 {
            bodyText = "「\(mitmPending[0])」请求开启 MITM 拦截。"
        } else {
            bodyText = "「\(mitmPending[0])」等 \(mitmPending.count) 个模块请求开启 MITM 拦截。"
        }
        return LiveStatusCard(tint: .purple, icon: "shield.fill", title: "MITM 待确认", bodyText: bodyText) {
            Button(action: onReviewMitm) {
                Text("查看并确认").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// The warnings entry is ConfigWarningsDeck itself in the
    /// shared card frame — its own header (icon + "配置警告" +
    /// count) is the card hero, so it is not wrapped in a
    /// LiveStatusCard as well.
    private var warningsCard: some View {
        ConfigWarningsDeck(warnings: warnings)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}

/// One live-status card: tinted hero (icon circle), title, body,
/// and the presenter's action buttons underneath.
private struct LiveStatusCard<Actions: View>: View {
    let tint: Color
    let icon: String
    let title: String
    let bodyText: String
    let actions: () -> Actions

    init(tint: Color, icon: String, title: String, bodyText: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.tint = tint
        self.icon = icon
        self.title = title
        self.bodyText = bodyText
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(bodyText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}
