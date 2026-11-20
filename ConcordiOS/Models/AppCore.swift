import Foundation

// MARK: - AppCore: the Concord core in the APP process, delay tests only
//
// FlClash runs its core in the app process, which is why its delay
// test works with the VPN off. Ours ran the core only in the
// PacketTunnel extension, so with the VPN off every delay test threw
// (the transport was down) and ProxyStore recorded -2 for every node
// — the v0.2.31 "all nodes 失败" report. This class loads the same
// Rust staticlib into the APP target (see ConcordFFI.h) and starts
// the engine in-process, using the ACTIVE profile's config, with TUN
// disabled (a delay test needs outbound dialers, not a TUN device).
//
// Rules (the extension path is untouched):
//   * Used ONLY when the VPN is off. When the VPN is running, the
//     Proxies page keeps using the extension's core; two cores must
//     never run at once — ensureStarted() refuses while the tunnel
//     is running, and TunnelManager.start() stops this core first.
//   * Its own home directory (Library/Application Support/
//     ConcordAppCore, app-private — NOT the App Group container),
//     so it shares no writable state with the extension instance.
//     It only READS the shared config.yaml.
//   * Its listeners are overridden in the config.apply overlay to
//     ports nothing else uses (mixed 17890, SOCKS 17891, HTTP
//     17892, external-controller 127.0.0.1:19090, DNS listen
//     127.0.0.1:18053), so even a Settings-initiated VPN start
//     while this core runs cannot clash on a port.
//   * No tun.start, no packet channel, no stream subscriptions
//     except the delay.run accumulator. Engine boot is
//     core.hello -> core.init -> config.apply -> engine.start,
//     mirroring PacketTunnelProvider.bootCore.
//   * Geo data is pre-seeded before boot (GeoSeed): config.apply
//     compiles the profile's GEOIP,CN,DIRECT rule, and a missing
//     geoip.metadb makes the core download it over its own TLS
//     client, which the campus network rejects (v0.2.33). The
//     files are fetched with URLSession (system trust store) into
//     this home dir — and into the App Group container too, so the
//     next VPN start finds them — and the overlay forces
//     geo-auto-update off for this instance only.
//
// If the in-app core cannot start (staticlib missing, engine
// failure), ensureStarted throws and the caller leaves nodes
// untested — it never records a fake -2 for a test that never ran.

enum AppCoreError: LocalizedError {
    case noConfig
    case tunnelRunning
    case coreStartFailed
    case sessionFailed
    case rpcFailed(String)
    /// The geo databases could not be pre-seeded and geoip.metadb is
    /// still missing, so config.apply would fail in the core's own
    /// MMDB download. Carries the real download reason (see GeoSeed).
    case geoSeedFailed(String)

    var errorDescription: String? {
        switch self {
        case .noConfig:
            return "尚未导入订阅：请先在主 App 里导入一个订阅，再测速"
        case .tunnelRunning:
            return "VPN 正在运行：测速走隧道核心"
        case .coreStartFailed:
            return "应用内核心启动失败（concord_ios_start 返回非 0）"
        case .sessionFailed:
            return "应用内核心会话打开失败（核心未运行）"
        case .rpcFailed(let message):
            return "核心调用失败：\(message)"
        case .geoSeedFailed(let message):
            return "GeoIP 数据库下载失败：\(message)（测速需要 geoip.metadb，核心自带的下载在当前网络下同样失败；请检查网络后重试）"
        }
    }
}

final class AppCore {
    static let shared = AppCore()

    /// Ports the app-side core listens on (see the header comment).
    /// Nothing else on the device uses them; the extension's core
    /// uses the profile's own ports, so the two can never clash.
    private static let appMixedPort = 17890
    private static let appSocksPort = 17891
    private static let appHTTPPort = 17892
    private static let appController = "127.0.0.1:19090"
    private static let appDNSListen = "127.0.0.1:18053"

    private let coreQueue = DispatchQueue(label: "com.concord.ios.appcore")
    private static var coreStarted = false

    private var session: UInt64 = 0
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// The config.yaml this core was started with (mtime + size);
    /// a different signature means the profile changed and the
    /// core must be restarted before the next test.
    private var loadedConfigSignature: String?
    /// One batch delay test at a time (mirrors the extension's
    /// DelayRunAccumulator): events accumulate here until the app
    /// polls them with delayRunPoll().
    private struct DelayRunAccumulator {
        let sub: Int
        var results: [[String: Any]] = []
        var done: Bool = false
    }
    private var delayRun: DelayRunAccumulator?

    /// True while the app-side core session is open.
    var isRunning: Bool { session != 0 }

    private init() {}

    // MARK: C callbacks (non-capturing; the core is passed as context)

    private static let deliverCallback: ConcordIOSDeliver = { context, data, len in
        guard let context, let data, len > 0 else { return false }
        let core = Unmanaged<AppCore>.fromOpaque(context).takeUnretainedValue()
        let message = Data(bytes: data, count: len)
        core.coreQueue.async { core.handleCoreMessage(message) }
        return true
    }

    private static let releaseCallback: ConcordIOSRelease = { context in
        guard let context else { return }
        Unmanaged<AppCore>.fromOpaque(context).release()
    }

    // MARK: Lifecycle

    /// The app-private home directory for this core instance.
    private func homeDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ConcordAppCore", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The shared config.yaml the extension reads at startTunnel
    /// (written by ProfileStore.activate). The app-side core reads
    /// the same file, so the delay test uses the active profile.
    private func sharedConfigURL() -> URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.configFileName)
    }

    private func configSignature(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else { return nil }
        return "\(mtime.timeIntervalSince1970)-\(size.intValue)"
    }

    /// Starts the app-side core with the active profile's config
    /// when it is not already running (or restarts it when the
    /// config changed since the last start). Throws when the VPN
    /// is running, when there is no config, or when the core fails
    /// to boot — the caller leaves nodes untested in that case.
    @MainActor
    func ensureStarted() async throws {
        guard !TunnelManager.shared.isRunning else {
            throw AppCoreError.tunnelRunning
        }
        guard let configURL = sharedConfigURL(),
              FileManager.default.fileExists(atPath: configURL.path),
              let signature = configSignature(for: configURL) else {
            throw AppCoreError.noConfig
        }
        if session != 0 {
            guard signature != loadedConfigSignature else { return }
            await stop()
        }
        let home = try homeDirectory()
        // Pre-seed the geo databases (GeoSeed) BEFORE the core boots:
        // config.apply compiles the profile's GEOIP,CN,DIRECT rule,
        // and a missing geoip.metadb makes the core download it over
        // its own TLS client — which rejects the campus network's
        // MITM certificate ("can't download MMDB: ... UnknownIssuer",
        // v0.2.33). URLSession uses the iOS system trust store, so
        // the same file downloads here where the core's cannot, and
        // a present file makes the core skip its download entirely.
        // Seed the extension's home (App Group container) at the
        // same time, so the next VPN start finds the files already
        // there; that pass is best-effort — the tunnel reports the
        // core's own error if files are still missing. The two homes
        // seed concurrently so a slow network does not pay both
        // timeouts in series.
        let groupHome = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
        let groupSeedTask = groupHome.map { dir in
            Task { await GeoSeed.ensureGeoFiles(in: dir, perFileTimeout: 30) }
        }
        let appSeed = await GeoSeed.ensureGeoFiles(in: home, perFileTimeout: 45)
        _ = await groupSeedTask?.value
        // The MMDB is the one file config.apply cannot live without.
        // If it is still missing, say so with the real download
        // reason instead of letting the core fail later with its TLS
        // error — the Proxies banner shows this verbatim.
        if !GeoSeed.isPresent(GeoSeed.mmdbFileName, in: home) {
            let reason: String
            if let failure = appSeed.failures.first(where: { $0.file == GeoSeed.mmdbFileName }) {
                reason = failure.error.localizedDescription
            } else if appSeed.skippedByCooldown.contains(GeoSeed.mmdbFileName) {
                reason = "上次下载失败不久（\(Int(GeoSeed.cooldownSeconds / 60)) 分钟内不再重试）"
            } else {
                reason = "文件缺失且未能下载"
            }
            throw AppCoreError.geoSeedFailed(reason)
        }
        let context = Unmanaged.passRetained(self).toOpaque()
        do {
            if !Self.coreStarted {
                guard concord_ios_start() == 0 else {
                    throw AppCoreError.coreStartFailed
                }
                Self.coreStarted = true
            }
            let sessionID = concord_ios_open_session(
                Self.deliverCallback, context, Self.releaseCallback)
            guard sessionID != 0 else {
                throw AppCoreError.sessionFailed
            }
            session = sessionID
            // Boot calls get 60 s, like the extension's bootCore
            // (PacketTunnelProvider.sendCoreRequest): a healthy but
            // slow boot — config.apply loading GeoIP data and the
            // profile's rule providers, the core warming up — must
            // not be aborted at 15 s. (v0.2.33's failure was not a
            // timeout: the MMDB download itself was rejected by the
            // core's TLS client — GeoSeed above pre-seeds the file
            // so config.apply no longer downloads it.) The 15 s
            // default killed the first delay test on every tap
            // (v0.2.32: the tap did nothing at all) and the torn-down
            // session made the next tap restart the same slow boot
            // and time out again. Only the boot is slow; delay.test
            // itself keeps the 15 s default (the core's own probe
            // timeout is 5 s).
            _ = try await sendRequest(method: "core.hello", params: [
                "protocol": ["min": 1, "max": 1],
                "client": ["name": "concord-ios", "version": "0.2.0"],
            ], resultType: EmptyResult.self, timeoutSeconds: 60)
            _ = try await sendRequest(method: "core.init", params: [
                "home": home.path,
            ], resultType: EmptyResult.self, timeoutSeconds: 60)
            // The profile gives proxies / proxy-groups / rules; the
            // overlay carries everything else — here the listener
            // ports, so this instance can never clash with the
            // extension's core or with anything else on the device.
            // geo-auto-update is forced off for this instance: the
            // delay test needs no geo refresh, and a periodic
            // re-download would run through the core's own TLS
            // client — the same one the campus network rejects
            // (v0.2.33 MMDB failure). The seeded files stay until
            // the user re-imports. This overlay is app-core-only:
            // the extension core keeps the profile's own setting.
            // (There is no overlay key that skips the compile-time
            // MMDB need itself — a GEOIP rule must have the file.
            // GeoSeed above is what removes that need.)
            let overlay: [String: Any] = [
                "mixed-port": Self.appMixedPort,
                "socks-port": Self.appSocksPort,
                "port": Self.appHTTPPort,
                "external-controller": Self.appController,
                "dns": ["listen": Self.appDNSListen],
                "geo-auto-update": false,
            ]
            _ = try await sendRequest(method: "config.apply", params: [
                "profile": ["path": configURL.path],
                "overlay": overlay,
            ], resultType: EmptyResult.self, timeoutSeconds: 60)
            _ = try await sendRequest(method: "engine.start", params: [:], resultType: EmptyResult.self, timeoutSeconds: 60)
            loadedConfigSignature = signature
        } catch {
            // Balance the passRetained above exactly once: if the
            // session was opened, tearDown() closes it and the
            // releaseCallback balances the retain (sync or async);
            // only when the session never opened (start/open failed)
            // does this catch own the release. Releasing in both
            // cases would over-release and crash.
            let hadSession = session != 0
            tearDown()
            if !hadSession {
                Unmanaged<AppCore>.fromOpaque(context).release()
            }
            throw error
        }
    }

    /// Stops the app-side core (engine.stop + close session).
    /// Best-effort; safe to call when it is not running.
    @MainActor
    func stop() async {
        guard session != 0 else { return }
        sendNotification(method: "engine.stop", params: [:])
        // Give the engine a moment to stop before closing the
        // session; the close fires releaseCallback, which balances
        // the passRetained in ensureStarted.
        try? await Task.sleep(nanoseconds: 200_000_000)
        tearDown()
    }

    /// Closes the session and clears the pending requests. The
    /// mutation runs on coreQueue (the same queue the callbacks
    /// and the send path use), so it never races them.
    private func tearDown() {
        coreQueue.sync {
            if session != 0 {
                concord_ios_close_session(session)
                session = 0
            }
            for (_, continuation) in pending {
                continuation.resume(throwing: AppCoreError.rpcFailed("核心会话已关闭"))
            }
            pending.removeAll()
            delayRun = nil
            loadedConfigSignature = nil
        }
    }

    // MARK: Delay test

    /// One node's delay (delay.test). The core must already be
    /// started (ensureStarted); a transport failure throws and the
    /// caller must NOT record it as a node failure.
    func delayTest(proxy: String, url: String? = nil, timeout: UInt64? = nil) async throws -> ConcordDelayResult {
        var params: [String: Any] = ["proxy": proxy]
        if let url { params["url"] = url }
        if let timeout { params["timeout"] = timeout }
        return try await sendRequest(method: "delay.test", params: params, resultType: ConcordDelayResult.self)
    }

    /// Starts a batch delay test (delay.run, a stream). The reply
    /// is the subscription ({sub, snapshot}); the results arrive as
    /// events the core accumulates here — poll them with
    /// delayRunPoll(). The run ends by itself with a `done` event.
    func delayRunStart(proxies: [String], url: String? = nil, timeout: UInt64? = nil, concurrency: UInt32? = nil) async throws -> DelayRunStart {
        var params: [String: Any] = ["proxies": proxies]
        if let url { params["url"] = url }
        if let timeout { params["timeout"] = timeout }
        if let concurrency { params["concurrency"] = concurrency }
        let start = try await sendRequest(method: "delay.run", params: params, resultType: DelayRunStart.self)
        coreQueue.async {
            // The reply's snapshot is empty for delay.run (the
            // result type carries EmptyResult?); the real results
            // arrive as $/event notifications and accumulate here.
            self.delayRun = DelayRunAccumulator(sub: start.sub)
        }
        return start
    }

    /// The accumulated batch results (nil when no run is active).
    /// Reads the accumulator on coreQueue (it is written there).
    func delayRunPoll() async -> DelayRunSnapshot? {
        await withCheckedContinuation { continuation in
            coreQueue.async {
                guard let run = self.delayRun else {
                    continuation.resume(returning: nil)
                    return
                }
                let results = run.results.compactMap { dict -> ConcordDelayResult? in
                    guard let name = dict["name"] as? String,
                          let url = dict["url"] as? String,
                          let value = (dict["value"] as? NSNumber)?.int32Value else { return nil }
                    return ConcordDelayResult(name: name, url: url, value: value)
                }
                continuation.resume(returning: DelayRunSnapshot(runId: run.sub, done: run.done, results: results))
            }
        }
    }

    // MARK: JSON-RPC plumbing (mirrors PacketTunnelProvider)

    private func sendRequest<Result: Decodable>(method: String, params: [String: Any], resultType: Result.Type, timeoutSeconds: TimeInterval = 15) async throws -> Result {
        let data = try await sendRawJSONRPC(["method": method, "params": params], timeoutSeconds: timeoutSeconds)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppCoreError.rpcFailed("核心返回了无法解析的响应（\(method)）")
        }
        if let error = object["error"] as? [String: Any] {
            throw AppCoreError.rpcFailed((error["message"] as? String) ?? "未知错误（\(method)）")
        }
        guard let resultData = try? JSONSerialization.data(withJSONObject: object["result"] ?? NSNull()) else {
            throw AppCoreError.rpcFailed("核心返回了无法解析的结果（\(method)）")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Result.self, from: resultData)
    }

    private func sendRawJSONRPC(_ request: [String: Any], timeoutSeconds: TimeInterval = 15) async throws -> Data {
        let id = nextRequestID
        nextRequestID += 1
        var object = request
        object["jsonrpc"] = "2.0"
        object["id"] = id
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await withCheckedThrowingContinuation { continuation in
            coreQueue.async {
                guard self.session != 0 else {
                    continuation.resume(throwing: AppCoreError.rpcFailed("核心会话已关闭"))
                    return
                }
                self.pending[id] = continuation
                let sent = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return Int32(0) }
                    return concord_ios_send(self.session, base.assumingMemoryBound(to: UInt8.self), data.count)
                }
                if sent == 0 {
                    self.pending.removeValue(forKey: id)
                    continuation.resume(throwing: AppCoreError.rpcFailed("会话不存在"))
                    return
                }
                self.coreQueue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let request = self.pending.removeValue(forKey: id) {
                        request.resume(
                            throwing: AppCoreError.rpcFailed("调用超时（\(Int(timeoutSeconds))s）"))
                    }
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
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
    /// `$/event` notifications to the delay-run accumulator.
    private func handleCoreMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if (object["method"] as? String) == "$/event" {
            handleStreamEvent(params: object["params"] as? [String: Any])
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: data)
    }

    private func handleStreamEvent(params: [String: Any]?) {
        guard let params,
              let sub = (params["sub"] as? NSNumber)?.intValue,
              var run = delayRun, run.sub == sub,
              let items = params["data"] as? [Any] else { return }
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
        // Refill one unit of credit per batch consumed, like the
        // extension; without it the server pump stops after the
        // initial credit.
        sendNotification(method: "$/credit", params: ["sub": sub, "n": 1])
    }
}
