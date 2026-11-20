import SwiftUI

// MARK: - Hosts editor (FlClash: Tools -> 常规 -> Hosts)
// A hostname -> IP map merged into config.apply's overlay as
// "hosts" by the PacketTunnel extension (see its header comment).
// The core resolves these names to the given IPs before any DNS
// lookup. Stored in the App Group as hosts.json.

struct HostsView: View {
    @State private var hosts: [(host: String, ip: String)] = []
    @State private var newHost = ""
    @State private var newIp = ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("把域名映射到固定 IP，核心在 DNS 查询前先查这张表。修改后重启 VPN 生效（或在 常规 页点「应用到核心」后重启）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Hosts") {
                // FlClash MapEditView: values edit in place. Each
                // row is two text fields; leaving a field (submit)
                // or tapping 保存 writes hosts.json.
                ForEach(Array(hosts.enumerated()), id: \.offset) { index, _ in
                    HostRowView(hosts: $hosts, index: index, onSubmit: save)
                }
                .onDelete { offsets in
                    hosts.remove(atOffsets: offsets)
                    save()
                }
                if hosts.contains(where: { !Self.isValidIP($0.ip) }) {
                    Text("标红的 IP 格式不对：应为 IPv4（如 1.2.3.4）或 IPv6 地址。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
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
            }
            Section {
                Button("保存") {
                    save()
                }
                .disabled(hosts.contains(where: { $0.host.trimmingCharacters(in: .whitespaces).isEmpty || !Self.isValidIP($0.ip) }))
            }
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
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
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            hosts = []
            return
        }
        hosts = json.sorted { $0.key < $1.key }.map { (host: $0.key, ip: $0.value) }
    }

    private func save() {
        guard let url = fileURL else { return }
        // In-place editing can leave two rows with the same host;
        // the last one wins instead of trapping on a duplicate key.
        var dict: [String: String] = [:]
        for entry in hosts {
            let host = entry.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            dict[host] = entry.ip.trimmingCharacters(in: .whitespaces)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        message = "已保存：\(hosts.count) 条，重启 VPN 后生效"
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
private struct HostRowView: View {
    @Binding var hosts: [(host: String, ip: String)]
    let index: Int
    let onSubmit: () -> Void

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
        }
    }
}
