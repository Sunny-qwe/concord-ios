import Foundation
import Combine
import CoreLocation
import NetworkExtension
import UIKit

// MARK: - SSID direct override, app side (fork: lib/providers/on_demand.dart
// SsidDirectOverride + lib/manager/connectivity_manager.dart + the
// wifi_ssid plugin, commits dcf3359 / 581d898)
//
// The extension enforces the override without the app running
// (PacketTunnel/SsidDirectController.swift): it switches its own core
// to direct on a direct SSID and persists {active, restoreMode} to
// ssid-direct-override.json in the App Group container. This store is
// the app's reader of that state, and the mirror onto the app-visible
// core:
//
// * It reads the override file and exposes it, gated on the tunnel
//   being up — a stale flag from a killed extension run must not be
//   honoured while the VPN is off (fork 581d898).
// * While the override is active it mirrors direct onto the core the
//   app talks to (ConcordClient, live transport -> the extension core
//   while the VPN is up), but only as a repair: the extension already
//   switched its own core, so the patch only fires when the live core
//   still reports another mode. The stored mode is untouched — the
//   override is in-memory only — and the user's own mode change wins:
//   the mirror only runs while the stored mode still equals the
//   recorded restore mode. When the override ends, the next refresh
//   re-pushes the stored mode if this store ever mirrored direct.
//   (In our architecture the App core never runs while the tunnel is
//   up — AppCore.ensureStarted throws tunnelRunning — so there is no
//   second core to patch; the live client IS the extension core, and
//   the mirror is the repair path plus the effective-mode display.)
// * It reads the current Wi-Fi SSID for the On-Demand page
//   (NEHotspotNetwork, like the fork's wifi_ssid plugin). Reading the
//   SSID needs the wifi-info entitlement (both .entitlements files)
//   AND location permission: the permission is requested only from
//   the On-Demand page's button, never automatically, and a denial
//   is shown honestly — an SSID is never guessed or faked.
//
// NOTE: the Dashboard mode segment reads SettingsStore.mode (the
// stored mode), which this store deliberately does not touch; during
// an override the On-Demand page is where the effective (direct)
// mode is shown. Wiring the Dashboard segment to the effective mode
// needs DashboardView/SettingsStore changes, outside this item.

final class SsidDirectStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SsidDirectStore()

    /// Must match PacketTunnel/SsidDirectController.swift.
    static let overrideFileName = "ssid-direct-override.json"

    /// The extension is currently enforcing direct on a direct SSID.
    @Published var overrideActive = false
    /// The mode the extension will restore on leaving ("rule"/"global"/"direct").
    @Published var restoreMode: String?
    /// The phone's current Wi-Fi SSID, nil when not on Wi-Fi, when the
    /// SSID could not be read, or when permission is missing. Never a guess.
    @Published var currentSSID: String?
    /// Why the current SSID is unavailable (permission text), nil otherwise.
    @Published var ssidUnavailableReason: String?
    @Published var permissionStatus: CLAuthorizationStatus = .notDetermined
    /// Whether this store has mirrored direct onto the live core.
    @Published private(set) var mirroredDirect = false
    /// Short human-readable mirror status for the On-Demand page.
    @Published var mirrorNote: String?

    let client: ConcordClient
    private let locationManager = CLLocationManager()
    private var foregroundObserver: NSObjectProtocol?

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        super.init()
        permissionStatus = CLLocationManager.authorizationStatus()
        locationManager.delegate = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { [weak self] in await self?.refreshAll() }
        }
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Refresh

    /// Re-reads the override file, mirrors it onto the live core, and
    /// re-reads the current SSID when permission allows. Called from
    /// the On-Demand page's onAppear / scenePhase and on foreground.
    @MainActor
    func refreshAll() async {
        refreshOverrideFile()
        await mirrorIfNeeded()
        refreshCurrentSSID()
    }

    /// Reads ssid-direct-override.json. Gated on the tunnel being up:
    /// with the VPN off the file can only be a stale flag from a
    /// killed extension run, and the override is not honoured then.
    @MainActor
    func refreshOverrideFile() {
        guard TunnelManager.shared.isRunning else {
            overrideActive = false
            restoreMode = nil
            return
        }
        guard let url = ConfigStore.sharedFileURL(name: Self.overrideFileName),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            overrideActive = false
            restoreMode = nil
            return
        }
        overrideActive = json["active"] as? Bool ?? false
        restoreMode = json["restoreMode"] as? String
        if !overrideActive {
            restoreMode = nil
        }
    }

    // MARK: - Mirror onto the app-visible core

    /// The stored mode, from the shared general.json the extension
    /// patches in at startup (SettingsStore writes it). Nil when the
    /// file cannot be read — the mirror then does nothing rather than
    /// guess what the user picked.
    private func storedMode() -> String? {
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.generalSettingsFileName),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = json["mode"] as? String, !mode.isEmpty else {
            return nil
        }
        return mode
    }

    @MainActor
    private func mirrorIfNeeded() async {
        guard client.mode == .live else { return }
        guard TunnelManager.shared.isRunning else {
            // A stale flag cannot switch anything while the tunnel is
            // down; forget a mirror from a previous run.
            mirroredDirect = false
            return
        }
        guard overrideActive, let restore = restoreMode else {
            // The override ended: lift the mirror on the next push by
            // re-pushing the stored mode, but only if this store ever
            // mirrored direct and the core still disagrees.
            if mirroredDirect {
                mirroredDirect = false
                await pushStoredModeIfNeeded()
            }
            return
        }
        guard let stored = storedMode(), stored == restore else {
            // The stored mode no longer equals the recorded restore
            // mode: the user took the mode over, and their choice
            // stands. (Or the stored mode cannot be read: do not guess.)
            return
        }
        do {
            let general = try await client.configGeneral()
            if general.mode == "direct" {
                mirroredDirect = true
                mirrorNote = nil
                return
            }
            // The extension missed the switch (or the core was
            // re-applied since): repair it from the app side.
            try await client.configPatchMode("direct")
            mirroredDirect = true
            mirrorNote = "已将直连覆盖同步到核心"
        } catch {
            mirrorNote = "直连覆盖同步失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func pushStoredModeIfNeeded() async {
        guard let stored = storedMode() else { return }
        do {
            let general = try await client.configGeneral()
            guard general.mode != stored else { return }
            try await client.configPatchMode(stored)
        } catch {
            mirrorNote = "恢复出站模式失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Current SSID + location permission

    var locationAuthorized: Bool {
        permissionStatus == .authorizedAlways || permissionStatus == .authorizedWhenInUse
    }

    /// Requests When-In-Use location, only ever called from the
    /// On-Demand page's button. The system prompt appears once; a
    /// denial lands in locationManagerDidChangeAuthorization and is
    /// shown honestly on the page.
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Reads the current SSID when (and only when) location is
    /// authorized. With no permission the reason is recorded and no
    /// SSID is produced — never a guessed name.
    @MainActor
    func refreshCurrentSSID() {
        guard locationAuthorized else {
            currentSSID = nil
            switch permissionStatus {
            case .denied, .restricted:
                ssidUnavailableReason = "位置权限已被拒绝，无法读取当前 Wi-Fi 名称。请在系统设置中允许位置权限，或手动输入 SSID。"
            case .notDetermined:
                ssidUnavailableReason = "读取当前 Wi-Fi 名称需要位置权限（系统要求），请点按授权。"
            default:
                ssidUnavailableReason = nil
            }
            return
        }
        ssidUnavailableReason = nil
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only publish when still authorized: a revoke between
                // the fetch and the callback must not leak an SSID.
                guard self.locationAuthorized else {
                    self.currentSSID = nil
                    self.ssidUnavailableReason = "位置权限已被拒绝，无法读取当前 Wi-Fi 名称。请在系统设置中允许位置权限，或手动输入 SSID。"
                    return
                }
                self.currentSSID = network?.ssid
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        permissionStatus = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.refreshCurrentSSID()
        }
    }
}
