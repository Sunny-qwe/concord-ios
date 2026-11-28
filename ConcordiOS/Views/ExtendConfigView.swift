import SwiftUI

// MARK: - Extend config (FlClash: lib/views/profiles/extend/)
// Standard mode: the shared added rules (AddedRulesView — the
// extension merges them into config.apply's overlay) plus a match
// target baked as a final MATCH rule. Script mode: a JavaScript
// config transform, run against the config the core parsed and
// written back through the profile apply path (see
// ExtendConfigStore). "立即应用" re-applies the active profile
// live when the tunnel is running.

struct ExtendConfigView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var extendStore = ExtendConfigStore()
    @StateObject private var scriptStore = MitmScriptStore()
    @State private var draft: ExtendSettings?
    @State private var message: String?
    @State private var isApplying = false
    /// Per-profile rule editing (FlClash extend/standard.dart
    /// profileRulesProvider): structured form + presets.
    @State private var editingProfileRule: RuleFormDraft?
    @State private var showProfileRulePresets = false
    /// Unapplied-on-open (FlClash extend.dart _checkUnappliedOnOpen):
    /// the stored settings differ from what is actually baked into
    /// the active profile's YAML.
    @State private var unappliedOnOpen = false
    /// The library script picked for script mode (FlClash
    /// extend/script.dart picks from the stored script library;
    /// picking one selects it for script mode).
    @State private var selectedScriptID: String?

    /// The profile this page edits. nil = the active profile (the
    /// old call sites). Passed by the Profiles page's context menu
    /// so 扩展 can target a non-active profile.
    let targetProfile: Profile?

    init(profile: Profile? = nil) {
        self.targetProfile = profile
    }

    private var profile: Profile? { targetProfile ?? profileStore.activeProfile }

    /// True only when the target IS the active profile — the only
    /// case where 立即应用 can apply live.
    private var isTargetActive: Bool {
        guard let profile else { return false }
        return profile.id == profileStore.activeProfile?.id
    }

    private var settings: ExtendSettings {
        draft ?? (profile.map { extendStore.settings(for: $0.id) } ?? ExtendSettings())
    }

    /// FlClash extend.dart:96-116: 立即应用 only shows when the
    /// current inputs differ from the applied snapshot.
    private var hasUnappliedChanges: Bool {
        guard let profile, let draft else { return false }
        return draft != extendStore.settings(for: profile.id)
    }

    /// FlClash standard.dart: invalid when the target is neither a
    /// built-in, nor a group, nor a proxy of the profile. Gated on
    /// matchTargetsLoaded: before the off-thread scan lands, an
    /// empty candidate list must not flash the target red.
    private var isMatchTargetInvalid: Bool {
        let target = settings.matchTarget
        guard !target.isEmpty, matchTargetsLoaded else { return false }
        return !matchTargetCandidates.contains(target)
    }

    private func setDraft(_ mutate: (inout ExtendSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        draft = copy
    }

    var body: some View {
        List {
            Section("扩展模式") {
                ForEach(ExtendMode.allCases, id: \.self) { mode in
                    Button {
                        setDraft { $0.mode = mode }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.label).font(.footnote.weight(.semibold))
                                Text(mode.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.mode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if settings.mode == .standard {
                Section("标准模式") {
                    NavigationLink {
                        GlobalRulesToggleView().concordNavBarBackground()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全局规则开关").font(.footnote.weight(.semibold))
                                Text("逐条启用 / 停用全局附加规则")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    NavigationLink {
                        AddedRulesView().concordNavBarBackground()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("附加规则").font(.footnote.weight(.semibold))
                                Text("在当前配置的规则之前先生效，扩展合并进配置")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    Picker("匹配目标", selection: Binding(
                        get: { settings.matchTarget },
                        set: { newValue in setDraft { $0.matchTarget = newValue } }
                    )) {
                        Text("跟随配置").tag("")
                        ForEach(matchTargetCandidates, id: \.self) { target in
                            Text(target).tag(target)
                        }
                    }
                    .foregroundStyle(isMatchTargetInvalid ? .red : .primary)
                    if isMatchTargetInvalid {
                        Text("该匹配目标在当前配置里不存在（不是分组也不是节点），保存后会回落到配置自身的最后一条规则。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("匹配目标会作为最后一条 MATCH 规则写进当前配置；留空则跟随配置自身的最后一条规则。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Per-profile rules (FlClash extend/standard.dart
                // StandardContent): rules that belong to THIS profile
                // only — add/edit via RuleForm, presets, reorder.
                // They bake into this profile's `rules:` section,
                // ahead of the match target.
                Section("本订阅规则（\(settings.profileRules.count) 条）") {
                    ForEach(settings.profileRules, id: \.self) { rule in
                        Button { editingProfileRule = RuleFormDraft(from: rule) } label: {
                            Text(rule)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(2)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        setDraft { $0.profileRules.remove(atOffsets: offsets) }
                    }
                    .onMove { from, to in
                        setDraft { $0.profileRules.move(fromOffsets: from, toOffset: to) }
                    }
                    Button { editingProfileRule = RuleFormDraft() } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    Button { showProfileRulePresets = true } label: {
                        Label("快捷操作", systemImage: "bolt.circle")
                    }
                    Text("只对当前订阅生效，写进该订阅的规则末尾、匹配目标之前。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("脚本模式") {
                    // FlClash extend/script.dart: pick one script
                    // from the stored library. Picking one selects
                    // it for script mode (there is no separate
                    // enable switch or inline editor upstream);
                    // picking "不使用脚本库" clears the selection.
                    Picker("从脚本库选择", selection: $selectedScriptID) {
                        Text("不使用脚本库").tag(nil as String?)
                        ForEach(scriptStore.scripts) { script in
                            Text(script.label).tag(script.id as String?)
                        }
                        // A dangling id (library entry deleted):
                        // show it so the picker does not render
                        // blank; picking anything else replaces it.
                        if let selectedScriptID, scriptStore.scripts.first(where: { $0.id == selectedScriptID }) == nil {
                            Text("已删除的脚本").tag(selectedScriptID as String?)
                        }
                    }
                    .onChange(of: selectedScriptID) { _, id in
                        guard let id else {
                            // The user picked "不使用脚本库": clear.
                            setDraft { $0.scriptEnabled = false; $0.scriptText = ""; $0.scriptId = nil }
                            return
                        }
                        guard let script = scriptStore.scripts.first(where: { $0.id == id }),
                              let content = scriptStore.content(of: script) else {
                            // Dangling id (library entry deleted):
                            // leave the draft alone. Clearing here
                            // would wipe the stored script text —
                            // including a pasted custom script —
                            // on merely opening the page, and
                            // onDisappear would persist the wipe
                            // (upstream extend/script.dart:38 shows
                            // null for a missing id without
                            // clearing anything).
                            return
                        }
                        setDraft { $0.scriptEnabled = true; $0.scriptText = content; $0.scriptId = id }
                    }
                    NavigationLink {
                        ScriptsView().concordNavBarBackground()
                    } label: {
                        HStack {
                            Text("前往配置脚本")
                            Spacer()
                            Text("\(scriptStore.scripts.count) 个")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("脚本定义 function main(config)，返回改写后的配置对象。config 是核心解析后的当前配置。运行需要核心可达（启动 VPN，或示例模式）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if hasUnappliedChanges || unappliedOnOpen {
                Section {
                    Button {
                        Task { await applyNow() }
                    } label: {
                        HStack {
                            if isApplying { ProgressView() }
                            Text(settings.mode == .script ? "运行脚本并应用" : "立即应用")
                        }
                    }
                    .disabled(isApplying || profile == nil)
                    if let profile, !isTargetActive {
                        Text("正在编辑「\(profile.name)」的扩展配置；立即应用只对当前已激活的订阅生效，切换到该订阅后才能立即应用。设置已保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if profile == nil {
                        Text("没有已激活的订阅：先导入并切换一个订阅。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if unappliedOnOpen && !hasUnappliedChanges {
                        Text("打开时发现已保存的扩展设置还没有应用到当前配置（上次可能没点「立即应用」）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("应用后立即生效（VPN 运行时）或下次启动 VPN 时生效；标准模式的附加规则由扩展合并，不用改订阅文件。")
                        .font(.footnote)
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
        // v0.2.66: tab-bar clearance for pushed pages
        // v0.2.165 (D): the profile-rules list stays reorderable
        // without an EditButton (upstream lists reorder by drag):
        // editMode is always on, so the drag handles + delete
        // affordance on the profile-rules rows never need a toggle.
        .environment(\.editMode, .constant(.active))
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("扩展配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // v0.2.165 (D): upstream extend.dart:114-120 — the bar
            // shows a FilledButton "立即应用" only when there are
            // unapplied changes (or while applying). Same condition
            // as the in-body apply section below, same action.
            if hasUnappliedChanges || unappliedOnOpen || isApplying {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("立即应用") {
                        Task { await applyNow() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || profile == nil)
                }
            }
        }
        .sheet(item: $editingProfileRule) { editing in
            RuleFormSheet(draft: editing, ruleProviderNames: []) { saved in
                let text = saved.text
                guard AddedRulesStore.validationError(for: text) == nil else { return }
                setDraft { draft in
                    if let original = editing.originalText,
                       let index = draft.profileRules.firstIndex(of: original) {
                        draft.profileRules[index] = text
                    } else if !draft.profileRules.contains(text) {
                        draft.profileRules.append(text)
                    }
                }
            }
            .formSheetChrome()
        }
        .sheet(isPresented: $showProfileRulePresets) {
            RulePresetSheetView { preset in
                setDraft { draft in
                    for rule in preset.rawRules where !draft.profileRules.contains(rule) {
                        draft.profileRules.append(rule)
                    }
                }
            }
            .formSheetChrome()
        }
        .task {
            if draft == nil, let profile {
                draft = extendStore.settings(for: profile.id)
            }
            // v0.2.147: show the stored library script as picked
            // (settings.scriptId). The onChange above then copies
            // the library's current content into the draft — when
            // the library script was updated since, that surfaces
            // as an unapplied change through the normal flow.
            if selectedScriptID == nil, let profile {
                selectedScriptID = extendStore.settings(for: profile.id).scriptId
            }
            // Unapplied-on-open (FlClash _checkUnappliedOnOpen):
            // compare the stored settings with what is actually
            // baked into the active profile's YAML.
            if let profile, isTargetActive, let yaml = profileStore.activeProfileYAML() {
                let stored = extendStore.settings(for: profile.id)
                unappliedOnOpen = Self.appliedStateDiffers(yaml: yaml, settings: stored)
            }
            // Match-target candidates need a full YAML scan; run it
            // off-thread so the first frame (static title included)
            // is not stalled. See matchTargetCandidates above.
            if let profile {
                let storeRef = profileStore
                let targets = await Task.detached(priority: .userInitiated) {
                    Self.matchTargets(for: profile, store: storeRef)
                }.value
                matchTargetCandidates = targets
                matchTargetsLoaded = true
            }
        }
        .onDisappear {
            // FlClash extend.dart:132-135: auto-apply on dispose.
            // (Also fires when a sub-page is pushed; applying then
            // is harmless — the draft is saved and applied live.)
            let dirty = hasUnappliedChanges
            saveDraft()
            if dirty, isTargetActive {
                Task { await applyNow() }
            }
        }
    }

    /// Targets the match-target picker offers: built-ins, the
    /// profile's groups, and its proxies (FlClash standard.dart
    /// match-target sheet: basic strategies + group names + proxy
    /// names). Loaded once off the main thread in the .task below —
    /// it used to be a computed property that scanned the whole
    /// profile YAML on every body evaluation, stalling the first
    /// frame. The picker shows only "跟随配置" until it lands.
    @State private var matchTargetCandidates: [String] = []
    @State private var matchTargetsLoaded = false

    private static func matchTargets(for profile: Profile, store: ProfileStore) -> [String] {
        var targets = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE"]
        if let groups = store.localProxyGroups(for: profile) {
            targets.append(contentsOf: groups.groups.map { $0.name })
        }
        targets.append(contentsOf: store.localNodeNames(for: profile))
        return Array(NSOrderedSet(array: targets)) as? [String] ?? []
    }

    /// True when the YAML baked into the active profile does
    /// not match the stored settings (match target or per-profile
    /// rules differ) — i.e. there are unapplied changes from an
    /// earlier session.
    private static func appliedStateDiffers(yaml: String, settings: ExtendSettings) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        // Baked MATCH target.
        var bakedTarget = ""
        if let begin = lines.firstIndex(of: ExtendConfigStore.matchTargetBegin),
           begin + 1 < lines.count {
            let line = lines[begin + 1].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- MATCH,") {
                bakedTarget = String(line.dropFirst("- MATCH,".count))
            } else if line.hasPrefix("rules:"), line.contains("MATCH,") {
                bakedTarget = line.components(separatedBy: "MATCH,").last?
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "]", with: "") ?? ""
            }
        }
        guard bakedTarget == settings.matchTarget.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        // Baked per-profile rules.
        var bakedRules: [String] = []
        if let begin = lines.firstIndex(of: ExtendConfigStore.profileRulesBegin),
           let end = lines.firstIndex(of: ExtendConfigStore.profileRulesEnd), end > begin {
            bakedRules = lines[(begin + 1)..<end].map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^- ", with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }
        }
        let wanted = settings.profileRules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return bakedRules != wanted
    }

    private func saveDraft() {
        guard let profile, let draft else { return }
        extendStore.update(draft, for: profile.id)
    }

    private func applyNow() async {
        saveDraft()
        guard let profile else { return }
        // 立即应用 only applies when the target IS the active
        // profile: activeProfileYAML / saveActiveProfileYAML /
        // runScript are all active-profile-scoped. A non-active
        // target keeps its saved settings; the note above says so.
        guard isTargetActive else {
            message = "「\(profile.name)」不是当前已激活的订阅：切换到该订阅后才能立即应用。扩展设置已保存。"
            return
        }
        let current = settings
        isApplying = true
        defer { isApplying = false }
        if current.mode == .script {
            message = await extendStore.runScript(profileStore: profileStore)
            return
        }
        guard var text = profileStore.activeProfileYAML() else {
            message = "没有可写入的当前配置（先导入一个订阅）"
            return
        }
        text = ExtendConfigStore.bakeProfileRules(current.profileRules, into: text)
        text = ExtendConfigStore.bakeMatchTarget(current.matchTarget, into: text)
        message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message = (message ?? "") + " " + live
        }
    }
}

// MARK: - Global rules enable/disable (FlClash extend/standard.dart _EditGlobalAddedRules)

/// Searchable list of the global added rules with per-rule
/// enable/disable toggles (FlClash profileDisabledRuleIdsProvider).
/// Disabling moves the rule to AddedRulesStore.disabledRules, so
/// the tunnel overlay never sees it; enabling moves it back.
private struct GlobalRulesToggleView: View {
    @StateObject private var rulesStore = AddedRulesStore()
    @State private var searchText = ""

    private var allRules: [String] { rulesStore.rules + rulesStore.disabledRules }

    private var visibleRules: [String] {
        guard !searchText.isEmpty else { return allRules }
        return allRules.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        // v0.2.165 (B): the docked search pill lives in this
        // ZStack, replacing the top .searchable field.
        ZStack(alignment: .bottom) {
        List {
            if allRules.isEmpty {
                ContentUnavailableView(
                    "暂无全局规则",
                    systemImage: "list.bullet",
                    description: Text("先在「附加规则」里添加全局规则")
                )
            } else {
                Section("全局规则（\(allRules.count) 条）") {
                    ForEach(visibleRules, id: \.self) { rule in
                        let disabled = rulesStore.isRuleDisabled(rule)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule)
                                    .font(.system(.footnote, design: .monospaced))
                                    .lineLimit(2)
                                    .foregroundStyle(disabled ? .secondary : .primary)
                                Text(disabled ? "已停用" : "生效中")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !disabled },
                                set: { on in rulesStore.setRule(rule, disabled: !on) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
                Section {
                    NavigationLink {
                        AddedRulesView().concordNavBarBackground()
                    } label: {
                        Label("去配置附加规则", systemImage: "list.bullet")
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        // v0.2.165 (B): + 56 for the docked search pill (48 + 8).
        .contentMargins(.bottom, ConcordTheme.tabBarClearance + 56)
        .font(.footnote.weight(.semibold))
        .navigationTitle("全局规则开关")
        .navigationBarTitleDisplayMode(.inline)
        DockedSearchBar(text: $searchText, prompt: "搜索规则")
            .padding(.horizontal, 16)
            .padding(.bottom, ConcordTheme.tabBarClearance + 8)
        }
    }
}
