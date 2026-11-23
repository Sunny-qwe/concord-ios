import SwiftUI

// MARK: - MITM script notification banner (v0.2.86 item 4)
// Upstream FlClash v0.9.5-rs.1 lib/manager/core_manager.dart
// `_onScriptNotification` (399–417): a MITM script's
// `$notification.post` shows a banner with the text
// `脚本 <script>\n<title>\n<subtitle>\n<body>` (l10n_zh.dart:2755,
// only the non-empty parts), tappable only when `url` is a valid
// http(s) URL with a host — and the tap does NOT open directly:
// `dialogs.openUrl` (dialog.dart:276–287) first shows a confirm
// dialog (title `外部链接`, message = the full URL, confirm
// `前往`) and only opens after the user confirms.
//
// The banner itself is prism_ui's `BannerHost`
// (lib/application.dart:188–189, `stackedBanners: false` on
// mobile — one banner at a time, no queue), but prism_ui is a
// local plugin whose directory is EMPTY in this checkout
// (plugins/prism_ui has no files), so its exact visuals (top
// offset, auto-dismiss duration, slide-in animation, whether it
// can be swiped away) cannot be verified from rs.1 source. This
// host therefore follows our own card language (ConcordTheme
// cardBackground + the floating-tab-bar shadow) as a top banner
// — it does NOT claim to replicate prism_ui. Our own choices,
// marked as such: 8 s auto-dismiss, × button to close, a
// chevron affordance when tappable, no swipe-to-dismiss
// (upstream source does not show whether the banner can be
// swiped away).
//
// Behaviour IS 1:1: empty text is discarded, nothing shows while
// the app is not foreground (scenePhase != .active), arrivals
// within 1 s of the previous banner are dropped (upstream
// Throttler, 1 s, fire: true — first shows immediately, repeats
// dropped, not queued), and only the latest notification is kept
// (mobile never stacks). Detection lives in EventStore.refresh()
// (new `scriptNotification` entries after the first load); this
// file is only the host + the card.

/// The mount point — ContentView overlays exactly this at the
/// root (`.overlay(alignment: .top)`); the banner UI lives here,
/// NOT in ContentView.
struct ScriptNotificationBannerHost: View {
    @EnvironmentObject private var eventStore: EventStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Confirm-before-open dialog (upstream dialogs.openUrl).
    @State private var showLinkConfirm = false

    var body: some View {
        GeometryReader { geo in
            if scenePhase == .active,
               let notice = eventStore.pendingScriptNotification {
                bannerCard(notice)
                    .padding(.horizontal, 16)
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        // Auto-dismiss (OUR choice — prism_ui's
                        // duration is unverifiable; see the header).
                        // The task is keyed on the notice id, so a
                        // newer banner restarts the countdown and
                        // dismissing early cancels it.
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled,
                           eventStore.pendingScriptNotification?.id == notice.id {
                            eventStore.dismissScriptNotification()
                        }
                    }
                    .alert("外部链接", isPresented: $showLinkConfirm) {
                        Button("取消", role: .cancel) {}
                        Button("前往") {
                            if let link = notice.linkURL { openURL(link) }
                        }
                    } message: {
                        Text(notice.url)
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: eventStore.pendingScriptNotification)
    }

    /// The card itself. Tappable only when the URL is openable
    /// (upstream: onTap is null otherwise — the banner still
    /// shows, just not tappable). A plain tap gesture (not a
    /// Button) wraps the card so the × dismiss button inside it
    /// keeps its own tap.
    @ViewBuilder
    private func bannerCard(_ notice: ScriptNotificationItem) -> some View {
        bannerContent(notice)
            .onTapGesture {
                if notice.linkURL != nil { showLinkConfirm = true }
            }
    }

    private func bannerContent(_ notice: ScriptNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 16))
                .foregroundStyle(ConcordTheme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                // Upstream text, verbatim (l10n_zh.dart:2755):
                // `脚本 <script>` + the title/subtitle/body lines.
                Text("脚本 \(notice.script)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.label))
                Text(notice.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(4)
            }
            Spacer(minLength: 4)
            // Tappable affordance (OUR choice — upstream shows no
            // affordance in source; the confirm dialog already
            // shows the full URL before opening).
            if notice.linkURL != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, 4)
            }
            Button { eventStore.dismissScriptNotification() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}
