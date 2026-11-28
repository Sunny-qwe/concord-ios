import SwiftUI

// MARK: - On-demand rules (FlClash: lib/views/config/on_demand.dart)
// FlClash's on-demand page is the list of SSIDs with a per-SSID
// action: direct (直连 — the tunnel stays up and the core switches
// to direct mode on that Wi-Fi) or disconnect (不自动连接 — the
// system does not auto-connect the VPN on that Wi-Fi). An SSID not
// in the list is the default action: auto-connect like any other
// network. On iOS the disconnect action is one
// NEOnDemandRuleDisconnect per SSID plus a trailing
// NEOnDemandRuleConnect, installed by TunnelManager; the direct
// action is enforced by the extension's SsidDirectController, which
// reads the list from the App Group (ssid-direct.json) and switches
// the core's mode itself. Every change saves immediately.
//
// The fork shows the actions as swipe-left = direct / swipe-right =
// disconnect cards; the same three actions are offered here as
// native SwiftUI swipe actions (right swipe = direct, left swipe =
// disconnect / delete) plus the per-row menu — same defaults (a
// newly added SSID defaults to direct, renaming keeps the action).
//
// Reading the current Wi-Fi name needs the wifi-info entitlement
// plus location permission (fork: "根据系统要求，获取Wi-Fi名称需要
// 您授予位置权限"). The permission is requested only from this
// page's button, never automatically; a denial is shown honestly
// and the SSID is never guessed.
//
// v0.2.159: title 按需运行 (upstream onDemand, l10n_zh:2344);
// the list section is 排除 SSID (upstream excludeSsids). KEPT
// functional: the 启用按需运行 toggle (upstream has no toggle on
// this page, but it is the only switch for the NEOnDemandRule
// install), the 当前 Wi-Fi section (only way to request location
// permission / add the current SSID), the 直连覆盖生效中 banner
// (live status) and the 重新应用按需规则 button. The list keeps
// its List structure (swipe actions, reorder, multi-select
// delete); only fonts/nav-bar/wording change.

struct OnDemandView: View {
    @ObservedObject private var store = OnDemandStore.shared
    @ObservedObject private var ssidDirect = SsidDirectStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var newSSID = ""
    @State private var ssidError: String?
    @State private var editingSSID: String?
    @State private var editingSSIDText = ""

    var body: some View {
        List {
            Section {
                Text("按需运行：打开后，iPhone 会在网络变化时自动按规则连接或断开 VPN。列表里的 Wi-Fi 各有动作：直连的 Wi-Fi 上 VPN 保持连接、核心切换为直连模式；不自动连接的 Wi-Fi 上 VPN 不会自动连接；不在列表里的网络都会自动连接。手动从仪表盘启动 VPN 不受这些规则限制。\n\n默认关闭：启动 VPN 时不会自动开启按需连接；打开下面的开关后，断网或切换网络（Wi-Fi ↔ 蜂窝）后系统会自动重连，不用手动再开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if ssidDirect.overrideActive {
                Section {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("直连覆盖生效中")
                                .font(.subheadline)
                            Text(overrideDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let note = ssidDirect.mirrorNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("当前 Wi-Fi") {
                currentWiFiContent
            }
            Section("按需运行") {
                Toggle("启用按需运行", isOn: $store.enabled)
                    .toggleStyle(UpstreamToggleStyle())
            }
            Section("排除 SSID") {
                if store.excludedSSIDs.isEmpty {
                    Text("还没有加入的 Wi-Fi：开启后所有网络都会自动连接。点下面的输入框或上面的「当前 Wi-Fi」添加。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.excludedSSIDs, id: \.self) { ssid in
                    HStack {
                        Button {
                            editingSSID = ssid
                            editingSSIDText = ssid
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ssid)
                                    .font(.body)
                                    .foregroundStyle(Color(.label))
                                Text(store.isDirect(ssid: ssid) ? "直连" : "不自动连接")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button("直连") {
                                store.setAction(ssid: ssid, direct: true)
                            }
                            Button("不自动连接") {
                                store.setAction(ssid: ssid, direct: false)
                            }
                            Button("删除（恢复默认）", role: .destructive) {
                                store.removeSSID(ssid)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // FlClash on_demand.dart swipe cards: right
                    // swipe = direct, left swipe = disconnect /
                    // delete. The … menu stays for the same actions.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button("直连") {
                            store.setAction(ssid: ssid, direct: true)
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("不自动连接") {
                            store.setAction(ssid: ssid, direct: false)
                        }
                        .tint(.orange)
                        Button("删除", role: .destructive) {
                            store.removeSSID(ssid)
                        }
                    }
                }
                .onDelete { offsets in
                    // Collect first: removing one shifts the later indices.
                    let removed = offsets.map { store.excludedSSIDs[$0] }
                    for ssid in removed {
                        store.removeSSID(ssid)
                    }
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
                        guard store.addSSID(value) else {
                            ssidError = "这个 SSID 已存在"
                            return
                        }
                        ssidError = nil
                        newSSID = ""
                    }
                    .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let ssidError {
                    Text(ssidError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("新加入的 Wi-Fi 默认动作为直连；点按列表里的 SSID 可以改名，改名后动作不变；向右滑设为直连，向左滑设为不自动连接或删除（也可用每行右边的 … 菜单）。删除后恢复默认（自动连接）。直连的 Wi-Fi 上隧道保持运行、核心切换为直连；不自动连接的 Wi-Fi 只影响自动连接，正在运行的隧道不会因此断开。")
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
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.top, 40)
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: "按需运行")
        .concordNavBarBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .onAppear {
            Task { await ssidDirect.refreshAll() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await ssidDirect.refreshAll() }
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
            Text("点按列表里的 SSID 可以改名；拖动可以排序。空名字或已有的名字不能保存。改名后动作不变。")
        }
    }

    /// The override banner's detail line: which mode the core will
    /// restore on leaving, and the SSID when it is known. The SSID
    /// is shown only when actually read — never guessed.
    private var overrideDetail: String {
        let restore = ssidDirect.restoreMode.flatMap { OutboundMode(rawValue: $0)?.label } ?? "规则模式"
        if let ssid = ssidDirect.currentSSID {
            return "当前 Wi-Fi「\(ssid)」下核心已切换为直连模式；离开后恢复为\(restore)。"
        }
        return "核心已切换为直连模式；离开当前 Wi-Fi 后恢复为\(restore)。"
    }

    @ViewBuilder
    private var currentWiFiContent: some View {
        if ssidDirect.locationAuthorized {
            if let ssid = ssidDirect.currentSSID {
                HStack {
                    Text("当前 Wi-Fi：\(ssid)")
                    Spacer()
                    if store.excludedSSIDs.contains(ssid) {
                        Text(store.isDirect(ssid: ssid) ? "已加入（直连）" : "已加入（不自动连接）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("加入列表") {
                            _ = store.addSSID(ssid)
                        }
                    }
                }
                Text("加入后默认直连；可以在下面的列表里改动作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前未读取到 Wi-Fi 名称（可能未连接 Wi-Fi）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let reason = ssidDirect.ssidUnavailableReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if ssidDirect.permissionStatus == .denied || ssidDirect.permissionStatus == .restricted {
                Button("打开系统设置") {
                    ssidDirect.openSystemSettings()
                }
            } else {
                Button("允许读取 Wi-Fi 名称") {
                    ssidDirect.requestLocationPermission()
                }
            }
            Text("没有位置权限也可以手动在下面输入 SSID 加入列表；按需规则本身不需要位置权限。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
    /// rejecting empty and duplicate names; the action is kept.
    private func saveEditedSSID() {
        guard let old = editingSSID else { return }
        let value = editingSSIDText.trimmingCharacters(in: .whitespaces)
        guard isEditedSSIDValid else { return }
        guard value != old else {
            editingSSID = nil
            return
        }
        _ = store.renameSSID(from: old, to: value)
        editingSSID = nil
    }
}
