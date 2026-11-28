import SwiftUI

// MARK: - Override framework UI (FlClash: lib/views/config/override.dart)
// One page per FlClash OverrideView: pick a scope (global, or one
// subscription), enable keys per section (general / DNS / TUN /
// sniffer / NTP), edit their values, and see the YAML the override
// produces. Only enabled keys exist in the override — a key that is
// not enabled leaves the profile's own value alone. A profile's
// keys win over the global ones; the extension merges them into
// config.apply's overlay (see OverrideStore).
//
// The same section editor is reused by TunOverrideView (the TUN
// section on its own page).
//
// v0.2.159: upstream has NO override hub — OverrideView is one
// page per section (General / DNS / TUN / NTP / Sniffer), with an
// app-bar add button and a quick-edit (YAML) app-bar button. The
// hub is kept (it is the override editor's navigation unit in
// this app), restyled to upstream cards; the per-section pages
// match upstream's one-page-per-section shape. The per-profile
// inline section mirrors FlClash's DnsView.profile /
// NtpView.profile / SnifferView.profile (same page, profile
// target). Override keys are NOT added/removed here — only
// restyled (the map did not compare key specs against upstream
// *OverrideKey enums).

struct OverrideView: View {
    @ObservedObject private var store = OverrideStore.shared
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var scope: String? = nil
    @State private var copied = false
    /// YAML at page entry, for the apply-on-leave check (FlClash
    /// edits update the target live; ours applies when leaving
    /// with changes, or on 应用覆盖）.
    @State private var baselineYAML: String?
    /// YAML quick-edit sheet (v0.2.165 D): the inline quick-edit
    /// TextEditor is gone — upstream override.dart opens the YAML
    /// editor from the ✎ bar button instead, so the hub ✎ opens
    /// this sheet for the whole scope (section = nil).
    @State private var showYamlSheet = false

    init(scope: String? = nil) {
        _scope = State(initialValue: scope)
    }

    /// Leading icon per override section (the hub rows are nav
    /// rows, so each needs a grey UpstreamRowIcon).
    private func sectionIcon(_ section: OverrideSection) -> String {
        switch section {
        case .general: return "slider.horizontal.3"
        case .dns: return "network"
        case .tun: return "cable.connector"
        case .sniffer: return "antenna.radiowaves.left.and.right"
        case .ntp: return "clock"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("覆盖只对启用的项生效：没启用的项用订阅自己的值。全局覆盖对所有订阅生效，单个订阅的覆盖优先于全局。改动在离开本页时自动应用（VPN 运行时立即生效，否则下次启动 VPN 时生效），也可以点「应用覆盖」立即应用。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                UpstreamCardSection(header: "作用范围") {
                    HStack(spacing: 16) {
                        Text("作用范围")
                            .font(.body)
                            .foregroundStyle(Color(.label))
                        Spacer()
                        Picker("", selection: $scope) {
                            Text("全局（全部订阅）").tag(nil as String?)
                            ForEach(profileStore.profiles) { profile in
                                Text(profile.name).tag(profile.id.uuidString as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                }
                // One page per section (FlClash DnsView / NtpView /
                // SnifferView / TunView + general overrides, each its
                // own OverrideView with its own title and app-bar add
                // button). Tapping a row pushes that section's editor.
                UpstreamCardSection(header: "覆盖分组") {
                    ForEach(OverrideSection.allCases) { section in
                        if section != OverrideSection.allCases.first { UpstreamDivider() }
                        NavigationLink {
                            OverrideSectionPage(section: section, scope: scope)
                                .concordNavBarBackground()
                        } label: {
                            UpstreamNavRowContent(
                                icon: sectionIcon(section),
                                title: section.label,
                                value: "\(store.state(scope: scope, section: section).count) 项已启用"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                UpstreamCardSection(header: "YAML 预览") {
                    Text(store.yamlText(scope: scope))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    UpstreamDivider(leading: 16)
                    Button(copied ? "已复制" : "复制 YAML") {
                        UIPasteboard.general.string = store.yamlText(scope: scope)
                        copied = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ConcordTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    UpstreamDivider(leading: 16)
                    Text("点右上角 ✎ 可以直接编辑 YAML（解析校验通过后才保存）。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                // v0.2.165 (D): the inline YAML quick-edit card is
                // gone — upstream override.dart opens the YAML
                // editor from the ✎ bar button, so editing now
                // lives in OverrideYamlQuickEditSheet (hub ✎ =
                // whole scope, section-page ✎ = that section).
                VStack(alignment: .leading, spacing: 8) {
                    Button("应用覆盖") {
                        Task { await store.applyOverrides() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConcordTheme.accent)
                    .frame(maxWidth: .infinity)
                    if let message = store.applyMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "覆盖")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                UpstreamBarButton(systemName: "square.and.pencil", label: "快速编辑 YAML") {
                    showYamlSheet = true
                }
            }
        }
        .sheet(isPresented: $showYamlSheet) {
            OverrideYamlQuickEditSheet(scope: scope, section: nil)
                .formSheetChrome()
        }
        .task {
            baselineYAML = store.yamlText(scope: scope)
        }
        .onChange(of: scope) { _, newScope in
            baselineYAML = store.yamlText(scope: newScope)
        }
        .onDisappear {
            // FlClash applies override edits live; ours applies on
            // leaving when anything changed (the explicit 应用覆盖
            // button below does the same on demand).
            if baselineYAML != store.yamlText(scope: scope) {
                Task { await store.applyOverrides() }
            }
        }
    }

    // MARK: - YAML 快速编辑校验（v0.2.55，v0.2.165 D 改为共享静态方法）

    // The hub inline editor is gone; the same validation now serves
    // OverrideYamlQuickEditSheet (whole scope, or one section via
    // flattenOverrideKeys). Only the edited scope / section is
    // replaced — the rest of the stored state is kept.

    /// 把 YAML 文本解析成 scope 的完整覆盖状态（section -> key -> value）。
    /// test-url 是客户端专用的测速地址兜底，预览里不显示，保存时原样保留。
    fileprivate static func validateOverrideYAML(_ text: String, scope: String?) throws -> [String: [String: JSONValue]] {
        let doc = try YamlParser.parse(text)
        // 空文档（或只有注释，如预览的 "# 暂无覆盖项"）= 清空本范围的覆盖
        let top: [String: JSONValue]
        switch doc {
        case .null:
            top = [:]
        case .object(let dict):
            top = dict
        default:
            throw YamlParserError(line: nil, message: "顶层必须是映射（key: value 形式）")
        }
        var out: [String: [String: JSONValue]] = [:]
        for (sectionName, sectionValue) in top {
            guard let section = OverrideSection(rawValue: sectionName) else {
                throw YamlParserError(line: nil, message: "未知的分组「\(sectionName)」，只能是 general、dns、tun、sniffer、ntp")
            }
            guard case .object(let sectionDict) = sectionValue else {
                throw YamlParserError(line: nil, message: "分组「\(sectionName)」的值必须是映射")
            }
            var flat: [String: JSONValue] = [:]
            try flattenOverrideKeys(section: section, dict: sectionDict, prefix: "", into: &flat)
            if !flat.isEmpty {
                out[sectionName] = flat
            }
        }
        if let testURL = OverrideStore.shared.testURL(scope: scope) {
            var general = out["general"] ?? [:]
            general["test-url"] = .string(testURL)
            out["general"] = general
        }
        return out
    }

    /// 把一个分组的嵌套映射展平成点分键（fallback-filter.geoip、
    /// sniff.HTTP），并按该分组的 key spec 逐项校验。stringMap
    /// （nameserver-policy）和 sniff 协议对象整体校验，不再展开。
    fileprivate static func flattenOverrideKeys(section: OverrideSection, dict: [String: JSONValue], prefix: String, into out: inout [String: JSONValue]) throws {
        let specs = OverrideStore.specs(for: section)
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if key.contains(".") {
                guard let spec = specs.first(where: { $0.key == fullKey }) else {
                    throw YamlParserError(line: nil, message: "未知的覆盖项「\(fullKey)」")
                }
                out[fullKey] = try validateOverrideValue(value, spec: spec, key: fullKey)
                continue
            }
            if let spec = specs.first(where: { $0.key == fullKey }) {
                switch spec.kind {
                case .stringMap, .sniff:
                    out[fullKey] = try validateOverrideValue(value, spec: spec, key: fullKey)
                default:
                    if case .object(let nested) = value {
                        try flattenOverrideKeys(section: section, dict: nested, prefix: fullKey, into: &out)
                    } else {
                        out[fullKey] = try validateOverrideValue(value, spec: spec, key: fullKey)
                    }
                }
                continue
            }
            if case .object(let nested) = value {
                try flattenOverrideKeys(section: section, dict: nested, prefix: fullKey, into: &out)
            } else {
                throw YamlParserError(line: nil, message: "未知的覆盖项「\(fullKey)」")
            }
        }
    }

    /// 按 key spec 的 kind 校验一个值（类型、选项范围、数字上下限）。
    fileprivate static func validateOverrideValue(_ value: JSONValue, spec: OverrideKeySpec, key: String) throws -> JSONValue {
        switch spec.kind {
        case .toggle:
            guard case .bool = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为 true/false")
            }
            return value
        case .text:
            guard case .string = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为字符串")
            }
            return value
        case .number:
            guard case .int(let number) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为整数")
            }
            if let min = spec.min, number < Int64(min) {
                throw YamlParserError(line: nil, message: "「\(key)」不能小于 \(min)")
            }
            if let max = spec.max, number > Int64(max) {
                throw YamlParserError(line: nil, message: "「\(key)」不能大于 \(max)")
            }
            return value
        case .stringList:
            guard case .array(let items) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为字符串列表")
            }
            for item in items {
                guard case .string = item else {
                    throw YamlParserError(line: nil, message: "「\(key)」里的每一项都必须是字符串")
                }
            }
            return value
        case .numberList:
            guard case .array(let items) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为数字列表")
            }
            for item in items {
                guard case .int = item else {
                    throw YamlParserError(line: nil, message: "「\(key)」里的每一项都必须是整数")
                }
            }
            return value
        case .stringMap:
            guard case .object(let dict) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为映射")
            }
            for (_, item) in dict {
                guard case .string = item else {
                    throw YamlParserError(line: nil, message: "「\(key)」的值都必须是字符串")
                }
            }
            return value
        case .options:
            guard case .string(let text) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为字符串")
            }
            guard spec.options?.contains(text) == true else {
                throw YamlParserError(line: nil, message: "「\(key)」的值「\(text)」不在可选范围：\((spec.options ?? []).joined(separator: "、"))")
            }
            return value
        case .sniff:
            guard case .object(let dict) = value else {
                throw YamlParserError(line: nil, message: "「\(key)」应为映射")
            }
            let allowed: Set<String> = ["ports", "override-destination"]
            for child in dict.keys where !allowed.contains(child) {
                throw YamlParserError(line: nil, message: "「\(key)」含有无法识别的字段「\(child)」")
            }
            if let ports = dict["ports"] {
                guard case .array(let items) = ports else {
                    throw YamlParserError(line: nil, message: "「\(key)」的 ports 应为列表")
                }
                for item in items {
                    guard case .string = item else {
                        throw YamlParserError(line: nil, message: "「\(key)」的 ports 里的每一项都必须是字符串")
                    }
                }
            }
            if let dest = dict["override-destination"] {
                guard case .bool = dest else {
                    throw YamlParserError(line: nil, message: "「\(key)」的 override-destination 应为 true/false")
                }
            }
            return value
        }
    }
}

// MARK: - YAML quick-edit sheet (FlClash override.dart _handleQuickEdit)

/// The override as YAML text, edited in a sheet opened from the ✎
/// bar button (v0.2.165 D — upstream has no inline YAML editor on
/// the page; the editor is a separate surface). `section == nil`
/// edits the whole scope (hub ✎); otherwise only that section's
/// mapping, and only that section is replaced on save — every
/// other section is kept. Validation is the hub's old inline
/// rule set (OverrideView.validateOverrideYAML /
/// flattenOverrideKeys); an error is shown and the stored state
/// is left untouched. test-url never appears in the text and is
/// preserved on save, as before.
private struct OverrideYamlQuickEditSheet: View {
    let scope: String?
    let section: OverrideSection?
    @ObservedObject private var store = OverrideStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var error: String?

    init(scope: String?, section: OverrideSection?) {
        self.scope = scope
        self.section = section
        _draft = State(initialValue: Self.initialText(scope: scope, section: section))
    }

    private var title: String {
        if let section { return "\(section.label) YAML" }
        return "覆盖 YAML"
    }

    private var note: String {
        if let section {
            return "只接受\(section.label)的已知覆盖项；未知项或类型不对会报错并保留原文本。留空会清空该分组的覆盖。"
        }
        return "只接受 general、dns、tun、sniffer、ntp 五个分组和已知的覆盖项；未知项或类型不对会报错并保留原文本。test-url 不在这里编辑（它只保存在 App 内用作测速地址兜底）。"
    }

    /// The text the sheet opens with: one section's mapping, or
    /// the whole scope's YAML for the hub.
    private static func initialText(scope: String?, section: OverrideSection?) -> String {
        let store = OverrideStore.shared
        guard let section else { return store.yamlText(scope: scope) }
        let values = store.state(scope: scope, section: section)
        guard !values.isEmpty else { return "# 暂无覆盖项\n" }
        return YAMLValue.lines(for: .object(OverrideStore.expanded(values)), indent: 0)
            .joined(separator: "\n") + "\n"
    }

    /// Parse + validate one section's mapping into its flat
    /// key/value state (same rules as the whole-scope validator).
    private static func sectionValues(_ text: String, section: OverrideSection, scope: String?) throws -> [String: JSONValue] {
        let doc = try YamlParser.parse(text)
        let top: [String: JSONValue]
        switch doc {
        case .null:
            top = [:]
        case .object(let dict):
            top = dict
        default:
            throw YamlParserError(line: nil, message: "顶层必须是映射（key: value 形式）")
        }
        var flat: [String: JSONValue] = [:]
        try OverrideView.flattenOverrideKeys(section: section, dict: top, prefix: "", into: &flat)
        if section == .general, let testURL = OverrideStore.shared.testURL(scope: scope) {
            flat["test-url"] = .string(testURL)
        }
        return flat
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            if let section {
                let values = try Self.sectionValues(draft, section: section, scope: scope)
                store.replaceSection(scope: scope, section: section, values: values)
            } else {
                let values = try OverrideView.validateOverrideYAML(draft, scope: scope)
                store.replaceScope(scope: scope, values: values)
            }
            error = nil
            dismiss()
        } catch let saveError {
            error = saveError.localizedDescription
        }
    }
}

/// One section on its own page (FlClash override.dart: one
/// OverrideView per section).
private struct OverrideSectionPage: View {
    let section: OverrideSection
    let scope: String?
    @State private var editableScope: String?

    init(section: OverrideSection, scope: String?) {
        self.section = section
        self.scope = scope
        _editableScope = State(initialValue: scope)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OverrideSectionEditorCard(section: section, scope: $editableScope, showToolbarAdd: true, showToolbarQuickEdit: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: section.label)
    }
}

// MARK: - One section's override editor (shared by OverrideView
// and TunOverrideView)

struct OverrideSectionEditor: View {
    let section: OverrideSection
    @Binding var scope: String?
    /// Show the + add button in the page's top-right bar (v0.2.165
    /// C): off by default — the editor is also embedded in pages
    /// that must not gain a bar button (e.g. the inline section on
    /// the DNS page enables it; other embeddings leave it off).
    let showToolbarAdd: Bool
    /// Show the ✎ quick-edit button next to it (v0.2.165 D):
    /// upstream OverrideView carries add + quick-edit together.
    /// Off by default, enabled at the same call sites as the +.
    let showToolbarQuickEdit: Bool
    @ObservedObject private var store = OverrideStore.shared
    @State private var showAddSheet = false
    @State private var showYamlSheet = false

    init(section: OverrideSection, scope: Binding<String?>, showToolbarAdd: Bool = false, showToolbarQuickEdit: Bool = false) {
        self.section = section
        self._scope = scope
        self.showToolbarAdd = showToolbarAdd
        self.showToolbarQuickEdit = showToolbarQuickEdit
    }

    private var enabledKeys: [String] {
        store.state(scope: scope, section: section).keys.sorted()
    }

    private var remainingSpecs: [OverrideKeySpec] {
        let enabled = Set(enabledKeys)
        return OverrideStore.specs(for: section).filter { spec in
            guard !enabled.contains(spec.key) else { return false }
            // C13-c2 (MuYu tunCongestionAvailable): the
            // congestion-controller key is only offered when the
            // core reports a congestion controller. Unknown (never
            // queried — nil) still offers it: the TUN page
            // refreshes on appear, and hiding the key before any
            // query would orphan it for users who never open the
            // TUN page. An already-enabled key stays editable even
            // when the core reports none (removing it silently
            // would lose the user's value).
            if section == .tun, spec.key == "congestion-controller",
               let controllers = store.congestionControllers, controllers.isEmpty {
                return false
            }
            return true
        }
    }

    var body: some View {
        Section(section.label) {
            // Upstream NullStatus: an empty section says so and
            // points at the add action (the add row below stays).
            if enabledKeys.isEmpty {
                Text("暂无已启用的覆盖项：点下面的「添加覆盖项」启用一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(enabledKeys, id: \.self) { key in
                if let spec = OverrideStore.specs(for: section).first(where: { $0.key == key }) {
                    OverrideKeyRow(section: section, scope: $scope, spec: spec)
                }
            }
            Button {
                showAddSheet = true
            } label: {
                Label("添加覆盖项", systemImage: "plus.circle")
            }
            .disabled(remainingSpecs.isEmpty)
        }
        .sheet(isPresented: $showAddSheet) {
            OverrideAddSheet(section: section, scope: $scope, specs: remainingSpecs) {
                showAddSheet = false
            }
            .formSheetChrome()
        }
        .sheet(isPresented: $showYamlSheet) {
            OverrideYamlQuickEditSheet(scope: scope, section: section)
                .formSheetChrome()
        }
        .toolbar {
            if showToolbarAdd {
                ToolbarItem(placement: .topBarTrailing) {
                    UpstreamBarButton(systemName: "plus.circle", label: "添加覆盖项") {
                        showAddSheet = true
                    }
                    .disabled(remainingSpecs.isEmpty)
                }
            }
            if showToolbarQuickEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    UpstreamBarButton(systemName: "square.and.pencil", label: "快速编辑 YAML") {
                        showYamlSheet = true
                    }
                }
            }
        }
    }
}

/// Card version of OverrideSectionEditor (v0.2.159): the same
/// enabled-key rows + add button inside an UpstreamCardSection,
/// for the ScrollView pages (OverrideSectionPage, the per-profile
/// inline card). The Section version above is kept unchanged for
/// TunOverrideView, which still embeds it in a List.
struct OverrideSectionEditorCard: View {
    let section: OverrideSection
    @Binding var scope: String?
    /// Show the + add button in the page's top-right bar (v0.2.165
    /// C): off by default — the card is also embedded in the
    /// Settings 常规 page, which must not gain a bar button.
    let showToolbarAdd: Bool
    /// Show the ✎ quick-edit button next to it (v0.2.165 D):
    /// upstream OverrideView carries add + quick-edit together.
    /// Off by default, enabled at the same call sites as the +.
    let showToolbarQuickEdit: Bool
    @ObservedObject private var store = OverrideStore.shared
    @State private var showAddSheet = false
    @State private var showYamlSheet = false

    init(section: OverrideSection, scope: Binding<String?>, showToolbarAdd: Bool = false, showToolbarQuickEdit: Bool = false) {
        self.section = section
        self._scope = scope
        self.showToolbarAdd = showToolbarAdd
        self.showToolbarQuickEdit = showToolbarQuickEdit
    }

    private var enabledKeys: [String] {
        store.state(scope: scope, section: section).keys.sorted()
    }

    private var remainingSpecs: [OverrideKeySpec] {
        let enabled = Set(enabledKeys)
        return OverrideStore.specs(for: section).filter { spec in
            guard !enabled.contains(spec.key) else { return false }
            if section == .tun, spec.key == "congestion-controller",
               let controllers = store.congestionControllers, controllers.isEmpty {
                return false
            }
            return true
        }
    }

    var body: some View {
        UpstreamCardSection(header: section.label) {
            // Upstream NullStatus: an empty section says so and
            // points at the add action (the add row below stays).
            if enabledKeys.isEmpty {
                Text("暂无已启用的覆盖项：点下面的「添加覆盖项」启用一项。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            ForEach(Array(enabledKeys.enumerated()), id: \.element) { index, key in
                if index > 0 { UpstreamDivider(leading: 16) }
                if let spec = OverrideStore.specs(for: section).first(where: { $0.key == key }) {
                    OverrideKeyRow(section: section, scope: $scope, spec: spec)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            if !enabledKeys.isEmpty { UpstreamDivider(leading: 16) }
            Button {
                showAddSheet = true
            } label: {
                HStack(spacing: 16) {
                    UpstreamRowIcon(systemName: "plus.circle")
                    Text("添加覆盖项")
                        .font(.body)
                        .foregroundStyle(remainingSpecs.isEmpty ? Color(.tertiaryLabel) : ConcordTheme.accent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 56)
            }
            .buttonStyle(.plain)
            .disabled(remainingSpecs.isEmpty)
        }
        .sheet(isPresented: $showAddSheet) {
            OverrideAddSheet(section: section, scope: $scope, specs: remainingSpecs) {
                showAddSheet = false
            }
            .formSheetChrome()
        }
        .sheet(isPresented: $showYamlSheet) {
            OverrideYamlQuickEditSheet(scope: scope, section: section)
                .formSheetChrome()
        }
        .toolbar {
            if showToolbarAdd {
                ToolbarItem(placement: .topBarTrailing) {
                    UpstreamBarButton(systemName: "plus.circle", label: "添加覆盖项") {
                        showAddSheet = true
                    }
                    .disabled(remainingSpecs.isEmpty)
                }
            }
            if showToolbarQuickEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    UpstreamBarButton(systemName: "square.and.pencil", label: "快速编辑 YAML") {
                        showYamlSheet = true
                    }
                }
            }
        }
    }
}

// MARK: - Inline per-profile override section (C7-c1 / C9-c1 / C12-c1)

/// The per-profile half of a settings page (FlClash: DnsView.profile
/// / NtpView.profile / SnifferView.profile — each is an OverrideView
/// with a profile target, global patch + per-profile keys on the
/// same page). The page's own base fields are the global patch; this
/// section edits ONE subscription's overrides in place, instead of
/// linking out to the generic OverrideView. Pick a subscription to
/// reveal its editor; the overrides save immediately (the store
/// writes overrides.json on every edit) and the 应用覆盖 button
/// re-applies them like the page's own save button does.
struct InlineProfileOverrideSection: View {
    let section: OverrideSection
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var store = OverrideStore.shared
    @State private var scope: String? = nil

    var body: some View {
        Section("按订阅覆盖") {
            Picker("订阅", selection: $scope) {
                Text("选择订阅…").tag(nil as String?)
                ForEach(profileStore.profiles) { profile in
                    Text(profile.name).tag(profile.id.uuidString as String?)
                }
            }
            .pickerStyle(.menu)
            if scope == nil {
                Text("选一个订阅，在这里单独覆盖\(section.label)；没有覆盖的订阅用上面的全局设置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if scope != nil {
            OverrideSectionEditor(section: section, scope: $scope, showToolbarAdd: true, showToolbarQuickEdit: true)
            Section {
                Button("应用覆盖") {
                    Task { await store.applyOverrides() }
                }
                if let message = store.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("覆盖只对该订阅生效；没有覆盖的项用上面的全局设置。VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Card version of InlineProfileOverrideSection (v0.2.159) for the
/// ScrollView pages (NTP, Sniffer). The Section version above is
/// kept unchanged for DnsSettingsView, which still embeds it in a
/// List.
struct InlineProfileOverrideCard: View {
    let section: OverrideSection
    /// Show the + add button in the page's top-right bar (v0.2.165
    /// C): the NTP page enables it; the Sniffer page leaves it off.
    let showToolbarAdd: Bool
    /// Show the ✎ quick-edit button next to it (v0.2.165 D):
    /// same call sites as the +.
    let showToolbarQuickEdit: Bool
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var store = OverrideStore.shared
    @State private var scope: String? = nil

    init(section: OverrideSection, showToolbarAdd: Bool = false, showToolbarQuickEdit: Bool = false) {
        self.section = section
        self.showToolbarAdd = showToolbarAdd
        self.showToolbarQuickEdit = showToolbarQuickEdit
    }

    var body: some View {
        UpstreamCardSection(header: "按订阅覆盖") {
            HStack(spacing: 16) {
                Text("订阅")
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Spacer()
                Picker("", selection: $scope) {
                    Text("选择订阅…").tag(nil as String?)
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            if scope == nil {
                UpstreamDivider(leading: 16)
                Text("选一个订阅，在这里单独覆盖\(section.label)；没有覆盖的订阅用上面的全局设置。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        if scope != nil {
            OverrideSectionEditorCard(section: section, scope: $scope, showToolbarAdd: showToolbarAdd, showToolbarQuickEdit: showToolbarQuickEdit)
            VStack(alignment: .leading, spacing: 8) {
                Button("应用覆盖") {
                    Task { await store.applyOverrides() }
                }
                .buttonStyle(.borderedProminent)
                .tint(ConcordTheme.accent)
                .frame(maxWidth: .infinity)
                if let message = store.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
                Text("覆盖只对该订阅生效；没有覆盖的项用上面的全局设置。VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
        }
    }
}

/// The add sheet: the section's remaining keys with their
/// descriptions. Tapping one enables it at its default value.
private struct OverrideAddSheet: View {
    let section: OverrideSection
    @Binding var scope: String?
    let specs: [OverrideKeySpec]
    let onDone: () -> Void
    @ObservedObject private var store = OverrideStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(specs, id: \.key) { spec in
                    Button {
                        store.addKey(scope: scope, section: section, key: spec.key)
                        dismiss()
                        onDone()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.label)
                            if let description = spec.description {
                                Text(description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("添加\(section.label)覆盖项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - One enabled key's editor row

private struct OverrideKeyRow: View {
    let section: OverrideSection
    @Binding var scope: String?
    let spec: OverrideKeySpec
    @ObservedObject private var store = OverrideStore.shared

    private var value: JSONValue? {
        store.state(scope: scope, section: section)[spec.key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    store.removeKey(scope: scope, section: section, key: spec.key)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                Text(spec.label)
                Spacer()
            }
            editor
            if let description = spec.description {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var editor: some View {
        switch spec.kind {
        case .toggle:
            Toggle(spec.label, isOn: boolBinding())
                .labelsHidden()
                .toggleStyle(UpstreamToggleStyle())
        case .text:
            TextField(spec.label, text: stringBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number:
            HStack {
                TextField(spec.label, value: intBinding(), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        case .stringList:
            NavigationLink("编辑列表（\(stringListBinding().wrappedValue.count) 项）") {
                OverrideStringListPage(title: spec.label, items: stringListBinding())
            }
        case .numberList:
            NavigationLink("编辑列表（\(numberListBinding().wrappedValue.count) 项）") {
                OverrideNumberListPage(title: spec.label, items: numberListBinding())
            }
        case .stringMap:
            NavigationLink("编辑映射（\(stringMapBinding().wrappedValue.count) 项）") {
                OverrideStringMapPage(title: spec.label, items: stringMapBinding())
            }
        case .options:
            Picker(spec.label, selection: stringBinding()) {
                ForEach(spec.options ?? [], id: \.self) { option in
                    Text(spec.optionLabels?[option] ?? option).tag(option)
                }
            }
            .pickerStyle(.menu)
        case .sniff:
            SniffOverrideEditor(
                ports: sniffPortsBinding(),
                overrideDest: sniffDestBinding()
            )
        }
    }

    private func boolBinding() -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let v) = value { return v }
                if case .bool(let d) = spec.defaultValue { return d }
                return false
            },
            set: { store.setValue(scope: scope, section: section, key: spec.key, value: .bool($0)) }
        )
    }

    private func stringBinding() -> Binding<String> {
        Binding(
            get: {
                if case .string(let v) = value { return v }
                if case .string(let d) = spec.defaultValue { return d }
                return ""
            },
            set: { store.setValue(scope: scope, section: section, key: spec.key, value: .string($0)) }
        )
    }

    private func intBinding() -> Binding<Int> {
        Binding(
            get: {
                if case .int(let v) = value { return Int(v) }
                if case .int(let d) = spec.defaultValue { return Int(d) }
                return 0
            },
            set: { new in
                var clamped = new
                if let min = spec.min { clamped = max(min, clamped) }
                if let max = spec.max { clamped = min(max, clamped) }
                store.setValue(scope: scope, section: section, key: spec.key, value: .int(Int64(clamped)))
            }
        )
    }

    private func stringListBinding() -> Binding<[String]> {
        Binding(
            get: {
                guard case .array(let items) = value else { return [] }
                return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            },
            set: { store.setValue(scope: scope, section: section, key: spec.key, value: .array($0.map(JSONValue.string))) }
        )
    }

    private func numberListBinding() -> Binding<[Int]> {
        Binding(
            get: {
                guard case .array(let items) = value else { return [] }
                return items.compactMap { if case .int(let n) = $0 { return Int(n) } else { return nil } }
            },
            set: { store.setValue(scope: scope, section: section, key: spec.key, value: .array($0.map { JSONValue.int(Int64($0)) })) }
        )
    }

    private func stringMapBinding() -> Binding<[String: String]> {
        Binding(
            get: {
                guard case .object(let dict) = value else { return [:] }
                var out: [String: String] = [:]
                for (k, v) in dict {
                    if case .string(let s) = v { out[k] = s }
                }
                return out
            },
            set: { store.setValue(scope: scope, section: section, key: spec.key, value: .object($0.mapValues(JSONValue.string))) }
        )
    }

    private func sniffPortsBinding() -> Binding<[String]> {
        Binding(
            get: {
                guard case .object(let dict) = value,
                      case .array(let ports) = dict["ports"] else { return [] }
                return ports.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            },
            set: { ports in
                var dict: [String: JSONValue] = [:]
                if case .object(let current) = value { dict = current }
                dict["ports"] = .array(ports.map(JSONValue.string))
                store.setValue(scope: scope, section: section, key: spec.key, value: .object(dict))
            }
        )
    }

    private func sniffDestBinding() -> Binding<Bool?> {
        Binding(
            get: {
                guard case .object(let dict) = value,
                      case .bool(let b) = dict["override-destination"] else { return nil }
                return b
            },
            set: { dest in
                var dict: [String: JSONValue] = [:]
                if case .object(let current) = value { dict = current }
                if let dest {
                    dict["override-destination"] = .bool(dest)
                } else {
                    dict.removeValue(forKey: "override-destination")
                }
                store.setValue(scope: scope, section: section, key: spec.key, value: .object(dict))
            }
        )
    }
}

/// One sniff protocol's override editor: ports + the
/// override-destination choice (inherit / on / off).
private struct SniffOverrideEditor: View {
    @Binding var ports: [String]
    @Binding var overrideDest: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("覆盖目标地址", selection: $overrideDest) {
                Text("跟随").tag(nil as Bool?)
                Text("覆盖开").tag(true as Bool?)
                Text("覆盖关").tag(false as Bool?)
            }
            .pickerStyle(.segmented)
            StringListEditor(items: $ports, placeholder: "端口或范围，如 8080")
        }
    }
}

// MARK: - Override list / map editor pages

private struct OverrideStringListPage: View {
    let title: String
    @Binding var items: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: nil) {
                    StringListEditor(items: $items, placeholder: "添加一项")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: title)
    }
}

private struct OverrideNumberListPage: View {
    let title: String
    @Binding var items: [Int]
    @State private var newItem = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: nil) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, number in
                        if index > 0 { UpstreamDivider(leading: 16) }
                        HStack {
                            Text("\(number)")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                items.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    }
                    if !items.isEmpty { UpstreamDivider(leading: 16) }
                    HStack {
                        TextField("数字", text: $newItem)
                            .keyboardType(.numberPad)
                        Button("添加") {
                            guard let number = Int(newItem.trimmingCharacters(in: .whitespaces)) else {
                                error = "请输入数字"
                                return
                            }
                            guard !items.contains(number) else {
                                error = "这个数字已存在"
                                return
                            }
                            error = nil
                            items.append(number)
                            newItem = ""
                        }
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    if let error {
                        UpstreamDivider(leading: 16)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: title)
    }
}

private struct OverrideStringMapPage: View {
    let title: String
    @Binding var items: [String: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                UpstreamCardSection(header: nil) {
                    KeyValueListEditor(items: $items, keyPlaceholder: "匹配", valuePlaceholder: "服务器")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: title)
    }
}
