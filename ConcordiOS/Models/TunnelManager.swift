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
    /// The D1 timeout reason, set by confirmTunnelUp() when a start
    /// never reaches a terminal state: the status observer's
    /// failed-start branch fires right after (the stop above lands
    /// .disconnected) and must surface THIS message, not the generic
    /// "扩展未完成启动" fallback. Consumed once by the observer.
    private var pendingStartFailureMessage: String?
    /// Set when the extension reports it could not restart the TUN
    /// runner after a live config change (config B1): the config
    /// applied, but the data plane is down until the VPN restarts.
    /// Read from the extension's tun-restart-needed.json (see
    /// checkTunRestartNeeded); the Dashboard shows it on the VPN
    /// card. Cleared when the file is gone (next successful start
    /// or restart clears it in the extension).
    @Published private(set) var tunRestartNeeded: String?
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
    // MARK: Zombie detection (v0.2.96, patient probe v0.2.97)
    //
    // A "zombie" tunnel reports .connected but its extension core
    // never answers (core log 0 entries, delay.test unreturned,
    // probe.outboundIp notRunning): the system thinks the VPN is
    // up while nothing proxies. The app probes the core after
    // every start and, at most once per manual start, restarts the
    // tunnel to recover — never silently, never in a loop.
    // v0.2.97: the probe is PATIENT — 8 s grace, then up to 3
    // attempts a few seconds apart, and a zombie is declared only
    // when ALL of them fail. v0.2.96 probed once at 2 s and the
    // call failed FAST (~1 s, not the 10 s timeout) while the
    // extension was still booting / between runs, so a healthy
    // tunnel was declared a zombie and the auto-restart disrupted
    // it. A final error also gets one delayed re-probe ~15 s later
    // that clears the banner if the core has since answered.
    /// User-visible zombie state; nil = no zombie. Set when a
    /// zombie is detected, cleared on a successful probe, by the
    /// recovery re-probe, and on manual stop/start.
    @Published private(set) var zombieNotice: String?
    /// True once the one auto-restart for this manual start has
    /// been used. Reset only by a MANUAL start(); the auto-restart
    /// path (startTunnel(manual: false)) preserves it.
    private var zombieRestartAttempted = false
    /// The in-flight zombie probe, so stop() / a new manual start
    /// can cancel it and a stale probe can never restart a VPN the
    /// user already stopped.
    private var zombieProbeTask: Task<Void, Never>?
    /// The one-off recovery re-probe (v0.2.97): scheduled when the
    /// final zombie error is set, it fires once ~15 s later and
    /// clears a stale banner if the core answers by then. It never
    /// restarts anything and never re-schedules itself; cancelled
    /// like the probe on manual stop / a new manual start.
    private var zombieRecoveryTask: Task<Void, Never>?

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
                self.lastError = nil
                self.pendingStartFailureMessage = nil
                self.lastSystemDisconnectError = nil
                self.unexpectedDisconnect = false
                self.reachedConnectedThisStart = true
                self.connectedAt = Date()
                // Config B1: the extension may have written
                // tun-restart-needed.json while this tunnel was
                // coming up (or during a previous run) — re-read it
                // on every connect so the Dashboard banner shows
                // without waiting for a pull-refresh.
                self.checkTunRestartNeeded()
                return
            }
            if new == .disconnected,
               old == .connected || old == .connecting || old == .reasserting,
               !self.userInitiatedStop {
                self.captureLastDisconnectError()
                self.unexpectedDisconnect = true
                if old == .connecting, !self.reachedConnectedThisStart {
                    // FAILED START (never reached .connected): the
                    // extension's startTunnel failed. Do NOT let
                    // On-Demand restart it — suspend the rules and
                    // surface the diagnostic instead of looping.
                    // D1/D6: a confirmTunnelUp() timeout already named
                    // the reason — prefer it over the generic fallback
                    // (and over a stale diagnostic from an older run).
                    if let pending = self.pendingStartFailureMessage {
                        self.pendingStartFailureMessage = nil
                        self.lastError = pending
                    } else {
                        self.lastError = self.lastStartupDiagnostic()
                            ?? "VPN 启动失败（扩展未完成启动）"
                    }
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
    /// drop. A drop within 60 s of a successful start is a rapid
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
            // C2: the six iOS-only tunnel switches, from the saved
            // settings (system defaults when untouched).
            Self.applyNetworkSwitches(to: proto)
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
    /// tunnel is confirmed: up to 45 s for .connected (FlClash
    /// waitForTunnelStatus); a .disconnected arrival throws the
    /// diagnostic error, and a timeout while still .connecting /
    /// .disconnecting / .invalid / .reasserting STOPS the tunnel
    /// and throws (D1 — a start that never reaches a terminal state
    /// is a failed start, never a silent success). The in-app core
    /// (AppCore, delay tests with the VPN off) is stopped first —
    /// two cores must never run at once.
    @MainActor
    func start() async throws {
        try await startTunnel(manual: true)
    }

    /// The shared start path. `manual: true` is a user-initiated
    /// start: it resets the zombie-restart budget, cancels any
    /// stale probe and clears the zombie notice. `manual: false`
    /// is the zombie auto-restart: it preserves
    /// zombieRestartAttempted so at most one auto-restart happens
    /// per manual start.
    @MainActor
    private func startTunnel(manual: Bool) async throws {
        if manual {
            zombieRestartAttempted = false
            zombieProbeTask?.cancel()
            zombieProbeTask = nil
            zombieRecoveryTask?.cancel()
            zombieRecoveryTask = nil
            zombieNotice = nil
        }
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        // S2 (config B2): make sure the shared files the extension
        // reads (dns.json / sniffer.json / general.json / tunnel.json
        // / mitm.json) exist before the core boots — a fresh install
        // without them makes the core run its own defaults (DNS
        // disabled) instead of the UI's. SettingsStore has no shared
        // instance, so a short-lived one loads the persisted
        // settings; ensureSharedFilesExist only writes files that
        // are missing, never overwrites existing ones.
        SettingsStore().ensureSharedFilesExist()
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
        // waitForTunnelStatus, 45 s, simplified: no generation
        // machinery). On-Demand rules are installed only now — a
        // failed start never arms them.
        try await confirmTunnelUp()
        _ = await OnDemandStore.shared.installRulesIfNeeded()
        // The tunnel reports .connected — now verify the extension
        // core actually answers (zombie check, v0.2.96).
        launchZombieProbe()
    }

    /// Zombie probe (v0.2.97): 8 s grace for the extension core to
    /// finish booting, then up to THREE config.general probes 3 s
    /// apart. Only when ALL attempts fail is the tunnel a zombie.
    /// v0.2.96 probed once at 2 s and the call failed FAST (~1 s,
    /// not the 10 s timeout) — the extension answers an app
    /// message immediately with an error envelope while its core
    /// session is not open yet (PacketTunnelProvider
    /// handleAppMessage: `guard session != 0`, and the app-side
    /// startupID guard in drainMessages /
    /// performProviderMessage threw TunnelError.notRunning just as
    /// fast when the tunnel flapped between enqueue and drain), so a
    /// tunnel that was still booting was declared a zombie and the
    /// auto-restart disrupted it. v0.2.98 dropped the connectedAt
    /// identity check in drainMessages / performProviderMessage
    /// (the exact-Date comparison rejected live IPC whenever the
    /// tunnel flapped between enqueue and drain); startupID is now
    /// the only IPC-identity guard, and drainMessages waits up to
    /// 2 s for a still-.connecting tunnel to settle. A single fast
    /// failure must never decide this on its own. Success clears the notice; failure
    /// of all three attempts goes to handleZombieDetected(). Only
    /// ever launched from startTunnel() after confirmTunnelUp —
    /// never from the status observer or On-Demand reconnects.
    @MainActor
    private func launchZombieProbe() {
        zombieProbeTask?.cancel()
        zombieProbeTask = nil
        zombieRecoveryTask?.cancel()
        zombieRecoveryTask = nil
        zombieProbeTask = Task { [weak self] in
            guard let self else { return }
            // 8 s grace: the tunnel reports .connected as soon as
            // the network settings are in, while the extension's
            // core session / RPC dispatcher may still be settling
            // (and on an auto-restart, confirmTunnelUp can return
            // on a stale .connected from the run being torn down).
            // Probing at 2 s caught it mid-boot.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            // Up to 3 attempts, 3 s apart: each attempt is itself
            // bounded to ~10 s by probeExtensionCore, so the worst
            // case here is 8 + 10 + 3 + 10 + 3 + 10 ≈ 44 s after
            // connect before a zombie is declared — silent all the
            // while, and the tunnel keeps proxying if it is healthy.
            for attempt in 1...3 {
                if await self.probeExtensionCore() {
                    self.zombieNotice = nil
                    return
                }
                guard !Task.isCancelled else { return }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
            // All attempts failed — but only declare a zombie while
            // the tunnel is still up; if it dropped on its own the
            // disconnect path owns the recovery, not the probe.
            guard !Task.isCancelled, self.status == .connected else { return }
            await self.handleZombieDetected()
        }
    }

    /// One config.general call against the extension core, raced
    /// against a 10 s sleep so a hung call cannot block past ~10 s.
    /// Returns true only when the core answers. A fresh
    /// ConcordClient() is deliberate here, not a bug: the client
    /// holds no session — init only reads the persisted mode, and
    /// the live transport routes every call through
    /// TunnelManager.shared.sendProviderMessage, which re-acquires
    /// the system session per call — so a fresh instance is
    /// identical to any shared one, and a fast failure is the
    /// extension not being ready yet (see launchZombieProbe), not
    /// the client. The patience lives in launchZombieProbe (grace
    /// + retries), not here.
    @MainActor
    private func probeExtensionCore() async -> Bool {
        do {
            let answered: ConcordGeneralState? = try await withThrowingTaskGroup(of: ConcordGeneralState?.self) { group in
                group.addTask { try await ConcordClient().configGeneral() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return nil
                }
                guard let first = try await group.next() else { return nil }
                group.cancelAll()
                return first
            }
            return answered != nil
        } catch {
            return false
        }
    }

    /// A zombie was detected (all three probes failed). Set the
    /// visible notice and, if the one auto-restart for this manual
    /// start is still unused, spend it: stop, then restart via the
    /// internal path (which preserves zombieRestartAttempted and
    /// launches a fresh probe). If the restart's probe also fails,
    /// this runs again with the flag already set and only sets the
    /// final error — never a second restart. After the final error,
    /// a one-off recovery re-probe ~15 s later clears the banner
    /// if the core has since answered (v0.2.97: the v0.2.96 banner
    /// went stale — traffic flowing and the IP showing while
    /// "VPN 核心无响应" stayed on screen).
    @MainActor
    private func handleZombieDetected() async {
        guard !zombieRestartAttempted else {
            setFinalZombieError()
            return
        }
        zombieRestartAttempted = true
        zombieNotice = "隧道已连接但核心无响应，正在重启…"
        await stop()
        // stop() clears the notice as a manual stop would; restore
        // the restarting notice for the auto-restart in progress.
        zombieNotice = "隧道已连接但核心无响应，正在重启…"
        do {
            try await startTunnel(manual: false)
        } catch {
            // The restart itself never came up; confirmTunnelUp
            // already set lastError — surface the final zombie text.
            setFinalZombieError()
        }
        // If the restart succeeded, its own probe (launched by
        // startTunnel) decides: success clears the notice, failure
        // re-enters here with the flag set and only sets the final
        // error above.
    }

    /// The final zombie error text, plus the one-off recovery
    /// re-probe that can clear it. Shared by both final-error
    /// paths (restart budget already spent, restart itself failed).
    /// lastError keeps the message as a record even if the banner
    /// is later cleared by the recovery re-probe.
    @MainActor
    private func setFinalZombieError() {
        let message = "隧道已连接但核心无响应，重启后仍无响应，请检查配置或手动重新启动 VPN。"
        zombieNotice = message
        lastError = message
        scheduleZombieRecoveryReprobe()
    }

    /// One delayed re-probe ~15 s after the final zombie error:
    /// if the core answers now, the banner was stale (the tunnel
    /// recovered on its own) and is cleared. Never restarts, never
    /// re-schedules — one shot. Cancelled on manual stop / a new
    /// manual start, like the probe itself.
    @MainActor
    private func scheduleZombieRecoveryReprobe() {
        zombieRecoveryTask?.cancel()
        zombieRecoveryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            // Only a live tunnel can have recovered; a stopped one
            // is the user's (or the system's) business, and a new
            // manual start cancels this task anyway.
            guard self.status == .connected else { return }
            if await self.probeExtensionCore() {
                self.zombieNotice = nil
            }
        }
    }

    /// Waits up to 45 s for the tunnel to reach .connected after
    /// startVPNTunnel succeeded (FlClash waitForTunnelStatus, 45 s).
    /// Decides only on a terminal state: .connected returns,
    /// .disconnected throws the startup diagnostic. A timeout while
    /// still .connecting / .disconnecting / .invalid / .reasserting
    /// is a FAILED start, not a slow one (D1): the tunnel is
    /// stopped so it cannot sit in .connecting forever showing
    /// "运行中", and a real error is thrown (D6 — ProxyStore.toggle
    /// turns the throw into proxyStore.startError, and lastError /
    /// pendingStartFailureMessage carry it to the Dashboard banner).
    @MainActor
    private func confirmTunnelUp() async throws {
        let deadline = Date().addingTimeInterval(45)
        var sawConnecting = false
        while Date() < deadline {
            let current = manager?.connection.status ?? status
            switch current {
            case .connected:
                lastError = nil
                pendingStartFailureMessage = nil
                return
            case .connecting, .reasserting:
                sawConnecting = true
            case .disconnected where sawConnecting || unexpectedDisconnect:
                let message = lastStartupDiagnostic()
                    ?? "VPN 启动失败（扩展未完成启动）"
                lastError = message
                captureLastDisconnectError()
                throw TunnelError.startFailed(message)
            default:
                // The initial disconnected state may precede the system's
                // connecting notification; it is not a failed attempt yet.
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let message = "VPN 启动超时（45 秒内未连接），已停止隧道：扩展可能启动缓慢或已无响应，请检查配置后重试"
        lastError = message
        pendingStartFailureMessage = message
        manager?.connection.stopVPNTunnel()
        throw TunnelError.startFailed(message)
    }

    /// Apply the six iOS-only NETunnelProviderProtocol switches
    /// (C2) from the saved settings onto a protocol. The saved
    /// defaults match the system defaults, so a user who never
    /// touches them sees no change. Called when the protocol is
    /// created (prepare) AND before every start (armManagerForStart),
    /// so a toggle takes effect on the next VPN start even with an
    /// already-saved manager. Pure NE API, core-independent.
    private static func applyNetworkSwitches(to proto: NETunnelProviderProtocol) {
        let settings = SettingsStore()
        proto.includeAllNetworks = settings.includeAllNetworks
        proto.excludeLocalNetworks = settings.excludeLocalNetworks
        proto.excludeAPNs = settings.excludeAPNs
        proto.excludeCellularServices = settings.excludeCellularServices
        proto.enforceRoutes = settings.enforceRoutes
        // excludeDeviceCommunication is iOS 17.4+ only; on 17.0–17.3
        // it stays at the system default (the app targets 17.0).
        if #available(iOS 17.4, *) {
            proto.excludeDeviceCommunication = settings.excludeDeviceCommunication
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
        // C2: re-assert the six tunnel switches before every start,
        // so a toggle takes effect on the next start.
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            Self.applyNetworkSwitches(to: proto)
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
    /// System error is separate from extension records, including early launch failures.
    @Published private(set) var lastSystemDisconnectError: String?

    func captureLastDisconnectError() {
        let requestedStartupID = currentStartupID
        manager?.connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            let ns = error as NSError
            let detail = "\(ns.localizedDescription) [\(ns.domain):\(ns.code)]"
            Task { @MainActor in
                guard let self, self.currentStartupID == requestedStartupID,
                      self.manager?.connection.status != .connected else { return }
                self.lastSystemDisconnectError = detail
            }
        }
    }

    func lastStartupDiagnostic() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("vpn-startup.json")),
              let record = try? JSONDecoder().decode(TunnelStartupDiagnosticRecord.self, from: data),
              Date().timeIntervalSince(record.date) < 180,
              // Correlate by ID when this run has one; a record from
              // an older run (different ID) is not this run's error.
              currentStartupID == nil || record.id == currentStartupID else { return nil }
        let base: String
        if let detail = record.detail, !detail.isEmpty {
            base = "VPN \(record.stage)：\(detail)"
        } else {
            base = "VPN 阶段：\(record.stage)"
        }
        // v0.2.96: append the extension's step trail when present,
        // so LogStore's "== VPN 启动诊断 ==" export shows it.
        if let steps = record.steps, !steps.isEmpty {
            return base + "\n" + steps.joined(separator: "\n")
        }
        return base
    }

    /// The extension's vpn-diagnostics.json startedAt (audit D4):
    /// the tunnel's real start time, written when the tunnel comes
    /// up and refreshed on the watchdog tick (30 s). The app reads
    /// it so the Dashboard uptime survives an app restart while the
    /// VPN is running, instead of restarting from zero. Nil when
    /// there is no fresh record (updated within 180 s) or the
    /// tunnel is stopped (startedAt is null then).
    func readTunnelStartedAt() -> Date? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("vpn-diagnostics.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startedMs = json["startedAt"] as? Int64,
              let updatedMs = json["updatedAt"] as? Int64,
              Date().timeIntervalSince1970 * 1000 - Double(updatedMs) < 180_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(startedMs) / 1000)
    }

    /// Reads the extension's tun-restart-needed.json (config B1):
    /// written when a live config change killed the TUN runner and
    /// the extension could not restart it, deleted on the next
    /// successful start / restart / stop. No expiry is applied —
    /// the file's lifecycle is the deletion, so a present file
    /// means the running tunnel's data plane is down right now.
    /// Called by the Dashboard on appear / pull-refresh.
    func checkTunRestartNeeded() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("tun-restart-needed.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = json["reason"] as? String, !reason.isEmpty else {
            tunRestartNeeded = nil
            return
        }
        tunRestartNeeded = reason
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
        zombieProbeTask?.cancel()
        zombieProbeTask = nil
        zombieRecoveryTask?.cancel()
        zombieRecoveryTask = nil
        zombieNotice = nil
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
    /// rule per DISCONNECT SSID — excluded but not direct (fork
    /// SharedStateStore.disconnectSSIDs) — then a connect rule for
    /// every other network; rule order matters, disconnect first. A
    /// direct SSID must NOT get a disconnect rule: the tunnel has to
    /// stay up on it so the extension's SsidDirectController can
    /// switch the core to direct mode. With no excluded SSIDs the
    /// single connect rule means "always connect on demand". Disabled
    /// clears the rules and turns on-demand off. The manager must be
    /// saved for the rules to take effect; a failure surfaces to the
    /// caller instead of being swallowed.
    @MainActor
    func updateOnDemandRules(enabled: Bool, excludedSSIDs: [String], directSSIDs: [String] = []) async throws {
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        if enabled {
            let direct = Set(directSSIDs)
            var rules: [NEOnDemandRule] = excludedSSIDs.filter { !direct.contains($0) }.map { ssid in
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
    /// TunnelError.noReply when the extension answers nothing, and
    /// TunnelError.timedOut when the extension does not answer within
    /// the deadline (interface B1 / proxy B4 — a dead extension used
    /// to hang every live call forever). The deadline comes from the
    /// method, FlClash's values (lib/core/interface.dart,
    /// lib/common/constant.dart): delay calls 30 s
    /// (delayTestGuardDuration), snapshots / probes and everything
    /// else 10 s (_snapshotTimeout), slow config / profile / provider
    /// / geo loads 60 s (the extension's own boot timeout for
    /// config.apply). An explicit timeoutSeconds overrides the table.
    private struct QueuedMessage {
        let data: Data
        let deadline: Date
        let startupID: String?
        let continuation: CheckedContinuation<Data, Error>
    }
    private var messageQueue: [QueuedMessage] = []
    private var messageBusy = false

    /// One active system IPC request, matching FlClash's provider queue.
    @MainActor
    func sendProviderMessage(_ data: Data, timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard messageQueue.count < 128 else {
                continuation.resume(throwing: TunnelError.noReply)
                return
            }
            let timeout = timeoutSeconds ?? Self.timeoutForMethod(Self.methodName(in: data) ?? "?")
            messageQueue.append(QueuedMessage(data: data, deadline: Date().addingTimeInterval(timeout),
                                              startupID: currentStartupID,
                                              continuation: continuation))
            drainMessages()
        }
    }

    @MainActor
    private func drainMessages() {
        guard !messageBusy, !messageQueue.isEmpty else { return }
        messageBusy = true
        let next = messageQueue.removeFirst()
        Task { @MainActor in
            do {
                guard next.startupID == self.currentStartupID else {
                    throw TunnelError.notRunning
                }
                // v0.2.98: the tunnel may still be .connecting when a probe
                // is enqueued right after confirmTunnelUp — wait briefly for
                // the status to settle instead of failing immediately. The
                // .connected notification can lag behind the IPC enqueue, and
                // a fast notRunning here is what made the zombie probe
                // misfire. Bounded to 2 s; performProviderMessage still
                // re-checks .connected before sending.
                if self.status == .connecting {
                    let settleDeadline = Date().addingTimeInterval(2)
                    while self.status == .connecting, Date() < settleDeadline {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                guard next.deadline > Date() else {
                    throw TunnelError.timedOut(Self.methodName(in: next.data) ?? "?", 0)
                }
                let reply = try await self.performProviderMessage(next.data, deadline: next.deadline,
                                                                 startupID: next.startupID)
                next.continuation.resume(returning: reply)
            } catch {
                next.continuation.resume(throwing: error)
            }
            self.messageBusy = false
            self.drainMessages()
        }
    }

    @MainActor
    private func performProviderMessage(_ data: Data, deadline: Date, startupID: String?) async throws -> Data {
        // Reacquire the system's connection, rather than reusing a stale manager.
        let managers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
        guard let active = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
                && $0.connection.status == .connected
        }), let session = active.connection as? NETunnelProviderSession else {
            throw TunnelError.notRunning
        }
        let method = Self.methodName(in: data) ?? "?"
        guard startupID == currentStartupID else {
            throw TunnelError.notRunning
        }
        let timeout = deadline.timeIntervalSinceNow
        guard timeout > 0 else { throw TunnelError.timedOut(method, 0) }
        return try await withCheckedThrowingContinuation { continuation in
            let claim = ReplyClaim()
            do {
                try session.sendProviderMessage(data) { reply in
                    guard claim.claim() else { return }
                    if let reply {
                        // Config B1: the extension re-starts the TUN
                        // runner (or records tun-restart-needed.json)
                        // before answering a live config.apply /
                        // config.patch — re-read the flag now, so the
                        // Dashboard banner appears without waiting
                        // for a pull-refresh or a reconnect.
                        if method == "config.apply" || method == "config.patch" {
                            Task { @MainActor [weak self] in self?.checkTunRestartNeeded() }
                        }
                        continuation.resume(returning: reply)
                    } else {
                        continuation.resume(throwing: TunnelError.noReply)
                    }
                }
            } catch {
                guard claim.claim() else { return }
                continuation.resume(throwing: error)
                return
            }
            // The timeout resumes the continuation (so the caller is
            // never left suspended); a late reply after that is
            // dropped by the claim. The session call itself has no
            // cancel API — a timed-out call's reply is simply ignored.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard claim.claim() else { return }
                continuation.resume(throwing: TunnelError.timedOut(method, timeout))
            }
        }
    }

    /// The "method" field of a JSON-RPC envelope, for the timeout
    /// table below. Nil when the bytes are not a request object.
    private static func methodName(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["method"] as? String
    }

    /// FlClash-matching deadline for one extension call (see
    /// sendProviderMessage). Delay tests may legitimately spend up
    /// to 8 s queueing + 8 s probing twice over, so they get the
    /// 30 s guard; config / profile / provider / geo work may
    /// download, so it gets 60 s; everything else answers fast or
    /// the extension is dead, so 10 s.
    private static func timeoutForMethod(_ method: String) -> TimeInterval {
        if method.hasPrefix("delay.") { return 30 }
        if method.hasPrefix("config.") || method.hasPrefix("profile.")
            || method.hasPrefix("provider.") || method == "geo.update"
            || method == "ruleSet.compile" || method == "convert.subscription" {
            return 60
        }
        return 10
    }
}

/// One-shot guard so a sendProviderMessage reply and its timeout
/// can never resume the same continuation twice (which would trap).
private final class ReplyClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum TunnelError: LocalizedError {
    case noManager
    case notRunning
    case noReply
    case timedOut(String, TimeInterval)
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
        case .timedOut(let method, let seconds):
            return "扩展在 \(Int(seconds)) 秒内未回复 \(method)：隧道可能已死但状态仍显示已连接，请重启 VPN"
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
    /// Extension step trail (v0.2.96, written by
    /// PacketTunnelProvider into vpn-startup.json as "steps"):
    /// timestamped strings like "19:06:52.123 tun.start: ok".
    /// Optional so JSON without it still decodes as nil.
    let steps: [String]?
}
