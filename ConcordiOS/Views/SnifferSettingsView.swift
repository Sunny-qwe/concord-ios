import SwiftUI

// MARK: - Sniffer settings (FlClash: lib/views/config/sniffer.dart)
// The full sniffer section: the global toggles and lists plus one
// item per sniffed protocol (HTTP / TLS / QUIC), each with its own
// ports list and override-destination (跟随 / 覆盖开 / 覆盖关).
// Written to the shared sniffer.json, merged by the extension into
// config.apply's overlay as "sniffer".
//
// The master switch is the 通用 page's 流量嗅探 toggle: the
// effective enable is master && this page's own 状态. Turning the
// master off disables sniffing without losing these choices.
//
// v0.2.159: upstream SnifferView is per-profile only (no global
// page, no General row) — this global page is kept because it is
// the only UI for the global override. Sections follow upstream
// (sniffer.dart:89-90: 选项 for the 8 option keys, 协议 for the 3
// protocol keys) and labels follow l10n_zh.dart (enable = 状态
// :1056, forceDnsMapping = 强制DNS映射 :1002, parsePureIp =
// 解析纯IP :1005, skipSrcAddress = 跳过来源地址 :1017). The
// 强制嗅探域名 description is upstream's forceDomainDesc
// (:1011). The master-off warning and the Fake-IP footnote are
// ours-only explanations, kept — they describe iOS behaviour
// upstream has no text for.

struct SnifferSettingsView: View {
    @ObservedObject private var snifferStore = SnifferStore.shared
    @EnvironmentObject private var settingsStore: SettingsStore

    /// Skip-address entries the core will ignore: valid entries are
    /// a plain IP or a CIDR (FlClash sniffer.dart validates the skip
    /// lists the same way; an invalid entry is silently skipped by
    /// the core, so it is flagged here instead).
    private var invalidSkipSrc: [String] {
        snifferStore.skipSrcAddress.filter { !Self.isValidSkipAddress($0) }
    }

    private var invalidSkipDst: [String] {
        snifferStore.skipDstAddress.filter { !Self.isValidSkipAddress($0) }
    }

    private static func isValidSkipAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") { return NetworkSettingsView.isValidCIDR(trimmed) }
        return isValidIP(trimmed)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("嗅探设置写入共享 sniffer.json，扩展在 config.apply 时把它作为 overlay 合并进去。改动后点「保存并应用」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                UpstreamCardSection(header: "选项") {
                    Toggle("状态", isOn: $snifferStore.enable)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    if !settingsStore.sniffing {
                        UpstreamDivider(leading: 16)
                        Text("通用里的「流量嗅探」总开关是关着的，嗅探当前不会生效（这里的设置会保留）。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    UpstreamDivider(leading: 16)
                    Toggle("覆盖目标地址", isOn: $snifferStore.overrideDest)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Toggle("强制DNS映射", isOn: $snifferStore.forceDnsMapping)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Text("把嗅探到的域名映射回 Fake-IP。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    Toggle("解析纯IP", isOn: $snifferStore.parsePureIp)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    snifferListBlock(
                        title: "强制嗅探域名",
                        items: $snifferStore.forceDomain,
                        placeholder: "域名，如 example.com",
                        footer: "强制嗅探域名中的域名同样会被嗅探，其余已有域名的连接不嗅探。"
                    )
                    UpstreamDivider(leading: 16)
                    snifferListBlock(
                        title: "跳过域名",
                        items: $snifferStore.skipDomain,
                        placeholder: "域名，如 example.com"
                    )
                    UpstreamDivider(leading: 16)
                    snifferListBlock(
                        title: "跳过来源地址",
                        items: $snifferStore.skipSrcAddress,
                        placeholder: "IP 或 CIDR，如 192.168.1.0/24",
                        footer: invalidSkipSrc.isEmpty ? nil : "以下地址格式不对（应为 IP 或 IP 段），核心会忽略：\(invalidSkipSrc.prefix(3).joined(separator: "、"))\(invalidSkipSrc.count > 3 ? " 等 \(invalidSkipSrc.count) 条" : "")",
                        footerIsError: !invalidSkipSrc.isEmpty
                    )
                    UpstreamDivider(leading: 16)
                    snifferListBlock(
                        title: "跳过目标地址",
                        items: $snifferStore.skipDstAddress,
                        placeholder: "IP 或 CIDR，如 10.0.0.0/8",
                        footer: invalidSkipDst.isEmpty ? nil : "以下地址格式不对（应为 IP 或 IP 段），核心会忽略：\(invalidSkipDst.prefix(3).joined(separator: "、"))\(invalidSkipDst.count > 3 ? " 等 \(invalidSkipDst.count) 条" : "")",
                        footerIsError: !invalidSkipDst.isEmpty
                    )
                }
                UpstreamCardSection(header: "协议") {
                    SniffProtocolRow(title: "HTTP", config: $snifferStore.sniffHttp)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    SniffProtocolRow(title: "TLS", config: $snifferStore.sniffTls)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    SniffProtocolRow(title: "QUIC", config: $snifferStore.sniffQuic)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    Text("端口为空时按协议默认端口嗅探。覆盖目标地址选「跟随」时用上面总开关的值。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                // v0.2.141 (C12-c1): per-profile sniffer overrides live
                // on this page now (FlClash SnifferView.profile), not
                // behind a link to the generic OverrideView.
                InlineProfileOverrideCard(section: .sniffer)
                VStack(alignment: .leading, spacing: 8) {
                    Button("保存并应用") {
                        Task { await snifferStore.applySnifferSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConcordTheme.accent)
                    .frame(maxWidth: .infinity)
                    if let message = snifferStore.applyMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "嗅探")
    }

    /// One list key inside the 选项 card: its label row, the
    /// inline list editor, and an optional footnote (an upstream
    /// key description, or an invalid-entry warning in red).
    private func snifferListBlock(
        title: String,
        items: Binding<[String]>,
        placeholder: String,
        footer: String? = nil,
        footerIsError: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(Color(.label))
            StringListEditor(items: items, placeholder: placeholder)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(footerIsError ? Color.red : ConcordTheme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One sniffed protocol: its ports list plus the
/// override-destination choice (inherit / on / off).
private struct SniffProtocolRow: View {
    let title: String
    @Binding var config: SniffProtocolConfig
    @State private var newPort = ""
    @State private var portError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Spacer()
                Text(config.ports.isEmpty ? "默认" : "\(config.ports.count) 项")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
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
