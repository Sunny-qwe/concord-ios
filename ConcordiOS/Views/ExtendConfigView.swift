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
    @State private var draft: ExtendSettings?
    @State private var message: String?
    @State private var isApplying = false

    private var profile: Profile? { profileStore.activeProfile }

    private var settings: ExtendSettings {
        draft ?? (profile.map { extendStore.settings(for: $0.id) } ?? ExtendSettings())
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
                                Text(mode.label).font(.system(size: 13))
                                Text(mode.description)
                                    .font(.system(size: 10))
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
                                Text("附加规则").font(.system(size: 13))
                                Text("在当前配置的规则之前先生效，扩展合并进配置")
                                    .font(.system(size: 10))
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
                    Text("匹配目标会作为最后一条 MATCH 规则写进当前配置；留空则跟随配置自身的最后一条规则。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("脚本模式") {
                    Toggle("启用脚本", isOn: Binding(
                        get: { settings.scriptEnabled },
                        set: { newValue in setDraft { $0.scriptEnabled = newValue } }
                    ))
                    Text("脚本定义 function main(config)，返回改写后的配置对象。config 是核心解析后的当前配置。运行需要核心可达（启动 VPN，或示例模式）。")
                        .font(.system(size: 10))
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
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if profile == nil {
                    Text("没有已激活的订阅：先导入并切换一个订阅。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("应用后立即生效（VPN 运行时）或下次启动 VPN 时生效；标准模式的附加规则由扩展合并，不用改订阅文件。")
            }
        }
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
        }
        .onDisappear {
            saveDraft()
        }
    }

    /// Targets the match-target picker offers: built-ins, the
    /// active profile's groups, and its proxies.
    private var matchTargetCandidates: [String] {
        var targets = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE"]
        if let profile {
            targets.append(contentsOf: profileStore.localNodeNames(for: profile))
        }
        return Array(NSOrderedSet(array: targets)) as? [String] ?? []
    }

    private func saveDraft() {
        guard let profile, let draft else { return }
        extendStore.update(draft, for: profile.id)
    }

    private func applyNow() async {
        saveDraft()
        guard let profile else { return }
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
