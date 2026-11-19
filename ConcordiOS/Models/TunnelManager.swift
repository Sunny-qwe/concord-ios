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
                  let connection = notification.object as? NEVPNConnection else { return }
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
        if let existing = managers.first {
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
    /// .disconnected (the error itself is logged by the extension).
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
        _ = await OnDemandStore.shared.installRulesIfNeeded()
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
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

    var errorDescription: String? {
        switch self {
        case .noManager:
            return "VPN 配置尚未创建（请先允许 VPN 权限）"
        case .notRunning:
            return "VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据"
        case .noReply:
            return "扩展未回复（隧道可能正在启动或已断开）"
        }
    }
}
