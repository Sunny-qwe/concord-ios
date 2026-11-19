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
                ForEach(hosts.indices, id: \.self) { index in
                    HStack {
                        Text(hosts[index].host)
                        Spacer()
                        Text(hosts[index].ip)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .onDelete { offsets in
                    hosts.remove(atOffsets: offsets)
                    save()
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
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
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
        let dict = Dictionary(uniqueKeysWithValues: hosts.map { ($0.host, $0.ip) })
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
