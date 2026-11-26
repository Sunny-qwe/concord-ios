import SwiftUI

// MARK: - Network settings (FlClash: Tools -> 进阶配置 -> 网络)
// TUN + interface + route settings. The TUN fields are the
// extension's parameters (tunnel.json); the route fields are
// applied by the extension when it sets up the tunnel interface
// (excluded routes bypass the tunnel, DNS hijacking decides
// whether the tunnel sets DNS servers).

struct NetworkSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var overrideStore = OverrideStore.shared
    @State private var newExclude = ""
    @State private var excludeError: String?
    @State private var newRouteAddress = ""
    @State private var routeAddressError: String?

    /// The global TUN override's route-address list (FlClash
    /// network.dart:254-271 RouteAddressItem; tun.route-address).
    /// It is the same key the TUN 覆盖 page edits — this page
    /// surfaces it directly, as FlClash's Network page does.
    private var routeAddresses: [String] {
        guard case .array(let items) = overrideStore.state(scope: nil, section: .tun)["route-address"] else { return [] }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private func setRouteAddresses(_ addresses: [String]) {
        overrideStore.setValue(scope: nil, section: .tun, key: "route-address", value: .array(addresses.map(JSONValue.string)))
    }

    /// FlClash's local-network-protection defaults (moved here
    /// from LocalNetworkView in v0.2.136 — M4: the Tools →
    /// 本地网络设置 row moves to Advanced → 网络）: these three
    /// CIDRs in routeExcludeAddress keep local services
    /// (AirDrop, LAN devices) out of the tunnel.
    static let protectionCIDRs = ["127.0.0.0/8", "10.7.0.0/24", "::1/128"]

    var body: some View {
        List {
            Section("TUN") {
                Toggle("启用 TUN", isOn: $settingsStore.tunEnabled)
                Picker("协议栈", selection: $settingsStore.tunStack) {
                    Text("gVisor").tag("gvisor")
                    Text("系统").tag("system")
                    Text("Lwip").tag("lwip")
                }
                // FlClash network.dart:350-356: MTU is a number item
                // bounded by minTunMtu/maxTunMtu (1280–65535). The
                // Settings TUN page uses the same Stepper range, so
                // both pages now agree (they disagreed before:
                // stepper 1280–9000 there, free field here).
                Stepper("MTU：\(settingsStore.tunMtu)", value: $settingsStore.tunMtu, in: 1280...65535, step: 100)
                TextField("DNS 服务器，逗号分隔", text: $settingsStore.tunDns)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section("网络") {
                // FlClash VpnSections (network.dart:474-524, iOS):
                // system proxy, bypass-domain, IPv6, DNS hijacking,
                // in that order. The switch + list write to
                // tunnel.json (SettingsStore); the list is only
                // passed to the VPN setup while the switch is on
                // (FlClash core.dart:247).
                Toggle("系统代理", isOn: $settingsStore.systemProxy)
                BypassDomainEditorView()
                Text("系统代理：上游 iOS 版提供的开关，随隧道设置保存；它是否影响 iOS 的系统代理行为尚未验证——iOS 的包隧道主要靠接口路由接管流量。绕过域名只在系统代理打开时传给 VPN 设置，开关关闭不会丢掉列表。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("IPv6", isOn: $settingsStore.ipv6)
                Toggle("DNS 劫持", isOn: $settingsStore.dnsHijack)
                Text("关闭后隧道不再设置 DNS 服务器，系统 DNS 保持原样，DNS 请求不走代理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("出站网卡模式", selection: $settingsStore.interfaceNameMode) {
                    Text("跟随订阅").tag("follow")
                    Text("清空").tag("clear")
                    Text("指定网卡").tag("custom")
                }
                if settingsStore.interfaceNameMode == "custom" {
                    TextField("网卡名，如 en0", text: $settingsStore.interfaceName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Text("跟随订阅：用订阅自己的 interface-name；清空：强制不绑定网卡；指定网卡：核心出站走这块网卡（还会作为 TUN 的自动检测依据）。写入 general-overlay.json，随 config.apply 的 overlay 下发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("TUN 覆盖（拥塞控制、路由、劫持…）") {
                    TunOverrideView()
                }
            }
            Section("系统隧道网络") {
                Toggle("包含所有网络", isOn: $settingsStore.includeAllNetworks)
                Toggle("排除本地网络", isOn: $settingsStore.excludeLocalNetworks)
                Toggle("排除 APN", isOn: $settingsStore.excludeAPNs)
                Toggle("排除蜂窝服务", isOn: $settingsStore.excludeCellularServices)
                Toggle("强制路由", isOn: $settingsStore.enforceRoutes)
                Toggle("排除设备间通信", isOn: $settingsStore.excludeDeviceCommunication)
                Text("iOS 隧道开关，下次启动 VPN 时生效；默认值与系统默认一致。包含所有网络会把全部流量送进隧道；其余几项把本地网络、运营商配置、蜂窝服务和设备间通信排除在外。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("路由") {
                // M4 (v0.2.136): the 本地网络保护 toggle, moved
                // from the deleted Tools → 本地网络设置 page — it
                // only manipulates routeExcludeAddress, which this
                // section already edits.
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
                Text("路由地址")
                    .font(.footnote.weight(.semibold))
                Text("走隧道的地址段（tun.route-address），与「TUN 覆盖」里的路由地址是同一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(routeAddresses, id: \.self) { cidr in
                    Text(cidr)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    var addresses = routeAddresses
                    addresses.remove(atOffsets: offsets)
                    setRouteAddresses(addresses)
                }
                HStack {
                    TextField("路由地址，如 0.0.0.0/0", text: $newRouteAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("添加") {
                        addRouteAddress()
                    }
                    .disabled(newRouteAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let routeAddressError {
                    Text(routeAddressError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(settingsStore.routeExcludeAddress, id: \.self) { cidr in
                    Text(cidr)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    settingsStore.routeExcludeAddress.remove(atOffsets: offsets)
                    settingsStore.save()
                }
                HStack {
                    TextField("排除地址，如 192.168.1.0/24", text: $newExclude)
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
            Section {
                Button("保存") {
                    settingsStore.save()
                }
                Text("保存后写入 tunnel.json，下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("网络")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRouteAddress() {
        let cidr = newRouteAddress.trimmingCharacters(in: .whitespaces)
        guard Self.isValidCIDR(cidr) else {
            routeAddressError = "格式不对，应为 a.b.c.d/n 或 IPv6 地址/n"
            return
        }
        guard !routeAddresses.contains(cidr) else {
            routeAddressError = "这条已存在"
            return
        }
        routeAddressError = nil
        setRouteAddresses(routeAddresses + [cidr])
        newRouteAddress = ""
    }

    private func addExclude() {
        let cidr = newExclude.trimmingCharacters(in: .whitespaces)
        guard Self.isValidCIDR(cidr) else {
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

    static func isValidCIDR(_ value: String) -> Bool {
        if value.contains(":") {
            let parts = value.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]), (0...128).contains(prefix) else { return false }
            return !parts[0].isEmpty
        }
        return SettingsStore.isValidIPv4CIDR(value)
    }
}

/// The bypass-domain list editor (FlClash network.dart
/// BypassDomainItem, in VpnSections and in the Network page's
/// system-proxy section). The list lives in
/// SettingsStore.bypassDomain and is written to tunnel.json (only
/// passed to the VPN setup while the system-proxy switch is on).
/// (v0.2.136: the second user, LocalNetworkView, was deleted with
/// the Tools → 本地网络设置 page — the editor now lives only here.)
struct BypassDomainEditorView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var newDomain = ""
    @State private var domainError: String?

    var body: some View {
        Text("绕过域名")
            .font(.footnote.weight(.semibold))
        ForEach(settingsStore.bypassDomain, id: \.self) { domain in
            HStack {
                Text(domain)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button {
                    settingsStore.bypassDomain.removeAll { $0 == domain }
                    settingsStore.save()
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            TextField("域名，如 example.com", text: $newDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") {
                addDomain()
            }
            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let domainError {
            Text(domainError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func addDomain() {
        let value = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.isValidDomain(value) else {
            domainError = "格式不对，应为域名，如 example.com"
            return
        }
        guard !settingsStore.bypassDomain.contains(value) else {
            domainError = "这个域名已存在"
            return
        }
        domainError = nil
        settingsStore.bypassDomain.append(value)
        settingsStore.save()
        newDomain = ""
    }

    /// A bare domain: labels of letters/digits/hyphens separated
    /// by dots, no leading/trailing dot or hyphen, no whitespace.
    /// Wildcards ("*.example.com") are rejected — FlClash's list
    /// holds plain domains.
    static func isValidDomain(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(" "), !value.contains("*"),
              !value.hasPrefix("."), !value.hasSuffix("."),
              !value.hasPrefix("-"), !value.hasSuffix("-") else { return false }
        return value.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }
}
