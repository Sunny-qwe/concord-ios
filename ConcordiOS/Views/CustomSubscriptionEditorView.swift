import SwiftUI

// MARK: - Custom subscription editor (FlClash: lib/views/profiles/custom/)
// Full editor for one custom subscription: groups (+ members),
// dialers, proxy/rule providers and rules. The subscription itself
// lives in CustomSubscriptionStore; providers here are references
// to existing providers by name (upstream custom/providers.dart),
// never created from scratch.

struct CustomSubscriptionEditorView: View {
    let subscriptionID: UUID

    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var store = CustomSubscriptionStore()
    @StateObject private var proxyStore = CustomProxyStore()
    @State private var draft: CustomSubscription?
    @State private var editingGroup: CustomGroup?
    @State private var editingDialer: CustomDialer?
    @State private var editingProxyProvider: CustomProvider?
    @State private var editingRule: CustomRule?
    @State private var showProxyProviderPicker = false
    @State private var showRuleProviderPicker = false
    /// Rule providers defined in the active profile's YAML, loaded
    /// once in .task — the existing providers a rule provider can
    /// reference (upstream: the core's provider list).
    @State private var ruleProviderCandidates: [CustomProvider] = []
    /// Node names read from the profile files, loaded once off the
    /// main thread (see the .task below).
    @State private var fileCandidates: [String] = []

    /// The subscription being edited. The store loads its file
    /// synchronously in init, so the real name is already there for
    /// the navigation title on the first frame — no .task round-trip
    /// that first shows the "自定义订阅" fallback and then flips.
    private var sub: CustomSubscription {
        draft ?? store.subscriptions.first(where: { $0.id == subscriptionID })
            ?? CustomSubscription(id: subscriptionID, name: "自定义订阅")
    }

    /// Names a group member can pick: custom nodes, other groups,
    /// providers and the built-in targets. The file scan (every
    /// profile YAML) lives in fileCandidates, loaded once off the
    /// main thread; only the cheap draft-dependent names are merged
    /// here, so opening a form sheet never re-scans the files.
    private var memberCandidates: [String] {
        var names = fileCandidates
        names.append(contentsOf: sub.groups.map { $0.name })
        names.append(contentsOf: sub.proxyProviders.map { $0.name })
        names.append(contentsOf: CustomGroup.reservedTargets)
        return Array(NSOrderedSet(array: names)) as? [String] ?? []
    }

    private var targetCandidates: [String] {
        memberCandidates + ["GLOBAL", "COMPATIBLE"]
    }

    /// Existing subscriptions usable as proxy providers (upstream:
    /// custom providers reference other profiles by name). Only URL
    /// subscriptions: a file profile has no URL to fetch from, and
    /// its file path is private to ProfileStore.
    private var proxyProviderCandidates: [CustomProvider] {
        let taken = Set(sub.proxyProviders.map { $0.name })
        return profileStore.profiles
            .filter { $0.kind == .url && !($0.urlString?.isEmpty ?? true) && !taken.contains($0.name) }
            .map { CustomProvider(name: $0.name, kind: "http", url: $0.urlString ?? "") }
    }

    var body: some View {
        List {
            Section {
                TextField("订阅名称", text: Binding(
                    get: { sub.name },
                    set: { var copy = sub; copy.name = $0; draft = copy }
                ))
            } header: {
                Text("自定义订阅")
            } footer: {
                Text("分组 / 提供方 / 规则保存在此自定义订阅中。")
                    .font(.footnote)
            }

            Section("代理组（\(sub.groups.count) 个）") {
                ForEach(sub.groups) { group in
                    Button { editingGroup = group } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.headline)
                                Text("\(group.type) · \(group.members.count) 成员\(group.useProviders.isEmpty ? "" : " · 用 \(group.useProviders.joined(separator: ", "))")")
                                    .font(.footnote)
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
                            Text(dialer.proxy).font(.headline)
                            Image(systemName: "arrow.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(dialer.dialer).font(.headline)
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
                                Text(provider.name).font(.headline)
                                Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                                    .font(.footnote)
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
                Button { showProxyProviderPicker = true } label: {
                    Label("添加代理提供方", systemImage: "plus")
                }
            }

            Section("规则提供方（\(sub.ruleProviders.count) 个）") {
                ForEach(sub.ruleProviders) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.headline)
                            Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .onDelete { offsets in
                    var copy = sub
                    copy.ruleProviders.remove(atOffsets: offsets)
                    draft = copy
                }
                Button { showRuleProviderPicker = true } label: {
                    Label("添加规则提供方", systemImage: "plus")
                }
            }

            Section("规则（\(sub.rules.count) 条）") {
                ForEach(sub.rules) { rule in
                    Button { editingRule = rule } label: {
                        HStack {
                            Text(rule.text)
                                .font(.system(.caption, design: .monospaced))
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
        .font(.footnote.weight(.semibold))
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
            if let yaml = profileStore.activeProfileYAML() {
                ruleProviderCandidates = ruleProvidersInYAML(yaml)
            }
            // The profile-file scan used to run inside
            // memberCandidates on every body evaluation, stalling
            // the first frame, and inside each form sheet's
            // presentation. Snapshot the inputs on the main actor,
            // scan off-thread, and write the result back to state:
            // the title and the page render first, the candidate
            // lists fill in (live, even if a sheet is already open).
            let profiles = profileStore.profiles
            let customNames = proxyStore.proxies.map { $0.name }
            let storeRef = profileStore
            let names = await Task.detached(priority: .userInitiated) {
                var names = customNames
                names.append(contentsOf: profiles.flatMap { storeRef.localNodeNames(for: $0) })
                return names
            }.value
            fileCandidates = names
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
            CustomProviderOptionsView(provider: provider) { saved in
                var copy = sub
                if let index = copy.proxyProviders.firstIndex(where: { $0.id == saved.id }) {
                    copy.proxyProviders[index] = saved
                } else {
                    copy.proxyProviders.append(saved)
                }
                draft = copy
            }
        }
        .sheet(isPresented: $showProxyProviderPicker) {
            CustomProviderPickerView(
                title: "添加代理提供方",
                candidates: proxyProviderCandidates,
                emptyTip: "没有可引用的订阅：先在订阅页导入一个带链接的订阅。"
            ) { picked in
                var copy = sub
                copy.proxyProviders.append(picked)
                draft = copy
            }
        }
        .sheet(isPresented: $showRuleProviderPicker) {
            CustomProviderPickerView(
                title: "添加规则提供方",
                candidates: ruleProviderCandidates.filter { candidate in
                    !sub.ruleProviders.contains(where: { $0.name == candidate.name })
                },
                emptyTip: "当前配置里没有规则提供方。"
            ) { picked in
                var copy = sub
                copy.ruleProviders.append(picked)
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
            .font(.footnote.weight(.semibold))
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
            .font(.footnote.weight(.semibold))
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

// MARK: - Provider options + reference picker

/// Overrides for one referenced proxy provider (FlClash
/// custom/providers.dart: ProxyProviderOptions only — the name,
/// type and url/path come from the referenced provider and are not
/// edited here).
private struct CustomProviderOptionsView: View {
    @State private var provider: CustomProvider
    var onSave: (CustomProvider) -> Void
    @Environment(\.dismiss) private var dismiss

    init(provider: CustomProvider, onSave: @escaping (CustomProvider) -> Void) {
        _provider = State(initialValue: provider)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提供方") {
                    Text(provider.name)
                    Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .font(.footnote.weight(.semibold))
            .navigationTitle(provider.name)
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
                }
            }
        }
    }
}

/// Pick an existing provider to reference by name — FlClash
/// custom providers are references, never created from scratch.
private struct CustomProviderPickerView: View {
    let title: String
    let candidates: [CustomProvider]
    let emptyTip: String
    var onPick: (CustomProvider) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text(emptyTip)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { provider in
                        Button {
                            onPick(provider)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name).font(.headline)
                                Text("\(provider.kind) · \(provider.kind == "http" ? provider.url : provider.path)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// Rule providers defined in a profile YAML text, with their
/// definitions copied so a referenced provider still bakes a
/// complete entry. Only the top-level `rule-providers:` section is
/// read: `  Name:` entries with `    type:/url:/path:/interval:`
/// underneath; the section ends at the next top-level key.
private func ruleProvidersInYAML(_ yaml: String) -> [CustomProvider] {
    let lines = yaml.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0 == "rule-providers:" || $0.hasPrefix("rule-providers: ") }) else { return [] }
    var out: [CustomProvider] = []
    var current: CustomProvider?
    for line in lines[(start + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
        if line.hasPrefix("  "), !line.hasPrefix("   "), trimmed.hasSuffix(":") {
            if let provider = current { out.append(provider) }
            current = CustomProvider(name: yamlUnquote(String(trimmed.dropLast())))
        } else if var provider = current {
            if trimmed.hasPrefix("type:") {
                provider.kind = yamlUnquote(String(trimmed.dropFirst("type:".count)))
            } else if trimmed.hasPrefix("url:") {
                provider.url = yamlUnquote(String(trimmed.dropFirst("url:".count)))
            } else if trimmed.hasPrefix("path:") {
                provider.path = yamlUnquote(String(trimmed.dropFirst("path:".count)))
            } else if trimmed.hasPrefix("interval:") {
                provider.interval = Int(yamlUnquote(String(trimmed.dropFirst("interval:".count)))) ?? 0
            }
            current = provider
        }
    }
    if let provider = current { out.append(provider) }
    return out
}

private func yamlUnquote(_ value: String) -> String {
    let text = value.trimmingCharacters(in: .whitespaces)
    if text.count >= 2,
       (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
        return String(text.dropFirst().dropLast())
    }
    return text
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
            .font(.footnote.weight(.semibold))
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
