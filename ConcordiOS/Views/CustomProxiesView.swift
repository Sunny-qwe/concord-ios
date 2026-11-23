import SwiftUI

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
    @State private var editingRawIndex: Int?
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
                        editingRawIndex = index
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
                Task { await saveProxy(saved) }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingRawIndex != nil },
            set: { if !$0 { editingRawIndex = nil } }
        )) {
            if let index = editingRawIndex, store.rawProxies.indices.contains(index) {
                RawProxyEditView(definition: store.rawProxies[index]) { saved in
                    store.rawProxies[index] = saved
                    store.save()
                    Task { await bakeIntoProfile() }
                } onDelete: {
                    deleteRawProxies(at: IndexSet(integer: index))
                }
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
        editingRawIndex = nil
        Task { await bakeIntoProfile() }
    }

    private func saveProxy(_ proxy: CustomProxy) async {
        // Validate against the core before saving.
        do {
            let issues = try await profileStore.client.validateProxies(proxies: [proxyJSONValue(proxy)])
            if !issues.isEmpty {
                message = "节点校验未通过：\(issues[0].message)"
                return
            }
        } catch {
            message = "校验失败（核心未连接）：\(error.localizedDescription)"
            return
        }
        if let index = store.proxies.firstIndex(where: { $0.id == proxy.id }) {
            store.proxies[index] = proxy
        } else {
            store.proxies.append(proxy)
        }
        store.save()
        await bakeIntoProfile()
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

    /// The proxy as a JSON value, for validate.proxies.
    private func proxyJSONValue(_ proxy: CustomProxy) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(proxy.name), "type": .string(proxy.type),
            "server": .string(proxy.server), "port": .int(Int64(proxy.port)),
        ]
        if !proxy.password.isEmpty { dict["password"] = .string(proxy.password) }
        if !proxy.uuid.isEmpty { dict["uuid"] = .string(proxy.uuid) }
        if !proxy.cipher.isEmpty { dict["cipher"] = .string(proxy.cipher) }
        if proxy.tls { dict["tls"] = .bool(true) }
        if !proxy.sni.isEmpty { dict["servername"] = .string(proxy.sni) }
        if !proxy.network.isEmpty { dict["network"] = .string(proxy.network) }
        if proxy.udp { dict["udp"] = .bool(true) }
        return .object(dict)
    }
}

// MARK: - Proxy form

struct CustomProxyFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: CustomProxy
    let isNew: Bool
    let onSave: (CustomProxy) -> Void

    init(proxy: CustomProxy, isNew: Bool = false, onSave: @escaping (CustomProxy) -> Void) {
        _proxy = State(initialValue: proxy)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    if proxy.type == "vmess" || proxy.type == "vless" {
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
            .font(.footnote.weight(.semibold))
            .navigationTitle(proxy.id.isEmpty || isNew ? "添加代理" : "编辑代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(proxy)
                        dismiss()
                    }
                    .disabled(proxy.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.server.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.port <= 0)
                }
            }
        }
    }
}

// MARK: - Raw ("添加到本地") node editor

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
                    Button("取消") { dismiss() }
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
