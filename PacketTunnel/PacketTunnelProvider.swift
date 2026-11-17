import Foundation
import NetworkExtension
import os

// PacketTunnelProvider — Network Extension entry point.
//
// The Concord core runs IN THIS PROCESS (in-process staticlib; iOS
// forbids spawning a helper process). The app process NEVER loads the
// core: it talks to this extension through NEProviderManager /
// sendProviderMessage (JSON-RPC) and reads live snapshots from the App
// Group container (see "Extension <-> app IPC" below).
//
// Startup sequence (core.hello -> core.init -> config.apply ->
// engine.start -> tun.start), mirroring bins/android, with
// EngineConfig { android: false } and capabilities
// ["tun.inherited", "tun.channel"] (upstream/bins/ios/src/core.rs):
//   1. Read config.yaml from the App Group shared container.
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
// Extension <-> app IPC (the app never loads the core):
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
// rawConfig['rules'] = [...mitm.rules, ...rules]. Module scripts and
// map-local files live in <home>/mitm/resources/ (the core's resources
// directory, home being this container), so the core reads them by the
// content-hash names the module-mitm.json lines name. The DNS choices
// travel the same way: the app writes dns.json (DnsConfig keys,
// kebab-case — "enhanced-mode", "fake-ip-range", upstream
// crates/config/src/dns.rs) and the extension merges it as
// {"dns": <dns.json>} alongside mitm. General settings travel as
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
        subsystem: "com.sunny-qwe.concord-ios", category: "PacketTunnel")

    // App Group shared container (must match the entitlements + ExportOptions).
    private let appGroupID = "group.com.sunny-qwe.concord-ios"
    private let configFileName = "config.yaml"
    private let mitmFileName = "mitm.json"
    private let moduleMitmFileName = "module-mitm.json"
    private let dnsFileName = "dns.json"
    private let generalSettingsFileName = "general.json"
    private let tunnelSettingsFileName = "tunnel.json"

    // The tunnel interface address. tun.start takes CIDR prefixes
    // (upstream crates/engine/src/tun.rs: Prefix::parse), so the core
    // gets "198.18.0.1/32"; the NE interface gets the plain address.
    private let tunnelAddress = "198.18.0.1"

    /// All core state is mutated only on this queue. The Deliver
    /// callback runs on a core thread and hops onto it.
    private let coreQueue = DispatchQueue(label: "com.sunny-qwe.concord-ios.core")
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

    private enum TunnelSetupError: LocalizedError {
        case noAppGroup
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
        let context = Unmanaged.passRetained(self).toOpaque()
        Task {
            do {
                try await self.bootCore(context: context)
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
                completionHandler(error)
            }
        }
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
        ])
        _ = try await sendCoreRequest(method: "core.init", params: [
            "home": container.path,
        ])

        // config.apply: the profile path is absolute (home is the App
        // Group container); the MITM + DNS overlays come from mitm.json
        // / dns.json when the user configured them in the app (see
        // header comment).
        var applyParams: [String: Any] = ["profile": ["path": configURL.path]]
        var overlay: [String: Any] = [:]
        if let mitm = mergedMitmOverlay() {
            overlay["mitm"] = mitm
        }
        if let rules = moduleRules() {
            overlay["rules"] = rules
        }
        if let dns = readSharedJSON(name: dnsFileName) {
            overlay["dns"] = dns
        }
        if !overlay.isEmpty {
            applyParams["overlay"] = overlay
        }
        _ = try await sendCoreRequest(method: "config.apply", params: applyParams)
        _ = try await sendCoreRequest(method: "engine.start", params: [:])

        // General settings saved in the app (general.json) are patched
        // in once at startup, so they take effect on the next VPN start
        // without the user tapping "apply". A failure here must not fail
        // the tunnel: the settings can still be applied live later.
        if let general = readSharedJSON(name: generalSettingsFileName), !general.isEmpty {
            do {
                _ = try await sendCoreRequest(method: "config.patch", params: general)
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

        var addresses = ["\(tunnelAddress)/32"]
        if tun.ipv6 {
            // The core parses each address as a CIDR prefix and sorts
            // IPv4 into inet4_address, IPv6 into inet6_address
            // (upstream crates/engine/src/tun.rs vpn_options); the
            // default below is the core's own DEFAULT_INET6.
            addresses.append(tun.ipv6Address)
        }
        _ = try await sendCoreRequest(method: "tun.start", params: [
            "source": ["kind": "channel", "handle": handle],
            "stack": tun.stack,
            "mtu": tun.mtu,
            "address": addresses,
            "dns": tun.dns,
        ])

        // Tunnel interface: the system owns routing; the core must not
        // install routes (upstream: Os::Other -> NullBackend on iOS).
        // IPv6 is configured from tunnel.json when the user enabled it
        // in Settings: the same address the core got in tun.start, plus
        // the IPv6 default route, so IPv6 traffic enters the tunnel
        // instead of bypassing it.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelAddress)
        settings.mtu = NSNumber(value: tun.mtu)
        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        if tun.ipv6 {
            let parts = tun.ipv6Address.split(separator: "/")
            if parts.count == 2, let prefixLength = Int(parts[1]) {
                let ipv6 = NEIPv6Settings(
                    addresses: [String(parts[0])],
                    networkPrefixLengths: [NSNumber(value: prefixLength)])
                ipv6.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = ipv6
            }
        }
        settings.dnsSettings = NEDNSSettings(servers: tun.dns)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try await subscribeToStreams()
        startPump()
        Self.log.info("tunnel up: channel \(handle), stack \(tun.stack, privacy: .public), mtu \(tun.mtu)")
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isStopping = true
        pumpRunning = false
        drainTimer?.cancel()
        drainTimer = nil
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
            var overlay: [String: Any] = [:]
            if let mitm = mergedMitmOverlay() {
                overlay["mitm"] = mitm
            }
            if let rules = moduleRules() {
                overlay["rules"] = rules
            }
            if let dns = readSharedJSON(name: dnsFileName) {
                overlay["dns"] = dns
            }
            if !overlay.isEmpty {
                request["overlay"] = overlay
            }
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
    private func sendRawJSONRPC(_ request: [String: Any], appID: Int? = nil) async throws -> Data {
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
                self.coreQueue.asyncAfter(deadline: .now() + 15) {
                    if let request = self.pending.removeValue(forKey: extID) {
                        request.continuation.resume(
                            throwing: TunnelSetupError.rpcFailed("调用超时（15s）"))
                    }
                }
            }
        }
    }

    /// Sends one request and returns its `result` value (throws on an
    /// error object). Used for the extension's own startup calls.
    private func sendCoreRequest(method: String, params: [String: Any]) async throws -> Any {
        let data = try await sendRawJSONRPC(["method": method, "params": params])
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
        ])
        registerStream(result: traffic, kind: .traffic)
        let connection = try await sendCoreRequest(method: "connection.watch", params: [
            "counters": true, "credit": 8,
        ])
        registerStream(result: connection, kind: .connection)
        let log = try await sendCoreRequest(method: "log.watch", params: ["credit": 8])
        registerStream(result: log, kind: .log)
        let dns = try await sendCoreRequest(method: "dns.watch", params: ["credit": 8])
        registerStream(result: dns, kind: .dns)
        // proxy.watch snapshot is the current ProxyGroups; its events
        // are ProxyDelta {order?, groups, nodes, removed}.
        let proxy = try await sendCoreRequest(method: "proxy.watch", params: ["credit": 8])
        registerStream(result: proxy, kind: .proxy)
        // route.watch snapshot is the current RouteStamp; its events
        // are RouteStamp values (latest policy).
        let route = try await sendCoreRequest(method: "route.watch", params: ["credit": 8])
        registerStream(result: route, kind: .route)
        // events.watch has NO snapshot — its CoreEvent items only
        // arrive as events, so the extension accumulates them like
        // log/dns.watch.
        let events = try await sendCoreRequest(method: "events.watch", params: ["credit": 8])
        registerStream(result: events, kind: .events)
        // engine.state snapshot is the current EngineStatus; its
        // events are EngineStatus values (latest policy).
        let engine = try await sendCoreRequest(method: "engine.state", params: ["credit": 8])
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
            do {
                let params: [String: Any]
                switch kind {
                case .traffic: params = ["interval_ms": 1000, "credit": 8]
                case .connection: params = ["counters": true, "credit": 8]
                case .log: params = ["credit": 8]
                case .dns: params = ["credit": 8]
                case .proxy: params = ["credit": 8]
                case .route: params = ["credit": 8]
                case .events: params = ["credit": 8]
                case .engine: params = ["credit": 8]
                }
                let result = try await self.sendCoreRequest(method: kind.methodName, params: params)
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
    }

    private func readTunnelSettings(container: URL) -> TunnelSettings {
        let file = container.appendingPathComponent(tunnelSettingsFileName)
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let enabled = json["enabled"] as? Bool ?? true
            let stack = json["stack"] as? String ?? "gvisor"
            let mtu = (json["mtu"] as? NSNumber)?.intValue ?? 1500
            let dns = json["dns"] as? [String] ?? ["223.5.5.5", "8.8.8.8"]
            let ipv6 = json["ipv6"] as? Bool ?? false
            let ipv6Address = json["ipv6-address"] as? String ?? "fdfe:dcba:9876::1/126"
            return TunnelSettings(enabled: enabled, stack: stack, mtu: mtu, dns: dns, ipv6: ipv6, ipv6Address: ipv6Address)
        }
        return TunnelSettings(enabled: true, stack: "gvisor", mtu: 1500, dns: ["223.5.5.5", "8.8.8.8"], ipv6: false, ipv6Address: "fdfe:dcba:9876::1/126")
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
        for key in ["url-rewrite", "header-rewrite", "body-rewrite", "map-local", "script"] {
            let merged = (user?[key] as? [String] ?? []) + (modules?[key] as? [String] ?? [])
            if merged.isEmpty {
                mitm.removeValue(forKey: key)
            } else {
                mitm[key] = merged
            }
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
}
