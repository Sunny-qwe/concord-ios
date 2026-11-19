import SwiftUI

// MARK: - Custom subscription editor (FlClash: lib/views/profiles/custom/)
// Full editor for one custom subscription: groups (+ members),
// dialers, proxy/rule providers and rules. The subscription itself
// lives in CustomSubscriptionStore; "应用到当前配置" bakes it into
// the ACTIVE profile's YAML through the existing profile apply
// path (ProfileStore.saveActiveProfileYAML + reapplyActive).

struct CustomSubscriptionListView: View {
    @StateObject private var store = CustomSubscriptionStore()
    @State private var editing: CustomSubscription?
    @State private var newName = ""
    @State private var showCreate = false

    var body: some View {
        List {
            Section {
                Text("自定义订阅是一套完整的分组 / 提供方 / 规则，可应用到当前配置上。节点本身仍在「代理」里编辑。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("自定义订阅（\(store.subscriptions.count) 个）") {
                ForEach(store.subscriptions) { sub in
                    NavigationLink {
                        CustomSubscriptionEditorView(subscriptionID: sub.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name).font(.system(size: 17, weight: .semibold))
                            Text("\(sub.groups.count) 分组 · \(sub.rules.count) 规则 · \(sub.proxyProviders.count + sub.ruleProviders.count) 提供方")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("重命名") { editing = sub; showCreate = true }
                            .tint(.blue)
                        Button("删除", role: .destructive) { store.delete(sub) }
                    }
                }
                Button {
                    newName = ""
                    editing = nil
                    showCreate = true
                } label: {
                    Label("新建自定义订阅", systemImage: "plus")
                }
            }
        }
        .navigationTitle("自定义订阅")
        .navigationBarTitleDisplayMode(.inline)
        .alert(editing == nil ? "新建自定义订阅" : "重命名", isPresented: $showCreate) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let existing = editing {
                    var copy = existing
                    copy.name = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.name : newName
                    store.update(copy)
                } else {
                    _ = store.create(name: newName)
                }
            }
        } message: {
            Text("名称只用来在列表里区分，应用到配置时用的是里面的分组和规则。")
        }
        .onChange(of: showCreate) { _, shown in
            if shown, let existing = editing { newName = existing.name }
        }
    }
}

struct CustomSubscriptionEditorView: View {
    let subscriptionID: UUID

    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var store = CustomSubscriptionStore()
    @StateObject private var proxyStore = CustomProxyStore()
    @State private var draft: CustomSubscription?
    @State private var editingGroup: CustomGroup?
    @State private var editingDialer: CustomDialer?
    @State private var editingProxyProvider: CustomProvider?
    @State private var editingRuleProvider: CustomProvider?
    @State private var editingRule: CustomRule?
    @State private var message: String?

    private var sub: CustomSubscription {
        draft ?? CustomSubscription(id: subscriptionID, name: "自定义订阅")
    }

    /// Names a group member can pick: custom nodes, other groups,
    /// providers and the built-in targets.
    private var memberCandidates: [String] {
        var names = proxyStore.proxies.map { $0.name }
        names.append(contentsOf: profileStore.profiles.flatMap { profileStore.localNodeNames(for: $0) })
        names.append(contentsOf: sub.groups.map { $0.name })
        names.append(contentsOf: sub.proxyProviders.map { $0.name })
        names.append(contentsOf: CustomGroup.reservedTargets)
        return Array(NSOrderedSet(array: names)) as? [String] ?? []
    }

    private var targetCandidates: [String] {
        memberCandidates + ["GLOBAL", "COMPATIBLE"]
    }

    var body: some View {
        List {
            Section {
                TextField("订阅名称", text: Binding(
                    get: { sub.name },
                    set: { var copy = sub; copy.name = $0; draft = copy }
                ))
                Button {
                    Task { await applyToActiveProfile() }
                } label: {
                    Label("应用到当前配置", systemImage: "checkmark.circle")
                }
                .disabled(profileStore.activeProfile == nil)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("自定义订阅")
            } footer: {
                Text("应用后，分组 / 提供方 / 规则会写进当前订阅的 YAML（带标记，可重复应用），拨号器会写到对应节点的 dialer-proxy 上；下次启动 VPN 或立即重应用后生效。")
            }

            Section("代理组（\(sub.groups.count) 个）") {
                ForEach(sub.groups) { group in
                    Button { editingGroup = group } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.system(size: 17, weight: .semibold))
                                Text("\(group.type) · \(group.members.count) 成员\(group.useProviders.isEmpty ? "" : " · 用 \(group.useProviders.joined(separator: ", "))")")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.groups.remove(atOffsets: offsets)
                    draft = copy
                }
                .onMove { from, to in
                    var copy = sub
                    copy.groups.move(fromOffsets: from, toOffset: to)
                    draft = copy
                }
                Button { editingGroup = CustomGroup() } label: {
                    Label("添加代理组", systemImage: "plus")
                }
            }

            Section("拨号器（\(sub.dialers.count) 个）") {
                ForEach(sub.dialers) { dialer in
                    Button { editingDialer = dialer } label: {
                        HStack {
                            Text(dialer.proxy).font(.system(size: 17, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(dialer.dialer).font(.system(size: 17, weight: .semibold))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.dialers.remove(atOffsets: offsets)
                    draft = copy
                }
                Button { editingDialer = CustomDialer() } label: {
                    Label("添加拨号器", systemImage: "plus")
                }
            }

            Section("代理提供方（\(sub.proxyProviders.count) 个）") {
                ForEach(sub.proxyProviders) { provider in
                    Button { editingProxyProvider = provider } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name).font(.system(size: 17, weight: .semibold))
                                Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.proxyProviders.remove(atOffsets: offsets)
                    draft = copy
                }
                Button { editingProxyProvider = CustomProvider() } label: {
                    Label("添加代理提供方", systemImage: "plus")
                }
            }

            Section("规则提供方（\(sub.ruleProviders.count) 个）") {
                ForEach(sub.ruleProviders) { provider in
                    Button { editingRuleProvider = provider } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name).font(.system(size: 17, weight: .semibold))
                                Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.ruleProviders.remove(atOffsets: offsets)
                    draft = copy
                }
                Button { editingRuleProvider = CustomProvider() } label: {
                    Label("添加规则提供方", systemImage: "plus")
                }
            }

            Section("规则（\(sub.rules.count) 条）") {
                ForEach(sub.rules) { rule in
                    Button { editingRule = rule } label: {
                        HStack {
                            Text(rule.text)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.rules.remove(atOffsets: offsets)
                    draft = copy
                }
                .onMove { from, to in
                    var copy = sub
                    copy.rules.move(fromOffsets: from, toOffset: to)
                    draft = copy
                }
                Button { editingRule = CustomRule() } label: {
                    Label("添加规则", systemImage: "plus")
                }
            }
        }
        .navigationTitle(sub.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { saveDraft() }
            }
        }
        .task {
            if draft == nil {
                draft = store.subscriptions.first(where: { $0.id == subscriptionID })
            }
        }
        .onDisappear {
            saveDraft()
        }
        .sheet(item: $editingGroup) { group in
            CustomGroupFormView(
                group: group,
                candidates: memberCandidates,
                providerNames: sub.proxyProviders.map { $0.name },
                isNew: !sub.groups.contains(where: { $0.id == group.id })
            ) { saved in
                var copy = sub
                if let index = copy.groups.firstIndex(where: { $0.id == saved.id }) {
                    copy.groups[index] = saved
                } else {
                    copy.groups.append(saved)
                }
                draft = copy
            }
        }
        .sheet(item: $editingDialer) { dialer in
            CustomDialerFormView(
                dialer: dialer,
                candidates: memberCandidates,
                isNew: !sub.dialers.contains(where: { $0.id == dialer.id })
            ) { saved in
                var copy = sub
                if let index = copy.dialers.firstIndex(where: { $0.id == saved.id }) {
                    copy.dialers[index] = saved
                } else {
                    copy.dialers.append(saved)
                }
                draft = copy
            }
        }
        .sheet(item: $editingProxyProvider) { provider in
            CustomProviderFormView(provider: provider, title: "代理提供方") { saved in
                var copy = sub
                if let index = copy.proxyProviders.firstIndex(where: { $0.id == saved.id }) {
                    copy.proxyProviders[index] = saved
                } else {
                    copy.proxyProviders.append(saved)
                }
                draft = copy
            }
        }
        .sheet(item: $editingRuleProvider) { provider in
            CustomProviderFormView(provider: provider, title: "规则提供方") { saved in
                var copy = sub
                if let index = copy.ruleProviders.firstIndex(where: { $0.id == saved.id }) {
                    copy.ruleProviders[index] = saved
                } else {
                    copy.ruleProviders.append(saved)
                }
                draft = copy
            }
        }
        .sheet(item: $editingRule) { rule in
            CustomRuleFormView(rule: rule, targets: targetCandidates) { saved in
                var copy = sub
                if let index = copy.rules.firstIndex(where: { $0.id == saved.id }) {
                    copy.rules[index] = saved
                } else {
                    copy.rules.append(saved)
                }
                draft = copy
            }
        }
    }

    private func saveDraft() {
        guard let draft else { return }
        store.update(draft)
    }

    private func applyToActiveProfile() async {
        saveDraft()
        guard var text = profileStore.activeProfileYAML() else {
            message = "没有可写入的当前配置（先导入一个订阅）"
            return
        }
        text = CustomSubscriptionStore.bake(sub, into: text)
        message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message = (message ?? "") + " " + live
        }
    }
}

// MARK: - Group form

private struct CustomGroupFormView: View {
    @State private var group: CustomGroup
    let candidates: [String]
    let providerNames: [String]
    let isNew: Bool
    var onSave: (CustomGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customMember = ""

    init(group: CustomGroup, candidates: [String], providerNames: [String], isNew: Bool, onSave: @escaping (CustomGroup) -> Void) {
        _group = State(initialValue: group)
        self.candidates = candidates
        self.providerNames = providerNames
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("分组名称", text: $group.name)
                    Picker("类型", selection: $group.type) {
                        ForEach(CustomGroup.types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    if group.type == "load-balance" {
                        Picker("负载均衡策略", selection: $group.strategy) {
                            Text("默认").tag("")
                            ForEach(CustomGroup.strategies, id: \.self) { strategy in
                                Text(strategy).tag(strategy)
                            }
                        }
                    }
                }
                Section("成员（\(group.members.count) 个）") {
                    ForEach(candidates, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { group.members.contains(name) },
                            set: { on in
                                if on {
                                    if !group.members.contains(name) { group.members.append(name) }
                                } else {
                                    group.members.removeAll { $0 == name }
                                }
                            }
                        ))
                    }
                    HStack {
                        TextField("手动输入成员名", text: $customMember)
                        Button("添加") {
                            let name = customMember.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, !group.members.contains(name) else { return }
                            group.members.append(name)
                            customMember = ""
                        }
                        .disabled(customMember.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !group.members.isEmpty {
                        Button("清空成员", role: .destructive) { group.members = [] }
                    }
                }
                Section("提供方") {
                    ForEach(providerNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { group.useProviders.contains(name) },
                            set: { on in
                                if on {
                                    if !group.useProviders.contains(name) { group.useProviders.append(name) }
                                } else {
                                    group.useProviders.removeAll { $0 == name }
                                }
                            }
                        ))
                    }
                    if providerNames.isEmpty {
                        Text("先在「代理提供方」里添加一个提供方，这里才能选用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("测速与选项") {
                    TextField("测速地址", text: $group.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("测速间隔（秒）")
                        Spacer()
                        TextField("300", value: Binding(
                            get: { group.interval == 0 ? nil : group.interval },
                            set: { group.interval = $0 ?? 0 }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                    HStack {
                        Text("超时（毫秒）")
                        Spacer()
                        TextField("5000", value: Binding(
                            get: { group.timeout == 0 ? nil : group.timeout },
                            set: { group.timeout = $0 ?? 0 }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                    HStack {
                        Text("容差（毫秒）")
                        Spacer()
                        TextField("0", value: Binding(
                            get: { group.tolerance == 0 ? nil : group.tolerance },
                            set: { group.tolerance = $0 ?? 0 }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                    Toggle("用时才测速（lazy）", isOn: $group.lazy)
                    Toggle("在列表中隐藏", isOn: $group.hidden)
                    Toggle("禁用 UDP", isOn: $group.disableUDP)
                    TextField("过滤表达式 filter", text: $group.filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("排除表达式 exclude-filter", text: $group.excludeFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(isNew ? "添加代理组" : "编辑代理组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(group)
                        dismiss()
                    }
                    .disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Dialer form

private struct CustomDialerFormView: View {
    @State private var dialer: CustomDialer
    let candidates: [String]
    let isNew: Bool
    var onSave: (CustomDialer) -> Void
    @Environment(\.dismiss) private var dismiss

    init(dialer: CustomDialer, candidates: [String], isNew: Bool, onSave: @escaping (CustomDialer) -> Void) {
        _dialer = State(initialValue: dialer)
        self.candidates = candidates
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("指定某个节点走另一个节点出站（dialer-proxy），例如让某个节点经前置代理连接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("拨号器") {
                    Picker("节点", selection: $dialer.proxy) {
                        Text("选择节点").tag("")
                        ForEach(candidates, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Picker("经由（拨号代理）", selection: $dialer.dialer) {
                        Text("选择节点").tag("")
                        ForEach(candidates, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加拨号器" : "编辑拨号器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(dialer)
                        dismiss()
                    }
                    .disabled(dialer.proxy.isEmpty || dialer.dialer.isEmpty || dialer.proxy == dialer.dialer)
                }
            }
        }
    }
}

// MARK: - Provider form

private struct CustomProviderFormView: View {
    @State private var provider: CustomProvider
    let title: String
    var onSave: (CustomProvider) -> Void
    @Environment(\.dismiss) private var dismiss

    init(provider: CustomProvider, title: String, onSave: @escaping (CustomProvider) -> Void) {
        _provider = State(initialValue: provider)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("提供方名称", text: $provider.name)
                    Picker("类型", selection: $provider.kind) {
                        ForEach(CustomProvider.kinds, id: \.self) { kind in
                            Text(kind == "http" ? "远程订阅（http）" : "本地文件（file）").tag(kind)
                        }
                    }
                    if provider.kind == "http" {
                        TextField("订阅地址", text: $provider.url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } else {
                        TextField("本地文件路径", text: $provider.path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section("选项") {
                    HStack {
                        Text("更新间隔（秒）")
                        Spacer()
                        TextField("0", value: Binding(
                            get: { provider.interval == 0 ? nil : provider.interval },
                            set: { provider.interval = $0 ?? 0 }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                    Toggle("健康检查", isOn: $provider.healthCheck)
                    TextField("过滤表达式 filter", text: $provider.filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("排除表达式 exclude-filter", text: $provider.excludeFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(provider)
                        dismiss()
                    }
                    .disabled(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Rule form

private struct CustomRuleFormView: View {
    @State private var rule: CustomRule
    let targets: [String]
    var onSave: (CustomRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(rule: CustomRule, targets: [String], onSave: @escaping (CustomRule) -> Void) {
        _rule = State(initialValue: rule)
        self.targets = targets
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    Picker("类型", selection: $rule.type) {
                        ForEach(CustomRule.types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    if rule.type != "MATCH" && rule.type != "FINAL" {
                        TextField(rule.type == "RULE-SET" ? "规则集名称" : "规则内容", text: $rule.content)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Picker("策略", selection: $rule.target) {
                        ForEach(targets, id: \.self) { target in
                            Text(target).tag(target)
                        }
                    }
                    if rule.type != "MATCH" && rule.type != "FINAL" {
                        Toggle("不解析域名（no-resolve）", isOn: $rule.noResolve)
                        Toggle("匹配源 IP（src）", isOn: $rule.src)
                    }
                }
                Section {
                    Text("预览：\(rule.text)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(rule)
                        dismiss()
                    }
                    .disabled(rule.type != "MATCH" && rule.type != "FINAL" && rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
