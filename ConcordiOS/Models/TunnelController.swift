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
///   GET  /configs                          -> {"unified-delay": bool, ...}
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
    static func secret() -> String {
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

    private static func authorizedRequest(url: URL, timeoutSeconds: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        let token = secret()
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
                .data(for: authorizedRequest(url: url, timeoutSeconds: 3))
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
            .data(for: authorizedRequest(url: requestURL, timeoutSeconds: requestTimeout))
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

    /// The core's unified-delay flag (GET /configs). Nil when the
    /// controller is unreachable or the key is absent — the caller
    /// treats that as "could not read", never as a failure.
    static func unifiedDelay() async -> Bool? {
        guard let url = URL(string: "http://\(address)/configs") else { return nil }
        do {
            let (data, response) = try await makeSession(timeoutSeconds: 5)
                .data(for: authorizedRequest(url: url, timeoutSeconds: 5))
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
