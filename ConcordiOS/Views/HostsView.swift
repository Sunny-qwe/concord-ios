import SwiftUI

// MARK: - Hosts editor (FlClash: Tools -> 常规 -> Hosts)
// A hostname -> IP map merged into config.apply's overlay as
// "hosts" by the PacketTunnel extension (see its header comment).
// The core resolves these names to the given IPs before any DNS
// lookup. Stored in the App Group as hosts.json.
//
// B16: the overlay `hosts` REPLACES the active subscription's
// whole hosts section, so saving only this page's list used to
// silently drop the subscription's own hosts. This page now also
// loads the subscription's hosts (read-only, marked as such) and
// saves the MERGED set (user entries win on a conflict), so a
// save can never drop subscription hosts.
//
// v0.2.159: upstream MapEditView (general.dart:98-111) shows only
// the user's own hosts map and saves on edit/close. Kept here:
// the 订阅自带（只读） section (the merge that protects
// subscription hosts depends on showing them) and the 保存 button
// (our edits are staged — removing it would change save
// semantics). Restyled to the upstream button (FilledButton
// equivalent). Not added: upstream's per-key MITM-takeover note
// (general.dart:104-110) — no such data is plumbed to this page.

struct HostsView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var hosts: [(host: String, ip: String)] = []
    /// The active subscription's own hosts (read-only here).
    @State private var subscriptionHosts: [(host: String, ip: String)] = []
    @State private var newHost = ""
    @State private var newIp = ""
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("把域名映射到固定 IP，核心在 DNS 查询前先查这张表。修改后重启 VPN 生效（或在 常规 页点「应用到核心」后重启）。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                if !subscriptionHosts.isEmpty {
                    UpstreamCardSection(header: "订阅自带（只读）") {
                        ForEach(Array(subscriptionHosts.enumerated()), id: \.offset) { index, entry in
                            if index > 0 { UpstreamDivider(leading: 16) }
                            HStack {
                                Text(entry.host)
                                    .font(.body)
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(entry.ip)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 56)
                        }
                    }
                    Text("这些来自当前订阅，在这里不能删除或修改（改订阅本身才能去掉）；每次保存都会一并保留，不会丢。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
                UpstreamCardSection(header: "Hosts") {
                    // FlClash MapEditView: values edit in place. Each
                    // row is two text fields; leaving a field (submit)
                    // or tapping 保存 writes hosts.json.
                    ForEach(Array(hosts.enumerated()), id: \.offset) { index, _ in
                        if index > 0 { UpstreamDivider(leading: 16) }
                        HostRowView(hosts: $hosts, index: index, onSubmit: save, onDelete: {
                            hosts.remove(at: index)
                            save()
                        })
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 56)
                    }
                    if hosts.contains(where: { !Self.isValidIP($0.ip) }) {
                        if !hosts.isEmpty { UpstreamDivider(leading: 16) }
                        Text("标红的 IP 格式不对：应为 IPv4（如 1.2.3.4）或 IPv6 地址。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    if !hosts.isEmpty { UpstreamDivider(leading: 16) }
                    HStack {
                        TextField("域名，如 example.com", text: $newHost)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("IP", text: $newIp)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .frame(width: 120)
                        Button("添加") {
                            addHost()
                        }
                        .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || newIp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("保存") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConcordTheme.accent)
                    .frame(maxWidth: .infinity)
                    .disabled(hosts.contains(where: { $0.host.trimmingCharacters(in: .whitespaces).isEmpty || !Self.isValidIP($0.ip) }))
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "Hosts")
        .onAppear { load() }
    }

    static func isValidIP(_ value: String) -> Bool {
        let ip = value.trimmingCharacters(in: .whitespaces)
        if ip.contains(":") { return ip.count >= 2 && !ip.hasPrefix(":") && !ip.hasSuffix(":") }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isNumber)
                && (Int(octet).map { (0...255).contains($0) } ?? false)
        }
    }

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: ConfigStore.hostsFileName)
    }

    private func load() {
        subscriptionHosts = Self.subscriptionHosts(from: profileStore.activeProfileYAML())
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            hosts = []
            return
        }
        // hosts.json may already hold a merged set (written by
        // save() below): entries identical to a subscription host
        // are shown in the read-only section, not duplicated here.
        // A same-host entry with a DIFFERENT IP stays: it is a
        // user override and wins on save.
        let subByHost: [String: String] = subscriptionHosts.reduce(into: [:]) { $0[$1.host] = $1.ip }
        hosts = json.sorted { $0.key < $1.key }
            .filter { subByHost[$0.key] != $0.value }
            .map { (host: $0.key, ip: $0.value) }
    }

    private func save() {
        guard let url = fileURL else { return }
        // B16: save the MERGED set — subscription hosts first,
        // then the user's entries (user wins on a conflict) — so
        // the overlay never drops the subscription's hosts.
        var dict: [String: String] = [:]
        for entry in subscriptionHosts {
            dict[entry.host] = entry.ip
        }
        // In-place editing can leave two rows with the same host;
        // the last one wins instead of trapping on a duplicate key.
        for entry in hosts {
            let host = entry.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            dict[host] = entry.ip.trimmingCharacters(in: .whitespaces)
        }
        let userCount = Set(hosts.map { $0.host.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).count
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        message = "已保存：\(dict.count) 条（你的 \(userCount) 条 + 订阅自带 \(subscriptionHosts.count) 条），重启 VPN 后生效"
    }

    /// The active subscription's own `hosts:` mapping, parsed out
    /// of its YAML text (block style, plus a simple one-line flow
    /// map `hosts: {a: 1.2.3.4}`). Values may be quoted; comment
    /// lines and blank lines are skipped; parsing stops at the
    /// next top-level key.
    static func subscriptionHosts(from yaml: String?) -> [(host: String, ip: String)] {
        guard let yaml else { return [] }
        let lines = yaml.components(separatedBy: "\n")
        guard let keyIndex = lines.firstIndex(where: { $0 == "hosts:" || $0.hasPrefix("hosts: ") }) else { return [] }
        let rest = lines[keyIndex].dropFirst("hosts:".count).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            if rest == "{}" || rest == "null" || rest == "~" { return [] }
            if rest.hasPrefix("{") { return parseFlowHosts(String(rest)) }
            return []
        }
        var out: [(host: String, ip: String)] = []
        var i = keyIndex + 1
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            // A non-indented line starts the next top-level key.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { i += 1; continue }
            guard let colon = trimmed.firstIndex(of: ":") else { i += 1; continue }
            let host = unquote(String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces))
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            let ip = unquote(value)
            if !host.isEmpty, !ip.isEmpty { out.append((host: host, ip: ip)) }
            i += 1
        }
        return out
    }

    /// Parse a one-line flow map `hosts: {a: 1.2.3.4, "b.c": "5.6.7.8"}`.
    private static func parseFlowHosts(_ text: String) -> [(host: String, ip: String)] {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return [] }
        body = String(body.dropFirst().dropLast())
        var parts: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in body {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        var out: [(host: String, ip: String)] = []
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let host = unquote(String(part[..<colon]))
            let ip = unquote(String(part[part.index(after: colon)...]))
            if !host.isEmpty, !ip.isEmpty { out.append((host: host, ip: ip)) }
        }
        return out
    }

    private static func unquote(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2,
           (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        let ip = newIp.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !ip.isEmpty else { return }
        if let index = hosts.firstIndex(where: { $0.host == host }) {
            hosts[index].ip = ip
        } else {
            hosts.append((host: host, ip: ip))
            hosts.sort { $0.host < $1.host }
        }
        newHost = ""
        newIp = ""
        save()
    }
}

/// One hosts row, extracted into its own view so the List body stays
/// trivial for the type checker (the inline row with two Bindings
/// previously defeated ForEach overload resolution and type-checking).
/// The delete button is explicit: this page is a ScrollView card now
/// (v0.2.159), so the List swipe-to-delete the old version used no
/// longer applies.
private struct HostRowView: View {
    @Binding var hosts: [(host: String, ip: String)]
    let index: Int
    let onSubmit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            TextField("域名", text: Binding(
                get: { hosts[index].host },
                set: { hosts[index].host = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { onSubmit() }
            TextField("IP", text: Binding(
                get: { hosts[index].ip },
                set: { hosts[index].ip = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(width: 120)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(HostsView.isValidIP(hosts[index].ip) ? Color.primary : Color.red)
            .onSubmit { onSubmit() }
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}
