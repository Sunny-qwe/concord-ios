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

    var body: some View {
        List {
            Section {
                Text("覆盖只对启用的项生效：没启用的项用订阅自己的值。全局覆盖对所有订阅生效，单个订阅的覆盖优先于全局。保存后点「应用覆盖」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
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
            ForEach(OverrideSection.allCases) { section in
                OverrideSectionEditor(section: section, scope: $scope)
            }
            Section("YAML 预览") {
                Text(store.yamlText(scope: scope))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "已复制" : "复制 YAML") {
                    UIPasteboard.general.string = store.yamlText(scope: scope)
                    copied = true
                }
                Text("YAML 仅供查看：App 内没有 YAML 解析器，改动请在上面的表单里做。")
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
        .navigationTitle("覆盖")
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
