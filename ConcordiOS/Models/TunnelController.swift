import Foundation

/// The extension core's HTTP controller (mihomo-compatible REST API)
/// on 127.0.0.1:9090 — the working channel for the VPN-on delay test
/// (v0.2.128 item 2).
///
/// The app<->extension JSON-RPC channel is dead (TunnelError code 4),
/// so delay.test cannot travel over it. The core's controller is a
/// plain HTTP listener in the extension process: bins/ios spawns
/// concord_controller::serve, and the host enables it via config.patch
/// (externalController + secret — see PacketTunnelProvider.bootCore).
/// The app reaches it over the shared loopback, the same way the
/// v0.2.125 IP probe and v0.2.127 service probe reach the core's
/// local mixed proxy on 17890. The controller is loopback-only, so
/// only this device can reach it; the Bearer secret below keeps
/// other apps on the device from driving the core through it.
///
/// Endpoints used (crates/controller/src/routes.rs, pinned core):
///   GET  /version                          -> {"version": ...}
///   GET  /proxies/{name}/delay?url=&timeout= (ms, i16)
///        -> 200 {"delay": N} / 504 timeout / 503 failure
///   PUT  /proxies/{group} {"name": "<proxy>"} -> 204 (routes.rs
///        `select`: the group must be a Selector or have a fixed
///        pin — covers Selector + URLTest + Fallback)
///   DELETE /proxies/{group} -> 204 (routes.rs `unfix`: clears
///        a URLTest/Fallback pin)
///   GET  /configs                          -> {"unified-delay": bool, ...}
///   GET  /services?proxy=&names=&timeout= (ms, optional)
///        -> 200 {"items": [...]} (probe.services result, v0.2.135)
/// PATCH /configs does NOT map unified-delay (patch_params omits it),
/// so the delay test only READS it here; the tunnel startup patch
/// already applied the setting through JSON-RPC config.patch.
enum TunnelController {
    static let address = "127.0.0.1:9090"
    private static let fileName = "tunnel-controller.json"

    /// The shared secret for the controller's Bearer auth, stored in
    /// the App Group container so the app and the extension read the
    /// same value. Generated once (random) when the file is missing
    /// or holds no secret; the extension runs the same ensure step
    /// at tunnel start, so whichever side runs first creates it.
    /// v0.2.169: async — the file read runs off the MainActor on a
    /// private serial queue, not on the calling thread. Every
    /// controller request used to do this sync read inline. The
    /// secret never rotates (the file is the persistence, never
    /// deleted), so it is also cached for the process lifetime
    /// after the first read. The serial queue makes the
    /// read-or-create atomic: two concurrent first calls cannot
    /// generate two different secrets (the old code had that race;
    /// the cache would have made a wrong value stick for the
    /// whole process).
    private static let secretQueue = DispatchQueue(label: "concord.tunnelControllerSecret")
    private static var cachedSecret: String?
    static func secret() async -> String {
        await withCheckedContinuation { continuation in
            secretQueue.async {
                if let cached = cachedSecret {
                    continuation.resume(returning: cached)
                    return
                }
                let value = readOrCreateSecret()
                cachedSecret = value
                continuation.resume(returning: value)
            }
        }
    }

    /// The tunnel-controller.json read-or-create. Runs only on
    /// secretQueue: pure file I/O, no other state.
    private static func readOrCreateSecret() -> String {
        let file = sharedFileURL()
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = json["secret"] as? String, !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let payload: [String: Any] = ["secret": generated]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: file, options: .atomic)
        }
        return generated
    }

    private static func sharedFileURL() -> URL {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)
        return (container ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(fileName)
    }

    /// A loopback-only session: no proxy (this request goes TO the
    /// core, not THROUGH it), short timeouts so a dead controller
    /// fails fast instead of hanging the delay-test guard.
    private static func makeSession(timeoutSeconds: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        return URLSession(configuration: config)
    }

    private static func authorizedRequest(url: URL, timeoutSeconds: TimeInterval) async -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        let token = await secret()
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Reachability probe (GET /version, 3 s): true only on HTTP 200.
    /// The delay-test backend check uses this instead of the dead
    /// RPC configGeneral when the VPN is on.
    static func isReachable() async -> Bool {
        guard let url = URL(string: "http://\(address)/version") else { return false }
        do {
            let (_, response) = try await makeSession(timeoutSeconds: 3)
                .data(for: await authorizedRequest(url: url, timeoutSeconds: 3))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// One delay test through the controller (GET
    /// /proxies/{name}/delay). Returns the latency in ms (>0), -1 on
    /// timeout (HTTP 504) and -2 on a core failure (HTTP 503).
    /// Throws on transport errors (connection refused, no listener,
    /// bad response) — the caller records those as transport
    /// failures, never as dead nodes.
    static func delayTest(proxy: String, url: String, timeoutMs: Int) async throws -> Int32 {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedName = proxy.addingPercentEncoding(withAllowedCharacters: allowed) ?? proxy
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 9090
        // percentEncodedPath (not .path): the name is already
        // percent-encoded above, and .path would encode the `%`
        // again (%20 -> %2520), so the core would look up a
        // proxy whose name contains a literal "%20".
        components.percentEncodedPath = "/proxies/\(encodedName)/delay"
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: "\(timeoutMs)"),
        ]
        guard let requestURL = components.url else {
            throw TunnelControllerError.badURL
        }
        // The core's test runs up to timeoutMs inside; allow that
        // plus a margin for the round-trip, under the 30 s guard
        // the caller applies around every delay call.
        let requestTimeout = min(TimeInterval(timeoutMs) / 1000.0 + 10.0, 25.0)
        let (data, response) = try await makeSession(timeoutSeconds: requestTimeout)
            .data(for: await authorizedRequest(url: requestURL, timeoutSeconds: requestTimeout))
        guard let http = response as? HTTPURLResponse else {
            throw TunnelControllerError.badResponse
        }
        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delay = json["delay"] as? Int else {
                throw TunnelControllerError.badResponse
            }
            return Int32(delay)
        case 504:
            return -1
        case 503:
            return -2
        case 401:
            throw TunnelControllerError.unauthorized
        default:
            throw TunnelControllerError.httpStatus(http.statusCode)
        }
    }

    /// Service availability through the tunnel core's own prober
    /// (GET /services, v0.2.135, patch 10): the core pins each
    /// check to `proxy`, exactly like upstream FlClash's
    /// checkServices. The answer is the probe.services result's
    /// own JSON, so it decodes with the existing ConcordServiceList.
    /// Throws on transport errors and on any non-200 status — the
    /// caller falls back to the app-side probe (ServiceProbeLocal).
    /// The core's sweep budget is 6 x the 10 s request timeout
    /// (services.rs SWEEP_BUDGET_FACTOR), so a full sweep can take
    /// up to 60 s; the session timeout allows that plus a margin.
    static func probeServices(proxy: String, names: [String]) async throws -> [ConcordServiceItem] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 9090
        components.path = "/services"
        components.queryItems = [
            URLQueryItem(name: "proxy", value: proxy),
            URLQueryItem(name: "names", value: names.joined(separator: ",")),
        ]
        guard let requestURL = components.url else {
            throw TunnelControllerError.badURL
        }
        let requestTimeout: TimeInterval = 90
        let (data, response) = try await makeSession(timeoutSeconds: requestTimeout)
            .data(for: await authorizedRequest(url: requestURL, timeoutSeconds: requestTimeout))
        guard let http = response as? HTTPURLResponse else {
            throw TunnelControllerError.badResponse
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(ConcordServiceList.self, from: data).items
        case 401:
            throw TunnelControllerError.unauthorized
        default:
            throw TunnelControllerError.httpStatus(http.statusCode)
        }
    }

    /// Select a proxy in a group through the controller (PUT
    /// /proxies/{group}). Returns on HTTP 204. An empty proxy
    /// clears a URLTest/Fallback pin (DELETE /proxies/{group}).
    /// Throws on transport errors and on any non-204 status.
    /// v0.2.131: the node tap's proxy.select cannot travel over
    /// the dead app->extension RPC when the VPN is on, so the
    /// tap always failed and rolled back to 自动选择 — this is
    /// the working channel for it, the same controller the
    /// VPN-on delay test already uses.
    static func selectProxy(group: String, proxy: String) async throws {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedName = group.addingPercentEncoding(withAllowedCharacters: allowed) ?? group
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 9090
        // percentEncodedPath (not .path): the name is already
        // percent-encoded above, and .path would encode the `%`
        // again, so the core would look up a group whose name
        // contains a literal "%20" (same as delayTest).
        components.percentEncodedPath = "/proxies/\(encodedName)"
        guard let requestURL = components.url else {
            throw TunnelControllerError.badURL
        }
        var request = await authorizedRequest(url: requestURL, timeoutSeconds: 10)
        if proxy.isEmpty {
            request.httpMethod = "DELETE"
        } else {
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": proxy])
        }
        let (_, response) = try await makeSession(timeoutSeconds: 10)
            .data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TunnelControllerError.badResponse
        }
        switch http.statusCode {
        case 204:
            return
        case 401:
            throw TunnelControllerError.unauthorized
        default:
            throw TunnelControllerError.httpStatus(http.statusCode)
        }
    }

    /// One RSS reading from the tunnel core (GET /memory, v0.2.133).
    /// The route streams newline-separated JSON once a second
    /// (`{"inuse": <rss bytes>, "oslimit": 0}`); the first frame is
    /// always 0 by design (chart-start convention, stream.rs), the
    /// next frame is the real RSS — the same
    /// engine.memory_stats().rss the in-app core.stats RPC returns.
    /// Returns nil when the controller does not answer or no non-zero
    /// frame arrives in time. The stream is closed as soon as a value
    /// is read: returning from the loop releases the byte sequence
    /// and cancels the underlying task (do not hold it open).
    static func memoryRSS() async -> UInt64? {
        guard let url = URL(string: "http://\(address)/memory") else { return nil }
        do {
            let (bytes, response) = try await makeSession(timeoutSeconds: 5)
                .bytes(for: await authorizedRequest(url: url, timeoutSeconds: 5))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var frames = 0
            for try await line in bytes.lines {
                frames += 1
                if frames > 8 { return nil }
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let inuse = (json["inuse"] as? NSNumber)?.uint64Value,
                      inuse > 0 else { continue }
                return inuse
            }
            return nil
        } catch {
            return nil
        }
    }

    /// The core's unified-delay flag (GET /configs). Nil when the
    /// controller is unreachable or the key is absent — the caller
    /// treats that as "could not read", never as a failure.
    static func unifiedDelay() async -> Bool? {
        guard let url = URL(string: "http://\(address)/configs") else { return nil }
        do {
            let (data, response) = try await makeSession(timeoutSeconds: 5)
                .data(for: await authorizedRequest(url: url, timeoutSeconds: 5))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["unified-delay"] as? Bool
        } catch {
            return nil
        }
    }
}

enum TunnelControllerError: Error, LocalizedError {
    case badURL
    case badResponse
    case unauthorized
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "控制器请求地址无效"
        case .badResponse: return "控制器返回了无法解析的响应"
        case .unauthorized: return "控制器拒绝了请求（密钥不匹配）"
        case .httpStatus(let code): return "控制器返回 HTTP \(code)"
        }
    }
}
