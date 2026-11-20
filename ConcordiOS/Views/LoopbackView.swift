import SwiftUI

// MARK: - Loopback addresses (Egern-style 虚拟接口回流地址)
//
// NOT the FlClash blockLoopback rule preset — that is a separate
// thing (five REJECT rules for 127.0.0.0/8, 0.0.0.0, ::1, :: and a
// TUN port-853 rule) and now lives as a toggle at the top of
// AddedRulesView. This page is the tun.loopback-address list:
// TCP connections to these IPv4 addresses loop back to the local
// machine on the virtual interface, so the app can reach its own
// services through a peer address.
//
// Core status, verified against upstream 165154c (do not take the
// key's presence as proof it works): the key IS registered —
// crates/config/src/keys.rs TUN_T2 ("loopback-address") and
// schema/config-schema.json "t2" both list it — but
// TunConfig::from_map (crates/config/src/tun.rs) never reads it:
// the struct has no loopback field, so the core accepts the key
// and silently ignores it. The engine's LoopbackGuard
// (crates/net/src/loopback.rs) only remembers the core's own
// DIRECT sockets to refuse its own traffic coming back; it takes
// no configurable addresses. The tunnel interface address is
// 198.18.0.1 (PacketTunnelProvider), so 10.7.0.1 is a peer
// address, not the interface's own. The addresses below are
// therefore stored and sent with the config, but do not change
// routing in this build — the page says so in plain text.
//
// Wiring: the list is the global .tun "loopback-address" override
// (OverrideStore specs, kind .stringList, default ["10.7.0.1"]),
// so it lands in the config.apply tun overlay and takes effect
// at the next VPN start, like other tun overrides. First visit
// seeds the default once (seeded flag below); deleting all
// addresses removes the key and is not re-seeded.

struct LoopbackView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var overrideStore = OverrideStore.shared
    @State private var showAddAlert = false
    @State private var newAddress = ""
    @State private var errorMessage: String?
    @State private var applyMessage: String?

    /// The tunnel interface's own address (PacketTunnelProvider):
    /// a loopback address may never be this.
    private static let tunnelAddress = "198.18.0.1"
    private static let seededFlag = "ConcordiOS.loopbackSeeded.v1"

    private var addresses: [String] {
        guard case .array(let items) = overrideStore.state(scope: nil, section: .tun)["loopback-address"] else {
            return []
        }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private func saveAddresses(_ list: [String]) {
        if list.isEmpty {
            overrideStore.removeKey(scope: nil, section: .tun, key: "loopback-address")
        } else {
            overrideStore.setValue(scope: nil, section: .tun, key: "loopback-address", value: .array(list.map(JSONValue.string)))
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    newAddress = ""
                    showAddAlert = true
                } label: {
                    Text("添加地址…")
                        .foregroundStyle(ConcordTheme.accent)
                }
                ForEach(addresses, id: \.self) { address in
                    Text(address)
                        .font(.system(size: 13))
                }
                .onDelete { offsets in
                    var list = addresses
                    list.remove(atOffsets: offsets)
                    saveAddresses(list)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("虚拟接口回流地址")
            } footer: {
                Text("发往这些 IPv4 地址的 TCP 连接会在虚拟接口上折返回本机，让 App 能通过一个对端地址连上本机自身的服务。地址不能属于 127.0.0.0/8，也不能是虚拟接口自身的地址。只要配置了地址，虚拟接口就仅使用 IPv4，IPv6 设置只对本应用自身的出站连接生效。")
                    .font(.system(size: 13))
            }
            Section {
                Text("当前版本说明：核心接受 tun.loopback-address 这个配置项，但尚未实现回流路由——地址会保存并随配置发给核心，在本版本中还不会改变实际路由。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("重新应用（VPN 运行时立即生效）") {
                    Task {
                        applyMessage = await profileStore.reapplyActive() ?? "VPN 未运行：已保存，下次启动 VPN 时生效"
                    }
                }
                if let applyMessage {
                    Text(applyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("虚拟接口回流地址")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            seedDefaultIfNeeded()
        }
        .alert("添加地址", isPresented: $showAddAlert) {
            TextField("例如 10.7.0.1", text: $newAddress)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("添加") { addAddress() }
        } message: {
            Text("输入一个 IPv4 地址，不能属于 127.0.0.0/8，也不能是虚拟接口自身的地址 198.18.0.1。")
        }
    }

    /// Seeds the Egern default (10.7.0.1) exactly once, on first
    /// visit, when the key has never been set. A user who deletes
    /// every address is not re-seeded: the flag stays set.
    private func seedDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededFlag) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededFlag)
        if overrideStore.state(scope: nil, section: .tun)["loopback-address"] == nil {
            overrideStore.setValue(scope: nil, section: .tun, key: "loopback-address", value: .array([.string("10.7.0.1")]))
        }
    }

    private func addAddress() {
        let candidate = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = validationError(for: candidate) {
            errorMessage = problem
            return
        }
        errorMessage = nil
        saveAddresses(addresses + [candidate])
    }

    /// Rejects invalid IPv4, 127.0.0.0/8, the tunnel's own address
    /// and duplicates, with a reason the page shows inline.
    private func validationError(for text: String) -> String? {
        guard !text.isEmpty else { return "请输入一个 IPv4 地址" }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.count <= 3
                      && part.allSatisfy({ $0.isASCII && $0.isNumber })
                      && (Int(part) ?? 256) <= 255
              }) else {
            return "「\(text)」不是有效的 IPv4 地址"
        }
        if parts[0] == "127" {
            return "地址不能属于 127.0.0.0/8"
        }
        if text == Self.tunnelAddress {
            return "地址不能是虚拟接口自身的地址（\(Self.tunnelAddress)）"
        }
        if addresses.contains(text) {
            return "这个地址已在列表里"
        }
        return nil
    }
}
