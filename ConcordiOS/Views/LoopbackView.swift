import SwiftUI

// MARK: - Loopback protection (FlClash: rule preset "防止代理回环"
// / rule_preset.dart blockLoopback)
// Traffic addressed to the device itself (127.0.0.0/8, 0.0.0.0,
// ::1, ::) must never be sent back into the proxy: the tunnel
// would hand it to the core, the core would hand it back to the
// tunnel, and the packet loops. FlClash ships this as a rule
// preset; here it is a switch that manages the same five rules in
// the added-rules overlay (AddedRulesStore): they are prepended
// before the profile's own rules, so they win over any user rule
// that would proxy loopback, and they take effect at the next VPN
// start (or immediately via 重新应用 when the tunnel runs) — the
// same timing as 附加规则， which uses the same overlay.

struct LoopbackView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var rulesStore = AddedRulesStore()
    @State private var applyMessage: String?

    var body: some View {
        List {
            Section("回环保护") {
                Toggle("防止代理回环", isOn: Binding(
                    get: { rulesStore.isLoopbackProtectionOn },
                    set: { rulesStore.setLoopbackProtection($0) }
                ))
                Text("开启后，发往本机的流量（127.0.0.0/8、0.0.0.0、::1、::）直接拦截，不进代理，避免代理把本机流量又送回隧道造成回环。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("生效的规则") {
                ForEach(AddedRulesStore.loopbackPresetRules, id: \.self) { rule in
                    Text(rule)
                        .font(.system(.body, design: .monospaced))
                }
            } footer: {
                if rulesStore.loopbackPresetPresentCount > 0,
                   !rulesStore.isLoopbackProtectionOn {
                    Text("检测到其中 \(rulesStore.loopbackPresetPresentCount) 条已被手动删除（在「附加规则」里），打开开关可补齐。")
                } else {
                    Text("这 5 条规则由上面的开关管理，会加到「附加规则」的最前面，优先于配置自身的规则；修改后下次启动 VPN 时生效，VPN 运行时可点「重新应用」立即生效。")
                }
            }
            Section {
                Button("重新应用（VPN 运行时立即生效）") {
                    Task {
                        applyMessage = await profileStore.reapplyActive() ?? "VPN 未运行：已保存，下次启动 VPN 时生效"
                    }
                }
                if let applyMessage {
                    Text(applyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("和本地网络保护的区别") {
                Text("「本地网络设置」里的本地网络保护是路由层面：不让回环地址进隧道；这里是规则层面：拦截进代理的回环流量。两个互补，可以一起开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("回环保护")
        .navigationBarTitleDisplayMode(.inline)
    }
}
