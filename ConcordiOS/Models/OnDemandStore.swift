import Foundation
import Combine

// MARK: - On-demand store (FlClash: lib/views/config/on_demand.dart)
// FlClash's on-demand page is one thing: the SSIDs the VPN must
// NOT connect on. On iOS that maps exactly onto NetworkExtension:
// one NEOnDemandRuleDisconnect per excluded SSID (ssidMatch), plus
// a trailing NEOnDemandRuleConnect for every other network. The
// rules are installed on the saved NETunnelProviderManager by
// TunnelManager.updateOnDemandRules and take effect without
// restarting the tunnel; the system evaluates them when the
// network changes.
//
// iOS notes: the SSID match is evaluated by the system, not the
// app, so no location permission is needed to use it. On-demand
// only auto-connects the VPN; starting it by hand from the
// dashboard still connects on any network, and a disconnect rule
// only stops the auto-connect, it does not tear down a running
// tunnel when you join the SSID. Android-only prerequisites from
// FlClash (battery optimization, location permission) do not exist
// on iOS and are not shown.

final class OnDemandStore: ObservableObject {
    static let shared = OnDemandStore()

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
    @Published var applyMessage: String?

    private let storageKey = "ConcordiOS.ondemand.v1"
    private var autosaveCancellable: AnyCancellable?
    /// Last rules installed on the manager: the autosave sink fires
    /// on every @Published change (including applyMessage), so the
    /// install is skipped when nothing about the rules changed —
    /// otherwise setting the message would reinstall forever.
    private var lastInstalledEnabled: Bool?
    private var lastInstalledSSIDs: [String]?

    private struct Saved: Codable {
        var version: Int = 2
        var enabled: Bool = false
        var excludedSSIDs: [String] = []
    }

    init() {
        load()
        autosaveCancellable = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.save()
                await self?.installRulesIfNeeded()
            }
        }
    }

    func save() {
        let saved = Saved(version: 2, enabled: enabled, excludedSSIDs: excludedSSIDs)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
            save()
            return
        }
        enabled = saved.enabled
        excludedSSIDs = saved.excludedSSIDs
    }

    /// Installs the rules when they changed since the last install.
    /// Returns false when the manager save failed (and reports it).
    @MainActor
    @discardableResult
    func installRulesIfNeeded() async -> Bool {
        guard enabled != lastInstalledEnabled || excludedSSIDs != lastInstalledSSIDs else {
            return true
        }
        lastInstalledEnabled = enabled
        lastInstalledSSIDs = excludedSSIDs
        do {
            try await TunnelManager.shared.updateOnDemandRules(
                enabled: enabled, excludedSSIDs: excludedSSIDs)
            return true
        } catch {
            applyMessage = "按需规则保存失败：\(error.localizedDescription)"
            return false
        }
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
        lastInstalledEnabled = nil
        lastInstalledSSIDs = nil
        try? await TunnelManager.shared.updateOnDemandRules(enabled: false, excludedSSIDs: [])
    }

    /// Installs (or clears) the on-demand rules on the saved VPN
    /// manager, and reports the result. The "重新应用" button calls
    /// this; every edit goes through the autosave sink instead.
    @MainActor
    func apply() async {
        lastInstalledEnabled = nil
        guard await installRulesIfNeeded() else { return }
        applyMessage = enabled
            ? (excludedSSIDs.isEmpty
               ? "按需连接已开启：所有网络都会自动连接 VPN"
               : "按需连接已开启：\(excludedSSIDs.count) 个 Wi-Fi 下不自动连接")
            : "按需连接已关闭"
    }
}
