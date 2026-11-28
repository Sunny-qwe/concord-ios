import SwiftUI

// MARK: - Authentication + external-controller secret
// (FlClash: lib/views/config/general.dart — AuthenticationItem,
// AuthenticationAccountItem, AuthenticationPasswordItem,
// ExternalControllerSecretItem)
//
// The local inbound auth (account / password) and the
// external-controller secret are config fields: they travel via
// config.patch (core ConfigPatchParams accepts `secret`,
// `authentication` and `externalController`) and are written to
// general.json for the startup patch. Enabling auth sends one
// "user:password" line; disabling sends an empty list, which clears
// the auth in force. The controller only opens (127.0.0.1:9090)
// while enabled AND a secret is set, matching FlClash.
//
// v0.2.159: upstream has these rows INLINE in GeneralView
// (general.dart:119-186) — 认证 toggle → [账号, 密码 text rows];
// 外部控制器 toggle → [外部控制器密钥 text row, 允许跨域访问
// toggle]. Ours keeps the sub-page (the two toggles + fields are
// all here), but the 允许跨域访问 toggle is BLOCKED, not omitted
// silently: no SettingsStore field exists for it, ConcordClient's
// ConcordConfigPatchParams has no cors field, and general.json /
// general-overlay.json never carry it — the only place the value
// appears is FlClashBackup's export patch, hardcoded
// "external-controller-cors": true. Adding the toggle needs a
// SettingsStore field + patch plumbing (+ verifying the core's
// ConfigPatchParams accepts the key) — model work outside this
// change's files. See scratch/v0.2.159/reports/settings-cluster.md.
//
// Storage: UserDefaults, with the rest of the settings — there is
// no Keychain helper in the app, so the password is stored in the
// clear. Do not reuse a password that protects anything else.

struct GeneralAuthView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var authMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("本地入站鉴权：开启后，访问本机混合 / SOCKS 入站需要提供这里的账号密码。外部控制器密钥：外部工具（仪表盘等）连接核心控制器时用的密钥。两者都是配置字段，保存后随通用设置应用到核心。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "本地鉴权") {
                        // FlClash general.dart AuthenticationItem: enabling
                        // auth with empty fields auto-generates a random
                        // 8-char username + 16-char password.
                        UpstreamToggleRow(title: "启用鉴权", isOn: Binding(
                            get: { settingsStore.authEnabled },
                            set: { newValue in
                                settingsStore.authEnabled = newValue
                                if newValue, settingsStore.authUsername.isEmpty {
                                    settingsStore.authUsername = Self.randomSecret(length: 8)
                                    settingsStore.authPassword = Self.randomSecret(length: 16)
                                    authMessage = "已自动生成鉴权账号密码，记得保存。"
                                }
                                settingsStore.save()
                            }
                        ))
                        if settingsStore.authEnabled {
                            UpstreamDivider(leading: 16)
                            HStack(spacing: 16) {
                                TextField("账号", text: $settingsStore.authUsername)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.body)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            UpstreamDivider(leading: 16)
                            HStack(spacing: 16) {
                                SecureField("密码", text: $settingsStore.authPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.body)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        }
                    }
                    Text("账号里的冒号会被去掉：核心按第一个冒号切分 user:password，账号里有冒号会让鉴权失效。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: "外部控制器") {
                        // FlClash PatchClashConfig.ensureControllerSecret
                        // (clash_config.dart:2418): opening the controller
                        // with an empty secret generates a random 32-char
                        // one; closing it clears the secret.
                        UpstreamToggleRow(title: "开启外部控制器", isOn: Binding(
                            get: { settingsStore.externalControllerEnabled },
                            set: { newValue in
                                settingsStore.externalControllerEnabled = newValue
                                if newValue {
                                    if settingsStore.externalControllerSecret.isEmpty {
                                        settingsStore.externalControllerSecret = Self.randomSecret(length: 32)
                                        authMessage = "已自动生成控制器密钥。"
                                    }
                                } else {
                                    settingsStore.externalControllerSecret = ""
                                }
                                settingsStore.save()
                            }
                        ))
                        UpstreamDivider(leading: 16)
                        HStack(spacing: 16) {
                            SecureField("控制器密钥", text: $settingsStore.externalControllerSecret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    }
                    Text("控制器只在「开启」且密钥非空时打开（127.0.0.1:9090）。App 平时用隧道消息和核心通信，不走这个控制器；密钥是给外部仪表盘工具用的。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 8) {
                    UpstreamCardSection(header: nil) {
                        HStack(spacing: 16) {
                            Button("保存并应用到核心（config.patch）") {
                                Task {
                                    settingsStore.save()
                                    await settingsStore.applyGeneralToCore()
                                    authMessage = settingsStore.generalApplyMessage
                                }
                            }
                            .font(.body)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    }
                    if let authMessage {
                        Text(authMessage)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                    }
                    Text("密码存在 UserDefaults（明文），没有 Keychain 保护：不要用其它地方的重要密码。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .background(ConcordTheme.pageBackground)
        .tint(ConcordTheme.accent)
        .upstreamNavBar(title: "鉴权与控制器")
        .concordNavBarBackground()
    }

    /// FlClash common/string.dart generateRandomSecret: [a-zA-Z0-9].
    static func randomSecret(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}
