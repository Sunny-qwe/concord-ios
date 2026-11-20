import Foundation
import Combine
import NetworkExtension

// MARK: - TunnelManager: the app side of the extension IPC
//
// The Concord core runs in the PacketTunnel extension process (see
// PacketTunnel/PacketTunnelProvider.swift); this manager is the app's
// handle on the system VPN (NETunnelProviderManager) that boots it.
// The app ALSO loads the core in-process, but only for delay tests
// with the VPN off (Models/AppCore.swift) — never while the tunnel
// runs, and never for the data plane.
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
    /// True while this start attempt ever reached .connected.
    /// A connecting -> disconnected transition with this false is a
    /// FAILED START (the extension's startTunnel never completed),
    /// not a drop: On-Demand must not restart it (v0.2.32).
    private var reachedConnectedThisStart = false
    /// The startupID passed to startVPNTunnel(options:) for this
    /// run; the extension adopts it in vpn-startup.json so the
    /// diagnostic read can be correlated by ID (FlClash
    /// TunnelStartupDiagnostic), not just by 180 s freshness.
    private var currentStartupID: String?
    // MARK: Crash-loop detection (v0.2.32)
    //
    // The extension can die seconds after a successful start
    // (Jetsam memory kill / core panic) without writing any
    // diagnostic — vpn-startup.json keeps the stale "running"
    // stage, so the app cannot tell a crash from a healthy tunnel
    // except by watching the status. A drop within 20 s of a
    // successful start counts as a rapid drop; 3 rapid drops in
    // 5 minutes means the tunnel is crash-looping: suspend the
    // On-Demand rules (stop the restart loop) and surface a clear
    // error instead of restarting forever. A drop after 60 s of
    // healthy uptime resets the count; an explicit stop clears it.
    private var connectedAt: Date?
    private var rapidDropCount = 0
    private var rapidDropWindowStart: Date?
    /// Set when the crash loop trips; the Dashboard shows a
    /// "VPN 反复掉线，已暂停自动重连" banner. Cleared on the next
    /// manual start.
    @Published private(set) var crashLoopActive = false

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
            if new == .connected {
                self.unexpectedDisconnect = false
                self.reachedConnectedThisStart = true
                self.connectedAt = Date()
                return
            }
            if new == .disconnected,
               old == .connected || old == .connecting || old == .reasserting,
               !self.userInitiatedStop {
                self.unexpectedDisconnect = true
                if old == .connecting, !self.reachedConnectedThisStart {
                    // FAILED START (never reached .connected): the
                    // extension's startTunnel failed. Do NOT let
                    // On-Demand restart it — suspend the rules and
                    // surface the diagnostic instead of looping.
                    self.lastError = self.lastStartupDiagnostic()
                        ?? "VPN 启动失败（扩展未完成启动）"
                    Task { await OnDemandStore.shared.suspendRules() }
                } else if old == .connected {
                    // A drop from a running tunnel: count rapid
                    // drops for the crash loop (see above).
                    self.noteRapidDropIfNeeded()
                }
            }
        }
        Task { try? await self.prepare() }
    }

    /// Crash-loop bookkeeping, called on a connected -> disconnected
    /// drop. A drop within 20 s of a successful start is a rapid
    /// drop; a drop after 60 s of healthy uptime resets the count.
    /// At 3 rapid drops inside a 5-minute window the tunnel is
    /// crash-looping: suspend On-Demand (stop the restart loop) and
    /// flag it for the Dashboard banner.
    private func noteRapidDropIfNeeded() {
        let now = Date()
        if let connectedAt, now.timeIntervalSince(connectedAt) > 60 {
            rapidDropCount = 0
            rapidDropWindowStart = nil
            return
        }
        if let windowStart = rapidDropWindowStart,
           now.timeIntervalSince(windowStart) > 300 {
            rapidDropCount = 0
            rapidDropWindowStart = now
        } else if rapidDropWindowStart == nil {
            rapidDropWindowStart = now
        }
        rapidDropCount += 1
        if rapidDropCount >= 3, !crashLoopActive {
            crashLoopActive = true
            lastError = "VPN 反复掉线（3 次快速掉线），已暂停自动重连：请检查配置后手动重新启动；若持续出现，可能是扩展被系统结束或核心崩溃"
            Task { await OnDemandStore.shared.suspendRules() }
        }
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
    /// On-Demand (v0.2.32, FlClash iOS parity): the rules are
    /// installed ONLY after startVPNTunnel succeeds — never before,
    /// so a failed start cannot arm an auto-restart loop — and
    /// only when the user opted in (the store defaults OFF; FlClash
    /// iOS never installs the rules at all). A synchronous throw
    /// suspends any installed rules. After the start call, the
    /// tunnel is confirmed: up to 30 s for .connected; a
    /// .disconnected arrival throws the diagnostic error, and a
    /// timeout while still .connecting returns success (the
    /// observer surfaces any later failure). The in-app core
    /// (AppCore, delay tests with the VPN off) is stopped first —
    /// two cores must never run at once.
    @MainActor
    func start() async throws {
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        userInitiatedStop = false
        unexpectedDisconnect = false
        crashLoopActive = false
        reachedConnectedThisStart = false
        // The app-side core (delay tests) must be down before the
        // system VPN starts; two cores must never run at once.
        await AppCore.shared.stop()
        if manager.connection.status == .disconnecting {
            try await waitForStableStatus(manager: manager)
        }
        if [.connecting, .connected, .reasserting].contains(manager.connection.status) {
            return
        }
        try await armManagerForStart(manager)
        // A fresh startupID per run, passed to the extension so the
        // diagnostic record can be correlated by ID (FlClash).
        let startupID = UUID().uuidString
        currentStartupID = startupID
        do {
            try manager.connection.startVPNTunnel(options: ["startupID": startupID as NSString])
        } catch {
            // A synchronous throw is a failed start: suspend any
            // installed rules so the system does not restart it.
            await OnDemandStore.shared.suspendRules()
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
                try retryManager.connection.startVPNTunnel(options: ["startupID": startupID as NSString])
            } catch {
                await OnDemandStore.shared.suspendRules()
                lastError = error.localizedDescription
                throw error
            }
        }
        // The start call only means the system accepted the start;
        // confirm the tunnel actually came up (FlClash
        // waitForTunnelStatus, simplified: 30 s, no generation
        // machinery). On-Demand rules are installed only now — a
        // failed start never arms them.
        try await confirmTunnelUp()
        _ = await OnDemandStore.shared.installRulesIfNeeded()
    }

    /// Waits up to 30 s for the tunnel to reach .connected after
    /// startVPNTunnel succeeded. Throws the startup diagnostic when
    /// the tunnel lands on .disconnected; returns normally on
    /// .connected, or on timeout while still .connecting (the status
    /// observer surfaces any later failure).
    @MainActor
    private func confirmTunnelUp() async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            switch status {
            case .connected:
                return
            case .disconnected:
                let message = lastStartupDiagnostic()
                    ?? "VPN 启动失败（扩展未完成启动）"
                lastError = message
                throw TunnelError.startFailed(message)
            default:
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
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
    /// vpn-startup.json in the App Group, fresh within 180 s AND
    /// matching this run's startupID (the extension adopts the ID
    /// passed in startVPNTunnel(options:); FlClash requires
    /// record.id == id as well as freshness). Returns a one-line
    /// "stage: detail" string, or nil when there is no recent
    /// startup record for this run — used by the Dashboard's
    /// unexpected-disconnect banner so an extension-side failure
    /// shows its stage instead of a generic message.
    func lastStartupDiagnostic() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("vpn-startup.json")),
              let record = try? JSONDecoder().decode(TunnelStartupDiagnosticRecord.self, from: data),
              Date().timeIntervalSince(record.date) < 180,
              // Correlate by ID when this run has one; a record from
              // an older run (different ID) is not this run's error.
              currentStartupID == nil || record.id == currentStartupID else { return nil }
        if let detail = record.detail, !detail.isEmpty {
            return "VPN \(record.stage)：\(detail)"
        }
        return "VPN 阶段：\(record.stage)"
    }

    /// Stop the system VPN. The extension's stopTunnel tears down the
    /// core (tun.stop -> engine.stop -> close session). An explicit
    /// stop MUST win over On-Demand: the installed rules are
    /// suspended first (v0.2.32 — the v0.2.31 "VPN 关不了" bug was
    /// that stop() never cleared them, so iOS restarted the tunnel
    /// immediately). Then wait briefly for a terminal status
    /// (FlClash reconcileStoppedTunnel, simplified to 5 s).
    @MainActor
    func stop() async {
        try? await prepare()
        userInitiatedStop = true
        unexpectedDisconnect = false
        crashLoopActive = false
        rapidDropCount = 0
        rapidDropWindowStart = nil
        await OnDemandStore.shared.suspendRules()
        manager?.connection.stopVPNTunnel()
        // Best-effort wait for a terminal status (5 s); the stop
        // itself is already issued, so a timeout is not an error.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if status == .disconnected { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
    case startFailed(String)

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
        case .startFailed(let message):
            return message
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
