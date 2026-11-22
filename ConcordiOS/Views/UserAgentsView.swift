import SwiftUI

// MARK: - User-Agent list (FlClash: lib/views/config/user_agents.dart)
// The saved list (SettingsStore.userAgents) plus the current
// selection (SettingsStore.globalUa; "" = default, the first row).
// The selected UA is written to general-overlay.json as
// "global-ua" by SettingsStore.save() and merged into config.apply's
// overlay; an empty selection means the core's built-in default.
// Add / edit / delete / reorder (long-press drag in edit mode,
// or the ↑↓ buttons — List edit mode is the reliable one here).

struct UserAgentsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var editingUA: String?
    @State private var editText = ""
    @State private var showAddSheet = false
    @State private var showDeleteConfirm: String?

    private var selected: String { settingsStore.globalUa }

    var body: some View {
        List {
            Section {
                Text("选中的 User-Agent 会作为全局 UA 发给核心（general-overlay.json 的 global-ua）。选「默认」时不发 global-ua，用核心自带的默认值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("User-Agent") {
                userAgentRow(label: "默认", value: "")
                ForEach(settingsStore.userAgents, id: \.self) { ua in
                    userAgentRow(label: ua, value: ua)
                }
                .onDelete { offsets in
                    let removed = offsets.map { settingsStore.userAgents[$0] }
                    settingsStore.userAgents.remove(atOffsets: offsets)
                    if removed.contains(selected) {
                        settingsStore.globalUa = ""
                    }
                    settingsStore.save()
                }
                .onMove { from, to in
                    settingsStore.userAgents.move(fromOffsets: from, toOffset: to)
                    settingsStore.save()
                }
            }
            Section {
                Button("添加 User-Agent") {
                    editText = ""
                    editingUA = nil
                    showAddSheet = true
                }
            }
            // FlClash user_agents.dart: changing the selection only
            // saves it; the core picks it up at the next VPN start.
            // This button re-applies the general settings to the
            // running core now, so the new UA takes effect at once.
            Section {
                Button("应用（重新应用配置）") {
                    settingsStore.save()
                    Task { await settingsStore.applyGeneralToCore() }
                }
                Text("改了 User-Agent 后点这里立即发给核心；否则等下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message = settingsStore.generalApplyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("User-Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            UserAgentEditSheet(
                title: editingUA == nil ? "添加 User-Agent" : "编辑 User-Agent",
                text: $editText,
                existing: settingsStore.userAgents,
                current: editingUA
            ) { value in
                if let editingUA {
                    if let index = settingsStore.userAgents.firstIndex(of: editingUA) {
                        settingsStore.userAgents[index] = value
                    }
                    if selected == editingUA {
                        settingsStore.globalUa = value
                    }
                } else {
                    settingsStore.userAgents.append(value)
                }
                settingsStore.save()
            }
        }
        .alert("删除这个 User-Agent？", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let ua = showDeleteConfirm {
                    settingsStore.userAgents.removeAll { $0 == ua }
                    if selected == ua {
                        settingsStore.globalUa = ""
                    }
                    settingsStore.save()
                }
                showDeleteConfirm = nil
            }
            Button("取消", role: .cancel) {
                showDeleteConfirm = nil
            }
        }
    }

    private func userAgentRow(label: String, value: String) -> some View {
        HStack {
            Button {
                settingsStore.globalUa = value
                settingsStore.save()
            } label: {
                HStack {
                    Image(systemName: selected == value ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected == value ? .blue : .secondary)
                    Text(label)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !value.isEmpty {
                Menu {
                    Button("编辑") {
                        editingUA = value
                        editText = value
                        showAddSheet = true
                    }
                    Button("删除", role: .destructive) {
                        showDeleteConfirm = value
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Add / edit sheet for one User-Agent: non-empty, no duplicates.
private struct UserAgentEditSheet: View {
    let title: String
    @Binding var text: String
    let existing: [String]
    let current: String?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var error: String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "User-Agent 不能为空" }
        if value != current && existing.contains(value) { return "这个 User-Agent 已存在" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User-Agent", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
        }
    }
}
