import Foundation
import Combine

// MARK: - DNS store (FlClash: DNS queries page)
// Backed by Concord dns.watch (stream of DnsEntry) and
// dns.clearCache.

final class DnsStore: ObservableObject {
    @Published var entries: [ConcordDnsEntry] = []
    @Published var searchText = ""
    @Published var lastError: String?
    @Published var lastActionMessage: String?

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var filtered: [ConcordDnsEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.domain.lowercased().contains(q)
                || $0.upstream.lowercased().contains(q)
                || $0.answers.contains { $0.lowercased().contains(q) }
        }
    }

    /// Cutoff for the broom (v0.2.68): entries at or before this
    /// `time` were cleared from the displayed list and must not
    /// come back on the next snapshot refresh. 0 = no clear yet.
    /// The core keeps its own DNS log (dns.watch returns the whole
    /// snapshot; there is no core-side clear), so the clear is a
    /// display cutoff, not a core wipe — queries after the clear
    /// still appear.
    private var clearedBeforeTime: Int64 = 0

    // v0.2.111: cap on the displayed list. The union merge in
    // refresh() never removed entries, so the array grew without
    // bound (the other stores cap at 200/500); the newest 500
    // match the extension / AppCore buffers.
    private static let maxEntries = 500

    /// Sequence counter for the sheet's ForEach identity
    /// (v0.2.111): `ConcordDnsEntry.id` is "\(time)-\(domain)-
    /// \(type)", so two identical queries in the same millisecond
    /// share one id. Each logical entry gets a sequence number on
    /// first sight, preserved across merges, and the sheet
    /// identifies rows by "\(id)-\(seq)". The stored entry.id
    /// itself is untouched — it stays the merge dictionary key,
    /// so the dedup is unchanged.
    private var nextSeq: UInt64 = 1

    /// v0.2.111 (DNS freeze, TOCTOU): while the DNS sheet is open,
    /// background refreshes fetch but do NOT publish — a publish
    /// landing mid-presentation is a freeze suspect. The check
    /// happens at publish time, not at call time, so a refresh
    /// already in flight when the user taps still defers. The
    /// newest result is held in pendingEntries and applied when
    /// the sheet closes (setPublishSuspended(false)). A
    /// user-initiated refresh inside the sheet passes force: true
    /// and publishes immediately.
    private var publishSuspended = false
    private var pendingEntries: [ConcordDnsEntry]?

    /// Sets the publish suspension (v0.2.111). Called by
    /// ContentView when the DNS sheet opens / closes. Clearing
    /// the suspension applies the newest deferred result, if any.
    @MainActor
    func setPublishSuspended(_ suspended: Bool) {
        publishSuspended = suspended
        if !suspended, let pending = pendingEntries {
            pendingEntries = nil
            entries = pending
        }
    }

    /// Clear the displayed record list (the broom in the DNS sheet
    /// header, MuYu cleaning_services). Entries at or before now
    /// are dropped and filtered out of later refreshes; new queries
    /// after the clear still appear. Does NOT clear the DNS cache
    /// (that is clearCache).
    @MainActor
    func clearEntries() {
        clearedBeforeTime = entries.map(\.time).max() ?? 0
        entries = []
        // v0.2.111: a deferred result must not resurrect the
        // cleared records when the sheet closes.
        pendingEntries = nil
        lastActionMessage = "记录已清除"
        lastError = nil
    }

    /// A user-initiated refresh (pull-to-refresh inside the DNS
    /// sheet, or the page's toolbar button) bypasses the publish
    /// suspension — it must still work while the sheet is open.
    /// Background refreshes (the Dashboard appear / tunnel-flip
    /// calls) use the default and defer while suspended.
    @MainActor
    func refresh(force: Bool = false) async {
        do {
            // v0.2.102 (MuYu parity): the query history no longer
            // comes from the extension snapshot only. Tunnel up →
            // the extension snapshot, as before. Tunnel down → the
            // in-app core's accumulated dns.watch buffer (runDns
            // boots it on demand; the Dashboard / ContentView
            // lifecycle keeps it running while the app is in the
            // foreground, like MuYu's startCore at launch), so the
            // Dashboard DNS count and the sheet show records with
            // the VPN off instead of 0. The merge below is
            // identical for both sources.
            let fresh = try await runDns(
                tunnel: { try await self.client.dnsEntries() },
                appCore: {
                    // Lazily (re-)subscribe if the boot-time
                    // subscribe failed or the session restarted
                    // since — same as LogStore.refresh; a no-op
                    // when a sub already exists.
                    if AppCore.shared.isRunning {
                        try? await AppCore.shared.subscribeDnsWatch()
                    }
                    return await AppCore.shared.dnsEntries()
                })
            let cutoff = clearedBeforeTime
            let visible = cutoff > 0 ? fresh.filter { $0.time > cutoff } : fresh
            // v0.2.111: same merge as before, but each logical
            // entry keeps a stable sequence number — a fresh
            // snapshot entry with an id already in the store
            // inherits the stored entry's seq, a genuinely new
            // entry gets the next one — so the sheet's
            // "\(id)-\(seq)" ForEach identity is unique AND
            // stable across refreshes.
            var merged: [String: ConcordDnsEntry] = [:]
            for entry in entries { merged[entry.id] = entry }
            for entry in visible {
                var freshEntry = entry
                if let old = merged[entry.id] {
                    freshEntry.seq = old.seq
                } else {
                    freshEntry.seq = nextSeq
                    nextSeq += 1
                }
                merged[entry.id] = freshEntry
            }
            // v0.2.111: cap at the newest 500 (see maxEntries).
            let sorted = Array(merged.values.sorted { $0.time > $1.time }.prefix(Self.maxEntries))
            if publishSuspended && !force {
                pendingEntries = sorted
            } else {
                pendingEntries = nil
                entries = sorted
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func clearCache() async {
        do {
            try await runDns(
                tunnel: { try await self.client.dnsClearCache() },
                appCore: { try await AppCore.shared.dnsClearCache() })
            lastActionMessage = "DNS 缓存已清除"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs one DNS action against the tunnel core when it is up, or
    /// the in-app core (booted on demand) when the VPN is off (audit
    /// B16). If the tunnel starts while AppCore is booting, AppCore
    /// refuses to run alongside it (AppCoreError.tunnelRunning) —
    /// the tunnel core is used instead, not reported as a failure.
    private func runDns<T>(tunnel: () async throws -> T, appCore: () async throws -> T) async throws -> T {
        if hasCore {
            return try await tunnel()
        }
        do {
            try await AppCore.shared.ensureStarted()
        } catch {
            if case AppCoreError.tunnelRunning = error {
                return try await tunnel()
            }
            throw error
        }
        return try await appCore()
    }

    /// True when the DNS tools can reach the tunnel core: the tunnel
    /// is running, or the client is in sample mode. With the VPN off
    /// in live mode the in-app core (AppCore, booted on demand by
    /// runDns) is the fallback (audit B16) — and since v0.2.102
    /// the query history (refresh/dns.watch) uses that fallback
    /// too, via AppCore's accumulated dns.watch buffer, so DNS
    /// records exist with the VPN off like MuYu.
    private var hasCore: Bool {
        client.mode == .sample || TunnelManager.shared.isRunning
    }
}
