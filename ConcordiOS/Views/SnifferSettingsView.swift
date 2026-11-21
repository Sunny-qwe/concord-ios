import SwiftUI

// MARK: - Sniffer settings (FlClash: lib/views/config/sniffer.dart)
// The full sniffer section: the global toggles and lists plus one
// item per sniffed protocol (HTTP / TLS / QUIC), each with its own
// ports list and override-destination (跟随 / 覆盖开 / 覆盖关).
// Written to the shared sniffer.json, merged by the extension into
// config.apply's overlay as "sniffer".
//
// The master switch is the 通用 page's 流量嗅探 toggle: the
// effective enable is master && this page's own 启用. Turning the
// master off disables sniffing without losing these choices.

struct SnifferSettingsView: View {
    @ObservedObject private var snifferStore = SnifferStore.shared
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                Text("嗅探设置写入共享 sniffer.json，扩展在 config.apply 时把它作为 overlay 合并进去。改动后点「保存并应用」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("嗅探") {
                Toggle("启用嗅探", isOn: $snifferStore.enable)
                if !settingsStore.sniffing {
                    Text("通用里的「流量嗅探」总开关是关着的，嗅探当前不会生效（这里的设置会保留）。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Toggle("覆盖目标地址", isOn: $snifferStore.overrideDest)
                Toggle("强制 DNS 映射", isOn: $snifferStore.forceDnsMapping)
                Text("把嗅探到的域名映射回 Fake-IP。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("解析纯 IP", isOn: $snifferStore.parsePureIp)
            }
            Section("强制嗅探域名") {
                StringListEditor(items: $snifferStore.forceDomain, placeholder: "域名，如 example.com")
            }
            Section("跳过域名") {
                StringListEditor(items: $snifferStore.skipDomain, placeholder: "域名，如 example.com")
            }
            Section("跳过源地址") {
                StringListEditor(items: $snifferStore.skipSrcAddress, placeholder: "IP 或 CIDR，如 192.168.1.0/24")
            }
            Section("跳过目标地址") {
                StringListEditor(items: $snifferStore.skipDstAddress, placeholder: "IP 或 CIDR，如 10.0.0.0/8")
            }
            Section("嗅探协议") {
                SniffProtocolRow(title: "HTTP", config: $snifferStore.sniffHttp)
                SniffProtocolRow(title: "TLS", config: $snifferStore.sniffTls)
                SniffProtocolRow(title: "QUIC", config: $snifferStore.sniffQuic)
                Text("端口为空时按协议默认端口嗅探。覆盖目标地址选「跟随」时用上面总开关的值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存并应用") {
                    Task { await snifferStore.applySnifferSettings() }
                }
                if let message = snifferStore.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .navigationTitle("嗅探")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One sniffed protocol: its ports list plus the
/// override-destination choice (inherit / on / off).
private struct SniffProtocolRow: View {
    let title: String
    @Binding var config: SniffProtocolConfig
    @State private var newPort = ""
    @State private var portError: String?

    private var destLabel: String {
        switch config.overrideDest {
        case nil: return "跟随"
        case true: return "覆盖开"
        case false: return "覆盖关"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Text(config.ports.isEmpty ? "默认端口" : "\(config.ports.count) 个端口")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker("覆盖目标地址", selection: Binding(
                get: { config.overrideDest },
                set: { config.overrideDest = $0 }
            )) {
                Text("跟随").tag(nil as Bool?)
                Text("覆盖开").tag(true as Bool?)
                Text("覆盖关").tag(false as Bool?)
            }
            .pickerStyle(.segmented)
            ForEach(config.ports, id: \.self) { port in
                HStack {
                    Text(port)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        config.ports.removeAll { $0 == port }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("端口或范围，如 8080 或 8000-9000", text: $newPort)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") {
                    let value = newPort.trimmingCharacters(in: .whitespaces)
                    guard Self.isValidPortRange(value) else {
                        portError = "格式不对，应为端口号或起止范围，如 8080 或 8000-9000"
                        return
                    }
                    guard !config.ports.contains(value) else {
                        portError = "这个端口已存在"
                        return
                    }
                    portError = nil
                    config.ports.append(value)
                    newPort = ""
                }
                .disabled(newPort.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let portError {
                Text(portError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    static func isValidPortRange(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            guard let port = Int(part), (1...65535).contains(port) else { return false }
            return true
        }
    }
}
