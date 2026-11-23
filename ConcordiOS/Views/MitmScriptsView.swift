import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - MITM scripts (FlClash: lib/views/config/scripts.dart)
//
// FlClash's standalone script library: list, URL update, reorder,
// editor, import from scratch / URL / file. Each script is a file
// the core can run once a module's [Script] section names it (the
// page offers the ready-to-paste `generic` script line); "运行"
// calls mitm.runScript by the script's label, which the core
// answers once an enabled module references it.

struct MitmScriptsView: View {
    @StateObject private var scriptStore = MitmScriptStore()
    @EnvironmentObject private var client: ConcordClient

    @State private var editingScript: MitmScript?
    @State private var showNewEditor = false
    @State private var showImportURLDialog = false
    @State private var importURLText = ""
    @State private var showFileImporter = false
    @State private var urlScript: MitmScript?
    @State private var renameText = ""
    @State private var deleteScript: MitmScript?
    @State private var showDeleteConfirm = false
    @State private var runResult: JSONValue?
    @State private var runMessage: String?
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                Text("独立脚本库：脚本文件保存在核心资源目录。核心只运行已被模块 [Script] 段引用的脚本——点「复制核心脚本行」粘贴进模块即可引用，引用后点「运行」按名字运行（mitm.runScript）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let message = scriptStore.statusMessage {
                    Text(message).font(.caption2).foregroundStyle(.green)
                }
                if let error = scriptStore.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
                if isRunning {
                    ProgressView()
                }
                if let message = runMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let result = runResult {
                    JSONValueView(value: result)
                        .frame(minHeight: 60)
                }
            }

            Section("脚本（\(scriptStore.scripts.count)）") {
                if scriptStore.scripts.isEmpty {
                    Text("还没有脚本。点右上角 + 新建一个，或从链接、文件导入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(scriptStore.scripts) { script in
                    MitmScriptRow(
                        script: script,
                        isUpdating: scriptStore.updatingIds.contains(script.id),
                        onEdit: { editingScript = script },
                        onUpdate: { Task { await scriptStore.update(script) } },
                        onRun: { Task { await run(script) } },
                        onCopyLine: {
                            if let line = scriptStore.coreScriptLine(for: script) {
                                UIPasteboard.general.string = line
                                runMessage = "已复制核心脚本行，可粘贴进模块的 [Script] 段"
                            }
                        },
                        onEditURL: {
                            renameText = script.label
                            urlScript = script
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

            Section("核心资源目录的脚本文件（只读）") {
                let files = scriptStore.resourceFiles()
                if files.isEmpty {
                    Text("资源目录里还没有 .js 文件。模块下载的脚本和这里保存的脚本都会出现在这里。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    HStack {
                        Text(file.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text("\(ConcordFormat.bytes(Int64(file.size))) · \(ConcordRelativeTime.string(since: file.modified))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("这些文件属于模块或本页的脚本，在「MITM 模块」里管理；删模块时会连同清理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("MITM 脚本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("从空白新建") { showNewEditor = true }
                    Button("从链接导入") {
                        importURLText = ""
                        showImportURLDialog = true
                    }
                    Button("从文件导入") { showFileImporter = true }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        // Upstream scripts.dart:259: editing a script pushes
        // EditorPage — a full page push, not a sheet.
        .navigationDestination(item: $editingScript) { script in
            MitmScriptEditorView(script: script, pushed: true)
                .environmentObject(scriptStore)
        }
        // Upstream scripts.dart:259: a new script is the same
        // EditorPage push.
        .navigationDestination(isPresented: $showNewEditor) {
            MitmScriptEditorView(script: nil, pushed: true)
                .environmentObject(scriptStore)
        }
        // Upstream scripts.dart:160,293: URL import is an input
        // dialog (dialogs.showUrlInput), not a sheet.
        .alert("从链接导入", isPresented: $showImportURLDialog) {
            TextField("脚本链接（https://…/*.js）", text: $importURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("导入") {
                Task { await importScriptFromURL() }
            }
        } message: {
            Text("下载后以链接的文件名命名；之后点「从链接更新」可重新下载。")
        }
        // Upstream scripts.dart:193: no dedicated edit-URL UI —
        // the closest is _showNameDialog → showCommonDialog
        // (InputDialog), a rename dialog.
        .alert("重命名脚本", isPresented: Binding(
            get: { urlScript != nil },
            set: { if !$0 { urlScript = nil } }
        ), presenting: urlScript) { script in
            TextField("脚本名", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { urlScript = nil }
            Button("重命名") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    scriptStore.rename(script, label: name)
                }
                urlScript = nil
            }
        } message: {
            Text("输入新的脚本名。")
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

    private func run(_ script: MitmScript) async {
        guard client.mode == .live else {
            runMessage = "示例模式：脚本不会真的运行"
            runResult = nil
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            runResult = ConcordSampleData.jsonValue(try await client.mitmRunScript(name: script.label).result)
            runMessage = "脚本“\(script.label)”已运行"
        } catch {
            runResult = nil
            runMessage = "运行失败：\(error.localizedDescription)（核心只运行已被模块 [Script] 段引用的脚本，先复制核心脚本行进模块）"
        }
    }

    /// Imports one script from a URL (the URL-import dialog's
    /// action; was MitmScriptImportURLView's Import button).
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

private struct MitmScriptRow: View {
    let script: MitmScript
    let isUpdating: Bool
    let onEdit: () -> Void
    let onUpdate: () -> Void
    let onRun: () -> Void
    let onCopyLine: () -> Void
    let onEditURL: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.label)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.label))
                    Text("\(script.isRemote ? "远程" : "本地") · 更新于 \(ConcordRelativeTime.string(since: script.lastUpdateTime))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if isUpdating {
                ProgressView()
            } else {
                Menu {
                    Button("编辑", action: onEdit)
                    Button("运行", action: onRun)
                    Button("复制核心脚本行", action: onCopyLine)
                    if script.isRemote {
                        Button("从链接更新", action: onUpdate)
                        Button("重命名", action: onEditURL)
                    } else {
                        Button("重命名", action: onEditURL)
                    }
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Editor (new blank / edit existing)

private struct MitmScriptEditorView: View {
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

    init(script: MitmScript?, pushed: Bool = false) {
        self.script = script
        self.pushed = pushed
        _label = State(initialValue: script?.label ?? "")
        _text = State(initialValue: "")
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
                Section("脚本内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 420)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("脚本以 main(config) 的形式运行，返回改写后的配置或结果。保存后会同步一份到核心资源目录。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("保存") {
                        Task {
                            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let script {
                                // Rename first, then save the renamed
                                // row: saving the old row would undo
                                // the rename.
                                if !name.isEmpty, name != script.label {
                                    scriptStore.rename(script, label: name)
                                    guard scriptStore.lastError == nil,
                                          let updated = scriptStore.scripts.first(where: { $0.id == script.id }) else { return }
                                    await scriptStore.save(updated, content: text)
                                } else {
                                    await scriptStore.save(script, content: text)
                                }
                            } else {
                                await scriptStore.create(
                                    label: name.isEmpty ? "新脚本" : name,
                                    url: nil, content: text)
                            }
                            if scriptStore.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || scriptStore.isBusy)
                    if let error = scriptStore.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle(script?.label ?? "新建脚本")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if let script {
                    text = scriptStore.content(of: script) ?? ""
                } else {
                    text = MitmScriptStore.template
                }
            }
        }
    }

