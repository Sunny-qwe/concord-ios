import SwiftUI

// MARK: - DNS settings (FlClash: Tools -> 进阶配置 -> DNS)
// The DNS fields of the shared dns.json, merged into
// config.apply's overlay by the extension. Same fields as the
// 常规 page's DNS section; this page is the Advanced hub's entry.

struct DnsSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    // FlClash dns.dart:191-193: listen-routing-mark number field.
    // Stored here until the SettingsStore owner wires it into
    // dns.json ("listen-routing-mark").
    @AppStorage("ConcordiOS.dnsListenRoutingMark") private var listenRoutingMark = 0

    /// Per-field validation (FlClash dns.dart: validateListenAddress
    /// on listen, validateCidr on the CIDR fields).
    private var listenIssue: String? {
        let value = settingsStore.dnsListen.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return Self.isValidListenAddress(value) ? nil : "监听地址格式不对，应为 IP 或 IP:端口，如 127.0.0.1:1053"
    }

    private var fakeIpRangeIssue: String? {
        let value = settingsStore.dnsFakeIpRange.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return SettingsStore.isValidIPv4CIDR(value) ? nil : "Fake-IP 段格式不对，应为 a.b.c.d/n"
    }

    private var fakeIpRange6Issue: String? {
        let value = settingsStore.dnsFakeIpRange6.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return NetworkSettingsView.isValidCIDR(value) ? nil : "Fake-IP 段（IPv6）格式不对，应为 IPv6 地址/n"
    }

    private var ipcidrIssue: String? {
        for cidr in settingsStore.dnsFallbackFilterIpcidr {
            if !NetworkSettingsView.isValidCIDR(cidr) {
                return "备用过滤里有一条 IP 段格式不对：\(cidr)"
            }
        }
        return nil
    }

    /// "IP" or "IP:port" (FlClash validateListenAddress).
    static func isValidListenAddress(_ value: String) -> Bool {
        let host: String
        if value.hasPrefix("[") {
            // [IPv6]:port
            guard let close = value.firstIndex(of: "]") else { return false }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return false }
            }
            return !host.isEmpty
        }
        let parts = value.split(separator: ":")
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port) else { return false }
            host = String(parts[0])
        } else if parts.count == 1 {
            host = value
        } else {
            return false
        }
        return isValidIP(host)
    }

    private static func isValidIP(_ host: String) -> Bool {
        if host.contains(":") { return !host.isEmpty }
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isNumber)
                && (Int(octet).map { (0...255).contains($0) } ?? false)
        }
    }

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
                    // No "hosts": the core rejects it as an
                    // enhanced-mode (FlClash dns.dart:95).
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
                if let fakeIpRangeIssue {
                    Text(fakeIpRangeIssue)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("Fake-IP 段（IPv6），如 2001:db8::/32", text: $settingsStore.dnsFakeIpRange6)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if let fakeIpRange6Issue {
                    Text(fakeIpRange6Issue)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("监听地址，如 127.0.0.1:1053（留空为默认）", text: $settingsStore.dnsListen)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if let listenIssue {
                    Text(listenIssue)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Stepper("监听路由标记：\(listenRoutingMark == 0 ? "默认" : "\(listenRoutingMark)")", value: $listenRoutingMark, in: 0...65535)
                    .onChange(of: listenRoutingMark) { _, _ in settingsStore.save() }
                Text("监听路由标记（listen-routing-mark）：DNS 监听套接字用的路由标记，0 为默认。改动随 DNS 设置保存，下次启动 VPN 或重载配置后生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                if let ipcidrIssue {
                    Text(ipcidrIssue)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
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
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
    }
}
