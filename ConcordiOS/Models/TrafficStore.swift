import Foundation
import Combine

// MARK: - Traffic store (FlClash: Dashboard network-speed card + traffic)
// Backed by Concord traffic.watch (stream) / traffic.reset and
// probe.outboundIp / core.stats. In `.sample` mode the rates come from
// the mock snapshot with a small amount of jitter so the chart moves;
// the totals are the mock totals. Sample values are labelled in the UI.

struct TrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let up: Int64
    let down: Int64
}

final class TrafficStore: ObservableObject {
    @Published var current = ConcordTraffic(up: 0, down: 0, totalUp: 0, totalDown: 0)
    @Published var history: [TrafficPoint] = []
    @Published var outboundIp: String?
    @Published var outboundChains: [String] = []
    @Published var coreMemoryBytes: UInt64?
    @Published var services: [ConcordServiceItem] = []
    @Published var isProbingServices = false
    @Published var servicesError: String?
    /// The live engine status (engine.state): created / initialized /
    /// configured / running / failed, plus any services that failed
    /// to start. Read from the extension's engine.json snapshot.
    @Published var engineStatus: ConcordEngineStatus?
    @Published var engineStatusError: String?
    @Published var lastError: String?

    let client: ConcordClient
    private var timer: AnyCancellable?
    private let maxHistory = 60

    /// Consecutive refresh() failures (audit D9): one failed
    /// snapshot keeps the last values (a transient), but after 3
    /// in a row the core is really gone, so the live rates are
    /// zeroed instead of showing stale numbers forever. Totals
    /// are kept — they are cumulative counters, not live rates.
    private var consecutiveRefreshFailures = 0

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    var maxDown: Int64 { history.map { $0.down }.max() ?? 1 }
    var maxUp: Int64 { history.map { $0.up }.max() ?? 1 }

    func start() {
        stop()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                    // D11: the engine row rides the same 1 s tick
                    // as the traffic snapshot, otherwise it freezes
                    // after the first read.
                    await self?.refreshEngineStatus()
                }
            }
        Task { await refresh() }
        Task { await probe() }
        Task { await refreshMemory() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    @MainActor
    func refresh() async {
        do {
            var traffic = try await client.trafficSnapshot()
            if client.mode == .sample {
                // Sample mode: jitter the snapshot so the live chart moves.
                // The underlying snapshot is still the mock's fixed value.
                traffic = ConcordTraffic(
                    up: max(0, traffic.up + Int64.random(in: -20_000...40_000)),
                    down: max(0, traffic.down + Int64.random(in: -200_000...400_000)),
                    totalUp: traffic.totalUp,
                    totalDown: traffic.totalDown
                )
            }
            current = traffic
            history.append(TrafficPoint(date: Date(), up: traffic.up, down: traffic.down))
            if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
            consecutiveRefreshFailures = 0
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            consecutiveRefreshFailures += 1
            if consecutiveRefreshFailures >= 3 {
                // The core has been unreachable for 3 ticks: drop
                // the stale live rates (keep the cumulative totals).
                current = ConcordTraffic(up: 0, down: 0, totalUp: current.totalUp, totalDown: current.totalDown)
            }
        }
    }

    @MainActor
    func probe() async {
        do {
            let result = try await client.probeOutboundIp()
            outboundIp = result.body
            outboundChains = result.chains
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func refreshMemory() async {
        do {
            coreMemoryBytes = try await client.coreStats().rss
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reads the live engine status (engine.state). Latest-policy:
    /// the extension rewrites the snapshot whenever the state or
    /// its faults change.
    @MainActor
    func refreshEngineStatus() async {
        do {
            engineStatus = try await client.engineSnapshot()
            engineStatusError = nil
        } catch {
            engineStatus = nil
            engineStatusError = error.localizedDescription
        }
    }

    @MainActor
    func resetTotals() async {
        do {
            try await client.trafficReset()
            history.removeAll()
            current = ConcordTraffic(up: 0, down: 0, totalUp: 0, totalDown: 0)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Checks the known services (google, github, youtube, …) through
    /// one proxy (probe.services). The status strings are the core's
    /// contract ("available", "blocked", "restricted", "timeout",
    /// "failed", … — upstream crates/engine/src/probe/services.rs).
    @MainActor
    func probeServices(proxy: String) async {
        guard !isProbingServices else { return }
        isProbingServices = true
        defer { isProbingServices = false }
        do {
            services = try await client.probeServices(proxy: proxy)
            servicesError = nil
        } catch {
            servicesError = error.localizedDescription
        }
    }
}
