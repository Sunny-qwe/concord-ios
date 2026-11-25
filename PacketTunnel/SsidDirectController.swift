import Foundation
import Network
import NetworkExtension
import os

// SsidDirectController — extension-side SSID direct override.
//
// Port of the reference fork's ios/NECore/SsidDirectController.swift
// (HEAD; commits 83912b4 "feat(ssid): switch the core to direct over
// 9090 and retry across failures", dcf3359 "feat(ios): restore
// on-demand SSID actions", 581d898 "feat(ios): mirror the SSID direct
// override onto the App core"). Behaviour is replicated as-is, with two
// adaptations forced by our architecture:
//
// 1. The fork talks to its own core through the 9090 external
//    controller (HTTP PATCH /configs, with a controller secret). Our
//    core runs IN THIS PROCESS (in-process staticlib, JSON-RPC over
//    the FFI session — there is no 9090 listener), so the mode
//    read/write go through the closures the provider wires to its own
//    sendCoreRequest ("config.general" / "config.patch"). There is no
//    secret and no 401 path.
// 2. The fork persists the override (active + restore mode) in the
//    App Group UserDefaults suite and reads the direct SSIDs from the
//    shared-state payload. Our app and extension share state through
//    files in the App Group container (the codebase convention), so
//    the override lives in ssid-direct-override.json and the direct
//    SSIDs are read from ssid-direct.json (written by OnDemandStore
//    on every save). Same keys, same semantics.
//
// What it does, like the fork: while the tunnel is up it watches the
// network itself (NWPathMonitor + NEHotspotNetwork — the main app is
// killed in the background, so nobody else could watch), switches the
// core to direct on a direct SSID, and restores the previous mode on
// leaving. Disconnect SSIDs never reach here: the system disconnects
// the VPN on those through the on-demand rules, so the tunnel (and
// this controller) is gone while on one. A failed core call never
// drops the pending switch/restore: it is retried with backoff and on
// the next path update. The user's own mode change wins: if the mode
// moved while a switch was unconfirmed, the switch is abandoned, and
// if it moved while a restore was pending, the restore is dropped.
final class SsidDirectController {
    private static let maxPendingRetries = 5

    /// File in the App Group container the app writes on every
    /// On-Demand save: {"directSSIDs": [...], "excludeSSIDs": [...]}.
    /// Must match OnDemandStore.sharedFileName.
    private static let directSettingsFileName = "ssid-direct.json"
    /// File in the App Group container this controller writes whenever
    /// the override state changes: {"active": Bool,
    /// "restoreMode": String?}. Must match
    /// SsidDirectStore.overrideFileName; the app reads it to mirror
    /// the override onto the app-visible core.
    private static let overrideFileName = "ssid-direct-override.json"

    private let appGroupID: String
    /// Reads the core's current mode ("rule"/"global"/"direct"), or
    /// nil when the core cannot be reached. Single-shot per call: the
    /// controller-level pending retry (below) is what retries across
    /// failures — the fork's inner 3-attempt HTTP loop has no
    /// equivalent here because there is no HTTP layer to retry in.
    private let fetchMode: (@escaping (String?) -> Void) -> Void
    /// Patches the core's mode; reports whether the patch landed.
    private let setMode: (String, @escaping (Bool) -> Void) -> Void

    private let logger = Logger(
        subsystem: "com.lumen.ios", category: "SsidDirect")

    private let queue = DispatchQueue(label: "com.lumen.ios.ssid-direct")
    private var monitor: NWPathMonitor?
    private var running = false

    /// The mode to restore when the phone leaves a direct SSID, nil while no
    /// direct override is active. Only cleared once the restore is issued
    /// or the user takes the mode over; a failed core call never drops it.
    private var restoreMode: String? {
        didSet {
            if oldValue != restoreMode {
                syncOverrideState()
            }
        }
    }
    private var lastPersistedOverrideActive = false
    private var lastPersistedOverrideRestoreMode: String?
    private var currentSsid: String?
    /// A direct SSID entered whose switch to direct is not confirmed yet.
    private var pendingEnterSsid: String?
    /// The mode recorded before an unconfirmed switch, moved into
    /// restoreMode once the switch is confirmed to have landed.
    private var pendingRestoreMode: String?
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var pendingRetryCount = 0
    private var pendingRetryExhausted = false

    init(
        appGroupID: String,
        fetchMode: @escaping (@escaping (String?) -> Void) -> Void,
        setMode: @escaping (String, @escaping (Bool) -> Void) -> Void
    ) {
        self.appGroupID = appGroupID
        self.fetchMode = fetchMode
        self.setMode = setMode
        // Seed the dedup from disk, so start() clears a stale flag from a killed run.
        let persisted = loadSsidDirectOverride()
        self.lastPersistedOverrideActive = persisted.active
        self.lastPersistedOverrideRestoreMode = persisted.restoreMode
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] _ in
                self?.refreshSsid()
            }
            monitor.start(queue: self.queue)
            self.syncOverrideState()
            self.refreshSsid()
            self.logger.info("ssid direct monitor started")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.monitor?.cancel()
            self.monitor = nil
            self.restoreMode = nil
            self.currentSsid = nil
            self.pendingEnterSsid = nil
            self.pendingRestoreMode = nil
            self.resetPendingRetry()
            self.logger.info("ssid direct monitor stopped")
        }
    }

    private func refreshSsid() {
        // A Wi-Fi to Wi-Fi switch may not move the path, and the SSID read is
        // asynchronous, so always re-read rather than trusting the last value.
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            guard let self else { return }
            self.queue.async {
                if let ssid = network?.ssid {
                    self.apply(ssid: ssid)
                    return
                }
                let path = self.monitor?.currentPath
                let onWifi =
                    path?.status == .satisfied
                    && (path?.usesInterfaceType(.wifi) ?? false)
                if onWifi {
                    // On Wi-Fi but the SSID could not be read, likely for lack of
                    // location permission: hold the current state, do not restore.
                    self.logger.warning(
                        "ssid direct: on Wi-Fi but SSID unreadable; holding current mode"
                    )
                    return
                }
                self.apply(ssid: nil)
            }
        }
    }

    private func apply(ssid: String?) {
        guard running else { return }
        let direct = Set(loadDirectSSIDs())
        let previous = currentSsid
        currentSsid = ssid
        if previous == ssid {
            // The SSID did not change, but a switch or restore may still be
            // pending after a failed core call; retry it on the next path update.
            retryPending()
            return
        }
        if let ssid, direct.contains(ssid) {
            enterDirect(ssid: ssid)
            return
        }
        leaveDirect()
    }

    private func retryPending() {
        if let pending = pendingEnterSsid, currentSsid == pending,
           restoreMode == nil
        {
            enterDirect(ssid: pending)
            return
        }
        if restoreMode != nil {
            if let current = currentSsid, Set(loadDirectSSIDs()).contains(current) {
                return
            }
            leaveDirect()
        }
    }

    private func enterDirect(ssid: String) {
        guard restoreMode == nil else { return }
        pendingEnterSsid = ssid
        fetchMode { [weak self] mode in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                guard let mode else {
                    self.schedulePendingRetry()
                    return
                }
                guard self.currentSsid == ssid, self.restoreMode == nil,
                      self.pendingEnterSsid == ssid
                else {
                    if self.currentSsid != ssid {
                        self.pendingEnterSsid = nil
                    }
                    return
                }
                if mode == "direct" {
                    // The switch landed on an earlier attempt whose reply was lost.
                    if let pending = self.pendingRestoreMode {
                        self.restoreMode = pending
                    }
                    self.pendingRestoreMode = nil
                    self.pendingEnterSsid = nil
                    self.resetPendingRetry()
                    return
                }
                if let pending = self.pendingRestoreMode, pending != mode {
                    // The user changed the mode while the switch was unconfirmed.
                    self.pendingRestoreMode = nil
                    self.pendingEnterSsid = nil
                    self.resetPendingRetry()
                    return
                }
                self.fetchMode { [weak self] current in
                    guard let self else { return }
                    self.queue.async {
                        guard self.running, self.currentSsid == ssid,
                              self.restoreMode == nil, self.pendingEnterSsid == ssid
                        else {
                            if self.currentSsid != ssid {
                                self.pendingEnterSsid = nil
                            }
                            return
                        }
                        guard let current else {
                            self.schedulePendingRetry()
                            return
                        }
                        if current != mode {
                            if current == "direct",
                               let pending = self.pendingRestoreMode
                            {
                                self.restoreMode = pending
                            } else {
                                self.logger.info(
                                    "ssid direct: mode changed while entering \(ssid, privacy: .public), abandoning switch"
                                )
                            }
                            self.pendingRestoreMode = nil
                            self.pendingEnterSsid = nil
                            self.resetPendingRetry()
                            return
                        }
                        self.pendingRestoreMode = mode
                        self.setMode("direct") { [weak self] succeeded in
                            guard let self else { return }
                            self.queue.async {
                                guard self.running else { return }
                                if succeeded {
                                    self.restoreMode = mode
                                    self.pendingRestoreMode = nil
                                    self.pendingEnterSsid = nil
                                    self.resetPendingRetry()
                                    self.logger.info(
                                        "ssid direct: \(ssid, privacy: .public) mode \(mode, privacy: .public) -> direct"
                                    )
                                } else {
                                    self.schedulePendingRetry()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func leaveDirect() {
        guard let restoreMode else { return }
        fetchMode { [weak self] mode in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.restoreMode == restoreMode else { return }
                guard let mode else {
                    self.schedulePendingRetry()
                    return
                }
                // The phone may have entered another direct SSID while the mode
                // was being read; only restore when it is not on one now.
                if let current = self.currentSsid, Set(self.loadDirectSSIDs()).contains(current) {
                    return
                }
                guard mode == "direct" else {
                    // The user changed the mode themselves; their choice stands.
                    self.restoreMode = nil
                    self.resetPendingRetry()
                    return
                }
                self.setMode(restoreMode) { [weak self] succeeded in
                    guard let self else { return }
                    self.queue.async {
                        guard self.running else { return }
                        if succeeded {
                            if self.restoreMode == restoreMode {
                                self.restoreMode = nil
                            }
                            self.resetPendingRetry()
                            self.logger.info(
                                "ssid direct: left, mode direct -> \(restoreMode, privacy: .public)"
                            )
                        } else {
                            self.schedulePendingRetry()
                        }
                    }
                }
            }
        }
    }

    private func schedulePendingRetry() {
        guard running else { return }
        if pendingRetryCount >= Self.maxPendingRetries {
            if !pendingRetryExhausted {
                pendingRetryExhausted = true
                logger.warning(
                    "ssid direct: keeping pending switch/restore after \(Self.maxPendingRetries, privacy: .public) timer retries; will retry on the next network change"
                )
            }
            return
        }
        pendingRetryWorkItem?.cancel()
        let delay = min(TimeInterval(2 << pendingRetryCount), 30)
        pendingRetryCount += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryPending()
        }
        pendingRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetPendingRetry() {
        pendingRetryWorkItem?.cancel()
        pendingRetryWorkItem = nil
        pendingRetryCount = 0
        pendingRetryExhausted = false
    }

    private func syncOverrideState() {
        let active = restoreMode != nil
        let restore = restoreMode
        guard
            active != lastPersistedOverrideActive
                || restore != lastPersistedOverrideRestoreMode
        else {
            return
        }
        lastPersistedOverrideActive = active
        lastPersistedOverrideRestoreMode = restore
        saveSsidDirectOverride(active: active, restoreMode: restore)
    }

    // MARK: - App Group files

    /// The direct SSIDs the app synced (OnDemandStore writes
    /// ssid-direct.json on every save). Re-read on every apply, like
    /// the fork re-reads its shared state, so an edit lands without
    /// restarting the tunnel.
    private func loadDirectSSIDs() -> [String] {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent(Self.directSettingsFileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ssids = json["directSSIDs"] as? [String] else {
            return []
        }
        return ssids
    }

    private func loadSsidDirectOverride() -> (active: Bool, restoreMode: String?) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent(Self.overrideFileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil)
        }
        return (
            json["active"] as? Bool ?? false,
            json["restoreMode"] as? String
        )
    }

    private func saveSsidDirectOverride(active: Bool, restoreMode: String?) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        var json: [String: Any] = ["active": active]
        if let restoreMode {
            json["restoreMode"] = restoreMode
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(
            to: container.appendingPathComponent(Self.overrideFileName),
            options: .atomic)
    }
}
