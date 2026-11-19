import Foundation
import Combine
import NetworkExtension

// MARK: - TunnelManager: the app side of the extension IPC
//
// The app NEVER loads the Concord core (it runs in the PacketTunnel
// extension process; see PacketTunnel/PacketTunnelProvider.swift).
// This manager is the app's only handle on the tunnel:
//
//   * start/stop the system VPN (NETunnelProviderManager), which in
//     turn boots / tears down the core inside the extension;
//   * sendProviderMessage: carry ONE JSON-RPC 2.0 request per message
//     to the extension and await its reply bytes (used by
//     ExtensionConcordTransport for every unary core method).
//
// Live snapshots (traffic / connections / logs / dns) do NOT go through
// here: the extension writes them to the App Group container and the
// live transport reads the files (see ConfigStore.snapshotURL).
//
// First launch: loadAllFromPreferences finds no saved manager, so one
// is created (providerBundleIdentifier below, serverAddress "Concord")
// and saved. Starting the VPN the first time prompts the user for VPN
// permission; that prompt, and the `packet-tunnel-provider`
// entitlement, require a paid Apple Developer Program provisioning
// profile (see SIGNING.md).

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    static let providerBundleID = "com.concord.ios.PacketTunnel"
    static let serverAddress = "Concord"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    /// True when the tunnel dropped without the user asking it to
    /// (v0.2.26 Batch F): the Dashboard shows an "unexpected
    /// disconnect" banner with a one-tap reconnect. Set only on a
    /// connected/connecting/reasserting -> disconnected transition
    /// that was not caused by stop(); cleared on start() and on the
    /// next successful connect. A failed start also sets it (the
    /// user asked to start and it did not stay up).
    @Published private(set) var unexpectedDisconnect = false
    /// Set by stop() so the observer can tell a user-initiated stop
    /// from a system/core failure. Cleared by start().
    private var userInitiatedStop = false

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    var isRunning: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? NEVPNConnection,
                  // FlClash TunnelCoordinator.handleTunnelStatusNotification:
                  // ignore status changes from OTHER apps' VPNs (the
                  // user also runs Egern) — only our manager's
                  // connection may move our status.
                  (connection.manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID else { return }
            let old = self.status
            let new = connection.status
            self.status = new
            if new == .disconnected,
               old == .connected || old == .connecting || old == .reasserting,
               !self.userInitiatedStop {
                self.unexpectedDisconnect = true
            }
            if new == .connected {
                self.unexpectedDisconnect = false
            }
        }
        Task { try? await self.prepare() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// Load the saved manager, or create + save one on first launch.
    /// FlClash TunnelManagerStore.isManagedManager: pick the manager
    /// whose providerBundleIdentifier is OURS — loadAllFromPreferences
    /// returns EVERY VPN configuration on the device, and taking
    /// `.first` could return another app's manager (the user also
    /// runs Egern): startVPNTunnel on a disabled/foreign manager
    /// throws or starts the wrong tunnel, with nothing shown in the
    /// UI. That is the most likely cause of the silent start failure.
    @MainActor
    func prepare() async throws {
        if manager != nil { return }
        let managers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
        if let existing = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID }) {
            manager = existing
        } else {
            let created = NETunnelProviderManager()
            created.localizedDescription = "Concord"
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleID
            proto.serverAddress = Self.serverAddress
            created.protocolConfiguration = proto
            created.isEnabled = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                created.saveToPreferences { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            manager = created
        }
        if let connection = manager?.connection {
            status = connection.status
        }
    }

    /// Start the system VPN. The extension's startTunnel boots the
    /// core; a failure there surfaces as a status change to
    /// .disconnected (the error itself is logged by the extension and
    /// written to vpn-startup.json — see readStartupDiagnostic).
    /// The pre-start sequence mirrors FlClash (NEHelper.start /
    /// TunnelCoordinator.reconcileRunningTunnel):
    ///  * wait out a disconnect in progress (up to 5 s) — starting
    ///    mid-disconnect throws;
    ///  * re-assert isEnabled + disconnectOnSleep=false and
    ///    save + reload preferences before every start — a manager
    ///    toggled off in Settings otherwise makes startVPNTunnel
    ///    throw .configurationDisabled with nothing shown in the UI;
    ///  * on a .configurationInvalid/.configurationStale error, drop
    ///    the cached manager, reload it fresh and retry once.
    /// Before starting, the On-Demand rules are (re)installed from
    /// the store (v0.2.26 Batch F): On-Demand is on by default, so
    /// the system auto-reconnects after a network loss or handover,
    /// and a watchdog-triggered restart in the extension only
    /// recovers when these rules exist. A rules-install failure does
    /// not block the start — On-Demand is a backstop, not a
    /// precondition. The install is a no-op when nothing changed.
    @MainActor
    func start() async throws {
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        userInitiatedStop = false
        unexpectedDisconnect = false
        if manager.connection.status == .disconnecting {
            try await waitForStableStatus(manager: manager)
        }
        if [.connecting, .connected, .reasserting].contains(manager.connection.status) {
            return
        }
        try await armManagerForStart(manager)
        _ = await OnDemandStore.shared.installRulesIfNeeded()
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            guard isRetryablePreferenceError(error) else {
                lastError = error.localizedDescription
                throw error
            }
            // Stale/invalid saved configuration: reload it fresh and
            // retry once (FlClash startWithPreferenceRetry).
            self.manager = nil
            try await prepare()
            guard let retryManager = self.manager else {
                lastError = error.localizedDescription
                throw TunnelError.noManager
            }
            try await armManagerForStart(retryManager)
            do {
                try retryManager.connection.startVPNTunnel()
            } catch {
                lastError = error.localizedDescription
                throw error
            }
        }
    }

    /// isEnabled + disconnectOnSleep + save + reload, the FlClash
    /// pre-start arming. A save failure throws (the start must not
    /// proceed on a manager the system will reject); a reload
    /// failure is tolerated — the in-memory manager is still usable.
    @MainActor
    private func armManagerForStart(_ manager: NETunnelProviderManager) async throws {
        manager.isEnabled = true
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.disconnectOnSleep = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let connection = manager.connection
        status = connection.status
    }

    /// FlClash NEHelper.waitForStableStatus: up to 5 s for a
    /// disconnect in progress to settle before starting.
    private func waitForStableStatus(manager: NETunnelProviderManager) async throws {
        let deadline = Date().addingTimeInterval(5)
        var status = manager.connection.status
        while status == .disconnecting && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            status = manager.connection.status
        }
        guard status != .disconnecting else {
            throw TunnelError.transitionTimedOut
        }
    }

    /// FlClash NEHelper/TunnelManagerStore: only .configurationInvalid
    /// and .configurationStale are worth retrying with a fresh load.
    private func isRetryablePreferenceError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NEVPNErrorDomain,
              let code = NEVPNError.Code(rawValue: error.code) else { return false }
        switch code {
        case .configurationInvalid, .configurationStale:
            return true
        default:
            return false
        }
    }

    /// The extension's startup stages (FlClash TunnelStartupDiagnostic):
    /// vpn-startup.json in the App Group, fresh within 180 s.
    /// Returns a one-line "stage: detail" string, or nil when there is
    /// no recent startup record — used by the Dashboard's
    /// unexpected-disconnect banner so an extension-side failure
    /// shows its stage instead of a generic message.
    func lastStartupDiagnostic() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("vpn-startup.json")),
              let record = try? JSONDecoder().decode(TunnelStartupDiagnosticRecord.self, from: data),
              Date().timeIntervalSince(record.date) < 180 else { return nil }
        if let detail = record.detail, !detail.isEmpty {
            return "VPN \(record.stage)：\(detail)"
        }
        return "VPN 阶段：\(record.stage)"
    }

    /// Stop the system VPN. The extension's stopTunnel tears down the
    /// core (tun.stop -> engine.stop -> close session).
    @MainActor
    func stop() async {
        try? await prepare()
        userInitiatedStop = true
        unexpectedDisconnect = false
        manager?.connection.stopVPNTunnel()
    }

    /// Install (or clear) the on-demand rules on the saved VPN
    /// manager (FlClash: On-Demand, exclude SSIDs). One disconnect
    /// rule per excluded SSID, then a connect rule for every other
    /// network; rule order matters, disconnect first. With no
    /// excluded SSIDs the single connect rule means "always connect
    /// on demand". Disabled clears the rules and turns on-demand
    /// off. The manager must be saved for the rules to take effect;
    /// a failure surfaces to the caller instead of being swallowed.
    @MainActor
    func updateOnDemandRules(enabled: Bool, excludedSSIDs: [String]) async throws {
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        if enabled {
            var rules: [NEOnDemandRule] = excludedSSIDs.map { ssid in
                let rule = NEOnDemandRuleDisconnect()
                rule.ssidMatch = [ssid]
                return rule
            }
            rules.append(NEOnDemandRuleConnect())
            manager.onDemandRules = rules
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Send one JSON-RPC request to the extension and await its reply.
    /// Throws TunnelError.notRunning unless the tunnel is connected,
    /// and TunnelError.noReply when the extension answers nothing.
    func sendProviderMessage(_ data: Data) async throws -> Data {
        guard isRunning, let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelError.notRunning
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    if let reply {
                        continuation.resume(returning: reply)
                    } else {
                        continuation.resume(throwing: TunnelError.noReply)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum TunnelError: LocalizedError {
    case noManager
    case notRunning
    case noReply
    case transitionTimedOut

    var errorDescription: String? {
        switch self {
        case .noManager:
            return "VPN 配置尚未创建（请先允许 VPN 权限）"
        case .notRunning:
            return "VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据"
        case .noReply:
            return "扩展未回复（隧道可能正在启动或已断开）"
        case .transitionTimedOut:
            return "VPN 状态切换超时，请稍后再试"
        }
    }
}

/// One record of the extension's vpn-startup.json (written by
/// PacketTunnelProvider, read by TunnelManager.lastStartupDiagnostic).
/// Shape mirrors FlClash's TunnelStartupDiagnostic.
struct TunnelStartupDiagnosticRecord: Codable {
    let id: String
    let stage: String
    let detail: String?
    let date: Date
}
