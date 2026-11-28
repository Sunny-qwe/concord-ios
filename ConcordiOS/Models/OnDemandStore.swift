import Foundation
import Combine

// MARK: - On-demand store (FlClash: lib/views/config/on_demand.dart)
// FlClash's on-demand page is the SSIDs the VPN must NOT connect on,
// each with an action: direct (the tunnel stays up and the core
// switches to direct mode) or disconnect (the system does not
// auto-connect the VPN on that SSID). On iOS that maps onto
// NetworkExtension: one NEOnDemandRuleDisconnect per disconnect SSID
// (ssidMatch) — a direct SSID must NOT get one, or the tunnel would
// be gone before the extension could switch it to direct — plus a
// trailing NEOnDemandRuleConnect for every other network. The rules
// are installed on the saved NETunnelProviderManager by
// TunnelManager.updateOnDemandRules and take effect without
// restarting the tunnel; the system evaluates them when the network
// changes. The direct SSIDs are also written to the App Group
// (ssid-direct.json) on every save, so the extension's
// SsidDirectController can enforce them without the app running.
//
// iOS notes: the SSID match is evaluated by the system, not the app,
// so no location permission is needed to USE the rules. Reading the
// current SSID (to show it on the page, or for the extension to know
// which network it is on) DOES need the wifi-info entitlement plus
// location permission — that flow lives in SsidDirectStore, not here.
// On-demand only auto-connects the VPN; starting it by hand from the
// dashboard still connects on any network, and a disconnect rule only
// stops the auto-connect, it does not tear down a running tunnel
// when you join the SSID. Android-only prerequisites from FlClash
// (battery optimization) do not exist on iOS and are not shown.

final class OnDemandStore: ObservableObject {
    static let shared = OnDemandStore()

    /// File in the App Group container the extension reads:
    /// {"directSSIDs": [...], "excludeSSIDs": [...]}. Must match
    /// PacketTunnel/SsidDirectController.swift.
    static let sharedFileName = "ssid-direct.json"

    /// Default OFF (v0.2.32, FlClash iOS parity: FlClash never
    /// installs NEOnDemandRule on iOS — TunnelCoordinator sets
    /// isOnDemandEnabled = false on every start — and never
    /// auto-restarts the tunnel). A fresh install gets On-Demand
    /// off, so the system never auto-reconnects unless the user
    /// explicitly turns it on in Tools → 按需连接. A user who
    /// explicitly turned it on keeps the saved `true` — load()
    /// overwrites this default whenever saved data exists (v2
    /// migration below resets the old v1 default-on).
    @Published var enabled: Bool = false
    @Published var excludedSSIDs: [String] = []
    /// Excluded SSIDs whose action is direct (the tunnel stays up and
    /// the core switches to direct). Excluded SSIDs NOT in this list
    /// are disconnect SSIDs. Fork (on_demand.dart): a newly added
    /// SSID defaults to direct; renaming keeps the action.
    @Published var directSSIDs: [String] = []
    @Published var applyMessage: String?

    private let storageKey = "ConcordiOS.ondemand.v1"
    private var autosaveCancellable: AnyCancellable?
    /// Last rules installed on the manager: the autosave sink fires
    /// on every @Published change (including applyMessage), so the
    /// install is skipped when nothing about the rules changed —
    /// otherwise setting the message would reinstall forever.
    private var lastInstalledEnabled: Bool?
    private var lastInstalledSSIDs: [String]?
    private var lastInstalledDirectSSIDs: [String]?
    /// Generation bumped by every suspendRules() (O2): an install
    /// whose awaited manager save was in flight while a suspend
    /// landed must not stand — the install re-checks this after
    /// its save and re-clears instead of leaving re-installed rules
    /// behind. Only suspends bump it (edits are handled by the
    /// post-save re-check below, not by a generation).
    private var suspendEpoch = 0
    /// Watermark for the v0.2.168 On-Demand readback (see
    /// TunnelManager.syncOnDemandFromManager): the manager state
    /// WE last wrote — (isOnDemandEnabled, rules empty). Nil =
    /// unknown (pre-v4 record, or the write failed): the readback
    /// never guesses from an unknown watermark. Persisted, so a
    /// Settings change made while the app was closed is still
    /// detectable against the last write before the relaunch.
    private(set) var lastManagerEnabled: Bool?
    private(set) var lastManagerRulesEmpty: Bool?

    private struct Saved: Codable {
        var version: Int = 3
        var enabled: Bool = false
        var excludedSSIDs: [String] = []
        var directSSIDs: [String] = []
        var lastManagerEnabled: Bool?
        var lastManagerRulesEmpty: Bool?
    }

    init() {
        load()
        // The extension reads the SSID lists from the App Group file,
        // not from this store: write it once after load so a user who
        // never edits the list after updating still gets their direct
        // SSIDs enforced at the next VPN start.
        syncSharedFile()
        autosaveCancellable = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.save()
                await self?.installRulesIfNeeded()
            }
        }
    }

    func save() {
        let saved = Saved(version: 3, enabled: enabled, excludedSSIDs: excludedSSIDs, directSSIDs: directSSIDs,
                          lastManagerEnabled: lastManagerEnabled, lastManagerRulesEmpty: lastManagerRulesEmpty)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        syncSharedFile()
    }

    /// Records the manager state a TunnelManager write just left
    /// behind (install or suspend). Nil values mean the write's
    /// outcome is unknown — the readback then skips the comparison
    /// instead of adopting a guess. Persists immediately: the
    /// watermark must survive a relaunch to stay meaningful.
    func noteManagerWrite(enabled: Bool?, rulesEmpty: Bool?) {
        lastManagerEnabled = enabled
        lastManagerRulesEmpty = rulesEmpty
        save()
    }

    /// Writes the SSID lists to the App Group container for the
    /// extension's SsidDirectController (direct SSIDs) and for the
    /// record (exclude list). Best-effort: a failure leaves the
    /// on-demand rules (installed on the manager) working, and the
    /// next save retries.
    private func syncSharedFile() {
        guard let url = ConfigStore.sharedFileURL(name: Self.sharedFileName) else { return }
        let json: [String: Any] = [
            "directSSIDs": directSSIDs,
            "excludeSSIDs": excludedSSIDs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // v1 → v2 migration (v0.2.32): v1 defaulted On-Demand ON, so
        // every v1 install has enabled=true unless the user turned
        // it off — and that default is exactly the "VPN 关不了，
        // 一直自动启动" complaint. A v1 record carries no intent
        // (the user never chose it), so the migration resets it to
        // OFF and keeps the SSID exclusions; the user can re-enable
        // it in Tools → 按需连接 if they want auto-reconnect.
        if saved.version < 2 {
            enabled = false
            excludedSSIDs = saved.excludedSSIDs
            directSSIDs = []
            save()
            return
        }
        enabled = saved.enabled
        excludedSSIDs = saved.excludedSSIDs
        // v2 -> v3: the direct action is new. Existing exclusions
        // keep their old meaning (disconnect) — silently flipping
        // them to direct would change what the user's VPN does on
        // those networks. New SSIDs added after the update default
        // to direct (fork on_demand.dart).
        directSSIDs = saved.version < 3 ? [] : saved.directSSIDs
        lastManagerEnabled = saved.lastManagerEnabled
        lastManagerRulesEmpty = saved.lastManagerRulesEmpty
    }

    /// Installs the rules when they changed since the last install.
    /// Returns false when the manager save failed (and reports it).
    /// O1: rules are installed ONLY while the VPN is running — the
    /// autosave sink fires on every @Published change, including
    /// enabling On-Demand or editing SSIDs while the VPN is off, and
    /// installing then would arm an auto-start the user never asked
    /// for (FlClash iOS sets isOnDemandEnabled = false on every
    /// start; our install point is TunnelManager.start(), after a
    /// successful confirm). While off this returns false WITHOUT
    /// updating lastInstalled*, so the next start re-installs.
    /// O2: the install's manager save awaits, so a suspend (explicit
    /// stop) or a newer edit can land mid-flight. After the save,
    /// a suspend is re-applied (the install must not overwrite the
    /// clear) and a newer edit re-runs the install (the save must
    /// not leave stale rules behind). lastInstalled* is set before
    /// the await so a failure does not spin the autosave sink into
    /// a retry loop — the "重新应用" button resets it explicitly.
    @MainActor
    @discardableResult
    func installRulesIfNeeded() async -> Bool {
        guard enabled != lastInstalledEnabled || excludedSSIDs != lastInstalledSSIDs
                || directSSIDs != lastInstalledDirectSSIDs else {
            return true
        }
        guard TunnelManager.shared.isRunning else {
            return false
        }
        let installingEnabled = enabled
        let installingSSIDs = excludedSSIDs
        let installingDirectSSIDs = directSSIDs
        let epoch = suspendEpoch
        lastInstalledEnabled = installingEnabled
        lastInstalledSSIDs = installingSSIDs
        lastInstalledDirectSSIDs = installingDirectSSIDs
        do {
            try await TunnelManager.shared.updateOnDemandRules(
                enabled: installingEnabled, excludedSSIDs: installingSSIDs,
                directSSIDs: installingDirectSSIDs)
        } catch {
            applyMessage = "按需规则保存失败：\(error.localizedDescription)"
            return false
        }
        // A suspend landed while the save was in flight: the save
        // may have overwritten the clear, so re-clear and report
        // not-installed (lastInstalled* back to nil, so the next
        // manual start re-arms the preference).
        if suspendEpoch != epoch {
            lastInstalledEnabled = nil
            lastInstalledSSIDs = nil
            lastInstalledDirectSSIDs = nil
            await suspendRules()
            return false
        }
        // A newer edit landed while the save was in flight: the
        // installed rules are already stale — install the current
        // values instead of leaving the old ones in place.
        if enabled != installingEnabled || excludedSSIDs != installingSSIDs
            || directSSIDs != installingDirectSSIDs {
            return await installRulesIfNeeded()
        }
        // The install landed: record what WE wrote, so the readback
        // can tell our own write apart from a change the user made
        // in Settings. With enabled on, the rules always carry the
        // trailing connect rule; with it off, they are empty.
        noteManagerWrite(enabled: installingEnabled, rulesEmpty: !installingEnabled)
        return true
    }

    /// Clears the installed On-Demand rules WITHOUT touching the
    /// user's standing preference (`enabled` survives): the next
    /// manual start re-arms the preference via
    /// installRulesIfNeeded. Called on an explicit user stop and on
    /// a failed start, so the system cannot restart the tunnel
    /// after the user asked it to stay off (v0.2.32: the v0.2.31
    /// "VPN 关不了" bug — stop() never cleared the rules, so iOS
    /// restarted the tunnel). A failure is swallowed: clearing the
    /// rules must never block the stop itself.
    @MainActor
    func suspendRules() async {
        // O2: bump the generation so an install whose save is in
        // flight notices the suspend when it resumes and re-clears
        // instead of leaving its rules installed.
        suspendEpoch += 1
        lastInstalledEnabled = nil
        lastInstalledSSIDs = nil
        lastInstalledDirectSSIDs = nil
        do {
            try await TunnelManager.shared.updateOnDemandRules(enabled: false, excludedSSIDs: [])
            noteManagerWrite(enabled: false, rulesEmpty: true)
        } catch {
            // The clear may not have landed: the live manager state
            // is unknown, so drop the watermark instead of recording
            // a write that never happened. Still swallowed, as
            // before — clearing must never block the stop itself.
            noteManagerWrite(enabled: nil, rulesEmpty: nil)
        }
    }

    /// Installs (or clears) the on-demand rules on the saved VPN
    /// manager, and reports the result. The "重新应用" button calls
    /// this; every edit goes through the autosave sink instead.
    /// O1: with the VPN off there is nothing to install — say so
    /// honestly instead of reporting success for rules that will
    /// only be installed at the next start.
    @MainActor
    func apply() async {
        guard TunnelManager.shared.isRunning else {
            applyMessage = enabled
                ? "VPN 未启动：按需规则将在下次启动 VPN 时安装"
                : "按需连接已关闭"
            return
        }
        lastInstalledEnabled = nil
        guard await installRulesIfNeeded() else { return }
        if !enabled {
            applyMessage = "按需连接已关闭"
            return
        }
        // Fork disconnectSSIDs: excluded but not direct.
        let directCount = directSSIDs.filter { excludedSSIDs.contains($0) }.count
        let disconnectCount = excludedSSIDs.count - directCount
        if excludedSSIDs.isEmpty {
            applyMessage = "按需连接已开启：所有网络都会自动连接 VPN"
        } else if disconnectCount == 0 {
            applyMessage = "按需连接已开启：\(directCount) 个 Wi-Fi 下切换直连，其它网络自动连接 VPN"
        } else if directCount == 0 {
            applyMessage = "按需连接已开启：\(disconnectCount) 个 Wi-Fi 下不自动连接"
        } else {
            applyMessage = "按需连接已开启：\(directCount) 个 Wi-Fi 直连，\(disconnectCount) 个 Wi-Fi 不自动连接"
        }
    }

    // MARK: - Per-SSID actions (fork on_demand.dart _setSsidAction /
    // _handleAddOrUpdate / _handleDelete)

    /// True when the SSID's action is direct; false means disconnect.
    func isDirect(ssid: String) -> Bool {
        directSSIDs.contains(ssid)
    }

    /// Sets one SSID's action. Only meaningful for an excluded SSID;
    /// the view only offers it for listed ones.
    func setAction(ssid: String, direct: Bool) {
        if direct {
            guard !directSSIDs.contains(ssid) else { return }
            directSSIDs.append(ssid)
        } else {
            directSSIDs.removeAll { $0 == ssid }
        }
    }

    /// Adds an SSID to the list. A newly added SSID defaults to
    /// direct (fork on_demand.dart); renaming keeps the action (see
    /// renameSSID below). Returns false when the SSID is already listed.
    @discardableResult
    func addSSID(_ ssid: String) -> Bool {
        let value = ssid.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !excludedSSIDs.contains(value) else { return false }
        excludedSSIDs.append(value)
        directSSIDs.append(value)
        return true
    }

    /// Removes an SSID from the list (back to the default action:
    /// auto-connect like any other network) and drops its direct flag.
    func removeSSID(_ ssid: String) {
        excludedSSIDs.removeAll { $0 == ssid }
        directSSIDs.removeAll { $0 == ssid }
    }

    /// Renames an SSID in place, keeping its action (fork
    /// _handleAddOrUpdate). Returns false for an empty or duplicate name.
    @discardableResult
    func renameSSID(from old: String, to newValue: String) -> Bool {
        let value = newValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != old, !excludedSSIDs.contains(value),
              let index = excludedSSIDs.firstIndex(of: old) else { return false }
        excludedSSIDs[index] = value
        if let directIndex = directSSIDs.firstIndex(of: old) {
            directSSIDs[directIndex] = value
        }
        return true
    }
}
