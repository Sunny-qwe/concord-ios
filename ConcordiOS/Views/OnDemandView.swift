import SwiftUI

// MARK: - On-demand rules (FlClash: lib/views/config/on_demand.dart)
// FlClash's on-demand page is the list of SSIDs the VPN must NOT
// connect on. On iOS that is one NEOnDemandRuleDisconnect per SSID
// plus a trailing NEOnDemandRuleConnect; the rules are installed on
// the saved VPN manager by TunnelManager and evaluated by the
// system when the network changes. Every change saves immediately.

struct OnDemandView: View {
    @ObservedObject private var store = OnDemandStore.shared
    @State private var newSSID = ""
    @State private var ssidError: String?
    @State private var editingSSID: String?
    @State private var editingSSIDText = ""

    var body: some View {
        List {
            Section {
                Text("按需连接：打开后，iPhone 会在网络变化时自动按规则连接或断开 VPN。下面的 Wi-Fi 不自动连接（其它网络都会自动连接）。手动从仪表盘启动 VPN 不受这些规则限制。\n\n默认关闭：启动 VPN 时不会自动开启按需连接；打开下面的开关后，断网或切换网络（Wi-Fi ↔ 蜂窝）后系统会自动重连，不用手动再开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("按需连接") {
                Toggle("启用按需连接", isOn: $store.enabled)
            }
            Section("不自动连接的 Wi-Fi（SSID）") {
                if store.excludedSSIDs.isEmpty {
                    Text("还没有排除的 Wi-Fi：开启后所有网络都会自动连接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.excludedSSIDs, id: \.self) { ssid in
                    Button {
                        editingSSID = ssid
                        editingSSIDText = ssid
                    } label: {
                        HStack {
                            Text(ssid)
                                .foregroundStyle(Color(.label))
                            Spacer()
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.excludedSSIDs.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    store.excludedSSIDs.move(fromOffsets: from, toOffset: to)
                }
                HStack {
                    TextField("Wi-Fi 名称（SSID）", text: $newSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let value = newSSID.trimmingCharacters(in: .whitespaces)
                        guard !value.isEmpty else { return }
                        guard !store.excludedSSIDs.contains(value) else {
                            ssidError = "这个 SSID 已存在"
                            return
                        }
                        ssidError = nil
                        store.excludedSSIDs.append(value)
                        newSSID = ""
                    }
                    .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let ssidError {
                    Text(ssidError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("加入当前 Wi-Fi 后，下次连上它时 VPN 不会自动连接；正在运行的隧道不会因此断开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("重新应用按需规则") {
                    Task { await store.apply() }
                }
                if let message = store.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("按需连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .alert("编辑 SSID", isPresented: Binding(
            get: { editingSSID != nil },
            set: { if !$0 { editingSSID = nil } }
        )) {
            TextField("Wi-Fi 名称（SSID）", text: $editingSSIDText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                saveEditedSSID()
            }
            .disabled(!isEditedSSIDValid)
            Button("取消", role: .cancel) { editingSSID = nil }
        } message: {
            Text("点按列表里的 SSID 可以改名；拖动可以排序。空名字或已有的名字不能保存。")
        }
    }

    /// The edited name is valid when non-empty and not a duplicate
    /// of another SSID (FlClash on_demand.dart _handleAddOrUpdate).
    private var isEditedSSIDValid: Bool {
        guard let old = editingSSID else { return false }
        let value = editingSSIDText.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        return value == old || !store.excludedSSIDs.contains(value)
    }

    /// FlClash on_demand.dart _handleAddOrUpdate: rename in place,
    /// rejecting empty and duplicate names.
    private func saveEditedSSID() {
        guard let old = editingSSID else { return }
        let value = editingSSIDText.trimmingCharacters(in: .whitespaces)
        guard isEditedSSIDValid else { return }
        guard value != old else {
            editingSSID = nil
            return
        }
        if let index = store.excludedSSIDs.firstIndex(of: old) {
            store.excludedSSIDs[index] = value
        }
        editingSSID = nil
    }
}
