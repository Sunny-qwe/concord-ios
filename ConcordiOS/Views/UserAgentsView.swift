import SwiftUI

// MARK: - User-Agent list (FlClash: lib/views/config/user_agents.dart)
// The saved list (SettingsStore.userAgents) plus the current
// selection (SettingsStore.globalUa; "" = default, the first row).
// The selected UA is written to general-overlay.json as
// "global-ua" by SettingsStore.save() and merged into config.apply's
// overlay; an empty selection means the core's built-in default.
// Add / edit / delete / reorder (long-press drag in edit mode,
// or the ↑↓ buttons — List edit mode is the reliable one here).
//
// v0.2.159: upstream UserAgentsView is a header row 默认 + UA rows
// (check + edit button, menu 编辑/删除) + add button. The list
// keeps its List structure (reorder/delete need it); only
// fonts/nav-bar change. The 应用（重新应用配置） button is KEPT:
// upstream selection only saves, but re-applying here makes a new
// UA take effect on the running core at once instead of at the
// next VPN start.

struct UserAgentsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    /// Single source for the add/edit input dialog (upstream
    /// showCommonDialog → InputDialog, a centred dialog, not a
    /// sheet): the value being edited (nil = add) + the text.
    @State private var uaDraft: UserAgentDraft?
    @State private var showDeleteConfirm: String?

    private struct UserAgentDraft: Identifiable {
        let id = UUID()
        var original: String?
        var text: String
    }

    private var selected: String { settingsStore.globalUa }

    /// Validation for the dialog's text (same rules as the old
    /// sheet): non-empty, no duplicates.
    private var uaValidationError: String? {
        guard let draft = uaDraft else { return nil }
        let value = draft.text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "User-Agent 不能为空" }
        if value != draft.original && settingsStore.userAgents.contains(value) { return "这个 User-Agent 已存在" }
        return nil
    }

    private func saveUserAgent() {
        guard let draft = uaDraft else { return }
        let value = draft.text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if let original = draft.original {
            if let index = settingsStore.userAgents.firstIndex(of: original) {
                settingsStore.userAgents[index] = value
            }
            if selected == original {
                settingsStore.globalUa = value
            }
        } else {
            settingsStore.userAgents.append(value)
        }
        settingsStore.save()
        uaDraft = nil
    }

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
                    showDeleteConfirm = nil
                    uaDraft = UserAgentDraft(original: nil, text: "")
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
        // v0.2.165 (D): no EditButton (upstream user_agents.dart
        // has no bar button besides +). Reorder / delete do not
        // depend on it any more: editMode is always on, so the
        // drag handles + delete affordance stay; edit / delete are
        // also on every row's … menu (upstream: row check + edit).
        .environment(\.editMode, .constant(.active))
        .contentMargins(.top, 16)
        .contentMargins(.bottom, ConcordTheme.pushedPageClearance)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: "User-Agent")
        .concordNavBarBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                UpstreamBarButton(systemName: "plus.circle", label: "添加 User-Agent") {
                    showDeleteConfirm = nil
                    uaDraft = UserAgentDraft(original: nil, text: "")
                }
            }
        }
        // Add / edit is a centred input dialog (upstream
        // showCommonDialog → InputDialog), not a sheet.
        .alert(uaDraft?.original == nil ? LocalizedStringKey("添加 User-Agent") : LocalizedStringKey("编辑 User-Agent"), isPresented: Binding(
            get: { uaDraft != nil },
            set: { if !$0 { uaDraft = nil } }
        )) {
            TextField("User-Agent", text: Binding(
                get: { uaDraft?.text ?? "" },
                set: { uaDraft?.text = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button("保存") { saveUserAgent() }
                .disabled(uaValidationError != nil)
            Button("取消", role: .cancel) { uaDraft = nil }
        } message: {
            if let error = uaValidationError {
                Text(error)
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
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !value.isEmpty {
                Menu {
                    Button("编辑") {
                        showDeleteConfirm = nil
                        uaDraft = UserAgentDraft(original: value, text: value)
                    }
                    Button("删除", role: .destructive) {
                        uaDraft = nil
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
