import SwiftUI

// MARK: - Added rules (FlClash: Tools -> 进阶配置 -> 附加规则)
// Extra Clash rules prepended before the profile's own rules via
// the config.apply overlay (see AddedRulesStore). Rules are edited
// with the structured RuleForm (type picker with descriptions,
// content field with payload validation, rule-provider picker with
// validity check, target picker, no-resolve/src toggles —
// FlClash views/config/rules.dart + features/form/rule_form.dart),
// with multi-select batch delete and the RulePresetSheet quick
// actions (features/form/rule_preset.dart).

struct AddedRulesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var rulesStore = AddedRulesStore()
    @State private var searchText = ""
    /// Structured add/edit sheet (nil = closed).
    @State private var editingRule: RuleFormDraft?
    @State private var showPresets = false
    /// Multi-select mode (FlClash rules.dart itemsProvider): tap to
    /// select, select-all, batch delete with confirm.
    @State private var selectedRules: Set<String> = []
    @State private var showDeleteConfirm = false

    /// Search filters the shown rows (FlClash rules.dart search);
    /// drag reorder only applies to the unfiltered list.
    private var visibleRules: [String] {
        guard !searchText.isEmpty else { return rulesStore.rules }
        return rulesStore.rules.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var isSelecting: Bool { !selectedRules.isEmpty }

    var body: some View {
        List {
            Section {
                Text("附加规则会排在订阅自带规则之前，优先匹配。保存后重启 VPN 生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("附加规则（\(rulesStore.rules.count) 条）") {
                if rulesStore.rules.isEmpty {
                    ContentUnavailableView(
                        "暂无规则",
                        systemImage: "list.bullet",
                        description: Text("点右上角的 + 添加一条规则，或用快捷操作批量添加常用规则")
                    )
                } else if searchText.isEmpty {
                    ForEach(rulesStore.rules, id: \.self) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { offsets in
                        rulesStore.rules.remove(atOffsets: offsets)
                        rulesStore.save()
                    }
                    .onMove { from, to in
                        rulesStore.rules.move(fromOffsets: from, toOffset: to)
                        rulesStore.save()
                    }
                } else {
                    if visibleRules.isEmpty {
                        Text("没有匹配的规则")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleRules, id: \.self) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let rule = visibleRules[index]
                            rulesStore.rules.removeAll { $0 == rule }
                        }
                        rulesStore.save()
                    }
                }
            }
            if !rulesStore.disabledRules.isEmpty {
                Section("已停用（\(rulesStore.disabledRules.count) 条）") {
                    ForEach(rulesStore.disabledRules, id: \.self) { rule in
                        HStack {
                            ruleRowContent(rule)
                            Spacer()
                            Button("启用") { rulesStore.setRule(rule, disabled: false) }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    Text("已停用的规则不在生效列表里，可在「扩展配置 → 全局规则开关」里管理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("附加规则")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索规则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("全选") { selectAllVisible() }
                } else {
                    Button { showPresets = true } label: {
                        Image(systemName: "bolt.circle")
                    }
                    .accessibilityLabel("快捷操作")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除所选")
                } else {
                    Button { editingRule = RuleFormDraft() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加规则")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("取消") { selectedRules.removeAll() }
                } else {
                    EditButton()
                }
            }
        }
        .sheet(item: $editingRule) { draft in
            RuleFormSheet(draft: draft, ruleProviderNames: ruleProviderNames) { saved in
                saveFormRule(saved, replacing: draft.originalText)
            }
            .formSheetChrome()
        }
        .sheet(isPresented: $showPresets) {
            RulePresetSheetView { preset in
                for rule in preset.rawRules where !rulesStore.rules.contains(rule) {
                    rulesStore.rules.append(rule)
                }
                rulesStore.save()
            }
            .formSheetChrome()
        }
        .alert("删除所选的 \(selectedRules.count) 条规则？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                rulesStore.rules.removeAll { selectedRules.contains($0) }
                rulesStore.save()
                selectedRules.removeAll()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// Rule-provider names from the active profile's YAML, for the
    /// RULE-SET provider picker + validity check in the form (same
    /// top-level `rule-providers:` scan as the custom editor).
    private var ruleProviderNames: [String] {
        guard let yaml = profileStore.activeProfileYAML() else { return [] }
        let lines = yaml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == "rule-providers:" || $0.hasPrefix("rule-providers: ") }) else { return [] }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            if line.hasPrefix("  "), !line.hasPrefix("   "), trimmed.hasSuffix(":") {
                out.append(String(trimmed.dropLast()))
            }
        }
        return out
    }

    private func selectAllVisible() {
        let visible = Set(visibleRules)
        selectedRules = selectedRules.isSuperset(of: visible) ? selectedRules.subtracting(visible) : selectedRules.union(visible)
    }

    /// Structured row (FlClash RuleItem): type chip + content +
    /// target, instead of the raw string.
    private func ruleRow(_ rule: String) -> some View {
        Button {
            if isSelecting {
                if selectedRules.contains(rule) { selectedRules.remove(rule) } else { selectedRules.insert(rule) }
            } else {
                editingRule = RuleFormDraft(from: rule)
            }
        } label: {
            HStack(spacing: 8) {
                if isSelecting {
                    Image(systemName: selectedRules.contains(rule) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedRules.contains(rule) ? ConcordTheme.accent : .secondary)
                }
                ruleRowContent(rule)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func ruleRowContent(_ rule: String) -> some View {
        if let parsed = RuleFormDraft.parse(rule) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(parsed.type)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(ConcordTheme.accent)
                    if parsed.type != "MATCH" && parsed.type != "FINAL" {
                        Text(parsed.content)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                Text("→ \(parsed.target)" + (parsed.noResolve ? " · no-resolve" : "") + (parsed.src ? " · src" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(rule)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func saveFormRule(_ draft: RuleFormDraft, replacing original: String?) {
        let text = draft.text
        guard AddedRulesStore.validationError(for: text) == nil else { return }
        if let original, let index = rulesStore.rules.firstIndex(of: original) {
            rulesStore.rules[index] = text
        } else if !rulesStore.rules.contains(text) {
            rulesStore.rules.append(text)
        }
        rulesStore.save()
    }
}

// MARK: - Structured rule form (FlClash RuleForm)

/// A rule being added/edited in the structured form. `originalText`
/// is the raw string being edited (nil for a new rule).
struct RuleFormDraft: Identifiable {
    var id = UUID()
    var type: String = "DOMAIN-SUFFIX"
    var content: String = ""
    var target: String = "DIRECT"
    var noResolve = false
    var src = false
    var originalText: String?

    init() {}

    init(from raw: String) {
        originalText = raw
        if let parsed = Self.parse(raw) {
            type = parsed.type
            content = parsed.content
            target = parsed.target
            noResolve = parsed.noResolve
            src = parsed.src
        } else {
            content = raw
        }
    }

    var text: String {
        if type == "MATCH" || type == "FINAL" { return "\(type),\(target)" }
        var line = "\(type),\(content),\(target)"
        if noResolve { line += ",no-resolve" }
        if src { line += ",src" }
        return line
    }

    /// Quote-aware parse of "TYPE,CONTENT,TARGET[,no-resolve][,src]".
    static func parse(_ raw: String) -> RuleFormDraft? {
        var parts: [String] = []
        var quoted = false
        var start = raw.startIndex
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\"" { quoted.toggle() }
            else if c == "," && !quoted {
                parts.append(String(raw[start..<i]).trimmingCharacters(in: .whitespaces))
                start = raw.index(after: i)
            }
            i = raw.index(after: i)
        }
        parts.append(String(raw[start...]).trimmingCharacters(in: .whitespaces))
        guard parts.count >= 2, AddedRulesStore.knownTypes.contains(parts[0].uppercased()) else { return nil }
        var draft = RuleFormDraft()
        draft.type = parts[0].uppercased()
        if draft.type == "MATCH" || draft.type == "FINAL" {
            guard parts.count == 2 else { return nil }
            draft.target = parts[1]
            return draft
        }
        // AND / OR / NOT payloads contain commas of their own
        // ("AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP"), so
        // the content is everything between the type and the final
        // target, not just parts[1].
        if draft.type == "AND" || draft.type == "OR" || draft.type == "NOT" {
            var tail = parts
            if tail.last == "no-resolve" || tail.last == "src" { tail.removeLast() }
            if tail.last == "no-resolve" || tail.last == "src" { tail.removeLast() }
            guard tail.count >= 3 else { return nil }
            draft.content = tail[1..<(tail.count - 1)].joined(separator: ",")
            draft.target = tail[tail.count - 1]
            draft.noResolve = parts.contains("no-resolve")
            draft.src = parts.contains("src")
            return draft
        }
        guard parts.count >= 3 else { return nil }
        draft.content = parts[1]
        draft.target = parts[2]
        draft.noResolve = parts.contains("no-resolve")
        draft.src = parts.contains("src")
        return draft
    }
}

/// Shared with ExtendConfigView's per-profile rules and the custom
/// editor's rules (same module, internal on purpose).
struct RuleFormSheet: View {
    @State private var draft: RuleFormDraft
    /// The rule text as opened (dirty = serialised text changed).
    private let originalText: String
    @State private var showDiscardConfirm = false
    let ruleProviderNames: [String]
    var onSave: (RuleFormDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: RuleFormDraft, ruleProviderNames: [String], onSave: @escaping (RuleFormDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.originalText = draft.text
        self.ruleProviderNames = ruleProviderNames
        self.onSave = onSave
    }

    private var isDirty: Bool { draft.text != originalText }

    private var validationError: String? {
        AddedRulesStore.validationError(for: draft.text)
    }

    /// RULE-SET provider validity (FlClash rules.dart
    /// customProfileRuleProviderIsValidProvider): the named provider
    /// must exist.
    private var isRuleSetProviderInvalid: Bool {
        draft.type == "RULE-SET" && !ruleProviderNames.isEmpty && !ruleProviderNames.contains(draft.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    Picker("类型", selection: $draft.type) {
                        ForEach(CustomRule.types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    if draft.type != "MATCH" && draft.type != "FINAL" {
                        if draft.type == "RULE-SET" && !ruleProviderNames.isEmpty {
                            Picker("规则集", selection: $draft.content) {
                                Text("选择规则集").tag("")
                                ForEach(ruleProviderNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        } else {
                            TextField(draft.type == "RULE-SET" ? "规则集名称" : "规则内容", text: $draft.content)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if isRuleSetProviderInvalid {
                            Text("规则集「\(draft.content)」不存在于当前配置的规则提供方里。")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    TextField("策略（分组或节点名）", text: $draft.target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if draft.type != "MATCH" && draft.type != "FINAL" {
                        Toggle("不解析域名（no-resolve）", isOn: $draft.noResolve)
                        Toggle("匹配源 IP（src）", isOn: $draft.src)
                    }
                }
                Section {
                    Text("预览：\(draft.text)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let error = validationError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle(draft.originalText == nil ? "添加规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(validationError != nil || isRuleSetProviderInvalid)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }
}

// MARK: - Rule presets (FlClash features/form/rule_preset.dart)

/// Quick-action preset sheet: pick one or more presets, confirm to
/// add their rules (skipping duplicates). Shared by AddedRulesView,
/// the custom editor's rules section and Extend's per-profile rules.
struct RulePresetSheetView: View {
    var onAdd: (RulePreset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<RulePreset> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(RulePreset.allCases, id: \.self) { preset in
                    Button {
                        if selected.contains(preset) { selected.remove(preset) } else { selected.insert(preset) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                ForEach(preset.rawRules, id: \.self) { rule in
                                    Text(rule)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if selected.contains(preset) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("快捷操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        for preset in selected { onAdd(preset) }
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}
