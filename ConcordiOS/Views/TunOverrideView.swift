import SwiftUI

// MARK: - TUN override page (FlClash: lib/views/config/tun.dart)
// The TUN override keys beyond the base enable / stack / MTU in
// 网络设置：拥塞控制、严格路由、路由地址、DNS 劫持、UDP 超时、
// ICMP 转发、GSO、网卡与 UID / 端口过滤。FlClash's tun.dart is
// itself an override page (global patch + per-profile), so this
// page is the Override framework's TUN section on its own page,
// with the same scope picker and YAML preview.
//
// How the keys reach the core: the extension merges the effective
// tun overrides into config.apply's overlay as "tun" (the core
// parses them into TunConfig), and mtu + congestion-controller
// are additionally folded into tun.start via tunnel.json
// (readTunnelSettings). BUT on iOS only mtu +
// congestion-controller have any effect: the rest only enter
// Applied.tun, whose DeviceSource::Create path never runs on
// iOS (config B12) — the packet-channel TUN is the only data
// plane. The per-key descriptions in OverrideStore say so, this
// page says so, and the save button below deliberately does NOT
// live-apply (a live config.apply touching the tun triple would
// close the channel runner and never restart it — config B1).
// enable / device / stack / auto-route stay owned by the
// extension and are never overridden here: on iOS the device is
// the packet channel, not a named interface.
//
// v0.2.141 (C13-c1): the button below routes through
// OverrideStore.applyTunOverrides() — the same save path as the
// sibling pages' apply buttons, but it never live-applies to a
// running tunnel (config B1). v0.2.141 (C13-c2): the
// congestion-controller key is gated on the core's capability
// (MuYu tunCongestionAvailable) — see OverrideStore /
// OverrideSectionEditor; the capability is refreshed on appear.

struct TunOverrideView: View {
    @ObservedObject private var store = OverrideStore.shared
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var scope: String? = nil
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("TUN 覆盖只对启用的项生效：没启用的项用订阅自己的值。全局覆盖对所有订阅生效，单个订阅的覆盖优先于全局。启用、协议栈、MTU 基础值在「网络」页；这里的 MTU 覆盖会盖掉它。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("iOS 上只有两项真正生效——MTU 和拥塞控制（下次启动 VPN 时经 tun.start 应用）。其余项在 iOS 上无效：严格路由、路由地址、排除路由地址、DNS 劫持、UDP 超时、禁用 ICMP 转发、GSO、包含/排除网卡、包含/排除 UID、排除源端口、排除目标端口、回流地址——它们只进核心的 TUN 设备创建路径，而 iOS 的包通道 TUN 从不走那条路（核心接受回流地址但尚未实现）。每项在行内和添加页也有同样的说明；改这些无效项不会改变任何行为。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("作用范围") {
                Picker("作用范围", selection: $scope) {
                    Text("全局（全部订阅）").tag(nil as String?)
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString as String?)
                    }
                }
                .pickerStyle(.menu)
            }
            // MuYu gates the congestion-controller field on the
            // core's capability (tunCongestionAvailable): the
            // check lives here on the TUN page, and the add sheet
            // hides the key when the core reports no congestion
            // controller (OverrideSectionEditor, C13-c2). The
            // capability is refreshed on appear so the gate has a
            // value before the user opens the add sheet.
            Section("拥塞控制支持") {
                Button("检查核心是否支持拥塞控制") {
                    Task {
                        await settingsStore.refreshDeveloperInfo()
                        await store.refreshCongestionCapability()
                    }
                }
                if let capabilities = settingsStore.capabilities {
                    if capabilities.congestionControllers.isEmpty {
                        Text("核心没有报告可用的拥塞控制算法：这里的拥塞控制覆盖可能不会生效，添加页里也不会提供该项。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text("核心支持的拥塞控制算法：\(capabilities.congestionControllers.joined(separator: "、"))。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("点上面按钮向核心查询支持的拥塞控制算法。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            OverrideSectionEditor(section: .tun, scope: $scope)
            Section("YAML 预览") {
                Text(tunYamlText())
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "已复制" : "复制 YAML") {
                    UIPasteboard.general.string = tunYamlText()
                    copied = true
                }
            }
            Section {
                // B12 + config B1: this page deliberately does NOT
                // live-apply to a running tunnel — see
                // OverrideStore.applyTunOverrides(). Save only:
                // MTU / congestion-controller take effect at the
                // next VPN start (via tun.start); the dead keys
                // take effect never, as noted above.
                Button("应用覆盖") {
                    Task { await store.applyTunOverrides() }
                }
                if let message = store.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("TUN 覆盖在下次启动 VPN 时生效：运行中的隧道不会因为改了覆盖就重建 TUN 设备。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("TUN 覆盖")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // C13-c2: refresh the congestion capability on appear
            // so the add sheet's gate has a value (unknown still
            // offers the key — see OverrideSectionEditor).
            if store.congestionControllers == nil {
                await store.refreshCongestionCapability()
            }
        }
    }

    private func tunYamlText() -> String {
        let values = store.state(scope: scope, section: .tun)
        guard !values.isEmpty else { return "# 暂无覆盖项\n" }
        return YAMLValue.lines(for: .object(["tun": .object(OverrideStore.expanded(values))]), indent: 0)
            .joined(separator: "\n") + "\n"
    }
}
