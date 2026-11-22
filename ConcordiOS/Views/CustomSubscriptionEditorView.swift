import SwiftUI
import UIKit

// MARK: - Custom subscription editor (FlClash: lib/views/profiles/custom/)
// Full editor for one custom subscription: groups (+ members),
// dialers, proxy/rule providers and rules, plus the per-profile
// scoped sections DNS / NTP / sniffer / TUN (v0.2.55, FlClash
// custom.dart _MoreSectionsView). The subscription itself
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
    @State private var editingRuleProvider: CustomProvider?
    @State private var editingRule: CustomRule?
    /// Overview / menu state (FlClash custom.dart:147-221): rename,
    /// delete and runtime-config preview from inside the editor.
    @Environment(\.dismiss) private var dismiss
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showPreview = false
    /// Rules multi-select batch delete (FlClash custom/rules.dart).
    @State private var ruleSelectionMode = false
    @State private var selectedRuleIDs: Set<String> = []
    @State private var showRulePresets = false
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

    /// Validation issues (FlClash customProfileIssuesProvider):
    /// counted per section and shown in the overview banner.
    private var validationIssues: [String] {
        var issues: [String] = []
        let groupNames = sub.groups.map { $0.name }
        if Set(groupNames).count != groupNames.count { issues.append("有重名的代理组") }
        for group in sub.groups {
            if group.members.isEmpty && group.useProviders.isEmpty {
                issues.append("分组「\(group.name)」没有成员也没有提供方")
            }
            for provider in group.useProviders where !sub.proxyProviders.contains(where: { $0.name == provider }) {
                issues.append("分组「\(group.name)」引用的提供方「\(provider)」不存在")
            }
        }
        let validTargets = Set(groupNames + CustomGroup.reservedTargets + ["GLOBAL", "COMPATIBLE"])
        for rule in sub.rules where !validTargets.contains(rule.target) {
            issues.append("规则「\(rule.text)」的目标「\(rule.target)」不是分组或内置策略")
        }
        for rule in sub.rules where rule.type == "RULE-SET" && !rule.content.isEmpty
            && !sub.ruleProviders.contains(where: { $0.name == rule.content }) {
            issues.append("规则集「\(rule.content)」没有对应的规则提供方")
        }
        for dialer in sub.dialers where dialer.proxy.isEmpty || dialer.dialer.isEmpty || dialer.proxy == dialer.dialer {
            issues.append("拨号器配置不完整或指向自己")
        }
        for provider in sub.proxyProviders where provider.kind == "http" && provider.url.isEmpty {
            issues.append("代理提供方「\(provider.name)」没有链接")
        }
        // Scoped sections (v0.2.55): the same per-field checks
        // the global pages run (DnsSettingsView listen / CIDR
        // validation, NtpSettingsView port / interval ranges,
        // NetworkSettingsView MTU range).
        if let dns = sub.dns {
            if let listen = dns.listen, !listen.isEmpty, !DnsSettingsView.isValidListenAddress(listen) {
                issues.append("DNS 监听地址格式不对，应为 IP 或 IP:端口")
            }
            if let range = dns.fakeIpRange, !range.isEmpty, !SettingsStore.isValidIPv4CIDR(range) {
                issues.append("DNS Fake-IP 段格式不对，应为 a.b.c.d/n")
            }
            if let range6 = dns.fakeIpRange6, !range6.isEmpty, !NetworkSettingsView.isValidCIDR(range6) {
                issues.append("DNS Fake-IP 段（IPv6）格式不对，应为 IPv6 地址/n")
            }
            if let ipcidr = dns.fallbackFilter?.ipcidr {
                for cidr in ipcidr where !NetworkSettingsView.isValidCIDR(cidr) {
                    issues.append("DNS 备用过滤里有一条 IP 段格式不对：\(cidr)")
                }
            }
        }
        if let ntp = sub.ntp {
            if let port = ntp.port, !(1...65535).contains(port) {
                issues.append("NTP 端口应在 1–65535 之间")
            }
            if let interval = ntp.interval, !(1...1440).contains(interval) {
                issues.append("NTP 同步间隔应在 1–1440 分钟之间")
            }
        }
        if let tun = sub.tun {
            if let mtu = tun.mtu, !(1280...65535).contains(mtu) {
                issues.append("TUN MTU 应在 1280–65535 之间")
            }
        }
        return issues
    }

    /// Which of the four scoped sections are set (overview row).
    private var moreSectionsSummary: String {
        var set: [String] = []
        if sub.dns != nil { set.append("DNS") }
        if sub.ntp != nil { set.append("NTP") }
        if sub.sniffer != nil { set.append("嗅探") }
        if sub.tun != nil { set.append("TUN") }
        return set.isEmpty ? "未设置" : set.joined(separator: "、") + " 已设置"
    }

    private var missingProviderCount: Int {
        sub.groups.flatMap { $0.useProviders }.filter { name in
            !sub.proxyProviders.contains(where: { $0.name == name })
        }.count
        + sub.rules.filter { rule in rule.type == "RULE-SET" && !rule.content.isEmpty
            && !sub.ruleProviders.contains(where: { $0.name == rule.content }) }.count
    }

    var body: some View {
        List {
            // Overview (FlClash custom.dart _Overview): issue banner
            // + per-section counts (validation = M13).
            Section("总览") {
                if !validationIssues.isEmpty {
                    Text("发现 \(validationIssues.count) 个问题：\n" + validationIssues.joined(separator: "\n"))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                overviewRow("代理组", count: sub.groups.count, issueCount: validationIssues.filter { $0.contains("分组") }.count)
                overviewRow("规则", count: sub.rules.count, issueCount: validationIssues.filter { $0.contains("规则") }.count)
                overviewRow("提供方", count: sub.proxyProviders.count + sub.ruleProviders.count, issueCount: missingProviderCount)
                HStack {
                    Text("拨号器").font(.headline)
                    Spacer()
                    Text("\(sub.dialers.count) 个")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("更多（DNS / NTP / 嗅探 / TUN）").font(.headline)
                    Spacer()
                    Text(moreSectionsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("下面四个区只对这个订阅生效：打开后只设置你想改的项，没设置的项用订阅自己的值；设置后会替换订阅自带的同名配置，关掉后恢复。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                    Button { editingRuleProvider = provider } label: {
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
                    copy.ruleProviders.remove(atOffsets: offsets)
                    draft = copy
                }
                Button { showRuleProviderPicker = true } label: {
                    Label("添加规则提供方", systemImage: "plus")
                }
            }

            Section("规则（\(sub.rules.count) 条）") {
                ForEach(sub.rules) { rule in
                    Button {
                        if ruleSelectionMode {
                            if selectedRuleIDs.contains(rule.id) { selectedRuleIDs.remove(rule.id) } else { selectedRuleIDs.insert(rule.id) }
                        } else {
                            editingRule = rule
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if ruleSelectionMode {
                                Image(systemName: selectedRuleIDs.contains(rule.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedRuleIDs.contains(rule.id) ? ConcordTheme.accent : .secondary)
                            }
                            Text(rule.text)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("复制一份") {
                            var copy = sub
                            var duplicated = rule
                            duplicated.id = UUID().uuidString
                            if let index = copy.rules.firstIndex(where: { $0.id == rule.id }) {
                                copy.rules.insert(duplicated, at: index + 1)
                            } else {
                                copy.rules.append(duplicated)
                            }
                            draft = copy
                        }
                        .tint(ConcordTheme.accent)
                    }
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
                Button { showRulePresets = true } label: {
                    Label("快捷操作", systemImage: "bolt.circle")
                }
                Button { ruleSelectionMode.toggle(); selectedRuleIDs.removeAll() } label: {
                    Label(ruleSelectionMode ? "完成选择" : "多选删除", systemImage: "checkmark.circle")
                }
                if ruleSelectionMode && !selectedRuleIDs.isEmpty {
                    Button(role: .destructive) {
                        var copy = sub
                        copy.rules.removeAll { selectedRuleIDs.contains($0.id) }
                        draft = copy
                        selectedRuleIDs.removeAll()
                        ruleSelectionMode = false
                    } label: {
                        Label("删除所选（\(selectedRuleIDs.count) 条）", systemImage: "trash")
                    }
                }
            }

            // MARK: - More sections (v0.2.55, FlClash custom.dart
            // _MoreSectionsView): per-profile DNS / NTP / sniffer /
            // TUN. Each area is off until its toggle is on; only
            // the keys the user sets are baked, replacing the
            // profile's own section of the same key (the original
            // is preserved in the baked block and restored when
            // the toggle goes off again).
            Section("DNS") {
                Toggle("为此订阅自定义 DNS", isOn: Binding(
                    get: { sub.dns != nil },
                    set: { on in
                        var copy = sub
                        copy.dns = on ? (copy.dns ?? CustomDnsSection()) : nil
                        draft = copy
                    }
                ))
                if sub.dns != nil {
                    Text("只设置你想改的项：没设置的项用订阅自己的值。设置后会替换订阅自带的 DNS。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sub.dns != nil {
                CustomDnsSectionFormView(section: Binding(
                    get: { sub.dns ?? CustomDnsSection() },
                    set: { value in
                        var copy = sub
                        copy.dns = value
                        draft = copy
                    }
                ))
            }
            Section("NTP") {
                Toggle("为此订阅自定义 NTP", isOn: Binding(
                    get: { sub.ntp != nil },
                    set: { on in
                        var copy = sub
                        copy.ntp = on ? (copy.ntp ?? CustomNtpSection()) : nil
                        draft = copy
                    }
                ))
                if sub.ntp != nil {
                    Text("只设置你想改的项：没设置的项用订阅自己的值。设置后会替换订阅自带的 NTP。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sub.ntp != nil {
                CustomNtpSectionFormView(section: Binding(
                    get: { sub.ntp ?? CustomNtpSection() },
                    set: { value in
                        var copy = sub
                        copy.ntp = value
                        draft = copy
                    }
                ))
            }
            Section("嗅探") {
                Toggle("为此订阅自定义嗅探", isOn: Binding(
                    get: { sub.sniffer != nil },
                    set: { on in
                        var copy = sub
                        copy.sniffer = on ? (copy.sniffer ?? CustomSnifferSection()) : nil
                        draft = copy
                    }
                ))
                if sub.sniffer != nil {
                    Text("只设置你想改的项：没设置的项用订阅自己的值。设置后会替换订阅自带的嗅探配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sub.sniffer != nil {
                CustomSnifferSectionFormView(section: Binding(
                    get: { sub.sniffer ?? CustomSnifferSection() },
                    set: { value in
                        var copy = sub
                        copy.sniffer = value
                        draft = copy
                    }
                ))
            }
            Section("TUN") {
                Toggle("为此订阅自定义 TUN", isOn: Binding(
                    get: { sub.tun != nil },
                    set: { on in
                        var copy = sub
                        copy.tun = on ? (copy.tun ?? CustomTunSection()) : nil
                        draft = copy
                    }
                ))
                if sub.tun != nil {
                    Text("只设置你想改的项：没设置的项用订阅自己的值。设置后会替换订阅自带的 TUN。iOS 上只有 MTU 和拥塞控制真正生效（下次启动 VPN 时应用），其余项只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sub.tun != nil {
                CustomTunSectionFormView(section: Binding(
                    get: { sub.tun ?? CustomTunSection() },
                    set: { value in
                        var copy = sub
                        copy.tun = value
                        draft = copy
                    }
                ))
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(sub.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = sub.name
                        showRenameAlert = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button { showPreview = true } label: {
                        Label("运行时配置", systemImage: "eye")
                    }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { saveDraft() }
            }
        }
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("订阅名称", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    var copy = sub
                    copy.name = name
                    draft = copy
                }
                showRenameAlert = false
            }
            Button("取消", role: .cancel) { showRenameAlert = false }
        }
        .alert("删除这个自定义订阅？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.delete(sub)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(sub.name)」里的分组、提供方和规则都会被删除。")
        }
        .sheet(isPresented: $showPreview) {
            CustomSubscriptionPreviewSheet(subscription: sub)
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
        .sheet(item: $editingRuleProvider) { provider in
            CustomProviderOptionsView(provider: provider) { saved in
                var copy = sub
                if let index = copy.ruleProviders.firstIndex(where: { $0.id == saved.id }) {
                    copy.ruleProviders[index] = saved
                } else {
                    copy.ruleProviders.append(saved)
                }
                draft = copy
            }
        }
        .sheet(isPresented: $showRulePresets) {
            RulePresetSheetView { preset in
                var copy = sub
                for raw in preset.rawRules {
                    guard let parsed = RuleFormDraft.parse(raw) else { continue }
                    let rule = CustomRule(type: parsed.type, content: parsed.content, target: parsed.target, noResolve: parsed.noResolve, src: parsed.src)
                    if !copy.rules.contains(where: { $0.text == rule.text }) {
                        copy.rules.append(rule)
                    }
                }
                draft = copy
            }
        }
        .sheet(item: $editingRule) { rule in
            CustomRuleFormView(rule: rule, targets: targetCandidates, ruleProviderNames: ruleProviderCandidates.map { $0.name }) { saved in
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

    private func overviewRow(_ title: String, count: Int, issueCount: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(count) 个")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if issueCount > 0 {
                Text("\(issueCount) 个问题")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveDraft() {
        guard let draft else { return }
        store.update(draft)
    }
}

// MARK: - Runtime-config preview (FlClash custom.dart:215-221)

/// The custom subscription baked into the active profile's YAML
/// (or a minimal template when there is no active profile),
/// read-only text with copy — the same preview surface as
/// ProfilePreviewView.
private struct CustomSubscriptionPreviewSheet: View {
    let subscription: CustomSubscription
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var bakedText: String {
        let base = profileStore.activeProfileYAML()
            ?? "mode: rule\nproxies: []\nproxy-groups: []\nproxy-providers: {}\nrule-providers: {}\nrules: []\n"
        return CustomSubscriptionStore.bake(subscription, into: base)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(bakedText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle("运行时配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = bakedText
                        copied = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
    /// Member search (FlClash custom/members.dart: search appears
    /// once the list reaches sheetSearchMinItemCount).
    @State private var memberSearch = ""

    private var visibleCandidates: [String] {
        guard !memberSearch.isEmpty else { return candidates }
        return candidates.filter { $0.localizedCaseInsensitiveContains(memberSearch) }
    }

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
                    // Group icon (FlClash custom/icon.dart
                    // IconPickerView): a URL, or a scored match from
                    // the user's imported icon pack for this name.
                    TextField("图标链接（可选）", text: $group.icon)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        if let iconURL = URL(string: group.icon), !group.icon.isEmpty {
                            AsyncImage(url: iconURL) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 28, height: 28)
                        }
                        Button("从图标源匹配") {
                            if let url = IconPackStore.shared.iconURL(for: group.name) {
                                group.icon = url.absoluteString
                            }
                        }
                        .disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || IconPackStore.shared.iconURL(for: group.name) == nil)
                        Spacer()
                        if !group.icon.isEmpty {
                            Button("清除") { group.icon = "" }
                        }
                    }
                    .font(.footnote)
                    Text("没有图标时用订阅图标 / 图标源 / 首字。图标源在「设置 → 图标源」导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    if candidates.count >= 10 {
                        TextField("搜索成员", text: $memberSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    ForEach(visibleCandidates, id: \.self) { name in
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
                    // Smart groups only (v0.2.60, upstream c4bc31d):
                    // per-site pick weights, `pattern:factor` pairs
                    // separated by `;` — a pattern is a regex when
                    // it compiles, a substring otherwise. Stored
                    // verbatim; the core skips invalid pairs.
                    if group.type == "smart" {
                        TextField("策略优先（policy-priority，如 hk:1.5; jp:0.5）", text: Binding(
                            get: { group.policyPriority ?? "" },
                            set: { group.policyPriority = $0.isEmpty ? nil : $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Text("按站点选节点时的加权偏好：系数越大，匹配的节点越优先。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                // Named-filter presets (FlClash members.dart:112-143):
                // tap to fill the group's filter / exclude-filter
                // from the global named-filter list.
                if !NamedFilterStore.shared.filters.isEmpty {
                    Section("过滤器预设") {
                        ForEach(NamedFilterStore.shared.filters) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.label).font(.headline)
                                    Text(preset.regex)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("用作 filter") { group.filter = preset.regex }
                                    .font(.footnote.weight(.semibold))
                                Button("用作排除") { group.excludeFilter = preset.regex }
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }
                // More group options (FlClash custom/groups.dart
                // _GroupOption): maxFailedTimes (default 5),
                // expectedStatus (default ''), emptyFallback
                // (default 'COMPATIBLE'), defaultSelected (selector
                // only), hashKey (load-balance, non-round-robin).
                Section("更多选项") {
                    HStack {
                        Text("最大失败次数")
                        Spacer()
                        TextField("默认 5", value: $group.maxFailedTimes, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    TextField("期望状态码（expected-status）", text: Binding(
                        get: { group.expectedStatus ?? "" },
                        set: { group.expectedStatus = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("空组回落（empty-fallback，默认 COMPATIBLE）", text: Binding(
                        get: { group.emptyFallback ?? "" },
                        set: { group.emptyFallback = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    if group.type == "select" {
                        TextField("默认选中节点（default-selected）", text: Binding(
                            get: { group.defaultSelected ?? "" },
                            set: { group.defaultSelected = $0.isEmpty ? nil : $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    if group.type == "load-balance" && group.strategy != "round-robin" {
                        Picker("哈希键（hash-key）", selection: Binding(
                            get: { group.hashKey ?? "" },
                            set: { group.hashKey = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("默认").tag("")
                            Text("按用户（in-user）").tag("in-user")
                        }
                    }
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
                // Health-check extras (FlClash custom/providers.dart
                // _ProviderOption: url / timeout / lazy /
                // expectedStatus) and proxy overrides (udp /
                // skip-cert-verify / ip-version / additional-prefix /
                // additional-suffix).
                Section("健康检查") {
                    TextField("测速地址", text: Binding(
                        get: { provider.healthCheckURL ?? "" },
                        set: { provider.healthCheckURL = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    HStack {
                        Text("超时（毫秒）")
                        Spacer()
                        TextField("默认", value: $provider.healthCheckTimeout, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Toggle("用时才测速（lazy）", isOn: Binding(
                        get: { provider.healthCheckLazy ?? false },
                        set: { provider.healthCheckLazy = $0 ? true : nil }
                    ))
                    TextField("期望状态码（expected-status）", text: Binding(
                        get: { provider.expectedStatus ?? "" },
                        set: { provider.expectedStatus = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Section("代理覆盖") {
                    Toggle("UDP", isOn: Binding(
                        get: { provider.udp ?? false },
                        set: { provider.udp = $0 ? true : nil }
                    ))
                    Toggle("跳过证书验证", isOn: Binding(
                        get: { provider.skipCertVerify ?? false },
                        set: { provider.skipCertVerify = $0 ? true : nil }
                    ))
                    Picker("IP 版本", selection: Binding(
                        get: { provider.ipVersion ?? "" },
                        set: { provider.ipVersion = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("跟随").tag("")
                        Text("双栈（dual）").tag("dual")
                        Text("IPv4").tag("ipv4")
                        Text("IPv6").tag("ipv6")
                    }
                    TextField("名称前缀（additional-prefix）", text: Binding(
                        get: { provider.additionalPrefix ?? "" },
                        set: { provider.additionalPrefix = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("名称后缀（additional-suffix）", text: Binding(
                        get: { provider.additionalSuffix ?? "" },
                        set: { provider.additionalSuffix = $0.isEmpty ? nil : $0 }
                    ))
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

// MARK: - Per-profile section forms (v0.2.55)
//
// Each form edits one scoped section through a Binding to the
// (non-optional) section struct; the parent creates the section
// on toggle-on and nils it on toggle-off. Every field is
// tri-state in effect: an empty text field / empty list / "未设置"
// choice stores nil, which bakes nothing for that key — only
// keys the user actually sets are baked (an explicit 关 bakes
// false, which is different from unset).

/// Tri-state toggle (unset / on / off) for an optional Bool —
/// the same segmented pattern as SnifferSettingsView's
/// per-protocol override-destination. "未设置" bakes nothing for
/// the key; an explicit 关 bakes false.
private struct OptionalBoolRow: View {
    let label: String
    var value: Binding<Bool?>

    var body: some View {
        Picker(label, selection: value) {
            Text("未设置").tag(nil as Bool?)
            Text("开").tag(true as Bool?)
            Text("关").tag(false as Bool?)
        }
        .pickerStyle(.segmented)
    }
}

/// Optional string picker: "未设置" plus the named options.
private struct OptionalStringPickerRow: View {
    let label: String
    var value: Binding<String?>
    var options: [(value: String, label: String)]

    var body: some View {
        Picker(label, selection: value) {
            Text("未设置").tag(nil as String?)
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].label).tag(options[index].value as String?)
            }
        }
    }
}

/// Number row for an optional Int: empty = unset (nil). Same
/// shape as the group form's interval / timeout rows.
private struct OptionalNumberRow: View {
    let label: String
    var value: Binding<Int?>
    var placeholder: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}

/// Optional text field: empty = unset (nil). Same pattern as
/// CustomProviderOptionsView's optional fields.
private struct OptionalTextRow: View {
    let placeholder: String
    var value: Binding<String?>
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        ))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
    }
}

/// Optional string list: empty = unset (nil).
private struct OptionalStringListRow: View {
    var value: Binding<[String]?>
    var placeholder: String

    var body: some View {
        StringListEditor(items: Binding(
            get: { value.wrappedValue ?? [] },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        ), placeholder: placeholder)
    }
}

/// Optional string map: empty = unset (nil).
private struct OptionalStringMapRow: View {
    var value: Binding<[String: String]?>
    var keyPlaceholder: String
    var valuePlaceholder: String

    var body: some View {
        KeyValueListEditor(items: Binding(
            get: { value.wrappedValue ?? [:] },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        ), keyPlaceholder: keyPlaceholder, valuePlaceholder: valuePlaceholder)
    }
}

/// Comma-separated number list (TUN UID / port lists): the field
/// shows the current values joined by ", "; editing parses the
/// text, keeps the valid integers and flags the rest. Bound to
/// an optional list through OptionalIntListRow (empty = nil).
private struct IntListEditor: View {
    @Binding var items: [Int]
    var placeholder: String
    @State private var text = ""
    @State private var invalidText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onAppear { text = items.map(String.init).joined(separator: ", ") }
                .onChange(of: text) { _, newValue in
                    let parts = newValue.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var valid: [Int] = []
                    var invalid: [String] = []
                    for part in parts {
                        if let number = Int(part) {
                            valid.append(number)
                        } else {
                            invalid.append(part)
                        }
                    }
                    items = valid
                    invalidText = invalid.isEmpty ? nil : "忽略了无效的数字：\(invalid.joined(separator: "、"))"
                }
            if let invalidText {
                Text(invalidText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Optional number list: empty = unset (nil).
private struct OptionalIntListRow: View {
    var value: Binding<[Int]?>
    var placeholder: String

    var body: some View {
        IntListEditor(items: Binding(
            get: { value.wrappedValue ?? [] },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        ), placeholder: placeholder)
    }
}

/// One sniffed protocol: ports list + override-destination
/// (跟随 / 覆盖开 / 覆盖关). Mirrors SnifferSettingsView's
/// SniffProtocolRow, bound to a CustomSnifferSection's protocol
/// config instead of the global store.
private struct CustomSniffProtocolRow: View {
    let title: String
    @Binding var config: SniffProtocolConfig
    @State private var newPort = ""
    @State private var portError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Text(config.ports.isEmpty ? "默认端口" : "\(config.ports.count) 个端口")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker("覆盖目标地址", selection: Binding(
                get: { config.overrideDest },
                set: { config.overrideDest = $0 }
            )) {
                Text("跟随").tag(nil as Bool?)
                Text("覆盖开").tag(true as Bool?)
                Text("覆盖关").tag(false as Bool?)
            }
            .pickerStyle(.segmented)
            ForEach(config.ports, id: \.self) { port in
                HStack {
                    Text(port)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        config.ports.removeAll { $0 == port }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("端口或范围，如 8080 或 8000-9000", text: $newPort)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") {
                    let value = newPort.trimmingCharacters(in: .whitespaces)
                    guard Self.isValidPortRange(value) else {
                        portError = "格式不对，应为端口号或起止范围，如 8080 或 8000-9000"
                        return
                    }
                    guard !config.ports.contains(value) else {
                        portError = "这个端口已存在"
                        return
                    }
                    portError = nil
                    config.ports.append(value)
                    newPort = ""
                }
                .disabled(newPort.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let portError {
                Text(portError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    static func isValidPortRange(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            guard let port = Int(part), (1...65535).contains(port) else { return false }
            return true
        }
    }
}

private struct CustomDnsSectionFormView: View {
    @Binding var section: CustomDnsSection

    /// Updates one field of the fallback filter, creating the
    /// filter on first set and dropping it again when it becomes
    /// entirely empty (so an untouched filter never persists).
    private func updateFallbackFilter(_ update: (inout CustomDnsFallbackFilter) -> Void) {
        var filter = section.fallbackFilter ?? CustomDnsFallbackFilter()
        update(&filter)
        let isEmpty = filter.geoip == nil && filter.geoipCode == nil
            && (filter.geosite ?? []).isEmpty && (filter.ipcidr ?? []).isEmpty
            && (filter.domain ?? []).isEmpty
        section.fallbackFilter = isEmpty ? nil : filter
    }

    var body: some View {
        Group {
            Section("DNS · 选项") {
                OptionalBoolRow(label: "启用 DNS", value: $section.enable)
                OptionalStringPickerRow(label: "增强模式", value: $section.enhancedMode, options: [
                    (value: "normal", label: "普通"),
                    (value: "fake-ip", label: "Fake-IP"),
                    (value: "redir-host", label: "redir-host"),
                ])
                OptionalTextRow(placeholder: "监听地址，如 127.0.0.1:1053（留空为默认）", value: $section.listen)
                OptionalNumberRow(label: "监听路由标记", value: $section.listenRoutingMark, placeholder: "默认 0")
                OptionalBoolRow(label: "使用 Hosts", value: $section.useHosts)
                OptionalBoolRow(label: "使用系统 Hosts", value: $section.useSystemHosts)
                OptionalBoolRow(label: "DNS 用 IPv6", value: $section.ipv6)
                OptionalNumberRow(label: "IPv6 超时（毫秒）", value: $section.ipv6Timeout, placeholder: "默认 100")
                OptionalBoolRow(label: "遵循规则", value: $section.respectRules)
                OptionalBoolRow(label: "优先 HTTP/3", value: $section.preferH3)
                OptionalStringPickerRow(label: "缓存算法", value: $section.cacheAlgorithm, options: [
                    (value: "lru", label: "LRU"),
                    (value: "arc", label: "ARC"),
                ])
                OptionalNumberRow(label: "缓存上限（条）", value: $section.cacheMaxSize, placeholder: "默认 4096")
            }
            Section("DNS · Fake-IP") {
                OptionalTextRow(placeholder: "Fake-IP 段，如 198.18.0.1/16", value: $section.fakeIpRange)
                OptionalTextRow(placeholder: "Fake-IP 段（IPv6），如 2001:db8::/32", value: $section.fakeIpRange6)
                OptionalStringPickerRow(label: "Fake-IP 过滤模式", value: $section.fakeIpFilterMode, options: [
                    (value: "blacklist", label: "黑名单"),
                    (value: "whitelist", label: "白名单"),
                    (value: "rule", label: "规则"),
                ])
                OptionalNumberRow(label: "Fake-IP TTL", value: $section.fakeIpTtl, placeholder: "默认 1")
                OptionalStringListRow(value: $section.fakeIpFilter, placeholder: "域名，如 example.com")
            }
            Section("DNS · 解析服务器") {
                OptionalStringListRow(value: $section.nameserver, placeholder: "解析服务器，如 https://dns.alidns.com/dns-query")
                OptionalStringListRow(value: $section.defaultNameserver, placeholder: "默认解析服务器 IP")
                OptionalStringMapRow(value: $section.nameserverPolicy, keyPlaceholder: "域名 / 规则集", valuePlaceholder: "服务器")
                OptionalStringListRow(value: $section.fallback, placeholder: "备用解析服务器")
                OptionalBoolRow(label: "备用懒查询", value: $section.fallbackLazyQuery)
                OptionalStringListRow(value: $section.proxyServerNameserver, placeholder: "代理节点解析服务器")
                OptionalStringMapRow(value: $section.proxyServerNameserverPolicy, keyPlaceholder: "域名 / 规则集", valuePlaceholder: "服务器")
                OptionalStringListRow(value: $section.directNameserver, placeholder: "直连解析服务器")
                OptionalBoolRow(label: "直连跟随解析策略", value: $section.directNameserverFollowPolicy)
            }
            Section("DNS · 备用过滤") {
                OptionalBoolRow(label: "GeoIP 过滤", value: Binding(
                    get: { section.fallbackFilter?.geoip },
                    set: { value in updateFallbackFilter { $0.geoip = value } }
                ))
                OptionalTextRow(placeholder: "GeoIP 国家码，如 CN", value: Binding(
                    get: { section.fallbackFilter?.geoipCode },
                    set: { value in updateFallbackFilter { $0.geoipCode = value } }
                ))
                Text("GeoSite、IP 段、域名留空时不写出；只填了其中几项也只写出那几项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                OptionalStringListRow(value: Binding(
                    get: { section.fallbackFilter?.geosite },
                    set: { value in updateFallbackFilter { $0.geosite = value } }
                ), placeholder: "GeoSite，如 gfw")
                OptionalStringListRow(value: Binding(
                    get: { section.fallbackFilter?.ipcidr },
                    set: { value in updateFallbackFilter { $0.ipcidr = value } }
                ), placeholder: "IP 段，如 1.2.3.0/24")
                OptionalStringListRow(value: Binding(
                    get: { section.fallbackFilter?.domain },
                    set: { value in updateFallbackFilter { $0.domain = value } }
                ), placeholder: "域名")
            }
        }
    }
}

private struct CustomNtpSectionFormView: View {
    @Binding var section: CustomNtpSection

    var body: some View {
        Group {
            Section("NTP") {
                OptionalBoolRow(label: "启用 NTP", value: $section.enable)
                OptionalTextRow(placeholder: "服务器，如 time.apple.com", value: $section.server, keyboard: .URL)
                OptionalNumberRow(label: "端口", value: $section.port, placeholder: "默认 123")
                OptionalNumberRow(label: "同步间隔（分钟）", value: $section.interval, placeholder: "默认 30")
                OptionalTextRow(placeholder: "拨号代理（节点名，留空为直连）", value: $section.dialerProxy)
                OptionalBoolRow(label: "写入系统时间", value: $section.writeToSystem)
                Text("iOS 不允许 App 修改系统时间：该开关会随配置传给核心，由核心决定是否执行，App 内无法验证它是否生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CustomSnifferSectionFormView: View {
    @Binding var section: CustomSnifferSection

    var body: some View {
        Group {
            Section("嗅探") {
                OptionalBoolRow(label: "启用嗅探", value: $section.enable)
                OptionalBoolRow(label: "覆盖目标地址", value: $section.overrideDestination)
                OptionalBoolRow(label: "强制 DNS 映射", value: $section.forceDnsMapping)
                Text("把嗅探到的域名映射回 Fake-IP。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                OptionalBoolRow(label: "解析纯 IP", value: $section.parsePureIp)
            }
            Section("强制嗅探域名") {
                OptionalStringListRow(value: $section.forceDomain, placeholder: "域名，如 example.com")
            }
            Section("跳过域名") {
                OptionalStringListRow(value: $section.skipDomain, placeholder: "域名，如 example.com")
            }
            Section("跳过源地址") {
                OptionalStringListRow(value: $section.skipSrcAddress, placeholder: "IP 或 CIDR，如 192.168.1.0/24")
            }
            Section("跳过目标地址") {
                OptionalStringListRow(value: $section.skipDstAddress, placeholder: "IP 或 CIDR，如 10.0.0.0/8")
            }
            Section("嗅探协议") {
                CustomSniffProtocolRow(title: "HTTP", config: $section.sniffHttp)
                CustomSniffProtocolRow(title: "TLS", config: $section.sniffTls)
                CustomSniffProtocolRow(title: "QUIC", config: $section.sniffQuic)
                Text("端口为空时按协议默认端口嗅探。覆盖目标地址选「跟随」时用上面总开关的值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CustomTunSectionFormView: View {
    @Binding var section: CustomTunSection

    var body: some View {
        Group {
            Section("TUN") {
                OptionalBoolRow(label: "启用 TUN", value: $section.enable)
                OptionalStringPickerRow(label: "协议栈", value: $section.stack, options: [
                    (value: "gvisor", label: "gVisor"),
                    (value: "system", label: "系统"),
                    (value: "lwip", label: "Lwip"),
                ])
                OptionalNumberRow(label: "MTU", value: $section.mtu, placeholder: "默认 9000")
                OptionalTextRow(placeholder: "拥塞控制算法，如 cubic、bbr", value: $section.congestionController)
                Text("iOS 上只有 MTU 和拥塞控制真正生效（下次启动 VPN 时应用）；下面的项只进核心的 TUN 设备创建路径，iOS 的包通道 TUN 从不走那条路，改了也不会生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                OptionalBoolRow(label: "严格路由", value: $section.strictRoute)
                OptionalStringListRow(value: $section.routeAddress, placeholder: "路由地址，如 10.0.0.0/8")
                OptionalStringListRow(value: $section.routeExcludeAddress, placeholder: "排除路由地址，如 192.168.0.0/16")
                OptionalStringListRow(value: $section.dnsHijack, placeholder: "DNS 劫持，如 any:53")
                OptionalNumberRow(label: "UDP 超时（秒）", value: $section.udpTimeout, placeholder: "默认 300")
                OptionalBoolRow(label: "禁用 ICMP 转发", value: $section.disableIcmpForwarding)
                OptionalBoolRow(label: "GSO", value: $section.gso)
                OptionalStringListRow(value: $section.includeInterface, placeholder: "包含网卡，如 en0")
                OptionalStringListRow(value: $section.excludeInterface, placeholder: "排除网卡，如 en0")
                OptionalIntListRow(value: $section.includeUid, placeholder: "包含 UID，逗号分隔")
                OptionalIntListRow(value: $section.excludeUid, placeholder: "排除 UID，逗号分隔")
                OptionalIntListRow(value: $section.excludeSrcPort, placeholder: "排除源端口，逗号分隔")
                OptionalIntListRow(value: $section.excludeDstPort, placeholder: "排除目标端口，逗号分隔")
                OptionalStringListRow(value: $section.loopbackAddress, placeholder: "回流地址")
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
    /// Rule-provider names for the RULE-SET picker (FlClash
    /// rules.dart:312 customProfileRuleProviderIsValidProvider).
    let ruleProviderNames: [String]
    var onSave: (CustomRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(rule: CustomRule, targets: [String], ruleProviderNames: [String] = [], onSave: @escaping (CustomRule) -> Void) {
        _rule = State(initialValue: rule)
        self.targets = targets
        self.ruleProviderNames = ruleProviderNames
        self.onSave = onSave
    }

    private var isRuleSetProviderInvalid: Bool {
        rule.type == "RULE-SET" && !ruleProviderNames.isEmpty && !ruleProviderNames.contains(rule.content)
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
                        if rule.type == "RULE-SET" && !ruleProviderNames.isEmpty {
                            Picker("规则集", selection: $rule.content) {
                                Text("选择规则集").tag("")
                                ForEach(ruleProviderNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        } else {
                            TextField(rule.type == "RULE-SET" ? "规则集名称" : "规则内容", text: $rule.content)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if isRuleSetProviderInvalid {
                            Text("规则集「\(rule.content)」不存在于当前配置的规则提供方里。")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
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
                    .disabled((rule.type != "MATCH" && rule.type != "FINAL" && rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isRuleSetProviderInvalid)
                }
            }
        }
    }
}
