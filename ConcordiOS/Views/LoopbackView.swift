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
// (OverrideStore specs, kind .stringList), so it lands in the
// config.apply tun overlay and takes effect at the next VPN
// start, like other tun overrides. The list starts empty;
// deleting all addresses removes the key.
//
// Editing: tap a row (or its … menu) to edit the address in a
// sheet; delete by swiping, by the Edit button's delete circles,
// or from the row's … menu (with a confirm). The list may become
// empty — an empty list simply removes the key.

struct LoopbackView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var overrideStore = OverrideStore.shared
    @State private var editingAddress: String?
    @State private var editText = ""
    @State private var showEditSheet = false
    @State private var showDeleteConfirm: String?
    @State private var applyMessage: String?

    /// The tunnel interface's own address (PacketTunnelProvider):
    /// a loopback address may never be this.
    private static let tunnelAddress = "198.18.0.1"

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
                    editingAddress = nil
                    editText = ""
                    showEditSheet = true
                } label: {
                    Text("添加地址…")
                        .foregroundStyle(ConcordTheme.accent)
                }
                if addresses.isEmpty {
                    Text("未配置回流地址")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(addresses, id: \.self) { address in
                    HStack {
                        Button {
                            editingAddress = address
                            editText = address
                            showEditSheet = true
                        } label: {
                            Text(address)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button("编辑") {
                                editingAddress = address
                                editText = address
                                showEditSheet = true
                            }
                            Button("删除", role: .destructive) {
                                showDeleteConfirm = address
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 13))
                }
                .onDelete { offsets in
                    var list = addresses
                    list.remove(atOffsets: offsets)
                    saveAddresses(list)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showEditSheet) {
            LoopbackEditSheet(
                title: editingAddress == nil ? "添加地址" : "编辑地址",
                text: $editText,
                existing: addresses,
                current: editingAddress,
                tunnelAddress: Self.tunnelAddress
            ) { value in
                if let editingAddress,
                   let index = addresses.firstIndex(of: editingAddress) {
                    var list = addresses
                    list[index] = value
                    saveAddresses(list)
                } else {
                    saveAddresses(addresses + [value])
                }
            }
        }
        .alert("删除这个地址？", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let address = showDeleteConfirm {
                    saveAddresses(addresses.filter { $0 != address })
                }
                showDeleteConfirm = nil
            }
            Button("取消", role: .cancel) {
                showDeleteConfirm = nil
            }
        }
    }

    /// Rejects invalid IPv4, 127.0.0.0/8, the tunnel's own address
    /// and duplicates, with a reason the edit sheet shows inline.
    /// `excluding` is the address currently being edited, so
    /// saving it unchanged is not flagged as a duplicate.
    static func validationError(for text: String, excluding: String?, existing: [String]) -> String? {
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
        if text == tunnelAddress {
            return "地址不能是虚拟接口自身的地址（\(tunnelAddress)）"
        }
        if text != excluding && existing.contains(text) {
            return "这个地址已在列表里"
        }
        return nil
    }
}

/// Add / edit sheet for one loopback address (same pattern as
/// UserAgentEditSheet): the reason for a rejected value is shown
/// inline in red and 保存 stays disabled until the value is valid.
private struct LoopbackEditSheet: View {
    let title: String
    @Binding var text: String
    let existing: [String]
    let current: String?
    let tunnelAddress: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var error: String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return LoopbackView.validationError(for: value, excluding: current, existing: existing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 10.7.0.1", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("输入一个 IPv4 地址，不能属于 127.0.0.0/8，也不能是虚拟接口自身的地址 \(tunnelAddress)。")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
        }
    }
}
