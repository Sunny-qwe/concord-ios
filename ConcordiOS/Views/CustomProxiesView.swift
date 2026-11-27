import SwiftUI

// MARK: - Shared form-sheet chrome + dirty-discard guard
//
// Upstream FlClash form sheets go through showFormSheet /
// showSnapSheet (plugins/prism_ui/lib/sheet.dart): detents
// [9/16, 0.9], tap-scrim dismiss, corner radius 38 (28pt here,
// the stats-sheet value at DashboardView.swift:540). Every form
// sheet in the Config/Settings area uses formSheetChrome().
// Upstream NestedFormSheet also intercepts dismiss and asks
// save-changes when the form is dirty. SwiftUI cannot intercept
// the swipe-down gesture itself, so while a form is dirty the
// swipe is blocked (interactiveDismissDisabled) and the Cancel
// button asks whether to discard — DiscardChangesGuard, applied
// to the form's root with the form's own isDirty flag.

/// Upstream form-sheet chrome: opens at the short detent, drags
/// to 90%, page background, 28pt corners (stats-sheet pattern).
extension View {
    func formSheetChrome() -> some View {
        presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }
}

/// Dirty-discard guard for edit-form sheets. `isDirty` is the
/// form's own flag; `showConfirm` drives the alert; `onDiscard`
/// dismisses the sheet. Cancel buttons call
/// `if isDirty { showConfirm = true } else { dismiss() }`.
struct DiscardChangesGuard: ViewModifier {
    var isDirty: Bool
    @Binding var showConfirm: Bool
    var onDiscard: () -> Void

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty)
            .alert("放弃未保存的修改？", isPresented: $showConfirm) {
                Button("放弃修改", role: .destructive, action: onDiscard)
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("已做的修改尚未保存。")
            }
    }
}

extension View {
    func discardChangesGuard(isDirty: Bool, showConfirm: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        modifier(DiscardChangesGuard(isDirty: isDirty, showConfirm: showConfirm, onDiscard: onDiscard))
    }
}

// MARK: - Custom proxies (FlClash: Tools -> 进阶配置 -> 代理)
// User-defined proxies, merged into the active profile's YAML
// under `proxies:` (see CustomProxyStore — the config.apply
// overlay cannot carry proxies, the profile owns them). Each
// proxy is validated against the core (validate.proxies) before
// it is saved. Subscription updates re-apply them (ProfileStore).

struct CustomProxiesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var store = CustomProxyStore()
    @StateObject private var customStore = CustomSubscriptionStore()
    @State private var editing: CustomProxy?
    @State private var editingRawItem: RawProxyEditItem?
    @State private var message: String?
    @State private var createdSubscriptionID: UUID?
    @State private var showCreatedEditor = false

    var body: some View {
        List {
            Section {
                Text("自定义节点会写进当前配置的 proxies: 段，之后可以在代理组里选用。订阅更新后会自动重新写回。保存前先用核心校验节点是否可用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    let created = customStore.create(name: "未命名自定义订阅")
                    createdSubscriptionID = created.id
                    showCreatedEditor = true
                } label: {
                    Label("完整自定义订阅编辑器（分组 / 拨号器 / 提供方 / 规则）", systemImage: "doc.badge.gearshape")
                        .font(.footnote)
                }
            }
            Section("自定义代理（\(store.proxies.count) 个）") {
                ForEach(store.proxies) { proxy in
                    Button {
                        editing = proxy
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proxy.name)
                                Text("\(proxy.type) · \(proxy.server):\(proxy.port)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.proxies.remove(atOffsets: offsets)
                    store.save()
                    Task { await bakeIntoProfile() }
                }
                Button {
                    editing = CustomProxy()
                } label: {
                    Label("添加代理", systemImage: "plus")
                }
            }
            // "添加到本地"的节点 (rawProxies): the full definition
            // as the core wrote it — ws-opts / grpc-opts /
            // reality-opts / flow / alpn included. They used to be
            // invisible here and undeletable anywhere; now they are
            // listed with edit + delete. Edit only touches
            // name / server / port (the form cannot express the
            // rest, so the remaining keys are kept verbatim).
            Section("本地添加的节点（\(store.rawProxies.count) 个）") {
                if store.rawProxies.isEmpty {
                    Text("还没有通过「添加到本地」加入的节点。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.rawProxies.enumerated()), id: \.offset) { index, definition in
                    Button {
                        editingRawItem = RawProxyEditItem(index: index)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(definition.objectValue?["name"]?.stringValue ?? "—")
                                Text("\(definition.objectValue?["type"]?.stringValue ?? "—") · \(definition.objectValue?["server"]?.stringValue ?? "—"):\(rawPortText(definition))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    deleteRawProxies(at: offsets)
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
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("代理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { proxy in
            CustomProxyFormView(proxy: proxy, isNew: !store.proxies.contains(where: { $0.id == proxy.id })) { saved in
                // The form only dismisses when this returns true:
                // a failed core validation keeps the sheet open so
                // the user can fix the node instead of re-typing
                // it (v0.2.151 B2 — pasted PEM blocks are long).
                await saveProxy(saved)
            }
            .formSheetChrome()
        }
        // Raw ("添加到本地") edit: ours-only, stays a sheet, but
        // single-item (the old Bool + index + if-let could show a
        // stale/blank form for a deleted row).
        .sheet(item: $editingRawItem) { item in
            if store.rawProxies.indices.contains(item.index) {
                RawProxyEditView(definition: store.rawProxies[item.index]) { saved in
                    store.rawProxies[item.index] = saved
                    store.save()
                    Task { await bakeIntoProfile() }
                } onDelete: {
                    deleteRawProxies(at: IndexSet(integer: item.index))
                }
                .formSheetChrome()
            }
        }
        .navigationDestination(isPresented: $showCreatedEditor) {
            if let createdSubscriptionID {
                CustomSubscriptionEditorView(subscriptionID: createdSubscriptionID).concordNavBarBackground()
            }
        }
    }

    private func rawPortText(_ definition: JSONValue) -> String {
        guard let port = definition.objectValue?["port"] else { return "—" }
        if case .int(let value) = port { return String(value) }
        if case .double(let value) = port { return String(Int(value)) }
        return "—"
    }

    /// Deletes raw ("添加到本地") nodes for real: removed from
    /// the store, persisted, and re-baked out of the profile.
    private func deleteRawProxies(at offsets: IndexSet) {
        store.rawProxies.remove(atOffsets: offsets)
        store.save()
        editingRawItem = nil
        Task { await bakeIntoProfile() }
    }

    /// Validates against the core, then saves + re-bakes. Returns
    /// nil on success, or the failure message: the form stays
    /// open and shows it so the user can fix the node.
    private func saveProxy(_ proxy: CustomProxy) async -> String? {
        // Validate against the core before saving.
        do {
            let issues = try await profileStore.client.validateProxies(proxies: [proxyJSONValue(proxy)])
            if !issues.isEmpty {
                message = "节点校验未通过：\(issues[0].message)"
                return message
            }
        } catch {
            message = "校验失败（核心未连接）：\(error.localizedDescription)"
            return message
        }
        if let index = store.proxies.firstIndex(where: { $0.id == proxy.id }) {
            store.proxies[index] = proxy
        } else {
            store.proxies.append(proxy)
        }
        store.save()
        await bakeIntoProfile()
        return nil
    }

    /// Write the current custom proxies into the active profile's
    /// YAML and re-apply live when the tunnel runs.
    private func bakeIntoProfile() async {
        guard var text = profileStore.activeProfileYAML() else {
            message = "没有可写入的当前配置（先导入一个订阅）"
            return
        }
        text = CustomProxyStore.bakeCurrent(into: text)
        message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message = (message ?? "") + " " + live
        }
    }

    /// The proxy as a JSON value, for validate.proxies. Per-type
    /// keys only: an unknown key reaches the core parser as a
    /// note, so a leaked `uuid` / `tls` / `sni` on an openvpn
    /// node would muddy its validation.
    private func proxyJSONValue(_ proxy: CustomProxy) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(proxy.name), "type": .string(proxy.type),
            "server": .string(proxy.server), "port": .int(Int64(proxy.port)),
        ]
        switch proxy.type {
        case "openvpn":
            if proxy.ovpnProto.lowercased() == "tcp" { dict["proto"] = .string("tcp") }
            if !proxy.ovpnCa.isEmpty { dict["ca"] = .string(proxy.ovpnCa) }
            if !proxy.ovpnCert.isEmpty { dict["cert"] = .string(proxy.ovpnCert) }
            if !proxy.ovpnKey.isEmpty { dict["key"] = .string(proxy.ovpnKey) }
            if !proxy.ovpnTlsAuth.isEmpty { dict["tls-auth"] = .string(proxy.ovpnTlsAuth) }
            if !proxy.ovpnTlsCrypt.isEmpty { dict["tls-crypt"] = .string(proxy.ovpnTlsCrypt) }
            if !proxy.ovpnTlsCryptV2.isEmpty { dict["tls-crypt-v2"] = .string(proxy.ovpnTlsCryptV2) }
            if proxy.ovpnKeyDirection == "0" || proxy.ovpnKeyDirection == "1" {
                dict["key-direction"] = .string(proxy.ovpnKeyDirection)
            }
            if !proxy.ovpnUsername.isEmpty { dict["username"] = .string(proxy.ovpnUsername) }
            if !proxy.password.isEmpty { dict["password"] = .string(proxy.password) }
            if !proxy.cipher.isEmpty { dict["cipher"] = .string(proxy.cipher) }
            let dataCiphers = CustomProxy.splitList(proxy.ovpnDataCiphers)
            if !dataCiphers.isEmpty { dict["data-ciphers"] = .array(dataCiphers.map(JSONValue.string)) }
            if !proxy.ovpnDataCiphersFallback.isEmpty { dict["data-ciphers-fallback"] = .string(proxy.ovpnDataCiphersFallback) }
            if !proxy.ovpnAuth.isEmpty { dict["auth"] = .string(proxy.ovpnAuth) }
            if proxy.ovpnCompLzo { dict["comp-lzo"] = .string("yes") }
            if proxy.ovpnPing > 0 { dict["ping"] = .int(Int64(proxy.ovpnPing)) }
            if proxy.ovpnPingRestart > 0 { dict["ping-restart"] = .int(Int64(proxy.ovpnPingRestart)) }
            if proxy.ovpnTranWindow > 0 { dict["tran-window"] = .int(Int64(proxy.ovpnTranWindow)) }
            if proxy.ovpnHandshakeTimeout > 0 { dict["handshake-timeout"] = .int(Int64(proxy.ovpnHandshakeTimeout)) }
            if proxy.ovpnMtu > 0 { dict["mtu"] = .int(Int64(proxy.ovpnMtu)) }
            if proxy.ovpnRemoteDnsResolve { dict["remote-dns-resolve"] = .bool(true) }
            let dns = CustomProxy.splitCommaList(proxy.ovpnDns)
            if !dns.isEmpty { dict["dns"] = .array(dns.map(JSONValue.string)) }
            dict["udp"] = .bool(true)
        default:
            if !proxy.password.isEmpty { dict["password"] = .string(proxy.password) }
            if !proxy.uuid.isEmpty { dict["uuid"] = .string(proxy.uuid) }
            if !proxy.cipher.isEmpty { dict["cipher"] = .string(proxy.cipher) }
            if proxy.tls { dict["tls"] = .bool(true) }
            if !proxy.sni.isEmpty { dict["servername"] = .string(proxy.sni) }
            if !proxy.network.isEmpty { dict["network"] = .string(proxy.network) }
            if proxy.udp { dict["udp"] = .bool(true) }
        }
        return .object(dict)
    }
}

// MARK: - Proxy form

struct CustomProxyFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: CustomProxy
    /// The proxy as opened (dirty = changed since open).
    private let original: CustomProxy
    @State private var showDiscardConfirm = false
    /// Last save failure, shown in the form (v0.2.151 B2: the
    /// sheet no longer dismisses on a failed validation).
    @State private var saveError: String?
    let isNew: Bool
    /// Validates + saves; nil = saved (dismiss), otherwise the
    /// failure message to show in the form (stay open).
    let onSave: (CustomProxy) async -> String?

    init(proxy: CustomProxy, isNew: Bool = false, onSave: @escaping (CustomProxy) async -> String?) {
        _proxy = State(initialValue: proxy)
        self.original = proxy
        self.isNew = isNew
        self.onSave = onSave
    }

    private var isDirty: Bool { proxy != original }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("基本") {
                    TextField("名称", text: $proxy.name)
                    Picker("类型", selection: $proxy.type) {
                        ForEach(CustomProxy.types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    TextField("服务器", text: $proxy.server)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", value: $proxy.port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section("认证") {
                    if proxy.type == "openvpn" {
                        TextField("用户名", text: $proxy.ovpnUsername)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("密码", text: $proxy.password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("证书认证和用户名认证二选一：填了证书 + 密钥就不用用户名；只用用户名也可以（密码可空）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if proxy.type == "vmess" || proxy.type == "vless" {
                        TextField("UUID", text: $proxy.uuid)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        TextField("密码", text: $proxy.password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    if proxy.type == "ss" || proxy.type == "vmess" {
                        TextField("加密方式，如 aes-128-gcm", text: $proxy.cipher)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                if proxy.type == "openvpn" {
                    Section("证书") {
                        Text("CA 证书（必填，PEM 文本）")
                        TextEditor(text: $proxy.ovpnCa)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("客户端证书（与密钥一起填才生效）")
                        TextEditor(text: $proxy.ovpnCert)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("客户端密钥")
                        TextEditor(text: $proxy.ovpnKey)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-auth（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsAuth)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-crypt（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsCrypt)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-crypt-v2（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsCryptV2)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Picker("密钥方向", selection: $proxy.ovpnKeyDirection) {
                            Text("不设置").tag("")
                            Text("0").tag("0")
                            Text("1").tag("1")
                        }
                        Text("tls-auth 和 tls-crypt 不能同时填；tls-crypt-v2 不能和前两者同时填。保存前会用核心校验，不合要求会报错。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("加密") {
                        Picker("协议", selection: $proxy.ovpnProto) {
                            Text("UDP").tag("udp")
                            Text("TCP").tag("tcp")
                        }
                        Picker("加密方式", selection: $proxy.cipher) {
                            Text("默认（AES-128-GCM）").tag("")
                            ForEach(CustomProxy.openvpnCiphers, id: \.self) { cipher in
                                Text(cipher).tag(cipher)
                            }
                        }
                        TextField("data-ciphers，多个用逗号隔开", text: $proxy.ovpnDataCiphers)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Picker("备用加密", selection: $proxy.ovpnDataCiphersFallback) {
                            Text("不设置").tag("")
                            ForEach(CustomProxy.openvpnCiphers, id: \.self) { cipher in
                                Text(cipher).tag(cipher)
                            }
                        }
                        Picker("认证摘要", selection: $proxy.ovpnAuth) {
                            Text("默认（SHA256）").tag("")
                            ForEach(CustomProxy.openvpnAuths, id: \.self) { auth in
                                Text(auth).tag(auth)
                            }
                        }
                        Toggle("comp-lzo", isOn: $proxy.ovpnCompLzo)
                    }
                    Section("高级") {
                        TextField("ping（秒，0 = 不设置）", value: $proxy.ovpnPing, format: .number)
                            .keyboardType(.numberPad)
                        TextField("ping-restart（秒，0 = 不设置）", value: $proxy.ovpnPingRestart, format: .number)
                            .keyboardType(.numberPad)
                        TextField("tran-window（秒，0 = 不设置）", value: $proxy.ovpnTranWindow, format: .number)
                            .keyboardType(.numberPad)
                        TextField("handshake-timeout（秒，0 = 不设置）", value: $proxy.ovpnHandshakeTimeout, format: .number)
                            .keyboardType(.numberPad)
                        TextField("MTU（0 = 默认）", value: $proxy.ovpnMtu, format: .number)
                            .keyboardType(.numberPad)
                        Toggle("remote-dns-resolve", isOn: $proxy.ovpnRemoteDnsResolve)
                        TextField("DNS，多个用逗号隔开", text: $proxy.ovpnDns)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                if proxy.type != "openvpn" {
                    Section("传输") {
                        if proxy.type == "vmess" || proxy.type == "vless" || proxy.type == "trojan" {
                            Toggle("TLS", isOn: $proxy.tls)
                            TextField("SNI / servername", text: $proxy.sni)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        if proxy.type == "vmess" || proxy.type == "vless" {
                            TextField("网络，如 ws / grpc", text: $proxy.network)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        Toggle("UDP", isOn: $proxy.udp)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle(proxy.id.isEmpty || isNew ? "添加代理" : "编辑代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if let error = await onSave(proxy) {
                                saveError = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(proxy.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.server.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.port <= 0)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }
}

// MARK: - Raw ("添加到本地") node editor

/// Single-item trigger for the raw-node edit sheet (the row index
/// as the item identity).
private struct RawProxyEditItem: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Edits one raw node definition losslessly for the fields the
/// form can express (name / server / port); every other key
/// (ws-opts, grpc-opts, reality-opts, flow, alpn, …) is kept
/// verbatim in the JSON object. The full definition is shown
/// below so the user can see what is preserved. Delete removes
/// the node from the store (and, via the caller's re-bake, from
/// the profile) for real.
struct RawProxyEditView: View {
    let definition: JSONValue
    var onSave: (JSONValue) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var server: String
    @State private var portText: String
    /// The values as opened (dirty = changed since open).
    private let originalName: String
    private let originalServer: String
    private let originalPortText: String
    @State private var showDiscardConfirm = false

    init(definition: JSONValue, onSave: @escaping (JSONValue) -> Void, onDelete: @escaping () -> Void) {
        self.definition = definition
        self.onSave = onSave
        self.onDelete = onDelete
        let object = definition.objectValue ?? [:]
        _name = State(initialValue: object["name"]?.stringValue ?? "")
        _server = State(initialValue: object["server"]?.stringValue ?? "")
        var port = ""
        if let value = object["port"], case .int(let number) = value {
            port = String(number)
        }
        _portText = State(initialValue: port)
        self.originalName = object["name"]?.stringValue ?? ""
        self.originalServer = object["server"]?.stringValue ?? ""
        self.originalPortText = port
    }

    private var isDirty: Bool {
        name != originalName || server != originalServer || portText != originalPortText
    }

    private var yamlText: String {
        YAMLValue.proxyItemLines(for: definition, indent: 2).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    TextField("名称", text: $name)
                    TextField("服务器", text: $server)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    Text("只能改这三项：其余参数（传输选项等）不在表单里，会按原样保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("完整定义（原样保留）") {
                    Text(yamlText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Button("删除此节点", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("编辑本地节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }

    private func save() {
        guard var dict = definition.objectValue else { return }
        dict["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
        if !trimmedServer.isEmpty { dict["server"] = .string(trimmedServer) }
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)), port > 0 {
            dict["port"] = .int(Int64(port))
        }
        onSave(.object(dict))
    }
}
