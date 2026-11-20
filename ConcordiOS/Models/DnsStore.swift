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

    @MainActor
    func refresh() async {
        do {
            let fresh = try await client.dnsEntries()
            var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for entry in fresh { merged[entry.id] = entry }
            entries = merged.values.sorted { $0.time > $1.time }
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
    /// runDns) is the fallback (audit B16). The query history
    /// (refresh/dns.watch) still comes from the extension snapshot
    /// only: it has no AppCore equivalent.
    private var hasCore: Bool {
        client.mode == .sample || TunnelManager.shared.isRunning
    }
}
