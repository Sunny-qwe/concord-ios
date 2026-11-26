import Foundation

// MARK: - App-side service probe (v0.2.127)
//
// The service sheet (服务状态) opens but stays empty because
// probe.services is a unary JSON-RPC method that can only travel
// via the app→extension RPC channel, and that channel is dead
// channel-wide (log-confirmed: every sendProviderMessage returns
// nil / TunnelError code 4 while the tunnel is connected; the
// extension's handler exists but the messages never arrive).
// The core's HTTP controller (127.0.0.1:9090, default OFF) has no
// probe.services route and no generic JSON-RPC endpoint, App Group
// snapshots carry no services file, and the in-app core cannot run
// alongside the tunnel (same fixed ports) — so the only fix is to
// replicate the 13 service checks inside the app, through the
// core's local mixed proxy 127.0.0.1:17890. This is the same
// pattern as the v0.2.125 IP probe (which worked on-device first
// try): URLSession through the proxy, rules-routed by the core.
//
// The checkers below are a faithful port of the pinned core
// (crates/engine/src/probe/services.rs + rules.rs + fetch.rs +
// region.rs, core 33904ff): same 13 services in the same order,
// same URLs, same per-request timeout (10 s), same concurrency
// (4), same retry-once-on-timeout inside a 60 s sweep budget,
// same body caps (16 KiB small / 512 KiB HTML / 8 MiB scan with
// early termination), same status mapping (200–299 available;
// 401/403/429/451 restricted; else unavailable), same region
// normalisation (alpha-3 → alpha-2 via the core's ISO 3166
// table), same verdict strings ("available", "blocked",
// "restricted", "timeout", "failed", … — the contract with the
// Dart UI, services.rs).
//
// Accepted losses (documented, not hidden):
// - Forced-proxy semantics become rules-routing: the core's probe
//   pins each check to the selected outbound, while these requests
//   arrive at the mixed port as inbound connections and are routed
//   by the rules. For the services themselves this is arguably
//   more accurate (it is the route the app's own traffic takes),
//   and the selected outbound still shows as the node line.
// - Drift risk on a future core rebase: if the core's rules.rs
//   changes a URL or a verdict, this file must be re-checked
//   against it.
// - The Disney+ Bearer token below is the public browser client
//   token the core ships (rules.rs DISNEY_AUTH — "the public
//   browser client token Disney+ hands to any web visitor"); it
//   may rotate, and if it does the Disney+ check fails until the
//   token is refreshed from the core.
// - `chains` is [proxy] (the selected outbound's name) rather
//   than the core's dial chain, `hits` is empty and `ip` is nil:
//   the pinned core never sets `ip` on service items either, and
//   nothing in the sheet reads `hits` — but the node line needs a
//   non-empty first chain (DashboardSheets nodeLine returns "—"
//   otherwise), so the selected outbound stands in for it.
// - epoch / route-version are 0: the core's route stamp is not
//   visible through the local proxy (the v0.2.125 IP probe does
//   the same), and ServiceProbeStore's route-version tracking is
//   out of scope anyway.

/// One line per service check + a sweep summary, kept in
/// UserDefaults (last 16 lines) like IPLookupDiagnostics, and
/// included in LogStore.fullExportText so a service sheet that
/// stays empty ships its cause in the log export.
struct ServiceProbeDiagnostics {
    private static let storageKey = "concord.serviceProbeDiagnostics"
    private static let maxLines = 16

    static func record(_ line: String) {
        var lines = UserDefaults.standard.string(forKey: storageKey)
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        lines.append("[\(timestamp())] \(line)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: storageKey)
    }

    static func lastDiagnosticText() -> String? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
              !text.isEmpty else { return nil }
        return text
    }

    /// "source: <localizedDescription> (<domain> code <code>)" —
    /// the (domain, code) is what tells a DNS failure
    /// (NSURLErrorCannotFindHost, -1003) apart from a timeout
    /// (-1001) or a refused connection (-1004).
    static func recordError(source: String, error: Error) {
        let nsError = error as NSError
        record("\(source): \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

enum ServiceProbeLocal {

    // MARK: - Constants (core: probe/mod.rs, services.rs)

    /// Kept in step with `browserUa` in FlClash
    /// lib/common/constant.dart (core BROWSER_USER_AGENT).
    private static let browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// Core DEFAULT_PROBE_TIMEOUT: 10 s per request.
    private static let requestTimeout: TimeInterval = 10
    /// Core CHECK_CONCURRENCY: 4 checks at a time.
    private static let checkConcurrency = 4
    /// Core SWEEP_BUDGET_FACTOR (6) x request timeout: the whole
    /// sweep must not start new checks past this deadline.
    private static let sweepBudget: TimeInterval = 60
    /// Core HTML_MAX_BODY / SMALL_MAX_BODY / SCAN_MAX_BODY.
    private static let htmlMaxBody = 512 * 1024
    private static let smallMaxBody = 16 * 1024
    private static let scanMaxBody = 8 * 1024 * 1024
    /// Core DISNEY_AUTH (rules.rs): the public browser client
    /// token Disney+ hands to any web visitor. May rotate — see
    /// the file header.
    private static let disneyAuth = "Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"
    /// Core GEMINI_REGION_MARKER (rules.rs).
    private static let geminiRegionMarker = ",2,1,200,\""
    /// Core CLAUDE_BLOCKED_REGIONS (rules.rs): alpha-2 codes.
    private static let claudeBlockedRegions: Set<String> = ["AF", "BY", "CN", "CU", "HK", "IR", "KP", "MO", "RU", "SY"]
    /// Core GEMINI_BLOCKED_REGIONS (rules.rs): alpha-3 codes,
    /// compared before normalisation.
    private static let geminiBlockedRegions: Set<String> = ["CHN", "RUS", "BLR", "CUB", "IRN", "PRK", "SYR", "HKG", "MAC"]

    /// The core's local mixed proxy (v0.2.125 pattern): the
    /// extension core listens here while the VPN is up.
    private static let proxyDictionary: [AnyHashable: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 17890,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890,
    ]

    // MARK: - Entry point

    /// Runs the 13 service checks (or the requested subset)
    /// through the core's local mixed proxy, in the requested
    /// order. Returns one item per requested service, in that
    /// order — a failed check is an item with status "timeout"
    /// or "failed", never an error (the core does the same).
    /// Throws only CancellationError (the sweep was cancelled).
    static func probeServices(proxy: String, names: [String]) async throws -> [ConcordServiceItem] {
        let selected = select(names)
        guard !selected.isEmpty else { return [] }
        let sweepStartedAt = Date()
        let ctx = Context(proxy: proxy, deadline: sweepStartedAt.addingTimeInterval(sweepBudget))
        let queue = WorkQueue(count: selected.count)
        let unordered = try await withThrowingTaskGroup(of: [ConcordServiceItem].self) { group -> [ConcordServiceItem] in
            for _ in 0..<min(checkConcurrency, selected.count) {
                group.addTask {
                    var mine: [ConcordServiceItem] = []
                    while let index = await queue.next() {
                        try Task.checkCancellation()
                        let name = selected[index]
                        if Date() >= ctx.deadline {
                            // The sweep budget is spent: the core
                            // leaves a never-started check failed.
                            mine.append(finish(name: name, status: "failed", region: "", delayMs: nil, proxy: proxy))
                            continue
                        }
                        mine.append(try await runChecker(ctx, name: name))
                    }
                    return mine
                }
            }
            var all: [ConcordServiceItem] = []
            for try await mine in group { all.append(contentsOf: mine) }
            return all
        }
        // The core returns checks in the requested order
        // (check_services joins in `wanted` order); the worker
        // pool finishes out of order, so re-sort.
        let order = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1, $0) })
        let items = unordered.sorted { (order[$0.name] ?? Int.max) < (order[$1.name] ?? Int.max) }
        let available = items.filter { $0.status == "available" }.count
        let failed = items.filter { $0.status == "timeout" || $0.status == "failed" }.count
        let elapsed = Int(Date().timeIntervalSince(sweepStartedAt) * 1000)
        ServiceProbeDiagnostics.record("service-probe: sweep done via local-proxy (proxy \(proxy)): \(available)/\(items.count) available, \(failed) failed/timeout, \(elapsed) ms")
        if failed == items.count {
            // Every check failed at the transport level — almost
            // certainly the local proxy itself (the tunnel core
            // not listening on 17890 yet; on-device 13:29 the IP
            // probe's local-proxy fetch failed 5x over 20 s after
            // tunnel start). This is NOT thrown: the core returns
            // failed items rather than an error in exactly this
            // situation, and returning them lets ServiceProbeStore's
            // confirm machine re-probe in 1 s and recover on its
            // own when the proxy comes up — throwing would leave
            // services empty with only a manual retry to recover.
            ServiceProbeDiagnostics.record("service-probe: all checks failed — local proxy 127.0.0.1:17890 may be unreachable; confirm re-probe will retry")
        }
        return items
    }

    /// The core's Registry.selected: an empty list runs every
    /// check; unknown names are dropped.
    private static func select(_ names: [String]) -> [String] {
        if names.isEmpty { return concordProbeServiceNames }
        return names.filter { concordProbeServiceNames.contains($0) }
    }

    /// One checker, with the core's retry-once-on-timeout
    /// (services.rs run_with_retry: a timeout gets one more try
    /// when the sweep still has a request budget left).
    private static func runChecker(_ ctx: Context, name: String) async throws -> ConcordServiceItem {
        var item = try await check(ctx, name: name)
        if item.status == "timeout", ctx.deadline.timeIntervalSinceNow >= requestTimeout {
            item = try await check(ctx, name: name)
        }
        ServiceProbeDiagnostics.record(verdictLine(item))
        return item
    }

    private static func verdictLine(_ item: ConcordServiceItem) -> String {
        var line = "service-probe: \(item.name) \(item.status)"
        if item.status == "available", let delay = item.delay {
            line += " (\(delay) ms"
            if let region = item.region, !region.isEmpty { line += ", \(region)" }
            line += ")"
        } else if let region = item.region, !region.isEmpty {
            line += " (\(region))"
        }
        return line
    }

    private static func check(_ ctx: Context, name: String) async throws -> ConcordServiceItem {
        switch name {
        case "google": return try await checkReachable(ctx, name: name, url: "https://www.google.com/generate_204")
        case "github": return try await checkReachable(ctx, name: name, url: "https://github.com/")
        case "youtube": return try await checkYoutube(ctx)
        case "chatgpt": return try await checkChatgpt(ctx)
        case "claude": return try await checkClaude(ctx)
        case "gemini": return try await checkGemini(ctx)
        case "netflix": return try await checkNetflix(ctx)
        case "disney-plus": return try await checkDisneyPlus(ctx)
        case "prime-video": return try await checkPrimeVideo(ctx)
        case "spotify": return try await checkSpotify(ctx)
        case "tiktok": return try await checkTiktok(ctx)
        case "discord": return try await checkDiscord(ctx)
        case "bilibili": return try await checkBilibili(ctx)
        default: return finish(name: name, status: "failed", region: "", delayMs: nil, proxy: ctx.proxy)
        }
    }

    // MARK: - Item assembly (core: services.rs item_from)

    /// The core's item_from: a transport error becomes status
    /// "timeout"/"failed" with no delay; an answered request
    /// leaves the status blank for the rule to judge and keeps
    /// the head delay.
    private static func itemFrom(_ result: FetchResult) -> (status: String, delayMs: Int64?) {
        if let error = result.error {
            return (error == .timeout ? "timeout" : "failed", nil)
        }
        return ("", result.delayMs)
    }

    /// The core's answered(): the request got a response (the
    /// item status is blank). A timed-out or failed request is
    /// not answerable.
    private static func answered(_ result: FetchResult) -> Bool {
        result.error == nil
    }

    /// The core's status_from_code: 200–299 available;
    /// 401/403/429/451 restricted; anything else unavailable.
    private static func statusFromCode(_ code: Int) -> String {
        switch code {
        case 200...299: return "available"
        case 401, 403, 429, 451: return "restricted"
        default: return "unavailable"
        }
    }

    /// Builds the final item. Region is nil when empty (the core
    /// omits an empty region from the JSON, so the live decode
    /// reads nil); delay is nil for transport failures (the core
    /// omits a zero delay the same way). checkedAt is now, epoch
    /// and version are 0 (see the file header).
    private static func finish(name: String, status: String, region: String, delayMs: Int64?, proxy: String) -> ConcordServiceItem {
        ConcordServiceItem(
            name: name,
            status: status,
            region: region.isEmpty ? nil : region,
            delay: delayMs,
            chains: [proxy],
            checkedAt: Int64(Date().timeIntervalSince1970 * 1000),
            epoch: 0,
            version: 0,
            hits: []
        )
    }

    // MARK: - Checkers (core: rules.rs)

    /// rules.rs reachable: status only, no body (max_body 0).
    private static func checkReachable(_ ctx: Context, name: String, url: String) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: url, maxBody: 0))
        let (status, delay) = itemFrom(result)
        guard answered(result), let code = result.status else {
            return finish(name: name, status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        return finish(name: name, status: statusFromCode(code), region: "", delayMs: delay, proxy: ctx.proxy)
    }

    /// rules.rs claude: Cloudflare trace `loc`, blocked regions
    /// are unsupported-region.
    private static func checkClaude(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://claude.ai/cdn-cgi/trace", maxBody: smallMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result) else {
            return finish(name: "claude", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let region = normalizeRegion(traceValue(result.body, key: "loc"))
        if region.isEmpty {
            return finish(name: "claude", status: "failed", region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let finalStatus = claudeBlockedRegions.contains(region) ? "unsupported-region" : "available"
        return finish(name: "claude", status: finalStatus, region: region, delayMs: delay, proxy: ctx.proxy)
    }

    /// rules.rs gemini: scan until the region marker appears
    /// (its region sits past 800 KiB); the code is alpha-3 and
    /// is checked against the blocked list before normalising.
    private static func checkGemini(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://gemini.google.com", maxBody: scanMaxBody, until: { tail in geminiCode(tail) != nil }))
        let (status, delay) = itemFrom(result)
        guard answered(result) else {
            return finish(name: "gemini", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        guard let code = geminiCode(result.body), isAsciiUpper(code) else {
            return finish(name: "gemini", status: "failed", region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let region = normalizeRegion(code)
        let finalStatus = geminiBlockedRegions.contains(code) ? "unsupported-region" : "available"
        return finish(name: "gemini", status: finalStatus, region: region, delayMs: delay, proxy: ctx.proxy)
    }

    /// The marker `,2,1,200,"` followed by the 3-letter region
    /// code (core gemini_code).
    private static func geminiCode(_ text: String) -> String? {
        guard let range = text.range(of: geminiRegionMarker) else { return nil }
        let start = range.upperBound
        guard let end = text.index(start, offsetBy: 3, limitedBy: text.endIndex) else { return nil }
        return String(text[start..<end])
    }

    /// rules.rs chatgpt: three sequential GETs — the iOS
    /// endpoint judges the verdict, the trace names the region,
    /// the compliance endpoint can override to
    /// unsupported-region. The delay stays the first request's
    /// (the core starts the item from it).
    private static func checkChatgpt(_ ctx: Context) async throws -> ConcordServiceItem {
        let ios = try await fetch(ctx, FetchSpec(method: "GET", url: "https://ios.chat.openai.com/", maxBody: smallMaxBody))
        let (iosStatus, iosDelay) = itemFrom(ios)
        var status = iosStatus
        if answered(ios) { status = chatgptIosStatus(ios) }
        var region = ""
        let trace = try await fetch(ctx, FetchSpec(method: "GET", url: "https://chat.openai.com/cdn-cgi/trace", maxBody: smallMaxBody))
        if answered(trace) { region = normalizeRegion(traceValue(trace.body, key: "loc")) }
        let web = try await fetch(ctx, FetchSpec(method: "GET", url: "https://api.openai.com/compliance/cookie_requirements", maxBody: smallMaxBody))
        if answered(web), bodyContains(web.body, "unsupported_country") { status = "unsupported-region" }
        return finish(name: "chatgpt", status: status, region: region, delayMs: iosDelay, proxy: ctx.proxy)
    }

    /// Core chatgpt_ios_status (body_contains, case-insensitive).
    private static func chatgptIosStatus(_ result: FetchResult) -> String {
        let lower = result.body.lowercased()
        if lower.contains("you may be connected to a disallowed isp") { return "disallowed-isp" }
        if lower.contains("sorry, you have been blocked") { return "blocked" }
        if lower.contains("request is not allowed. please try again later.") { return "available" }
        return "failed"
    }

    /// rules.rs youtube_premium: the premium page names its
    /// region (four patterns, first hit wins) and says outright
    /// when Premium is not available in the country.
    private static func checkYoutube(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.youtube.com/premium?hl=en", maxBody: htmlMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result), let code = result.status else {
            return finish(name: "youtube", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let region = youtubeRegion(result.body)
        let lower = result.body.lowercased()
        let finalStatus: String
        if lower.contains("youtube premium is not available in your country")
            || lower.contains("premium is not available in your country")
            || lower.contains("premium is not available in your region") {
            finalStatus = "unsupported-region"
        } else if (200...299).contains(code)
            && (lower.contains("youtube premium") || lower.contains("ad-free") || lower.contains("\"browseid\":\"spunlimited\"")) {
            finalStatus = "available"
        } else {
            finalStatus = statusFromCode(code)
        }
        return finish(name: "youtube", status: finalStatus, region: region, delayMs: delay, proxy: ctx.proxy)
    }

    private static func youtubeRegion(_ body: String) -> String {
        for regex in youtubeRegionRegexes {
            let code = firstSubmatch(regex, in: body)
            if !code.isEmpty { return normalizeRegion(code) }
        }
        return ""
    }

    /// rules.rs spotify: the country selector names the region
    /// — preferring the country Spotify redirected into (the
    /// final URL's first path segment) over the payload.
    private static func checkSpotify(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json", maxBody: smallMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result), let code = result.status else {
            return finish(name: "spotify", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let region = normalizeRegion(spotifyRegion(result))
        let finalStatus: String
        if code == 403 || code == 451 {
            finalStatus = "unsupported-region"
        } else if !(200...299).contains(code) {
            finalStatus = statusFromCode(code)
        } else if bodyContains(result.body, "not available in your country") {
            finalStatus = "unsupported-region"
        } else {
            finalStatus = "available"
        }
        return finish(name: "spotify", status: finalStatus, region: region, delayMs: delay, proxy: ctx.proxy)
    }

    /// Core spotify_region: the final URL's first path segment
    /// (before any '-'), unless it is empty or "api" — then the
    /// countryCode named in the payload.
    private static func spotifyRegion(_ result: FetchResult) -> String {
        if let url = URL(string: result.url) {
            let first = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first
            if let first, !first.isEmpty, first != "api" {
                return String(first.split(separator: "-").first ?? "")
            }
        }
        return firstSubmatch(spotifyCountryRegex, in: result.body)
    }

    /// rules.rs tiktok: scan until the web app's context names
    /// its region (TikTok is not behind Cloudflare, so there is
    /// no /cdn-cgi/trace to read).
    private static func checkTiktok(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.tiktok.com/", maxBody: scanMaxBody, until: { tail in matches(tiktokRegionRegex, in: tail) }))
        let (status, delay) = itemFrom(result)
        guard answered(result), let code = result.status else {
            return finish(name: "tiktok", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        return finish(name: "tiktok", status: tiktokStatus(result, code: code), region: normalizeRegion(firstSubmatch(tiktokRegionRegex, in: result.body)), delayMs: delay, proxy: ctx.proxy)
    }

    /// Core tiktok_status (body_contains, case-insensitive).
    private static func tiktokStatus(_ result: FetchResult, code: Int) -> String {
        if code == 403 || code == 451 { return "unsupported-region" }
        if !(200...299).contains(code) { return "failed" }
        let lower = result.body.lowercased()
        if lower.contains("access denied") || lower.contains("not available in your region") || lower.contains("tiktok is not available") {
            return "unsupported-region"
        }
        return "available"
    }

    /// rules.rs bilibili: try the mainland episode first; a
    /// playable episode is available with region CN, a
    /// -10403 is unsupported-region and falls through to the
    /// Hong Kong / Macau / Taiwan episode (whose item carries no
    /// region, exactly like the core).
    private static func checkBilibili(_ ctx: Context) async throws -> ConcordServiceItem {
        let mainland = "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi"
        let hmt = "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi"
        let first = try await bilibiliEpisode(ctx, url: mainland)
        switch first.status {
        case "available":
            return finish(name: "bilibili", status: "available", region: "CN", delayMs: first.delayMs, proxy: ctx.proxy)
        case "unsupported-region":
            let second = try await bilibiliEpisode(ctx, url: hmt)
            return finish(name: "bilibili", status: second.status, region: "", delayMs: second.delayMs, proxy: ctx.proxy)
        default:
            return finish(name: "bilibili", status: first.status, region: "", delayMs: first.delayMs, proxy: ctx.proxy)
        }
    }

    private static func bilibiliEpisode(_ ctx: Context, url: String) async throws -> (status: String, delayMs: Int64?) {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: url, maxBody: smallMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result) else { return (status, delay) }
        return (bilibiliStatus(result.body), delay)
    }

    /// Core bilibili_status: the leading JSON code — 0 is
    /// playable, -10403 is region-locked, anything else failed.
    /// (A playable episode runs past the small body cap; only
    /// its leading code is read.)
    private static func bilibiliStatus(_ body: String) -> String {
        switch firstSubmatch(bilibiliCodeRegex, in: body) {
        case "0": return "available"
        case "-10403": return "unsupported-region"
        default: return "failed"
        }
    }

    /// rules.rs discord: the location-metadata endpoint names
    /// its country code when the answer is available.
    private static func checkDiscord(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://discord.com/api/v9/auth/location-metadata", maxBody: smallMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result), let code = result.status else {
            return finish(name: "discord", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let finalStatus = statusFromCode(code)
        let region = finalStatus == "available" ? normalizeRegion(firstSubmatch(discordCountryRegex, in: result.body)) : ""
        return finish(name: "discord", status: finalStatus, region: region, delayMs: delay, proxy: ctx.proxy)
    }

    /// rules.rs prime_video: scan until the page either says
    /// the service is restricted or names its territory (its
    /// region sits at times past 4 MiB).
    private static func checkPrimeVideo(_ ctx: Context) async throws -> ConcordServiceItem {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.primevideo.com", maxBody: scanMaxBody, until: { tail in
            tail.contains("isServiceRestricted") || matches(primeRegionRegex, in: tail)
        }))
        let (status, delay) = itemFrom(result)
        guard answered(result) else {
            return finish(name: "prime-video", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        // NOTE: case-sensitive `contains`, like the core —
        // this is a marker in the page, not a verdict phrase.
        if result.body.contains("isServiceRestricted") {
            return finish(name: "prime-video", status: "unsupported-region", region: "", delayMs: delay, proxy: ctx.proxy)
        }
        let code = firstSubmatch(primeRegionRegex, in: result.body)
        if code.isEmpty {
            return finish(name: "prime-video", status: "failed", region: "", delayMs: delay, proxy: ctx.proxy)
        }
        return finish(name: "prime-video", status: "available", region: normalizeRegion(code), delayMs: delay, proxy: ctx.proxy)
    }

    /// rules.rs netflix: fast.com first (a 403 there is
    /// blocked outright), then the two title pages — both 404
    /// is originals-only, either 403 is unsupported-region,
    /// either 200/301 is available with the region read out of
    /// the redirect Netflix would send a visitor to.
    private static func checkNetflix(_ ctx: Context) async throws -> ConcordServiceItem {
        let fromCdn = try await netflixFromCdn(ctx)
        if fromCdn.status == "available" || fromCdn.status == "blocked" { return fromCdn }
        let first = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.netflix.com/title/81280792", maxBody: 0))
        let (firstStatus, firstDelay) = itemFrom(first)
        guard answered(first), let firstCode = first.status else {
            return finish(name: "netflix", status: firstStatus, region: "", delayMs: firstDelay, proxy: ctx.proxy)
        }
        let second = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.netflix.com/title/70143836", maxBody: 0))
        let (secondStatus, secondDelay) = itemFrom(second)
        guard answered(second), let secondCode = second.status else {
            return finish(name: "netflix", status: secondStatus, region: "", delayMs: secondDelay, proxy: ctx.proxy)
        }
        let finalStatus: String
        var region = ""
        if firstCode == 404 && secondCode == 404 {
            finalStatus = "originals-only"
        } else if firstCode == 403 || secondCode == 403 {
            finalStatus = "unsupported-region"
        } else if netflixServed(firstCode) || netflixServed(secondCode) {
            finalStatus = "available"
            region = try await netflixRegion(ctx)
        } else {
            finalStatus = statusFromCode(firstCode)
        }
        return finish(name: "netflix", status: finalStatus, region: region, delayMs: firstDelay, proxy: ctx.proxy)
    }

    private static func netflixServed(_ code: Int) -> Bool {
        code == 200 || code == 301
    }

    /// Core netflix_from_cdn: the speedtest targets name their
    /// country; a 403 is blocked; an unparsable answer is failed.
    private static func netflixFromCdn(_ ctx: Context) async throws -> ConcordServiceItem {
        let url = "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5"
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: url, maxBody: smallMaxBody))
        let (status, delay) = itemFrom(result)
        guard answered(result) else {
            return finish(name: "netflix", status: status, region: "", delayMs: delay, proxy: ctx.proxy)
        }
        if result.status == 403 {
            return finish(name: "netflix", status: "blocked", region: "", delayMs: delay, proxy: ctx.proxy)
        }
        if let country = fastCountry(result.body) {
            return finish(name: "netflix", status: "available", region: normalizeRegion(country), delayMs: delay, proxy: ctx.proxy)
        }
        return finish(name: "netflix", status: "failed", region: "", delayMs: delay, proxy: ctx.proxy)
    }

    private struct FastPayload: Decodable { let targets: [FastTarget] }
    private struct FastTarget: Decodable { let location: FastLocation }
    private struct FastLocation: Decodable { let country: String }

    private static func fastCountry(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(FastPayload.self, from: data) else { return nil }
        return payload.targets.first?.location.country
    }

    /// Core netflix_region: reads the country out of the
    /// redirect Netflix would send a visitor to, so the redirect
    /// must not be followed.
    private static func netflixRegion(_ ctx: Context) async throws -> String {
        let result = try await fetch(ctx, FetchSpec(method: "GET", url: "https://www.netflix.com/title/80018499", maxBody: 0, noRedirect: true))
        guard result.error == nil else { return "" }
        let location = result.headers["location"] ?? ""
        // Split keeping empty segments: "https://www.netflix.com/us/…"
        // splits to ["https:", "", "www.netflix.com", "us", …] and
        // the country is segment 3 ("us" or "jp-en" → "jp").
        let segments = location.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count > 3 else { return "" }
        let country = segments[3].split(separator: "-").first ?? ""
        return normalizeRegion(String(country))
    }

    /// rules.rs disney_plus: walks the browser hand-shake —
    /// register a device, exchange the assertion for a refresh
    /// token, then ask the session which region it landed in.
    /// Any step can answer on its own that the address is not
    /// welcome. The delay stays the FIRST (device) request's
    /// throughout — the core starts the item from it — except
    /// the token-request error, which returns the token's own
    /// item (see the core).
    private static func checkDisneyPlus(_ ctx: Context) async throws -> ConcordServiceItem {
        let device = try await fetch(ctx, disneyRequest(
            url: "https://disney.api.edge.bamgrid.com/devices",
            contentType: "application/json; charset=UTF-8",
            body: #"{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}"#))
        let (deviceStatus, deviceDelay) = itemFrom(device)
        guard answered(device), let deviceCode = device.status else {
            return finish(name: "disney-plus", status: deviceStatus, region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        if deviceCode == 403 {
            return finish(name: "disney-plus", status: "blocked", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let assertion = firstSubmatch(disneyAssertionRegex, in: device.body)
        if assertion.isEmpty {
            return finish(name: "disney-plus", status: "failed", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let form = "grant_type=urn:ietf:params:oauth:grant-type:token-exchange&latitude=0&longitude=0&platform=browser&subject_token=\(queryEscape(assertion))&subject_token_type=urn:bamtech:params:oauth:token-type:device"
        let token = try await fetch(ctx, disneyRequest(
            url: "https://disney.api.edge.bamgrid.com/token",
            contentType: "application/x-www-form-urlencoded",
            body: form))
        guard answered(token) else {
            let (tokenStatus, tokenDelay) = itemFrom(token)
            return finish(name: "disney-plus", status: tokenStatus, region: "", delayMs: tokenDelay, proxy: ctx.proxy)
        }
        // NOTE: case-sensitive `contains`, like the core.
        if token.body.contains("forbidden-location") || token.body.contains("403 ERROR") {
            return finish(name: "disney-plus", status: "blocked", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let refresh = firstSubmatch(disneyRefreshRegex, in: token.body)
        if refresh.isEmpty {
            return finish(name: "disney-plus", status: "failed", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let query = "{\"query\":\"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }\",\"variables\":{\"input\":{\"refreshToken\":\"\(refresh)\"}}}"
        let session = try await fetch(ctx, disneyRequest(
            url: "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql",
            contentType: "application/json",
            body: query))
        guard answered(session), !session.body.isEmpty, (session.status ?? 0) < 400 else {
            return finish(name: "disney-plus", status: "failed", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let region = normalizeRegion(firstSubmatch(disneyCountryRegex, in: session.body))
        if region.isEmpty {
            return finish(name: "disney-plus", status: "unavailable", region: "", delayMs: deviceDelay, proxy: ctx.proxy)
        }
        let supported = firstSubmatch(disneySupportedRegex, in: session.body)
        let finalStatus: String
        switch supported {
        case "true": finalStatus = "available"
        case "false": finalStatus = "coming-soon"
        default: finalStatus = "failed"
        }
        return finish(name: "disney-plus", status: finalStatus, region: region, delayMs: deviceDelay, proxy: ctx.proxy)
    }

    /// Core disney_request: a POST with the browser auth token.
    private static func disneyRequest(url: String, contentType: String, body: String) -> FetchSpec {
        FetchSpec(method: "POST", url: url, headers: [("Authorization", disneyAuth), ("Content-Type", contentType)], body: Data(body.utf8), maxBody: smallMaxBody)
    }

    /// Go's `url.QueryEscape` (core query_escape): everything
    /// but the unreserved set, a space as `+`.
    private static func queryEscape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for byte in text.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 95, 46, 126:
                // UnicodeScalar(UInt8) is non-failable: every
                // byte 0...255 is a valid scalar (the UInt32
                // spelling is failable and does not compile here).
                escaped.append(Character(UnicodeScalar(byte)))
            case 32:
                escaped.append("+")
            default:
                escaped.append(String(format: "%%%02X", Int(byte)))
            }
        }
        return escaped
    }
}

extension ServiceProbeLocal {

    // MARK: - Fetch primitive (core: fetch.rs)

    private struct Context {
        let proxy: String
        let deadline: Date
    }

    /// The four workers (CHECK_CONCURRENCY) pull checker indices
    /// from this queue; the actor serialises the hand-out.
    private actor WorkQueue {
        private var nextIndex = 0
        private let count: Int
        init(count: Int) { self.count = count }
        func next() -> Int? {
            guard nextIndex < count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    private struct FetchSpec {
        var method: String
        var url: String
        var headers: [(String, String)] = []
        var body: Data? = nil
        var maxBody: Int
        /// Sees the latest frame of the body plus 256 bytes
        /// before it (core SCAN_OVERLAP); when it matches, the
        /// read stops early and the partial body is the answer.
        var until: ((String) -> Bool)? = nil
        /// Do not follow redirects (Netflix names its region in
        /// the Location the visitor would be sent to).
        var noRedirect: Bool = false
    }

    private enum FetchError {
        case timeout
        case failed
    }

    /// One request's answer (core ProbeResult, minus the parts
    /// the app cannot know: chains come from the dial log, hits
    /// from the recorder — both are fixed by finish()).
    private struct FetchResult {
        /// nil when the request errored before a response.
        var status: Int?
        /// Head delay in ms (core: time to the response head);
        /// 0 when there was no response.
        var delayMs: Int64
        /// Lossy UTF-8 body, capped at maxBody ("" when the head
        /// was never read — maxBody 0 reads no body at all).
        var body: String
        /// Final URL after redirects (or the requested URL).
        var url: String
        /// Response headers, names lowercased.
        var headers: [String: String]
        /// nil when the request was answered.
        var error: FetchError?
        /// Transport error detail, for diagnostics ("" when answered).
        var message: String
    }

    /// One request through the core's local mixed proxy, with the
    /// core's streaming semantics: the body is read in chunks up
    /// to maxBody and stops early when `until` matches the tail;
    /// a maxBody of 0 reads no body at all; a read that stops
    /// mid-body (timeout included) keeps the partial body and the
    /// head status — only a missing head is a transport failure.
    /// Throws only CancellationError (genuine task cancellation).
    private static func fetch(_ ctx: Context, _ spec: FetchSpec) async throws -> FetchResult {
        guard let url = URL(string: spec.url) else {
            return FetchResult(status: nil, delayMs: 0, body: "", url: spec.url, headers: [:], error: .failed, message: "bad URL: \(spec.url)")
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = spec.method
        // The core sends Accept-Encoding: identity (fetch.rs) —
        // no transparent decompression, so a body truncated at
        // the cap stays cleanly cut instead of failing mid-stream.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = spec.body
        let startedAt = Date()
        let box = CancellationBox()
        var sessionRef: URLSession?
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = proxyDictionary
                config.timeoutIntervalForRequest = requestTimeout
                config.timeoutIntervalForResource = requestTimeout
                let delegate = CappedFetchDelegate(spec: spec, startedAt: startedAt) { result in
                    continuation.resume(returning: result)
                }
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                sessionRef = session
                let task = session.dataTask(with: request)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
        sessionRef?.finishTasksAndInvalidate()
        try Task.checkCancellation()
        if let error = result.error {
            // The service name is not known here, so the line
            // names the host; the per-service verdict line names
            // the service. Only transport failures are logged —
            // a sweep that succeeds stays quiet.
            ServiceProbeDiagnostics.record("local-proxy: \(host(of: spec.url)) \(error == .timeout ? "timeout" : "failed") (\(result.message))")
        }
        return result
    }

    private static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    /// Holds the in-flight data task so the cancellation handler
    /// can stop it; the lock is the only shared state.
    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        func set(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            lock.unlock()
        }
        func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    /// One request's streaming state. Everything but the
    /// completion closure is touched only on the session's serial
    /// delegate queue.
    private final class CappedFetchDelegate: NSObject, URLSessionDataDelegate {
        private let spec: FetchSpec
        private let startedAt: Date
        private let completion: (FetchResult) -> Void
        private var response: HTTPURLResponse?
        private var headDelayMs: Int64 = 0
        private var body = Data()
        private var completed = false

        init(spec: FetchSpec, startedAt: Date, completion: @escaping (FetchResult) -> Void) {
            self.spec = spec
            self.startedAt = startedAt
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            self.response = http
            headDelayMs = Int64(Date().timeIntervalSince(startedAt) * 1000)
            if spec.maxBody == 0 {
                // Head only (google, github, netflix titles): the
                // core reads no body for these — cancel before
                // any data arrives.
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard response != nil, !data.isEmpty else { return }
            // The core checks `until` on the last 256 bytes of the
            // old buffer plus the new piece (SCAN_OVERLAP).
            let from = body.count - min(body.count, 256)
            let room = spec.maxBody - body.count
            guard room > 0 else { dataTask.cancel(); return }
            body.append(data.prefix(room))
            if let until = spec.until,
               until(String(decoding: body[from...], as: UTF8.self)) {
                dataTask.cancel()
                return
            }
            if body.count >= spec.maxBody { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Netflix names its region in the redirect it would
            // send a visitor to, so that one request must not
            // follow it (core ProbeRequest.no_redirect) — the 301
            // itself is the answer.
            completionHandler(spec.noRedirect ? nil : request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !completed else { return }
            completed = true
            let result: FetchResult
            if let http = response {
                // The head arrived: the core keeps the partial
                // body and the head status whatever stopped the
                // read (timeout included) — only a missing head
                // is a transport failure.
                result = FetchResult(
                    status: http.statusCode,
                    delayMs: headDelayMs,
                    body: String(decoding: body, as: UTF8.self),
                    url: http.url?.absoluteString ?? spec.url,
                    headers: Self.headerMap(http),
                    error: nil,
                    message: ""
                )
            } else {
                let (kind, message) = Self.classify(error)
                result = FetchResult(status: nil, delayMs: 0, body: "", url: spec.url, headers: [:], error: kind, message: message)
            }
            completion(result)
        }

        private static func headerMap(_ response: HTTPURLResponse) -> [String: String] {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let name = key as? String, let value = value as? String {
                    headers[name.lowercased()] = value
                }
            }
            return headers
        }

        private static func classify(_ error: Error?) -> (FetchError, String) {
            guard let error else { return (.failed, "no response, no error") }
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                return (.timeout, detail)
            }
            return (.failed, detail)
        }
    }

    // MARK: - Helpers (core: fetch.rs, region.rs, services.rs)

    /// The core's body_contains: case-insensitive (the body is
    /// lowercased once, the needles are already lowercase).
    private static func bodyContains(_ body: String, _ needle: String) -> Bool {
        body.lowercased().contains(needle)
    }

    /// The core's trace_value: the line starting with "key=",
    /// the rest after "=" trimmed.
    private static func traceValue(_ body: String, key: String) -> String {
        let prefix = key + "="
        for line in body.split(separator: "\n") {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func isAsciiUpper(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 65 && $0 <= 90 }
    }

    /// The core's region::normalize_region: trim, ASCII-uppercase,
    /// then a 2-letter all-caps code passes through, a 3-letter
    /// one folds to alpha-2 through the ISO 3166 table, anything
    /// else is empty. Only Gemini reports alpha-3.
    private static func normalizeRegion(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespaces).utf8.map { byte -> UInt8 in
            (byte >= 97 && byte <= 122) ? byte - 32 : byte
        }
        guard (upper.count == 2 || upper.count == 3),
              upper.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return "" }
        let text = String(decoding: upper, as: UTF8.self)
        if upper.count == 2 { return text }
        return alpha3ToAlpha2[text] ?? ""
    }

    /// The core's ISO3166_PACKED (region.rs): each 5-character
    /// entry is an alpha-3 code followed by its alpha-2 code.
    private static let iso3166Packed = "ABWAWAFGAFAGOAOAIAAIALAAXALBALANDADAREAEARGARARMAMASMASATAAQATFTFATGAGAUSAUAUTATAZEAZBDIBIBELBEBENBJBESBQBFABFBGDBDBGRBGBHRBHBHSBSBIHBABLMBLBLRBYBLZBZBMUBMBOLBOBRABRBRBBBBRNBNBTNBTBVTBVBWABWCAFCFCANCACCKCCCHECHCHLCLCHNCNCIVCICMRCMCODCDCOGCGCOKCKCOLCOCOMKMCPVCVCRICRCUBCUCUWCWCXRCXCYMKYCYPCYCZECZDEUDEDJIDJDMADMDNKDKDOMDODZADZECUECEGYEGERIERESHEHESPESESTEEETHETFINFIFJIFJFLKFKFRAFRFROFOFSMFMGABGAGBRGBGEOGEGGYGGGHAGHGIBGIGINGNGLPGPGMBGMGNBGWGNQGQGRCGRGRDGDGRLGLGTMGTGUFGFGUMGUGUYGYHKGHKHMDHMHNDHNHRVHRHTIHTHUNHUIDNIDIMNIMINDINIOTIOIRLIEIRNIRIRQIQISLISISRILITAITJAMJMJEYJEJORJOJPNJPKAZKZKENKEKGZKGKHMKHKIRKIKNAKNKORKRKWTKWLAOLALBNLBLBRLRLBYLYLCALCLIELILKALKLSOLSLTULTLUXLULVALVMACMOMAFMFMARMAMCOMCMDAMDMDGMGMDVMVMEXMXMHLMHMKDMKMLIMLMLTMTMMRMMMNEMEMNGMNMNPMPMOZMZMRTMRMSRMSMTQMQMUSMUMWIMWMYSMYMYTYTNAMNANCLNCNERNENFKNFNGANGNICNINIUNUNLDNLNORNONPLNPNRUNRNZLNZOMNOMPAKPKPANPAPCNPNPERPEPHLPHPLWPWPNGPGPOLPLPRIPRPRKKPPRTPTPRYPYPSEPSPYFPFQATQAREUREROURORUSRURWARWSAUSASDNSDSENSNSGPSGSGSGSSHNSHSJMSJSLBSBSLESLSLVSVSMRSMSOMSOSPMPMSRBRSSSDSSSTPSTSURSRSVKSKSVNSISWESESWZSZSXMSXSYCSCSYRSYTCATCTCDTDTGOTGTHATHTJKTJTKLTKTKMTMTLSTLTONTOTTOTTTUNTNTURTRTUVTVTWNTWTZATZUGAUGUKRUAUMIUMURYUYUSAUSUZBUZVATVAVCTVCVENVEVGBVGVIRVIVNMVNVUTVUWLFWFWSMWSYEMYEZAFZAZMBZMZWEZW"

    private static let alpha3ToAlpha2: [String: String] = {
        let chars = Array(iso3166Packed)
        var map: [String: String] = [:]
        map.reserveCapacity(chars.count / 5)
        for start in stride(from: 0, to: chars.count - 4, by: 5) {
            map[String(chars[start..<start + 3])] = String(chars[start + 3..<start + 5])
        }
        return map
    }()

    // MARK: - Patterns (core: rules.rs Patterns)

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func firstSubmatch(_ regex: NSRegularExpression?, in body: String) -> String {
        guard let regex else { return "" }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges > 1 else { return "" }
        let groupRange = match.range(at: 1)
        guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: body) else { return "" }
        return String(body[swiftRange])
    }

    /// Core youtube_region: tried in order, first hit wins.
    private static let youtubeRegionRegexes: [NSRegularExpression?] = [
        #"(?i)id=["']country-code["'][^>]*>\s*([A-Za-z]{2,3})\s*<"#,
        #""GL"\s*:\s*"([A-Za-z]{2})""#,
        #""countryCode"\s*:\s*"([A-Za-z]{2})""#,
        #""country_code"\s*:\s*"([A-Za-z]{2})""#,
    ].map(compiled)

    private static let tiktokRegionRegex: NSRegularExpression? = compiled(#""webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"([^"]*)""#)
    private static let primeRegionRegex: NSRegularExpression? = compiled(#""currentTerritory":"([^"]+)""#)
    private static let disneyAssertionRegex: NSRegularExpression? = compiled(#""assertion"\s*:\s*"([^"]+)""#)
    private static let disneyRefreshRegex: NSRegularExpression? = compiled(#""refresh_token"\s*:\s*"([^"]+)""#)
    private static let disneyCountryRegex: NSRegularExpression? = compiled(#""countryCode"\s*:\s*"([^"]+)""#)
    private static let disneySupportedRegex: NSRegularExpression? = compiled(#""inSupportedLocation"\s*:\s*(false|true)"#)
    private static let spotifyCountryRegex: NSRegularExpression? = compiled(#""countryCode"\s*:\s*"([^"]+)""#)
    private static let discordCountryRegex: NSRegularExpression? = compiled(#""country_code"\s*:\s*"([^"]+)""#)
    private static let bilibiliCodeRegex: NSRegularExpression? = compiled(#"^\s*\{\s*"code"\s*:\s*(-?\d+)"#)
}
