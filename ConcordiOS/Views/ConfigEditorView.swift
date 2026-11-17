import SwiftUI

// MARK: - Config editor (Profiles -> 编辑配置)
// A full-screen YAML editor for the ACTIVE profile — the mobile
// equivalent of FlClash's desktop config editor. Loads the profile's
// YAML from the App Group container, edits it as monospace text,
// and saves it back.
//
// Save flow, in order:
//   1. Local sanity check (non-empty UTF-8, looks like a Clash /
//      mihomo document) — always.
//   2. Core validation (config.validate) when the core is reachable
//      (live mode + VPN running): the text is written to a temporary
//      file in the App Group (the core reads it with a plain fs::read
//      in the extension process) and validated there. Any issue aborts
//      the save before the active config is touched.
//   3. When the VPN is stopped the core is unreachable: the page says
//      so, saves after the local check only, and the extension
//      validates again at the next VPN start.
//   4. A confirmation alert before the file is actually overwritten.
// Unsaved changes: the page keeps a draft in tmp (restored with a
// prompt if you leave and come back), and 放弃修改 asks first.

struct ConfigEditorView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var text = ""
    @State private var originalText = ""
    @State private var isLoaded = false
    @State private var loadError: String?
    @State private var validationIssues: [ConcordIssue] = []
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showSaveConfirm = false
    @State private var showDiscardConfirm = false
    @State private var showDraftAlert = false
    @State private var pendingSaveNote = ""

    private var isDirty: Bool { isLoaded && text != originalText }

    private static var draftURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("concord-editor-draft.yaml")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                ContentUnavailableView("打不开配置", systemImage: "doc.text.magnifyingglass", description: Text(loadError))
            } else if !isLoaded {
                ProgressView("正在读取配置…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorHeader
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .onChange(of: text) { _, _ in saveDraft() }
                statusArea
            }
        }
        .navigationTitle("编辑配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await validateBeforeSave() } }
                    .disabled(!isDirty || isWorking)
            }
            ToolbarItem(placement: .topBarLeading) {
                if isDirty {
                    Button("放弃修改") { showDiscardConfirm = true }
                        .disabled(isWorking)
                }
            }
        }
        .task { load() }
        .alert("保存并应用吗？", isPresented: $showSaveConfirm) {
            Button("保存") { Task { await save() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text(pendingSaveNote)
        }
        .alert("放弃未保存的修改？", isPresented: $showDiscardConfirm) {
            Button("放弃", role: .destructive) {
                text = originalText
                validationIssues = []
                message = nil
                errorMessage = nil
                try? FileManager.default.removeItem(at: Self.draftURL)
            }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("编辑器里的改动会被丢弃，恢复为磁盘上的版本。")
        }
        .alert("恢复上次未保存的修改吗？", isPresented: $showDraftAlert) {
            Button("恢复草稿") {
                if let draft = try? String(contentsOf: Self.draftURL, encoding: .utf8) {
                    text = draft
                    message = "已恢复上次未保存的草稿。"
                }
            }
            Button("丢弃草稿", role: .destructive) {
                try? FileManager.default.removeItem(at: Self.draftURL)
            }
        } message: {
            Text("上次离开编辑器时还有未保存的修改。")
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profileStore.activeProfile?.name ?? "当前配置")
                    .font(.headline)
                Spacer()
                if isDirty {
                    PillBadge(text: "未保存", tint: .orange)
                } else {
                    PillBadge(text: "已保存", tint: .green)
                }
            }
            Text(client.mode == .live
                 ? (tunnelManager.isRunning
                    ? "保存前会先用核心校验（config.validate），有问题就不会覆盖。"
                    : "VPN 未运行：保存前只能做本地检查，核心会在下次启动 VPN 时再校验一次。")
                 : "示例模式：保存只做本地检查，不会发给核心。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(ConcordTheme.cardBackground)
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isWorking {
                ProgressView("正在校验…")
            }
            if !validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("校验发现 \(validationIssues.count) 个问题，未保存：")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    ForEach(Array(validationIssues.enumerated()), id: \.offset) { _, issue in
                        Text("· \(issue.message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ConcordTheme.cardBackground)
    }

    private func load() {
        guard let yaml = profileStore.activeProfileYAML() else {
            loadError = "没有已激活的订阅，或者它的配置文件找不到了"
            return
        }
        originalText = yaml
        text = yaml
        isLoaded = true
        // A draft from a previous interrupted edit session wins a
        // prompt — it is never silently applied or discarded.
        if let draft = try? String(contentsOf: Self.draftURL, encoding: .utf8),
           draft != yaml {
            showDraftAlert = true
        }
    }

    private func saveDraft() {
        guard isLoaded else { return }
        try? text.write(to: Self.draftURL, atomically: true, encoding: .utf8)
    }

    private func validateBeforeSave() async {
        validationIssues = []
        message = nil
        errorMessage = nil
        // 1. Local sanity check, always.
        if let problem = ProfileStore.localSanityCheckText(text) {
            errorMessage = "本地检查未通过：\(problem)"
            return
        }
        // 2. Core validation when the core is reachable.
        if client.mode == .live, tunnelManager.isRunning {
            isWorking = true
            defer { isWorking = false }
            do {
                let issues = try await profileStore.validateYAMLText(text)
                if !issues.isEmpty {
                    validationIssues = issues
                    return
                }
                pendingSaveNote = "核心校验通过。保存后会立即重新应用到核心（VPN 正在运行）。"
            } catch {
                errorMessage = "核心校验失败：\(error.localizedDescription)。未保存——请稍后重试，或先停止 VPN 再用本地检查保存。"
                return
            }
        } else if client.mode == .live {
            pendingSaveNote = "VPN 未运行：只做了本地检查。保存后下次启动 VPN 时核心会再校验一次，校验失败时隧道会启动失败并报错。"
        } else {
            pendingSaveNote = "示例模式：只做了本地检查，不会发给核心。"
        }
        showSaveConfirm = true
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        let result = await profileStore.saveActiveProfileYAML(text)
        message = result
        errorMessage = nil
        originalText = text
        try? FileManager.default.removeItem(at: Self.draftURL)
    }
}
