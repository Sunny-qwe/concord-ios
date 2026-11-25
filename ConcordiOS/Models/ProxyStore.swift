import Foundation
import Combine

// MARK: - Proxy store (FlClash: Proxies page)
// Backed by Concord proxy.groups / proxy.select / delay.test.
// In `.sample` mode the groups come from ConcordSampleData via
// ConcordClient; in `.live` mode they come from the real core.

struct ProxyNode: Identifiable {
    /// Stable identity: the core guarantees unique proxy names
    /// within a profile, and the app already keys scrolling by name
    /// (scrollID). The old `let id = UUID()` regenerated every id
    /// on each refresh() (new structs from the core / local YAML),
    /// so SwiftUI destroyed and rebuilt every row — and could lose
    /// the scroll position — whenever the list reloaded.
    var id: String { name }
    let name: String
    let type: String
    let provider: String?
    var latencyMs: Int32?
}

struct ProxyGroup: Identifiable {
    /// Same as ProxyNode.id: group names are unique within a
    /// profile; a UUID here churned every row's identity on reload.
    var id: String { name }
    let name: String
    let type: String
    var nodes: [ProxyNode]
    var selectedNodeName: String?
    var testUrl: String
    /// Manual override for url-test / fallback / smart groups
    /// (Clash `fixed`): the node pinned as 首选； nil/"" = the pick
    /// is computed by the group itself. Smart reports `fixed` like
    /// url-test (upstream views.rs: the pin is the per-site
    /// default the group falls back to).
    var fixed: String?
    /// Group icon from the profile (URL or short text); "" = none,
    /// the list header falls back to the name's first character.
    var icon: String
    /// Hidden from the Proxies page in rule mode (Clash `hidden`).
    /// Carried through the store (v0.2.53, MuYu mode filtering):
    /// rule mode shows only non-hidden groups, global mode shows
    /// all of them, direct mode shows none. The flag lives here —
    /// not dropped at fetch — so the mode filter can apply at
    /// display time and the delay test sees the same list the page
    /// shows. Local/offline groups read it from the YAML too.
    let hidden: Bool
}

/// A delay-test result key (FlClash delayTestKey): the test URL
/// actually used + the real node name. Stored alongside the
/// legacy name-keyed `latencies` in ProxyStore.
struct LatencyKey: Hashable {
    let testUrl: String
    let name: String
}

// MARK: - Proxy group tap diagnostics (v0.2.119 FIX 2)
//
// On-device v0.2.117 every Proxies group card was untappable,
// and v0.2.118's ListGroupCard Button conversion left the card
// style (IconGroupCard) on .onTapGesture. These lines are the
// proof whether a tap fires at all: each group-card Button
// action records "button fired", and toggleExpanded records
// "toggled" — one tap + log export distinguishes "the Button
// never fired" from "the store never toggled". Same
// UserDefaults ring buffer as IPLookupDiagnostics (last 8
// lines), surfaced in LogStore.fullExportText.
struct ProxyTapDiagnostics {
    private static let storageKey = "concord.proxyTapDiagnostics"
    private static let maxLines = 8

    static func record(_ line: String) {
        var lines = UserDefaults.standard.string(forKey: storageKey)
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        lines.append("[\(timestamp())] \(line)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: storageKey)
    }

    static func lastDiagnosticText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
              !text.isEmpty else { return nil }
        return text
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

final class ProxyStore: ObservableObject {
    @Published var isRunning = false
    /// Persistent "VPN enabled" switch (v0.2.115, upstream
    /// network_takeover.dart: the TUN row binds to the persisted
    /// `tun.enable` config flag, NOT to the live tunnel state).
    /// Once the user turns it on it stays on — across tunnel stops
    /// and app restarts — and the status card's play button is the
    /// start/stop control. Defaults true: a fresh install reads
    /// enabled, matching MuYu's out-of-the-box state (toggle on,
    /// tunnel stopped). Persisted in UserDefaults, same pattern as
    /// ConcordClient.mode (didSet writes through).
    @Published var vpnEnabled: Bool = UserDefaults.standard.object(forKey: "ConcordiOS.vpn.enabled.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(vpnEnabled, forKey: "ConcordiOS.vpn.enabled.v1") }
    }
    /// ALL fetched groups, hidden included (v0.2.53). The hidden
    /// filter used to live at fetch (`!$0.hidden`); it moved to
    /// display time so the mode filter (below) can apply — rule
    /// mode drops hidden groups, global mode keeps them, direct
    /// mode shows none (MuYu providers/state/proxies.dart:10-12).
    /// `groups` itself is the raw list: name-resolution lookups
    /// (member icons, availability counts) still read it, while
    /// everything the user SEES reads `displayGroups`.
    @Published var groups: [ProxyGroup] = []
    /// Groups without the hidden flag — what Dashboard and Settings
    /// count (they never showed hidden groups, in any mode).
    var nonHiddenGroups: [ProxyGroup] { groups.filter { !$0.hidden } }
    /// The groups the Proxies page shows for the CURRENT outbound
    /// mode, read live from SettingsStore (same weak-ref pattern as
    /// delayTimeoutMs below; defaults to rule when unset). The
    /// delay test iterates this list too, so in rule mode it tests
    /// exactly what it tested before (hidden groups were never
    /// fetched), in global mode it also tests hidden groups, and in
    /// direct mode there is nothing to test.
    var displayGroups: [ProxyGroup] {
        switch settingsStore?.mode ?? .rule {
        case .direct: return []
        case .global: return groups
        case .rule: return nonHiddenGroups
        }
    }
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
    /// The Proxies tab's currently selected group (v0.2.64): hoisted
    /// out of ProxiesView's @State so the Dashboard 策略组 sheet can
    /// select a group before switching tabs — the pills read
    /// selectedVisibleGroup, which reads this. nil = first group.
    @Published var selectedGroupName: String?
    /// Groups the user expanded in list / card style. FlClash's
    /// unfoldSet (models/profile.dart:78) defaults to {} — groups
    /// start collapsed — so this set starts empty too. Hoisted
    /// out of ProxiesView's @State (v0.2.118) so the group cards'
    /// tap actions call a method on the stable store reference.
    /// (v0.2.119 correction: the v0.2.118 comment blamed a stale
    /// @State closure — that cannot be the cause, a closure over
    /// @State still writes the shared storage. On-device the tap
    /// gesture itself never fired, which is why both card styles
    /// are real Buttons now; see IconGroupCard / ListGroupCard.)
    @Published var expandedGroups: Set<String> = []

    func toggleExpanded(_ name: String) {
        if expandedGroups.contains(name) {
            expandedGroups.remove(name)
        } else {
            expandedGroups.insert(name)
        }
        // On-device proof (v0.2.119 FIX 2): the v0.2.118 Button
        // conversion is only proven when a tap lands here. The
        // card Button records its own line (IconGroupCard /
        // ListGroupCard tapAction), so "button fired" without this
        // line means the action ran but the store never saw it.
        ProxyTapDiagnostics.record("toggleExpanded \(name) → \(expandedGroups.contains(name) ? "展开" : "收起")")
    }
    /// When each testing group started its current run (v0.2.49):
    /// a run that never returns leaves its flag set forever, so
    /// every later tap is refused. A run older than
    /// staleTestRunSeconds with no result is treated as dead —
    /// the next tap clears it and starts fresh instead of being
    /// refused. Same for the single-node flags below.
    private var testingGroupsStartedAt: [String: Date] = [:]
    private var testingNodesStartedAt: [String: Date] = [:]
    /// A delay-test run "in progress" for longer than this is
    /// dead (the longest legitimate run — 43 nodes × 30 s guard
    /// at parallelism 2 — is ~11 min, but a run that produced no
    /// result at all in 5 min is grinding on a dead backend, not
    /// testing; the next tap restarts it rather than waiting out
    /// the full worst case).
    private static let staleTestRunSeconds: TimeInterval = 300
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
    /// Bumps on every (re-)set of testError, so the banner
    /// re-appears even when the new failure text is identical to
    /// the previous one (@Published only notifies on change — a
    /// dismissed banner would otherwise never come back for the
    /// same error, e.g. every tap failing with the same -2
    /// channel message).
    @Published var testErrorNonce = 0
    /// True when testError is a GeoSeed failure (the MMDB could not
    /// be seeded). The Proxies banner shows a retry button only in
    /// that case: tapping it re-seeds immediately, bypassing the
    /// 10-minute cool-down, instead of trapping the user (v0.2.35).
    @Published var testErrorIsGeoSeed = false
    /// The reason the last node switch failed AND was rolled back,
    /// if it failed (v0.2.97 gap 4). The Proxies page shows this in
    /// its notice banner, like testError: the old lastError write
    /// was invisible on this page, so a refused switch left the
    /// blue checkmark disagreeing with the core's actual node in
    /// silence. Set only when the proxy.select RPC AND its 3 s
    /// retry both fail; cleared when a later switch succeeds.
    @Published var selectError: String?
    /// Bumps on every (re-)set of selectError, so the banner
    /// re-appears even when the new failure text is identical to
    /// the previous one (same reason as testErrorNonce).
    @Published var selectErrorNonce = 0
    /// True while a banner retry re-seed is running (banner spinner).
    @Published var isRetryingGeoSeed = false
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
        testErrorNonce += 1
    }

    /// Same as noteTestError, for a channel failure that is not an
    /// Error (e.g. every node returning -2 — a value, not a throw).
    private func noteTestMessage(_ message: String) {
        lastError = message
        testError = message
        testErrorIsGeoSeed = false
        testErrorNonce += 1
    }

    /// True once any delay test has ever returned a positive
    /// latency on this device. An all--2 run with this false means
    /// the speed-test channel never worked at all (not "nodes that
    /// used to work just died").
    private var everDelaySucceeded: Bool {
        get { UserDefaults.standard.bool(forKey: "concord.everDelaySucceeded") }
        set { UserDefaults.standard.set(newValue, forKey: "concord.everDelaySucceeded") }
    }

    /// What the applied config actually knows (one proxy.groups
    /// response): every loaded name, plus — per provider — the
    /// live node names the core really has. proxy.groups nodes
    /// carry their provider (ConcordNodeInfo.provider), so the
    /// inventory costs nothing extra: it is the same call
    /// missingLoadedNames already made. The per-provider lists
    /// are what makes a "names still missing" banner diagnosable
    /// instead of a generic "请检查订阅": when a provider's live
    /// list is empty the pull brought nothing usable; when it
    /// holds other names the subscription renamed them.
    private struct LoadedInventory {
        /// Every proxy + group name the applied config knows.
        let loaded: Set<String>
        /// Live node names per provider. Only providers that own
        /// at least one loaded node appear (a provider with zero
        /// live nodes is absent — its count is 0). Order is
        /// unsorted here; describeProviderContents sorts when it
        /// samples them.
        let namesByProvider: [String: [String]]
    }

    /// One proxy.groups read (app-side core while the VPN is off,
    /// extension core while it runs), as an inventory. Nil when
    /// the core is unreachable / the query fails — the caller then
    /// reports the -2s without claiming a membership verdict.
    private func loadedInventory() async -> LoadedInventory? {
        do {
            let groups: ConcordProxyGroups
            if client.mode == .live && !TunnelManager.shared.isRunning {
                groups = try await AppCore.shared.loadedProxyGroups()
            } else {
                groups = try await client.proxyGroups()
            }
            var loaded = Set(groups.nodes.map { $0.name })
            loaded.formUnion(groups.groups.map { $0.name })
            var namesByProvider: [String: [String]] = [:]
            for node in groups.nodes {
                guard let provider = node.provider else { continue }
                namesByProvider[provider, default: []].append(node.name)
            }
            return LoadedInventory(loaded: loaded, namesByProvider: namesByProvider)
        } catch {
            return nil
        }
    }

    /// Describes what the loaded providers actually hold, for a
    /// banner / report line: "「我的订阅」有 25 个节点，例如：A、B、C…"
    /// (one clause per provider, sample of 5). `only`, when given,
    /// restricts the line to those providers; a listed provider
    /// with no loaded nodes is named with 0. "" when there is
    /// nothing to describe.
    private func describeProviderContents(_ namesByProvider: [String: [String]], only: Set<String>? = nil) -> String {
        let providers = (only ?? Set(namesByProvider.keys)).sorted()
        guard !providers.isEmpty else { return "" }
        let clauses = providers.map { provider -> String in
            let actual = (namesByProvider[provider] ?? []).sorted()
            if actual.isEmpty { return "「\(provider)」有 0 个节点" }
            let sample = actual.prefix(5).joined(separator: "、")
            let suffix = actual.count > 5 ? "…" : ""
            return "「\(provider)」有 \(actual.count) 个节点，例如：\(sample)\(suffix)"
        }
        return clauses.joined(separator: "；")
    }

    /// FIX 1b (v0.2.45): the config.validate hint for an all--2
    /// run. When the core's provider list is empty AND
    /// config.validate reports an issue against the applied
    /// config, returns "配置校验：<first issue's message>" for the
    /// banner + the delay-test report — the direct explanation
    /// when the applied config itself is broken (e.g. it
    /// references a RULE-SET provider it never defines, which
    /// config.apply refuses outright). Returns nil when the
    /// provider list is non-empty, validate reports no issues, or
    /// either call fails — the caller then keeps its existing
    /// wording (e.g. "可能没有 proxy-providers"). Never throws.
    /// VPN-off validates on the app-side core (AppCore, which is
    /// the live core here); VPN-on validates on the extension
    /// core through the client, against the same shared
    /// config.yaml. Diagnostics only: nothing is repaired.
    private func validateHintIfProvidersEmpty(useAppCore: Bool) async -> String? {
        do {
            let list: ConcordProviderList
            if useAppCore {
                list = try await AppCore.shared.providerList()
            } else {
                list = try await client.providerList()
            }
            guard list.providers.isEmpty else { return nil }
            let issues: [ConcordIssue]
            if useAppCore {
                issues = try await AppCore.shared.configValidate()
            } else if let path = ConfigStore.sharedFileURL(name: ConfigStore.configFileName)?.path {
                issues = try await client.configValidate(profilePath: path)
            } else {
                return nil
            }
            guard let first = issues.first else { return nil }
            return "配置校验：\(first.message)"
        } catch {
            return nil
        }
    }

    /// Names among `names` that the currently loaded core config
    /// does NOT know. Nil when the check itself is unavailable
    /// (core unreachable / query failed) — the caller then reports
    /// the -2s without claiming a membership verdict. VPN-off
    /// reads the app-side core (proxy.groups, 15 s timeout);
    /// VPN-on reads the extension's core the same way (the
    /// extension RPC path has its own deadline since v0.2.36).
    private func missingLoadedNames(_ names: [String]) async -> Set<String>? {
        guard let inventory = await loadedInventory() else { return nil }
        return Set(names).subtracting(inventory.loaded)
    }

    /// The timestamp line the delay-test diagnostic report opens
    /// with (yyyy-MM-dd HH:mm:ss, local time).
    private static func reportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
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

    // MARK: - Rule-set repair (v0.2.46 ITEM 1)
    //
    // The Proxies banner's 修复 button: only when the current
    // testError names a missing rule-set (AppCoreError
    // .configApplyFailed — the core refused the WHOLE config
    // because a rule references an undefined rule-set). Tapping
    // builds a plan from the ACTIVE profile's YAML (ProfileStore:
    // complete from sibling providers, else delete the
    // referencing RULE-SET lines); the sheet shows the exact
    // lines and the user confirms before anything is written.
    // The write goes through ProfileStore.updateProfileFile (the
    // normal update path: profile file + shared config.yaml +
    // live apply when the tunnel runs); the re-apply is then
    // verified — AppCore.ensureStarted while the VPN is off, a
    // fresh delay test while it runs — and a further missing set
    // named by the next error offers repair again from the same
    // banner. Never automatic: no repair runs on boot, on
    // update, or on any test — only this button, only after
    // confirmation.

    /// The missing rule-set name in the current banner error, if
    /// it names one. Nil in sample mode (no real core) and for
    /// every other failure — the 修复 button only appears for
    /// this exact failure.
    var missingRuleSetName: String? {
        guard client.mode == .live, let message = testError else { return nil }
        return ProfileStore.missingRuleSetName(from: message)
    }

    /// The repair-ALL plan awaiting confirmation in the sheet, if
    /// any (v0.2.49: every missing rule set in one plan).
    @Published var ruleSetRepairOffer: RuleSetRepairAllPlan?
    /// The outcome of the last confirmed repair, shown INLINE in
    /// the same sheet (v0.2.49): success, or the remaining problem
    /// verbatim. Never re-pops the banner as if nothing happened.
    @Published var ruleSetRepairOutcome: String?
    /// True when the outcome above is a success.
    @Published var ruleSetRepairOutcomeIsSuccess = false
    /// True while a repair plan is being collected or a confirmed
    /// repair is writing + re-applying.
    @Published var isRepairingRuleSet = false
    /// A repair attempt that could not build a plan (or found
    /// nothing missing) reports HERE (v0.2.58) — never by writing
    /// into testError: overwriting testError hid the TikTok error,
    /// dropped the 修复 button (the new message no longer matches
    /// the `rule set [...] not found` regex), and let the next
    /// test bring the banner back. Rendered as its own dismissible
    /// notice in ProxiesView; the TikTok error stays visible.
    /// The notice names the profile it was raised on: refresh()
    /// clears it when the active profile changes (v0.2.59:
    /// IMG_1191 showed the 150G notice still on 顺畅网络 after
    /// a switch). testError needs no such clearing — the new
    /// profile's own test result replaces it.
    @Published var repairNotice: String?
    /// Profile the last refresh() ran for (non-nil calls only —
    /// a nil refresh from another tab must not clear the notice).
    private var lastRefreshProfileID: UUID?

    /// One timestamped repair-attempt line for
    /// AppCore.recordRepairAttempt (names only — never a
    /// subscription URL or a token).
    private static func repairAttemptLine(profileName: String, missingNames: [String], result: String) -> String {
        let names = missingNames.isEmpty ? "未知" : missingNames.map { "「\($0)」" }.joined(separator: "、")
        return "[\(reportTimestamp(Date()))] 修复尝试：订阅「\(profileName)」，缺失：\(names)，结果：\(result)"
    }

    /// Builds the repair-ALL plan for the banner's error and
    /// presents the confirmation sheet. Never writes anything.
    /// Async: the plan needs one core YAML-parse sanity check
    /// (validateCandidateText), so the banner button calls this
    /// in a Task; the missing-set discovery itself is textual.
    @MainActor
    func prepareRuleSetRepair() async {
        guard let bannerMissing = missingRuleSetName, !isRepairingRuleSet else { return }
        guard let store = profileStore, let profile = store.activeProfile else {
            repairNotice = "没有已激活的订阅，无法修复缺失的规则集"
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: "未知订阅", missingNames: [bannerMissing], result: "没有已激活的订阅，未做任何修改"))
            return
        }
        ruleSetRepairOutcome = nil
        ruleSetRepairOutcomeIsSuccess = false
        repairNotice = nil
        isRepairingRuleSet = true
        defer { isRepairingRuleSet = false }
        // The banner's name goes in as coreReportedMissing: a set
        // the text already defines is core-invisible (v0.2.58
        // 150G/TikTok — the text detector alone finds nothing
        // missing, so without the name the plan is nil and this
        // branch reports "未找到缺失的规则集"). With the name the
        // plan offers deleting the referencing rule(s) instead.
        guard let plan = await store.ruleSetRepairAllPlan(for: profile, coreReportedMissing: bannerMissing) else {
            // No plan — and the diagnosis must survive: the old
            // noteTestMessage here overwrote testError, which hid
            // the TikTok error and its 修复 button.
            repairNotice = "未能生成修复方案：当前订阅「\(profile.name)」没有找到缺失的规则集（或文件无法读取），未做任何修改。原来的报错还在上面，可以再点一次「修复」重试。"
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: [bannerMissing], result: "未找到缺失的规则集，未做任何修改"))
            return
        }
        ruleSetRepairOffer = plan
        AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: plan.items.map { $0.missingName }, result: "已生成修复方案，等待确认"))
    }

    /// Dismisses the repair sheet (clears the offer and the inline
    /// outcome). Called by the sheet's 取消 / 完成 buttons.
    @MainActor
    func dismissRuleSetRepair() {
        ruleSetRepairOffer = nil
        ruleSetRepairOutcome = nil
        ruleSetRepairOutcomeIsSuccess = false
    }

    /// Applies the confirmed repair-ALL plan, then re-applies +
    /// re-tests. The sheet stays open: the outcome is written
    /// INLINE into the sheet (ruleSetRepairOutcome) — a remaining
    /// problem is shown there, never as a fresh banner pop. The
    /// offer is NOT cleared here; the sheet's 完成 button
    /// dismisses it.
    @MainActor
    func confirmRuleSetRepair() async {
        guard let offer = ruleSetRepairOffer, !isRepairingRuleSet else { return }
        guard offer.isRepairable, let offerText = offer.newText else {
            // Unrepairable plans have no confirm button; this
            // only fires if the sheet is dismissed another way.
            return
        }
        guard let store = profileStore, let profile = store.activeProfile else {
            ruleSetRepairOutcome = "没有已激活的订阅，无法修复"
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: "未知订阅", missingNames: offer.items.map { $0.missingName }, result: "没有已激活的订阅，未做任何修改"))
            return
        }
        isRepairingRuleSet = true
        defer { isRepairingRuleSet = false }
        // Re-collect fresh: the file may have changed since the
        // offer was built (subscription update, another edit). A
        // plan that no longer matches is refused, never written
        // stale — the refusal is shown inline in the sheet.
        // The same core-reported name goes in again: the offer was
        // built with it, so a fresh plan without it would differ
        // (an invisible set would drop out) and be refused as a
        // stale change. testError is still the original error
        // here — no re-test runs until after the write.
        guard let fresh = await store.ruleSetRepairAllPlan(for: profile, coreReportedMissing: missingRuleSetName),
              fresh.isRepairable,
              fresh.newText == offerText,
              fresh.items.map({ $0.missingName }) == offer.items.map({ $0.missingName }) else {
            ruleSetRepairOutcome = "配置文件在确认前已变化，请关闭后重新点「修复」再确认"
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: offer.items.map { $0.missingName }, result: "配置文件在确认前已变化，未写入"))
            return
        }
        let missingNames = offer.items.map { $0.missingName }
        // Bake-source rules must go from the subscription BEFORE
        // the file is written: updateProfileFile re-bakes the
        // subscription into the shared config on apply, so a
        // file-only delete would be resurrected on the next
        // switch / update. Only .delete items are removed from
        // the store — a .complete item's rule stays, its provider
        // is now defined. (The old noteTestMessage("正在修复…")
        // here is gone: it overwrote testError with a progress
        // line, hiding the original diagnosis; the sheet's own
        // spinner shows progress instead.)
        let deleteNames = offer.items.filter { if case .delete = $0.kind { return true }; return false }.map { $0.missingName }
        let bakeRemovals = store.removeBakedRuleSetRules(deleteNames, for: profile)
        let bakeRemovalNote = bakeRemovals.map { "同时从自定义订阅「\($0.subscriptionName)」删除了引用「\($0.name)」的 \($0.removedCount) 条规则，下次切换或更新不会再补回来。" }.joined(separator: "")
        guard let newData = offerText.data(using: .utf8) else {
            ruleSetRepairOutcome = "修复内容不是有效的 UTF-8 文本，无法写入"
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "修复内容不是有效的 UTF-8 文本，未写入"))
            return
        }
        // The normal update path: sanity check + profile file +
        // shared config.yaml + live apply when the tunnel runs.
        // lastError carries a live-apply / validate refusal
        // verbatim; nil means the write + apply succeeded.
        await store.updateProfileFile(profile, data: newData)
        if let failure = store.lastError {
            ruleSetRepairOutcome = failure + (bakeRemovalNote.isEmpty ? "" : "（\(bakeRemovalNote)）")
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "写入或应用失败：\(failure)" + (bakeRemovalNote.isEmpty ? "" : "；\(bakeRemovalNote)")))
            return
        }
        if TunnelManager.shared.isRunning {
            // Live apply already succeeded inside
            // updateProfileFile; verify end to end with the test
            // that failed.
            await rerunLastTest()
            if testError == nil {
                ruleSetRepairOutcome = offer.successMessage + bakeRemovalNote
                ruleSetRepairOutcomeIsSuccess = true
                AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "已修复并重新应用，测速已恢复" + (bakeRemovalNote.isEmpty ? "" : "；\(bakeRemovalNote)")))
            } else if let error = testError {
                ruleSetRepairOutcome = "配置已修复并应用，但测速仍有问题：\(error)"
                ruleSetRepairOutcomeIsSuccess = false
                AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "配置已修复并应用，但测速仍有问题：\(error)"))
            }
            return
        }
        // VPN off: the app-side core is the one that refused the
        // config — re-apply on it now (it restarts on the changed
        // shared config.yaml). A refusal is shown inline;
        // success re-runs the failed test.
        do {
            try await AppCore.shared.ensureStarted()
        } catch {
            noteTestError(error)
            ruleSetRepairOutcome = error.localizedDescription
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "配置已写入，但重新启动核心失败：\(error.localizedDescription)"))
            return
        }
        await rerunLastTest()
        if testError == nil {
            ruleSetRepairOutcome = offer.successMessage + bakeRemovalNote
            ruleSetRepairOutcomeIsSuccess = true
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "已修复并重新应用，测速已恢复" + (bakeRemovalNote.isEmpty ? "" : "；\(bakeRemovalNote)")))
        } else if let error = testError {
            ruleSetRepairOutcome = "配置已修复并应用，但测速仍有问题：\(error)"
            ruleSetRepairOutcomeIsSuccess = false
            AppCore.recordRepairAttempt(Self.repairAttemptLine(profileName: profile.name, missingNames: missingNames, result: "配置已修复并应用，但测速仍有问题：\(error)"))
        }
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

    /// The service-probe store, linked by the app at startup
    /// (ConcordiOSApp, next to the lines above — it is
    /// `trafficStore.serviceProbeStore`): a user-initiated
    /// outbound change re-probes the dashboard service checks
    /// immediately through the new outbound (v0.2.86 item 16,
    /// upstream _onRoute picks change). Weak, like profileStore
    /// above; until it is linked, selections change with no
    /// probe notification and the dashboard's normal probe path
    /// covers the checks.
    weak var serviceProbeStore: ServiceProbeStore?

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
    /// url-test/fallback/smart pin.
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

    /// The pre-pick local values for a group whose optimistic pick
    /// has not yet been confirmed by the core (v0.2.97 gap 4): what
    /// the group showed before applySelect's applyLocalPick.
    /// Restored — and dropped — when the RPC and its retry both
    /// fail, so the list shows the node the core actually still
    /// has. In-memory only: a restart loses it, but the pending is
    /// still dropped then, so fetchCoreGroups shows the core's
    /// actual pick instead of the refused one.
    private struct PreviousPick {
        let selectedNodeName: String?
        let fixed: String?
    }
    /// Keyed [profileID.uuidString][group], mirroring the pending
    /// selections. Cleared once the core confirms the new pick
    /// (fetchCoreGroups), when the pending is dropped for any other
    /// reason, or by the rollback itself.
    private var previousPicks: [String: [String: PreviousPick]] = [:]

    private func savePreviousPick(profileID: UUID, group: ProxyGroup) {
        previousPicks[profileID.uuidString, default: [:]][group.name] = PreviousPick(selectedNodeName: group.selectedNodeName, fixed: group.fixed)
    }

    private func dropPreviousPick(profileID: UUID, group: String) {
        previousPicks[profileID.uuidString]?.removeValue(forKey: group)
        if previousPicks[profileID.uuidString]?.isEmpty == true {
            previousPicks.removeValue(forKey: profileID.uuidString)
        }
    }

    /// Restores the pre-pick local values for one group (the
    /// inverse of applyLocalPick: both the displayed pick and the
    /// pin, exactly as captured before the tap). No-op when nothing
    /// was captured — the caller still drops the pending, so the
    /// core's actual pick shows after the refresh.
    private func restorePreviousPick(profileID: UUID, group: String) {
        guard let previous = previousPicks[profileID.uuidString]?[group] else { return }
        groups = groups.map { g in
            guard g.name == group else { return g }
            var g = g
            g.selectedNodeName = previous.selectedNodeName
            g.fixed = previous.fixed
            return g
        }
        dropPreviousPick(profileID: profileID, group: group)
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
        // A repair notice names the profile it was raised on: a
        // switch makes it stale (v0.2.58 IMG_1191 — the 150G
        // notice was still showing on 顺畅网络). Clear it on the
        // switch only; a nil refresh (another tab's onAppear) or
        // a pull-to-refresh on the same profile keeps it.
        if let id = activeProfile?.id, id != lastRefreshProfileID {
            repairNotice = nil
            lastRefreshProfileID = id
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await fetchCoreGroups(profileID: activeProfile?.id)
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
            // reads throw. The parse is a whole-file line scan
            // (ProfileStore.localProxyGroups): it runs off the main
            // thread so the Proxies page's first frame (static
            // title + loading state) is not held up by it
            // (v0.2.40 title-delay fix); the parsed result is
            // applied back on the main actor below.
            if client.mode == .live, TunnelManager.shared.isRunning, !groups.isEmpty {
                lastError = error.localizedDescription
                return
            }
            if let profile = activeProfile {
                let store = profileStore
                let local = await Task.detached { store?.localProxyGroups(for: profile) }.value
                if let local, loadLocalGroups(local, profileID: profile.id) {
                    lastUpdated = Date()
                    lastError = nil
                    return
                }
            }
            lastError = error.localizedDescription
            isLocalFallback = false
        }
    }

    /// Group-kind spelling, normalized once at the fetch boundary
    /// (v0.2.60): the core reports kinds by display name —
    /// "Selector", "URLTest", "Smart", "Fallback", "LoadBalance",
    /// "Relay" (upstream crates/group/src/group.rs type_name,
    /// wired through GroupInfo.kind as "type") — while the profile
    /// YAML and the whole UI spell them "select", "url-test",
    /// "smart", "fallback", "load-balance", "relay". Without this
    /// every type comparison below (selection, pinning, member
    /// icons, isAddable) silently missed in live mode and only
    /// matched the offline YAML / sample spellings. Unknown
    /// spellings pass through lowercased, never invented.
    static func normalizedGroupType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "selector", "select": return "select"
        case "urltest", "url-test": return "url-test"
        case "smart": return "smart"
        case "fallback": return "fallback"
        case "loadbalance", "load-balance": return "load-balance"
        case "relay": return "relay"
        default: return raw.lowercased()
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
    private func fetchCoreGroups(profileID: UUID? = nil) async throws {
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
        // The core's node list holds only real nodes — a member that is
        // itself a group (a nested Selector / URLTest / Smart /
        // Fallback) is absent from it, so its type used to fall
        // through to "unknown" (v0.2.56 IMG_1178: 自动选择 /
        // unknown, 故障转移 / unknown). Resolve it from the
        // group's own type instead — the same type the core reports
        // for that group, normalized to the YAML spelling (see
        // normalizedGroupType). MuYu's Proxy.type comes from the
        // core's /proxies table, where groups ARE proxies (Selector
        // / URLTest / Smart / Fallback), so MuYu never shows
        // "unknown" for a nested group.
        let groupTypeByName = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.name, Self.normalizedGroupType($0.type)) })
        groups = result.groups.map { g in
            // v0.2.57: a never-tested url-test/fallback/smart group
            // reports an empty `now` — live it showed an empty
            // subtitle while MuYu shows the pinned pick. (Smart is
            // url-test-like here: the core reports `now` — its
            // per-site default pick — and `fixed` for it, so the
            // same chain applies.) Display-only: `now` wins when
            // present; else the core's `fixed` pin, else the
            // remembered pick (a pin saved while off, or one the core
            // has not applied yet). Nothing is selected here and no
            // delay-test state is touched — only the displayed pick
            // (header subtitle, card selected row, scroll target)
            // changes. Same fallback the offline path has used since
            // v0.2.56 (selectedNodeName = pending).
            let now = (g.now ?? "").trimmingCharacters(in: .whitespaces)
            // v0.2.95 Bug 1: the user's explicit pick is authoritative
            // while the core has not confirmed it yet — a stale
            // snapshot (written before the select) used to revert
            // the UI to the old pick (自动选择）. New display order:
            // pending -> now -> fixed. With no pending the chain
            // is unchanged. A pending is dropped here, and only
            // here, once the RAW core values confirm it: a
            // non-empty pending is confirmed when g.now or g.fixed
            // equals it; an empty pending "" (clear-pin) is
            // confirmed when g.fixed is nil/empty. Until then the
            // pending is kept and displayed.
            let pending = profileID.flatMap { self.pendingSelection(profileID: $0, group: g.name) }
            if let profileID, let pending {
                let trimmedPending = pending.trimmingCharacters(in: .whitespaces)
                let fixedTrimmed = (g.fixed ?? "").trimmingCharacters(in: .whitespaces)
                let confirmed: Bool
                if trimmedPending.isEmpty {
                    confirmed = fixedTrimmed.isEmpty
                } else {
                    confirmed = now == trimmedPending || fixedTrimmed == trimmedPending
                }
                if confirmed {
                    dropPendingSelection(profileID: profileID, group: g.name)
                    // v0.2.97 gap 4: the core confirmed the new pick,
                    // so the pre-pick snapshot is no longer needed.
                    dropPreviousPick(profileID: profileID, group: g.name)
                }
            }
            let displayedPick: String?
            if let pending, !pending.trimmingCharacters(in: .whitespaces).isEmpty {
                displayedPick = pending.trimmingCharacters(in: .whitespaces)
            } else if !now.isEmpty {
                displayedPick = now
            } else if let fixed = g.fixed, !fixed.trimmingCharacters(in: .whitespaces).isEmpty {
                displayedPick = fixed.trimmingCharacters(in: .whitespaces)
            } else {
                displayedPick = nil
            }
            return ProxyGroup(
                name: g.name,
                type: Self.normalizedGroupType(g.type),
                nodes: (g.all ?? []).map { name in
                    let info = nodeTypes[name]
                    return ProxyNode(name: name, type: info?.type ?? groupTypeByName[name] ?? "unknown", provider: info?.provider, latencyMs: nil)
                },
                selectedNodeName: displayedPick,
                testUrl: g.testUrl,
                fixed: g.fixed,
                icon: g.icon,
                hidden: g.hidden
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
        // Offline, a member that is itself a group is absent from the
        // parsed node list too, so resolve its type from the parsed
        // groups — same "unknown" fix as the live path above.
        // Normalized like the live path, so a YAML spelling such as
        // "Smart" still matches the UI's "smart".
        let groupTypeByName = Dictionary(uniqueKeysWithValues: local.groups.map { ($0.name, Self.normalizedGroupType($0.type)) })
        groups = local.groups.map { g in
            let pending = pendingSelection(profileID: profileID, group: g.name)
            let type = Self.normalizedGroupType(g.type)
            return ProxyGroup(
                name: g.name,
                type: type,
                nodes: g.nodeNames.map { name in
                    ProxyNode(name: name, type: typeByName[name] ?? groupTypeByName[name] ?? localBuiltinType(name), provider: providerByName[name], latencyMs: nil)
                },
                // MuYu selectedProxyName for url-test / fallback /
                // smart: the core's now when present, else the saved
                // pick. Offline there is no now, so the remembered
                // pick IS the current selection — show it (header
                // subtitle, card selected row, scroll target)
                // instead of nothing. `fixed` keeps the pin, as
                // before; for Selector groups this line is unchanged.
                selectedNodeName: pending,
                testUrl: g.testURL,
                fixed: type == "select" ? nil : pending,
                icon: g.icon,
                hidden: g.hidden
            )
        }
        isLocalFallback = true
        return true
    }

    /// Built-in pseudo-proxies keep their type offline; anything else
    /// the file does not declare is "unknown". Nested-group members
    /// never reach this fallback — loadLocalGroups resolves them
    /// from the parsed groups first (see groupTypeByName above).
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
    /// dropping the user's choice. An accepted entry is NOT dropped
    /// here (v0.2.95 Bug 1): it is dropped by fetchCoreGroups once
    /// the core snapshot confirms the new pick — dropping on RPC
    /// success let the next refresh show the stale `now` before the
    /// snapshot caught up. A re-fetch follows when anything changed,
    /// so `now`/`fixed` show what the core actually picked (and the
    /// confirmation/drop in fetchCoreGroups runs there).
    /// `rollbackGroups` (v0.2.97 gap 4): groups whose entry is the
    /// retry of a live applySelect that already failed once — a
    /// second failure there rolls the pick back (restore the
    /// pre-pick values, drop the pending, surface a message)
    /// instead of keeping an optimistic checkmark the core
    /// disagrees with. Refresh()/on-connect callers leave it empty,
    /// so their entries keep the old keep-for-next-attempt
    /// behaviour.
    private func applyPendingSelections(profileID: UUID, rollbackGroups: Set<String> = []) async {
        let pendings = loadPendingSelections()[profileID.uuidString] ?? [:]
        guard !pendings.isEmpty else { return }
        var changed = false
        for (groupName, proxy) in pendings {
            guard groups.contains(where: { $0.name == groupName }) else {
                dropPendingSelection(profileID: profileID, group: groupName)
                dropPreviousPick(profileID: profileID, group: groupName)
                continue
            }
            do {
                let result = try await client.proxySelect(group: groupName, proxy: proxy)
                if result.changed { changed = true }
            } catch {
                if rollbackGroups.contains(groupName) {
                    rollbackFailedSelection(profileID: profileID, group: groupName, error: error)
                    changed = true
                }
                continue
            }
        }
        if changed {
            try? await fetchCoreGroups(profileID: profileID)
        }
    }

    /// Rolls back a pending selection the core refused twice
    /// (v0.2.97 gap 4): restores the pre-pick local values, drops
    /// the pending so fetchCoreGroups stops preferring it over the
    /// core's actual pick, and surfaces a visible message on the
    /// Proxies page. The caller (applyPendingSelections) re-fetches
    /// the core groups afterwards, so the display ends
    /// core-confirmed even when no pre-pick was captured (e.g. the
    /// app restarted after the tap) — dropping the pending alone
    /// already lets the core's actual pick show.
    private func rollbackFailedSelection(profileID: UUID, group: String, error: Error) {
        restorePreviousPick(profileID: profileID, group: group)
        dropPendingSelection(profileID: profileID, group: group)
        lastError = error.localizedDescription
        selectError = "「\(group)」切换失败，已恢复原来的节点"
        selectErrorNonce += 1
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
        // v0.2.95 Bug 1: bounded retry loop (up to 3 attempts, 3 s
        // apart) instead of the single isLocalFallback retry. The
        // tunnel can report .connected a moment before the core is
        // ready to accept proxy.select, so the first refresh can
        // succeed while the select fails and the pick is lost from
        // the UI. Each attempt re-reads the core groups first (the
        // local fallback list cannot be applied); refresh() itself
        // applies the pending selections. Stop early when the
        // pending list is empty or the tunnel is no longer
        // connected. The entries stay in UserDefaults either way,
        // so a later manual refresh would still apply them.
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh(activeProfile: profile)
            }
            if loadPendingSelections()[profile.id.uuidString]?.isEmpty ?? true { return }
            guard isRunning else { return }
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

    /// Select a node in a smart group (v0.2.60, upstream c4bc31d):
    /// the core's is_selectable includes Smart, and it pins like
    /// url-test/fallback — tap pins the node as 首选； tapping the
    /// pinned node again clears the pin (proxy.select with ""). The
    /// pin is the group's per-site default: the core still picks
    /// per site around it, and redials the next member on failure.
    /// `select(node:in:)` above is byte-frozen for the v0.2.60
    /// rebase work, so smart routing lives here (called from
    /// ProxiesView.selectNode) instead of in its switch. It reuses
    /// applySelect, so the live/offline, pending-selection and
    /// refresh behaviour is identical to url-test/fallback.
    @MainActor
    func selectSmart(node: ProxyNode, in group: ProxyGroup, profileID: UUID? = nil) async -> String? {
        let pinned = group.fixed == node.name
        return await applySelect(group: group, proxy: pinned ? "" : node.name, profileID: profileID)
    }

    /// The optimistic local pick (v0.2.95 Bug 1): the mapping the
    /// old !isRunning catch branch had — type "select" sets
    /// selectedNodeName; url-test/fallback/smart set the fixed pin
    /// AND selectedNodeName (the displayed pick follows the pin).
    /// An empty proxy clears both. Called BEFORE the RPC so the
    /// tap is visible immediately, whatever the core does.
    private func applyLocalPick(group: ProxyGroup, proxy: String) {
        groups = groups.map { g in
            guard g.name == group.name else { return g }
            var g = g
            if g.type == "select" {
                g.selectedNodeName = proxy.isEmpty ? nil : proxy
            } else {
                g.fixed = proxy.isEmpty ? nil : proxy
                // Keep the displayed pick in step with the pin
                // (loadLocalGroups now reports the pick as
                // selectedNodeName for computed groups).
                g.selectedNodeName = proxy.isEmpty ? nil : proxy
            }
            return g
        }
    }

    @MainActor
    private func applySelect(group: ProxyGroup, proxy: String, profileID: UUID? = nil) async -> String? {
        // The selected outbound the dashboard probes through may
        // change with this pick (upstream _onRoute picks change):
        // capture it before so the probe store can be told after.
        let previousOutbound = selectedOutbound
        // v0.2.95 Bug 1 (upstream FlClash card.dart
        // selectGroupProxy / providers/actions/proxies.dart
        // changeProxy): update the local pick OPTIMISTICALLY first
        // — the local groups AND the saved pending selection —
        // then call the RPC. The old order (RPC first, local
        // update only on failure and only while the VPN was off)
        // left a tap with the VPN on doing nothing visible when
        // the RPC failed or the immediate refresh read a stale
        // snapshot. The pending is dropped only once the core
        // snapshot confirms the new pick (fetchCoreGroups).
        if let profileID {
            savePendingSelection(profileID: profileID, group: group.name, proxy: proxy)
            // v0.2.97 gap 4: remember what the group showed before
            // this tap, so a double failure can put it back.
            savePreviousPick(profileID: profileID, group: group)
        }
        applyLocalPick(group: group, proxy: proxy)
        do {
            let result = try await client.proxySelect(group: group.name, proxy: proxy)
            if result.changed {
                // Pass the active profile so the post-apply refresh
                // can prefer the pending pick over a stale snapshot
                // (fetchCoreGroups, v0.2.95 Bug 1) — a bare
                // refresh() has no profileID and would skip the
                // pending lookup entirely.
                let active = profileStore?.activeProfile
                await refresh(activeProfile: active?.id == profileID ? active : nil)
                // v0.2.97 gap 3 (upstream FlClash
                // providers/actions/proxies.dart changeProxy calls
                // closeConnections/resetNetwork after a successful
                // switch): reset the core's network so EXISTING
                // connections move to the new node too — without
                // this only new connections use it, and e.g.
                // Telegram stays on the old node.
                // closeConnections is NOT exposed in the core FFI,
                // so only the resetNetwork half is possible.
                // Best-effort: a reset failure must not fail the
                // switch that already succeeded.
                try? await client.networkReset()
            }
            lastError = nil
            selectError = nil
            // v0.2.86 item 16: the selected outbound changed — the
            // service checks re-probe immediately through the new
            // outbound (no backoff, no throttle). Live path only:
            // offline the core is unreachable and the dashboard
            // re-probes on connect anyway. Fire-and-forget: the
            // probe runs seconds behind the tap, never holding it.
            if selectedOutbound != previousOutbound, let outbound = selectedOutbound {
                Task { await serviceProbeStore?.outboundChanged(proxy: outbound) }
            }
            return nil
        } catch {
            if !isRunning {
                // Offline: the core is unreachable; the choice is
                // already remembered above and applied locally, so
                // the tap visibly takes effect and the pick is
                // applied when the tunnel connects.
                lastError = nil
                return nil
            }
            // VPN on but the RPC failed (core not ready yet): keep
            // the optimistic pick and the pending selection, and
            // retry once after ~3 s via applyPendingSelections.
            // v0.2.97 gap 4: the retry carries this group in
            // rollbackGroups — if it fails too, the pick is rolled
            // back to the pre-tap values and the user is told.
            lastError = error.localizedDescription
            if let profileID {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, isRunning else { return }
                    await applyPendingSelections(profileID: profileID, rollbackGroups: [group.name])
                }
            }
            return nil
        }
    }

    // MARK: - Delay-test targets, timeout, URL fallback (audit B1/B2/B3/B24)

    /// One dial target after nested-group resolution (FlClash
    /// computeRealSelectedProxyState / _resolveDelayTestTargets):
    /// the real node to dial + the URL to dial it with — always a
    /// real URL now (see defaultTestURL), never "". Hashable on
    /// (testUrl, proxyName) — the same key upstream dedupes and
    /// stores delays under.
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

    /// FlClash default test URL (lib/common/constant.dart:134):
    /// the last fallback of realTestUrl, so a delay test always
    /// has a URL to dial. delay.test is always called with a
    /// non-empty url now (B2 second version): the old "" left the
    /// choice to the core's own default and hid a missing
    /// test-url from the diagnostic report.
    private static let defaultTestURL = "https://www.gstatic.com/generate_204"

    /// A group's effective delay-test URL (FlClash realTestUrl):
    /// the group's own testUrl, else the stored override
    /// test-url, else the FlClash default above — never "".
    private func effectiveTestURL(for group: ProxyGroup) -> String {
        firstNonEmpty(group.testUrl, overrideTestURL(), Self.defaultTestURL) ?? Self.defaultTestURL
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

    /// Drops the recorded latencies for `targets` (both keys), so
    /// a new run never shows the previous run's results as its
    /// own (v0.2.49, IMG_1163). Called after the in-flight guard
    /// passes — never on a refused tap, so a refused tap keeps
    /// the old results on screen.
    private func clearLatencies(for targets: [DelayTarget]) {
        for target in targets {
            latencies.removeValue(forKey: target.proxyName)
            latenciesByURL.removeValue(forKey: LatencyKey(testUrl: target.testUrl.trimmingCharacters(in: .whitespaces), name: target.proxyName))
        }
    }

    /// The delay to show for a resolved target: the
    /// (testUrl, real name) entry first, the legacy name entry as
    /// fallback (e.g. a result whose URL the core echoed
    /// differently from the URL requested).
    private func latency(for target: DelayTarget) -> Int32? {
        latenciesByURL[LatencyKey(testUrl: target.testUrl, name: target.proxyName)]
            ?? latencies[target.proxyName]
    }

    /// The delay to show for one node row in a group (audit B7,
    /// for DashboardView.timeoutCount): resolve the row to the
    /// real node FlClash would dial (nested group -> its current
    /// pick, with that pick's test URL), read the (testUrl, real
    /// name) entry first, and fall back to the legacy name-keyed
    /// entry when resolution fails or the URL-keyed entry is
    /// absent (e.g. a result whose URL the core echoed
    /// differently). Nil = untested.
    func latency(forNodeNamed name: String, inGroup group: ProxyGroup) -> Int32? {
        let fallback = effectiveTestURL(for: group)
        if let target = resolveDelayTarget(memberName: name, fallbackTestUrl: fallback) {
            return latency(for: target)
        }
        return latencies[name]
    }

    /// Latency test for every node (FlClash delayTestGroups on
    /// all groups): each resolved target gets one delay.test call,
    /// at most delayTestBatchSize (32) in flight (see runLatencyTest). With the VPN OFF
    /// (live mode) the test runs on the app-side core (AppCore,
    /// FlClash parity) instead of failing: the extension's core is
    /// down, so the calls below go to AppCore. A transport failure
    /// records -2 for that node and, after 3 such throws, stops
    /// the run — a throw means the backend is down, not that the
    /// node failed; only a returned value of -2 marks a dead node.
    @MainActor
    func testLatency() async {
        // Direct mode shows no groups (MuYu providers/state/
        // proxies.dart:10), so there is nothing to test: return
        // before touching lastTest / the report, so a bolt tap in
        // direct mode is a silent no-op instead of a confusing
        // empty diagnosis. In rule mode displayGroups is exactly
        // the old fetched list, so the tested set is unchanged.
        guard (settingsStore?.mode ?? .rule) != .direct else { return }
        lastTest = .all
        // Every member of every group, resolved to the real node
        // FlClash would dial (nested groups -> their current pick,
        // audit B3) with that pick's test URL (audit B24 fallback
        // included). DIRECT is dial-tested like any other node
        // (audit B2): only a name that parses empty is skipped.
        // Targets dedupe on (testUrl, real name), as upstream does.
        var seen = Set<DelayTarget>()
        var targets: [DelayTarget] = []
        for group in displayGroups {
            let fallback = effectiveTestURL(for: group)
            for node in group.nodes {
                guard let target = resolveDelayTarget(memberName: node.name, fallbackTestUrl: fallback),
                      seen.insert(target).inserted else { continue }
                targets.append(target)
            }
        }
        await runLatencyTest(targets: targets, groupNames: Set(displayGroups.map { $0.name }))
    }

    /// Latency test for one group only (the bolt on a group
    /// header, or the top bolt in tab style, which tests the current
    /// group). Same per-target logic as the all-groups test.
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

    // MARK: - Delay test, FlClash-style (B2 second version)

    /// One per-target delay outcome (FlClash _runDelayTest returns
    /// one Delay per target; the guard timeout and the transport
    /// throw are ours, mapped onto FlClash's values: a guard
    /// timeout is a timeout (-1), a throw is a transport failure
    /// recorded as -2 for that node — see runLatencyTest). The
    /// transport failure carries the error's message as a String,
    /// not the Error itself, so the outcome stays Sendable for the
    /// task group; the caller re-wraps it (DelayTransportFailure)
    /// for the banner.
    private enum DelayTargetOutcome {
        case value(DelayTarget, Int32)
        case guardTimedOut(DelayTarget)
        case transportFailed(DelayTarget, String)
    }

    /// A transport failure re-wrapped for the banner (the message
    /// is the RPC error's localizedDescription, verbatim).
    private struct DelayTransportFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One-shot gate for the delay-test guard race (v0.2.49):
    /// the RPC task and the 30 s guard task both try to resume
    /// the same continuation; only the first wins and the loser's
    /// result is discarded. Lets runOneDelayTest return at the
    /// guard even if the RPC task never finishes (a
    /// withThrowingTaskGroup would wait for that child forever).
    private final class DelayGuardGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<DelayTargetOutcome, Never>?
        func arm(_ continuation: CheckedContinuation<DelayTargetOutcome, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
        func resume(with outcome: DelayTargetOutcome) {
            lock.lock()
            guard !resumed, let continuation else { lock.unlock(); return }
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        }
    }

    /// Forces the current "统一延迟测试" value into the core that
    /// is about to run the delay test, then reads that core's ACTUAL
    /// unified_delay back (v0.2.89): on-device, the switch ON / OFF
    /// / flip / full restart all measured the same cold numbers, so
    /// the value evidently never reached the test core — patching
    /// immediately before the test closes the stale-core gap, and
    /// the read-back makes the core's real value visible in the
    /// report instead of guessed. Best-effort: a failed patch or
    /// read only changes the line (or leaves it out) — the test
    /// always runs. Returns the report line, or nil in sample mode
    /// (no real core).
    /// Do not start a second core while NetworkExtension is transitioning.
    @MainActor
    private func verifyDelayBackend() async throws {
        guard client.mode == .live else { return }
        switch TunnelManager.shared.status {
        case .connected:
            _ = try await client.configGeneral()
        case .disconnected, .invalid:
            break
        default:
            throw NSError(domain: "DelayBackend", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "VPN 正在切换，暂不能测速；请等待连接完成或完全断开"])
        }
    }

    @MainActor
    private func unifiedDelayDiagnosticLine(useAppCore: Bool) async -> String? {
        guard client.mode == .live else { return nil }
        guard let settings = settingsStore else {
            return "统一延迟测试：设置未就绪，未修改核心开关"
        }
        let enabled = settings.unifiedDelay
        let switchText = enabled ? "开" : "关"
        do {
            if useAppCore {
                try await AppCore.shared.setUnifiedDelay(enabled)
            } else {
                try await client.setUnifiedDelay(enabled)
            }
        } catch {
            return "统一延迟测试：设置开关\(switchText)，写入失败（\(error.localizedDescription)）"
        }
        do {
            let general: ConcordGeneralState
            if useAppCore {
                general = try await AppCore.shared.configGeneral()
            } else {
                general = try await client.configGeneral()
            }
            guard let actual = general.unifiedDelay else {
                return "统一延迟测试：设置开关\(switchText)，核心响应缺少 unifiedDelay，无法确认是否生效"
            }
            let coreText = actual ? "开" : "关"
            let verification = actual == enabled ? "（已校验）" : "（不一致，设置未生效）"
            return "统一延迟测试：设置开关\(switchText)，测速核心实际值\(coreText)\(verification)"
        } catch {
            return "统一延迟测试：设置开关\(switchText)，测速核心实际值读取失败（\(error.localizedDescription)）"
        }
    }

    /// One delay.test call with the 30 s outer guard (FlClash
    /// delayTestGuardDuration, lib/common/constant.dart:62, applied
    /// to the testDelay call in lib/core/interface.dart:195). The
    /// RPC layer keeps its own timeout underneath — 15 s on the
    /// app-side core (AppCore.sendRequest default), 30 s for
    /// delay.* on the extension path (TunnelManager
    /// timeoutForMethod) — so the guard is a backstop for a call
    /// that neither returns nor times out on its own. A guard
    /// timeout is NOT a node failure: it comes back as
    /// .guardTimedOut and the caller records -1 (FlClash
    /// delayTimedOutValue, constant.dart:64).
    ///
    /// v0.2.49: the guard is a DETACHED-task race, not a
    /// withThrowingTaskGroup — the group waits for every child,
    /// so a child that never returned (lost reply, hung
    /// transport) defeated the guard and stalled the whole run:
    /// testingGroups never cleared and every later tap was
    /// refused. Here the first of (RPC result, 30 s sleep) wins
    /// and the run moves on; a late RPC result is discarded.
    private func runOneDelayTest(target: DelayTarget, useAppCore: Bool) async -> DelayTargetOutcome {
        let gate = DelayGuardGate()
        return await withCheckedContinuation { continuation in
            gate.arm(continuation)
            let proxyName = target.proxyName
            let testUrl = target.testUrl
            let timeoutMs = delayTimeoutMs
            let client = self.client
            Task.detached {
                let outcome: DelayTargetOutcome
                do {
                    let result: ConcordDelayResult
                    if useAppCore {
                        result = try await AppCore.shared.delayTest(proxy: proxyName, url: testUrl, timeout: timeoutMs)
                    } else {
                        result = try await client.delayTest(proxy: proxyName, url: testUrl, timeout: timeoutMs)
                    }
                    outcome = .value(target, result.value)
                } catch {
                    outcome = .transportFailed(target, error.localizedDescription)
                }
                gate.resume(with: outcome)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                gate.resume(with: .guardTimedOut(target))
            }
        }
    }

    /// What the provider preload step found (B2 second version).
    /// `updated` lists the providers that were actually updated —
    /// empty when nothing was missing, or when the loaded-names
    /// check itself was unavailable (the test then surfaces a
    /// dead channel on its own).
    private enum ProviderPreload {
        case ready(updated: [String])
        case stillMissing(reason: String, updated: [String])
    }

    /// Makes sure the providers behind `names` are really loaded
    /// in the core BEFORE any delay.test runs — the step the first
    /// B version was missing. Flow: seedProviderCache inside
    /// ensureStarted only COPIES the cache, and when the user has
    /// never started the VPN there is no cache to copy; the
    /// providers' own pull at config.apply may then fail on this
    /// network exactly like the MMDB download did, and
    /// config.apply still succeeds with zero provider nodes, so
    /// every delay.test returns -2 with no throw.
    ///   1. missingLoadedNames: all present
    ///      → .ready (nothing updated).
    ///   2. Missing → update the owning providers (group rows
    ///      carry the provider name; when no row attributes a
    ///      missing name, every provider from provider.list).
    ///      Upstream provider.update pulls and swaps the node set
    ///      LIVE (crates/group/src/provider/mod.rs update() ->
    ///      pull() -> load_buf() -> apply(): nodes.store +
    ///      route.moved + request_refresh), so NO config.apply is
    ///      needed afterwards. Cold-start exception: an update
    ///      that answers `config is not applied` (the call raced
    ///      ahead of config.apply) is retried once after ~2 s,
    ///      and if it still answers that, the banner says the
    ///      core is still starting — never "提供方更新失败".
    ///   3. Re-check the names against a fresh inventory. Still
    ///      missing → .stillMissing with a precise banner, not the
    ///      old generic "更新成功但仍没有…请检查订阅": the provider
    ///      update error verbatim when the update failed; when it
    ///      did not throw, the provider name(s) updated plus what
    ///      each one actually holds now (live count + a sample of
    ///      real names) — so a rename upstream reads as a rename,
    ///      and an empty provider reads as empty. When NO provider
    ///      was updated at all (no provider owns the names and
    ///      provider.list is empty — e.g. a literal-proxy config
    ///      with no proxy-providers), the banner says exactly that
    ///      instead of claiming a successful update that never
    ///      happened. The test still runs afterwards: loaded nodes
    ///      get real results, missing ones return -2.
    /// Sample mode skips this entirely (its data is fake).
    private func ensureProvidersLoaded(for names: [String], useAppCore: Bool) async -> ProviderPreload {
        guard client.mode == .live else { return .ready(updated: []) }
        guard let missing = await missingLoadedNames(names), !missing.isEmpty else {
            return .ready(updated: [])
        }
        // Which provider owns each missing node? The group rows
        // carry it (proxy.groups nodes[].provider, and the local
        // YAML parse for the offline list). One node name can sit
        // in several groups, so duplicates keep the first provider
        // (uniqueKeysWithValues would trap on a repeated name).
        let providerByNode: [String: String] = Dictionary(
            allNodes.compactMap { node in
                node.provider.map { (node.name, $0) }
            },
            uniquingKeysWith: { first, _ in first })
        var providers = Set(missing.compactMap { providerByNode[$0] })
        if providers.isEmpty {
            // No row attributes the missing names to a provider
            // (e.g. a stale pick): update every provider the core
            // knows, then re-check.
            do {
                let list: ConcordProviderList
                if useAppCore {
                    list = try await AppCore.shared.providerList()
                } else {
                    list = try await client.providerList()
                }
                providers = Set(list.providers.map { $0.name })
            } catch {
                return .stillMissing(
                    reason: "测速前检查提供方失败：无法列出提供方（\(error.localizedDescription)），核心已加载的配置里没有这 \(missing.count) 个节点，测速会失败（-2）。",
                    updated: [])
            }
        }
        var updated: [String] = []
        var updateErrors: [(provider: String, error: String)] = []
        // The cold-start race (WWW-MuYu-Love/FlClash 12aa5f6f):
        // provider.update reached a core that has not applied any
        // config yet. That is not a failure — waiting fixes it —
        // so those providers are kept out of updateErrors (and its
        // "提供方更新失败" banner) and retried once below.
        var notApplied: [String] = []
        // v0.2.49: the updates run CONCURRENTLY (one TaskGroup
        // child per provider), not one after another. Each
        // provider.update carries a 60 s timeout for a slow
        // network pull, so the sequential loop cost N×60 s for N
        // providers — the whole preload could grind for 10 min
        // while the delay test waited, which reads on-device as
        // "the test never starts". Providers are independent
        // (each pulls its own URL and swaps its own node set),
        // and FlClash updates providers concurrently too
        // (maxConcurrentImports). Results are collected first,
        // then processed in sorted order, so the reporting stays
        // deterministic. The cold-start retry below stays
        // sequential (it is usually 0–1 providers).
        let updateResults: [(String, Result<Void, Error>)] = await withTaskGroup(of: (String, Result<Void, Error>).self) { group in
            for provider in providers.sorted() {
                group.addTask {
                    do {
                        if useAppCore {
                            try await AppCore.shared.providerUpdate(name: provider)
                        } else {
                            try await self.client.providerUpdate(name: provider)
                        }
                        return (provider, .success(()))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<Void, Error>)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (provider, result) in updateResults.sorted(by: { $0.0 < $1.0 }) {
            switch result {
            case .success:
                updated.append(provider)
            case .failure(let error):
                if case AppCoreError.configNotApplied = error {
                    notApplied.append(provider)
                } else if case ConcordClientError.configNotApplied = error {
                    notApplied.append(provider)
                } else {
                    updateErrors.append((provider, error.localizedDescription))
                }
            }
        }
        // One retry for the cold-start race only: give the core
        // ~2 s to finish applying, then update just those
        // providers once more. Still not applied after the retry
        // stays out of updateErrors — the stillMissing reason
        // below says the core is still starting instead of
        // reporting a failure. The single warning line lands in
        // the delay-test diagnostic report via that reason
        // (preloadNote -> writeReport -> last-delay-test-report
        // .txt, included in the Logs export): LogStore itself
        // only replays the core's own log stream, so there is no
        // app-side append API to write a warning to.
        var coreNotReady = false
        if !notApplied.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for provider in notApplied {
                do {
                    if useAppCore {
                        try await AppCore.shared.providerUpdate(name: provider)
                    } else {
                        try await client.providerUpdate(name: provider)
                    }
                    updated.append(provider)
                } catch {
                    if case AppCoreError.configNotApplied = error {
                        coreNotReady = true
                    } else if case ConcordClientError.configNotApplied = error {
                        coreNotReady = true
                    } else {
                        updateErrors.append((provider, error.localizedDescription))
                    }
                }
            }
        }
        // Re-check with a fresh inventory (one proxy.groups call):
        // it says which names are still missing AND what each
        // updated provider actually holds now — the two facts the
        // old generic "更新成功但仍没有" text never had. When the
        // re-check itself fails, claim nothing about the update:
        // the test below surfaces a dead channel on its own —
        // unless the core is known not ready (the retry above
        // still raced apply): then a .ready would run delay.test
        // against a core with no applied config, so report the
        // not-ready state instead.
        guard let after = await loadedInventory() else {
            if coreNotReady {
                return .stillMissing(
                    reason: "核心还在启动，请稍后再试",
                    updated: updated)
            }
            return .ready(updated: updated)
        }
        let stillMissing = Set(names).subtracting(after.loaded)
        guard !stillMissing.isEmpty else {
            return .ready(updated: updated)
        }
        if coreNotReady, updateErrors.isEmpty {
            // The retry still raced the core: do NOT banner this
            // as a provider failure — the core simply has not
            // applied its config yet. (When other providers failed
            // for real reasons, updateErrors is non-empty and the
            // existing failure banner below keeps precedence.)
            return .stillMissing(
                reason: "核心还在启动，请稍后再试",
                updated: updated)
        }
        if !updateErrors.isEmpty {
            let detail = updateErrors.prefix(2).map { "\($0.provider)：\($0.error)" }.joined(separator: "；")
            let suffix = updateErrors.count > 2 ? "；等 \(updateErrors.count) 个提供方" : ""
            return .stillMissing(
                reason: "提供方更新失败：\(detail)\(suffix)。核心已加载的配置里仍没有这 \(stillMissing.count) 个节点，测速会失败（-2）。请检查订阅链接/网络后重试。",
                updated: updated)
        }
        let shown = stillMissing.sorted().prefix(3).joined(separator: "、")
        let shownSuffix = stillMissing.count > 3 ? "…" : ""
        if updated.isEmpty {
            // Nothing was updated at all: no row attributes the
            // missing names to a provider, and provider.list came
            // back empty, so the update loop ran zero times. The
            // old text still printed "提供方更新成功" here — a
            // success that never happened. Say so, with whatever
            // the inventory shows, if anything.
            let actual = describeProviderContents(after.namesByProvider)
            let actualSuffix = actual.isEmpty ? "" : "（\(actual)）"
            return .stillMissing(
                reason: "没有可更新的提供方：核心的提供方列表为空，刚才没有更新任何提供方。核心已加载的配置里仍没有这 \(stillMissing.count) 个节点（\(shown)\(shownSuffix)）\(actualSuffix)，测速会失败（-2）。当前配置可能没有 proxy-providers（节点直接写在配置文件里），请检查订阅内容或配置文件。",
                updated: updated)
        }
        // Updated, still missing: name the providers and what each
        // one actually holds now, so the user can see whether the
        // subscription renamed the nodes or the provider is empty.
        let actual = describeProviderContents(after.namesByProvider, only: Set(updated))
        return .stillMissing(
            reason: "已更新提供方：\(updated.sorted().joined(separator: "、"))，但核心已加载的配置里仍没有这 \(stillMissing.count) 个节点（\(shown)\(shownSuffix)）。\(actual)。订阅里的节点名可能已变更，请对照提供方实际的节点名检查订阅。",
            updated: updated)
    }

    /// Runs the resolved targets, FlClash-style (lib/providers/
    /// actions/proxies.dart _runDelayTests, :405-445): every target
    /// gets exactly ONE delay.test call (timeout = the settings
    /// delayTestTimeout, default 8000 ms — constant.dart:60), run
    /// in parallel with at most delayTestBatchSize (32) in flight
    /// (upstream caps iOS at 2 — TaskPool maxConcurrentDelayTests
    /// = 2, constant.dart:99; see the note below), each
    /// call guarded by a 30 s outer timeout (delayTestGuardDuration,
    /// constant.dart:62, applied in lib/core/interface.dart:195).
    /// There is deliberately NO delay.run batch here any more (B2
    /// second version): the batch event stream is an extra failure
    /// surface on the in-app core and upstream never uses it for
    /// manual delay tests. The delayRunStart/delayRunPoll wrappers
    /// in ConcordClient/AppCore are left in place, unused.
    /// A returned value is the verdict (-1 timeout, -2 failure);
    /// a THROW is a transport failure (the core never throws for a
    /// dead node — urltest.rs test_delay returns Failed), so it
    /// records -2 for that node and, after 3 such throws, cancels
    /// the rest of the run: the backend is down, not the nodes.
    /// How many delay.test calls run at once (v0.2.64, user
    /// direction 2026-11-22: "一次测多少个改的和上游一样"):
    /// upstream FlClash caps iOS at 2 but runs 32 on
    /// Windows/Android (lib/common/constant.dart:99:
    /// maxConcurrentDelayTests = Platform.isIOS ? 2 : 32,
    /// TaskPool in providers/actions/proxies.dart:30). 2 made a
    /// 43-node run take ~9 minutes (log 2026-11-22 18:44:
    /// 566 s) while fast nodes waited behind slow ones; 32
    /// matches the upstream Windows/Android behaviour the user
    /// asked for. The per-outcome applyLatencies() streaming
    /// (same version) shows each result as it lands.
    private static let delayTestBatchSize = 32
    @MainActor
    private func runLatencyTest(targets: [DelayTarget], groupNames: Set<String>) async {
        let startedAt = Date()
        let backend = client.mode == .live
            ? (TunnelManager.shared.isRunning ? "隧道核心（VPN 运行中）" : "应用内核心（VPN 未运行）")
            : "示例数据"
        let timeoutMs = delayTimeoutMs
        /// The active profile this run tests (v0.2.49): the 12:05
        /// card did not name it, so a failure could not be tied to
        /// a subscription.
        let profileName = profileStore?.activeProfile?.name
        var okCount = 0, timeoutCount = 0, failedCount = 0
        /// How many calls hit the 30 s guard / threw on transport
        /// (v0.2.49): the 12:15 card's "0 返回，43 未返回" could not
        /// tell grinding from stuck — these counts can.
        var guardTimedOutCount = 0
        var transportThrowCount = 0
        /// Names of the nodes whose delay.test call threw on the
        /// transport layer (v0.2.58): they are recorded as -2 like a
        /// core failure, but the names tell the report which -2s are
        /// call failures, not dead nodes.
        var transportFailedNames: [String] = []
        var throwError: Error?
        var preloadNote: String?
        var channelNote: String?
        /// The unified_delay force-apply + read-back line (v0.2.89):
        /// set just before the test loop; nil in sample mode or when
        /// the run exits before the loop (then the defer omits it).
        var unifiedDelayDiagnostic: String?
        /// Set when this tap starts nothing because a test for the
        /// same group(s) is already in flight: the report still
        /// updates, so a stuck earlier run is visible instead of a
        /// stale card (v0.2.48: the old guard returned before the
        /// defer was installed, so a tap during an in-flight run
        /// left the 00:09:29 card untouched).
        var skippedNote: String?
        /// Set when this tap cleared a stale in-flight run and
        /// started fresh (v0.2.49 stale recovery, see the guard
        /// below).
        var supersededStaleNote: String?
        /// Phase durations in seconds, for the report: a run that
        /// grinds is only diagnosable when the card says WHERE the
        /// time went (boot / preload / the test loop itself).
        var bootSeconds: Int?
        var preloadSeconds: Int?
        var loopSeconds: Int?
        // The diagnostic report for the Logs export (method, params,
        // per-node outcome counts, channel diagnosis): written on
        // EVERY exit — including the early ones below — so the file
        // the user sends always describes the last run, never a
        // stale one. Counts are tallied in the shared tail from the
        // recorded latencies (one record per target — the parallel
        // loop records each outcome exactly once), so the counts
        // cannot double-count. The sampled target names are the
        // exact strings passed to delay.test, so a name mismatch
        // between the page and the core is visible in the export.
        defer {
            let untested = targets.count - okCount - timeoutCount - failedCount
            let urlText = Set(targets.map { $0.testUrl }).sorted().joined(separator: "、")
            let everText = everDelaySucceeded ? "是" : "否"
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            var lines = ["[\(Self.reportTimestamp(startedAt))] 测速诊断（\(backend)）"]
            if let profileName { lines.append("当前订阅：\(profileName)") }
            lines.append("方法：delay.test（逐个，并行 \(Self.delayTestBatchSize) 个）；超时：\(timeoutMs)ms（单次调用另有 30s 兜底）")
            if let unifiedDelayDiagnostic { lines.append(unifiedDelayDiagnostic) }
            lines.append("测速地址：\(urlText)")
            lines.append("目标：\(targets.count) 个节点；结果：成功 \(okCount)，超时(-1) \(timeoutCount)，失败(-2) \(failedCount)，未返回 \(untested)")
            let targetSample = targets.prefix(5).map { $0.proxyName }.joined(separator: "、")
            if !targetSample.isEmpty {
                lines.append("目标节点（前 5，传给 delay.test 的原名）：\(targetSample)" + (targets.count > 5 ? "…" : ""))
            }
            if failedCount > 0 {
                let failedNames = targets.filter { latency(for: $0) == -2 }.map { $0.proxyName }
                let failedText = failedNames.prefix(8).joined(separator: "、") + (failedNames.count > 8 ? "…" : "")
                lines.append("失败节点（前 8）：\(failedText)")
            }
            if guardTimedOutCount > 0 {
                lines.append("守卫超时（单次调用 30s 未返回）：\(guardTimedOutCount) 次")
            }
            if transportThrowCount > 0 {
                lines.append("传输失败（调用抛错）：\(transportThrowCount) 次")
            }
            if !transportFailedNames.isEmpty {
                let transportNamesText = transportFailedNames.prefix(8).joined(separator: "、") + (transportFailedNames.count > 8 ? "…" : "")
                lines.append("传输层失败节点（前 8，调用抛错而非核心 -2）：\(transportNamesText)")
            }
            var phaseBits: [String] = []
            if let bootSeconds { phaseBits.append("启动 \(bootSeconds)s") }
            if let preloadSeconds { phaseBits.append("预加载 \(preloadSeconds)s") }
            if let loopSeconds { phaseBits.append("测速 \(loopSeconds)s") }
            if !phaseBits.isEmpty || elapsed > 0 {
                lines.append("耗时：\(phaseBits.joined(separator: "，"))（本次共 \(elapsed)s）")
            }
            if let preloadNote { lines.append("提供方预加载：\(preloadNote)") }
            if let throwError { lines.append("调用失败：\(throwError.localizedDescription)") }
            if let channelNote { lines.append("通道诊断：\(channelNote)") }
            if let supersededStaleNote { lines.append(supersededStaleNote) }
            if let skippedNote { lines.append(skippedNote) }
            lines.append("此前是否测速成功过：\(everText)")
            AppCore.recordDelayTestReport(lines.joined(separator: "\n"))
        }
        // Stale-run recovery (v0.2.49): a run that never returns
        // used to lock its groups forever — every later tap was
        // refused with no way out. A run "in progress" for over
        // 5 min with no result is treated as dead: clear it and
        // start fresh. A younger in-flight run still refuses the
        // tap, but the report now says how long it has been
        // running, so grinding and stuck are distinguishable.
        let overlapping = testingGroups.intersection(groupNames)
        if !overlapping.isEmpty {
            let now = Date()
            let stale = overlapping.filter { group in
                guard let started = testingGroupsStartedAt[group] else { return true }
                return now.timeIntervalSince(started) > Self.staleTestRunSeconds
            }
            if stale.isEmpty {
                let oldest = overlapping.compactMap { testingGroupsStartedAt[$0] }.min() ?? now
                let elapsed = Int(now.timeIntervalSince(oldest))
                skippedNote = "本次点击未启动新测速：同一策略组已有测速在进行中（已进行 \(elapsed) 秒；若超过 5 分钟仍无结果，下次点击会自动清除旧测速并重新开始）"
                return
            }
            testingGroups.subtract(stale)
            for group in stale { testingGroupsStartedAt.removeValue(forKey: group) }
            supersededStaleNote = "已清除超过 5 分钟未完成的旧测速（\(stale.sorted().joined(separator: "、"))），重新开始"
        }
        // No resolvable target (e.g. a group whose members are all
        // nested groups with no current pick): tapping the bolt
        // used to do nothing at all — say why instead.
        guard !targets.isEmpty else {
            noteTestMessage("该组没有可测速的节点（成员无法解析为真实节点，或策略组未选择节点）")
            return
        }
        testingGroups.formUnion(groupNames)
        for group in groupNames { testingGroupsStartedAt[group] = startedAt }
        defer {
            testingGroups.subtract(groupNames)
            for group in groupNames { testingGroupsStartedAt.removeValue(forKey: group) }
        }
        // A new run supersedes the old results: clear the targets'
        // recorded latencies first, so the page shows the testing
        // state instead of stale -2s from the previous run
        // (v0.2.49, IMG_1163: every row showed 测速失败 from an
        // earlier completed run while a new run was still in
        // flight). Fresh results land per batch below.
        do {
            try await verifyDelayBackend()
        } catch {
            throwError = error
            noteTestError(error)
            return
        }
        clearLatencies(for: targets)
        applyLatencies()
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
        let bootStart = Date()
        if useAppCore {
            do {
                try await AppCore.shared.ensureStarted()
            } catch {
                bootSeconds = Int(Date().timeIntervalSince(bootStart))
                throwError = error
                noteTestError(error)
                return
            }
        }
        bootSeconds = Int(Date().timeIntervalSince(bootStart))
        // Provider preload (B2 second version): seedProviderCache
        // inside ensureStarted only copies the cache — when the user
        // has never started the VPN there is no cache to copy, and
        // the providers' own pull may fail on this network exactly
        // like the MMDB download did. So before testing, check
        // whether the loaded config even knows these names; if not,
        // update the owning providers (live swap, no config.apply —
        // see ensureProvidersLoaded) and re-check. Still missing
        // after that is a banner with the real reason, not a silent
        // wall of -2s. Sample mode skips this: its data is fake.
        let preload: ProviderPreload
        let preloadStart = Date()
        if client.mode == .live {
            preload = await ensureProvidersLoaded(for: targets.map { $0.proxyName }, useAppCore: useAppCore)
            switch preload {
            case .ready(let updated):
                if !updated.isEmpty {
                    preloadNote = "已更新提供方：\(updated.joined(separator: "、"))；复查后节点已全部加载"
                }
            case .stillMissing(let reason, let updated):
                preloadNote = updated.isEmpty ? reason : "已更新提供方：\(updated.joined(separator: "、"))；\(reason)"
                noteTestMessage(reason)
            }
        } else {
            preload = .ready(updated: [])
        }
        preloadSeconds = Int(Date().timeIntervalSince(preloadStart))
        // v0.2.89: force the current "统一延迟测试" value into the
        // core that is about to test, and read its actual value
        // back for the report (see unifiedDelayDiagnosticLine) —
        // the last thing before the loop, so no boot or flip in
        // between can leave the test core stale.
        unifiedDelayDiagnostic = await unifiedDelayDiagnosticLine(useAppCore: useAppCore)
        // One delay.test per target, at most delayTestBatchSize in
        // flight (see the constant above for why 10, not
        // upstream's iOS cap of 2). Each call carries the settings
        // timeout and the 30 s guard; see runOneDelayTest.
        var firstTransportError: Error?
        var cancelledByTransport = false
        var index = 0
        let loopStart = Date()
        while index < targets.count, !cancelledByTransport {
            let batch = Array(targets[index..<min(index + Self.delayTestBatchSize, targets.count)])
            index += batch.count
            await withTaskGroup(of: DelayTargetOutcome.self) { group in
                for target in batch {
                    group.addTask { await self.runOneDelayTest(target: target, useAppCore: useAppCore) }
                }
                for await outcome in group {
                    switch outcome {
                    case .value(let target, let value):
                        recordLatency(name: target.proxyName, url: target.testUrl, value: value)
                    case .guardTimedOut(let target):
                        recordLatency(name: target.proxyName, url: target.testUrl, value: -1)
                        guardTimedOutCount += 1
                    case .transportFailed(let target, let message):
                        // A throw is a transport failure, never a
                        // dead node — but the node still shows as
                        // failed (-2) instead of silently untested.
                        recordLatency(name: target.proxyName, url: target.testUrl, value: -2)
                        transportThrowCount += 1
                        transportFailedNames.append(target.proxyName)
                        if firstTransportError == nil { firstTransportError = DelayTransportFailure(message: message) }
                        if transportThrowCount >= 3 { cancelledByTransport = true }
                    }
                    // Stream results: recordLatency only writes the
                    // dictionaries — the page reads groups, which
                    // applyLatencies() rebuilds — so without this a
                    // fast result waits for its whole batch's slowest
                    // call before it shows (v0.2.64).
                    applyLatencies()
                }
            }
            applyLatencies()
        }
        loopSeconds = Int(Date().timeIntervalSince(loopStart))
        if let firstTransportError { throwError = firstTransportError }
        // Tally the run from the recorded latencies (one record per
        // target — the parallel loop records each outcome once).
        for target in targets {
            switch latency(for: target) {
            case .some(let value) where value > 0:
                okCount += 1
            case .some(-1):
                timeoutCount += 1
            case .some:
                failedCount += 1
            case .none:
                break
            }
        }
        if okCount > 0 { everDelaySucceeded = true }
        // Failure handling, FlClash _runDelayTest (:449-458): only a
        // dead core cancels the job. Three transport throws in one
        // run mean the backend is down — a dead node returns -2, it
        // never throws (urltest.rs test_delay) — so the run was cut
        // short above and the banner carries the real transport
        // reason instead of silence.
        if cancelledByTransport, let firstTransportError {
            noteTestError(firstTransportError)
            channelNote = "传输层连续失败 \(transportThrowCount) 次，已停止剩余测速：\(firstTransportError.localizedDescription)"
        } else if client.mode == .live, okCount == 0, failedCount == targets.count {
            // FIX 1b (v0.2.45): all targets -2 AND the core's
            // provider list empty → config.validate may name the
            // real fault (e.g. a RULE-SET provider the config
            // references but never defines). The hint is APPENDED
            // to the banner + the report; the existing precise
            // wording about WHICH nodes are missing is kept, and
            // when validate finds nothing the existing wording
            // stands unchanged (empty suffix appends nothing).
            let validateHint = await validateHintIfProvidersEmpty(useAppCore: useAppCore)
            let validateSuffix = validateHint.map { "（\($0)）" } ?? ""
            if case .stillMissing = preload {
                // The preload already explained why, with the
                // provider.update error verbatim — keep that instead
                // of the generic membership verdict below. (The
                // banner was set at preload time; the validate
                // hint is appended to it + the report line here.)
                channelNote = preloadNote.map { $0 + validateSuffix }
                if !validateSuffix.isEmpty, let banner = testError {
                    noteTestMessage(banner + validateSuffix)
                }
            } else {
                // Channel failure vs dead nodes: -2 is a VALUE, never a
                // throw, so a run where every node fails -2 never set
                // testError — the page showed red cards and total silence
                // (IMG_1145). Upstream returns -2 for a name that is not
                // part of the applied config (urltest.rs test_delay), which
                // is exactly what happens when the subscription's provider
                // never loaded — so all -2 with no success is a channel
                // failure until proven otherwise: check whether the loaded
                // config even knows these names.
                let names = targets.map { $0.proxyName }
                if let inventory = await loadedInventory() {
                    let missing = Set(names).subtracting(inventory.loaded)
                    if !missing.isEmpty {
                        let shown = missing.sorted().prefix(3).joined(separator: "、")
                        let shownSuffix = missing.count > 3 ? "…" : ""
                        noteTestMessage("测速通道异常：核心已加载的配置里没有这 \(missing.count) 个节点（\(shown)\(shownSuffix)），很可能是订阅提供方还没加载。请先启动一次 VPN 再回来测速，仍失败请把日志导出发来定位。\(validateSuffix)")
                        let missingShown = missing.sorted().prefix(8).joined(separator: "、")
                        // The report line names what the providers
                        // actually hold, so the exported log shows
                        // the rename/empty-provider mismatch instead
                        // of only the gap.
                        let actual = describeProviderContents(inventory.namesByProvider)
                        channelNote = "核心缺少节点 \(missingShown)（共 \(missing.count) 个）" + (actual.isEmpty ? "；提供方缓存见启动诊断" : "；\(actual)") + validateSuffix
                    } else {
                        noteTestMessage("测速通道异常：\(targets.count) 个节点全部测速失败（-2），核心里有这些节点，但拨测全部失败——可能是节点已失效或当前网络不通。请检查订阅是否过期，或把日志导出发来定位。\(validateSuffix)")
                        channelNote = "核心里有这些节点，但 delay 拨测全部返回 -2" + validateSuffix
                    }
                } else {
                    noteTestMessage("测速通道异常：\(targets.count) 个节点全部测速失败（-2），且无法确认核心是否加载了这些节点（查询失败）。请把日志导出发来定位。\(validateSuffix)")
                    channelNote = "全部 -2；核心节点查询失败，无法区分通道故障与节点故障" + validateSuffix
                }
            }
        }
        lastError = nil
    }

    /// One node's delay (the per-node chip tap). The tapped row may
    /// itself be a nested group: it is resolved to the real node it
    /// currently picks, dialled with that nested group's own test
    /// URL (audit B3, FlClash _handleTestCurrentDelay +
    /// _resolveDelayTestTargets); a plain node is dialled with the
    /// group's test URL, else the stored override test-url (B24),
    /// else the FlClash default URL — never empty. Every call
    /// passes the timeout explicitly (audit B1). Uses the app-side
    /// core when the VPN is off; runs through the same per-target
    /// path as the all-groups test (runOneDelayTest: settings timeout +
    /// 30 s guard) and the same provider preload first. A transport
    /// failure only sets lastError/testError and marks the chip
    /// failed (-2), never silent; a guard timeout shows as 超时
    /// (-1). A nested group with no current pick cannot be dialled:
    /// the chip stays untested and the banner says why.
    @MainActor
    func testLatency(node: ProxyNode, testURL: String? = nil) async {
        let startedAt = Date()
        let backend = client.mode == .live
            ? (TunnelManager.shared.isRunning ? "隧道核心（VPN 运行中）" : "应用内核心（VPN 未运行）")
            : "示例数据"
        let profileName = profileStore?.activeProfile?.name
        // Same stale-run recovery as the group path (v0.2.49): a
        // single-node test older than 5 min is dead — clear it and
        // start fresh instead of refusing forever.
        if testingNodes.contains(node.name) {
            let stale: Bool
            if let started = testingNodesStartedAt[node.name] {
                stale = Date().timeIntervalSince(started) > Self.staleTestRunSeconds
            } else {
                stale = true
            }
            if !stale {
                // v0.2.48: like the group path, a tap during an
                // in-flight test still writes a fresh report instead
                // of leaving a stale card.
                AppCore.recordDelayTestReport("[\(Self.reportTimestamp(startedAt))] 测速诊断（\(backend)，单节点）\n方法：delay.test；节点：\(node.name)\n结果：未测速：该节点已有测速在进行中")
                return
            }
            testingNodes.remove(node.name)
            testingNodesStartedAt.removeValue(forKey: node.name)
        }
        testingNodes.insert(node.name)
        testingNodesStartedAt[node.name] = startedAt
        testError = nil
        testErrorIsGeoSeed = false
        lastTest = .node(node, testURL: testURL)
        defer {
            testingNodes.remove(node.name)
            testingNodesStartedAt.removeValue(forKey: node.name)
        }
        let fallbackURL = firstNonEmpty(testURL, overrideTestURL(), Self.defaultTestURL) ?? Self.defaultTestURL
        guard let target = resolveDelayTarget(memberName: node.name, fallbackTestUrl: fallbackURL) else {
            let reason = "该节点当前没有可测速的真实节点（策略组未选择节点）"
            lastError = reason
            testError = reason
            // v0.2.48: the group path writes a fresh report on
            // every exit — do the same here, so this tap does not
            // leave a stale card either.
            AppCore.recordDelayTestReport("[\(Self.reportTimestamp(startedAt))] 测速诊断（\(backend)，单节点）\n方法：delay.test；节点：\(node.name)\n结果：未测速：\(reason)")
            return
        }
        // Clear the stale result for this node first (v0.2.49,
        // same as the group path): the chip shows the testing
        // state, not the previous run's -2.
        do {
            try await verifyDelayBackend()
        } catch {
            noteTestError(error)
            AppCore.recordDelayTestReport("单节点未测速：\(error.localizedDescription)")
            return
        }
        clearLatencies(for: [target])
        applyLatencies()
        let useAppCore = client.mode == .live && !TunnelManager.shared.isRunning
        // v0.2.89: the unified_delay force-apply + read-back line,
        // set after the preload below; nil until then (and in sample
        // mode), so the early writeReport calls omit it.
        var unifiedDelayDiagnostic: String?
        // Writes the single-node diagnostic report (last-delay-
        // test-report.txt) for one outcome. `extra` carries the
        // channel diagnosis, if any; the preload line is added
        // when the preload ran and did anything.
        func writeReport(resultLine: String, preloadNote: String?, extra: [String] = []) {
            var lines = ["[\(Self.reportTimestamp(startedAt))] 测速诊断（\(backend)，单节点）"]
            if let profileName { lines.append("当前订阅：\(profileName)") }
            lines.append("方法：delay.test；节点：\(target.proxyName)；测速地址：\(target.testUrl)；超时：\(delayTimeoutMs)ms（单次调用另有 30s 兜底）")
            if let unifiedDelayDiagnostic { lines.append(unifiedDelayDiagnostic) }
            lines.append("结果：\(resultLine)")
            if let preloadNote { lines.append("提供方预加载：\(preloadNote)") }
            lines.append(contentsOf: extra)
            lines.append("此前是否测速成功过：\(everDelaySucceeded ? "是" : "否")")
            AppCore.recordDelayTestReport(lines.joined(separator: "\n"))
        }
        // ensureStarted throws (no config / core won't boot) are a
        // dead backend, not a dead node: banner the real reason.
        if useAppCore {
            do {
                try await AppCore.shared.ensureStarted()
            } catch {
                noteTestError(error)
                writeReport(resultLine: "调用失败：\(error.localizedDescription)", preloadNote: nil)
                return
            }
        }
        // Provider preload, same as the all-groups path.
        var preloadNote: String?
        if client.mode == .live {
            switch await ensureProvidersLoaded(for: [target.proxyName], useAppCore: useAppCore) {
            case .ready(let updated):
                if !updated.isEmpty {
                    preloadNote = "已更新提供方：\(updated.joined(separator: "、"))；复查后节点已全部加载"
                }
            case .stillMissing(let reason, let updated):
                preloadNote = updated.isEmpty ? reason : "已更新提供方：\(updated.joined(separator: "、"))；\(reason)"
                noteTestMessage(reason)
            }
        }
        // v0.2.89: force-apply + read back, same as the group path.
        unifiedDelayDiagnostic = await unifiedDelayDiagnosticLine(useAppCore: useAppCore)
        switch await runOneDelayTest(target: target, useAppCore: useAppCore) {
        case .value(_, let value):
            recordLatency(name: target.proxyName, url: target.testUrl, value: value)
            applyLatencies()
            if value > 0 { everDelaySucceeded = true }
            let resultText = value > 0 ? "成功 \(value)ms" : value == -1 ? "超时(-1)" : "失败(-2)"
            var extra: [String] = []
            if value == -2, client.mode == .live, testError == nil {
                // A single -2 is usually a dead node — except when
                // the name is not in the loaded config at all
                // (provider never loaded), which is a channel
                // failure and deserves the banner, not silence.
                // (The preload above already tried provider.update,
                // so this only fires when the preload check was
                // unavailable or the name vanished mid-run.)
                if let missing = await missingLoadedNames([target.proxyName]),
                   missing.contains(target.proxyName) {
                    noteTestMessage("测速通道异常：核心已加载的配置里没有节点“\(target.proxyName)”（订阅提供方还没加载到核心）。请检查订阅更新后重试，仍失败请把日志导出发来定位。")
                    extra.append("通道诊断：核心缺少该节点（订阅提供方未加载）；提供方缓存见启动诊断")
                    // FIX 1b (v0.2.45): same validate hint as the
                    // all-groups path — appended to the banner +
                    // the single-node report; nothing changes when
                    // the provider list is non-empty or validate
                    // finds no issue.
                    if let hint = await validateHintIfProvidersEmpty(useAppCore: useAppCore) {
                        if let banner = testError {
                            noteTestMessage(banner + "（\(hint)）")
                        }
                        extra.append(hint)
                    }
                }
            }
            writeReport(resultLine: resultText, preloadNote: preloadNote, extra: extra)
        case .guardTimedOut:
            recordLatency(name: target.proxyName, url: target.testUrl, value: -1)
            applyLatencies()
            writeReport(resultLine: "超时（30s 兜底，未等到核心返回）", preloadNote: preloadNote)
        case .transportFailed(_, let message):
            // A throw is a transport failure, never a dead node —
            // but the chip still shows as failed (-2) instead of
            // silently untested, and the banner carries the real
            // reason.
            recordLatency(name: target.proxyName, url: target.testUrl, value: -2)
            applyLatencies()
            let error = DelayTransportFailure(message: message)
            noteTestError(error)
            writeReport(resultLine: "调用失败：\(message)", preloadNote: preloadNote)
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
    /// D2: true while toggle() is running. The Dashboard play
    /// button, the VPN row and the toggle all call toggle(), so a
    /// double tap used to start two stop/start races; the second
    /// call now returns immediately while the first is in flight.
    private var isToggling = false

    @MainActor
    /// Sets the persistent VPN-enabled flag ONLY (v0.2.115 — MuYu
    /// `_setVpn`, lib/views/dashboard/widgets/network_takeover.dart:
    /// 195-198: it only updates the persisted `vpnSetting.enable`
    /// setting and does NOT start/stop the tunnel; the play button
    /// `toggle()` is the only start/stop). The flag's didSet
    /// persists it to UserDefaults.
    func setVpnEnabled(_ enabled: Bool) async {
        vpnEnabled = enabled
    }

    func toggle() async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }
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
