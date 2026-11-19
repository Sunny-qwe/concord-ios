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

    var body: some View {
        List {
            Section {
                Text("按需连接：打开后，iPhone 会在网络变化时自动按规则连接或断开 VPN。下面的 Wi-Fi 不自动连接（其它网络都会自动连接）。手动从仪表盘启动 VPN 不受这些规则限制。\n\n默认开启：启动 VPN 时会自动开启按需连接，断网或切换网络（Wi-Fi ↔ 蜂窝）后系统会自动重连，不用手动再开；不想自动重连时可以关掉下面的开关。")
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
                    Text(ssid)
                }
                .onDelete { offsets in
                    store.excludedSSIDs.remove(atOffsets: offsets)
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
        .navigationTitle("按需连接")
        .navigationBarTitleDisplayMode(.inline)
    }
}
