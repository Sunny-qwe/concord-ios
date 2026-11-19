import SwiftUI

// MARK: - DNS settings (FlClash: Tools -> 进阶配置 -> DNS)
// The DNS fields of the shared dns.json, merged into
// config.apply's overlay by the extension. Same fields as the
// 常规 page's DNS section; this page is the Advanced hub's entry.

struct DnsSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                Text("DNS 设置写入共享 dns.json，扩展在 config.apply 时把它作为 overlay 合并进去。改动后点「保存并应用」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("DNS") {
                Toggle("启用 DNS", isOn: $settingsStore.dnsEnabled)
                TextField("上游 DoH 地址", text: $settingsStore.dnsNameserver)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                Toggle("Fake-IP", isOn: $settingsStore.dnsFakeIpEnabled)
                TextField("Fake-IP 段，如 198.18.0.1/16", text: $settingsStore.dnsFakeIpRange)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section {
                Button("保存并应用") {
                    Task { await settingsStore.applyDnsSettings() }
                }
                if let message = settingsStore.dnsApplyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}
