import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scripts (FlClash: lib/views/config/scripts.dart)
//
// Upstream's standalone script library, reached from Advanced
// config -> 脚本 (and from profile 扩展 -> 前往配置脚本): list,
// URL update, reorder, editor, import from scratch / URL / file.
// Each script is a row (id, label, optional source URL,
// last-update time) plus a `<id>.js` content file in the App
// Group (MitmScriptStore: registry scripts.json + files, the
// same split as upstream's database row + `<id>.js` file in
// <home>/scripts). A script is a `main(config)` transform: it
// runs against the parsed config and returns the new config
// object (ExtendConfigView script mode evaluates it with
// JavaScriptCore — the iOS equivalent of upstream's Rust
// evaluateScript).
//
// Row layout follows upstream: title (1 line, ellipsis) +
// 远程/本地 subtitle, trailing last-update time (a spinner while
// a sync is in flight). The row menu is an ellipsis button —
// the iOS idiom for upstream's long-press context menu — with
// upstream's exact items: 编辑 / 链接 / 同步 (remote only) /
// 删除. The store also keeps a content-hash copy of each script
// in the core's resources directory so MITM modules that already
// reference a standalone script keep working; that copy is
// plumbing, not page UI, and this page no longer advertises it.

struct ScriptsView: View {
    @StateObject private var scriptStore = MitmScriptStore()

    @State private var editingScript: MitmScript?
    @State private var showNewEditor = false
    @State private var showImportURLDialog = false
    @State private var importURLText = ""
    @State private var showFileImporter = false
    @State private var editURLScript: MitmScript?
    @State private var editURLText = ""
    @State private var deleteScript: MitmScript?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            statusSection
            scriptsSection
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .contentMargins(.top, 16)
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "脚本")
        .toolbar {
            toolbarContent
        }
        // Upstream scripts.dart:259: editing a script pushes
        // EditorPage — a full page push, not a sheet.
        .navigationDestination(item: $editingScript) { script in
            ScriptEditorView(script: script, pushed: true)
                .environmentObject(scriptStore)
        }
        // Upstream scripts.dart:259: a new script is the same
        // EditorPage push.
        .navigationDestination(isPresented: $showNewEditor) {
            ScriptEditorView(script: nil, pushed: true)
                .environmentObject(scriptStore)
        }
        // Upstream scripts.dart:293: URL import is an input
        // dialog (dialogs.showUrlInput), not a sheet.
        .alert("通过URL导入", isPresented: $showImportURLDialog) {
            TextField("脚本链接（https://…/*.js）", text: $importURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("导入") {
                Task { await importScriptFromURL() }
            }
        } message: {
            Text("下载后以链接的文件名命名；之后点「同步」可重新下载。")
        }
        // Upstream scripts.dart:160-175: editing a remote
        // script's URL is an input dialog; saving a new URL
        // syncs from it at once (MitmScriptStore.setURL).
        .alert("链接", isPresented: Binding(
            get: { editURLScript != nil },
            set: { if !$0 { editURLScript = nil } }
        ), presenting: editURLScript) { script in
            TextField("脚本链接（https://…/*.js）", text: $editURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { editURLScript = nil }
            Button("保存") {
                let url = editURLText
                editURLScript = nil
                Task { await scriptStore.setURL(script, url: url) }
            }
        } message: { _ in
            Text("改链接后会立即从新链接重新下载。清空则只清除链接，不再同步。")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.sourceCode, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importFile(result)
        }
        .alert("删除脚本", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { deleteScript = nil }
            Button("删除", role: .destructive) {
                if let script = deleteScript {
                    deleteScript = nil
                    scriptStore.delete(script)
                }
            }
        } message: {
            Text("删除“\(deleteScript?.label ?? "")”？它的文件和核心资源副本都会删掉，已引用它的模块行会失效。")
        }
    }

    /// Operation feedback (save / sync / delete results and
    /// errors), shown inline — the store's established pattern.
    @ViewBuilder
    private var statusSection: some View {
        if scriptStore.statusMessage != nil || scriptStore.lastError != nil {
            Section {
                if let message = scriptStore.statusMessage {
                    Text(message).font(.caption2).foregroundStyle(.green)
                }
                if let error = scriptStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    /// The list, split out so the type-checker solves it on its
    /// own: the whole body as one expression timed out (v0.2.85
    /// CI runs #238–239).
    private var scriptsSection: some View {
        Section(header: Text("脚本（\(scriptStore.scripts.count)）").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
            if scriptStore.scripts.isEmpty {
                Text("还没有脚本。点右上角 + 新建一个，或从链接、文件导入。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(scriptStore.scripts) { script in
                ScriptRow(
                    script: script,
                    isUpdating: scriptStore.updatingIds.contains(script.id),
                    onEdit: { editingScript = script },
                    onUpdate: { Task { await scriptStore.update(script) } },
                    onEditURL: {
                        editURLText = script.url ?? ""
                        editURLScript = script
                    },
                    onDelete: {
                        deleteScript = script
                        showDeleteConfirm = true
                    }
                )
            }
            .onMove { source, destination in
                scriptStore.move(from: source, to: destination)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            UpstreamBarButtonMenu(systemName: "plus.circle", label: "添加脚本") {
                Button("从零开始") { showNewEditor = true }
                Button("通过URL导入") {
                    importURLText = ""
                    showImportURLDialog = true
                }
                Button("通过文件导入") { showFileImporter = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            EditButton()
        }
    }

    /// Imports one script from a URL (the URL-import dialog's
    /// action). Upstream scripts.dart:293-314: the label is the
    /// URL's file stem, made unique.
    private func importScriptFromURL() async {
        let urlString = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            scriptStore.lastError = "不是有效的 http(s) 链接"
            return
        }
        do {
            let data = try await mitmDownloadValidated(from: url)
            guard let content = String(data: data, encoding: .utf8) else {
                scriptStore.lastError = "下载的内容不是 UTF-8 文本"
                return
            }
            let stem = url.lastPathComponent.isEmpty
                ? "脚本" : url.deletingPathExtension().lastPathComponent
            await scriptStore.create(
                label: scriptStore.uniqueLabel(stem),
                url: urlString, content: content)
        } catch {
            scriptStore.lastError = "下载失败：\(error.localizedDescription)"
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else {
            scriptStore.lastError = "未选择文件"
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            scriptStore.lastError = "无法读取该文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            scriptStore.lastError = "文件不是 UTF-8 文本"
            return
        }
        let label = scriptStore.uniqueLabel(url.deletingPathExtension().lastPathComponent)
        Task { await scriptStore.create(label: label, url: nil, content: content) }
    }
}

// MARK: - One script row

private struct ScriptRow: View {
    let script: MitmScript
    let isUpdating: Bool
    let onEdit: () -> Void
    let onUpdate: () -> Void
    let onEditURL: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.label)
                        .font(.body)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                    Text(script.isRemote ? "远程" : "本地")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if isUpdating {
                ProgressView()
            } else {
                Text(ConcordRelativeTime.string(since: script.lastUpdateTime))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button("编辑", action: onEdit)
                if script.isRemote {
                    Button("链接", action: onEditURL)
                    Button("同步", action: onUpdate)
                }
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Editor (new blank / edit existing)

private struct ScriptEditorView: View {
    let script: MitmScript?
    /// Upstream pushes EditorPage: when true the editor renders
    /// as a pushed page in the caller's stack (no own
    /// NavigationStack, no 取消 button); when false it is the old
    /// sheet with its own stack and 取消 button.
    let pushed: Bool

    @EnvironmentObject private var scriptStore: MitmScriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var text: String
    /// Values at load time, for the unsaved-changes guard
    /// (upstream scripts.dart _handleEditorPop).
    @State private var originalLabel = ""
    @State private var originalText = ""
    /// Empty-title save prompts for a name (upstream
    /// scripts.dart _showNameDialog).
    @State private var showNameDialog = false
    @State private var nameDialogText = ""
    @State private var nameDialogError: String?
    @State private var showUnsavedConfirm = false

    init(script: MitmScript?, pushed: Bool = false) {
        self.script = script
        self.pushed = pushed
        _label = State(initialValue: script?.label ?? "")
        _text = State(initialValue: "")
    }

    private var isDirty: Bool {
        label != originalLabel || text != originalText
    }

    var body: some View {
        if pushed {
            editorContent
        } else {
            NavigationStack {
                editorContent
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("取消") { dismiss() }
                        }
                    }
            }
        }
    }

    /// The editor page itself, shared by the sheet and pushed forms.
    private var editorContent: some View {
        List {
                Section {
                    TextField("脚本名", text: $label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(header: Text("脚本内容").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    TextEditor(text: $text)
                        .frame(minHeight: 420)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("脚本以 main(config) 的形式运行，返回改写后的配置。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("保存") {
                        saveAndDismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || scriptStore.isBusy)
                    if let error = scriptStore.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, pushed ? 40 : 0)
            .background(ConcordTheme.pageBackground)
            .navigationTitle(pushed ? "" : (script?.label ?? "新建脚本"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if pushed {
                    // v0.2.159: the upstream circular icon-only back
                    // button (same custom-drawn "<" on a 44pt card
                    // circle as UpstreamBackButton, no shadow), but
                    // with this editor's unsaved-changes guard:
                    // upstream _handleEditorPop asks before
                    // discarding, so the plain dismiss in
                    // UpstreamBackButton would lose the guard — the
                    // button is restyled, not removed.
                    ToolbarItem(placement: .navigationBarLeading) {
                        HStack(spacing: 16) {
                            Button {
                                if isDirty {
                                    showUnsavedConfirm = true
                                } else {
                                    dismiss()
                                }
                            } label: {
                                // Same custom-drawn "<" as
                                // UpstreamBackButton (no shadow), with
                                // this editor's unsaved-changes guard.
                                Path { path in
                                    path.move(to: CGPoint(x: 8, y: 0))
                                    path.addLine(to: CGPoint(x: 0, y: 7.5))
                                    path.addLine(to: CGPoint(x: 8, y: 15))
                                }
                                .stroke(Color(.label), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                .frame(width: 8, height: 15)
                                .frame(width: 44, height: 44)
                                .background(ConcordTheme.cardBackground, in: Circle())
                            }
                            .buttonStyle(.plain)
                            Text(script?.label ?? "新建脚本")
                                .font(.headline)
                                .foregroundStyle(Color(.label))
                        }
                    }
                }
            }
            .confirmationDialog("保存更改？", isPresented: $showUnsavedConfirm) {
                Button("保存") {
                    Task {
                        if await save() { dismiss() }
                    }
                }
                Button("放弃更改", role: .destructive) { dismiss() }
                Button("取消", role: .cancel) {}
            }
            .alert("保存脚本", isPresented: $showNameDialog) {
                TextField("请输入脚本名称", text: $nameDialogText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("保存") {
                    confirmNameDialog()
                }
            } message: {
                Text(nameDialogError ?? "给这个脚本起个名字。")
            }
            .task {
                if let script {
                    text = scriptStore.content(of: script) ?? ""
                } else {
                    text = MitmScriptStore.template
                }
                originalLabel = label
                originalText = text
            }
        }

    /// Save entry point for the 保存 button: an empty title
    /// prompts for a name first (upstream _showNameDialog);
    /// otherwise save and pop on success.
    private func saveAndDismiss() {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameDialogText = ""
            nameDialogError = nil
            showNameDialog = true
            return
        }
        Task {
            if await save() { dismiss() }
        }
    }

    /// The name dialog's 保存: validate like upstream
    /// _validateName (non-empty, unique) and re-prompt on
    /// failure; on success adopt the name and save.
    private func confirmNameDialog() {
        let name = nameDialogText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            nameDialogError = "名字不能为空"
            DispatchQueue.main.async { showNameDialog = true }
            return
        }
        if scriptStore.hasLabel(name, except: script) {
            nameDialogError = "已存在同名脚本"
            DispatchQueue.main.async { showNameDialog = true }
            return
        }
        label = name
        Task {
            if await save() { dismiss() }
        }
    }

    /// Persist the editor state. For an existing script the
    /// rename goes first, then the renamed row is saved: saving
    /// the old row would undo the rename. Returns false when
    /// the store reports an error (shown inline, page stays).
    private func save() async -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if let script {
            if name != script.label {
                scriptStore.rename(script, label: name)
                guard scriptStore.lastError == nil,
                      let updated = scriptStore.scripts.first(where: { $0.id == script.id }) else { return false }
                await scriptStore.save(updated, content: text)
            } else {
                await scriptStore.save(script, content: text)
            }
        } else {
            await scriptStore.create(label: name, url: nil, content: text)
        }
        return scriptStore.lastError == nil
    }
}
