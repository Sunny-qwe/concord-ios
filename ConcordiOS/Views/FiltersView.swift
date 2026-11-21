import SwiftUI

// MARK: - Filters (FlClash: Tools -> 进阶配置 -> 过滤器)
//
// Two features share this page, kept on separate tabs:
// 1. 全局过滤器 — upstream FiltersView (config/filters.dart):
//    the GLOBAL named-filter list (app settings): label + regex
//    pairs, add/edit (label uniqueness + regex validated, core
//    checkFilters when reachable, local NSRegularExpression
//    otherwise), delete (multi-select), drag reorder, search by
//    label/regex, empty state. These named filters are the presets
//    offered in group-member pickers (custom/members.dart).
// 2. 代理组过滤器 — ours-only: per-group `filter:` regexes in the
//    active profile's YAML (alert-based edit, local regex
//    validation, override recording so updates re-apply it).
//    Upstream has no page of its own for this; group filters live
//    in the group editor (groups.dart filter/exclude-filter).

/// One global named filter (FlClash models Filter: label + regex).
struct NamedFilter: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var regex: String

    init(id: String = UUID().uuidString, label: String = "", regex: String = "") {
        self.id = id
        self.label = label
        self.regex = regex
    }
}

/// The global named-filter list, persisted in the App Group
/// (named-filters.json). The custom group editor reads it for its
/// filter presets (see CustomGroupFormView).
final class NamedFilterStore: ObservableObject {
    static let shared = NamedFilterStore()
    @Published var filters: [NamedFilter] = []

    private var fileURL: URL? {
        ConfigStore.sharedFileURL(name: "named-filters.json")
    }

    init() { load() }

    func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([NamedFilter].self, from: data) else { return }
        filters = decoded
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(filters) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ filter: NamedFilter) {
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        save()
    }

    func delete(_ ids: Set<String>) {
        filters.removeAll { ids.contains($0.id) }
        save()
    }
}

private enum FiltersTab: String, CaseIterable {
    case named = "全局过滤器"
    case perGroup = "代理组过滤器"
}

struct FiltersView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var ruleStore: RuleStore
    @StateObject private var proxyStore = CustomProxyStore()
    @ObservedObject private var namedStore = NamedFilterStore.shared
    @State private var tab: FiltersTab = .named
    @State private var filters: [(group: String, filter: String)] = []
    @State private var loadError: String?
    @State private var editingGroup: String?
    @State private var editingFilter = ""
    @State private var message: String?
    // Named-filter editing state.
    @State private var editingNamed: NamedFilter?
    @State private var namedSearch = ""
    @State private var selectedNamed: Set<String> = []
    @State private var showNamedDeleteConfirm = false

    private var visibleNamed: [NamedFilter] {
        guard !namedSearch.isEmpty else { return namedStore.filters }
        return namedStore.filters.filter {
            $0.label.localizedCaseInsensitiveContains(namedSearch)
                || $0.regex.localizedCaseInsensitiveContains(namedSearch)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("过滤器", selection: $tab) {
                ForEach(FiltersTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if tab == .named {
                namedFiltersList
            } else {
                perGroupFiltersList
            }
        }
        .font(.footnote.weight(.semibold))
        .navigationTitle("过滤器")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $namedSearch, prompt: "搜索名称或正则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if tab == .named {
                    if selectedNamed.isEmpty {
                        Button { editingNamed = NamedFilter() } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加过滤器")
                    } else {
                        Button(role: .destructive) { showNamedDeleteConfirm = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("删除所选")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if tab == .named && !selectedNamed.isEmpty {
                    Button("取消") { selectedNamed.removeAll() }
                }
            }
        }
        .task { await load() }
        .sheet(item: $editingNamed) { filter in
            NamedFilterFormView(filter: filter, reservedLabels: Set(namedStore.filters.map { $0.label }).subtracting([filter.label])) { saved in
                namedStore.upsert(saved)
            }
        }
        .alert("编辑过滤器", isPresented: Binding(
            get: { editingGroup != nil },
            set: { if !$0 { editingGroup = nil } }
        )) {
            TextField("正则表达式", text: $editingFilter)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("保存") { saveFilter() }
            Button("取消", role: .cancel) {}
        } message: {
            if let group = editingGroup {
                Text("代理组 \(group) 的过滤器（正则，匹配节点名）。")
            }
        }
        .alert("删除所选的 \(selectedNamed.count) 个过滤器？", isPresented: $showNamedDeleteConfirm) {
            Button("删除", role: .destructive) {
                namedStore.delete(selectedNamed)
                selectedNamed.removeAll()
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Global named filters (FlClash config/filters.dart)

    private var namedFiltersList: some View {
        List {
            Section {
                Text("全局命名过滤器：名称 + 正则表达式。在自定义订阅的分组编辑器里，这些过滤器会作为预设出现，一点就能把正则填进分组的 filter。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if namedStore.filters.isEmpty {
                Section {
                    ContentUnavailableView(
                        "暂无过滤器",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("点右上角的 + 添加一个命名过滤器")
                    )
                }
            } else {
                Section("全局过滤器（\(namedStore.filters.count) 个）") {
                    if namedSearch.isEmpty {
                        ForEach(namedStore.filters) { filter in
                            namedFilterRow(filter)
                        }
                        .onDelete { offsets in
                            namedStore.filters.remove(atOffsets: offsets)
                            namedStore.save()
                        }
                        .onMove { from, to in
                            namedStore.filters.move(fromOffsets: from, toOffset: to)
                            namedStore.save()
                        }
                    } else {
                        if visibleNamed.isEmpty {
                            Text("没有匹配的过滤器")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleNamed) { filter in
                            namedFilterRow(filter)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                namedStore.delete([visibleNamed[index].id])
                            }
                        }
                    }
                }
            }
        }
    }

    private func namedFilterRow(_ filter: NamedFilter) -> some View {
        Button {
            if !selectedNamed.isEmpty {
                if selectedNamed.contains(filter.id) { selectedNamed.remove(filter.id) } else { selectedNamed.insert(filter.id) }
            } else {
                editingNamed = filter
            }
        } label: {
            HStack(spacing: 8) {
                if !selectedNamed.isEmpty {
                    Image(systemName: selectedNamed.contains(filter.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedNamed.contains(filter.id) ? ConcordTheme.accent : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(filter.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(filter.regex)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            if selectedNamed.contains(filter.id) { selectedNamed.remove(filter.id) } else { selectedNamed.insert(filter.id) }
        }
    }

    // MARK: - Per-group filters (ours-only, unchanged behaviour)

    private var perGroupFiltersList: some View {
        List {
            Section {
                Text("过滤器决定一个代理组里出现哪些节点（正则表达式，匹配节点名）。改动会写入当前配置并保存为覆盖项，订阅更新后仍保留。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if filters.isEmpty {
                Section {
                    Text(loadError ?? "当前配置里没有带过滤器的代理组。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("代理组过滤器") {
                    ForEach(filters, id: \.group) { item in
                        Button {
                            editingGroup = item.group
                            editingFilter = item.filter
                        } label: {
                            HStack {
                                Text(item.group)
                                Spacer()
                                Text(item.filter)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
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
    }

    private func load() async {
        switch await profileStore.extractActiveProfileFilters() {
        case .success(let pairs):
            filters = pairs
            loadError = nil
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func saveFilter() {
        guard let group = editingGroup else { return }
        let filter = editingFilter.trimmingCharacters(in: .whitespaces)
        // B19: validate locally (regex syntax) — no core needed.
        // An empty filter clears the group's filter; anything else
        // must compile as a regular expression. The core still
        // validates on the next apply when it is reachable.
        if !filter.isEmpty {
            do {
                _ = try NSRegularExpression(pattern: filter)
            } catch {
                message = "过滤器无效（正则表达式错误）：\(error.localizedDescription)"
                return
            }
        }
        Task {
            // Record the override, then rewrite the active file.
            proxyStore.filterOverrides[group] = filter
            proxyStore.save()
            guard var text = profileStore.activeProfileYAML() else {
                message = "没有可编辑的当前配置"
                return
            }
            text = CustomProxyStore.bakeFilterOverrides(proxyStore.filterOverrides, into: text)
            message = await profileStore.saveActiveProfileYAML(text)
            await load()
            editingGroup = nil
        }
    }
}

// MARK: - Named-filter form (FlClash _FilterForm)

/// Add/edit one named filter. Label must be unique (reservedLabels
/// excludes the label being edited); the regex is validated through
/// the core's checkFilters when reachable (RuleStore.validateFilters)
/// and locally otherwise — never saved invalid.
private struct NamedFilterFormView: View {
    @State private var filter: NamedFilter
    let reservedLabels: Set<String>
    var onSave: (NamedFilter) -> Void
    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isChecking = false

    init(filter: NamedFilter, reservedLabels: Set<String>, onSave: @escaping (NamedFilter) -> Void) {
        _filter = State(initialValue: filter)
        self.reservedLabels = reservedLabels
        self.onSave = onSave
    }

    private var isNew: Bool { filter.label.isEmpty && filter.regex.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("过滤器") {
                    TextField("名称（唯一）", text: $filter.label)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("正则表达式", text: $filter.regex)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("名称在列表里唯一；正则匹配节点名，例如 (?i)港|hk。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle(isNew ? "添加过滤器" : "编辑过滤器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .disabled(isChecking || filter.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter.regex.isEmpty)
                }
            }
        }
    }

    private func save() async {
        let label = filter.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { errorMessage = "请填写名称"; return }
        guard !reservedLabels.contains(label) else { errorMessage = "名称「\(label)」已被使用"; return }
        // Core-backed check (FlClash checkFilters) when the core is
        // reachable; local NSRegularExpression otherwise.
        isChecking = true
        defer { isChecking = false }
        await ruleStore.validateFilters([filter.regex])
        if ruleStore.lastError != nil {
            // Core unreachable (filterIssues may be stale from an
            // earlier check) — fall back to local validation.
            do {
                _ = try NSRegularExpression(pattern: filter.regex)
            } catch {
                errorMessage = "正则表达式无效：\(error.localizedDescription)"
                return
            }
        } else if !ruleStore.filterIssues.isEmpty {
            errorMessage = ruleStore.filterIssues.map { $0.message }.joined(separator: "\n")
            return
        }
        var saved = filter
        saved.label = label
        onSave(saved)
        dismiss()
    }
}
