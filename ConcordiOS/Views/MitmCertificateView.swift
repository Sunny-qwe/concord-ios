import SwiftUI

// MARK: - MITM certificate settings (FlClash: Tools -> MITM证书设置)
// The certificate side of MITM: CA status, generate, validate,
// issue a leaf certificate, share the CA PEM. The CA itself must
// be installed and trusted by the user in iOS Settings — the app
// cannot install a trusted CA. The exchange log lives in MitmView
// (reachable from 常规）.

struct MitmCertificateView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var issueHost = ""

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
