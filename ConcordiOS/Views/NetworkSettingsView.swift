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

    var body: some View {
        List {
            Section("TUN") {
                Toggle("启用 TUN", isOn: $settingsStore.tunEnabled)
                Picker("协议栈", selection: $settingsStore.tunStack) {
                    Text("gVisor").tag("gvisor")
                    Text("系统").tag("system")
                }
                HStack {
                    Text("MTU")
                    Spacer()
                    TextField("1500", value: $settingsStore.tunMtu, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                TextField("DNS 服务器，逗号分隔", text: $settingsStore.tunDns)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section("网络") {
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
            Section("路由") {
                Toggle("绕过私有路由", isOn: $settingsStore.bypassPrivateRoute)
                Text("开启后 10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16 不走隧道。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("路由地址")
                    .font(.system(size: 13, weight: .semibold))
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
