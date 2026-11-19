import SwiftUI
import Security

// MARK: - MITM certificate settings (FlClash: Tools -> MITM证书设置)
// The certificate side of MITM: CA status, generate, validate,
// issue a leaf certificate, share the CA PEM. The CA itself must
// be installed and trusted by the user in iOS Settings — the app
// cannot install a trusted CA. The exchange log lives in MitmView
// (reachable from 常规）.
//
// Trust check (FlClash: lib/common/mitm_trust.dart
// IOSMitmTrustStore.check): the core signs a leaf for
// mitm-check.concord.invalid and the leaf is evaluated against the
// system trust store with SecTrust. It only runs locally and never
// leaves the device: a pass means the CA is installed AND fully
// trusted; a fail means it is missing or its "fully trust" switch
// is still off in Settings → General → About → Certificate Trust
// Settings. The check cannot tell those two apart — iOS does not
// let an app list the system store — so the UI says so.

struct MitmCertificateView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var issueHost = ""
    @State private var trustResult: MitmTrustResult?
    @State private var isCheckingTrust = false

    var body: some View {
        List {
            Section {
                Text("MITM 需要把 CA 证书装到系统里并信任：在「设置 → 通用 → VPN 与设备管理」安装描述文件，再到「关于本机 → 证书信任设置」里打开完全信任。应用本身装不了系统证书。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("CA 证书") {
                if settingsStore.mitmAvailable, let info = settingsStore.mitmCertificate {
                    labeled("主题", info.subject)
                    labeled("指纹", info.fingerprint)
                    labeled("有效期自", info.notBefore)
                    labeled("有效期至", info.notAfter)
                    ShareLink("分享 CA 证书（PEM）", item: info.pem)
                } else {
                    Text(settingsStore.mitmStatusMessage ?? "尚未读取 CA 状态")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("刷新 CA 状态") {
                    Task { await settingsStore.refreshMitmStatus() }
                }
                Button("生成 CA 证书") {
                    Task { await settingsStore.generateMitmCertificate() }
                }
            }
            Section("信任检测") {
                Text("检测会请核心签发一张 mitm-check.concord.invalid 的叶证书，再用系统信任库验证它（只在本地验证，不联网）。通过 = CA 已安装且已完全信任；不通过 = CA 还没装，或装了但没在「证书信任设置」里打开完全信任——本应用无法区分这两种情况。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let trustResult {
                    HStack {
                        Image(systemName: trustResult.isReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(trustResult.isReady ? .green : .orange)
                        Text(trustResult.message)
                            .font(.footnote)
                    }
                }
                if isCheckingTrust {
                    ProgressView()
                }
                Button("检测信任状态") {
                    Task { await checkTrust() }
                }
                .disabled(isCheckingTrust || !settingsStore.mitmAvailable || settingsStore.mitmCertificate == nil)
            }
            Section("MITM 配置") {
                Toggle("启用 MITM", isOn: $settingsStore.mitmEnabled)
                Toggle("解密 TLS", isOn: $settingsStore.mitmDecryptTls)
                TextField("解密域名，逗号分隔", text: $settingsStore.mitmHostnames)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("校验 MITM 配置") {
                    Task { await settingsStore.validateMitmConfig() }
                }
                if !settingsStore.mitmIssues.isEmpty {
                    ForEach(settingsStore.mitmIssues, id: \.self) { issue in
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Button("保存并应用") {
                    Task { await settingsStore.applyMitmSettings() }
                }
            }
            Section("签发叶证书") {
                TextField("主机名，如 example.com", text: $issueHost)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("签发") {
                    Task { await settingsStore.issueMitmCertificate(host: issueHost) }
                }
                .disabled(issueHost.trimmingCharacters(in: .whitespaces).isEmpty)
                if let pem = settingsStore.mitmIssuedPem {
                    ShareLink("分享叶证书（PEM）", item: pem)
                }
            }
            if let message = settingsStore.mitmStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("MITM 证书设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settingsStore.refreshMitmStatus()
        }
    }

    /// FlClash IOSMitmTrustStore.check, in-process: the core signs
    /// a leaf for the check host (mitm.issueCertificate) and the
    /// leaf is evaluated against the system trust store. No CA, no
    /// live core, or a failed issuance means "cannot check", not
    /// "untrusted" — those are reported separately.
    private func checkTrust() async {
        guard settingsStore.client.mode == .live else {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：示例模式没有真实核心")
            return
        }
        guard settingsStore.mitmCertificate != nil else {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：尚未生成 CA 证书")
            return
        }
        isCheckingTrust = true
        defer { isCheckingTrust = false }
        do {
            let leafPem = try await settingsStore.client
                .mitmIssueCertificate(host: MitmTrustResult.checkHost).pem
            guard let leafData = Self.derData(fromPEM: leafPem),
                  let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "无法检测：核心签发的叶证书读不出来")
                return
            }
            var trust: SecTrust?
            let policy = SecPolicyCreateSSL(true, MitmTrustResult.checkHost as CFString)
            guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess,
                  let trust else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "无法检测：系统信任评估创建失败")
                return
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                trustResult = MitmTrustResult(
                    isReady: true,
                    message: "CA 已安装并受信任：HTTPS 可以解密")
            } else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "CA 未受信任：还没安装，或安装后没在「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任")
            }
        } catch {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：\(error.localizedDescription)")
        }
    }

    /// PEM text to DER bytes (strip the armor lines, base64-decode).
    private static func derData(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: body)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// One trust-check outcome (FlClash MitmTrustCheck, iOS subset:
/// ready / untrusted — iOS cannot tell "not installed" from
/// "installed but not fully trusted", so both are "untrusted" with
/// the explanation in the message).
private struct MitmTrustResult {
    /// The leaf the core signs for the trust store to verify
    /// (FlClash mitmCheckHost, renamed for this app).
    static let checkHost = "mitm-check.concord.invalid"

    var isReady: Bool
    var message: String
}
