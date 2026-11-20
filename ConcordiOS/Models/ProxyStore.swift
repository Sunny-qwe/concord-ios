import Foundation
import Combine

// MARK: - Proxy store (FlClash: Proxies page)
// Backed by Concord proxy.groups / proxy.select / delay.test.
// In `.sample` mode the groups come from ConcordSampleData via
// ConcordClient; in `.live` mode they come from the real core.

struct ProxyNode: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let provider: String?
    var latencyMs: Int32?
}

struct ProxyGroup: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    var nodes: [ProxyNode]
    var selectedNodeName: String?
    var testUrl: String
    /// Manual override for url-test / fallback groups (Clash
    /// `fixed`): the node pinned as 首选； nil/"" = the pick is
    /// computed by the group itself.
    var fixed: String?
    /// Group icon from the profile (URL or short text); "" = none,
    /// the list header falls back to the name's first character.
    var icon: String
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    @Published var groups: [ProxyGroup] = []
    @Published var latencies: [String: Int32] = [:]
    /// Group names with a delay test in flight (per-group spinners).
    @Published var testingGroups: Set<String> = []
    /// True while any delay test runs.
    var isTesting: Bool { !testingGroups.isEmpty }
    /// True while the group list itself is loading (first load).
    @Published var isLoading = false
    @Published var lastError: String?
    /// The reason the last VPN start attempt failed, if it failed.
    /// Kept apart from lastError (which refresh/select also write)
    /// so the Dashboard can show exactly why the play button did
    /// nothing: start() can throw in prepare()/startVPNTunnel()
    /// before the status ever leaves .disconnected, so without this
    /// the card shows no spinner and no banner — just silence.
    @Published var startError: String?
    @Published var lastUpdated: Date?

    /// True when the group list on screen comes from the active
    /// profile's LOCAL YAML instead of the core (VPN off — the core
    /// has no config loaded, so proxy.watch/proxy.groups are empty).
    /// The Proxies page shows a small "本地配置" note while this is
    /// set. Delay tests still work while off: they run on the
    /// app-side core (AppCore, v0.2.32).
    @Published var isLocalFallback = false

    /// The profile store, linked by the app at startup (ConcordiOSApp):
    /// the local fallback reads the active profile's YAML through it.
    weak var profileStore: ProfileStore?

    /// Node selections made while the VPN is off, persisted per
    /// profile in UserDefaults as {profileID: {group: proxy}}.
    /// Applied to the core by refresh() once it is reachable again.
    /// Every successful live selection is recorded here too, so the
    /// local fallback keeps showing the same pick after the tunnel
    /// stops. The value is the proxy.select argument: a node name,
    /// or "" to clear a url-test/fallback pin.
    private let pendingSelectionsKey = "concord.pendingSelections"

    private func loadPendingSelections() -> [String: [String: String]] {
        guard let data = UserDefaults.standard.data(forKey: pendingSelectionsKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return decoded
    }

    private func savePendingSelections(_ all: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: pendingSelectionsKey)
        }
    }

    /// The remembered selection for one group, if any.
    func pendingSelection(profileID: UUID, group: String) -> String? {
        loadPendingSelections()[profileID.uuidString]?[group]
    }

    private func savePendingSelection(profileID: UUID, group: String, proxy: String) {
        var all = loadPendingSelections()
        all[profileID.uuidString, default: [:]][group] = proxy
        savePendingSelections(all)
    }

    private func dropPendingSelection(profileID: UUID, group: String) {
        var all = loadPendingSelections()
        all[profileID.uuidString]?.removeValue(forKey: group)
        if all[profileID.uuidString]?.isEmpty == true {
            all.removeValue(forKey: profileID.uuidString)
        }
        savePendingSelections(all)
    }

    let client: ConcordClient
    private var cancellables = Set<AnyCancellable>()

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        // In live mode the running state follows the system VPN, so a
        // disconnect from outside the app (e.g. iOS Settings) is
        // reflected here too.
        TunnelManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.client.mode == .live else { return }
                self.isRunning = status == .connected || status == .connecting || status == .reasserting
            }
            .store(in: &cancellables)
    }

    var selectedOutbound: String? {
        groups.first { $0.name == "GLOBAL" }?.selectedNodeName
            ?? groups.first?.selectedNodeName
    }

    var allNodes: [ProxyNode] {
        groups.flatMap { $0.nodes }
    }

    @MainActor
    func refresh(activeProfile: Profile? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await fetchCoreGroups()
            lastUpdated = Date()
            lastError = nil
            isLocalFallback = false
            // A selection made while the VPN was off is remembered in
            // UserDefaults; now that the core is reachable, apply it.
            if let profileID = activeProfile?.id {
                await applyPendingSelections(profileID: profileID)
            }
        } catch {
            // Core unreachable (VPN off): fall back to the active
            // profile's local YAML so the Proxies page still shows
            // the subscription's groups and nodes. The live path
            // above is untouched — this runs only when both core
            // reads throw.
            if let profile = activeProfile,
               let local = profileStore?.localProxyGroups(for: profile),
               loadLocalGroups(local, profileID: profile.id) {
                lastUpdated = Date()
                lastError = nil
                return
            }
            lastError = error.localizedDescription
            isLocalFallback = false
        }
    }

    /// One core read (proxy.watch snapshot, fallback proxy.groups),
    /// shared by refresh() and the post-apply re-fetch. An empty
    /// result (no groups at all) is treated as a failure, not as a
    /// real answer: a core that loaded the profile always has its
    /// groups, so zero groups means the snapshot was stale/empty or
    /// the core has not finished applying — the caller then falls
    /// back to the local YAML instead of showing an empty page
    /// (v0.2.32: the v0.2.31 "节点也看不见" report).
    private func fetchCoreGroups() async throws {
        // proxy.watch is the live table: the extension subscribes
        // once at startup and rewrites snapshots/proxies.json on
        // every change, so this is fresher than a one-shot
        // proxy.groups call. Fall back to proxy.groups when the
        // snapshot file is missing (tunnel never subscribed yet).
        let result: ConcordProxyGroups
        do {
            result = try await client.proxyWatchSnapshot()
        } catch {
            result = try await client.proxyGroups()
        }
        guard !result.groups.isEmpty else {
            throw ConcordClientError.transport("核心未返回策略组（快照为空）")
        }
        let nodeTypes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.name, $0) })
        groups = result.groups.filter { !$0.hidden }.map { g in
            ProxyGroup(
                name: g.name,
                type: g.type,
                nodes: (g.all ?? []).map { name in
                    let info = nodeTypes[name]
                    return ProxyNode(name: name, type: info?.type ?? "unknown", provider: info?.provider, latencyMs: latencies[name])
                },
                selectedNodeName: g.now,
                testUrl: g.testUrl,
                fixed: g.fixed,
                icon: g.icon
            )
        }
    }

    /// Build the group list from the local parse. Returns false when
    /// the parse has no groups at all (caller keeps the core error).
    /// The remembered selection (if any) becomes the group's `now` /
    /// `fixed`, so the pick the user made while off survives a
    /// restart. No latency data exists offline — nodes show no delay.
    private func loadLocalGroups(_ local: ProfileStore.LocalProxyGroups, profileID: UUID) -> Bool {
        guard !local.groups.isEmpty else { return false }
        let typeByName = Dictionary(uniqueKeysWithValues: local.nodes.map { ($0.name, $0.type) })
        groups = local.groups.map { g in
            let pending = pendingSelection(profileID: profileID, group: g.name)
            return ProxyGroup(
                name: g.name,
                type: g.type,
                nodes: g.nodeNames.map { name in
                    ProxyNode(name: name, type: typeByName[name] ?? localBuiltinType(name), provider: nil, latencyMs: nil)
                },
                selectedNodeName: g.type == "select" ? pending : nil,
                testUrl: g.testURL,
                fixed: g.type == "select" ? nil : pending,
                icon: ""
            )
        }
        isLocalFallback = true
        return true
    }

    /// Built-in pseudo-proxies keep their type offline; anything else
    /// the file does not declare is "unknown" (the live path does the
    /// same for nested-group members).
    private func localBuiltinType(_ name: String) -> String {
        switch name {
        case "DIRECT", "REJECT", "REJECT-DROP", "PASS":
            return name
        default:
            return "unknown"
        }
    }

    /// Apply remembered off-VPN selections to the now-reachable core.
    /// Entries for groups the core no longer has are dropped; entries
    /// the core rejects are kept for the next refresh instead of
    /// dropping the user's choice. A re-fetch follows when anything
    /// changed, so `now`/`fixed` show what the core actually picked.
    private func applyPendingSelections(profileID: UUID) async {
        let pendings = loadPendingSelections()[profileID.uuidString] ?? [:]
        guard !pendings.isEmpty else { return }
        var changed = false
        for (groupName, proxy) in pendings {
            guard groups.contains(where: { $0.name == groupName }) else {
                dropPendingSelection(profileID: profileID, group: groupName)
                continue
            }
            do {
                let result = try await client.proxySelect(group: groupName, proxy: proxy)
                if result.changed { changed = true }
                dropPendingSelection(profileID: profileID, group: groupName)
            } catch {
                continue
            }
        }
        if changed {
            try? await fetchCoreGroups()
        }
    }

    /// Select a node (FlClash card.dart selectGroupProxy). Returns a
    /// notice when the group cannot be chosen by hand, else nil.
    /// - Selector: tap selects the node.
    /// - url-test / fallback: tap pins the node as 首选； tapping the
    ///   pinned node again clears the pin (proxy.select with "").
    /// - load-balance / relay / other: not selectable by hand.
    /// A successful change reloads the groups so `now` and `fixed`
    /// show what the core actually picked. When the VPN is OFF the
    /// core is unreachable: the choice is remembered (UserDefaults,
    /// per profile) and applied when the tunnel connects, and the
    /// local list updates immediately so the tap visibly takes
    /// effect — the user picks a node first, then starts the VPN.
    @MainActor
    func select(node: ProxyNode, in group: ProxyGroup, profileID: UUID? = nil) async -> String? {
        switch group.type {
        case "select":
            return await applySelect(group: group, proxy: node.name, profileID: profileID)
        case "url-test", "fallback":
            let pinned = group.fixed == node.name
            return await applySelect(group: group, proxy: pinned ? "" : node.name, profileID: profileID)
        default:
            return "该策略组（\(group.type)）不可手动选择"
        }
    }

    @MainActor
    private func applySelect(group: ProxyGroup, proxy: String, profileID: UUID? = nil) async -> String? {
        do {
            let result = try await client.proxySelect(group: group.name, proxy: proxy)
            // Record the live pick too, so the local fallback keeps
            // showing it after the tunnel stops.
            if let profileID {
                savePendingSelection(profileID: profileID, group: group.name, proxy: proxy)
            }
            if result.changed { await refresh() }
            lastError = nil
            return nil
        } catch {
            if !isRunning, let profileID {
                savePendingSelection(profileID: profileID, group: group.name, proxy: proxy)
                groups = groups.map { g in
                    guard g.name == group.name else { return g }
                    var g = g
                    if g.type == "select" {
                        g.selectedNodeName = proxy.isEmpty ? nil : proxy
                    } else {
                        g.fixed = proxy.isEmpty ? nil : proxy
                    }
                    return g
                }
                lastError = nil
                return nil
            }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Batch latency test for every node. In live mode this uses
    /// delay.run: one stream tests all nodes at once and the extension
    /// accumulates the results into snapshots/delay.json, which is
    /// polled here until the run reports `done` (up to ~60 s). If the
    /// run cannot start, or the poll never completes, it falls back to
    /// sequential delay.test calls — the same results, just slower.
    /// With the VPN OFF (live mode) the test runs on the app-side
    /// core (AppCore, FlClash parity) instead of failing: the
    /// extension's core is down, so the batch/sequential calls below
    /// go to AppCore. A transport failure (no core at all) never
    /// records -2 — a throw means the test never ran, not that the
    /// node failed; only a returned value of -2 marks a failure.
    @MainActor
    func testLatency() async {
        var nodes: [(name: String, url: String?)] = []
        for group in groups {
            for node in group.nodes where node.type != "DIRECT" {
                nodes.append((name: node.name, url: group.testUrl.isEmpty ? nil : group.testUrl))
            }
        }
        await runLatencyTest(nodes: nodes, groupNames: Set(groups.map { $0.name }), batchURL: nil)
    }

    /// Batch latency test for one group only (the bolt on a group
    /// header, or the top bolt in tab style, which tests the current
    /// group). Same batch/sequential logic as the all-groups test.
    /// `nodeNames`, when given, restricts the test to those nodes
    /// (the Proxies page passes the search-matching names while
    /// searching — FlClash tests only search matches).
    @MainActor
    func testLatency(group: ProxyGroup, nodeNames: [String]? = nil) async {
        let names = nodeNames.map { Set($0) }
        let nodes = group.nodes.filter { $0.type != "DIRECT" && (names == nil || names!.contains($0.name)) }
            .map { (name: $0.name, url: group.testUrl) }
        await runLatencyTest(nodes: nodes, groupNames: [group.name], batchURL: group.testUrl.isEmpty ? nil : group.testUrl)
    }

    @MainActor
    private func runLatencyTest(nodes: [(name: String, url: String?)], groupNames: Set<String>, batchURL: String?) async {
        guard !nodes.isEmpty, testingGroups.isDisjoint(with: groupNames) else { return }
        testingGroups.formUnion(groupNames)
        defer { testingGroups.subtract(groupNames) }
        // Backend: the extension's core while the VPN runs; the
        // app-side core (AppCore) while it is off; the sample
        // transport in sample mode. When the VPN is off and the
        // app-side core cannot start (no profile, engine failure),
        // the test cannot run at all — leave the nodes untested
        // (no -2) and say why.
        let useAppCore = client.mode == .live && !TunnelManager.shared.isRunning
        if useAppCore {
            do {
                try await AppCore.shared.ensureStarted()
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        if client.mode == .live {
            let names = nodes.map { $0.name }
            do {
                if useAppCore {
                    _ = try await AppCore.shared.delayRunStart(proxies: names, url: batchURL)
                } else {
                    _ = try await client.delayRunStart(proxies: names, url: batchURL)
                }
                var polls = 0
                while polls < 120, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    polls += 1
                    do {
                        let snapshot: DelayRunSnapshot
                        if useAppCore {
                            guard let polled = await AppCore.shared.delayRunPoll() else { continue }
                            snapshot = polled
                        } else {
                            snapshot = try await client.delayRunPoll()
                        }
                        for result in snapshot.results {
                            latencies[result.name] = result.value
                        }
                        applyLatencies()
                        if snapshot.done {
                            lastError = nil
                            return
                        }
                    } catch is TunnelError {
                        // The extension has not written the run file
                        // yet — keep polling, do not fail.
                        continue
                    }
                }
                // The run is still going (or its file never appeared):
                // keep the partial results and let the next test
                // start a fresh run.
                lastError = nil
                return
            } catch {
                // delay.run failed to start — fall through to the
                // sequential delay.test loop below.
            }
        }
        for node in nodes {
            do {
                let result: ConcordDelayResult
                if useAppCore {
                    result = try await AppCore.shared.delayTest(proxy: node.name, url: node.url)
                } else {
                    result = try await client.delayTest(proxy: node.name, url: node.url)
                }
                latencies[node.name] = result.value
            } catch {
                // A throw means the CALL failed (transport / core
                // down), not that the node failed: the core reports
                // a node failure as a returned value of -2, never
                // as a throw. Leave the node untested and stop —
                // the backend is down, further calls fail too.
                break
            }
        }
        applyLatencies()
        lastError = nil
    }

    /// One node's delay (the per-node chip tap). Passes the group's
    /// test URL (FlClash _handleTestCurrentDelay). Uses the app-side
    /// core when the VPN is off; a transport failure only sets
    /// lastError and leaves the chip unchanged.
    @MainActor
    func testLatency(node: ProxyNode, testURL: String? = nil) async {
        do {
            let result: ConcordDelayResult
            if client.mode == .live && !TunnelManager.shared.isRunning {
                try await AppCore.shared.ensureStarted()
                result = try await AppCore.shared.delayTest(proxy: node.name, url: testURL)
            } else {
                result = try await client.delayTest(proxy: node.name, url: testURL)
            }
            latencies[node.name] = result.value
            applyLatencies()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyLatencies() {
        groups = groups.map { g in
            var g = g
            g.nodes = g.nodes.map { n in
                var n = n
                n.latencyMs = latencies[n.name]
                return n
            }
            return g
        }
    }

    /// Full node detail for the detail sheet: the configured definition
    /// (proxy.definition, open JSON) and the live state (proxy.states:
    /// alive / UDP / delay history). Either may be absent — the sheet
    /// shows what it got and says what it did not.
    struct NodeDetail {
        var definition: JSONValue?
        var state: ConcordProxyState?
        var error: String?
    }

    @MainActor
    func fetchNodeDetail(name: String) async -> NodeDetail {
        var detail = NodeDetail()
        do {
            detail.definition = try await client.proxyDefinition(name: name)
        } catch {
            detail.error = "读取节点配置失败：\(error.localizedDescription)"
        }
        do {
            detail.state = try await client.proxyStates(names: [name]).first
        } catch {
            if detail.error == nil {
                detail.error = "读取节点状态失败：\(error.localizedDescription)"
            }
        }
        return detail
    }

    // Engine lifecycle.
    //
    // `.live`: the Dashboard start/stop button drives the SYSTEM VPN
    // (TunnelManager -> NETunnelProviderManager). The extension's
    // startTunnel boots the core (engine.start + tun.start) and its
    // stopTunnel tears it down; isRunning follows the tunnel status.
    // `.sample`: only flips local UI state, as before.
    @MainActor
    func toggle() async {
        if client.mode == .live {
            if TunnelManager.shared.isRunning {
                await TunnelManager.shared.stop()
                isRunning = false
                startError = nil
            } else {
                do {
                    try await TunnelManager.shared.start()
                    isRunning = true
                    lastError = nil
                    startError = nil
                } catch {
                    lastError = error.localizedDescription
                    startError = error.localizedDescription
                }
            }
            return
        }
        if isRunning {
            do {
                try await client.tunStop()
                try await client.engineStop()
            } catch {
                lastError = error.localizedDescription
            }
            isRunning = false
            startError = nil
        } else {
            do {
                try await client.engineStart()
                isRunning = true
                startError = nil
            } catch {
                lastError = error.localizedDescription
                startError = error.localizedDescription
            }
        }
    }
}
