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
// Storage: UserDefaults, with the rest of the settings — there is
// no Keychain helper in the app, so the password is stored in the
// clear. Do not reuse a password that protects anything else.

struct GeneralAuthView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var authMessage: String?

    var body: some View {
        Form {
            Section {
                Text("本地入站鉴权：开启后，访问本机混合 / SOCKS 入站需要提供这里的账号密码。外部控制器密钥：外部工具（仪表盘等）连接核心控制器时用的密钥。两者都是配置字段，保存后随通用设置应用到核心。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("本地鉴权") {
                Toggle("启用鉴权", isOn: $settingsStore.authEnabled)
                if settingsStore.authEnabled {
                    TextField("账号", text: $settingsStore.authUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $settingsStore.authPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("账号里的冒号会被去掉：核心按第一个冒号切分 user:password，账号里有冒号会让鉴权失效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("外部控制器") {
                Toggle("开启外部控制器", isOn: $settingsStore.externalControllerEnabled)
                SecureField("控制器密钥", text: $settingsStore.externalControllerSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("控制器只在「开启」且密钥非空时打开（127.0.0.1:9090）。App 平时用隧道消息和核心通信，不走这个控制器；密钥是给外部仪表盘工具用的。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存并应用到核心（config.patch）") {
                    Task {
                        settingsStore.save()
                        await settingsStore.applyGeneralToCore()
                        authMessage = settingsStore.generalApplyMessage
                    }
                }
                if let authMessage {
                    Text(authMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("密码存在 UserDefaults（明文），没有 Keychain 保护：不要用其它地方的重要密码。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("鉴权与控制器")
        .navigationBarTitleDisplayMode(.inline)
    }
}
