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
        case .geoSeedFailed(let message):
            return "GeoIP 数据库下载失败：\(message)（测速需要 geoip.metadb，核心自带的下载在当前网络下同样失败；请检查网络后重试）"
        case .caSyncFailed(let message):
            return "CA 同步到隧道失败：\(message)"
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
    private func recordBootReport(home: URL, seed: GeoSeed.Report, outcome: String, providerSeed: ProviderCacheSeed.Report? = nil) {
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
            recordBootReport(home: home, seed: appSeed, outcome: "失败：\(failure.localizedDescription)")
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
            recordBootReport(home: home, seed: appSeed, outcome: "成功", providerSeed: providerSeed)
            loadedConfigSignature = signature
        } catch {
            recordBootReport(home: home, seed: appSeed, outcome: "失败：\(error.localizedDescription)", providerSeed: providerSeed)
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
    /// this core's home, before config.apply. Only files that are
    /// missing here, or older/smaller than the source, are copied
    /// — a newer file here (e.g. written by this core's own pull)
    /// is never downgraded. Hidden files and partial temp files
    /// are skipped. Best-effort: the caller still boots when the
    /// source has no cache at all (the core then pulls over the
    /// network); the report says so honestly.
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
            guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let source as URL in enumerator {
                let name = source.lastPathComponent
                guard !name.hasPrefix("."), !name.contains(".tmp-") else { continue }
                guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = source.path.replacingOccurrences(of: sourceDir.path + "/", with: "\(dir)/")
                let dest = appHome.appendingPathComponent(rel)
                do {
                    if fm.fileExists(atPath: dest.path),
                       let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
                       let dstAttrs = try? fm.attributesOfItem(atPath: dest.path),
                       let srcSize = srcAttrs[.size] as? NSNumber,
                       let dstSize = dstAttrs[.size] as? NSNumber,
                       let srcDate = srcAttrs[.modificationDate] as? Date,
                       let dstDate = dstAttrs[.modificationDate] as? Date,
                       dstSize.intValue == srcSize.intValue, dstDate >= srcDate {
                        report.alreadyPresent.append(rel)
                        continue
                    }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try Data(contentsOf: source)
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
        let groups = try await sendRequest(method: "proxy.groups", params: [:], resultType: ConcordProxyGroups.self, timeoutSeconds: 15)
        var names = Set(groups.nodes.map { $0.name })
        names.formUnion(groups.groups.map { $0.name })
        return names
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
              let items = params["data"] as? [Any] else { return }
        if delayRun?.sub == sub {
            accumulateDelayItems(items)
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
}
