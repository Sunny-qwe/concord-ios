import Foundation
import Combine

// MARK: - DNS store (FlClash: DNS queries page)
// Backed by Concord dns.watch (stream of DnsEntry), dns.query,
// dns.clearCache and dns.flushFakeIp.

final class DnsStore: ObservableObject {
    @Published var entries: [ConcordDnsEntry] = []
    @Published var searchText = ""
    @Published var lastError: String?
    @Published var lastActionMessage: String?
    @Published var queriedResult: ConcordDnsQueryResult?
    @Published var queryError: String?

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

    /// Publishing suspended while the DNS stats sheet is
    /// presenting (v0.2.102): the Dashboard appear task checks
    /// statsDestination before starting a refresh, but a refresh
    /// already in flight when the user taps still publishes
    /// mid-presentation — and a publish landing during the sheet
    /// presentation is what wedged the List. Dropping that one
    /// publish is safe: the next refresh picks the entries up.
    /// Set on the stats-cell tap, cleared when the sheet finishes
    /// presenting (DnsQueriesView.onAppear, 0.6s) or when the
    /// sheet dismisses (DashboardView.onChange). Main-thread only:
    /// refresh() runs on the main actor and the tap / onAppear /
    /// onChange all run on the main thread, so the guard in
    /// refresh() is correctly ordered against the tap. Deliberately
    /// NOT @MainActor (the onAppear unsuspend runs from a plain
    /// DispatchQueue.main.asyncAfter closure, which cannot call a
    /// main-actor method).
    private var publishSuspended = false

    func setPublishSuspended(_ suspended: Bool) {
        publishSuspended = suspended
    }

    /// Clear the displayed record list (the broom in the DNS sheet
    /// header, MuYu cleaning_services). Entries at or before now
    /// are dropped and filtered out of later refreshes; new queries
    /// after the clear still appear. Does NOT clear the DNS cache
    /// (that is clearCache) or the Fake-IP mappings.
    @MainActor
    func clearEntries() {
        clearedBeforeTime = entries.map(\.time).max() ?? 0
        entries = []
        lastActionMessage = "记录已清除"
        lastError = nil
    }

    @MainActor
    func refresh() async {
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
            // v0.2.102: a refresh that was already in flight when
            // the DNS sheet opened must not publish mid-presentation
            // (see publishSuspended) — drop it; the next refresh
            // picks the entries up.
            guard !publishSuspended else { return }
            let cutoff = clearedBeforeTime
            let visible = cutoff > 0 ? fresh.filter { $0.time > cutoff } : fresh
            // v0.2.101 (Issue 2): build the merge dictionary with
            // a loop, not Dictionary(uniqueKeysWithValues:) — that
            // traps on a duplicate key, and `id` is only
            // "\(time)-\(domain)-\(type)" (ConcordClient.swift:683),
            // so two identical queries in the same millisecond
            // share one id. Last write wins, fresh snapshot entries
            // overwriting older ones, exactly as before.
            var merged: [String: ConcordDnsEntry] = [:]
            for entry in entries { merged[entry.id] = entry }
            for entry in visible { merged[entry.id] = entry }
            entries = merged.values.sorted { $0.time > $1.time }
            lastError = nil
        } catch {
            // v0.2.102: same as above — do not publish an error
            // into the sheet mid-presentation either.
            guard !publishSuspended else { return }
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

    @MainActor
    func flushFakeIp() async {
        do {
            try await runDns(
                tunnel: { try await self.client.dnsFlushFakeIp() },
                appCore: { try await AppCore.shared.dnsFlushFakeIp() })
            lastActionMessage = "Fake-IP 映射已清除"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs one query through the core's resolver (dns.query) and keeps
    /// the full answer for the query box.
    @MainActor
    func query(name: String, qtype: String) async {
        let host = name.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            queryError = "请输入要查询的域名"
            return
        }
        do {
            queriedResult = try await runDns(
                tunnel: { try await self.client.dnsQuery(name: host, qtype: qtype) },
                appCore: { try await AppCore.shared.dnsQuery(name: host, qtype: qtype) })
            queryError = nil
        } catch {
            queriedResult = nil
            queryError = error.localizedDescription
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
