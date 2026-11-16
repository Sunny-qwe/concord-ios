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
            try await client.dnsClearCache()
            lastActionMessage = "DNS 缓存已清除"
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func flushFakeIp() async {
        do {
            try await client.dnsFlushFakeIp()
            lastActionMessage = "Fake-IP 映射已清除"
        } catch {
            lastError = error.localizedDescription
        }
    }
}
