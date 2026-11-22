import SwiftUI

// MARK: - Local network settings (FlClash: Tools -> 常规 -> 本地
// 网络设置， iOS only)
// Route exclusions and private-route bypass, applied by the
// PacketTunnel extension when it sets up the interface. The
// 系统代理 section holds FlClash's system-proxy switch and
// bypass-domain list (local_network.dart:68-73); the switch is
// stored in tunnel.json, and whether iOS honours it is unverified
// (see the section footnote).

struct LocalNetworkView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var newExclude = ""
    @State private var excludeError: String?

    /// FlClash's local-network-protection defaults.
    static let protectionCIDRs = ["127.0.0.0/8", "10.7.0.0/24", "::1/128"]

    var body: some View {
        List {
            Section("本地网络") {
                Toggle("本地网络保护", isOn: Binding(
                    get: { Self.protectionCIDRs.allSatisfy { settingsStore.routeExcludeAddress.contains($0) } },
                    set: { on in
                        if on {
                            for cidr in Self.protectionCIDRs where !settingsStore.routeExcludeAddress.contains(cidr) {
                                settingsStore.routeExcludeAddress.append(cidr)
                            }
                        } else {
                            settingsStore.routeExcludeAddress.removeAll { Self.protectionCIDRs.contains($0) }
                        }
                        settingsStore.save()
                    }
                ))
                Text("开启后 127.0.0.0/8、10.7.0.0/24、::1/128 不走隧道，本地服务（隔空投送、局域网设备等）不受影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("绕过私有路由", isOn: $settingsStore.bypassPrivateRoute)
                Text("开启后 10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16 不走隧道。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("路由排除地址") {
                ForEach(settingsStore.routeExcludeAddress, id: \.self) { cidr in
                    Text(cidr)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    settingsStore.routeExcludeAddress.remove(atOffsets: offsets)
                    settingsStore.save()
                }
                HStack {
                    TextField("CIDR，如 192.168.1.0/24", text: $newExclude)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("添加") {
                        addExclude()
                    }
                    .disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let excludeError {
                    Text(excludeError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            // FlClash local_network.dart:68-73: the system-proxy
            // section holds the system-proxy switch and the
            // bypass-domain list (footer: bypassDomainDesc). The
            // switch is stored in tunnel.json; whether iOS honours
            // it is unverified (the packet tunnel works through
            // interface routes), so the footnote says so instead of
            // claiming an effect.
            Section("系统代理") {
                Toggle("系统代理", isOn: $settingsStore.systemProxy)
                BypassDomainEditorView()
                Text("系统代理：上游 iOS 版提供的开关，随隧道设置保存；它是否影响 iOS 的系统代理行为尚未验证——iOS 的包隧道主要靠接口路由接管流量。绕过域名只在系统代理打开时传给 VPN 设置，开关关闭不会丢掉列表。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("网络") {
                Toggle("IPv6", isOn: $settingsStore.ipv6)
                Toggle("DNS 劫持", isOn: $settingsStore.dnsHijack)
                Picker("TUN 协议栈", selection: $settingsStore.tunStack) {
                    Text("gVisor").tag("gvisor")
                    Text("系统").tag("system")
                    Text("Lwip").tag("lwip")
                }
                Text("修改后保存，下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("保存") {
                    settingsStore.save()
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("本地网络设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addExclude() {
        let cidr = newExclude.trimmingCharacters(in: .whitespaces)
        guard NetworkSettingsView.isValidCIDR(cidr) else {
            excludeError = "格式不对，应为 a.b.c.d/n 或 IPv6 地址/n"
            return
        }
        guard !settingsStore.routeExcludeAddress.contains(cidr) else {
            excludeError = "这条已存在"
            return
        }
        excludeError = nil
        settingsStore.routeExcludeAddress.append(cidr)
        settingsStore.save()
        newExclude = ""
    }
}
