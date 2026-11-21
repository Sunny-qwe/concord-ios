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

/// One node's live up/down rates in bytes/s (MuYu `Traffic` as
/// sampled by `ExternalTrafficSampler`: per-connection byte deltas
/// over the sample interval, attributed to every name in the
/// connection's chain).
struct NodeSpeed {
    let up: Double
    let down: Double

    static let zero = NodeSpeed(up: 0, down: 0)
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
    /// Live up/down per proxy and group name (MuYu
    /// nodeSpeedsProvider), from the same snapshots as the
    /// dashboard speeds. A reader takes the selected node's entry,
    /// or zero when nothing flows through it; the map keeps its
    /// last values while the tunnel is down, so a reader checks
    /// `isRunning` itself.
    @Published var nodeSpeeds: [String: NodeSpeed] = [:]
    /// Per-connection last-seen byte counts behind the sampler
    /// (MuYu ExternalTrafficSampler._nodeSeen). A connection first
    /// seen here is only a baseline; its bytes so far would
    /// otherwise read as one second's spike.
    private var nodeSeen: [UInt64: (upload: Int64, download: Int64)] = [:]
    private var nodeSeenAt: Date?
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
                    // The per-node speeds ride the same 1 s tick as
                    // the traffic snapshot (MuYu updateTraffic).
                    await self?.refreshNodeSpeeds()
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

    /// Samples the per-node live speeds (MuYu
    /// ExternalTrafficSampler._updateNodeSpeeds,
    /// lib/core/external_controller.dart:56-103, ported verbatim):
    /// each live connection's byte deltas since the last sample,
    /// divided by the elapsed seconds, attributed to every name in
    /// the connection's chain. The data source is the core's
    /// connection.watch snapshot — ConcordConnection carries the
    /// cumulative upload/download counters and the exit chain, so
    /// no new core API was needed. On the first sample the
    /// connections are baselines only (no speeds); a stale snapshot
    /// while the tunnel is down throws and the last map is kept —
    /// the UI shows zeros while not running anyway. This touches
    /// only the connections snapshot; the delay test uses
    /// test_delay / delay.run.poll and is unaffected.
    @MainActor
    func refreshNodeSpeeds() async {
        do {
            let snapshot = try await client.connectionSnapshot()
            let now = Date()
            let previousAt = nodeSeenAt
            nodeSeenAt = now
            guard let previousAt else {
                for c in snapshot.connections {
                    nodeSeen[c.connectionId] = (c.upload ?? 0, c.download ?? 0)
                }
                return
            }
            let elapsed = now.timeIntervalSince(previousAt)
            guard elapsed > 0 else { return }
            var speeds: [String: NodeSpeed] = [:]
            var currentIds = Set<UInt64>()
            for c in snapshot.connections {
                currentIds.insert(c.connectionId)
                let previous = nodeSeen[c.connectionId]
                nodeSeen[c.connectionId] = (c.upload ?? 0, c.download ?? 0)
                guard let previous else { continue }
                let upDelta = (c.upload ?? 0) - previous.upload
                let downDelta = (c.download ?? 0) - previous.download
                guard upDelta > 0 || downDelta > 0 else { continue }
                let up = upDelta > 0 ? Double(upDelta) / elapsed : 0
                let down = downDelta > 0 ? Double(downDelta) / elapsed : 0
                for name in Set(c.chains ?? []) {
                    let current = speeds[name] ?? .zero
                    speeds[name] = NodeSpeed(up: current.up + up, down: current.down + down)
                }
            }
            nodeSeen = nodeSeen.filter { currentIds.contains($0.key) }
            nodeSpeeds = speeds
        } catch {
            // Stale snapshot while the tunnel is down
            // (connection.watch throws past its 10 s max-age):
            // keep the last map.
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
