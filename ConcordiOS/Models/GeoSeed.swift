import Foundation

// MARK: - GeoSeed: pre-seed the core's geo databases with URLSession
//
// Why this exists (v0.2.33, IMG_1132): the delay test failed in
// config.apply with "can't download MMDB: invalid peer certificate:
// ... certificate verify failed: UnknownIssuer". The core downloads
// a missing geo database itself, over its own TLS client (rustls,
// upstream crates/engine/src/resources.rs GeoUpdater::download_missing
// via TunnelFetcher), and that client rejects the campus network's
// MITM certificate. URLSession uses the iOS system trust store
// instead, so the same file downloads here where the core's cannot.
//
// What the core needs (upstream crates/config/src/keys.rs
// geox_defaults, crates/rules/src/geo/mod.rs GeoStore):
//   geoip.metadb  <- https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
//   GeoSite.dat   <- .../latest/geosite.dat
//   ASN.mmdb      <- .../latest/GeoLite2-ASN.mmdb
// The files live directly in the core home dir (the dir passed to
// core.init; upstream crates/engine/src/engine.rs sets the GeoStore
// dir to home.root()). GeoStore::path matches the names above
// case-insensitively, so these exact default names are what to write.
//
// When the download happens (upstream crates/engine/src/apply.rs
// compile_program): ONLY when a rule needs a file that is missing
// (GEOIP rules need the MMDB — every generated config has
// "GEOIP,CN,DIRECT" — GEOSITE rules need GeoSite.dat) or invalid,
// and then the failure is FATAL to config.apply. A file already on
// disk is loaded from disk and no download runs at all, so seeding
// once is enough. IP-ASN rules are different: a missing ASN.mmdb is
// deferred (fetched in the background after apply answers), so ASN
// is never what fails a boot — it is seeded here anyway so the
// background fetch never has to run. Auto-update is off by default
// (upstream General.geo_auto_update = false) and only re-downloads
// files already in use, so seeded files are not replaced behind
// our back.
//
// Both cores are seeded: the app core's home (AppCore.ensureStarted,
// app-private) and the extension core's home (the App Group
// container root, PacketTunnelProvider.bootCore — and, opportunistically,
// from the app process too, so a VPN start finds the files already
// there). No TLS verification is disabled anywhere: URLSession
// validates the server certificate against the system trust store,
// exactly as Safari would; if that fails too, the failure is
// reported honestly instead of faking a latency.
//
// This file is Foundation-only and is compiled into BOTH targets
// (ConcordiOS app + PacketTunnel extension); it references no
// app-only type, so the same file can be registered in both.

enum GeoSeed {

    /// One geo database: the file name the core looks for on disk
    /// and the URL the core itself would download it from.
    struct Spec {
        let fileName: String
        let url: URL
    }

    /// The three geo files, in the order that matters: the MMDB
    /// first (it is the one that fails config.apply), then GeoSite
    /// (also fatal when a GEOSITE rule needs it), then ASN
    /// (deferred, never fatal — seeded for completeness).
    static let files: [Spec] = [
        Spec(fileName: "geoip.metadb", url: URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb")!),
        Spec(fileName: "GeoSite.dat", url: URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat")!),
        Spec(fileName: "ASN.mmdb", url: URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb")!),
    ]

    /// The file config.apply cannot live without (GEOIP,CN,DIRECT).
    static let mmdbFileName = "geoip.metadb"

    /// A download that fails is not retried for this long (a file in
    /// the home dir records the retry-after time). Without it, every
    /// VPN start / delay-test tap on a network where the download
    /// cannot succeed would burn a full set of timeouts first.
    static let cooldownSeconds: TimeInterval = 600

    /// Loose sanity floor for a downloaded database: catches empty
    /// bodies and HTML error/block pages without pretending to know
    /// the exact size of each database. The core itself validates
    /// the bytes on load (upstream GeoStore::validate), so a bad file
    /// that slips past here is still rejected honestly at apply.
    static let minimumBytes = 100_000

    private static let cooldownFileName = ".geo-seed-cooldown"

    struct Failure {
        let file: String
        let error: Error
    }

    struct Report {
        var seeded: [String] = []
        var alreadyPresent: [String] = []
        var failures: [Failure] = []
        /// Files not attempted because a recent failure is still in
        /// its cool-down window.
        var skippedByCooldown: [String] = []
    }

    static func isPresent(_ fileName: String, in home: URL) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(fileName).path)
    }

    /// Downloads every missing geo file into `home` (the core home
    /// dir). Files already on disk are left alone — including stale
    /// ones; GeoIP staleness is harmless for routing and the delay
    /// test, and the core's own auto-update (when the profile
    /// enables it) refreshes them later. Best-effort by design: the
    /// caller decides what a missing file means (AppCore throws a
    /// geoSeedFailed with the real reason; the extension proceeds
    /// and lets config.apply report the core's own error).
    static func ensureGeoFiles(in home: URL, perFileTimeout: TimeInterval = 30) async -> Report {
        var report = Report()
        let missing = files.filter { !isPresent($0.fileName, in: home) }
        for spec in files where isPresent(spec.fileName, in: home) {
            report.alreadyPresent.append(spec.fileName)
        }
        guard !missing.isEmpty else { return report }
        if let retryAfter = cooldownRetryAfter(in: home), retryAfter > Date() {
            report.skippedByCooldown = missing.map(\.fileName)
            return report
        }
        var anyFailure = false
        for spec in missing {
            do {
                try await download(spec, to: home, timeout: perFileTimeout)
                report.seeded.append(spec.fileName)
            } catch {
                anyFailure = true
                report.failures.append(Failure(file: spec.fileName, error: error))
            }
        }
        if anyFailure {
            writeCooldown(in: home)
        } else {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(cooldownFileName))
        }
        return report
    }

    // MARK: - Download

    private enum SeedError: LocalizedError {
        case badStatus(Int)
        case htmlResponse
        case tooSmall(Int)

        var errorDescription: String? {
            switch self {
            case .badStatus(let status):
                return "服务器返回 HTTP \(status)"
            case .htmlResponse:
                return "服务器返回了网页而不是数据库文件"
            case .tooSmall(let bytes):
                return "下载的文件只有 \(bytes) 字节，不完整"
            }
        }
    }

    private static func download(_ spec: Spec, to home: URL, timeout: TimeInterval) async throws {
        // Ephemeral session: no cache (a cached error page must never
        // pose as a database), default trust evaluation against the
        // iOS system trust store — nothing here skips certificate
        // checks. The resource timeout bounds a stalled download.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: spec.url)
        guard let http = response as? HTTPURLResponse else {
            throw SeedError.badStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SeedError.badStatus(http.statusCode)
        }
        if http.mimeType == "text/html" {
            throw SeedError.htmlResponse
        }
        guard data.count >= minimumBytes else {
            throw SeedError.tooSmall(data.count)
        }
        // Atomic write: a partial download must never look like a
        // present file (the core mmaps the file read-only on load, so
        // it must be complete before it appears at its real name).
        let temp = home
            .appendingPathComponent(".geo-seed-\(spec.fileName).tmp-\(UUID().uuidString)")
        let dest = home.appendingPathComponent(spec.fileName)
        do {
            try data.write(to: temp, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
            } catch {
                // Another seeder (app + extension racing the same
                // App Group home) got there first: its file wins.
                try? FileManager.default.removeItem(at: temp)
                if !isPresent(spec.fileName, in: home) { throw error }
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: - Cool-down marker

    private static func cooldownRetryAfter(in home: URL) -> Date? {
        guard let text = try? String(
            contentsOf: home.appendingPathComponent(cooldownFileName), encoding: .utf8),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    private static func writeCooldown(in home: URL) {
        let retryAfter = Date().addingTimeInterval(cooldownSeconds).timeIntervalSince1970
        try? String(retryAfter).write(
            to: home.appendingPathComponent(cooldownFileName),
            atomically: true, encoding: .utf8)
    }
}
