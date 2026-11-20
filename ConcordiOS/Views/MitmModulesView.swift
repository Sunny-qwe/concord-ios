import SwiftUI
import UniformTypeIdentifiers

// MARK: - MITM modules (FlClash: MITM modules page)
// Surge .sgmodule / Loon .plugin / Quantumult X / Stash override
// modules, parsed by MitmModuleParser and merged into the config
// the core receives (see MitmModuleStore + PacketTunnelProvider's
// mergedMitmOverlay). The user's own hostnames always come first;
// each enabled module's content follows in list order.
//
// Scripts are code the core runs: a module that declares scripts
// starts disabled and asks before it is turned on; an update that
// brings new scripts turns it off again.

struct MitmModulesView: View {
    @EnvironmentObject private var moduleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient

    @State private var urlText = ""
    @State private var showPasteImport = false
    @State private var showBlankEditor = false
    @State private var showFileImporter = false
    @State private var consentModule: MitmModule?
    @State private var showConsentAlert = false
    @State private var deleteModule: MitmModule?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section {
                Text("模块把一组规则、重写、脚本和解密域名打包在一起，整体开关、整体更新。支持 Surge 模块、Loon 插件、Quantumult X 片段和 Stash 覆写。模块内容会在下次启动 VPN 时生效；VPN 运行时改动会立即重新应用。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let message = moduleStore.applyMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let message = moduleStore.statusMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.green)
                }
                if let error = moduleStore.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }

            Section("导入模块") {
                // FlClash mitm_modules.dart:174-205: multiple URLs
                // (plus install links) in one import, skipping
                // already-installed ones.
                TextEditor(text: $urlText)
                    .frame(minHeight: 56)
                    .font(.system(.caption, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .overlay(alignment: .topLeading) {
                        if urlText.isEmpty {
                            Text("模块链接，每行一个；也支持 surge:// / loon:// 安装链接")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button("导入") {
                        Task { await importURLs() }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || moduleStore.isBusy)
                    Spacer()
                    Button("从文件导入") { showFileImporter = true }
                        .disabled(moduleStore.isBusy)
                }
                Button("粘贴模块文本导入") { showPasteImport = true }
                Button("新建空白模块") { showBlankEditor = true }
                if moduleStore.isBusy { ProgressView() }
            }

            Section("已安装的模块（\(moduleStore.modules.count)）") {
                if moduleStore.modules.isEmpty {
                    Text("还没有模块。粘贴一个 Surge / Loon / Quantumult X 模块链接导入。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                ForEach(moduleStore.modules) { module in
                    MitmModuleRow(
                        module: module,
                        onToggle: { on in toggle(module, on: on) },
                        onMoveUp: { Task { await moduleStore.moveUp(module) } },
                        onMoveDown: { Task { await moduleStore.moveDown(module) } },
                        onDelete: {
                            deleteModule = module
                            showDeleteConfirm = true
                        }
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("MITM 模块")
        .sheet(isPresented: $showPasteImport) {
            MitmModulePasteImportView()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.plainText]) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    moduleStore.lastError = "读取模块文件失败：不是 UTF-8 文本"
                    return
                }
                Task { await importFile(text: text, fileName: url.lastPathComponent) }
            case .failure(let error):
                moduleStore.lastError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showBlankEditor) {
            MitmModuleTextEditorView(module: nil, initialText: MitmModuleStore.blankTemplate(name: "新模块"))
        }
        .alert("模块包含脚本", isPresented: $showConsentAlert) {
            Button("取消", role: .cancel) { consentModule = nil }
            Button("启用") {
                if let module = consentModule {
                    consentModule = nil
                    Task { await moduleStore.setEnabled(module, on: true) }
                }
            }
        } message: {
            let count = consentModule
                .flatMap { moduleStore.parsedContent(for: $0)?.declaredScripts }
                ?? consentModule?.scripts ?? 0
            Text("“\(consentModule?.name ?? "")”声明了 \(count) 个脚本。脚本会在核心里运行，能改请求、跑定时任务。确认是自己信任的模块再启用。")
        }
        .alert("删除模块", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { deleteModule = nil }
            Button("删除", role: .destructive) {
                if let module = deleteModule {
                    deleteModule = nil
                    Task { await moduleStore.delete(module) }
                }
            }
        } message: {
            Text("删除“\(deleteModule?.name ?? "")”？它的文本和已下载的脚本都会删掉。")
        }
    }

    private func toggle(_ module: MitmModule, on: Bool) {
        if on {
            let declared = moduleStore.parsedContent(for: module)?.declaredScripts ?? module.scripts
            if module.needsScriptConsent(declaredScripts: declared) {
                consentModule = module
                showConsentAlert = true
                return
            }
        }
        Task { await moduleStore.setEnabled(module, on: on) }
    }

    /// Imports every URL on its own line, skipping ones already
    /// installed (FlClash mitm_modules.dart:174-205), then offers
    /// script consent for any newly imported script-bearing module
    /// (FlClash :206 — consent right after import, not only when
    /// the module is later enabled).
    private func importURLs() async {
        let lines = urlText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        urlText = ""
        let beforeIDs = Set(moduleStore.modules.map(\.id))
        let existingURLs = Set(moduleStore.modules.compactMap(\.url))
        var imported = 0
        for line in lines {
            guard !existingURLs.contains(line) else { continue }
            await moduleStore.addFromURL(line)
            if moduleStore.lastError == nil { imported += 1 }
        }
        if imported == 0 && moduleStore.lastError == nil {
            moduleStore.lastError = "这些链接都已导入过了"
        }
        offerConsentForNewModules(beforeIDs: beforeIDs)
    }

    private func importFile(text: String, fileName: String) async {
        let beforeIDs = Set(moduleStore.modules.map(\.id))
        await moduleStore.addFromText(text, fileName: fileName)
        offerConsentForNewModules(beforeIDs: beforeIDs)
    }

    /// FlClash offerMitmScripts: a freshly imported module that
    /// declares scripts asks for consent immediately.
    private func offerConsentForNewModules(beforeIDs: Set<String>) {
        let fresh = moduleStore.modules.filter { !beforeIDs.contains($0.id) }
        if let scripted = fresh.first(where: {
            (moduleStore.parsedContent(for: $0)?.declaredScripts ?? $0.scripts) > 0
        }) {
            consentModule = scripted
            showConsentAlert = true
        }
    }
}

// MARK: - One module row

private struct MitmModuleRow: View {
    let module: MitmModule
    let onToggle: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var moduleStore: MitmModuleStore

    private var content: MitmModuleContent? {
        moduleStore.parsedContent(for: module)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { module.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            NavigationLink {
                MitmModuleDetailView(moduleId: module.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(module.name)
                            .font(.system(size: 13))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(.label))
                        if module.url != nil {
                            Text("链接")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                        }
                        if let content, content.declaredScripts > 0 {
                            Text("\(content.declaredScripts) 脚本")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        if let content, !content.skipped.isEmpty {
                            Text("\(content.skipped.count) 跳过")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.gray.opacity(0.14), in: Capsule())
                        }
                    }
                    if !module.description.isEmpty {
                        Text(module.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("更新于 \(ConcordRelativeTime.string(since: module.lastUpdateTime))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            VStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
                }
                .disabled(moduleStore.modules.first?.id == module.id)
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                }
                .disabled(moduleStore.modules.last?.id == module.id)
            }
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - Detail view

struct MitmModuleDetailView: View {
    let moduleId: String

    @EnvironmentObject private var moduleStore: MitmModuleStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var showConsent = false
    @State private var runMessage: String?
    @State private var runResult: JSONValue?
    @State private var runningScript: String?
    @State private var validateMessage: String?
    @State private var validateIssues: [String: [ConcordMitmIssue]]?
    @State private var isValidating = false
    @State private var coreContent: MitmModuleContent?

    private var module: MitmModule? {
        moduleStore.modules.first { $0.id == moduleId }
    }

    private var content: MitmModuleContent? {
        module.flatMap { moduleStore.parsedContent(for: $0) }
    }

    /// The content shown: the core's parse when the tunnel is
    /// running (mitm.readModule), the Swift parser's otherwise.
    private var shownContent: MitmModuleContent? {
        coreContent ?? content
    }

    var body: some View {
        List {
            if let module {
                Section {
                    // FlClash mitm_modules.dart detail build: the
                    // enabled toggle is the first section.
                    Toggle("启用模块", isOn: Binding(
                        get: { module.enabled },
                        set: { on in toggleDetail(module, on: on) }
                    ))
                    Text(module.description.isEmpty ? "（无描述）" : module.description)
                        .font(.system(size: 13))
                    LabeledContent("来源", value: module.url ?? "本地")
                    LabeledContent("上次更新", value: ConcordRelativeTime.string(since: module.lastUpdateTime))
                    if let tip = module.systemTip {
                        Text(tip).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    if let message = moduleStore.applyMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                if let content = shownContent {
                    Section("解析出的内容") {
                        if content.coreParsed {
                            coreNote(content: content)
                        }
                        countRow("解密域名", content.insertedHostname.count + content.hostname.count)
                        countRow("URL 重写", content.urlRewrite.count)
                        countRow("头重写", content.headerRewrite.count)
                        countRow("正文重写", content.bodyRewrite.count)
                        countRow("本地映射", content.mapLocal.count)
                        countRow("请求体模拟", content.requestBodyMock.count)
                        countRow("跳过验证域名", content.skipVerifyHostname.count)
                        countRow("客户端来源", content.clientSourceAddress.count)
                        countRow("脚本", content.script.count)
                        countRow("规则", content.rules.count)
                        countRow("待下载资源", content.resourceUrls.count)
                        if !content.skipped.isEmpty {
                            NavigationLink("跳过的行（\(content.skipped.count)）") {
                                MitmModuleSkippedView(skipped: content.skipped)
                            }
                        }
                    }

                    if !content.arguments.isEmpty {
                        MitmModuleArgumentsSection(module: module, arguments: content.arguments)
                    }

                    // FlClash mitm_modules.dart:55-76: run one script
                    // line when the module is enabled and MITM is on.
                    if !content.script.isEmpty {
                        Section("脚本（mitm.runScript）") {
                            ForEach(content.script, id: \.self) { line in
                                let name = Self.scriptName(of: line)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(name.isEmpty ? line : name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Button(runningScript == name ? "运行中…" : "运行") {
                                        Task { await runScriptLine(line) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(runningScript != nil
                                              || !module.enabled
                                              || !settingsStore.mitmEnabled)
                                }
                            }
                            if !module.enabled || !settingsStore.mitmEnabled {
                                Text("先启用模块并打开 MITM，才能运行脚本。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            if let runMessage {
                                Text(runMessage)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            if let runResult {
                                JSONValueView(value: runResult)
                                    .frame(minHeight: 60)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("模块文本丢失，请重新导入。")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }

                Section("操作") {
                    if module.url != nil {
                        Button("更新（重新下载）") {
                            Task {
                                await moduleStore.update(module)
                                // FlClash mitm_modules.dart:224:
                                // consent right after an update that
                                // brings new scripts.
                                if let updated = moduleStore.modules.first(where: { $0.id == module.id }),
                                   !updated.enabled,
                                   (moduleStore.parsedContent(for: updated)?.declaredScripts ?? updated.scripts) > updated.scripts {
                                    showConsent = true
                                }
                            }
                        }
                        .disabled(moduleStore.isBusy)
                    }
                    Button("编辑原文") { showEditor = true }
                    if client.mode == .live && tunnelManager.isRunning {
                        Button("校验合并后的 MITM 配置") {
                            Task { await validate() }
                        }
                        .disabled(isValidating)
                    }
                    if isValidating { ProgressView() }
                    if let message = validateMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let issues = validateIssues, !issues.isEmpty {
                        ForEach(issues.keys.sorted(), id: \.self) { list in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list).font(.system(size: 10)).fontWeight(.semibold)
                                ForEach(issues[list] ?? [], id: \.index) { issue in
                                    Text("第 \(issue.index + 1) 行：\(issue.message)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Button("删除模块", role: .destructive) { showDeleteConfirm = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle(module?.name ?? "模块")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: moduleId) {
            coreContent = nil
            if let module, client.mode == .live, tunnelManager.isRunning {
                coreContent = await moduleStore.coreParsedContent(for: module)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let module, let text = moduleStore.text(of: module) {
                MitmModuleTextEditorView(module: module, initialText: text)
            }
        }
        .alert("删除模块", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let module {
                    Task { await moduleStore.delete(module) }
                }
            }
        } message: {
            Text("删除“\(module?.name ?? "")”？它的文本和已下载的脚本都会删掉。")
        }
        .alert("模块包含脚本", isPresented: $showConsent) {
            Button("取消", role: .cancel) {}
            Button("启用") {
                if let module {
                    Task { await moduleStore.setEnabled(module, on: true) }
                }
            }
        } message: {
            let count = module
                .flatMap { moduleStore.parsedContent(for: $0)?.declaredScripts }
                ?? module?.scripts ?? 0
            Text("“\(module?.name ?? "")”声明了 \(count) 个脚本。脚本会在核心里运行，能改请求、跑定时任务。确认是自己信任的模块再启用。")
        }
    }

    /// The detail page's own enable toggle, with the same script
    /// consent gate as the list row.
    private func toggleDetail(_ module: MitmModule, on: Bool) {
        if on {
            let declared = moduleStore.parsedContent(for: module)?.declaredScripts ?? module.scripts
            if module.needsScriptConsent(declaredScripts: declared) {
                showConsent = true
                return
            }
        }
        Task { await moduleStore.setEnabled(module, on: on) }
    }

    /// A script line's label: the name before the first "=".
    static func scriptName(of line: String) -> String {
        line.split(separator: "=", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) ?? line
    }

    /// Runs one module script line by name (mitm.runScript).
    private func runScriptLine(_ line: String) async {
        let name = Self.scriptName(of: line)
        guard !name.isEmpty else {
            runMessage = "这行没有脚本名，无法运行"
            return
        }
        runningScript = name
        defer { runningScript = nil }
        do {
            runResult = try await client.mitmRunScript(name: name).result
            runMessage = "脚本 \(name) 已运行"
        } catch {
            runResult = nil
            runMessage = "运行失败：\(error.localizedDescription)"
        }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        LabeledContent(title, value: "\(count)")
    }

    /// The core's report for this module (mitm.readModule): what
    /// format it read, whether the module takes effect as a whole,
    /// and the lines it does not take. A short note, not a redesign.
    private func coreNote(content: MitmModuleContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("核心已解析（\(content.coreFormat ?? "?")）")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let off = content.coreOffReason {
                Text("该模块整体不生效：\(off == "requirement" ? "前置条件不满足" : "前置条件无法读取")")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if content.coreAsksConsent {
                Text("该模块会改动 DNS / hosts / 路由等你未设置的项")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if content.coreIssueCount > 0 {
                Text("核心有 \(content.coreIssueCount) 行无法读取（见下方校验）")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Array(content.coreIgnored.prefix(10)), id: \.self) { line in
                Text(line).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if content.coreIgnored.count > 10 {
                Text("等 \(content.coreIgnored.count) 行").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func validate() async {
        isValidating = true
        defer { isValidating = false }
        do {
            let config = await moduleStore.mergedConfigLive(userMitm: settingsStore.mitmConfig)
            let result = try await client.mitmValidate(config: config)
            validateIssues = result.issues
            let total = result.issues.values.reduce(0) { $0 + $1.count }
            validateMessage = total == 0 ? "校验通过：核心能读懂合并后的全部 MITM 行" : "校验发现 \(total) 个问题（见下）"
        } catch {
            validateIssues = nil
            validateMessage = "校验失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Arguments editor

private struct MitmModuleArgumentsSection: View {
    let module: MitmModule
    let arguments: [MitmModuleArgument]

    @EnvironmentObject private var moduleStore: MitmModuleStore
    @State private var values: [String: String] = [:]
    @State private var suppressNextSave = false
    @State private var savedMessage: String?

    var body: some View {
        Section("参数") {
            ForEach(arguments, id: \.name) { argument in
                VStack(alignment: .leading, spacing: 4) {
                    Text(argument.title)
                        .font(.system(size: 13))
                        .fontWeight(.semibold)
                    if let description = argument.description, !description.isEmpty {
                        Text(description).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    switch argument.type {
                    case .input:
                        TextField("默认：\(argument.defaultValue)", text: binding(for: argument))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { saveArguments() }
                    case .select:
                        Picker(argument.title, selection: binding(for: argument)) {
                            ForEach(argument.options, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    case .toggle:
                        Toggle(argument.title, isOn: Binding(
                            get: { (values[argument.name] ?? argument.defaultValue) == "true" },
                            set: { values[argument.name] = $0 ? "true" : "false" }
                        ))
                    }
                }
            }
            // FlClash mitm_modules.dart:570-595: arguments save on
            // each change — no Save button. Discrete controls
            // (toggle / select) save immediately; text input saves
            // on submit, so typing does not re-parse per keystroke.
            if let savedMessage {
                Text(savedMessage).font(.system(size: 10)).foregroundStyle(.green)
            }
            Text("参数会填进模块的每一行（Surge 的 {{{参数}}}、Loon 的 ${参数}、Stash 的 ${args.参数}）。改参数后需要资源的行会重新下载。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            var initial: [String: String] = [:]
            for argument in arguments {
                initial[argument.name] = module.arguments[argument.name] ?? argument.defaultValue
            }
            suppressNextSave = true
            values = initial
        }
        .onChange(of: values) { _, _ in
            if suppressNextSave {
                suppressNextSave = false
                return
            }
            saveArguments()
        }
    }

    private func saveArguments() {
        Task {
            await moduleStore.setArguments(module, values: values)
            savedMessage = "参数已保存"
        }
    }

    private func binding(for argument: MitmModuleArgument) -> Binding<String> {
        Binding(
            get: { values[argument.name] ?? argument.defaultValue },
            set: { values[argument.name] = $0 }
        )
    }
}

// MARK: - Skipped lines

struct MitmModuleSkippedView: View {
    let skipped: [MitmModuleSkip]

    var body: some View {
        List {
            Section {
                Text("这些行 FlClash 也带不过来：原因写在每行下面。改模块原文可以去掉它们。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, skip in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skip.line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("\(skip.section) · \(skip.reason.label)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("跳过的行")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Paste import

private struct MitmModulePasteImportView: View {
    @EnvironmentObject private var moduleStore: MitmModuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fileName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("名字（可选，默认从内容里读）", text: $fileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("模块文本") {
                    TextEditor(text: $text)
                        .frame(minHeight: 320)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("导入") {
                        Task {
                            await moduleStore.addFromText(text, fileName: fileName.isEmpty ? nil : fileName)
                            if moduleStore.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || moduleStore.isBusy)
                    if let error = moduleStore.lastError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("粘贴模块文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Text editor (new blank / edit existing)

private struct MitmModuleTextEditorView: View {
    let module: MitmModule?
    let initialText: String

    @EnvironmentObject private var moduleStore: MitmModuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(module: MitmModule?, initialText: String) {
        self.module = module
        self.initialText = initialText
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 420)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("支持 Surge、Loon、Quantumult X 和 Stash 覆写语法。保存后会重新解析、重新下载资源；带新脚本的模块会先暂停。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("保存") {
                        Task {
                            if let module {
                                await moduleStore.edit(module, text: text)
                            } else {
                                await moduleStore.addFromText(text, fileName: nil)
                            }
                            if moduleStore.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || moduleStore.isBusy)
                    if let error = moduleStore.lastError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle(module?.name ?? "新建模块")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
