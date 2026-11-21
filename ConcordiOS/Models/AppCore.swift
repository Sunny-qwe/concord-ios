import Foundation

// MARK: - AppCore: the Concord core in the APP process, delay tests + MITM CA generation
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
//     so it shares no writable state with the extension instance
//     except the MITM CA: a CA generated here is copied into the
//     App Group container (and a tunnel-generated CA is healed
//     back here), so both cores load the SAME CA — see the CA sync
//     section below. It only READS the shared config.yaml.
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
//     next VPN start finds them — and the overlay follows the
//     user's Resources geo setting (default on, 24 h — upstream
//     FlClash 1b2ea11 flipped the default false -> true), so the
//     core's own periodic refresh runs for this instance too.
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
    /// The core answered `config is not applied`: the call raced
    /// ahead of config.apply — e.g. provider.update while the core
    /// is still booting. The same call succeeds once apply
    /// finishes, so callers swallow + retry this one error only;
    /// it is never a real failure. Match note: the engine's
    /// string code `core_error` (Failure::core, engine.rs) never
    /// reaches the wire — api_error maps it to ApiError::internal,
    /// so the wire error is code -32603 with this exact message
    /// (data {"kind": "internal"}). The match in sendRequest is
    /// therefore on the wire code + message, not `core_error`.
    case configNotApplied
    /// The geo databases could not be pre-seeded and geoip.metadb is
    /// still missing, so config.apply would fail in the core's own
    /// MMDB download. Carries the real download reason (see GeoSeed).
    case geoSeedFailed(String)
    /// config.apply failed with the core's own error (v0.2.45,
    /// case (b)): e.g. a RULE-SET provider the config references
    /// but never defines ("rules[0] [RULE-SET, Apple, …] error:
    /// rule set [Apple] not found"). That is a HARD error — the
    /// core refused the WHOLE config, not just the named nodes —
    /// so no delay test can run at all. Carries the core's exact
    /// message verbatim; only raised for a genuine apply refusal
    /// (a timeout / dead session keeps its existing error, see
    /// ensureStarted). The banner and the boot report both show
    /// this description, so both surfaces name the missing
    /// provider/rule AND say the whole config was refused.
    case configApplyFailed(String)
    /// The CA generated in-app could not be copied into the App
    /// Group container (the tunnel core's home), so the tunnel may
    /// generate a different CA at the next VPN start.
    case caSyncFailed(String)

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
        case .configNotApplied:
            return "核心还在启动，请稍后再试"
        case .geoSeedFailed(let message):
            return "GeoIP 数据库下载失败：\(message)（测速需要 geoip.metadb，核心自带的下载在当前网络下同样失败；请检查网络后重试）"
        case .configApplyFailed(let message):
            return "核心拒绝了当前配置，测速无法进行：\(message)（整个配置未生效——缺失的提供方或规则集会让核心拒绝全部配置，请检查订阅内容）"
        case .caSyncFailed(let message):
            return "CA 同步到隧道失败：\(message)"
        }
    }
}

final class AppCore {
    static let shared = AppCore()

    /// The profile store, linked by the app at startup
    /// (ConcordiOSApp, next to proxyStore.profileStore): FIX 2
    /// reads the active profile's current built bytes through it
    /// to heal a stale shared config.yaml, and FIX 1a reads the
    /// applied profile's name for the boot report. Weak, like
    /// ProxyStore.profileStore — the app owns the store. Nil when
    /// unlinked (e.g. a non-app caller): both fixes then skip
    /// silently and the boot proceeds exactly as before.
    static weak var profileStore: ProfileStore?

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

    /// delay.run event batches that arrived before their run was
    /// registered (see delayRunStart): the reply and the first
    /// result events race across the MainActor hop, and a
    /// fast-failing run (every node missing from the config fails
    /// with no I/O at all) can emit its whole batch — results AND
    /// the done event — inside that window. Dropping them made the
    /// poll loop wait the full 60 s for a `done` that already
    /// passed, then give up with the nodes still untested. Batches
    /// are keyed by sub and replayed on registration.
    private var delayRunStash: [(sub: Int, items: [Any])] = []

    /// log.watch subscription (mirrors the extension's five-stream
    /// subscribe in PacketTunnelProvider): the app core's log stream
    /// has an EMPTY snapshot — entries only arrive as events — so
    /// the Logs page reads them from this buffer while the VPN is
    /// off (the extension snapshot file does not exist then).
    /// Bounded to the newest 500 entries, like the extension's
    /// trimBuffer.
    private var logSub: Int?
    private var logBuffer: [ConcordLogEntry] = []

    /// True while the app-side core session is open.
    var isRunning: Bool { session != 0 }

    /// The file name the last boot report is persisted under, in
    /// this core's app-private home dir.
    private static let bootReportFileName = "last-boot-report.txt"

    /// The file name the last delay-test diagnostic is persisted
    /// under, in this core's app-private home dir. Written by
    /// ProxyStore after every delay run (method, params, per-node
    /// outcome counts, channel diagnosis); read by the Logs export,
    /// so the user can send the last failure as-is.
    private static let delayTestReportFileName = "last-delay-test-report.txt"

    /// Writes one delay-test diagnostic (plain text, already
    /// timestamped by the caller) to `last-delay-test-report.txt`.
    /// Best-effort and synchronous: called from ProxyStore's
    /// run-exits, including the throw paths.
    static func recordDelayTestReport(_ text: String) {
        guard let home = try? appHomeDirectory() else { return }
        try? text.write(
            to: home.appendingPathComponent(delayTestReportFileName),
            atomically: true, encoding: .utf8)
    }

    /// The last delay-test diagnostic, if one was ever written.
    static func lastDelayTestReportText() -> String? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("ConcordAppCore", isDirectory: true)
            .appendingPathComponent(delayTestReportFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// The last app-core boot attempt, as timestamped plain-text
    /// lines (GeoSeed outcome per file + boot result), read back
    /// from the file ensureStarted writes. Persisted so it survives
    /// an app restart: the Logs page export includes it, so a GeoIP
    /// download failure (v0.2.33/34) is visible in the file the user
    /// sends instead of living only in a transient banner.
    static func lastBootReportText() -> String? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("ConcordAppCore", isDirectory: true)
            .appendingPathComponent(bootReportFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// Records one boot attempt (GeoSeed outcome + provider-cache
    /// seed outcome + result) to `last-boot-report.txt` in this
    /// core's home dir, for the Logs export. Called on success, on
    /// a GeoSeed failure, and on any other boot failure — so the
    /// file always describes the latest attempt, never a stale one.
    /// FIX 1a (v0.2.45): on success the report also records which
    /// profile was applied, the shared config.yaml's size + mtime,
    /// and how many groups / nodes the core actually loaded — the
    /// three facts that distinguish "stale config.yaml" from "the
    /// core dropped the proxy entries". The extra lines are only
    /// added when their values are known, so failure reports keep
    /// their existing shape. `configRefreshNote` (FIX 2) is passed
    /// on every call, so a heal that precedes a failed boot is
    /// still visible.
    private func recordBootReport(home: URL, seed: GeoSeed.Report, outcome: String, providerSeed: ProviderCacheSeed.Report? = nil, appliedProfileName: String? = nil, configSize: Int? = nil, configMtime: Date? = nil, loadedGroupCount: Int? = nil, loadedNodeCount: Int? = nil, configRefreshNote: String? = nil, logSubscribeNote: String? = nil) {
        let stamp = Self.bootReportTimestamp(Date())
        var lines = ["[\(stamp)] 应用内核心启动"]
        for spec in GeoSeed.files {
            if seed.seeded.contains(spec.fileName) {
                lines.append("GeoSeed \(spec.fileName)：已下载")
            } else if seed.alreadyPresent.contains(spec.fileName) {
                lines.append("GeoSeed \(spec.fileName)：已存在")
            } else if let failure = seed.failures.first(where: { $0.file == spec.fileName }) {
                lines.append("GeoSeed \(spec.fileName)：下载失败：\(failure.error.localizedDescription)")
            } else if seed.skippedByCooldown.contains(spec.fileName) {
                lines.append("GeoSeed \(spec.fileName)：上次失败不久，跳过（\(Int(GeoSeed.cooldownSeconds / 60)) 分钟内不再重试）")
            } else {
                lines.append("GeoSeed \(spec.fileName)：未尝试")
            }
        }
        if let providerSeed {
            if providerSeed.sourceUnavailable {
                lines.append("提供方缓存：App Group 容器不可用，未复制")
            } else {
                if !providerSeed.copied.isEmpty || !providerSeed.alreadyPresent.isEmpty {
                    let shown = providerSeed.copied.prefix(3).joined(separator: "、")
                    let shownSuffix = providerSeed.copied.count > 3 ? "…" : ""
                    let copiedDetail = shown.isEmpty ? "" : "（\(shown)\(shownSuffix))"
                    lines.append("提供方缓存：已复制 \(providerSeed.copied.count) 个\(copiedDetail)，已存在 \(providerSeed.alreadyPresent.count) 个")
                } else if !providerSeed.sourceMissingDirs.isEmpty {
                    let missingDirs = providerSeed.sourceMissingDirs.joined(separator: "、")
                    lines.append("提供方缓存：扩展侧无缓存（\(missingDirs) 均不存在），提供方需联网拉取")
                }
                for failure in providerSeed.failures {
                    lines.append("提供方缓存 \(failure.file)：复制失败：\(failure.error.localizedDescription)")
                }
            }
        } else {
            lines.append("提供方缓存：未尝试")
        }
        if let configRefreshNote {
            lines.append("配置刷新：\(configRefreshNote)")
        }
        if let appliedProfileName {
            lines.append("当前订阅：\(appliedProfileName)")
        }
        if let configSize, let configMtime {
            lines.append("配置文件：config.yaml \(configSize) 字节，修改于 \(Self.bootReportTimestamp(configMtime))")
        }
        if let loadedGroupCount, let loadedNodeCount {
            lines.append("核心已加载：\(loadedGroupCount) 个策略组，\(loadedNodeCount) 个节点")
        }
        if let logSubscribeNote {
            lines.append("日志流：\(logSubscribeNote)")
        }
        lines.append("启动结果：\(outcome)")
        try? lines.joined(separator: "\n").write(
            to: home.appendingPathComponent(Self.bootReportFileName),
            atomically: true, encoding: .utf8)
    }

    private static func bootReportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

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
    static func appHomeDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ConcordAppCore", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The app-private home directory for this core instance.
    private func homeDirectory() throws -> URL {
        try Self.appHomeDirectory()
    }

    /// The shared config.yaml the extension reads at startTunnel
    /// (written by ProfileStore.activate). The app-side core reads
    /// the same file, so the delay test uses the active profile.
    private func sharedConfigURL() -> URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.configFileName)
    }

    private func configSignature(for url: URL) -> String? {
        guard let info = configFileInfo(for: url) else { return nil }
        return "\(info.mtime.timeIntervalSince1970)-\(info.size)"
    }

    /// The shared config.yaml's size + mtime (FIX 1a, boot report).
    /// Nil when the file cannot be statted.
    private func configFileInfo(for url: URL) -> (size: Int, mtime: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else { return nil }
        return (size.intValue, mtime)
    }

    /// Self-heals a stale shared config.yaml before the boot
    /// (FIX 2, v0.2.45): the file this core applies is written by
    /// ProfileStore.applyProfile at profile-switch time, but a
    /// profile can change afterwards (subscription update, local
    /// overrides re-baked) without the shared file being rewritten,
    /// so config.apply can succeed on a file that no longer holds
    /// the active profile's nodes — and every delay.test then
    /// returns -2. Compares the file's bytes with the active
    /// profile's current built bytes (the exact bytes
    /// applyProfile writes, local overrides re-baked) and, when
    /// they differ, rewrites the file with the same atomic write
    /// applyProfile uses. Returns a one-line note for the boot
    /// report when it rewrote the file, nil otherwise. NEVER fails
    /// the boot: no active profile, an unbuildable profile, or a
    /// failed write all return nil and the caller proceeds with
    /// the existing file. The caller recomputes the config
    /// signature from the returned value when it is non-nil.
    private func healStaleSharedConfig(configURL: URL) -> String? {
        guard let store = Self.profileStore,
              let built = store.builtActiveProfileData(),
              let current = try? Data(contentsOf: configURL),
              current != built.data else { return nil }
        do {
            try built.data.write(to: configURL, options: .atomic)
            return "已从当前订阅「\(built.profile.name)」重新生成 config.yaml（旧文件与当前订阅内容不一致）"
        } catch {
            return nil
        }
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
              let initialSignature = configSignature(for: configURL) else {
            throw AppCoreError.noConfig
        }
        var signature = initialSignature
        // FIX 2 (v0.2.45): heal a stale shared config.yaml BEFORE
        // anything reads it — a rewrite changes the signature, so
        // the already-running check below sees the mismatch and
        // restarts the core on the fresh file instead of returning
        // early on the stale one. A nil note means nothing changed
        // (or nothing could be built) and the boot proceeds with
        // the existing file, exactly as before.
        let configRefreshNote = healStaleSharedConfig(configURL: configURL)
        if configRefreshNote != nil {
            signature = configSignature(for: configURL) ?? signature
        }
        let home = try homeDirectory()
        let groupHome = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
        if session != 0 {
            if signature == loadedConfigSignature {
                // The core is already running this exact config — but
                // re-seed the provider cache anyway: the extension
                // may have cached provider files since this core
                // booted (first VPN start). If files that were
                // missing appear now, restart so the provider
                // initial() load (disk-first) picks them up — a
                // running core never re-reads the cache file on its
                // own, so without the restart the next test would
                // keep reporting the same nodes as missing.
                let reseeded = Self.seedProviderCache(appHome: home, groupHome: groupHome)
                if reseeded.copied.isEmpty { return }
            }
            await stop()
        }
        // Heal a one-sided CA before the core boots and reads its CA
        // from disk: if the tunnel generated a CA, this core loads
        // that one instead of creating a divergent one on first MITM
        // use; if this core generated one earlier and the tunnel
        // never got it, the next VPN start finds it. Never overwrites
        // an existing CA on either side, and never fails the boot
        // (best-effort).
        Self.healCAFiles(appHome: home, groupHome: groupHome)
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
            let failure = AppCoreError.geoSeedFailed(reason)
            recordBootReport(home: home, seed: appSeed, outcome: "失败：\(failure.localizedDescription)", configRefreshNote: configRefreshNote)
            throw failure
        }
        // Seed the proxy/rule provider cache (seedProviderCache)
        // BEFORE the core boots: config.apply starts each
        // proxy-provider's initial() load, which reads its cache
        // file from THIS home first and only pulls over the network
        // when nothing is on disk — and a failed pull is non-fatal
        // to apply (upstream provider/mod.rs run(): it only logs a
        // warning), so the config loads with zero provider nodes
        // and every delay.test then returns -2 for a name the core
        // never saw ("not part of the applied config"). The
        // extension core's home (App Group container) already holds
        // the cache from earlier VPN starts; this home is separate
        // and starts empty, so copy it across here.
        let providerSeed = Self.seedProviderCache(appHome: home, groupHome: groupHome)
        // v0.2.49: the log.watch subscribe outcome (for the boot
        // report). Set after core.init below; a second attempt
        // runs after engine.start on the success path.
        var logSubscribeNote: String?
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
            // Subscribe to the app core's log.watch stream HERE,
            // before config.apply (v0.2.49, Issue 2): the
            // subscribe used to happen only after engine.start,
            // so a boot that failed on config.apply never
            // subscribed and the Logs page stayed empty even
            // though the session was up long enough to log the
            // refusal. A second attempt runs after engine.start
            // on the success path (a no-op when this one
            // worked). The outcome is recorded in the boot
            // report instead of swallowed, so the next export
            // says whether the log stream is live.
            logSubscribeNote = await trySubscribeLogWatch()
            // The profile gives proxies / proxy-groups / rules; the
            // overlay carries everything else — here the listener
            // ports, so this instance can never clash with the
            // extension's core or with anything else on the device.
            // geo-auto-update follows the user's Resources setting
            // (default on, 24 h — upstream FlClash 1b2ea11 flipped
            // the default false -> true; an explicitly saved false
            // stays off). Absent UserDefaults key = true:
            // bool(forKey:) returns false for a missing key. The
            // periodic refresh then runs through the core's own TLS
            // client — the same one the campus network rejects
            // (v0.2.33 MMDB failure) — but a failed refresh is
            // log-only in the core (resources.rs GeoUpdater::update
            // logs the error and keeps the old file), so the delay
            // test keeps working on the seeded files. This overlay
            // is app-core-only: the extension core gets the same
            // values from general-overlay.json instead.
            // (There is no overlay key that skips the compile-time
            // MMDB need itself — a GEOIP rule must have the file.
            // GeoSeed above is what removes that need.)
            let geoDefaults = UserDefaults.standard
            let geoAutoUpdate = geoDefaults.object(forKey: "ConcordiOS.geoAutoUpdate") as? Bool ?? true
            let geoUpdateHours = geoDefaults.object(forKey: "ConcordiOS.geoAutoUpdateHours") as? Double ?? 24.0
            let overlay: [String: Any] = [
                "mixed-port": Self.appMixedPort,
                "socks-port": Self.appSocksPort,
                "port": Self.appHTTPPort,
                "external-controller": Self.appController,
                "dns": ["listen": Self.appDNSListen],
                "geo-auto-update": geoAutoUpdate,
                "geo-update-interval": Int(geoUpdateHours),
            ]
            // config.apply is the one boot call whose failure means
            // the core refused the WHOLE config (v0.2.45 case (b)):
            // a missing RULE-SET / proxy provider is a hard error,
            // not a per-node problem, and the engine falls back to
            // a no-proxy default. Re-raise a genuine refusal as
            // .configApplyFailed with the core's exact message, so
            // the banner + boot report say the config was refused
            // instead of the generic "nodes are missing". A timeout
            // or dead session is NOT a refusal (the apply may or
            // may not have completed) and keeps its existing error.
            do {
                _ = try await sendRequest(method: "config.apply", params: [
                    "profile": ["path": configURL.path],
                    "overlay": overlay,
                ], resultType: EmptyResult.self, timeoutSeconds: 60)
            } catch let error as AppCoreError {
                if case .rpcFailed(let message) = error,
                   !message.hasPrefix("调用超时"),
                   message != "核心会话已关闭",
                   message != "会话不存在" {
                    throw AppCoreError.configApplyFailed(message)
                }
                throw error
            }
            _ = try await sendRequest(method: "engine.start", params: [:], resultType: EmptyResult.self, timeoutSeconds: 60)
            // FIX 1a (v0.2.45): record what the core actually
            // loaded, while the session is up — a proxy.groups
            // read here costs one local call and tells the next
            // all--2 diagnosis whether apply loaded zero nodes.
            // A failed read leaves the counts out of the report;
            // the boot itself already succeeded.
            var loadedGroupCount: Int?
            var loadedNodeCount: Int?
            do {
                let groups = try await loadedProxyGroups()
                loadedGroupCount = groups.groups.count
                loadedNodeCount = groups.nodes.count
            } catch {
                loadedGroupCount = nil
                loadedNodeCount = nil
            }
            // Second subscribe attempt (a no-op when the
            // pre-apply one above worked): the stream's snapshot
            // is empty — entries only arrive as events.
            logSubscribeNote = await trySubscribeLogWatch()
            let configInfo = configFileInfo(for: configURL)
            recordBootReport(home: home, seed: appSeed, outcome: "成功", providerSeed: providerSeed,
                             appliedProfileName: Self.profileStore?.activeProfile?.name,
                             configSize: configInfo?.size, configMtime: configInfo?.mtime,
                             loadedGroupCount: loadedGroupCount, loadedNodeCount: loadedNodeCount,
                             configRefreshNote: configRefreshNote, logSubscribeNote: logSubscribeNote)
            loadedConfigSignature = signature
        } catch {
            recordBootReport(home: home, seed: appSeed, outcome: "失败：\(error.localizedDescription)", providerSeed: providerSeed, configRefreshNote: configRefreshNote, logSubscribeNote: logSubscribeNote)
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
            delayRunStash.removeAll()
            logSub = nil
            // v0.2.49: the captured log entries SURVIVE the
            // teardown (the old code wiped them here): a boot
            // that failed on config.apply still logged the
            // refusal, and the Logs page / export should show
            // those lines instead of an empty list. The buffer
            // stays capped at 500 (see accumulateLogItems).
            loadedConfigSignature = nil
        }
    }

    // MARK: Provider cache seeding + loaded-config membership
    //
    // The provider cache lives under the core home (upstream
    // crates/group/src/provider/mod.rs: the cache `path` is
    // confined to shared.home, and initial() reads it from disk
    // before pulling over the network). The extension core's home
    // is the App Group container; this core's home is the
    // app-private ConcordAppCore dir — a different home, so a
    // provider the extension already cached is still missing here
    // on first boot. A missing provider is not fatal to
    // config.apply (its load runs async and only warns), so the
    // config loads with zero provider nodes and every delay.test
    // for one returns -2 with no throw — the silent all-nodes-fail
    // of IMG_1145. Copying the cache across before boot makes
    // initial() load from disk instead of the network.

    /// The outcome of one provider-cache seeding pass, for the
    /// boot report. `copied` / `alreadyPresent` are paths relative
    /// to the home (e.g. providers/subscription.yaml).
    struct ProviderCacheSeed {
        struct Report {
            var copied: [String] = []
            var alreadyPresent: [String] = []
            var sourceMissingDirs: [String] = []
            var failures: [(file: String, error: Error)] = []
            var sourceUnavailable = false
        }

        /// Home-relative dirs holding provider cache files: the
        /// explicit `path:` of http proxy/rule providers
        /// (./providers/…, ./rules/…) and the md5-named cache of
        /// providers without an explicit path (proxies/<md5>).
        static let cacheDirs = ["providers", "rules", "proxies"]
    }

    /// Copies the provider cache (providers/ + rules/ + proxies/)
    /// from the extension core's home (App Group container) into
    /// this core's home, before config.apply. A file is copied
    /// when it is missing here or its CONTENT differs from the
    /// source — the old size+mtime shortcut could keep a stale
    /// copy: the app core's own pulls touch_file() the local copy
    /// on every unchanged update, so it can look newer than the
    /// extension's fresher file while holding older content (same
    /// size, e.g. renamed nodes), and the copy was then skipped.
    /// Content equality is the only safe skip; provider files are
    /// small YAML, so one extra read per file is cheap. Hidden
    /// files and partial temp files are skipped. Best-effort: the
    /// caller still boots when the source has no cache at all (the
    /// core then pulls over the network); the report says so
    /// honestly.
    static func seedProviderCache(appHome: URL, groupHome: URL?) -> ProviderCacheSeed.Report {
        var report = ProviderCacheSeed.Report()
        guard let groupHome else {
            report.sourceUnavailable = true
            return report
        }
        let fm = FileManager.default
        for dir in ProviderCacheSeed.cacheDirs {
            let sourceDir = groupHome.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: sourceDir.path) else {
                report.sourceMissingDirs.append(dir)
                continue
            }
            guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let source as URL in enumerator {
                let name = source.lastPathComponent
                guard !name.hasPrefix("."), !name.contains(".tmp-") else { continue }
                guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = source.path.replacingOccurrences(of: sourceDir.path + "/", with: "\(dir)/")
                let dest = appHome.appendingPathComponent(rel)
                do {
                    let data = try Data(contentsOf: source)
                    if fm.fileExists(atPath: dest.path),
                       let dstData = try? Data(contentsOf: dest),
                       dstData == data {
                        report.alreadyPresent.append(rel)
                        continue
                    }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let temp = dest.deletingLastPathComponent()
                        .appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
                    do {
                        try data.write(to: temp, options: .atomic)
                        if fm.fileExists(atPath: dest.path) {
                            try fm.removeItem(at: dest)
                        }
                        try fm.moveItem(at: temp, to: dest)
                    } catch {
                        try? fm.removeItem(at: temp)
                        throw error
                    }
                    report.copied.append(rel)
                } catch {
                    report.failures.append((file: rel, error: error))
                }
            }
        }
        return report
    }

    /// The proxy + group names the applied config knows
    /// (proxy.groups), for the channel-vs-node diagnosis: a delay
    /// target absent from this set was never loaded (provider not
    /// loaded / name mismatch), so its -2 is a channel failure,
    /// not a dead node. The core must already be started.
    func loadedProxyNames() async throws -> Set<String> {
        let groups = try await loadedProxyGroups()
        var names = Set(groups.nodes.map { $0.name })
        names.formUnion(groups.groups.map { $0.name })
        return names
    }

    /// The full proxy.groups response behind loadedProxyNames —
    /// ProxyStore builds its per-provider inventory from it
    /// (nodes carry their provider), so the "names still missing"
    /// banner can name what each provider actually holds. The
    /// core must already be started.
    func loadedProxyGroups() async throws -> ConcordProxyGroups {
        try await sendRequest(method: "proxy.groups", params: [:], resultType: ConcordProxyGroups.self, timeoutSeconds: 15)
    }

    // MARK: Delay test

    /// One node's delay (delay.test). The core must already be
    /// started (ensureStarted); a transport failure throws and the
    /// caller must NOT record it as a node failure. The timeout
    /// defaults to 8000ms (FlClash defaultDelayTestTimeout; audit
    /// B1 — the core default is 5000ms, which times out nodes
    /// FlClash still reports); callers pass it explicitly too.
    func delayTest(proxy: String, url: String? = nil, timeout: UInt64? = 8000) async throws -> ConcordDelayResult {
        var params: [String: Any] = ["proxy": proxy]
        if let url { params["url"] = url }
        if let timeout { params["timeout"] = timeout }
        return try await sendRequest(method: "delay.test", params: params, resultType: ConcordDelayResult.self)
    }

    /// Starts a batch delay test (delay.run, a stream). The reply
    /// is the subscription ({sub, snapshot}); the results arrive as
    /// events the core accumulates here — poll them with
    /// delayRunPoll(). The run ends by itself with a `done` event.
    /// The timeout defaults to 8000ms (FlClash
    /// defaultDelayTestTimeout; audit B1).
    func delayRunStart(proxies: [String], url: String? = nil, timeout: UInt64? = 8000, concurrency: UInt32? = nil) async throws -> DelayRunStart {
        var params: [String: Any] = ["proxies": proxies]
        if let url { params["url"] = url }
        if let timeout { params["timeout"] = timeout }
        if let concurrency { params["concurrency"] = concurrency }
        let start = try await sendRequest(method: "delay.run", params: params, resultType: DelayRunStart.self)
        // Register the accumulator SYNCHRONOUSLY on coreQueue and
        // replay any batches that arrived before registration (see
        // delayRunStash): the old `coreQueue.async` assignment left
        // a window in which fast-failing results and the done event
        // were dropped, stalling the poll loop for the full 60 s.
        coreQueue.sync {
            self.delayRun = DelayRunAccumulator(sub: start.sub)
            let stashed = self.delayRunStash.filter { $0.sub == start.sub }
            self.delayRunStash.removeAll { $0.sub == start.sub }
            for batch in stashed {
                self.accumulateDelayItems(batch.items)
            }
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

    // MARK: App-core log stream (Issue 2)
    //
    // The Logs page used to read ONLY the extension's log.watch
    // snapshot file, so with the VPN off the list was always empty
    // even though this core was up and logging (IMG_1162: boot
    // report 10:02:33 "成功", live list empty). The app core gets
    // the same subscribe-once + accumulate pattern the extension
    // uses (PacketTunnelProvider.subscribeToStreams): one log.watch
    // subscription per session, events accumulate in logBuffer,
    // one unit of credit refilled per batch consumed.

    /// The log.watch subscribe reply ({sub, snapshot: {}}).
    private struct StreamSubscribeResult: Decodable {
        let sub: Int
    }

    /// Subscribes to the app core's log.watch stream (once per
    /// session; best-effort — a failure just leaves the Logs page
    /// without live entries, it never fails the boot). Called from
    /// ensureStarted after engine.start, and lazily from
    /// LogStore.refresh when the session is up but no sub exists.
    func subscribeLogWatch() async throws {
        guard session != 0 else { return }
        if logSub != nil { return }
        let start = try await sendRequest(method: "log.watch", params: ["credit": 8], resultType: StreamSubscribeResult.self, timeoutSeconds: 60)
        // Register the sub SYNCHRONOUSLY on coreQueue and replay
        // any batches that arrived before registration (same race
        // as delay.run — see delayRunStash). The nil-check inside
        // the sync is the real guard: two concurrent subscribes
        // (boot + a Logs-page refresh) both send the request, but
        // only the first registration wins — the loser's sub is
        // ignored, so its events never double-accumulate.
        coreQueue.sync {
            guard self.logSub == nil else { return }
            self.logSub = start.sub
            let stashed = self.delayRunStash.filter { $0.sub == start.sub }
            self.delayRunStash.removeAll { $0.sub == start.sub }
            for batch in stashed {
                self.accumulateLogItems(batch.items)
            }
        }
    }

    /// Best-effort log.watch subscribe that reports its outcome
    /// instead of swallowing it (v0.2.49): the Logs page needs to
    /// know whether the stream is live, and a silent failure used
    /// to leave it empty with no explanation. "已订阅" when a sub
    /// already exists, too (subscribeLogWatch is a no-op then).
    private func trySubscribeLogWatch() async -> String {
        do {
            try await subscribeLogWatch()
            return "已订阅"
        } catch {
            return "订阅失败：\(error.localizedDescription)"
        }
    }

    /// The accumulated app-core log entries (empty when the session
    /// is down or the stream was never subscribed). Reads the
    /// buffer on coreQueue (it is written there).
    func logEntries() async -> [ConcordLogEntry] {
        await withCheckedContinuation { continuation in
            coreQueue.async {
                continuation.resume(returning: self.logBuffer)
            }
        }
    }

    /// core.lastWarnings on the app-side core (same shape as the
    /// client's: {warnings: [ConcordWarning]}).
    func lastWarnings() async throws -> [ConcordWarning] {
        struct WarningsResult: Decodable { let warnings: [ConcordWarning] }
        return try await sendRequest(method: "core.lastWarnings", params: [:], resultType: WarningsResult.self).warnings
    }

    // MARK: Providers (B2 second version)

    /// Updates one proxy provider (provider.update) on the app-side
    /// core, for the delay-test preload (ProxyStore
    /// ensureProvidersLoaded): pulls the provider's content and
    /// swaps its node set live — upstream crates/group/src/
    /// provider/mod.rs update() -> pull() -> load_buf() ->
    /// apply() does nodes.store + route.moved +
    /// request_refresh(), so NO config.apply is needed afterwards.
    /// 60 s: a subscription pull over the user's network can be
    /// slow; a tight timeout would fail the preload on a
    /// slow-but-working network. Throws the core's reason verbatim
    /// (download failure, timeout, already-updating), which the
    /// caller puts in the banner.
    func providerUpdate(name: String) async throws {
        _ = try await sendRequest(method: "provider.update", params: ["name": name], resultType: EmptyResult.self, timeoutSeconds: 60)
    }

    /// Lists the providers the app-side core knows (provider.list),
    /// for the preload fallback: when no group row attributes a
    /// missing node to a provider, every provider is updated and
    /// the names are re-checked. A local read, so the 15 s default
    /// stands.
    func providerList() async throws -> ConcordProviderList {
        try await sendRequest(method: "provider.list", params: [:], resultType: ConcordProviderList.self, timeoutSeconds: 15)
    }

    /// Validates the shared config.yaml with this core
    /// (config.validate, FIX 1b v0.2.45). Same method + params as
    /// ConcordClient.configValidate, but on the app-side core's
    /// own session — the extension core is unreachable while the
    /// VPN is off, which is exactly when the delay test needs it.
    /// Like the client's version, the core only parses the file,
    /// so the result is at most one issue: the parse error as a
    /// plain message. Throws when the core is unreachable or the
    /// shared config is missing; the caller treats that as "no
    /// hint" and never breaks the delay-test flow for it.
    func configValidate() async throws -> [ConcordIssue] {
        guard let configURL = sharedConfigURL() else {
            throw AppCoreError.noConfig
        }
        return try await configValidate(profilePath: configURL.path)
    }

    /// Validates an arbitrary profile file with the core
    /// (config.validate) — the repair-all loop (v0.2.49) validates
    /// candidate configs this way instead of only the shared one.
    /// Needs a live session; use ensureValidationSession() first
    /// when the boot itself failed (no session). The core only
    /// parses the file, so the result is at most one issue.
    func configValidate(profilePath: String) async throws -> [ConcordIssue] {
        return try await sendRequest(method: "config.validate", params: [
            "profile": ["path": profilePath],
        ], resultType: ConcordConfigValidateResult.self, timeoutSeconds: 15).issues
    }

    /// Opens a bare app-core session (hello + init, NO
    /// config.apply / engine.start) for config.validate calls
    /// (v0.2.49 repair-all loop): when the active config is
    /// broken, ensureStarted tears the session down, so there is
    /// no session to validate with — but validate only parses a
    /// file and never needs the broken config applied. A session
    /// that is already up is reused; the session stays up
    /// afterwards (the next ensureStarted sees the signature
    /// mismatch and restarts it on the repaired config). Throws
    /// when the core cannot start or hello/init fail.
    @MainActor
    func ensureValidationSession() async throws {
        guard !TunnelManager.shared.isRunning else {
            throw AppCoreError.tunnelRunning
        }
        if session != 0 { return }
        let home = try homeDirectory()
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
            _ = try await sendRequest(method: "core.hello", params: [
                "protocol": ["min": 1, "max": 1],
                "client": ["name": "concord-ios", "version": "0.2.0"],
            ], resultType: EmptyResult.self, timeoutSeconds: 60)
            _ = try await sendRequest(method: "core.init", params: [
                "home": home.path,
            ], resultType: EmptyResult.self, timeoutSeconds: 60)
        } catch {
            let hadSession = session != 0
            tearDown()
            if !hadSession {
                Unmanaged<AppCore>.fromOpaque(context).release()
            }
            throw error
        }
    }

    // MARK: MITM CA (v0.2.35 Item C)

    /// Generates the MITM CA via the in-app core
    /// (mitm.generateCertificate). The core must already be started
    /// (ensureStarted); used by MitmCertificateView when the VPN is
    /// off, so CA generation no longer needs the tunnel. Returns
    /// the certificate info the core reports — a nil certificate
    /// means the core answered without one, and the caller must not
    /// report success in that case.
    func mitmGenerateCertificate() async throws -> ConcordMitmCertificate {
        try await sendRequest(method: "mitm.generateCertificate", params: [:], resultType: ConcordMitmCertificate.self, timeoutSeconds: 60)
    }

    /// Issues a leaf certificate for one host via the in-app core
    /// (mitm.issueCertificate) — the AppCore side of audit B38:
    /// MitmCertificateView's trust check and
    /// SettingsStore.issueMitmCertificate use this when the VPN is
    /// off, instead of reporting that no such wrapper exists. Same
    /// shape as mitmGenerateCertificate; the core must already be
    /// started (ensureStarted).
    func mitmIssueCertificate(host: String) async throws -> ConcordMitmPem {
        try await sendRequest(method: "mitm.issueCertificate", params: ["host": host], resultType: ConcordMitmPem.self, timeoutSeconds: 60)
    }

    // MARK: DNS tools (audit B16)
    //
    // dns.query / dns.clearCache / dns.flushFakeIp via the in-app
    // core, so the DNS tools work with the VPN off. The core must
    // already be started (ensureStarted). The query history
    // (refresh/dns.watch) still comes from the extension snapshot
    // only — it has no AppCore equivalent.

    func dnsQuery(name: String, qtype: String? = nil) async throws -> ConcordDnsQueryResult {
        var params: [String: Any] = ["name": name]
        if let qtype { params["qtype"] = qtype }
        return try await sendRequest(method: "dns.query", params: params, resultType: ConcordDnsQueryResult.self, timeoutSeconds: 15)
    }

    func dnsClearCache() async throws {
        _ = try await sendRequest(method: "dns.clearCache", params: [:], resultType: EmptyResult.self, timeoutSeconds: 15)
    }

    func dnsFlushFakeIp() async throws {
        _ = try await sendRequest(method: "dns.flushFakeIp", params: [:], resultType: EmptyResult.self, timeoutSeconds: 15)
    }

    // MARK: - MITM CA sync (v0.2.35 Item C follow-up)
    //
    // The CA lives as files in the core home (<home>/mitm/ca.crt +
    // ca.key; upstream crates/mitm/src/ca.rs: AUTHORITY_DIR "mitm",
    // CERT_FILE_NAME "ca.crt", KEY_FILE_NAME "ca.key", key written
    // 0600). The in-app core's home (Library/Application
    // Support/ConcordAppCore) and the extension core's home (the App
    // Group container root) are DIFFERENT homes, so a CA generated
    // VPN-off by this core is invisible to the tunnel core: at the
    // next VPN start the tunnel core would find no CA and generate a
    // DIFFERENT one, which would not match the CA the user installed
    // and trusted in Settings — MITM would silently break. So after
    // a VPN-off generation the CA files are copied into the App Group
    // container (syncGeneratedCAToTunnel, called by
    // MitmCertificateView), and ensureStarted heals a one-sided CA
    // the same way. The rule in both directions: fill only MISSING
    // files, NEVER overwrite an existing CA on either side — if both
    // sides already have a CA (even if they differ) both are left
    // alone; there is no safe way to guess which one the user
    // installed and trusted, so the caller must say so honestly
    // instead of claiming the tunnel will use the new CA.

    /// The CA file names inside <home>/mitm (see the section
    /// comment). Copied key first, then cert — upstream
    /// generate_ca writes in that order too, so a present cert
    /// implies a present key.
    private static let caDirectoryName = "mitm"
    private static let caCertFileName = "ca.crt"
    private static let caKeyFileName = "ca.key"
    private static let caFileNames = [caKeyFileName, caCertFileName]

    /// The stale CA file names the FlClash fork deletes before
    /// regenerating (WWW-MuYu-Love/FlClash ac90aebb): the cert and
    /// key, plus their .bak variants. The pinned core itself never
    /// writes .bak files — generate_ca (crates/mitm/src/ca.rs)
    /// writes ca.key then ca.crt atomically and replaces any
    /// existing pair — but deleting the .bak names too costs
    /// nothing and matches the fork.
    private static let staleCAFileNames = caFileNames + ["ca.crt.bak", "ca.key.bak"]

    /// What deleting the old CA files before a regenerate did.
    /// Non-throwing by design: a deletion failure must not abort
    /// the regenerate (the core overwrites the generating home on
    /// its own), but the caller must report it in the status
    /// message instead of claiming a clean regenerate.
    struct OldCADeletion {
        /// "应用内 ca.crt" style names of files actually removed.
        var deleted: [String] = []
        /// Human-readable failures, e.g. "隧道 ca.key：权限不足".
        var failures: [String] = []
        var hasFailures: Bool { !failures.isEmpty }
    }

    /// Deletes the old CA files from BOTH core homes — this core's
    /// home and the App Group container (the tunnel core's home) —
    /// before a regenerate (FlClash fork ac90aebb). The core
    /// overwrites the generating home on its own, so the deletion
    /// matters for the OTHER home: without it, a VPN-off
    /// regenerate would leave the tunnel's old CA in place and
    /// syncGeneratedCAToTunnel (fill only MISSING, never
    /// overwrite) would refuse to replace it, so the next VPN
    /// start would use the old CA while the user installed and
    /// trusted the new one — and vice versa for a VPN-on
    /// regenerate, where the app home would keep the stale CA for
    /// VPN-off trust checks. Never throws; check `failures`.
    static func deleteOldCAFiles() -> OldCADeletion {
        var result = OldCADeletion()
        let homes: [(label: String, url: URL?)] = [
            ("应用内", try? appHomeDirectory()),
            ("隧道", FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)),
        ]
        for (label, home) in homes {
            guard let home else {
                result.failures.append("\(label)核心目录不可用，旧 CA 未能删除")
                continue
            }
            let dir = home.appendingPathComponent(caDirectoryName, isDirectory: true)
            for name in staleCAFileNames {
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    result.deleted.append("\(label) \(name)")
                } catch {
                    result.failures.append("\(label) \(name)：\(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// What syncing a freshly generated CA into the tunnel home did.
    /// `.synced` is the only outcome where the tunnel will use this
    /// CA; the other two mean the tunnel keeps (or may generate) a
    /// different CA, and the caller must say so in the status
    /// message instead of claiming full success.
    enum GeneratedCASync {
        /// The tunnel home now holds a complete copy of this CA
        /// (the listed files were copied).
        case synced([String])
        /// The tunnel home already held both CA files, so nothing
        /// was copied and the tunnel keeps its own CA.
        case tunnelAlreadyHadCA
        /// This core's home holds no CA files to copy.
        case nothingToSync
    }

    /// Copies this core's freshly generated CA into the App Group
    /// container (the tunnel core's home), so the next VPN start
    /// loads the SAME CA the user is about to install and trust
    /// instead of generating a different one. Throws when the App
    /// Group container is unavailable or the copy fails / leaves
    /// the tunnel CA incomplete — the caller must report that
    /// honestly and must NOT claim full success.
    func syncGeneratedCAToTunnel() throws -> GeneratedCASync {
        let appHome = try homeDirectory()
        guard let groupHome = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            throw AppCoreError.caSyncFailed("App Group 容器不可用")
        }
        let copied = try Self.fillMissingCAFiles(from: appHome, to: groupHome)
        if copied.isEmpty {
            return Self.caFilesPresent(in: groupHome) ? .tunnelAlreadyHadCA : .nothingToSync
        }
        guard Self.caFilesPresent(in: groupHome) else {
            throw AppCoreError.caSyncFailed("隧道里的 CA 文件仍不完整")
        }
        return .synced(copied)
    }

    /// Best-effort, never throws: fills a missing CA on either side
    /// from the other side, so a CA generated by one core is visible
    /// to the other. Called at the top of ensureStarted, before the
    /// core boots and reads its CA from disk. Never overwrites an
    /// existing CA on either side (see the section comment); a
    /// failure here must never fail the boot — the next VPN start /
    /// generation retries it, and the tunnel reports the core's own
    /// error if its CA is still missing.
    static func healCAFiles(appHome: URL, groupHome: URL?) {
        guard let groupHome else { return }
        try? fillMissingCAFiles(from: appHome, to: groupHome)
        try? fillMissingCAFiles(from: groupHome, to: appHome)
    }

    /// True when both CA files exist in `home`.
    private static func caFilesPresent(in home: URL) -> Bool {
        caFileNames.allSatisfy { name in
            FileManager.default.fileExists(atPath: home
                .appendingPathComponent(caDirectoryName, isDirectory: true)
                .appendingPathComponent(name).path)
        }
    }

    /// Copies each CA file present in `sourceHome` but missing in
    /// `destHome`. Per file, never overwriting: an existing file in
    /// the destination — even a different CA — is left alone.
    /// Returns the names copied.
    @discardableResult
    private static func fillMissingCAFiles(from sourceHome: URL, to destHome: URL) throws -> [String] {
        var copied: [String] = []
        for name in caFileNames {
            let source = sourceHome
                .appendingPathComponent(caDirectoryName, isDirectory: true)
                .appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destDir = destHome.appendingPathComponent(caDirectoryName, isDirectory: true)
            let dest = destDir.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            // Atomic copy, mirroring GeoSeed.install: a partial file
            // must never look like a present file (the core reads the
            // CA on load).
            let temp = destDir.appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
            do {
                try Data(contentsOf: source).write(to: temp, options: .atomic)
                do {
                    try FileManager.default.moveItem(at: temp, to: dest)
                } catch {
                    // Another writer (app + extension racing the same
                    // App Group home) got there first: its file wins.
                    try? FileManager.default.removeItem(at: temp)
                    guard FileManager.default.fileExists(atPath: dest.path) else { throw error }
                    continue
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            // The core keeps the key owner-only (0600); a copy via
            // Data would otherwise land 0644. Best-effort: a wrong
            // mode must not fail the sync.
            if name == caKeyFileName {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: dest.path)
            }
            copied.append(name)
        }
        return copied
    }

    // MARK: JSON-RPC plumbing (mirrors PacketTunnelProvider)

    private func sendRequest<Result: Decodable>(method: String, params: [String: Any], resultType: Result.Type, timeoutSeconds: TimeInterval = 15) async throws -> Result {
        let data = try await sendRawJSONRPC(["method": method, "params": params], timeoutSeconds: timeoutSeconds)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppCoreError.rpcFailed("核心返回了无法解析的响应（\(method)）")
        }
        if let error = object["error"] as? [String: Any] {
            // Cold-start race (WWW-MuYu-Love/FlClash 12aa5f6f):
            // code -32603 + message `config is not applied` means
            // the call raced ahead of config.apply. Only this
            // exact pair maps to .configNotApplied; every other
            // error keeps the old rpcFailed path verbatim.
            let code = (error["code"] as? NSNumber)?.intValue
            let message = (error["message"] as? String) ?? "未知错误（\(method)）"
            if code == -32603 && message == "config is not applied" {
                throw AppCoreError.configNotApplied
            }
            throw AppCoreError.rpcFailed(message)
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
              let items = params["data"] as? [Any] else { return }
        if delayRun?.sub == sub {
            accumulateDelayItems(items)
            return
        }
        if logSub == sub {
            accumulateLogItems(items)
            return
        }
        // No run registered for this sub yet — the delay.run reply
        // has not reached delayRunStart's registration (see
        // delayRunStash). Stash the batch instead of dropping it;
        // anything else (a stale run's late batch) is bounded and
        // discarded on the next registration.
        if delayRunStash.count < 64 {
            delayRunStash.append((sub: sub, items: items))
        }
    }

    /// Applies one batch of delay.run events ({type: "result",
    /// name, url, value} and a final {type: "done"}) to the
    /// registered run. Runs on coreQueue. Refills one unit of
    /// credit per batch consumed, like the extension; without it
    /// the server pump stops after the initial credit.
    private func accumulateDelayItems(_ items: [Any]) {
        guard var run = delayRun else { return }
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
        sendNotification(method: "$/credit", params: ["sub": run.sub, "n": 1])
    }

    /// Applies one batch of log.watch events (LogEntry {level,
    /// time, text}) to the buffer. Runs on coreQueue. Refills one
    /// unit of credit per batch consumed, like the extension;
    /// without it the server pump stops after the initial credit
    /// (WatchOptions.credit = 8).
    private func accumulateLogItems(_ items: [Any]) {
        for item in items {
            guard let dict = item as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let entry = try? JSONDecoder().decode(ConcordLogEntry.self, from: data) else { continue }
            logBuffer.append(entry)
        }
        if logBuffer.count > 500 {
            logBuffer.removeFirst(logBuffer.count - 500)
        }
        if let sub = logSub {
            sendNotification(method: "$/credit", params: ["sub": sub, "n": 1])
        }
    }
}
