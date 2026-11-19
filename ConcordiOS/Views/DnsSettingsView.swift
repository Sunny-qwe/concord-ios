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
                Picker("增强模式", selection: $settingsStore.dnsEnhancedMode) {
                    Text("普通").tag("normal")
                    Text("Fake-IP").tag("fake-ip")
                    Text("redir-host").tag("redir-host")
                    Text("hosts").tag("hosts")
                }
                .onChange(of: settingsStore.dnsEnhancedMode) { _, mode in
                    settingsStore.dnsFakeIpEnabled = (mode == "fake-ip")
                    settingsStore.save()
                }
                Toggle("Fake-IP", isOn: $settingsStore.dnsFakeIpEnabled)
                    .onChange(of: settingsStore.dnsFakeIpEnabled) { _, value in
                        settingsStore.dnsEnhancedMode = value ? "fake-ip" : "normal"
                        settingsStore.save()
                    }
                TextField("Fake-IP 段，如 198.18.0.1/16", text: $settingsStore.dnsFakeIpRange)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("Fake-IP 段（IPv6），如 2001:db8::/32", text: $settingsStore.dnsFakeIpRange6)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("监听地址，如 127.0.0.1:1053（留空为默认）", text: $settingsStore.dnsListen)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Toggle("使用 Hosts", isOn: $settingsStore.dnsUseHosts)
                Toggle("使用系统 Hosts", isOn: $settingsStore.dnsUseSystemHosts)
                Toggle("遵循规则", isOn: $settingsStore.dnsRespectRules)
                Toggle("优先 HTTP/3", isOn: $settingsStore.dnsPreferH3)
                Toggle("DNS 用 IPv6", isOn: $settingsStore.ipv6)
                Stepper("IPv6 超时：\(settingsStore.dnsIpv6Timeout) ms", value: $settingsStore.dnsIpv6Timeout, in: 0...10000, step: 10)
            }
            Section("上游与备用") {
                StringListEditor(items: $settingsStore.dnsExtraNameservers, placeholder: "其它解析服务器，如 tls://1.1.1.1:853")
                Text("主上游在上面；这里的会追加到 nameserver 列表里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                StringListEditor(items: $settingsStore.dnsFallback, placeholder: "备用解析服务器")
                Toggle("备用懒查询", isOn: $settingsStore.dnsFallbackLazyQuery)
                KeyValueListEditor(items: $settingsStore.dnsNameserverPolicy, keyPlaceholder: "域名 / 规则集", valuePlaceholder: "服务器")
                Text("解析策略：键是域名或规则集（如 geosite:cn），值是解析服务器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("代理与直连解析") {
                StringListEditor(items: $settingsStore.dnsProxyServerNameserver, placeholder: "代理节点解析服务器")
                KeyValueListEditor(items: $settingsStore.dnsProxyServerNameserverPolicy, keyPlaceholder: "域名 / 规则集", valuePlaceholder: "服务器")
                StringListEditor(items: $settingsStore.dnsDirectNameserver, placeholder: "直连解析服务器")
                Toggle("直连跟随解析策略", isOn: $settingsStore.dnsDirectNameserverFollowPolicy)
            }
            Section("Fake-IP") {
                Picker("Fake-IP 过滤模式", selection: $settingsStore.dnsFakeIpFilterMode) {
                    Text("黑名单").tag("blacklist")
                    Text("白名单").tag("whitelist")
                    Text("规则").tag("rule")
                }
                Stepper("Fake-IP TTL：\(settingsStore.dnsFakeIpTtl)", value: $settingsStore.dnsFakeIpTtl, in: 0...86400)
                StringListEditor(items: $settingsStore.dnsFakeIpFilter, placeholder: "域名，如 example.com")
                StringListEditor(items: $settingsStore.dnsDefaultNameserver, placeholder: "默认解析服务器 IP")
                Text("默认解析服务器：解析 Fake-IP 过滤域名和 nameserver 自身域名时用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("备用过滤（fallback-filter）") {
                Toggle("GeoIP 过滤", isOn: $settingsStore.dnsFallbackFilterGeoip)
                TextField("GeoIP 国家码，如 CN", text: $settingsStore.dnsFallbackFilterGeoipCode)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                StringListEditor(items: $settingsStore.dnsFallbackFilterGeosite, placeholder: "GeoSite，如 gfw")
                StringListEditor(items: $settingsStore.dnsFallbackFilterIpcidr, placeholder: "IP 段，如 1.2.3.0/24")
                StringListEditor(items: $settingsStore.dnsFallbackFilterDomain, placeholder: "域名")
            }
            Section("缓存") {
                Picker("缓存算法", selection: $settingsStore.dnsCacheAlgorithm) {
                    Text("LRU").tag("lru")
                    Text("ARC").tag("arc")
                }
                Stepper("缓存上限：\(settingsStore.dnsCacheMaxSize) 条", value: $settingsStore.dnsCacheMaxSize, in: 0...65536, step: 256)
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
