import Foundation
import Network
import NetworkExtension
import os

// PacketTunnelProvider — Network Extension entry point.
//
// The Concord core runs IN THIS PROCESS (in-process staticlib; iOS
// forbids spawning a helper process). The app process loads the core
// too, but only for delay tests with the VPN off
// (ConcordiOS/Models/AppCore.swift) — never while the tunnel runs.
// This extension talks to the app through NEProviderManager /
// sendProviderMessage (JSON-RPC) and reads live snapshots from the App
// Group container (see "Extension <-> app IPC" below).
//
// Startup sequence (core.hello -> core.init -> config.apply ->
// engine.start -> tun.start), mirroring bins/android, with
// EngineConfig { android: false } and capabilities
// ["tun.inherited", "tun.channel"] (upstream/bins/ios/src/core.rs):
//   1. Read config.yaml from the App Group shared container.
//   1b. GeoSeed.ensureGeoFiles(container): pre-seed geoip.metadb /
//      GeoSite.dat / ASN.mmdb with URLSession (system trust store)
//      before config.apply — a missing MMDB makes the core download
//      it over its own TLS client, which the campus network rejects
//      (v0.2.33 "can't download MMDB: ... UnknownIssuer"); a present
//      file makes the core skip its download entirely. Best-effort:
//      if files are still missing, config.apply fails with the core's
//      own error, recorded in the startup diagnostic.
//   2. concord_ios_start() (once per process), then open a JSON-RPC
//      session (concord_ios_open_session). Replies arrive on the Deliver
//      callback, on a core thread; all state lives on `coreQueue`.
//   3. core.hello (protocol 1, concord-proto PROTOCOL_VERSION),
//      core.init {"home": <app-group dir>},
//      config.apply {"profile": {"path": <abs config.yaml path>},
//                    "overlay": {"mitm": <mitm.json contents, if any>}},
//      engine.start.
//   4. Open the Option B packet channel
//      (concord_ios_packet_channel_open, patches/02-packet-channel.patch)
//      and tun.start {"source": {"kind": "channel", "handle": H}, ...}.
//      The socketpair / inherited-fd Option A (concord_ios_adopt_fd) is
//      NOT used: the channel is the supported path.
//   5. Configure the tunnel interface (NEPacketTunnelNetworkSettings)
//      from tunnel.json / defaults, subscribe to the five live streams,
//      start the packet pump.
//
// Packet pump (Option B, no fd involved):
//   packetFlow.readPackets -> concord_ios_packet_write(handle, packet)
//   (returns 1 queued / 0 ring full / -1 unknown handle); poll
//   concord_ios_packet_read(handle, buf, cap) -> packetFlow.writePackets.
//   On ring-full (0) the packet is dropped and counted; if the ring stays
//   full, reads pause briefly (10 ms) instead of busy-looping. Outbound
//   packets are also drained on a 20 ms timer, so core output that is not
//   triggered by an inbound packet (timers, retransmits) still flows.
//   Packets are bare IP packets (no utun header) on both sides.
//
// Extension <-> app IPC (the app loads the core only for delay
// tests with the VPN off; see AppCore.swift):
//   * App -> extension (commands): NETunnelProviderManager /
//     NETunnelProviderSession.sendProviderMessage, carrying ONE JSON-RPC
//     2.0 request per message (the same envelope ConcordClient builds).
//     handleAppMessage forwards it to the in-process core session and
//     replies with the JSON-RPC response bytes. The extension rewrites
//     the request id to its own id space (app ids and the extension's
//     own ids share one core session) and restores the app's id in the
//     reply. A config.apply request with no overlay gets the MITM
//     overlay merged in from the shared mitm.json (see below).
//   * Extension -> app (live data): the extension subscribes once, at
//     startup, to traffic.watch / connection.watch / log.watch /
//     dns.watch / proxy.watch and writes the latest snapshot to the App
//     Group container as JSON files the app polls:
//       snapshots/traffic.json      {"updatedAt": <ms>, "data": <Traffic>}
//       snapshots/connections.json  {"updatedAt": <ms>, "data": {"connections": [...]}}
//       snapshots/logs.json         {"updatedAt": <ms>, "data": {"entries": [...]}}
//       snapshots/dns.json          {"updatedAt": <ms>, "data": {"entries": [...]}}
//       snapshots/proxies.json      {"updatedAt": <ms>, "data": <ProxyGroups>}
//       snapshots/delay.json        {"updatedAt": <ms>, "data": {"runId": N, "done": bool, "results": [...]}}
//     Stream events arrive as `$/event` notifications
//     {"sub": N, "seq": M, "data": [...]}; traffic events are full
//     Traffic values, connection events are ConnectionDelta
//     {opened, closed, counters} applied to a table the extension
//     keeps, log/dns events are single entries appended to a bounded
//     buffer (500 entries). After each batch the extension refills one
//     unit of credit ($/credit {"sub": N, "n": 1}); without it the
//     server pump stops after the initial credit (WatchOptions.credit,
//     default 4). A `resync: true` event means events were dropped:
//     the extension re-subscribes that stream and replaces the table
//     from the new snapshot.
//
// MITM overlay: config.patch has NO mitm field, and the profile YAML is
// the user's file (the app does not rewrite it). The MITM section
// therefore travels in config.apply's `overlay` ("the profile gives only
// proxies, proxy-groups, sub-rules and rules; every other key comes from
// here" — upstream crates/proto/src/types/config.rs). The app writes the
// user's MITM choices to the shared mitm.json
// ({"enable": ..., "hostname": [...], "decrypt-tls": ...,
//   "ca-fingerprint": ...} — the RawConfig keys of
// crates/mitm/src/config.rs); this extension merges it as
// {"mitm": <mitm.json>} into every config.apply that has no overlay of
// its own, including its own startup apply. MITM modules add a second
// file, module-mitm.json (MitmModuleStore: the merged lists + rules of
// the enabled modules, in order); mergedMitmOverlay() puts the user's
// hostnames first and appends the modules' lists, and the module rules
// travel as the overlay's top-level "rules" — the core prepends
// overlay rules before the profile's own (upstream
// crates/config/src/merge.rs: rules_after), exactly like FlClash's
// rawConfig['rules'] = [...mitm.rules, ...rules]. The same file also
// carries what the lists alone cannot: "h2" (a module asking for
// HTTP/2 turns mitm.h2 on), "rule-providers" (the profile's providers
// merged with the modules' — the overlay replaces the profile's
// wholesale, so a rule must never name a provider the overlay does
// not carry, or config.apply fails with `rule set […] not found`),
// "module-rule-providers" (the module-only map, used when
// "profileDigest" no longer matches config.yaml, i.e. the profile
// changed since the file was written), and "network" (the modules'
// DNS / hosts / TUN-route edits, applied here onto dns.json /
// hosts.json / the tun overrides — the profile's own sections never
// reach the core, so those files ARE the lists the edits run over).
// A module's proxy-bypass ask (bypass-domain) is not applied: the
// core calls it "the host's proxy bypass list" and this host is a
// packet tunnel with no such list. Module scripts and
// map-local files live in <home>/mitm/resources/ (the core's resources
// directory, home being this container), so the core reads them by the
// content-hash names the module-mitm.json lines name. The DNS choices
// travel the same way: the app writes dns.json (DnsConfig keys,
// kebab-case — "enhanced-mode", "fake-ip-range", upstream
// crates/config/src/dns.rs) and the extension merges it as
// {"dns": <dns.json>} alongside mitm. NTP and sniffer travel the same
// way (ntp.json -> "ntp", sniffer.json -> "sniffer"). Top-level
// RawConfig keys config.patch cannot carry (global-ua,
// interface-name) travel in general-overlay.json, merged key by key
// into the overlay. The override framework (OverrideStore) writes
// overrides.json — global overrides plus one entry per profile UUID
// and the active profile id — and effectiveSection() merges the
// effective overrides over each base file (global, then the active
// profile's); the tun fragment has no base file and goes straight
// into the overlay as "tun" (the core parses it into TunConfig, so
// strict-route / udp-timeout / dns-hijack / … apply; mtu and
// congestion-controller are additionally folded into tun.start via
// readTunnelSettings). General settings travel as
// general.json (ConfigPatchParams wire keys, snake_case) and are sent
// as config.patch once at startup, after engine.start, so saved
// settings take effect on the next VPN start.
//
// Memory: the extension runs under the NetworkExtension memory limit
// (historically ~15 MB, reported ~50 MB more recently). The pump reuses
// one 64 KiB read buffer, keeps no per-packet logs, and bounds the
// log/dns buffers (500 entries) and the outbound drain (64 packets per
// pass). The core + rule/geo data fitting in the limit is UNVERIFIED
// until a device run.
//
// UNVERIFIED (no Xcode / Apple SDK on the Linux VM where this was
// written): the staticlib build (ios-core-check.yml), the channel
// bridge against real traffic, tun.start's address handling, and the
// exact snapshot/event JSON the core emits. This file compiles against
// the documented API surface only; a macOS runner + device run is the
// proof. It does NOT claim the app can proxy traffic yet.

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private static let log = Logger(
        subsystem: "com.concord.ios", category: "PacketTunnel")

    // App Group shared container (must match the entitlements + ExportOptions).
    private let appGroupID = "group.434fff4c253add77.1"
    private let configFileName = "config.yaml"
    private let mitmFileName = "mitm.json"
    private let moduleMitmFileName = "module-mitm.json"
    private let dnsFileName = "dns.json"
    private let ntpFileName = "ntp.json"
    private let snifferFileName = "sniffer.json"
    private let generalOverlayFileName = "general-overlay.json"
    private let overridesFileName = "overrides.json"
    private let generalSettingsFileName = "general.json"
    private let tunnelSettingsFileName = "tunnel.json"
    private let addedRulesFileName = "added-rules.json"
    private let hostsFileName = "hosts.json"

    // The tunnel interface address. tun.start takes CIDR prefixes
    // (upstream crates/engine/src/tun.rs: Prefix::parse), so the core
    // gets "198.18.0.1/32"; the NE interface gets the plain address.
    private let tunnelAddress = "198.18.0.1"

    /// All core state is mutated only on this queue. The Deliver
    /// callback runs on a core thread and hops onto it.
    private let coreQueue = DispatchQueue(label: "com.concord.ios.core")
    /// Guards pumpRunning / isStopping, which are read from the
    /// packetFlow callback thread as well as coreQueue, and the
    /// request-id counter. (A plain lock/unlock helper rather than
    /// `NSLock.withLock`, which needs a newer toolchain than this
    /// project's Xcode 15.0 baseline.)
    private let stateLock = NSLock()
    private func locked<T>(_ work: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return work()
    }
    private var _pumpRunning = false
    private var pumpRunning: Bool {
        get { locked { _pumpRunning } }
        set { locked { _pumpRunning = newValue } }
    }
    private var _isStopping = false
    private var isStopping: Bool {
        get { locked { _isStopping } }
        set { locked { _isStopping = newValue } }
    }

    private var session: UInt64 = 0
    private var channelHandle: UInt64 = 0
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var subscriptions: [Int: StreamKind] = [:]

    // Config B1 — the fingerprint of the core's (tun, tun_inet4,
    // ipv6) triple the CURRENT channel runner was started with
    // (see tunTripleFingerprint). reconcile_tun kills the runner
    // whenever a live apply/patch moves that triple, so after
    // forwarding one, maybeRestartChannelTun compares fingerprints
    // and re-runs tun.start when they differ. Nil before the first
    // tun.start.
    private var channelTunFingerprint: String?
    /// The reason the last TUN re-start failed, if any (config B1):
    /// written to tun-restart-needed.json for the app's Dashboard
    /// banner, so a dead data plane is never silent. Nil when the
    /// runner is up or was intentionally not restarted.
    private var tunRestartNeeded: String?
    private let tunRestartNeededFileName = "tun-restart-needed.json"

    // Live tables behind the snapshot files (see header comment).
    private var connectionTable: [UInt64: [String: Any]] = [:]
    private var logBuffer: [[String: Any]] = []
    private var dnsBuffer: [[String: Any]] = []
    private var eventBuffer: [[String: Any]] = []
    private let maxBufferedEntries = 500

    // proxy.watch table: the latest ProxyGroups, kept as the group's
    // order plus the group / node arrays so ProxyDelta events (whole
    // changed groups / nodes + removed names) can be applied in place
    // by name while preserving order.
    private var proxyOrder: [String] = []
    private var proxyGroups: [[String: Any]] = []
    private var proxyNodes: [[String: Any]] = []

    // delay.run accumulator: one batch delay test at a time. The app
    // starts a run with delay.run; its Result/Done events accumulate
    // here and are written to snapshots/delay.json for the app to poll.
    // A new run replaces the accumulator; the old stream's late events
    // are ignored (its sub no longer matches) and the run ends by
    // itself with its Done event.
    private struct DelayRunAccumulator {
        let sub: Int
        var results: [[String: Any]] = []
        var done: Bool = false
    }
    private var delayRun: DelayRunAccumulator?

    // Packet pump.
    private var readBuffer = [UInt8](repeating: 0, count: 65535)
    private var drainTimer: DispatchSourceTimer?
    private var ringFullStreak = 0
    private var packetsIn: UInt64 = 0
    private var packetsOut: UInt64 = 0
    private var packetsDroppedFull: UInt64 = 0

    // Long-run stability (v0.2.26 Batch F). The system-level backstop
    // is On-Demand (TunnelManager/OnDemandStore, default on): it
    // restarts the tunnel after a failure. These three guards run
    // inside the extension and only fire when something is actually
    // wrong — nothing here restarts a healthy tunnel.
    //
    // Watchdog: traffic.watch pushes a full Traffic value every
    // second while the core is alive (upstream crates/api/src/watch.rs:
    // a ticker emits unconditionally), so "no core message at all"
    // is the liveness signal. No extra RPC is sent: engine.state is
    // a subscribe, not a unary call (re-subscribing every tick would
    // leak subscriptions), and a second core.hello handshake is not
    // defined as idempotent. Network loss alone cannot trip it (the
    // traffic ticker is core-internal, not network-dependent).
    private var watchdogTimer: DispatchSourceTimer?
    private var lastCoreMessageAt: Date?
    private var watchdogFailures = 0
    // Memory pressure: the extension lives under the NetworkExtension
    // memory limit (historically ~15 MB, reported ~50 MB more
    // recently); Jetsam kills the tunnel when it is exceeded.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    // Path monitor: re-assert the tunnel network settings when the
    // underlying network changes (Wi-Fi <-> cellular).
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var pathReapplyWorkItem: DispatchWorkItem?
    private var lastAppliedNetworkSettings: NEPacketTunnelNetworkSettings?

    // SSID direct override (v0.2.43 C1): watches the Wi-Fi SSID while
    // the tunnel is up and switches the in-process core to direct on a
    // direct SSID, restoring the previous mode on leaving. Port of the
    // fork's SsidDirectController; the fork talks to its core over the
    // 9090 HTTP controller, ours is in-process, so the mode read/write
    // are closures over this provider's own sendCoreRequest
    // (config.general / config.patch). Started at the end of bootCore
    // (core + TUN up) and stopped in stopTunnel.
    private lazy var ssidDirectController = SsidDirectController(
        appGroupID: appGroupID,
        fetchMode: { [weak self] completion in
            Task { [weak self] in
                guard let self else { completion(nil); return }
                do {
                    let result = try await self.sendCoreRequest(
                        method: "config.general", params: [:], timeoutSeconds: 15)
                    completion((result as? [String: Any])?["mode"] as? String)
                } catch {
                    completion(nil)
                }
            }
        },
        setMode: { [weak self] mode, completion in
            Task { [weak self] in
                guard let self else { completion(false); return }
                do {
                    _ = try await self.sendCoreRequest(
                        method: "config.patch", params: ["mode": mode], timeoutSeconds: 15)
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        })

    private struct PendingRequest {
        /// The app's original request id, if this request came from
        /// handleAppMessage (nil for the extension's own requests).
        let appID: Int?
        let continuation: CheckedContinuation<Data, Error>
    }

    private enum StreamKind: String {
        case traffic, connection, log, dns, proxy, route, events, engine

        /// The JSON-RPC method name. All streams are "<kind>.watch"
        /// except engine.state, which is a stream named "engine.state"
        /// (there is no "engine.watch").
        var methodName: String {
            switch self {
            case .engine: return "engine.state"
            default: return "\(rawValue).watch"
            }
        }
    }

    /// One record of vpn-startup.json. Same JSON shape as the app's
    /// TunnelStartupDiagnosticRecord (the two targets cannot share
    /// the type); mirrors FlClash's TunnelStartupDiagnostic.
    private struct StartupDiagnosticRecord: Codable {
        let id: String
        let stage: String
        let detail: String?
        let date: Date
    }

    private enum TunnelSetupError: LocalizedError {        case noAppGroup
        case noConfig
        case tunDisabled
        case coreStartFailed
        case sessionFailed
        case channelFailed
        case rpcFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAppGroup:
                return "App Group 容器不可用，请检查 entitlements 与 App Group 配置"
            case .noConfig:
                return "尚未导入订阅：请先在主 App 里导入一个订阅（config.yaml），再启动 VPN"
            case .tunDisabled:
                return "TUN 已在设置中关闭：iOS 上 TUN 是唯一的数据面，请在主 App 设置里重新启用 TUN 后再启动"
            case .coreStartFailed:
                return "Concord 核心启动失败（concord_ios_start 返回非 0）"
            case .sessionFailed:
                return "Concord 核心会话打开失败（核心未运行）"
            case .channelFailed:
                return "数据包通道打开失败（concord_ios_packet_channel_open 返回 0）"
            case .rpcFailed(let message):
                return "核心调用失败：\(message)"
            }
        }
    }

    // MARK: - Startup diagnostic (FlClash TunnelStartupDiagnostic)
    //
    // The app reads vpn-startup.json to show WHY a start failed
    // instead of silence: without it an extension-side failure only
    // surfaces as a status flip to .disconnected, which the app
    // cannot distinguish from a user stop. Stages mirror FlClash's
    // (extension-entered → configuration → core-setup → tun-start →
    // network-settings → running / startup-failed). Freshness (< 180 s)
    // is enforced on the reader side (TunnelManager).

    private var startupID = UUID().uuidString
    /// When this run's tunnel came up (for the diagnostics file).
    private var tunnelStartedAt: Date?

    /// VPN evidence for the app's Diagnostics page (FlClash
    /// diagnostics shows peak memory / last sample / last stage /
    /// startup record from the tunnel diagnostics file; ours had
    /// none). Written at "running", refreshed on the watchdog tick
    /// (30 s) and at "stopped": stage, pid, start time, packet
    /// counters and the last core-message time, so a crash loop is
    /// diagnosable after the fact instead of invisible.
    private func writeVPNDiagnostics(stage: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let record: [String: Any] = [
            "stage": stage,
            "startupId": startupID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "startedAt": tunnelStartedAt.map { Int64($0.timeIntervalSince1970 * 1000) } as Any,
            "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            "packetsIn": packetsIn,
            "packetsOut": packetsOut,
            "packetsDroppedFull": packetsDroppedFull,
            "lastCoreMessageAt": lastCoreMessageAt.map { Int64($0.timeIntervalSince1970 * 1000) } as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: container.appendingPathComponent("vpn-diagnostics.json"), options: .atomic)
    }

    private func recordStartup(_ stage: String, error: Error? = nil) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let detail = error.map { e -> String in
            let ns = e as NSError
            return String("\(ns.localizedDescription) [\(ns.domain):\(ns.code)]".prefix(2048))
        }
        let record = StartupDiagnosticRecord(id: startupID, stage: stage, detail: detail, date: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: container.appendingPathComponent("vpn-startup.json"), options: .atomic)
    }

    // MARK: - C callbacks (non-capturing; the provider is passed as context)

    private static let deliverCallback: ConcordIOSDeliver = { context, data, len in
        guard let context, let data, len > 0 else { return false }
        let provider = Unmanaged<PacketTunnelProvider>.fromOpaque(context).takeUnretainedValue()
        // The bytes are valid only during this call: copy before returning.
        let message = Data(bytes: data, count: len)
        provider.coreQueue.async { provider.handleCoreMessage(message) }
        return true
    }

    private static let releaseCallback: ConcordIOSRelease = { context in
        guard let context else { return }
        // Balances the passRetained in startTunnel: the core no longer
        // holds the session, so the provider may deallocate.
        Unmanaged<PacketTunnelProvider>.fromOpaque(context).release()
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The extension retains itself for the core session's lifetime
        // (released by releaseCallback when the session ends).
        // Adopt the app's startupID when it passed one in
        // startVPNTunnel(options:) (FlClash TunnelStartupDiagnostic:
        // the diagnostic record is correlated by ID, not just by
        // freshness); mint one when it did not.
        if let id = options?["startupID"] as? String, !id.isEmpty {
            startupID = id
        } else {
            startupID = UUID().uuidString
        }
        // A reused extension process keeps the previous run's tables
        // in memory (FlClash clears its runtime at the top of
        // startTunnel): reset them so a stale proxy table or a dead
        // delay-run accumulator cannot leak into this run.
        resetRunState()
        recordStartup("extension-entered")
        let context = Unmanaged.passRetained(self).toOpaque()
        Task {
            do {
                try await self.bootCore(context: context)
                self.recordStartup("running")
                completionHandler(nil)
            } catch {
                // Boot failed: tear down whatever got started so a retry
                // starts clean, then report the failure to the system.
                // If a session was opened, closing it fires
                // releaseCallback, which balances the passRetained above;
                // only release here when no session was ever opened,
                // otherwise the retain would be released twice.
                let openedSession = self.session != 0
                self.coreQueue.async { self.tearDownCore() }
                if !openedSession {
                    Unmanaged<PacketTunnelProvider>.fromOpaque(context).release()
                }
                Self.log.error("startTunnel failed: \(error.localizedDescription, privacy: .public)")
                self.recordStartup("startup-failed", error: error)
                completionHandler(error)
            }
        }
    }

    /// Clears the per-run in-memory tables before a (re)start, so a
    /// reused extension process never serves the previous run's
    /// proxy table, connections, buffers or delay-run state.
    /// Called at the top of startTunnel (FlClash clears its runtime
    /// there too); tearDownCore already closes the channel/session.
    private func resetRunState() {
        proxyOrder = []
        proxyGroups = []
        proxyNodes = []
        connectionTable.removeAll()
        logBuffer.removeAll()
        dnsBuffer.removeAll()
        eventBuffer.removeAll()
        delayRun = nil
        lastCoreMessageAt = nil
        watchdogFailures = 0
        packetsIn = 0
        packetsOut = 0
        packetsDroppedFull = 0
        ringFullStreak = 0
        // Config B1: a new run gets a fresh runner and a fresh
        // fingerprint baseline; a previous run's restart-needed flag
        // must not survive into it.
        channelTunFingerprint = nil
        clearTunRestartNeeded()
    }

    private func bootCore(context: UnsafeMutableRawPointer) async throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw TunnelSetupError.noAppGroup
        }
        let configURL = container.appendingPathComponent(configFileName)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw TunnelSetupError.noConfig
        }
        recordStartup("configuration")

        // Pre-seed the geo databases (GeoSeed) before config.apply:
        // config.apply compiles the profile's GEOIP,CN,DIRECT rule,
        // and a missing geoip.metadb makes the core download it over
        // its own TLS client (rustls) — which rejects the campus
        // network's MITM certificate ("can't download MMDB: ...
        // UnknownIssuer", v0.2.33 in the in-app core). The extension
        // core runs the SAME config.apply against the SAME rule, so
        // it hits the same download and the same failure whenever
        // the file is missing — here it fails startTunnel outright
        // (no compiled route program, no tunnel), so this is one of
        // the VPN-won't-start causes, not the v0.2.31 "tunnel up but
        // traffic goes direct" report (there the tunnel showed as
        // running, so config.apply must have succeeded that time).
        // URLSession uses the iOS system trust store, so the same
        // file downloads here where the core's cannot, and a present
        // file makes the core skip its download entirely. Best-effort
        // and bounded (30 s per file): if files are still missing,
        // config.apply below fails with the core's own error,
        // recorded in the startup diagnostic as before. The app seeds
        // this same container from AppCore.ensureStarted too, so a
        // user who delay-tests first never pays the download at VPN
        // start. No TLS verification is disabled anywhere.
        let seed = await GeoSeed.ensureGeoFiles(in: container, perFileTimeout: 30)
        Self.log.info("geo seed: seeded \(seed.seeded.joined(separator: ","), privacy: .public), present \(seed.alreadyPresent.joined(separator: ","), privacy: .public), failed \(seed.failures.map(\.file).joined(separator: ","), privacy: .public)")

        guard concord_ios_start() == 0 else {
            throw TunnelSetupError.coreStartFailed
        }
        let sessionID = concord_ios_open_session(
            Self.deliverCallback, context, Self.releaseCallback)
        guard sessionID != 0 else {
            throw TunnelSetupError.sessionFailed
        }
        session = sessionID
        Self.log.info("core session opened: \(sessionID)")

        // core.hello (protocol 1 = concord-proto PROTOCOL_VERSION).
        _ = try await sendCoreRequest(method: "core.hello", params: [
            "protocol": ["min": 1, "max": 1],
            "client": ["name": "concord-ios", "version": "0.2.0"],
        ], timeoutSeconds: 60)
        _ = try await sendCoreRequest(method: "core.init", params: [
            "home": container.path,
        ], timeoutSeconds: 60)

        // config.apply: the profile path is absolute (home is the App
        // Group container); the MITM + DNS overlays come from mitm.json
        // / dns.json when the user configured them in the app (see
        // header comment).
        var applyParams: [String: Any] = ["profile": ["path": configURL.path]]
        // The same overlay the live re-apply path merges (see
        // buildApplyOverlay): startup and live applies must see
        // identical fragments, or the B1 fingerprint below would
        // report a change on the first live apply when nothing moved.
        let overlay = buildApplyOverlay()
        if !overlay.isEmpty {
            applyParams["overlay"] = overlay
        }
        // MITM capture: the core's engine.set_capture reads the
        // `mitmCapture` wire key from config.apply's `options`
        // (upstream crates/proto/src/types/config.rs Options, camelCase
        // via the dto! macro; api.json $defs/Options). The Settings
        // capture switch only writes mitm.json's "capture" flag, so
        // the flag has to travel here — otherwise capture is never on.
        if let mitmJSON = readSharedJSON(name: mitmFileName),
           let capture = mitmJSON["capture"] as? Bool {
            applyParams["options"] = ["mitmCapture": capture]
        }
        _ = try await sendCoreRequest(method: "config.apply", params: applyParams, timeoutSeconds: 60)
        _ = try await sendCoreRequest(method: "engine.start", params: [:], timeoutSeconds: 60)
        recordStartup("core-configured")

        // General settings saved in the app (general.json) are patched
        // in once at startup, so they take effect on the next VPN start
        // without the user tapping "apply". A failure here must not fail
        // the tunnel: the settings can still be applied live later.
        // Kept for the B1 fingerprint below: the patch's ipv6 is part
        // of the core's (tun, tun_inet4, ipv6) triple.
        var startupPatchParams: [String: Any]?
        if let general = readSharedJSON(name: generalSettingsFileName), !general.isEmpty {
            do {
                // General overrides for the keys that also travel via
                // config.patch (ipv6, unified-delay, tcp-concurrent):
                // fold them into this patch, or it would clobber the
                // overlay values applied above.
                var patch = general
                if let overrides = effectiveTopLevelOverrides(section: "general") {
                    for (key, snake) in ["ipv6": "ipv6", "unified-delay": "unified_delay", "tcp-concurrent": "tcp_concurrent"] {
                        if let value = overrides[key] {
                            patch[snake] = value
                        }
                    }
                }
                _ = try await sendCoreRequest(method: "config.patch", params: patch, timeoutSeconds: 60)
                // Only record the patch in the B1 fingerprint once
                // it actually applied: if it failed, a later live
                // patch of the same values is a real change and must
                // re-start the runner instead of being missed.
                startupPatchParams = patch
            } catch {
                Self.log.error("startup config.patch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Option B packet channel (NOT the socketpair / inherited fd).
        // TUN must be enabled first: on iOS it is the only data plane,
        // and a disabled TUN fails the tunnel before any channel exists.
        let tun = readTunnelSettings(container: container)
        guard tun.enabled else {
            throw TunnelSetupError.tunDisabled
        }
        let handle = concord_ios_packet_channel_open()
        guard handle != 0 else {
            throw TunnelSetupError.channelFailed
        }
        channelHandle = handle

        let tunParams = tunStartParams(handle: handle, tun: tun)
        recordStartup("tun-start")
        _ = try await sendCoreRequest(method: "tun.start", params: tunParams, timeoutSeconds: 60)
        // Config B1: the runner this tun.start created is the
        // baseline — a later live apply/patch that moves the triple
        // kills it, and the fingerprint tells the re-start check
        // what "unchanged" looks like.
        channelTunFingerprint = tunTripleFingerprint(overlay: overlay, patchParams: startupPatchParams)
        clearTunRestartNeeded()
        // Tunnel interface: the system owns routing; the core must not
        // install routes (upstream: Os::Other -> NullBackend on iOS).
        // IPv6 is configured from tunnel.json when the user enabled it
        // in Settings: the same address the core got in tun.start, plus
        // the IPv6 default route, so IPv6 traffic enters the tunnel
        // instead of bypassing it.
        // tunnelRemoteAddress / IPv4 mask match FlClash
        // (PacketTunnelNetworkConfiguration): the remote address is a
        // dummy 127.0.0.1 and the interface is a /30 (198.18.0.1,
        // with 198.18.0.2 as the DNS address inside the same /30).
        // Our previous values (remote = the interface address itself,
        // mask /16) are not known to fail a start, but there is no
        // reason to differ from upstream here.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: tun.mtu)
        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // E6: Loopback 10.7.0.1 switch — adds 10.7.0.2 + a 10.7.0.1/32
        // route when on (no-op when off). Needs a VPN restart.
        LoopbackNetworkSettings.apply(to: ipv4, enabled: tun.loopbackDevice)
        // Local network settings (FlClash: 本地网络设置）: excluded
        // routes bypass the tunnel — the standard private ranges when
        // bypass-private-route is on, plus the user's list.
        var excludedV4: [NEIPv4Route] = []
        var excludedV6: [NEIPv6Route] = []
        var excludeCIDRs = tun.routeExcludeAddress
        if tun.bypassPrivateRoute {
            excludeCIDRs += ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
        }
        for cidr in excludeCIDRs {
            let route = excludedRoute(from: cidr)
            if let v4 = route.v4 { excludedV4.append(v4) }
            if let v6 = route.v6 { excludedV6.append(v6) }
        }
        if !excludedV4.isEmpty { ipv4.excludedRoutes = excludedV4 }
        settings.ipv4Settings = ipv4
        if tun.ipv6 {
            let parts = tun.ipv6Address.split(separator: "/")
            if parts.count == 2, let prefixLength = Int(parts[1]) {
                let ipv6 = NEIPv6Settings(
                    addresses: [String(parts[0])],
                    networkPrefixLengths: [NSNumber(value: prefixLength)])
                ipv6.includedRoutes = [NEIPv6Route.default()]
                if !excludedV6.isEmpty { ipv6.excludedRoutes = excludedV6 }
                settings.ipv6Settings = ipv6
            }
        }
        // DNS hijacking off (FlClash: DNS 劫持）: leave the system DNS
        // alone — the tunnel sets no DNS servers.
        if tun.dnsHijack {
            settings.dnsSettings = NEDNSSettings(servers: tun.dns)
        }
        recordStartup("network-settings")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        // Kept for the path monitor (Batch F): a network change
        // re-asserts these exact settings.
        lastAppliedNetworkSettings = settings

        try await subscribeToStreams()
        startPump()
        startStabilityGuards()
        tunnelStartedAt = Date()
        writeVPNDiagnostics(stage: "running")
        Self.log.info("tunnel up: channel \(handle), stack \(tun.stack, privacy: .public), mtu \(tun.mtu)")
        // The core (and its TUN) is up, so the SSID watcher can switch
        // the mode to direct on a direct SSID and restore it on
        // leaving, without the main app running (fork
        // PacketTunnelProvider.startTunnel).
        ssidDirectController.start()
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isStopping = true
        recordStartup("stopped")
        writeVPNDiagnostics(stage: "stopped")
        // Interface B8 (stop-part): drop the stale snapshots now,
        // while the files still belong to this run — the app must
        // never read last-round logs / DNS / route / engine data as
        // if it were current after the tunnel stops.
        deleteStaleSnapshots()
        pumpRunning = false
        drainTimer?.cancel()
        drainTimer = nil
        // Long-run stability guards (Batch F): stop them here; the
        // watchdog must not fire while the tunnel is tearing down.
        watchdogTimer?.cancel()
        watchdogTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathReapplyWorkItem?.cancel()
        pathReapplyWorkItem = nil
        // The SSID watcher stops with the tunnel: its stop() clears
        // the override state (restoreMode = nil), so the app never
        // sees a stale "direct override active" flag from this run.
        ssidDirectController.stop()
        coreQueue.async {
            // Best effort: ask the core to stop the tunnel and engine,
            // then give it a moment before closing the session. The
            // extension process exits after this returns anyway.
            if self.session != 0 {
                self.sendCoreNotification(method: "tun.stop", params: [:])
                self.sendCoreNotification(method: "engine.stop", params: [:])
            }
            Self.log.info(
                "tunnel stopping (reason \(reason.rawValue)): in \(self.packetsIn) out \(self.packetsOut) dropped-full \(self.packetsDroppedFull)")
            self.coreQueue.asyncAfter(deadline: .now() + 0.2) {
                self.tearDownCore()
                completionHandler()
            }
        }
    }

    /// Must be called on coreQueue (all callers dispatch there):
    /// `pending` / `subscriptions` are only touched on that queue.
    private func tearDownCore() {
        if channelHandle != 0 {
            concord_ios_packet_channel_close(channelHandle)
            channelHandle = 0
        }
        if session != 0 {
            concord_ios_close_session(session)
            session = 0
        }
        for (_, request) in pending {
            request.continuation.resume(throwing: TunnelSetupError.rpcFailed("核心会话已关闭"))
        }
        pending.removeAll()
        subscriptions.removeAll()
        delayRun = nil
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }

    // MARK: - App -> extension commands (sendProviderMessage)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard session != 0 else {
            completionHandler?(errorEnvelope(id: nil, message: "核心未运行：请先启动 VPN"))
            return
        }
        guard var request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              request["method"] as? String != nil,
              let appID = (request["id"] as? NSNumber)?.intValue else {
            // Not a JSON-RPC request: nothing to forward.
            completionHandler?(nil)
            return
        }
        // config.apply with no overlay gets the MITM + DNS overlays
        // merged in from the shared mitm.json / module-mitm.json /
        // dns.json (see header comment). A request that already
        // carries an overlay is forwarded untouched.
        if (request["method"] as? String) == "config.apply" && request["overlay"] == nil {
            let overlay = buildApplyOverlay()
            if !overlay.isEmpty {
                request["overlay"] = overlay
            }
        }
        // Live re-apply: the app's config.apply params carry options
        // with mitmCapture always false (ConcordConfigOptions default;
        // nothing in the app sets it). Merge the mitm.json capture flag
        // in so a live re-apply honours the capture switch too, keeping
        // any other option keys the app sent.
        if (request["method"] as? String) == "config.apply" {
            var options = (request["options"] as? [String: Any]) ?? [:]
            if let mitmJSON = readSharedJSON(name: mitmFileName),
               let capture = mitmJSON["capture"] as? Bool {
                options["mitmCapture"] = capture
            }
            request["options"] = options
        }
        // delay.run is a stream, not a plain request: forward it, then
        // register the accumulator on the sub it returns so its Result /
        // Done events land in snapshots/delay.json for the app to poll
        // (see handleStreamEvent). The app gets the normal subscribe
        // reply back.
        if (request["method"] as? String) == "delay.run" {
            Task {
                do {
                    let response = try await self.forwardAppRequest(request, appID: appID)
                    if let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                       let result = object["result"] as? [String: Any],
                       let sub = (result["sub"] as? NSNumber)?.intValue {
                        self.coreQueue.async {
                            // A new run supersedes any previous one; the
                            // old stream's late events no longer match
                            // the accumulator's sub and are ignored.
                            self.delayRun = DelayRunAccumulator(sub: sub)
                            self.writeDelaySnapshot()
                        }
                    }
                    completionHandler?(response)
                } catch {
                    completionHandler?(self.errorEnvelope(id: appID, message: error.localizedDescription))
                }
            }
            return
        }
        Task {
            do {
                let response = try await self.forwardAppRequest(request, appID: appID)
                // Config B1: a live config.apply / config.patch that
                // moved the core's (tun, tun_inet4, ipv6) triple
                // killed the channel TUN runner in reconcile_tun —
                // re-start it before answering, so the app's "已应用"
                // is not a lie about a dead data plane. A failed
                // re-start is reported via tun-restart-needed.json,
                // not by failing the apply (the apply itself
                // succeeded).
                if let method = request["method"] as? String,
                   method == "config.apply" || method == "config.patch" {
                    await self.maybeRestartChannelTun(after: request)
                }
                completionHandler?(response)
            } catch {
                completionHandler?(self.errorEnvelope(id: appID, message: error.localizedDescription))
            }
        }
    }

    /// Forwards one app JSON-RPC request to the core session. The
    /// request id is rewritten to the extension's own id space (the app
    /// and the extension share one core session) and restored in the
    /// reply by handleCoreMessage.
    private func forwardAppRequest(_ request: [String: Any], appID: Int) async throws -> Data {
        try await sendRawJSONRPC(request, appID: appID)
    }

    private func errorEnvelope(id: Int?, message: String) -> Data {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": -32001, "message": message],
        ]
        envelope["id"] = id.map { NSNumber(value: $0) } ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    // MARK: - JSON-RPC over the FFI session

    /// Sends one JSON-RPC request object and awaits its response bytes
    /// (with the app's original id restored when `appID` is set).
    private func sendRawJSONRPC(_ request: [String: Any], appID: Int? = nil, timeoutSeconds: TimeInterval = 15) async throws -> Data {
        let extID = locked { () -> Int in
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        var object = request
        object["jsonrpc"] = "2.0"
        object["id"] = extID
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await withCheckedThrowingContinuation { continuation in
            coreQueue.async {
                guard self.session != 0 else {
                    continuation.resume(throwing: TunnelSetupError.rpcFailed("核心会话已关闭"))
                    return
                }
                self.pending[extID] = PendingRequest(appID: appID, continuation: continuation)
                let sent = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return Int32(0) }
                    return concord_ios_send(self.session, base.assumingMemoryBound(to: UInt8.self), data.count)
                }
                if sent == 0 {
                    self.pending.removeValue(forKey: extID)
                    continuation.resume(throwing: TunnelSetupError.rpcFailed("会话不存在"))
                    return
                }
                self.coreQueue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let request = self.pending.removeValue(forKey: extID) {
                        request.continuation.resume(
                            throwing: TunnelSetupError.rpcFailed("调用超时（\(Int(timeoutSeconds))s）"))
                    }
                }
            }
        }
    }

    /// Sends one request and returns its `result` value (throws on an
    /// error object). Used for the extension's own startup calls.
    /// The boot sequence uses a 60 s timeout (v0.2.32): a healthy
    /// but slow boot — config.apply loading GeoIP data, the core
    /// warming up — must not be aborted at 15 s and reported as a
    /// failure that feeds the On-Demand restart loop.
    private func sendCoreRequest(method: String, params: [String: Any], timeoutSeconds: TimeInterval = 15) async throws -> Any {
        let data = try await sendRawJSONRPC(["method": method, "params": params], timeoutSeconds: timeoutSeconds)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelSetupError.rpcFailed("核心返回了无法解析的响应（\(method)）")
        }
        if let error = object["error"] as? [String: Any] {
            throw TunnelSetupError.rpcFailed(
                (error["message"] as? String) ?? "未知错误（\(method)）")
        }
        return object["result"] ?? NSNull()
    }

    /// Sends a JSON-RPC notification (no id, no reply expected), e.g.
    /// `$/credit`. Fire-and-forget.
    private func sendCoreNotification(method: String, params: [String: Any]) {
        guard session != 0 else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method, "params": params,
        ]) else { return }
        _ = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Int32(0) }
            return concord_ios_send(session, base.assumingMemoryBound(to: UInt8.self), data.count)
        }
    }

    /// Runs on coreQueue. Routes replies to the pending request and
    /// `$/event` notifications to the stream handlers.
    private func handleCoreMessage(_ data: Data) {
        // Watchdog heartbeat (Batch F): every reply and every stream
        // event passes through here; traffic.watch alone ticks once
        // a second while the core is alive.
        lastCoreMessageAt = Date()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.error("dropping unparsable core message (\(data.count) bytes)")
            return
        }
        if (object["method"] as? String) == "$/event" {
            handleStreamEvent(params: object["params"] as? [String: Any])
            return
        }
        guard let extID = (object["id"] as? NSNumber)?.intValue,
              let request = pending.removeValue(forKey: extID) else {
            return
        }
        var response = object
        if let appID = request.appID {
            response["id"] = appID
        }
        let out = (try? JSONSerialization.data(withJSONObject: response)) ?? data
        request.continuation.resume(returning: out)
    }

    // MARK: - Streams -> snapshot files

    private func subscribeToStreams() async throws {
        // traffic.watch snapshot is a Traffic value; connection.watch
        // snapshot is a ConnectionSnapshot; log/dns.watch have NO
        // snapshot (Subscription::new(None, ...)) — their entries only
        // arrive as events, so the extension accumulates them.
        let traffic = try await sendCoreRequest(method: "traffic.watch", params: [
            "interval_ms": 1000, "credit": 8,
        ], timeoutSeconds: 60)
        registerStream(result: traffic, kind: .traffic)
        let connection = try await sendCoreRequest(method: "connection.watch", params: [
            "counters": true, "credit": 8,
        ], timeoutSeconds: 60)
        registerStream(result: connection, kind: .connection)
        let log = try await sendCoreRequest(method: "log.watch", params: ["credit": 8], timeoutSeconds: 60)
        registerStream(result: log, kind: .log)
        let dns = try await sendCoreRequest(method: "dns.watch", params: ["credit": 8], timeoutSeconds: 60)
        registerStream(result: dns, kind: .dns)
        // proxy.watch snapshot is the current ProxyGroups; its events
        // are ProxyDelta {order?, groups, nodes, removed}.
        let proxy = try await sendCoreRequest(method: "proxy.watch", params: ["credit": 8], timeoutSeconds: 60)
        registerStream(result: proxy, kind: .proxy)
        // route.watch snapshot is the current RouteStamp; its events
        // are RouteStamp values (latest policy).
        let route = try await sendCoreRequest(method: "route.watch", params: ["credit": 8], timeoutSeconds: 60)
        registerStream(result: route, kind: .route)
        // events.watch has NO snapshot — its CoreEvent items only
        // arrive as events, so the extension accumulates them like
        // log/dns.watch. delays + state are requested explicitly:
        // both default false in the 165154c schema
        // (EventsWatchParams), so a bare {credit: 8} never delivers
        // `delay` or `stateChanged` events at all.
        let events = try await sendCoreRequest(method: "events.watch", params: [
            "delays": true, "state": true, "credit": 8,
        ], timeoutSeconds: 60)
        registerStream(result: events, kind: .events)
        // engine.state snapshot is the current EngineStatus; its
        // events are EngineStatus values (latest policy).
        let engine = try await sendCoreRequest(method: "engine.state", params: ["credit": 8], timeoutSeconds: 60)
        registerStream(result: engine, kind: .engine)
    }

    private func registerStream(result: Any, kind: StreamKind) {
        // Hop onto coreQueue: `subscriptions` and the snapshot tables
        // are only touched there, and a $/event for this sub can already
        // be in flight on that queue.
        coreQueue.async {
            guard let result = result as? [String: Any],
                  let sub = (result["sub"] as? NSNumber)?.intValue else {
                Self.log.error("subscribe \(kind.rawValue, privacy: .public) returned no sub id")
                return
            }
            self.subscriptions[sub] = kind
            if let snapshot = result["snapshot"] {
                self.applyStreamSnapshot(kind: kind, snapshot: snapshot)
            }
            Self.log.info("subscribed \(kind.rawValue, privacy: .public) (sub \(sub))")
        }
    }

    private func resubscribe(_ kind: StreamKind) {
        // A resync means events were dropped and the local table is
        // stale; a fresh subscribe returns a new snapshot to replace it.
        Task {
            // V8: the API has no unsubscribe, so drop the old sub's
            // entries first — otherwise its late deltas keep
            // applying to the replaced table after the new snapshot
            // lands (closed connections resurrecting, counters
            // double-counted). Enqueued on coreQueue ahead of the
            // new registerStream, so the order is deterministic.
            self.coreQueue.async { self.subscriptions = self.subscriptions.filter { $0.value != kind } }
            do {
                let params: [String: Any]
                switch kind {
                case .traffic: params = ["interval_ms": 1000, "credit": 8]
                case .connection: params = ["counters": true, "credit": 8]
                case .log: params = ["credit": 8]
                case .dns: params = ["credit": 8]
                case .proxy: params = ["credit": 8]
                case .route: params = ["credit": 8]
                // Like the startup subscribe: delays + state, or the
                // re-subscribed stream goes silent on delay /
                // stateChanged events again (interface B12).
                case .events: params = ["delays": true, "state": true, "credit": 8]
                case .engine: params = ["credit": 8]
                }
                let result = try await self.sendCoreRequest(method: kind.methodName, params: params, timeoutSeconds: 60)
                self.coreQueue.async { self.registerStream(result: result, kind: kind) }
            } catch {
                Self.log.error("resubscribe \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleStreamEvent(params: [String: Any]?) {
        guard let params,
              let sub = (params["sub"] as? NSNumber)?.intValue else {
            return
        }
        // delay.run events arrive on their own sub, separate from the
        // five startup subscriptions (see handleAppMessage).
        if delayRun?.sub == sub {
            guard let items = params["data"] as? [Any] else { return }
            handleDelayRunEvent(items: items, sub: sub)
            return
        }
        guard let kind = subscriptions[sub] else {
            return
        }
        if params["resync"] as? Bool == true {
            Self.log.info("stream \(kind.rawValue, privacy: .public) resync; re-subscribing")
            resubscribe(kind)
            return
        }
        guard let items = params["data"] as? [Any] else { return }
        switch kind {
        case .traffic:
            // Each event is a full Traffic value; keep the newest.
            if let last = items.last {
                writeSnapshot(name: "traffic", data: last)
            }
        case .connection:
            // Each event is a ConnectionDelta {opened, closed, counters}.
            for item in items {
                guard let delta = item as? [String: Any] else { continue }
                applyConnectionDelta(delta)
            }
            let connections = connectionTable.values.sorted {
                (($0["start"] as? NSNumber)?.int64Value ?? 0) > (($1["start"] as? NSNumber)?.int64Value ?? 0)
            }
            writeSnapshot(name: "connections", data: ["connections": connections])
        case .log:
            for item in items {
                guard let entry = item as? [String: Any] else { continue }
                logBuffer.append(entry)
            }
            trimBuffer(&logBuffer)
            writeSnapshot(name: "logs", data: ["entries": logBuffer])
        case .dns:
            for item in items {
                guard let entry = item as? [String: Any] else { continue }
                dnsBuffer.append(entry)
            }
            trimBuffer(&dnsBuffer)
            writeSnapshot(name: "dns", data: ["entries": dnsBuffer])
        case .proxy:
            // Each event is a ProxyDelta {order?, groups, nodes, removed}.
            for item in items {
                guard let delta = item as? [String: Any] else { continue }
                applyProxyDelta(delta)
            }
            writeProxySnapshot()
        case .route:
            // Each event is a full RouteStamp; keep the newest.
            if let last = items.last {
                writeSnapshot(name: "route", data: last)
            }
        case .events:
            for item in items {
                guard let entry = item as? [String: Any] else { continue }
                eventBuffer.append(entry)
            }
            trimBuffer(&eventBuffer)
            writeSnapshot(name: "events", data: ["entries": eventBuffer])
        case .engine:
            // Each event is a full EngineStatus; keep the newest.
            if let last = items.last {
                writeSnapshot(name: "engine", data: last)
            }
        }
        // Refill one unit of credit per batch consumed; without this
        // the server pump stops after the initial credit.
        sendCoreNotification(method: "$/credit", params: ["sub": sub, "n": 1])
    }

    private func handleDelayRunEvent(items: [Any], sub: Int) {
        // Runs on coreQueue. Events are {type: "result", name, url,
        // value} and a final {type: "done"}; dropping the stream aborts
        // the remaining tests, so the app simply stops polling.
        guard var run = delayRun, run.sub == sub else { return }
        for item in items {
            guard let event = item as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "result":
                run.results.append(event)
            case "done":
                run.done = true
            default:
                break
            }
        }
        delayRun = run
        writeDelaySnapshot()
        // Refill one unit of credit per batch consumed, like the other
        // streams; without this the server pump stops after the
        // initial credit.
        sendCoreNotification(method: "$/credit", params: ["sub": sub, "n": 1])
    }

    private func writeDelaySnapshot() {
        guard let run = delayRun else { return }
        writeSnapshot(name: "delay", data: [
            "runId": run.sub,
            "done": run.done,
            "results": run.results,
        ])
    }

    private func applyProxyDelta(_ delta: [String: Any]) {
        // Whole changed groups / nodes replace the entry of the same
        // name (appended when new); removed names drop out of the
        // tables and the order list.
        if let order = delta["order"] as? [String] {
            proxyOrder = order
        }
        if let groups = delta["groups"] as? [[String: Any]] {
            for group in groups {
                upsertNamed(&proxyGroups, entry: group)
            }
        }
        if let nodes = delta["nodes"] as? [[String: Any]] {
            for node in nodes {
                upsertNamed(&proxyNodes, entry: node)
            }
        }
        if let removed = delta["removed"] as? [String] {
            for name in removed {
                proxyGroups.removeAll { ($0["name"] as? String) == name }
                proxyNodes.removeAll { ($0["name"] as? String) == name }
                proxyOrder.removeAll { $0 == name }
            }
        }
    }

    private func upsertNamed(_ table: inout [[String: Any]], entry: [String: Any]) {
        guard let name = entry["name"] as? String else { return }
        if let index = table.firstIndex(where: { ($0["name"] as? String) == name }) {
            table[index] = entry
        } else {
            table.append(entry)
        }
    }

    private func writeProxySnapshot() {
        writeSnapshot(name: "proxies", data: [
            "order": proxyOrder,
            "groups": proxyGroups,
            "nodes": proxyNodes,
        ])
    }

    private func applyStreamSnapshot(kind: StreamKind, snapshot: Any) {
        switch kind {
        case .traffic:
            writeSnapshot(name: "traffic", data: snapshot)
        case .connection:
            guard let snapshot = snapshot as? [String: Any],
                  let connections = snapshot["connections"] as? [[String: Any]] else { return }
            connectionTable.removeAll()
            for connection in connections {
                if let id = (connection["id"] as? NSNumber)?.uint64Value {
                    connectionTable[id] = connection
                }
            }
            writeSnapshot(name: "connections", data: ["connections": connections])
        case .log, .dns, .events:
            // log/dns/events.watch have no snapshot; nothing to apply.
            break
        case .proxy:
            guard let snapshot = snapshot as? [String: Any] else { return }
            proxyOrder = snapshot["order"] as? [String] ?? []
            proxyGroups = snapshot["groups"] as? [[String: Any]] ?? []
            proxyNodes = snapshot["nodes"] as? [[String: Any]] ?? []
            writeProxySnapshot()
        case .route:
            writeSnapshot(name: "route", data: snapshot)
        case .engine:
            writeSnapshot(name: "engine", data: snapshot)
        }
    }

    private func applyConnectionDelta(_ delta: [String: Any]) {
        if let opened = delta["opened"] as? [[String: Any]] {
            for connection in opened {
                if let id = (connection["id"] as? NSNumber)?.uint64Value {
                    connectionTable[id] = connection
                }
            }
        }
        if let closed = delta["closed"] as? [NSNumber] {
            for id in closed {
                connectionTable.removeValue(forKey: id.uint64Value)
            }
        }
        if let counters = delta["counters"] as? [[String: Any]] {
            for counter in counters {
                guard let id = (counter["id"] as? NSNumber)?.uint64Value,
                      var connection = connectionTable[id] else { continue }
                if let upload = counter["upload"] { connection["upload"] = upload }
                if let download = counter["download"] { connection["download"] = download }
                connectionTable[id] = connection
            }
        }
    }

    private func trimBuffer(_ buffer: inout [[String: Any]]) {
        if buffer.count > maxBufferedEntries {
            buffer.removeFirst(buffer.count - maxBufferedEntries)
        }
    }

    private func writeSnapshot(name: String, data: Any) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let directory = container.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).json")
        let envelope: [String: Any] = [
            "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            "data": data,
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? bytes.write(to: file, options: .atomic)
    }

    // MARK: - Packet pump (Option B channel)

    private func startPump() {
        pumpRunning = true
        readNextPackets()
        let timer = DispatchSource.makeTimerSource(queue: coreQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.pumpRunning else { return }
            self.drainOutbound()
        }
        timer.resume()
        drainTimer = timer
    }

    private func readNextPackets() {
        guard pumpRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.pumpRunning else { return }
            self.handleInbound(packets)
            self.drainOutbound()
            if self.ringFullStreak > 8 {
                // Ring stayed full: pause reads briefly instead of
                // busy-looping on a channel the core is not draining.
                self.ringFullStreak = 0
                self.coreQueue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    self.readNextPackets()
                }
            } else {
                self.readNextPackets()
            }
        }
    }

    private func handleInbound(_ packets: [Data]) {
        guard channelHandle != 0 else { return }
        for packet in packets where !packet.isEmpty {
            packetsIn += 1
            let result = packet.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return Int32(-1) }
                return concord_ios_packet_write(
                    channelHandle, base.assumingMemoryBound(to: UInt8.self), packet.count)
            }
            switch result {
            case 1:
                ringFullStreak = 0
            case 0:
                // Ring full: drop this packet (counted) and keep going;
                // readNextPackets pauses if the streak grows.
                packetsDroppedFull += 1
                ringFullStreak += 1
                if ringFullStreak == 10 {
                    Self.log.error("packet channel ring full; dropping packets")
                }
            default:
                Self.log.error("packet channel write failed (\(result))")
                ringFullStreak = 0
            }
        }
    }

    private func drainOutbound() {
        guard channelHandle != 0 else { return }
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        packets.reserveCapacity(32)
        for _ in 0..<64 {
            let count = readBuffer.withUnsafeMutableBufferPointer { buffer in
                concord_ios_packet_read(channelHandle, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { break }
            let bytes = Data(readBuffer.prefix(Int(count)))
            packets.append(bytes)
            // writePackets wants the address family per packet; read it
            // off the IP version nibble (4 -> AF_INET, 6 -> AF_INET6).
            let family = (readBuffer[0] >> 4) == 6 ? AF_INET6 : AF_INET
            protocols.append(NSNumber(value: family))
        }
        guard !packets.isEmpty else { return }
        packetsOut += UInt64(packets.count)
        packetFlow.writePackets(packets, withProtocols: protocols)
    }

    // MARK: - Long-run stability (Batch F)

    /// Starts the watchdog, memory-pressure watch and path monitor.
    /// Called once, after the tunnel is fully up (startPump).
    private func startStabilityGuards() {
        startWatchdog()
        startMemoryPressureWatch()
        startPathMonitor()
    }

    /// Health watchdog: every 30s, checks whether any core message
    /// has arrived recently. A tick only counts a failure after 75s
    /// of total core silence, and two consecutive failures are needed
    /// before the tunnel is cancelled — conservative on purpose, so a
    /// scheduling stall cannot cause a reconnect loop. Cancelling
    /// lets the system restart the tunnel when On-Demand is enabled
    /// (the default); with On-Demand off, the tunnel stays down and
    /// the app shows the unexpected-disconnect banner instead.
    private func startWatchdog() {
        lastCoreMessageAt = Date()
        watchdogFailures = 0
        let timer = DispatchSource.makeTimerSource(queue: coreQueue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.session != 0, !self.isStopping, self.pumpRunning else { return }
            guard let last = self.lastCoreMessageAt else { return }
            let silent = Date().timeIntervalSince(last)
            // Refresh the diagnostics file on every tick so the
            // packet counters stay current for the app's
            // Diagnostics page even when the tunnel is healthy.
            self.writeVPNDiagnostics(stage: "running")
            if silent > 75 {
                self.watchdogFailures += 1
                Self.log.error("watchdog: no core message for \(Int(silent))s (failure \(self.watchdogFailures)/2)")
                if self.watchdogFailures >= 2 {
                    self.watchdogTimer?.cancel()
                    self.watchdogTimer = nil
                    Self.log.error("watchdog: core unresponsive, cancelling tunnel so On-Demand restarts it")
                    self.cancelTunnelWithError(TunnelSetupError.rpcFailed("核心无响应（看门狗：75 秒以上无核心消息，连续两次）"))
                }
            } else {
                self.watchdogFailures = 0
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// Memory-pressure shedding: on warning/critical, ask the core to
    /// release its caches (core.releaseMemory: resets outbound
    /// sessions and returns free pages to the OS) and drop this
    /// process's append-only buffers (log/dns/events; they refill
    /// from the next stream events). The MITM capture buffer itself
    /// is core-side and bounded by limits.capture-entries (default
    /// 64), so it is small; there is no separate "clear capture" RPC.
    private func startMemoryPressureWatch() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: coreQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            Self.log.error("memory pressure event (data \(source.data)); releasing core memory and dropping log/dns/event buffers")
            self.logBuffer.removeAll()
            self.dnsBuffer.removeAll()
            self.eventBuffer.removeAll()
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.sendCoreRequest(method: "core.releaseMemory", params: [:])
                    Self.log.info("core.releaseMemory done after memory pressure")
                } catch {
                    Self.log.error("core.releaseMemory failed after memory pressure: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Watches the underlying network (Wi-Fi <-> cellular) and
    /// re-asserts the tunnel network settings when it changes, so
    /// routing stays correct after a handover. The signature is the
    /// path status + interface names + interface types in use; the
    /// tunnel interface (utun) appears in the list too, but
    /// re-applying identical settings does not change the signature,
    /// so this cannot loop. The 1s debounce coalesces bursts
    /// (interface up/down, IP change); the first callback only sets
    /// the baseline.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.concord.ios.pathmonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = [
                String(describing: path.status),
                path.availableInterfaces.map(\.name).sorted().joined(separator: ","),
                "wifi:\(path.usesInterfaceType(.wifi))",
                "cell:\(path.usesInterfaceType(.cellular))",
                "wired:\(path.usesInterfaceType(.wiredEthernet))",
            ].joined(separator: "|")
            guard let last = self.lastPathSignature else {
                self.lastPathSignature = signature
                return
            }
            guard signature != last else { return }
            self.lastPathSignature = signature
            self.scheduleNetworkSettingsReapply()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func scheduleNetworkSettingsReapply() {
        pathReapplyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reapplyNetworkSettings()
        }
        pathReapplyWorkItem = item
        coreQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func reapplyNetworkSettings() {
        guard session != 0, !isStopping, pumpRunning,
              let settings = lastAppliedNetworkSettings else { return }
        Self.log.info("network path changed; re-applying tunnel network settings")
        setTunnelNetworkSettings(settings) { error in
            if let error {
                Self.log.error("re-apply tunnel network settings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Config B1: re-start the channel TUN runner after a live apply/patch
    //
    // Verified against the pinned core (165154c):
    //   * crates/engine/src/engine/tun.rs reconcile_tun(): after every
    //     config.apply (setup_as) and config.patch (update_as ->
    //     reconcile_listeners -> reconcile_tun), the core compares the
    //     desired triple (applied.tun, applied.tun_inet4, applied.
    //     general.ipv6) with the held tun_config. Any difference
    //     closes the TUN runner first; then, when applied.tun.enable
    //     is false it returns with NO runner, and when true it tries
    //     DeviceSource::Create — which cannot succeed on iOS
    //     (tun-rs has no DeviceBuilder there). Either way the
    //     packet-channel runner this extension started is dead, and
    //     nothing restarts it: the VPN still shows connected while
    //     traffic goes direct. tun_inet4 comes from the DNS
    //     fake-ip-range (crates/engine/src/tun.rs inet4_of), so a
    //     fake-ip-range change kills it too.
    //   * The channel device half is consumed by the FIRST tun.start
    //     (crates/api/src/channels.rs take_device() returns None
    //     afterwards), so a re-start MUST open a fresh channel —
    //     re-invoking tun.start with the old handle fails with
    //     not_found("handle"). start_channel_tun() closes the old
    //     runner, starts a new one on the fresh device, and — while
    //     the engine runs — resets resolver connections and the
    //     route table, i.e. it restores the data plane.
    // The fingerprint below tracks the triple as the extension can
    // see it (profile bytes + overlay/patch tun fragment + effective
    // fake-ip-range + ipv6 sources + tunnel.json values feeding
    // tun.start). It is deliberately conservative: any component
    // moving triggers a re-start attempt, because a missed kill
    // silently drops the data plane while a spurious re-start costs
    // only a sub-second blip. The whole-file profile hash is safe
    // here: the app rewrites config.yaml only on profile switch /
    // edit (ProfileStore.applyProfile), never on a plain re-apply.
    // LIMITS, stated honestly: (a) a profile that explicitly sets
    // `tun: {enable: false}` is indistinguishable from the default
    // (no tun section) without a YAML parser, so the runner is
    // restarted anyway — matching startup, which also starts the
    // channel runner regardless of the profile's tun.enable (only
    // tunnel.json's `enabled` gates it); (b) a live IPv6 flip is
    // only half-fixed — the runner is restarted with the new
    // addresses, but the NE interface's IPv6 settings are built at
    // startup, so IPv6 packets still cannot enter the tunnel until
    // the VPN itself restarts; IPv4 is restored immediately.

    /// The tun.start params for one channel handle, factored out of
    /// bootCore so a re-start builds exactly the same params from
    /// the current tunnel.json (FlClash: the tun address is
    /// 198.18.0.1/30; the core sorts each CIDR prefix into its
    /// inet4/inet6 address, crates/engine/src/tun.rs vpn_options).
    private func tunStartParams(handle: UInt64, tun: TunnelSettings) -> [String: Any] {
        var addresses = ["\(tunnelAddress)/30"]
        if tun.ipv6 {
            addresses.append(tun.ipv6Address)
        }
        var params: [String: Any] = [
            "source": ["kind": "channel", "handle": handle],
            "stack": tun.stack,
            "mtu": tun.mtu,
            "address": addresses,
            "dns": tun.dns,
        ]
        if let congestionController = tun.congestionController {
            params["congestionController"] = congestionController
        }
        return params
    }

    /// FNV-1a hex of a file's bytes — a cheap content hash for the
    /// profile component of the fingerprint (no CryptoKit import).
    private func fnv1aHex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Canonical (sorted-key) JSON of the tun-relevant inputs, as a
    /// comparable string. `overlay` is the config.apply overlay the
    /// extension merged (or the app's own); `patchParams` is the
    /// config.patch params. Components: the profile bytes (its tun:
    //  section and dns.fake-ip-range), the tun fragment, the
    // effective fake-ip-range (-> tun_inet4), every ipv6 source
    // (overlay key, patch key, general.json), and the tunnel.json
    // values that feed tun.start directly.
    private func tunTripleFingerprint(overlay: [String: Any]?, patchParams: [String: Any]?) -> String {
        var doc: [String: Any] = [:]
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID),
           let data = try? Data(contentsOf: container.appendingPathComponent(configFileName)) {
            doc["profile"] = fnv1aHex(data)
        } else {
            doc["profile"] = "missing"
        }
        if let tun = overlay?["tun"] {
            doc["tun"] = tun
        } else if let tun = patchParams?["tun"] {
            doc["tun"] = tun
        } else {
            doc["tun"] = NSNull()
        }
        doc["fakeIpRange"] = effectiveSection(file: dnsFileName, section: "dns")?["fake-ip-range"] ?? NSNull()
        var ipv6: [String: Any] = [:]
        if let value = overlay?["ipv6"] { ipv6["overlay"] = value }
        if let value = patchParams?["ipv6"] { ipv6["patch"] = value }
        if let general = readSharedJSON(name: generalSettingsFileName),
           let value = general["ipv6"] { ipv6["general"] = value }
        doc["ipv6"] = ipv6
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) {
            let tun = readTunnelSettings(container: container)
            doc["tunnel"] = [
                "enabled": tun.enabled,
                "stack": tun.stack,
                "mtu": tun.mtu,
                "ipv6": tun.ipv6,
                "ipv6Address": tun.ipv6Address,
                "dns": tun.dns,
                "congestionController": tun.congestionController ?? NSNull(),
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(doc)"
    }

    /// True when the new config intentionally disables TUN: the
    /// overlay / patch tun fragment says enable=false, or
    /// tunnel.json (the Settings switch, the same gate as the
    /// startup tunDisabled throw) says off. In that case the core
    /// means "no runner" and no re-start is attempted.
    private func tunDisabledIn(overlay: [String: Any]?, patchParams: [String: Any]?) -> Bool {
        if let tun = overlay?["tun"] as? [String: Any],
           (tun["enable"] as? Bool) == false { return true }
        if let tun = patchParams?["tun"] as? [String: Any],
           (tun["enable"] as? Bool) == false { return true }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID),
           !readTunnelSettings(container: container).enabled { return true }
        return false
    }

    /// After a forwarded config.apply / config.patch succeeded,
    /// re-start the channel TUN runner when the triple moved.
    /// No-op when nothing tun-relevant changed, when TUN is
    /// intentionally off, or when there is no runner to restore.
    /// A failed re-start never fails the apply (it succeeded) —
    /// it records the honest "需要重启 VPN" state instead.
    private func maybeRestartChannelTun(after request: [String: Any]) async {
        guard session != 0, channelHandle != 0, !isStopping else { return }
        let method = request["method"] as? String ?? ""
        let overlay = request["overlay"] as? [String: Any]
        let patchParams = method == "config.patch"
            ? (request["params"] as? [String: Any]) : nil
        let fingerprint = tunTripleFingerprint(overlay: overlay, patchParams: patchParams)
        guard fingerprint != channelTunFingerprint else { return }
        if tunDisabledIn(overlay: overlay, patchParams: patchParams) {
            channelTunFingerprint = fingerprint
            clearTunRestartNeeded()
            Self.log.info("live \(method, privacy: .public) disabled TUN; runner stays stopped by design")
            return
        }
        do {
            try await restartChannelTun()
            channelTunFingerprint = fingerprint
            clearTunRestartNeeded()
            Self.log.info("TUN runner restarted after live \(method, privacy: .public) (triple changed)")
        } catch {
            let reason = "配置已应用，但 TUN 数据面重启失败（\(error.localizedDescription)）：流量可能不再走代理，请重启 VPN 恢复"
            tunRestartNeeded = reason
            writeTunRestartNeeded(reason: reason)
            Self.log.error("TUN restart after live \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public); restart the VPN to restore the data plane")
        }
    }

    /// Opens a FRESH packet channel and re-runs tun.start on it
    /// (the old handle's device half was consumed by the first
    /// tun.start and cannot be re-used). On success the pump is
    /// swapped onto the new channel and the old channel is closed;
    /// on failure the new channel is closed and the old handle is
    /// left alone (its runner is already dead — the caller records
    /// the restart-needed state instead of pretending otherwise).
    private func restartChannelTun() async throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw TunnelSetupError.noAppGroup
        }
        let tun = readTunnelSettings(container: container)
        guard tun.enabled else {
            throw TunnelSetupError.tunDisabled
        }
        let oldHandle = channelHandle
        let newHandle = concord_ios_packet_channel_open()
        guard newHandle != 0 else {
            throw TunnelSetupError.channelFailed
        }
        do {
            let params = tunStartParams(handle: newHandle, tun: tun)
            _ = try await sendCoreRequest(method: "tun.start", params: params, timeoutSeconds: 60)
        } catch {
            concord_ios_packet_channel_close(newHandle)
            throw error
        }
        channelHandle = newHandle
        if oldHandle != 0 {
            concord_ios_packet_channel_close(oldHandle)
        }
    }

    /// Writes the restart-needed flag for the app's Dashboard
    /// (TunnelManager.checkTunRestartNeeded reads it).
    private func writeTunRestartNeeded(reason: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let record: [String: Any] = [
            "reason": reason,
            "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: container.appendingPathComponent(tunRestartNeededFileName), options: .atomic)
    }

    /// Clears the restart-needed flag (successful start / restart).
    private func clearTunRestartNeeded() {
        tunRestartNeeded = nil
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(tunRestartNeededFileName))
    }

    /// Deletes stale snapshot files (interface B8, stop-part) so the
    /// app never shows last-round data as current after the tunnel
    /// stops. The ConcordClient maxAge part (another worker) is the
    /// backstop; deleting here removes the files at the source.
    /// Also clears the TUN restart-needed flag: with the VPN off
    /// there is no data plane to restart.
    private func deleteStaleSnapshots() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let snapshots = container.appendingPathComponent("snapshots")
        for name in ["logs", "dns", "route", "engine"] {
            try? FileManager.default.removeItem(at: snapshots.appendingPathComponent("\(name).json"))
        }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(tunRestartNeededFileName))
        tunRestartNeeded = nil
    }

    // MARK: - Shared files (App Group)

    private struct TunnelSettings {
        let enabled: Bool
        let stack: String
        let mtu: Int
        let dns: [String]
        // IPv6 (Settings > 通用): disabled by default. When enabled, the
        // core gets the address below in tun.start and the interface gets
        // the same address plus the IPv6 default route. The default is
        // the core's own DEFAULT_INET6 (upstream crates/engine/src/tun.rs).
        let ipv6: Bool
        let ipv6Address: String
        // Local network (FlClash: 本地网络设置）: CIDRs excluded from
        // the tunnel routes, private-range bypass, DNS hijacking.
        let routeExcludeAddress: [String]
        let bypassPrivateRoute: Bool
        let dnsHijack: Bool
        // Loopback 10.7.0.1 switch (E6, fork 89aa066 NE side):
        // when on, bootCore adds 10.7.0.2 + a 10.7.0.1/32 route.
        // Deliberately NOT part of the tunTripleFingerprint — the
        // NE interface is built once at startup, so a live change
        // needs a VPN restart and must not trigger a channel TUN
        // restart by itself.
        let loopbackDevice: Bool
        // TUN override (FlClash tun.dart, via overrides.json): the
        // congestion controller for tun.start. mtu is overridden the
        // same way below; the other tun override keys travel in the
        // config.apply overlay's "tun" fragment, which the core
        // parses into TunConfig (strict-route, udp-timeout, …).
        let congestionController: String?
    }

    private func readTunnelSettings(container: URL) -> TunnelSettings {
        let file = container.appendingPathComponent(tunnelSettingsFileName)
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let enabled = json["enabled"] as? Bool ?? true
            let stack = json["stack"] as? String ?? "gvisor"
            let tunOverrides = effectiveOverrides(section: "tun")
            // FlClash PacketTunnelSharedStateStore
            // (PacketTunnelVPNOptions.tunMTU): clamp into
            // 1280...65535 — below 1280 the system drops the IPv6
            // address.
            let mtu = max(1280, min(65535,
                (tunOverrides?["mtu"] as? NSNumber)?.intValue
                    ?? (json["mtu"] as? NSNumber)?.intValue ?? 1500))
            let dns = json["dns"] as? [String] ?? ["223.5.5.5", "8.8.8.8"]
            let ipv6 = json["ipv6"] as? Bool ?? false
            let ipv6Address = json["ipv6-address"] as? String ?? "fdfe:dcba:9876::1/126"
            let routeExcludeAddress = json["route-exclude-address"] as? [String] ?? []
            let bypassPrivateRoute = json["bypass-private-route"] as? Bool ?? false
            let dnsHijack = json["dns-hijack"] as? Bool ?? true
            let congestionController = tunOverrides?["congestion-controller"] as? String
                ?? json["congestion-controller"] as? String
            let loopbackDevice = LoopbackNetworkSettings.isEnabled(in: json)
            return TunnelSettings(enabled: enabled, stack: stack, mtu: mtu, dns: dns, ipv6: ipv6, ipv6Address: ipv6Address, routeExcludeAddress: routeExcludeAddress, bypassPrivateRoute: bypassPrivateRoute, dnsHijack: dnsHijack, congestionController: congestionController, loopbackDevice: loopbackDevice)
        }
        return TunnelSettings(enabled: true, stack: "gvisor", mtu: 1500, dns: ["223.5.5.5", "8.8.8.8"], ipv6: false, ipv6Address: "fdfe:dcba:9876::1/126", routeExcludeAddress: [], bypassPrivateRoute: false, dnsHijack: true, congestionController: nil, loopbackDevice: false)
    }

    /// Parse a CIDR ("10.0.0.0/8" or "::1/128") into an excluded
    /// route. IPv4 needs a dotted subnet mask; IPv6 takes the prefix
    /// length directly. Returns (nil, nil) for malformed input.
    private func excludedRoute(from cidr: String) -> (v4: NEIPv4Route?, v6: NEIPv6Route?) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return (nil, nil) }
        let address = String(parts[0])
        if address.contains(":") {
            guard (0...128).contains(prefix) else { return (nil, nil) }
            return (nil, NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix)))
        }
        guard (0...32).contains(prefix) else { return (nil, nil) }
        let maskValue: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        let mask = "\(maskValue >> 24 & 0xFF).\(maskValue >> 16 & 0xFF).\(maskValue >> 8 & 0xFF).\(maskValue & 0xFF)"
        return (NEIPv4Route(destinationAddress: address, subnetMask: mask), nil)
    }

    /// The config.apply overlay, built from the shared files (see
    /// the header comment). Used identically by the startup apply
    /// in bootCore and by live re-applies in handleAppMessage, so
    /// both see the same fragments — including the "tun" fragment
    /// the B1 fingerprint compares.
    private func buildApplyOverlay() -> [String: Any] {
        var overlay: [String: Any] = [:]
        if let mitm = mergedMitmOverlay() {
            overlay["mitm"] = mitm
        }
        if let rules = overlayRules() {
            overlay["rules"] = rules
        }
        if let dns = effectiveDnsWithModules() {
            overlay["dns"] = dns
        }
        if let ntp = effectiveSection(file: ntpFileName, section: "ntp") {
            overlay["ntp"] = ntp
        }
        if let sniffer = effectiveSection(file: snifferFileName, section: "sniffer") {
            overlay["sniffer"] = sniffer
        }
        if let tun = effectiveTunWithModules() {
            overlay["tun"] = tun
        }
        if let hosts = effectiveHostsWithModules() {
            overlay["hosts"] = hosts
        }
        // Module rule providers: the overlay replaces the profile's
        // rule-providers wholesale (upstream merge.rs), so the
        // merged map (profile ∪ module) travels here; see
        // moduleRuleProviders() for the stale-profile fallback.
        if let providers = moduleRuleProviders() {
            overlay["rule-providers"] = providers
        }
        if let generalOverlay = readSharedJSON(name: generalOverlayFileName) {
            for (key, value) in generalOverlay {
                overlay[key] = value
            }
        }
        // General overrides (test-url, geodata-loader, …) are
        // top-level RawConfig keys: they merge straight into the
        // overlay. ipv6 / unified-delay / tcp-concurrent overrides
        // are ALSO in the overlay (so a live re-apply honours them).
        if let generalOverrides = effectiveTopLevelOverrides(section: "general") {
            for (key, value) in generalOverrides {
                overlay[key] = value
            }
        }
        return overlay
    }

    /// The MITM overlay for config.apply: the user's own mitm.json
    /// first, then the enabled modules' merged lists from
    /// module-mitm.json (user hostnames first, so an exclusion the
    /// user wrote holds against any module — FlClash's
    /// mergeMitmModules). Nil when neither file exists.
    private func mergedMitmOverlay() -> [String: Any]? {
        let user = readSharedJSON(name: mitmFileName)
        let modules = readSharedJSON(name: moduleMitmFileName)
        guard user != nil || modules != nil else { return nil }
        var mitm = user ?? [:]
        let hosts = (user?["hostname"] as? [String] ?? [])
            + (modules?["hostname"] as? [String] ?? [])
        mitm["hostname"] = hosts
        for key in ["url-rewrite", "header-rewrite", "body-rewrite", "map-local", "script", "skip-server-cert-verify-hostname", "client-source-address", "request-body-mock"] {
            let merged = (user?[key] as? [String] ?? []) + (modules?[key] as? [String] ?? [])
            if merged.isEmpty {
                mitm.removeValue(forKey: key)
            } else {
                mitm[key] = merged
            }
        }
        // h2: a module asking for HTTP/2 turns it on (OR with the
        // user's own switch — the module's ask wins, like its lists).
        if (user?["h2"] as? Bool) == true || (modules?["h2"] as? Bool) == true {
            mitm["h2"] = true
        }
        return mitm
    }

    /// The enabled modules' merged rules, for the overlay's
    /// top-level "rules" (the core prepends them before the
    /// profile's own rules). Nil when there are none.
    private func moduleRules() -> [String]? {
        guard let modules = readSharedJSON(name: moduleMitmFileName),
              let rules = modules["rules"] as? [String], !rules.isEmpty else { return nil }
        return rules
    }

    /// The overlay's top-level "rules": the enabled modules' merged
    /// rules FIRST, then the user's added rules (FlClash
    /// rawConfig['rules'] = [...mitm.rules, ...rules] — rules here
    /// already has the added rules first). The core prepends overlay
    /// rules before the profile's own, so on a conflict the module
    /// rule wins, like FlClash. Nil when there are none.
    private func overlayRules() -> [String]? {
        var rules: [String] = []
        if let modules = moduleRules() {
            rules.append(contentsOf: modules)
        }
        if let added = readSharedJSONArray(name: addedRulesFileName) {
            rules.append(contentsOf: added)
        }
        return rules.isEmpty ? nil : rules
    }

    // MARK: - Module network + rule providers (module-mitm.json)
    //
    // The store writes the enabled modules' merged network edits
    // ("network") and rule providers ("rule-providers" +
    // "module-rule-providers" + "profileDigest") into
    // module-mitm.json; this section applies them to the overlay
    // at every config.apply. The edits run over the overlay's OWN
    // effective sections (dns.json / hosts.json / the tun
    // overrides) — those ARE the profile's lists as the core sees
    // them, because the overlay replaces the profile's dns / hosts
    // / tun wholesale (upstream merge.rs: the merged document
    // keeps only the overlay's keys plus the profile's proxies,
    // proxy-groups, sub-rules and rules). The module's
    // bypass-domain has no such section: the core names it "the
    // host's proxy bypass list" (config/src/mitm/module/
    // network.rs), and this host is a packet tunnel with no proxy
    // bypass list, so it is carried for consent only and never
    // written here.

    /// The merged module network edits from module-mitm.json, if any.
    private func moduleNetwork() -> [String: Any]? {
        guard let modules = readSharedJSON(name: moduleMitmFileName),
              let network = modules["network"] as? [String: Any], !network.isEmpty else { return nil }
        return network
    }

    /// MitmListEdit.applyTo, over the overlay's own list: `before`
    /// ahead, `after` behind, `replace` dropping the current list;
    /// duplicates removed, order kept.
    private func applyModuleListEdit(_ edit: [String: Any], to current: [String]) -> [String] {
        let replace = edit["replace"] as? Bool ?? false
        let before = edit["before"] as? [String] ?? []
        let after = edit["after"] as? [String] ?? []
        var out: [String] = []
        for value in before + (replace ? [] : current) + after where !out.contains(value) {
            out.append(value)
        }
        return out
    }

    /// The effective dns section with the modules' network edits
    /// applied: the edits run over dns.json, then the dns overrides
    /// merge over the result, so a user's explicit override still
    /// wins on a key it sets. Nil when the section stays empty.
    private func effectiveDnsWithModules() -> [String: Any]? {
        var base = readSharedJSON(name: dnsFileName) ?? [:]
        if let network = moduleNetwork() {
            for key in ["nameserver", "default-nameserver", "fake-ip-filter"] {
                if let edit = network[key] as? [String: Any] {
                    base[key] = applyModuleListEdit(edit, to: base[key] as? [String] ?? [])
                }
            }
            if let policy = network["nameserver-policy"] as? [[String: Any]] {
                var map = base["nameserver-policy"] as? [String: Any] ?? [:]
                for entry in policy {
                    guard let domain = entry["domain"] as? String,
                          let values = entry["values"] as? [String], !values.isEmpty else { continue }
                    map[domain] = values.count == 1 ? values[0] : values
                }
                base["nameserver-policy"] = map
            }
        }
        if let overrides = effectiveOverrides(section: "dns") {
            deepMerge(into: &base, overrides)
        }
        return base.isEmpty ? nil : base
    }

    /// The effective hosts map with the modules' host entries
    /// applied: a module entry replaces the same-domain entry
    /// (the fork applies module hosts over the profile's, and
    /// hosts.json stands in for the profile's hosts here). One
    /// value writes as a string, several as a list — the core
    /// reads both (hosts.rs value_to_strings). Nil when empty.
    private func effectiveHostsWithModules() -> [String: Any]? {
        var base = readSharedJSON(name: hostsFileName) ?? [:]
        if let network = moduleNetwork(),
           let entries = network["hosts"] as? [[String: Any]] {
            for entry in entries {
                guard let domain = entry["domain"] as? String,
                      let values = entry["values"] as? [String], !values.isEmpty else { continue }
                base[domain] = values.count == 1 ? values[0] : values
            }
        }
        return base.isEmpty ? nil : base
    }

    /// The effective tun fragment with the modules' routes
    /// applied: included routes union with the fragment's
    /// (an override's routes are kept, the module's add to them),
    /// and the exclude edit runs over the fragment's list. Nil
    /// when the fragment stays empty, so a profile with no tun
    /// overrides and no module routes still sends no "tun" key.
    private func effectiveTunWithModules() -> [String: Any]? {
        var base = effectiveSection(file: nil, section: "tun") ?? [:]
        if let network = moduleNetwork() {
            if let routes = network["route-address"] as? [String], !routes.isEmpty {
                var current = base["route-address"] as? [String] ?? []
                for route in routes where !current.contains(route) { current.append(route) }
                base["route-address"] = current
            }
            if let edit = network["route-exclude-address"] as? [String: Any] {
                base["route-exclude-address"] = applyModuleListEdit(edit, to: base["route-exclude-address"] as? [String] ?? [])
            }
        }
        return base.isEmpty ? nil : base
    }

    /// The rule providers for the overlay: the merged map
    /// (profile ∪ module) from module-mitm.json when it was
    /// computed against the config.yaml in force, else the
    /// module-only map. The overlay REPLACES the profile's
    /// rule-providers wholesale (upstream merge.rs), so emitting
    /// only the module providers would drop the profile's own and
    /// break its RULE-SET rules — and emitting a rule without its
    /// provider fails config.apply outright (UnknownRuleSet). A
    /// stale merged map is never emitted: after a profile switch
    /// the module-only map keeps the module rules working while
    /// the profile's own providers wait for the next module
    /// refresh (nothing re-reads the new profile's providers on a
    /// switch — see the report). Nil when the file carries no
    /// providers at all.
    private func moduleRuleProviders() -> [String: Any]? {
        guard let modules = readSharedJSON(name: moduleMitmFileName),
              let merged = modules["rule-providers"] as? [String: Any], !merged.isEmpty else { return nil }
        if let digest = modules["profileDigest"] as? String,
           digest == profileDigestNow() {
            return merged
        }
        return modules["module-rule-providers"] as? [String: Any]
    }

    /// FNV-1a of the config.yaml bytes the next apply will use
    /// (nil when unreadable — treated as a digest mismatch).
    private func profileDigestNow() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent(configFileName)) else { return nil }
        return fnv1aHex(data)
    }

    private func readSharedJSONArray(name: String) -> [String]? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let file = container.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return json
    }

    private func readSharedJSON(name: String) -> [String: Any]? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let file = container.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Override framework (OverrideStore / overrides.json)
    //
    // overrides.json holds the global overrides plus one entry per
    // profile UUID and the active profile id. A section's effective
    // value is its base file (if any) with the global overrides,
    // then the active profile's overrides, merged over it. Dotted
    // key paths ("fallback-filter.geoip", "sniff.HTTP") expand into
    // nested maps. The tun fragment has no base file: only overrides
    // exist (the device itself is owned by tun.start / tunnel.json).

    private func readOverrides() -> [String: Any]? {
        readSharedJSON(name: overridesFileName)
    }

    private func effectiveOverrides(section: String) -> [String: Any]? {
        guard let doc = readOverrides() else { return nil }
        var merged: [String: Any] = [:]
        if let global = doc["global"] as? [String: Any],
           let keys = global[section] as? [String: Any] {
            mergeDotted(into: &merged, keys)
        }
        if let active = doc["activeProfileId"] as? String,
           let profiles = doc["profiles"] as? [String: Any],
           let profile = profiles[active] as? [String: Any],
           let keys = profile[section] as? [String: Any] {
            mergeDotted(into: &merged, keys)
        }
        return merged.isEmpty ? nil : merged
    }

    private func effectiveSection(file: String?, section: String) -> [String: Any]? {
        var base = file.flatMap { readSharedJSON(name: $0) } ?? [:]
        if let overrides = effectiveOverrides(section: section) {
            deepMerge(into: &base, overrides)
        }
        return base.isEmpty ? nil : base
    }

    private func effectiveTopLevelOverrides(section: String) -> [String: Any]? {
        effectiveOverrides(section: section)
    }

    private func mergeDotted(into dict: inout [String: Any], _ keys: [String: Any]) {
        for (key, value) in keys {
            let parts = key.split(separator: ".").map(String.init)
            assignDotted(into: &dict, parts: parts, value: value)
        }
    }

    private func assignDotted(into dict: inout [String: Any], parts: [String], value: Any) {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dict[first] = value
            return
        }
        var child = dict[first] as? [String: Any] ?? [:]
        assignDotted(into: &child, parts: Array(parts.dropFirst()), value: value)
        dict[first] = child
    }

    private func deepMerge(into base: inout [String: Any], _ overrides: [String: Any]) {
        for (key, value) in overrides {
            if var baseChild = base[key] as? [String: Any],
               let overrideChild = value as? [String: Any] {
                deepMerge(into: &baseChild, overrideChild)
                base[key] = baseChild
            } else {
                base[key] = value
            }
        }
    }
}
