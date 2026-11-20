import Foundation
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
        case writeFailed(Error)
        case systemRefusedToOpen

        var errorDescription: String? {
            switch self {
            case .invalidPEM:
                return "CA 证书读不出来（PEM 格式不对），请点「刷新 CA 状态」重试"
            case .profileBuildFailed(let error):
                return "生成描述文件失败：\(error.localizedDescription)"
            case .writeFailed(let error):
                return "写描述文件失败：\(error.localizedDescription)"
            case .systemRefusedToOpen:
                return "系统没有打开描述文件。请确认 Safari 可用，或改用「分享 CA 证书（PEM）」把证书发到电脑上安装"
            }
        }
    }

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

    /// Writes ConcordCA.mobileconfig to the temp directory and asks
    /// iOS to open it — iOS routes .mobileconfig to the profile
    /// installer and prompts the user to install. Must be called on
    /// the main thread (UIApplication.shared.open). The completion
    /// reports whether iOS accepted the open, NOT whether the user
    /// finished installing — the app cannot observe the install
    /// itself, so a success here only means the system prompt was
    /// handed off.
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConcordCA.mobileconfig")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            completion(.failure(.writeFailed(error)))
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            completion(opened ? .success(()) : .failure(.systemRefusedToOpen))
        }
    }
}
