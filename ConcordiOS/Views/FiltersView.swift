import SwiftUI

// MARK: - Filters (FlClash: Tools -> 进阶配置 -> 过滤器)
// Per-group proxy filters from the active profile
// (profile.extractActiveProfileFilters). Editing a filter rewrites
// it in the active profile's YAML and records the override, so a
// later subscription update re-applies it (see ProfileStore).
// The filter is validated LOCALLY (regex syntax) before saving —
// no core round-trip, so editing works with the VPN off (config
// B19; FlClash's filters.dart has no core-validation step
// either). The core still validates on the next apply if it is
// available.

struct FiltersView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var proxyStore = CustomProxyStore()
    @State private var filters: [(group: String, filter: String)] = []
    @State private var loadError: String?
    @State private var editingGroup: String?
    @State private var editingFilter = ""
    @State private var message: String?

    var body: some View {
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
        .font(.footnote.weight(.semibold))
        .navigationTitle("过滤器")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
