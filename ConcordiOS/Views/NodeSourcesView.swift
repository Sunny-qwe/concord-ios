import SwiftUI
import UIKit

// MARK: - Node sources (FlClash: lib/views/profiles/node_sources.dart)
//
// Upstream NodeSourcesView is an interactive node-source MANAGER for
// a custom profile, not a read-only list:
//  - two-level navigation: profile list → per-profile editor
//    (NodeSourcesView(profileId:));
//  - opening a non-custom profile asks for copy confirmation
//    (nodeSourcesCopyTip) then creates a custom profile from it;
//  - group picker: choose which groups the custom profile draws
//    from, with smart defaults (groups with `use:` / include-all,
//    else Selector / URLTest) and select-all/search;
//  - attach flows: batch subscription URLs with age key, existing
//    subscriptions picker, manual node create or pick existing,
//    clipboard share-link import;
//  - apply now: set current profile + applyProfile(force: true);
//  - attached-subscriptions list (tap → EditProfileView) and
//    manual-nodes list (tap → custom proxy editor, re-apply on
//    rename).
// The old read-only provenance list is kept as a section at the
// bottom of the root page (it works with the tunnel stopped, from
// the profile files themselves), under its own heading.

struct NodeSourcesView: View {
    /// The profile being edited, or nil for the root list.
    let profileId: UUID?
    /// The custom subscription being edited, or nil when editing a
    /// plain profile (a copy is created first).
    let customSubscriptionID: UUID?

    init(profileId: UUID? = nil, customSubscriptionID: UUID? = nil) {
        self.profileId = profileId
        self.customSubscriptionID = customSubscriptionID
    }

    var body: some View {
        if profileId == nil && customSubscriptionID == nil {
            NodeSourcesRootView()
        } else {
            NodeSourcesEditorView(profileId: profileId, customSubscriptionID: customSubscriptionID)
        }
    }
}

// MARK: - Root: profile list + provenance

private struct NodeSourcesRootView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customStore = CustomSubscriptionStore()
    @StateObject private var customProxyStore = CustomProxyStore()
    @State private var sections: [NodeSourceSection] = []
    @State private var createdSubscriptionID: UUID?
    @State private var showCreatedEditor = false

    var body: some View {
        List {
            Section("选择一个订阅，管理它的节点来源") {
                ForEach(profileStore.profiles) { profile in
                    NavigationLink {
                        NodeSourcesView(profileId: profile.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.headline)
                                Text(profile.kind == .url ? "远程订阅" : "本地文件")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                ForEach(customStore.subscriptions) { sub in
                    NavigationLink {
                        NodeSourcesView(customSubscriptionID: sub.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.name).font(.headline)
                                Text("自定义订阅 · \(sub.groups.count) 分组")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                Button {
                    let created = customStore.create(name: "未命名自定义订阅")
                    createdSubscriptionID = created.id
                    showCreatedEditor = true
                } label: {
                    Label("新建自定义订阅", systemImage: "plus")
                }
            }
            if sections.isEmpty {
                Section {
                    Text("暂无节点来源：先导入一个订阅，或在「代理」里添加自定义节点")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("节点来源（只读）")
                }
            }
            ForEach(sections) { section in
                Section("\(section.profileName) · \(section.kindLabel)（\(section.nodes.count) 个）") {
                    ForEach(section.nodes) { node in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).font(.footnote)
                                if !node.type.isEmpty || node.provider != nil {
                                    Text(nodeDetail(node))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("节点来源")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCreatedEditor) {
            if let createdSubscriptionID {
                CustomSubscriptionEditorView(subscriptionID: createdSubscriptionID).concordNavBarBackground()
            }
        }
        .task {
            let profiles = profileStore.profiles
            let customs = customProxyStore.proxies
            let raws = customProxyStore.rawProxies
            let storeRef = profileStore
            sections = await Task.detached(priority: .userInitiated) {
                NodeSourceSection.buildSections(profiles: profiles, customProxies: customs, rawProxies: raws, store: storeRef)
            }.value
        }
    }

    private func nodeDetail(_ node: NodeSourceSection.NodeEntry) -> String {
        var parts: [String] = []
        if !node.type.isEmpty { parts.append(node.type) }
        if let provider = node.provider, !provider.isEmpty {
            parts.append("提供方：\(provider)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Per-profile editor

private struct NodeSourcesEditorView: View {
    let profileId: UUID?
    let customSubscriptionID: UUID?

    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customStore = CustomSubscriptionStore()
    @StateObject private var customProxyStore = CustomProxyStore()
    @State private var localGroups: [ProfileStore.LocalProxyGroup] = []
    /// Groups the custom profile draws from (FlClash _selectedGroups
    /// with smart defaults: `use:` / include-all groups, else
    /// Selector / URLTest).
    @State private var selectedGroupNames: Set<String> = []
    @State private var groupSearch = ""
    @State private var showCopyConfirm = false
    @State private var showAddSubscription = false
    @State private var showExistingPicker = false
    @State private var editProfileID: UUID?
    @State private var applyMessage: String?
    @State private var isApplying = false
    @State private var clipboardMessage: String?
    @State private var editingCustomID: UUID?

    private var profile: Profile? {
        profileId.flatMap { id in profileStore.profiles.first(where: { $0.id == id }) }
    }

    /// The custom subscription under edit: the one opened directly,
    /// or the copy created from the profile (created on demand).
    private var customSub: CustomSubscription? {
        if let customSubscriptionID {
            return customStore.subscriptions.first(where: { $0.id == customSubscriptionID })
        }
        return nil
    }

    private var visibleGroups: [ProfileStore.LocalProxyGroup] {
        guard !groupSearch.isEmpty else { return localGroups }
        return localGroups.filter { $0.name.localizedCaseInsensitiveContains(groupSearch) }
    }

    private var attachedProfiles: [Profile] {
        guard let sub = customSub else { return [] }
        return profileStore.profiles.filter { profile in
            sub.proxyProviders.contains(where: { $0.name == profile.name })
        }
    }

    var body: some View {
        List {
            if let profile, customSub == nil {
                Section {
                    Text("「\(profile.name)」不是自定义订阅。复制一份成为自定义订阅后，才能在这里管理它的节点来源（分组选择、附加订阅、手动节点）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("复制为自定义订阅") { showCopyConfirm = true }
                }
            }
            if let sub = customSub {
                Section("分组（选择此自定义订阅从哪些分组取节点）") {
                    if localGroups.isEmpty {
                        Text("这个订阅里还没有分组。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("搜索分组", text: $groupSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Button(selectedGroupNames.count == localGroups.count ? "取消全选" : "全选") {
                                if selectedGroupNames.count == localGroups.count {
                                    selectedGroupNames.removeAll()
                                } else {
                                    selectedGroupNames = Set(localGroups.map { $0.name })
                                }
                            }
                            Spacer()
                            Text("已选 \(selectedGroupNames.count) / \(localGroups.count)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleGroups, id: \.name) { group in
                            Button {
                                if selectedGroupNames.contains(group.name) {
                                    selectedGroupNames.remove(group.name)
                                } else {
                                    selectedGroupNames.insert(group.name)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedGroupNames.contains(group.name) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedGroupNames.contains(group.name) ? ConcordTheme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name).font(.headline)
                                        Text("\(group.type) · \(group.nodeNames.count) 个节点")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Button("应用分组选择") { applyGroupSelection(to: sub) }
                            .disabled(selectedGroupNames.isEmpty)
                        Text("选中的分组会作为成员写进自定义订阅的同名分组；没选中的分组不取节点。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("附加订阅") {
                    ForEach(attachedProfiles) { attached in
                        Button { editProfileID = attached.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attached.name).font(.headline)
                                    Text(attached.kind == .url ? "远程订阅" : "本地文件")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showAddSubscription = true } label: {
                        Label("添加订阅（链接）", systemImage: "link")
                    }
                    Button { showExistingPicker = true } label: {
                        Label("附加已有订阅", systemImage: "list.bullet")
                    }
                }
                Section("手动节点") {
                    ForEach(customProxyStore.proxies) { node in
                        NavigationLink {
                            CustomProxiesView()
                        } label: {
                            HStack {
                                Text(node.name).font(.headline)
                                Spacer()
                                Text(node.type)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { Task { await importClipboardLinks(into: sub) } } label: {
                        Label("从剪贴板导入节点链接", systemImage: "doc.on.clipboard")
                    }
                    NavigationLink {
                        CustomProxiesView()
                    } label: {
                        Label("新建 / 管理手动节点", systemImage: "plus")
                    }
                    if let clipboardMessage {
                        Text(clipboardMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        Task { await applyNow(sub) }
                    } label: {
                        HStack {
                            if isApplying { ProgressView() }
                            Text("立即应用")
                        }
                    }
                    .disabled(isApplying)
                    if let applyMessage {
                        Text(applyMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("把这个自定义订阅烘焙进当前已激活的配置并重新应用（FlClash applyProfile(force: true)）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        CustomSubscriptionEditorView(subscriptionID: sub.id)
                    } label: {
                        Label("打开完整自定义订阅编辑器", systemImage: "doc.badge.gearshape")
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(profile?.name ?? customSub?.name ?? "节点来源")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGroups() }
        .alert("复制为自定义订阅？", isPresented: $showCopyConfirm) {
            Button("复制") { createCopy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会新建一个自定义订阅，复制当前订阅的分组和成员，原订阅不受影响。")
        }
        .sheet(isPresented: $showAddSubscription) {
            NodeSourcesAddSubscriptionSheet { url, label, ageKey in
                Task { await addSubscription(url: url, label: label, ageKey: ageKey) }
            }
        }
        .sheet(isPresented: $showExistingPicker) {
            NodeSourcesExistingPickerSheet(
                profiles: profileStore.profiles.filter { $0.id != profileId },
                alreadyAttached: Set(customSub?.proxyProviders.map { $0.name } ?? [])
            ) { picked in
                attachExisting(picked)
            }
        }
        .navigationDestination(item: $editProfileID) { id in
            if let attached = profileStore.profiles.first(where: { $0.id == id }) {
                EditProfileView(profile: attached)
            }
        }
        .navigationDestination(item: $editingCustomID) { id in
            NodeSourcesView(customSubscriptionID: id)
        }
    }

    private func loadGroups() async {
        guard let profile else {
            // Editing a custom subscription directly: groups come
            // from its own stored groups.
            if let sub = customSub {
                localGroups = sub.groups.map {
                    ProfileStore.LocalProxyGroup(name: $0.name, type: $0.type, nodeNames: $0.members, testURL: $0.url, filter: $0.filter, excludeFilter: $0.excludeFilter, useProviders: $0.useProviders)
                }
                if selectedGroupNames.isEmpty {
                    selectedGroupNames = Set(localGroups.map { $0.name })
                }
            }
            return
        }
        let storeRef = profileStore
        let groups = await Task.detached(priority: .userInitiated) {
            storeRef.localProxyGroups(for: profile)?.groups ?? []
        }.value
        localGroups = groups
        if selectedGroupNames.isEmpty {
            // Smart defaults (FlClash _selectedGroups): groups with
            // `use:` first, else Selector / URLTest / Smart (smart
            // picks like url-test, so it belongs in the same set).
            let withUse = groups.filter { !$0.useProviders.isEmpty }
            selectedGroupNames = Set(
                withUse.isEmpty
                    ? groups.filter { $0.type == "select" || $0.type == "url-test" || $0.type == "smart" }.map { $0.name }
                    : withUse.map { $0.name }
            )
        }
    }

    /// Create a custom subscription copying this profile's groups
    /// (FlClash nodeSourcesCopyTip → createProfile(source:)).
    private func createCopy() {
        guard let profile else { return }
        var sub = customStore.create(name: "\(profile.name)（自定义）")
        sub.groups = localGroups.map { group in
            CustomGroup(name: group.name, type: group.type, members: group.nodeNames,
                        useProviders: group.useProviders, url: group.testURL,
                        filter: group.filter, excludeFilter: group.excludeFilter)
        }
        customStore.update(sub)
        editingCustomID = sub.id
    }

    private func applyGroupSelection(to sub: CustomSubscription) {
        var copy = sub
        for group in localGroups where selectedGroupNames.contains(group.name) {
            if let index = copy.groups.firstIndex(where: { $0.name == group.name }) {
                copy.groups[index].members = group.nodeNames
                copy.groups[index].useProviders = group.useProviders
            } else {
                copy.groups.append(CustomGroup(name: group.name, type: group.type, members: group.nodeNames,
                                               useProviders: group.useProviders, url: group.testURL,
                                               filter: group.filter, excludeFilter: group.excludeFilter))
            }
        }
        copy.groups.removeAll { group in
            localGroups.contains(where: { $0.name == group.name })
                && !selectedGroupNames.contains(group.name)
        }
        customStore.update(copy)
        applyMessage = "已把 \(selectedGroupNames.count) 个分组的成员写进自定义订阅。"
    }

    private func addSubscription(url: String, label: String, ageKey: String?) async {
        guard var sub = customSub else { return }
        // addFromURL directly (not UnifiedImporter.importText, which
        // would also ACTIVATE the new profile — attaching must not
        // switch the user's current config).
        let beforeCount = profileStore.profiles.count
        await profileStore.addFromURL(name: label, urlString: url, ageSecretKey: ageKey)
        guard profileStore.profiles.count > beforeCount,
              profileStore.lastError == nil,
              let created = profileStore.profiles.last else {
            applyMessage = profileStore.lastError ?? "添加订阅失败"
            return
        }
        sub.proxyProviders.append(CustomProvider(name: created.name, kind: "http", url: url))
        customStore.update(sub)
        applyMessage = "已附加订阅「\(created.name)」"
    }

    private func attachExisting(_ picked: [Profile]) {
        guard var sub = customSub else { return }
        for profile in picked where !sub.proxyProviders.contains(where: { $0.name == profile.name }) {
            sub.proxyProviders.append(CustomProvider(name: profile.name, kind: "http", url: profile.urlString ?? ""))
        }
        customStore.update(sub)
        applyMessage = "已附加 \(picked.count) 个订阅"
    }

    private func importClipboardLinks(into sub: CustomSubscription) async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            clipboardMessage = "剪贴板里没有内容"
            return
        }
        let lines = UnifiedImporter.nonEmptyLines(text)
        var added: [String] = []
        var failed = 0
        for line in lines {
            switch NodeLinkParser.parse(line) {
            case .success(let node):
                if !customProxyStore.rawProxies.contains(where: { $0.objectValue?["name"]?.stringValue == node.name }) {
                    customProxyStore.rawProxies.append(node.jsonValue)
                    added.append(node.name)
                }
            case .failure:
                failed += 1
            }
        }
        customProxyStore.save()
        var copy = sub
        for index in copy.groups.indices where selectedGroupNames.contains(copy.groups[index].name) {
            for name in added where !copy.groups[index].members.contains(name) {
                copy.groups[index].members.append(name)
            }
        }
        customStore.update(copy)
        clipboardMessage = added.isEmpty
            ? "剪贴板里没有可导入的节点链接\(failed > 0 ? "（\(failed) 行解析失败）" : "")"
            : "已导入 \(added.count) 个节点\(failed > 0 ? "，\(failed) 行解析失败" : "")，并加入已选分组"
    }

    private func applyNow(_ sub: CustomSubscription) async {
        guard let active = profileStore.activeProfile,
              var text = profileStore.activeProfileYAML() else {
            applyMessage = "没有已激活的订阅：先导入并切换一个订阅。"
            return
        }
        isApplying = true
        defer { isApplying = false }
        // Validate the bake with the core BEFORE noteBaked +
        // saveActiveProfileYAML (ProfileStore.validateBakedSubscription):
        // a baked section the core rejects must never be saved into
        // the active profile. Refuse on issues, and also when the
        // validation itself fails — a gate that fails open would
        // silently save unvalidated content. The refusal surfaces
        // in applyMessage, the view's existing message line.
        do {
            let issues = try await profileStore.validateBakedSubscription(sub, for: active)
            if !issues.isEmpty {
                applyMessage = "校验未通过，未保存：" + issues.map { $0.message }.joined(separator: "；")
                return
            }
        } catch {
            applyMessage = "校验失败，未保存：\(error.localizedDescription)"
            return
        }
        CustomSubscriptionStore.noteBaked(subscriptionID: sub.id, into: active.id)
        text = CustomSubscriptionStore.bake(sub, into: text)
        var message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message += " " + live
        }
        applyMessage = message
    }
}

// MARK: - Add subscription sheet (FlClash showNamedUrlsForm, withAgeSecretKey)

private struct NodeSourcesAddSubscriptionSheet: View {
    var onAdd: (String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var label = ""
    @State private var ageKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅链接") {
                    TextField("https://…", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("名称（可选）", text: $label)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("age 私钥（可选）", text: $ageKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("age 加密的订阅填了私钥才能一次导入成功。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        let key = ageKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(url.trimmingCharacters(in: .whitespacesAndNewlines), label.trimmingCharacters(in: .whitespacesAndNewlines), key.isEmpty ? nil : key)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Existing subscriptions picker (FlClash _SourcePicker)

private struct NodeSourcesExistingPickerSheet: View {
    let profiles: [Profile]
    let alreadyAttached: Set<String>
    var onPick: ([Profile]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var search = ""

    private var visible: [Profile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty {
                    Text("没有可附加的订阅。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("搜索订阅", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button(selected.count == profiles.count ? "取消全选" : "全选") {
                            selected = selected.count == profiles.count ? [] : Set(profiles.map { $0.id })
                        }
                        Spacer()
                        Text("已选 \(selected.count) 个")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { profile in
                        Button {
                            if selected.contains(profile.id) { selected.remove(profile.id) } else { selected.insert(profile.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(profile.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(profile.id) ? ConcordTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(.headline)
                                    Text(alreadyAttached.contains(profile.name) ? "已附加" : (profile.kind == .url ? "远程订阅" : "本地文件"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("附加已有订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("附加") {
                        onPick(profiles.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - Read-only provenance (kept from the previous version)

struct NodeSourceSection: Identifiable {
    var id: UUID { profileID }
    let profileID: UUID
    let profileName: String
    let kindLabel: String
    var nodes: [NodeEntry]

    struct NodeEntry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        var type: String
        /// Proxy-provider the node came from, when it did not come
        /// from the profile's own `proxies:` section.
        var provider: String?

        init(name: String, type: String, provider: String? = nil) {
            self.name = name
            self.type = type
            self.provider = provider
        }
    }

    /// Local provenance only: every profile's own `proxies:` names
    /// plus the locally added custom nodes. Pure file work (no
    /// @Published state touched), so it runs in a detached task.
    static func buildSections(profiles: [Profile], customProxies: [CustomProxy], rawProxies: [JSONValue], store: ProfileStore) -> [NodeSourceSection] {
        var built: [NodeSourceSection] = profiles.map { profile in
            let nodes: [NodeEntry]
            if let parsed = store.localProxyGroups(for: profile) {
                nodes = parsed.nodes.map {
                    NodeEntry(name: $0.name, type: $0.type == "unknown" ? "" : $0.type, provider: $0.provider)
                }
            } else {
                nodes = store.localNodeNames(for: profile).map {
                    NodeEntry(name: $0, type: "")
                }
            }
            return NodeSourceSection(
                profileID: profile.id,
                profileName: profile.name,
                kindLabel: profile.kind.rawValue,
                nodes: nodes
            )
        }
        let customNames = customProxies.map { NodeEntry(name: $0.name, type: $0.type) }
            + rawProxies.compactMap { value -> NodeEntry? in
                guard let name = value.objectValue?["name"]?.stringValue else { return nil }
                return NodeEntry(name: name, type: value.objectValue?["type"]?.stringValue ?? "")
            }
        if !customNames.isEmpty {
            built.append(NodeSourceSection(
                profileID: UUID(),
                profileName: "自定义节点",
                kindLabel: "本地添加",
                nodes: customNames
            ))
        }
        return built.filter { !$0.nodes.isEmpty }
    }
}
