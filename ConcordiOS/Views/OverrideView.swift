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

struct OverrideView: View {
    @ObservedObject private var store = OverrideStore.shared
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var scope: String? = nil
    @State private var copied = false
    /// YAML at page entry, for the apply-on-leave check (FlClash
    /// edits update the target live; ours applies when leaving
    /// with changes, or on 应用覆盖）.
    @State private var baselineYAML: String?
    /// YAML quick-edit draft, error and saved flag (v0.2.55).
    @State private var yamlDraft = ""
    @State private var yamlEditError: String?
    @State private var yamlEditSaved = false

    init(scope: String? = nil) {
        _scope = State(initialValue: scope)
    }

    var body: some View {
        List {
            Section {
                Text("覆盖只对启用的项生效：没启用的项用订阅自己的值。全局覆盖对所有订阅生效，单个订阅的覆盖优先于全局。改动在离开本页时自动应用（VPN 运行时立即生效，否则下次启动 VPN 时生效），也可以点「应用覆盖」立即应用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("作用范围") {
                Picker("作用范围", selection: $scope) {
                    Text("全局（全部订阅）").tag(nil as String?)
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString as String?)
                    }
                }
                .pickerStyle(.menu)
            }
            // One page per section (FlClash DnsView / NtpView /
            // SnifferView / TunView + general overrides, each its
            // own OverrideView with its own title and app-bar add
            // button). Tapping a row pushes that section's editor.
            Section("覆盖分组") {
                ForEach(OverrideSection.allCases) { section in
                    NavigationLink {
                        OverrideSectionPage(section: section, scope: scope)
                    } label: {
                        HStack {
                            Text(section.label)
                            Spacer()
                            Text("\(store.state(scope: scope, section: section).count) 项已启用")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("YAML 预览") {
                Text(store.yamlText(scope: scope))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "已复制" : "复制 YAML") {
                    UIPasteboard.general.string = store.yamlText(scope: scope)
                    copied = true
                }
                Text("也可以在下面直接编辑 YAML（解析校验通过后才保存）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("YAML 快速编辑") {
                TextEditor(text: $yamlDraft)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 200)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("校验并保存") {
                    saveYAMLQuickEdit()
                }
                .disabled(yamlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let yamlEditError {
                    Text(yamlEditError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if yamlEditSaved {
                    Text("已保存，离开本页时应用（或点「应用覆盖」立即应用）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("只接受 general、dns、tun、sniffer、ntp 五个分组和已知的覆盖项；未知项或类型不对会报错并保留原文本。test-url 不在这里编辑（它只保存在 App 内用作测速地址兜底）。切换作用范围会丢弃未保存的编辑。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("应用覆盖") {
                    Task { await store.applyOverrides() }
                }
                if let message = store.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("覆盖")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            baselineYAML = store.yamlText(scope: scope)
            if yamlDraft.isEmpty {
                yamlDraft = store.yamlText(scope: scope)
            }
        }
        .onChange(of: scope) { _, newScope in
            baselineYAML = store.yamlText(scope: newScope)
            yamlDraft = store.yamlText(scope: newScope)
            yamlEditError = nil
            yamlEditSaved = false
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

    // MARK: - YAML 快速编辑（v0.2.55）

    /// 解析并校验编辑框里的 YAML；只有全部合法才替换当前作用范围的
    /// 覆盖状态，否则显示精确的中文错误并保留原文本和旧状态。
    private func saveYAMLQuickEdit() {
        do {
            let values = try validateOverrideYAML(yamlDraft, scope: scope)
            store.replaceScope(scope: scope, values: values)
            yamlEditError = nil
            yamlEditSaved = true
            yamlDraft = store.yamlText(scope: scope)
        } catch {
            yamlEditError = error.localizedDescription
            yamlEditSaved = false
        }
    }

    /// 把 YAML 文本解析成 scope 的完整覆盖状态（section -> key -> value）。
    /// test-url 是客户端专用的测速地址兜底，预览里不显示，保存时原样保留。
    private func validateOverrideYAML(_ text: String, scope: String?) throws -> [String: [String: JSONValue]] {
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
        if let testURL = store.testURL(scope: scope) {
            var general = out["general"] ?? [:]
            general["test-url"] = .string(testURL)
            out["general"] = general
        }
        return out
    }

    /// 把一个分组的嵌套映射展平成点分键（fallback-filter.geoip、
    /// sniff.HTTP），并按该分组的 key spec 逐项校验。stringMap
    /// （nameserver-policy）和 sniff 协议对象整体校验，不再展开。
    private func flattenOverrideKeys(section: OverrideSection, dict: [String: JSONValue], prefix: String, into out: inout [String: JSONValue]) throws {
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
    private func validateOverrideValue(_ value: JSONValue, spec: OverrideKeySpec, key: String) throws -> JSONValue {
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
        List {
            OverrideSectionEditor(section: section, scope: $editableScope)
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(section.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - One section's override editor (shared by OverrideView
// and TunOverrideView)

struct OverrideSectionEditor: View {
    let section: OverrideSection
    @Binding var scope: String?
    @ObservedObject private var store = OverrideStore.shared
    @State private var showAddSheet = false

    private var enabledKeys: [String] {
        store.state(scope: scope, section: section).keys.sorted()
    }

    private var remainingSpecs: [OverrideKeySpec] {
        let enabled = Set(enabledKeys)
        return OverrideStore.specs(for: section).filter { !enabled.contains($0.key) }
    }

    var body: some View {
        Section(section.label) {
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
            .font(.footnote.weight(.semibold))
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
        List {
            Section {
                StringListEditor(items: $items, placeholder: "添加一项")
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverrideNumberListPage: View {
    let title: String
    @Binding var items: [Int]
    @State private var newItem = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.self) { number in
                    Text("\(number)")
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                }
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
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverrideStringMapPage: View {
    let title: String
    @Binding var items: [String: String]

    var body: some View {
        List {
            Section {
                KeyValueListEditor(items: $items, keyPlaceholder: "匹配", valuePlaceholder: "服务器")
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
