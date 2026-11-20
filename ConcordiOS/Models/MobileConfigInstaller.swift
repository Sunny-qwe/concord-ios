import Foundation
import Network
import UIKit

/// Builds and opens the .mobileconfig profile that installs the
/// Concord MITM CA into the iOS system trust store.
///
/// The app CANNOT install a trusted CA itself — there is no API for
/// it. The flow is: generate a standard configuration profile
/// (.mobileconfig) containing the CA certificate, hand it to iOS
/// with UIApplication.shared.open, and iOS prompts the user to
/// install it (Settings → General → VPN & Device Management).
/// After installing, the user still has to flip the "fully trust"
/// switch in Settings → General → About → Certificate Trust
/// Settings.
///
/// The profile is served over loopback HTTP, NOT opened as a file
/// URL: Safari / Settings cannot read a file inside the app
/// sandbox, so opening the tmp .mobileconfig file URL silently
/// failed (v0.2.40 bug 1 — "系统没有打开描述文件"). A tiny
/// NWListener on 127.0.0.1 serves the exact profile bytes with
/// Content-Type application/x-apple-aspen-config; Safari fetches
/// it and hands it to the profile installer. The listener lives
/// at most 60 s, or a few seconds after the app backgrounds.
///
/// The CA only ever reaches this installer as PEM text
/// (ConcordCertificateInfo.pem, from mitm.certificate /
/// mitm.generateCertificate over RPC — the core stores the CA as
/// <home>/mitm/ca.crt and the app never sees the raw file). The PEM
/// is base64-decoded to DER here; the profile carries the DER as a
/// base64 string in the com.apple.security.root payload — NOT the
/// PEM text.
enum MobileConfigInstaller {

    /// What goes wrong, in words the user can act on.
    enum InstallError: LocalizedError {
        case invalidPEM
        case profileBuildFailed(Error)
        case serverFailed(Error)
        case systemRefusedToOpen

        var errorDescription: String? {
            switch self {
            case .invalidPEM:
                return "CA 证书读不出来（PEM 格式不对），请点「刷新 CA 状态」重试"
            case .profileBuildFailed(let error):
                return "生成描述文件失败：\(error.localizedDescription)"
            case .serverFailed(let error):
                return "启动本地安装服务失败：\(error.localizedDescription)"
            case .systemRefusedToOpen:
                // No PEM-share fallback sentence here:
                // MitmCertificateView appends it once already —
                // putting it here too printed it twice
                // (v0.2.40 bug 1).
                return "系统没有打开描述文件。请确认 Safari 可用"
            }
        }
    }

    /// The live loopback server, kept alive while Safari fetches
    /// the profile — the open handoff returns long before Safari
    /// connects. Cleared when the server stops itself.
    private static var activeServer: LoopbackProfileServer?

    /// PEM text → DER bytes: drop the -----BEGIN/END CERTIFICATE-----
    /// armor lines and blank lines, base64-decode the rest.
    static func derData(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    }

    /// The .mobileconfig plist (XML) for one CA certificate.
    ///
    /// Top level: a "Configuration" profile; PayloadContent holds a
    /// single com.apple.security.root payload whose PayloadContent is
    /// the CA DER as Data (plist encodes it as <data> base64). Both PayloadUUIDs are fresh on
    /// every generation, so reinstalling after a CA regeneration
    /// never collides with the old profile.
    static func profileData(caDER: Data, displayName: String = "Concord CA") throws -> Data {
        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadIdentifier": "com.concord.ios.ca",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadDisplayName": displayName,
            "PayloadDescription": "Concord MITM 根证书，用于解密 HTTPS 流量。安装后还需在「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任。",
            // com.apple.security.root 的 PayloadContent 必须是 Data
            // 类型（plist 里写成 <data>，即 base64）；写成 String
            // 会被描述文件安装器拒绝。PropertyListSerialization
            // 会把 Data 编码成 <data>…</data>。
            "PayloadContent": caDER,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadIdentifier": "com.concord.ios.ca-profile",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadDisplayName": displayName,
            "PayloadDescription": "安装 Concord MITM 根证书（CA）。安装后还需在「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任，MITM 才能解密 HTTPS。",
            "PayloadContent": [certPayload],
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        } catch {
            throw InstallError.profileBuildFailed(error)
        }
    }

    /// Serves the profile over loopback HTTP and asks iOS to open
    /// it in Safari — Safari fetches the URL and hands the profile
    /// to the installer. Must be called on the main thread
    /// (UIApplication.shared.open). The completion reports whether
    /// iOS accepted the open, NOT whether the user finished
    /// installing — the app cannot observe the install itself, so
    /// a success here only means the system prompt was handed off.
    @MainActor
    static func install(caPEM: String, completion: @escaping (Result<Void, InstallError>) -> Void) {
        guard let der = derData(fromPEM: caPEM) else {
            completion(.failure(.invalidPEM))
            return
        }
        let data: Data
        do {
            data = try profileData(caDER: der)
        } catch {
            completion(.failure(error as? InstallError ?? .profileBuildFailed(error)))
            return
        }
        // A file URL inside the app sandbox cannot be opened by
        // Safari / Settings (v0.2.40 bug 1): serve the profile
        // over loopback HTTP instead.
        let server: LoopbackProfileServer
        do {
            server = try LoopbackProfileServer(data: data)
        } catch {
            completion(.failure(.serverFailed(error)))
            return
        }
        activeServer = server
        server.onStopped = { activeServer = nil }
        server.start { result in
            switch result {
            case .success(let url):
                UIApplication.shared.open(url, options: [:]) { opened in
                    completion(opened ? .success(()) : .failure(.systemRefusedToOpen))
                }
            case .failure(let error):
                activeServer = nil
                completion(.failure(error))
            }
        }
    }
}

/// One-shot loopback HTTP server for a single .mobileconfig.
///
/// NWListener on an ephemeral port, answering every request with
/// the profile bytes as application/x-apple-aspen-config. It
/// stops itself 60 s after starting, or shortly after the app
/// backgrounds — whichever comes first. The background stop has
/// a short grace period on purpose: Safari only fetches the
/// profile AFTER the app has already backgrounded, so cancelling
/// the listener the instant the app backgrounds would kill the
/// fetch. The payload is only the public CA certificate (no
/// private key), and the served URL is loopback-only — the
/// listener never leaves the device.
private final class LoopbackProfileServer {

    /// Hard cap on the server lifetime, from start.
    private static let maxLifetime: TimeInterval = 60
    /// Grace after backgrounding, for Safari to fetch the profile.
    private static let backgroundGrace: TimeInterval = 10

    private let listener: NWListener
    private let data: Data
    private var stopWorkItem: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var onReady: ((Result<URL, MobileConfigInstaller.InstallError>) -> Void)?

    /// Called when the server has fully stopped (timer, background
    /// grace, or failure), so the owner can drop its reference.
    var onStopped: (() -> Void)?

    init(data: Data) throws {
        self.data = data
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts listening; reports the loopback URL once the listener
    /// is ready (exactly once), or the failure.
    func start(completion: @escaping (Result<URL, MobileConfigInstaller.InstallError>) -> Void) {
        onReady = completion
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reportReady()
            case .failed(let error):
                self.report(.failure(.serverFailed(error)))
                self.stop()
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
        armStop(after: Self.maxLifetime)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Safari fetches only after we backgrounded: give it
            // a short grace instead of stopping instantly.
            self?.armStop(after: Self.backgroundGrace)
        }
    }

    /// Stops listening and releases the timer / observer. Safe to
    /// call more than once.
    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        listener.cancel()
        onReady = nil
        onStopped?()
    }

    /// Reports the result to the start completion exactly once;
    /// later listener failures (after a successful open) no longer
    /// report — the install flow is already handed off.
    private func report(_ result: Result<URL, MobileConfigInstaller.InstallError>) {
        guard let onReady else { return }
        self.onReady = nil
        onReady(result)
    }

    private func reportReady() {
        guard let port = listener.port else {
            report(.failure(.serverFailed(NWError.posix(.EADDRNOTAVAIL))))
            stop()
            return
        }
        report(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/ConcordCA.mobileconfig")!))
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Any request gets the same profile — the path is
                // irrelevant; read just enough to know a request
                // arrived, then answer.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, error in
                    guard let self else { return }
                    guard error == nil else {
                        connection.cancel()
                        return
                    }
                    self.sendProfile(on: connection)
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func sendProfile(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/x-apple-aspen-config\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// (Re-)arms the self-stop timer, cancelling any previous one.
    private func armStop(after seconds: TimeInterval) {
        stopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
