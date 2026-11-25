import Foundation
import Combine

// MARK: - Event store (core events feed)
// Backed by Concord events.watch (stream of CoreEvent). The
// extension accumulates events into the App Group snapshot file
// (cap 500) because the app only reads it when the Events tab is
// opened; the file IS the buffer. CoreEvent has no id, so rows are
// keyed by a content hash (see `key(for:)`).
//
// Event kinds (upstream crates/proto/src/types/live.rs CoreEvent):
// resourceUpdate (provider update, phase updating/updated/failed/
// unchanged), dialerLoop, delay, fatal, stateChanged.
//
// Timestamps: CoreEvent carries NO timestamp of its own (the core
// sends no time field), so the store stamps each event with the
// time the app first saw it (`receivedAt`) and keeps it across
// refreshes by merging on a content key. Two events with identical
// content share one row (they are the same event re-read); a
// stateChanged event's `change` payload is not part of the key.
// Sample data is stamped the same way, so the rows look right in
// sample mode too.

/// One core event with the time the app first saw it.
struct StampedCoreEvent: Identifiable {
    var id: String { key }
    let key: String
    let event: ConcordCoreEvent
    let receivedAt: Date

    /// Epoch millis for ConcordFormat.time (same "HH:mm:ss" column
    /// as the log rows).
    var receivedAtMillis: Int64 { Int64(receivedAt.timeIntervalSince1970 * 1000) }
}

/// One MITM script `$notification.post` ready to show as a top
/// banner (v0.2.86 item 4, upstream lib/core/api/dto.dart
/// `ScriptNotificationEvent`: ONLY script / title / subtitle /
/// body / url — the core's extra `at` / `connection` / `exchange`
/// fields are NOT part of the banner). `text` is the non-empty
/// parts of title, subtitle, body joined with "\n" (upstream
/// `ScriptNotificationEvent.text`).
struct ScriptNotificationItem: Identifiable, Equatable {
    /// Content key (EventStore.key(for:)) — the same notification
    /// re-read from the snapshot is the same item, never re-shown.
    let id: String
    let script: String
    let text: String
    let url: String

    /// Upstream core_manager.dart `scriptNotificationLink`: only
    /// http/https URLs with a non-empty host are openable; anything
    /// else makes the banner non-tappable (it still shows).
    var linkURL: URL? {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return nil }
        return parsed
    }
}

final class EventStore: ObservableObject {
    @Published var entries: [StampedCoreEvent] = []
    @Published var searchText = ""
    @Published var typeFilter = "全部"
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    /// The newest unread script notification to show as a banner,
    /// or nil when there is none (v0.2.86 item 4; upstream mobile
    /// never stacks banners — application.dart
    /// `stackedBanners: !isMobileView` — so only the latest is
    /// kept, never a queue).
    @Published var pendingScriptNotification: ScriptNotificationItem?
    /// Last time a banner was shown (upstream Throttler, 1 s,
    /// fire: true — the first call shows immediately, repeats
    /// within 1 s are dropped, not queued).
    private var lastScriptNotificationShownAt: Date?
    /// The first refresh() only establishes the baseline: events
    /// already in the snapshot at launch are history, not new
    /// arrivals — upstream's feed is a live stream, so a banner
    /// must only fire for notifications that arrive AFTER the
    /// first load.
    private var eventsBaselineLoaded = false
    /// refresh() is now called from the 1 s tick AND from
    /// Dashboard / LogsView — guard against overlapping runs (the
    /// merge is idempotent, but a fresh event seen by two concurrent
    /// runs would banner twice).
    private var refreshInFlight = false

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var eventTypes: [String] {
        var types = ["全部"]
        types.append(contentsOf: Set(entries.map { $0.event.type }).sorted())
        return types
    }

    var filtered: [StampedCoreEvent] {
        entries.filter { entry in
            let typeOK = typeFilter == "全部" || entry.event.type == typeFilter
            let textOK = searchText.isEmpty
                || entry.event.summary.localizedCaseInsensitiveContains(searchText)
            return typeOK && textOK
        }
    }

    /// Content key for merge/dedupe. `change` is excluded (see the
    /// header comment); `seq` identifies stateChanged events. The
    /// script-notification fields are included: two notifications
    /// with the same title from different connections or exchanges
    /// are different rows (upstream 0c9788f adds `at` / `connection`
    /// / `exchange` to scriptNotification).
    private static func key(for event: ConcordCoreEvent) -> String {
        // Built with appends, not one big array literal: a 17-element
        // literal made the type-checker time out (CI run 44994989058).
        var parts: [String] = []
        parts.append(event.type)
        parts.append(event.kind ?? "")
        parts.append(event.name ?? "")
        parts.append(event.phase ?? "")
        parts.append(event.error ?? "")
        parts.append(event.url ?? "")
        parts.append(event.value.map(String.init) ?? "")
        parts.append(event.message ?? "")
        parts.append(event.seq.map(String.init) ?? "")
        parts.append(event.origin ?? "")
        parts.append(event.script ?? "")
        parts.append(event.title ?? "")
        parts.append(event.subtitle ?? "")
        parts.append(event.body ?? "")
        parts.append(event.at.map(String.init) ?? "")
        parts.append(event.connection.map(String.init) ?? "")
        parts.append(event.exchange.map(String.init) ?? "")
        return parts.joined(separator: "|")
    }

    /// Dismiss the pending script-notification banner (× button,
    /// auto-dismiss, or the app leaving the foreground — upstream
    /// only shows while resumed).
    @MainActor
    func dismissScriptNotification() {
        pendingScriptNotification = nil
    }

    @MainActor
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        do {
            // v0.2.115: the events no longer come from the extension
            // snapshot only. Tunnel up → the extension snapshot, as
            // before. Tunnel down → the in-app core's live
            // events.watch buffer (AppCore boots it on demand; the
            // Dashboard / Logs lifecycle keeps it running while the
            // app is in the foreground, like MuYu's startCore at
            // launch), so the Dashboard 最近请求 count and the
            // Events page show rows with the VPN off instead of 0.
            // The merge below is identical for both sources — and
            // key-based, so an event seen from the in-app core is
            // never double-counted when the same event later
            // arrives in the extension snapshot.
            let fresh = try await runEvents(
                tunnel: { try await self.client.eventEntries() },
                appCore: {
                    // Lazily (re-)subscribe if the boot-time
                    // subscribe failed or the session restarted
                    // since — same as DnsStore.refresh; a no-op
                    // when a sub already exists.
                    if AppCore.shared.isRunning {
                        try? await AppCore.shared.subscribeEventsWatch()
                    }
                    return await AppCore.shared.eventEntries()
                })
            let now = Date()
            var byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
            // New script notifications seen in this refresh (v0.2.86
            // item 4): only entries the store has never seen before
            // can banner — a re-read of the snapshot is not new.
            var newNotices: [ConcordCoreEvent] = []
            for event in fresh {
                let key = Self.key(for: event)
                if byKey[key] == nil {
                    byKey[key] = StampedCoreEvent(key: key, event: event, receivedAt: now)
                    if event.type == "scriptNotification" {
                        newNotices.append(event)
                    }
                }
            }
            // Keep only events still in the latest buffer (the
            // extension drops old ones past its 500 cap), oldest
            // first; drop anything past the cap the same way.
            let freshKeys = Set(fresh.map { Self.key(for: $0) })
            var merged = byKey.values.filter { freshKeys.contains($0.key) }
            merged.sort { $0.receivedAt < $1.receivedAt }
            if merged.count > 500 { merged.removeFirst(merged.count - 500) }
            entries = merged
            lastUpdated = Date()
            lastError = nil
            // Script-notification banner (upstream
            // core_manager.dart `_onScriptNotification`): discard
            // when the text is empty; several arrivals in one
            // refresh show only the newest one (mobile never
            // stacks); arrivals within 1 s of the previous banner
            // are dropped, not queued (upstream Throttler, 1 s,
            // fire: true). The foreground gate lives in the banner
            // host (scenePhase == .active) — the poll only runs
            // while the app is active anyway (TrafficStore stops
            // its tick in the background).
            if eventsBaselineLoaded, let notice = newNotices.last {
                var parts: [String] = []
                if let title = notice.title, !title.isEmpty { parts.append(title) }
                if let subtitle = notice.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
                if let body = notice.body, !body.isEmpty { parts.append(body) }
                let text = parts.joined(separator: "\n")
                if !text.isEmpty {
                    let throttled = lastScriptNotificationShownAt.map { now.timeIntervalSince($0) < 1 } ?? false
                    if !throttled {
                        pendingScriptNotification = ScriptNotificationItem(
                            id: Self.key(for: notice),
                            script: notice.script ?? "",
                            text: text,
                            url: notice.url ?? ""
                        )
                        lastScriptNotificationShownAt = now
                    }
                }
            }
            eventsBaselineLoaded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs one events query against the tunnel core when it is up,
    /// or the in-app core (booted on demand) when the VPN is off —
    /// same shape as DnsStore.runDns. The in-app core's live
    /// events.watch buffer is the only live source with the VPN
    /// off, so the Dashboard 最近请求 count and the Events page
    /// show rows instead of 0. The ensureStarted call is skipped
    /// when the core is already running: its early-return path
    /// walks the whole provider cache (reads every file to compare
    /// bytes) — pointless work on a hot path. If the tunnel starts
    /// while AppCore is booting, AppCore refuses to run alongside
    /// it (AppCoreError.tunnelRunning) — the tunnel core is used
    /// instead, not reported as a failure.
    private func runEvents<T>(tunnel: () async throws -> T, appCore: () async throws -> T) async throws -> T {
        if hasCore {
            return try await tunnel()
        }
        if !AppCore.shared.isRunning {
            do {
                try await AppCore.shared.ensureStarted()
            } catch {
                if case AppCoreError.tunnelRunning = error {
                    return try await tunnel()
                }
                throw error
            }
        }
        return try await appCore()
    }

    /// True when the events query can reach the tunnel core: the
    /// tunnel is running, or the client is in sample mode. With
    /// the VPN off in live mode the in-app core (AppCore, booted
    /// on demand by runEvents) is the fallback.
    private var hasCore: Bool {
        client.mode == .sample || TunnelManager.shared.isRunning
    }
}
