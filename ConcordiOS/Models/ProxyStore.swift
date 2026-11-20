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

/// A delay-test result key (FlClash delayTestKey): the test URL
/// actually used + the real node name. Stored alongside the
/// legacy name-keyed `latencies` in ProxyStore.
struct LatencyKey: Hashable {
    let testUrl: String
    let name: String
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    @Published var groups: [ProxyGroup] = []
    @Published var latencies: [String: Int32] = [:]
    /// Latency keyed by (testUrl, real node name) — FlClash
    /// DelayMap (audit B3/B7). `latencies` above stays name-keyed
    /// because DashboardView reads latencies[name] (that file is
    /// out of scope for this batch); this map is what the Proxies
    /// page displays, via applyLatencies(), so one node can hold
    /// a different delay per test address.
    @Published var latenciesByURL: [LatencyKey: Int32] = [:]
    /// Group names with a delay test in flight (per-group spinners).
    @Published var testingGroups: Set<String> = []
    /// Node names with a single-node delay test in flight (per-node
    /// spinners — FlClash shows an ActivityIndicator while a card's
    /// test runs; without this the bolt tap shows nothing at all
    /// until the result lands, which reads as "no response").
    @Published var testingNodes: Set<String> = []
    /// The reason the last delay test failed, if it failed. The
    /// Proxies page shows this in its notice banner: testLatency
    /// used to write only lastError, which no view on this page
    /// reads, so every failure was total silence (v0.2.32).
    @Published var testError: String?
    /// True when testError is a GeoSeed failure (the MMDB could not
    /// be seeded). The Proxies banner shows a retry button only in
    /// that case: tapping it re-seeds immediately, bypassing the
    /// 10-minute cool-down, instead of trapping the user (v0.2.35).
    @Published var testErrorIsGeoSeed = false
    /// True while a banner retry re-seed is running (banner spinner).
    @Published var isRetryingGeoSeed = false
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

    /// The delay test that most recently ran (or failed), so the
    /// Proxies banner's GeoSeed retry can re-run exactly that test
    /// once the files are seeded, instead of making the user tap
    /// the bolt again (v0.2.35).
    private enum LastTest {
        case all
        case group(ProxyGroup, nodeNames: [String]?)
        case node(ProxyNode, testURL: String?)
    }
    private var lastTest: LastTest?

    /// Records a delay-test failure for the banner: lastError and
    /// testError carry the reason, and testErrorIsGeoSeed marks a
    /// GeoSeed failure so the banner can offer its retry button.
    private func noteTestError(_ error: Error) {
        lastError = error.localizedDescription
        testError = error.localizedDescription
        testErrorIsGeoSeed = Self.isGeoSeedError(error)
    }

    private static func isGeoSeedError(_ error: Error) -> Bool {
        guard let appError = error as? AppCoreError else { return false }
        if case .geoSeedFailed = appError { return true }
        return false
    }

    /// The two homes GeoSeed writes to: the app core's private home
    /// (the one AppCore.ensureStarted checks) first, and, when
    /// available, the App Group container the extension core reads.
    /// Mirrors AppCore.homeDirectory — that helper is private to
    /// AppCore, so the path is reproduced here.
    private func geoSeedHomes() -> (appHome: URL, groupHome: URL?) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appHome = base.appendingPathComponent("ConcordAppCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        let groupHome = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
        return (appHome, groupHome)
    }

    /// Re-seeds the geo databases immediately and re-runs the test
    /// that failed, for the Proxies banner's retry tap. The tap is
    /// the user explicitly asking to try again NOW, so the
    /// 10-minute cool-down is cleared in both homes and the seed
    /// runs with ignoreCooldown (bundle copy first, network
    /// fallback — GeoSeed). Returns false when there is no GeoSeed
    /// failure to retry, or the MMDB is still missing afterwards:
    /// the banner then keeps showing the honest reason.
    @MainActor
    func retryGeoSeedAndRetest() async -> Bool {
        guard testErrorIsGeoSeed else { return false }
        isRetryingGeoSeed = true
        defer { isRetryingGeoSeed = false }
        let (appHome, groupHome) = geoSeedHomes()
        GeoSeed.clearCooldown(in: appHome)
        let appReport = await GeoSeed.ensureGeoFiles(in: appHome, perFileTimeout: 30, ignoreCooldown: true)
        if let groupHome {
            GeoSeed.clearCooldown(in: groupHome)
            _ = await GeoSeed.ensureGeoFiles(in: groupHome, perFileTimeout: 30, ignoreCooldown: true)
        }
        guard GeoSeed.isPresent(GeoSeed.mmdbFileName, in: appHome) else {
            // Still missing: keep the honest reason — fresh from
            // this retry when it produced one, otherwise the
            // original banner text.
            if let failure = appReport.failures.first(where: { $0.file == GeoSeed.mmdbFileName }) {
                noteTestError(AppCoreError.geoSeedFailed(failure.error.localizedDescription))
            } else if appReport.skippedByCooldown.contains(GeoSeed.mmdbFileName) {
                noteTestError(AppCoreError.geoSeedFailed("上次下载失败不久（\(Int(GeoSeed.cooldownSeconds / 60)) 分钟内不再重试）"))
            }
            return false
        }
        // Seeded: clear the stale banner and re-run the test that
        // failed. If the re-run fails again, noteTestError sets a
        // fresh testError and the banner shows the new reason.
        testError = nil
        testErrorIsGeoSeed = false
        await rerunLastTest()
        return true
    }

    private func rerunLastTest() async {
        switch lastTest {
        case .all:
            await testLatency()
        case .group(let group, let nodeNames):
            await testLatency(group: group, nodeNames: nodeNames)
        case .node(let node, let testURL):
            await testLatency(node: node, testURL: testURL)
        case nil:
            break
        }
    }

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

    /// The settings store, linked by the app at startup
    /// (ConcordiOSApp, next to the profileStore line above):
    /// the delay-test timeout is read from it (audit B1). Until
    /// it is linked, the persisted settings blob is read instead,
    /// then the FlClash default 8000ms — see delayTimeoutMs.
    weak var settingsStore: SettingsStore?

    /// Last tunnel-connected state seen by the status subscription
    /// (audit A1): the connect edge is what triggers applying
    /// pending selections.
    private var wasTunnelConnected = false

    /// Node selections made while the VPN is off, persisted per
    /// profile in UserDefaults as {profileID: {group: proxy}}.
    /// Applied to the core by refresh() once it is reachable again,
    /// and by applyPendingSelectionsOnConnect() on the
    /// tunnel-connected edge (audit A1). Every successful live
    /// selection is recorded here too, so the local fallback keeps
    /// showing the same pick after the tunnel stops. The value is
    /// the proxy.select argument: a node name, or "" to clear a
    /// url-test/fallback pin.
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
                // Audit A1: the tunnel just came up — apply any
                // selections made while it was off. They sit in
                // UserDefaults until now; no view refreshes on
                // connect, so without this edge the "启动后自动应用"
                // promise never happens. The apply itself is a
                // refresh (core groups first, then pending picks);
                // entries the core accepts are dropped, so a later
                // reconnect is a no-op.
                let connected = status == .connected
                if connected, !self.wasTunnelConnected {
                    Task { await self.applyPendingSelectionsOnConnect() }
                }
                self.wasTunnelConnected = connected
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
                    return ProxyNode(name: name, type: info?.type ?? "unknown", provider: info?.provider, latencyMs: nil)
                },
                selectedNodeName: g.now,
                testUrl: g.testUrl,
                fixed: g.fixed,
                icon: g.icon
            )
        }
        // Latencies are keyed by (testUrl, real node) now (B3):
        // fill each row from its resolved target, not the raw name.
        applyLatencies()
    }

    /// Build the group list from the local parse. Returns false when
    /// the parse has no groups at all (caller keeps the core error).
    /// The remembered selection (if any) becomes the group's `now` /
    /// `fixed`, so the pick the user made while off survives a
    /// restart. No latency data exists offline — nodes show no delay.
    private func loadLocalGroups(_ local: ProfileStore.LocalProxyGroups, profileID: UUID) -> Bool {
        guard !local.groups.isEmpty else { return false }
        let typeByName = Dictionary(uniqueKeysWithValues: local.nodes.map { ($0.name, $0.type) })
        // Provider attribution for the offline list (audit C1):
        // a node that came from a proxy-provider shows its provider
        // name, like the live path. Literal nodes have no provider.
        let providerByName: [String: String] = Dictionary(uniqueKeysWithValues: local.nodes.compactMap { node in
            node.provider.map { (node.name, $0) }
        })
        groups = local.groups.map { g in
            let pending = pendingSelection(profileID: profileID, group: g.name)
            return ProxyGroup(
                name: g.name,
                type: g.type,
                nodes: g.nodeNames.map { name in
                    ProxyNode(name: name, type: typeByName[name] ?? localBuiltinType(name), provider: providerByName[name], latencyMs: nil)
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

    /// Applies off-VPN selections now that the tunnel is up (audit
    /// A1). Called from the tunnel-status subscription in init, so
    /// the "启动后自动应用" promise holds without any view having
    /// to refresh on connect; the coordinator can also call this
    /// directly from a connect call site. No-op in sample mode or
    /// with no active profile. Refreshing re-reads the core groups
    /// first (the local fallback list cannot be applied), and
    /// refresh() itself applies the pending selections.
    @MainActor
    func applyPendingSelectionsOnConnect() async {
        guard client.mode == .live else { return }
        guard let profile = profileStore?.activeProfile else { return }
        await refresh(activeProfile: profile)
        // The tunnel can report .connected a moment before the
        // extension's core snapshot is readable; in that case the
        // refresh above fell back to the local list and the
        // selections are still pending. One bounded retry covers
        // the boot race — the entries stay in UserDefaults either
        // way, so a later manual refresh would still apply them.
        if isLocalFallback, !(loadPendingSelections()[profile.id.uuidString]?.isEmpty ?? true) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await refresh(activeProfile: profile)
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

    // MARK: - Delay-test targets, timeout, URL fallback (audit B1/B2/B3/B24)

    /// One dial target after nested-group resolution (FlClash
    /// computeRealSelectedProxyState / _resolveDelayTestTargets):
    /// the real node to dial + the URL to dial it with ("" = the
    /// core default). Hashable on (testUrl, proxyName) — the same
    /// key upstream dedupes and stores delays under.
    private struct DelayTarget: Hashable {
        let proxyName: String
        let testUrl: String
    }

    /// Delay-test timeout in ms (FlClash defaultDelayTestTimeout =
    /// 8000; audit B1). The linked SettingsStore wins; otherwise
    /// the persisted settings blob; otherwise 8000. Another worker
    /// is changing the stored default 5000 -> 8000 — this reads
    /// the live property either way, so no value is baked in here.
    private var delayTimeoutMs: UInt64 {
        if let ms = settingsStore?.delayTestTimeout, ms > 0 { return UInt64(ms) }
        if let ms = Self.persistedDelayTestTimeout(), ms > 0 { return UInt64(ms) }
        return 8000
    }

    /// The persisted settings blob's delayTestTimeout, if readable
    /// (SettingsStore saves under "ConcordiOS.settings.v1").
    private static func persistedDelayTestTimeout() -> Int? {
        struct SavedTimeout: Decodable {
            var delayTestTimeout: Int?
        }
        guard let data = UserDefaults.standard.data(forKey: "ConcordiOS.settings.v1"),
              let saved = try? JSONDecoder().decode(SavedTimeout.self, from: data) else { return nil }
        return saved.delayTestTimeout
    }

    /// First non-blank value, trimmed (FlClash takeFirstValid).
    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// The stored override `test-url` (general section), read-only
    /// through OverrideStore's existing `state(scope:section:)`
    /// accessor — profile-scoped wins over global. FlClash keeps
    /// testUrl out of the core patch and uses it client-side as
    /// the delay fallback (audit B24); removing it from the
    /// overlay is another worker's job.
    private func overrideTestURL() -> String? {
        let profileScope = profileStore?.activeProfile?.id.uuidString
        for scope in [profileScope, nil] {
            guard let stored = OverrideStore.shared.state(scope: scope, section: .general)["test-url"],
                  case .string(let value) = stored,
                  let trimmed = firstNonEmpty(value) else { continue }
            return trimmed
        }
        return nil
    }

    /// A group's effective delay-test URL (FlClash realTestUrl):
    /// the group's own testUrl, else the stored override
    /// test-url, else "" (core default).
    private func effectiveTestURL(for group: ProxyGroup) -> String {
        firstNonEmpty(group.testUrl, overrideTestURL()) ?? ""
    }

    /// Resolves a group member to the real node FlClash would dial
    /// (FlClash common/compute.dart getRealSelectedProxyState):
    /// while the name is itself a group, follow that group's
    /// current pick — live: the core's `now`; offline select: the
    /// remembered pick; offline url-test/fallback: the pinned 首选 —
    /// and take the nested group's own testUrl at each hop (each
    /// hop overwrites, so the innermost group's URL wins; an empty
    /// one falls back to the enclosing group's URL below). Returns
    /// nil when the resolved name parses empty (upstream skips it),
    /// the pick is stale (no longer a member — a subscription
    /// update renamed or dropped it), or a group cycle is found.
    private func resolveDelayTarget(memberName: String, fallbackTestUrl: String) -> DelayTarget? {
        var name = memberName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var testUrl = ""
        var seenGroups: Set<String> = []
        while let nested = groups.first(where: { $0.name == name }) {
            guard seenGroups.insert(name).inserted else { return nil }
            testUrl = nested.testUrl.trimmingCharacters(in: .whitespaces)
            let pick = (nested.selectedNodeName ?? nested.fixed ?? "").trimmingCharacters(in: .whitespaces)
            guard !pick.isEmpty else { return nil }
            guard nested.nodes.contains(where: { $0.name == pick }) || groups.contains(where: { $0.name == pick }) else { return nil }
            name = pick
        }
        return DelayTarget(proxyName: name, testUrl: testUrl.isEmpty ? fallbackTestUrl : testUrl)
    }

    /// Records one result under both keys: the name key keeps
    /// DashboardView working (it reads latencies[name] — that
    /// file is out of scope for this batch); the (testUrl, name)
    /// key is what the Proxies page displays, so one node can
    /// hold a different delay per test address (audit B3/B7).
    private func recordLatency(name: String, url: String, value: Int32) {
        latencies[name] = value
        latenciesByURL[LatencyKey(testUrl: url.trimmingCharacters(in: .whitespaces), name: name)] = value
    }

    /// The delay to show for a resolved target: the
    /// (testUrl, real name) entry first, the legacy name entry as
    /// fallback (e.g. a result whose URL the core echoed
    /// differently from the URL requested).
    private func latency(for target: DelayTarget) -> Int32? {
        latenciesByURL[LatencyKey(testUrl: target.testUrl, name: target.proxyName)]
            ?? latencies[target.proxyName]
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
        lastTest = .all
        // Every member of every group, resolved to the real node
        // FlClash would dial (nested groups -> their current pick,
        // audit B3) with that pick's test URL (audit B24 fallback
        // included). DIRECT is dial-tested like any other node
        // (audit B2): only a name that parses empty is skipped.
        // Targets dedupe on (testUrl, real name), as upstream does.
        var seen = Set<DelayTarget>()
        var targets: [DelayTarget] = []
        for group in groups {
            let fallback = effectiveTestURL(for: group)
            for node in group.nodes {
                guard let target = resolveDelayTarget(memberName: node.name, fallbackTestUrl: fallback),
                      seen.insert(target).inserted else { continue }
                targets.append(target)
            }
        }
        await runLatencyTest(targets: targets, groupNames: Set(groups.map { $0.name }))
    }

    /// Batch latency test for one group only (the bolt on a group
    /// header, or the top bolt in tab style, which tests the current
    /// group). Same batch/sequential logic as the all-groups test.
    /// `nodeNames`, when given, restricts the test to those nodes
    /// (the Proxies page passes the search-matching names while
    /// searching — FlClash tests only search matches).
    @MainActor
    func testLatency(group: ProxyGroup, nodeNames: [String]? = nil) async {
        lastTest = .group(group, nodeNames: nodeNames)
        let names = nodeNames.map { Set($0) }
        let fallback = effectiveTestURL(for: group)
        var seen = Set<DelayTarget>()
        var targets: [DelayTarget] = []
        for node in group.nodes where names == nil || names!.contains(node.name) {
            guard let target = resolveDelayTarget(memberName: node.name, fallbackTestUrl: fallback),
                  seen.insert(target).inserted else { continue }
            targets.append(target)
        }
        await runLatencyTest(targets: targets, groupNames: [group.name])
    }

    /// Runs the resolved targets. One delay.run batch per distinct
    /// test URL (the batch takes a single URL for all its proxies),
    /// then a sequential delay.test pass for whatever the batches
    /// did not complete. A batch that never reports `done` keeps
    /// its partial results and returns without the sequential pass
    /// (audit B5 behaviour, untouched — B5 is out of scope).
    /// Every delay call passes the timeout explicitly (audit B1):
    /// SettingsStore.delayTestTimeout, else the FlClash default
    /// 8000ms. A failed test stays "untested" — a throw never
    /// records a latency, and only a returned -2 marks a failure.
    @MainActor
    private func runLatencyTest(targets: [DelayTarget], groupNames: Set<String>) async {
        guard !targets.isEmpty, testingGroups.isDisjoint(with: groupNames) else { return }
        testingGroups.formUnion(groupNames)
        defer { testingGroups.subtract(groupNames) }
        // A new test supersedes the old failure: clear the banner
        // now, so a stale GeoIP error does not linger while the new
        // run is in flight (a fresh failure re-sets it below).
        testError = nil
        testErrorIsGeoSeed = false
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
                noteTestError(error)
                return
            }
        }
        var pending = targets
        if client.mode == .live {
            // One batch per distinct test URL: a single delay.run
            // cannot honour mixed URLs, so the all-groups path no
            // longer funnels every group through the core default
            // (audit B9 falls out of the B3 fix).
            let partitions = Dictionary(grouping: targets, by: { $0.testUrl })
            var batchIncomplete = false
            for testUrl in partitions.keys.sorted() {
                let batch = partitions[testUrl]!
                let names = batch.map { $0.proxyName }
                do {
                    if useAppCore {
                        _ = try await AppCore.shared.delayRunStart(proxies: names, url: testUrl.isEmpty ? nil : testUrl, timeout: delayTimeoutMs)
                    } else {
                        _ = try await client.delayRunStart(proxies: names, url: testUrl.isEmpty ? nil : testUrl, timeout: delayTimeoutMs)
                    }
                    var polls = 0
                    var done = false
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
                                recordLatency(name: result.name, url: result.url, value: result.value)
                                pending.removeAll { $0.proxyName == result.name && ($0.testUrl.isEmpty || result.url.isEmpty || $0.testUrl == result.url) }
                            }
                            applyLatencies()
                            if snapshot.done {
                                done = true
                                break
                            }
                        } catch is TunnelError {
                            // The extension has not written the run file
                            // yet — keep polling, do not fail.
                            continue
                        }
                    }
                    if !done {
                        // The run is still going (or its file never appeared):
                        // keep the partial results and let the next test
                        // start a fresh run.
                        batchIncomplete = true
                        break
                    }
                } catch {
                    // This partition's run never started, or its
                    // poll failed for a non-transient reason — its
                    // targets fall through to the sequential loop.
                    continue
                }
            }
            if batchIncomplete {
                lastError = nil
                return
            }
            if pending.isEmpty {
                lastError = nil
                return
            }
        }
        for target in pending {
            do {
                let result: ConcordDelayResult
                let url = target.testUrl.isEmpty ? nil : target.testUrl
                if useAppCore {
                    result = try await AppCore.shared.delayTest(proxy: target.proxyName, url: url, timeout: delayTimeoutMs)
                } else {
                    result = try await client.delayTest(proxy: target.proxyName, url: url, timeout: delayTimeoutMs)
                }
                recordLatency(name: result.name, url: result.url, value: result.value)
            } catch {
                // A throw means the CALL failed (transport / core
                // down), not that the node failed: the core reports
                // a node failure as a returned value of -2, never
                // as a throw. Leave the node untested and stop —
                // the backend is down, further calls fail too.
                // Surface the reason instead of going silent.
                noteTestError(error)
                break
            }
        }
        applyLatencies()
        lastError = nil
    }

    /// One node's delay (the per-node chip tap). The tapped row may
    /// itself be a nested group: it is resolved to the real node it
    /// currently picks, dialled with that nested group's own test
    /// URL (audit B3, FlClash _handleTestCurrentDelay +
    /// _resolveDelayTestTargets); a plain node is dialled with the
    /// group's test URL, else the stored override test-url (B24),
    /// else the core default. Every call passes the timeout
    /// explicitly (audit B1). Uses the app-side core when the VPN
    /// is off; a transport failure only sets lastError/testError
    /// and leaves the chip unchanged (never -2, never silent).
    /// A nested group with no current pick cannot be dialled: the
    /// chip stays untested and the banner says why.
    @MainActor
    func testLatency(node: ProxyNode, testURL: String? = nil) async {
        guard !testingNodes.contains(node.name) else { return }
        testingNodes.insert(node.name)
        testError = nil
        testErrorIsGeoSeed = false
        lastTest = .node(node, testURL: testURL)
        defer { testingNodes.remove(node.name) }
        let fallbackURL = firstNonEmpty(testURL, overrideTestURL()) ?? ""
        guard let target = resolveDelayTarget(memberName: node.name, fallbackTestUrl: fallbackURL) else {
            let reason = "该节点当前没有可测速的真实节点（策略组未选择节点）"
            lastError = reason
            testError = reason
            return
        }
        do {
            let result: ConcordDelayResult
            let url = target.testUrl.isEmpty ? nil : target.testUrl
            if client.mode == .live && !TunnelManager.shared.isRunning {
                try await AppCore.shared.ensureStarted()
                result = try await AppCore.shared.delayTest(proxy: target.proxyName, url: url, timeout: delayTimeoutMs)
            } else {
                result = try await client.delayTest(proxy: target.proxyName, url: url, timeout: delayTimeoutMs)
            }
            recordLatency(name: result.name, url: result.url, value: result.value)
            applyLatencies()
        } catch {
            noteTestError(error)
        }
    }

    private func applyLatencies() {
        groups = groups.map { g in
            var g = g
            let fallback = effectiveTestURL(for: g)
            g.nodes = g.nodes.map { n in
                var n = n
                // A row that is itself a group shows the delay of
                // the real node it currently picks, under that
                // pick's test URL (audit B3).
                if let target = resolveDelayTarget(memberName: n.name, fallbackTestUrl: fallback) {
                    n.latencyMs = latency(for: target)
                } else {
                    n.latencyMs = latencies[n.name]
                }
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
