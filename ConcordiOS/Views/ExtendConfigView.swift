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
    /// The library script picked for script mode (FlClash
    /// extend/script.dart picks from the stored script library;
    /// picking one loads its text into the inline editor).
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
                                Text(mode.label).font(.system(size: 13, weight: .semibold))
                                Text(mode.description)
                                    .font(.system(size: 13))
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
                        AddedRulesView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("附加规则").font(.system(size: 13, weight: .semibold))
                                Text("在当前配置的规则之前先生效，扩展合并进配置")
                                    .font(.system(size: 13))
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
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                    Text("匹配目标会作为最后一条 MATCH 规则写进当前配置；留空则跟随配置自身的最后一条规则。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("脚本模式") {
                    Toggle("启用脚本", isOn: Binding(
                        get: { settings.scriptEnabled },
                        set: { newValue in setDraft { $0.scriptEnabled = newValue } }
                    ))
                    // FlClash extend/script.dart: pick one script
                    // from the stored library, or keep the inline
                    // editor. Picking loads the library script's
                    // text into the editor below.
                    Picker("从脚本库选择", selection: $selectedScriptID) {
                        Text("不使用脚本库").tag(nil as String?)
                        ForEach(scriptStore.scripts) { script in
                            Text(script.label).tag(script.id as String?)
                        }
                    }
                    .onChange(of: selectedScriptID) { _, id in
                        guard let id,
                              let script = scriptStore.scripts.first(where: { $0.id == id }),
                              let content = scriptStore.content(of: script) else { return }
                        setDraft { $0.scriptText = content }
                    }
                    NavigationLink {
                        MitmScriptsView()
                    } label: {
                        HStack {
                            Text("管理 MITM 脚本")
                            Spacer()
                            Text("\(scriptStore.scripts.count) 个")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("脚本定义 function main(config)，返回改写后的配置对象。config 是核心解析后的当前配置。运行需要核心可达（启动 VPN，或示例模式）。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Section("脚本") {
                    TextEditor(text: Binding(
                        get: { settings.scriptText },
                        set: { newValue in setDraft { $0.scriptText = newValue } }
                    ))
                    .frame(minHeight: 220)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    Button("填入示例脚本") {
                        setDraft { $0.scriptText = ExtendSettings.defaultScript }
                    }
                }
            }

            if hasUnappliedChanges {
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
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if profile == nil {
                        Text("没有已激活的订阅：先导入并切换一个订阅。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("应用后立即生效（VPN 运行时）或下次启动 VPN 时生效；标准模式的附加规则由扩展合并，不用改订阅文件。")
                        .font(.system(size: 13))
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
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("扩展配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { saveDraft() }
            }
        }
        .task {
            if draft == nil, let profile {
                draft = extendStore.settings(for: profile.id)
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
        text = ExtendConfigStore.bakeMatchTarget(current.matchTarget, into: text)
        message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message = (message ?? "") + " " + live
        }
    }
}
