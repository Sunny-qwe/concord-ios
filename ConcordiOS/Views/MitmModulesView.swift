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
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var urlText = ""
    @State private var showPasteImport = false
    @State private var showBlankEditor = false
    @State private var showFileImporter = false
    @State private var consentModule: MitmModule?
    @State private var showConsentAlert = false
    @State private var deleteModule: MitmModule?
    @State private var showDeleteConfirm = false
    /// Live per-module status from the core (mitm.moduleStatus),
    /// keyed by module name. Refreshed on appear, on pull-to-refresh,
    /// when the VPN comes up, and after a re-fetch.
    @State private var statusByName: [String: ConcordMitmModuleStatus] = [:]
    /// Why no status could be fetched yet (gate not met: sample mode,
    /// VPN off, MITM off). Shown briefly inside an expanded row.
    @State private var statusNote: String?
    /// The last status-fetch failure, shown briefly inside an
    /// expanded row — status is advisory, never a banner.
    @State private var statusError: String?
    @State private var isLoadingStatus = false
    /// Detail page target: the row tap now expands the row in place,
    /// so detail navigation is programmatic instead of a
    /// NavigationLink inside the row.
    @State private var detailModule: MitmModule?
    /// Modules currently re-fetching their remote files.
    @State private var refetchingNames: Set<String> = []
    /// Per-module re-fetch failure, shown inline in the expanded row.
    @State private var refetchErrorByName: [String: String] = [:]

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
                        status: statusByName[module.name],
                        statusNote: statusNote,
                        statusError: statusError,
                        isLoadingStatus: isLoadingStatus,
                        isRefetching: refetchingNames.contains(module.name),
                        refetchError: refetchErrorByName[module.name],
                        onToggle: { on in toggle(module, on: on) },
                        onMoveUp: { Task { await moduleStore.moveUp(module) } },
                        onMoveDown: { Task { await moduleStore.moveDown(module) } },
                        onDelete: {
                            deleteModule = module
                            showDeleteConfirm = true
                        },
                        onAwaitingConsent: {
                            consentModule = module
                            showConsentAlert = true
                        },
                        onDismissAwaiting: {
                            Task { await moduleStore.answerConsent(module, agreed: false) }
                        },
                        onShowDetail: { detailModule = module },
                        onRefetch: { Task { await refetch(module) } },
                        onExpand: { Task { await refreshStatusIfNeeded() } }
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("MITM 模块")
        .task { await refreshStatus() }
        .refreshable { await refreshStatus() }
        .onChange(of: tunnelManager.isRunning) { _, running in
            if running {
                Task { await refreshStatus() }
            } else {
                // The status belongs to the running core — once the
                // VPN stops it is stale, so drop it and say so.
                statusByName = [:]
                statusError = nil
                statusNote = "启动 VPN 后可以看到模块实时状态"
            }
        }
        .onChange(of: settingsStore.mitmEnabled) { _, enabled in
            if enabled {
                Task { await refreshStatus() }
            } else {
                statusByName = [:]
                statusError = nil
                statusNote = "打开 MITM 后可以看到模块实时状态"
            }
        }
        .navigationDestination(item: $detailModule) { module in
            MitmModuleDetailView(moduleId: module.id)
        }
        .sheet(isPresented: $showPasteImport) {
            MitmModulePasteImportView(onImported: { saved in
                offerConsent(saved)
            })
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
            MitmModuleTextEditorView(
                module: nil,
                initialText: MitmModuleStore.blankTemplate(name: "新模块"),
                onSaved: { saved in offerConsent(saved) }
            )
        }
        // The consent prompt (fork `answerMitmModule`): what turning
        // the module on asks about — unreadable file, scripts,
        // skipped verification, limited clients. Cancelling records
        // the decline, so the module stops awaiting consent; the
        // "待确认" badge in its row is the same prompt, and the
        // row's × dismisses it without asking.
        .alert(listConsentTitle, isPresented: $showConsentAlert) {
            Button("取消", role: .cancel) {
                if let module = consentModule {
                    consentModule = nil
                    Task { await moduleStore.answerConsent(module, agreed: false) }
                }
            }
            Button("启用") {
                if let module = consentModule {
                    consentModule = nil
                    Task { await moduleStore.answerConsent(module, agreed: true) }
                }
            }
        } message: {
            Text(listConsentMessage)
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

    /// The prompt for the module the consent alert is asking about.
    private var listConsentTitle: String {
        consentModule.flatMap { moduleStore.consentPrompt(for: $0)?.title } ?? "启用此模块？"
    }

    private var listConsentMessage: String {
        consentModule.flatMap { moduleStore.consentPrompt(for: $0)?.message } ?? ""
    }

    /// Offers the consent prompt for a module that awaits it (fork
    /// `offerMitmModule`): fresh imports, editor saves and updates
    /// land here; anything else stays on the persistent "待确认"
    /// badge in the row and the dashboard card.
    private func offerConsent(_ module: MitmModule?) {
        guard let module, moduleStore.awaitsConsent(module) else { return }
        consentModule = module
        showConsentAlert = true
    }

    private func toggle(_ module: MitmModule, on: Bool) {
        if on, moduleStore.consentPrompt(for: module) != nil {
            // Asks about something — a script it declares, skipped
            // verification, limited clients, or a file that cannot
            // be read (7140e37): ask first instead of enabling
            // blindly.
            consentModule = module
            showConsentAlert = true
            return
        }
        Task { await moduleStore.setEnabled(module, on: on) }
    }

    /// Reads the core's per-module status (mitm.moduleStatus). The
    /// handler is gated by mitm_enabled() in the core, and the sample
    /// transport would answer with sample data — so this only calls
    /// when the client is live, the VPN is up and MITM is on.
    /// Otherwise it records an honest note for the expanded rows
    /// instead of failing loudly.
    private func refreshStatus() async {
        guard client.mode == .live else {
            statusByName = [:]
            statusError = nil
            statusNote = "示例数据模式下没有实时状态"
            return
        }
        guard tunnelManager.isRunning else {
            statusByName = [:]
            statusError = nil
            statusNote = "启动 VPN 后可以看到模块实时状态"
            return
        }
        guard settingsStore.mitmEnabled else {
            statusByName = [:]
            statusError = nil
            statusNote = "打开 MITM 后可以看到模块实时状态"
            return
        }
        statusNote = nil
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        do {
            let list = try await client.mitmModuleStatus()
            statusByName = Dictionary(
                list.modules.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            statusError = nil
        } catch {
            statusError = error.localizedDescription
        }
    }

    /// A row expanding re-reads the status only when nothing is
    /// loaded yet — expanding a row that already has status must
    /// not hit the core again.
    private func refreshStatusIfNeeded() async {
        guard statusByName.isEmpty, !isLoadingStatus else { return }
        await refreshStatus()
    }

    /// Re-fetches one module's remote files (mitm.fetchModule) and
    /// then re-reads the status, so the expanded row shows the fresh
    /// state. A failure is recorded per module and shown inline in
    /// its expanded row.
    private func refetch(_ module: MitmModule) async {
        refetchingNames.insert(module.name)
        refetchErrorByName[module.name] = nil
        defer { refetchingNames.remove(module.name) }
        do {
            try await client.mitmFetchModule(name: module.name)
            await refreshStatus()
        } catch {
            refetchErrorByName[module.name] = error.localizedDescription
        }
    }

    /// Imports every URL on its own line, skipping ones already
    /// installed (FlClash mitm_modules.dart:174-205), then offers
    /// script consent for any newly imported module that awaits it
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
    /// awaits consent asks for it immediately.
    private func offerConsentForNewModules(beforeIDs: Set<String>) {
        let fresh = moduleStore.modules.filter { !beforeIDs.contains($0.id) }
        if let awaiting = fresh.first(where: { moduleStore.awaitsConsent($0) }) {
            consentModule = awaiting
            showConsentAlert = true
        }
    }
}

// MARK: - One module row

private struct MitmModuleRow: View {
    let module: MitmModule
    /// Live status for this module from mitm.moduleStatus, matched
    /// by name; nil when the core has no entry for it.
    let status: ConcordMitmModuleStatus?
    /// Why no status could be fetched (sample mode / VPN off /
    /// MITM off); shown briefly inside the expanded row.
    let statusNote: String?
    /// The last status-fetch failure, shown briefly in the row.
    let statusError: String?
    let isLoadingStatus: Bool
    let isRefetching: Bool
    /// The last re-fetch failure for this module, shown inline.
    let refetchError: String?
    let onToggle: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    /// Tapping the "待确认" badge opens the consent prompt for
    /// this module; the × next to it declines without asking.
    let onAwaitingConsent: () -> Void
    let onDismissAwaiting: () -> Void
    /// Opens the module detail page (the row tap itself now expands
    /// the row in place instead of navigating).
    let onShowDetail: () -> Void
    /// Re-fetches this module's remote files (mitm.fetchModule).
    let onRefetch: () -> Void
    /// Called when the row expands, so the list can load the status
    /// if it has none yet.
    let onExpand: () -> Void

    @EnvironmentObject private var moduleStore: MitmModuleStore
    /// Tapping the row expands it in place to show the core's live
    /// status for this module.
    @State private var isExpanded = false

    private var content: MitmModuleContent? {
        moduleStore.parsedContent(for: module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { module.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                Button(action: toggleExpand) {
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
                            // Fork 2d31f10: the module awaits consent —
                            // off, never answered, asking about something.
                            // The state lives in the row, so the badge
                            // survives app restart. Tapping it opens the
                            // consent prompt; the × declines it.
                            if moduleStore.awaitsConsent(module) {
                                Button("待确认", action: onAwaitingConsent)
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.orange)
                                    .buttonStyle(.plain)
                                Button(action: onDismissAwaiting) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                                .accessibilityLabel("不再询问此模块")
                            }
                            if let content, !content.skipped.isEmpty {
                                Text("\(content.skipped.count) 跳过")
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.gray.opacity(0.14), in: Capsule())
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
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
            if isExpanded {
                Divider()
                    .padding(.top, 8)
                statusArea
                    .padding(.top, 8)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func toggleExpand() {
        isExpanded.toggle()
        if isExpanded { onExpand() }
    }

    /// The expanded area: the core's live status for this module,
    /// or an honest note when there is none. The re-fetch and
    /// detail actions live here too — the row tap is expansion now,
    /// so the detail page is one tap away from the expanded row.
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                statusContent(status)
            } else if isLoadingStatus {
                ProgressView()
                    .controlSize(.small)
            } else if let statusError {
                Text("拉取状态失败：\(statusError)")
                    .font(.system(size: 10)).foregroundStyle(.red)
            } else if let statusNote {
                Text(statusNote)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("暂无状态")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button(isRefetching ? "拉取中…" : "重新拉取", action: onRefetch)
                    .disabled(isRefetching)
                Button("详情", action: onShowDetail)
            }
            .font(.system(size: 11))
            if let refetchError {
                Text("重新拉取失败：\(refetchError)")
                    .font(.system(size: 10)).foregroundStyle(.red)
            }
        }
    }

    /// Enabled / in force, the problem that keeps the module out
    /// entirely, the requirement that turns it off, each remote
    /// resource's state, and the rules the core refused.
    private func statusContent(_ status: ConcordMitmModuleStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.enabled
                 ? (status.inForce ? "已启用 · 生效中" : "已启用 · 未生效")
                 : "未启用")
                .font(.system(size: 10))
                .foregroundStyle(status.inForce ? Color.green : Color.secondary)
            if let problem = status.problem {
                Text(problemText(problem))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let off = status.off {
                Text(off.reason == "requirement"
                     ? "整体不生效：前置条件不满足"
                     : "整体不生效：前置条件无法读取")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if !status.resources.isEmpty {
                Text("远程资源（\(status.resources.count)）")
                    .font(.system(size: 10)).fontWeight(.semibold)
                ForEach(Array(status.resources.enumerated()), id: \.offset) { _, resource in
                    resourceRow(resource)
                }
            }
            if !status.refusedRules.isEmpty {
                Text("被拒绝的规则（\(status.refusedRules.count)）")
                    .font(.system(size: 10)).fontWeight(.semibold)
                ForEach(Array(status.refusedRules.enumerated()), id: \.offset) { _, rule in
                    Text("第 \(rule.line) 行：\(rule.detail)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func problemText(_ problem: ConcordMitmModuleProblem) -> String {
        switch problem.reason {
        case "unreadable":
            if let detail = problem.detail, !detail.isEmpty {
                return "无法读取：\(detail)"
            }
            return "模块文件无法读取"
        case "duplicate":
            return "与另一模块重名，未生效"
        default:
            return "未生效：\(problem.reason)"
        }
    }

    private func resourceRow(_ resource: ConcordMitmModuleResourceStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(resourceKindLabel(resource.kind))
                    .font(.system(size: 10)).fontWeight(.semibold)
                Text(resourceStateLabel(resource.state))
                    .font(.system(size: 10))
                    .foregroundStyle(resourceStateColor(resource.state))
                if !resource.lines.isEmpty {
                    Text("行 \(resource.lines.map(String.init).joined(separator: "、"))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(resource.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let file = resource.file, !file.isEmpty {
                Text("已存为 \(file)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error = resource.error {
                Text("拉取失败（\(error.reason)\(error.status.map { " \($0)" } ?? "")）：\(error.detail)")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func resourceKindLabel(_ kind: String) -> String {
        switch kind {
        case "script": return "脚本"
        case "map-local": return "本地映射"
        case "jq": return "jq"
        default: return kind
        }
    }

    private func resourceStateLabel(_ state: String) -> String {
        switch state {
        case "ok": return "已就绪"
        case "fetching": return "拉取中…"
        case "failed": return "失败"
        case "missing": return "缺失"
        default: return state
        }
    }

    private func resourceStateColor(_ state: String) -> Color {
        switch state {
        case "ok": return Color.green
        case "failed", "missing": return Color.orange
        default: return Color.secondary
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
                        MitmModuleArgumentsSection(
                            module: module,
                            arguments: content.arguments,
                            onAwaitingConsent: { showConsent = true }
                        )
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
                                // FlClash mitm_modules.dart:224:
                                // consent right after an update that
                                // brings new scripts — the module now
                                // awaits consent persistently, so the
                                // prompt is offered when it does.
                                if let updated = await moduleStore.update(module),
                                   moduleStore.awaitsConsent(updated) {
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
        .font(.system(size: 13, weight: .semibold))
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
                MitmModuleTextEditorView(
                    module: module,
                    initialText: text,
                    onSaved: { saved in
                        if let saved, moduleStore.awaitsConsent(saved) {
                            showConsent = true
                        }
                    }
                )
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
        // Same consent prompt as the list (fork `answerMitmModule`).
        // Cancelling records the decline, so the module stops
        // awaiting consent.
        .alert(detailConsentTitle, isPresented: $showConsent) {
            Button("取消", role: .cancel) {
                if let module {
                    Task { await moduleStore.answerConsent(module, agreed: false) }
                }
            }
            Button("启用") {
                if let module {
                    Task { await moduleStore.answerConsent(module, agreed: true) }
                }
            }
        } message: {
            Text(detailConsentMessage)
        }
    }

    /// The prompt for this module (title / message), like the list's.
    private var detailConsentTitle: String {
        module.flatMap { moduleStore.consentPrompt(for: $0)?.title } ?? "启用此模块？"
    }

    private var detailConsentMessage: String {
        module.flatMap { moduleStore.consentPrompt(for: $0)?.message } ?? ""
    }

    /// The detail page's own enable toggle, with the same consent
    /// gate as the list row.
    private func toggleDetail(_ module: MitmModule, on: Bool) {
        if on, moduleStore.consentPrompt(for: module) != nil {
            showConsent = true
            return
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
    /// Called when saving the values turned the module off for
    /// something it never agreed to (fork `setArguments` offers
    /// the consent prompt right after); the detail view shows it.
    var onAwaitingConsent: () -> Void = {}

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
            if let error = moduleStore.lastError {
                savedMessage = error
                return
            }
            if let fresh = moduleStore.modules.first(where: { $0.id == module.id }),
               moduleStore.awaitsConsent(fresh) {
                onAwaitingConsent()
            }
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
    /// Called with the saved module after a successful import, so
    /// the list can offer the consent prompt when it awaits it.
    var onImported: ((MitmModule?) -> Void)? = nil

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
                            let imported = await moduleStore.addFromText(text, fileName: fileName.isEmpty ? nil : fileName)
                            if moduleStore.lastError == nil {
                                dismiss()
                                onImported?(imported)
                            }
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
            .font(.system(size: 13, weight: .semibold))
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
    /// Called with the saved module after a successful save, so the
    /// caller can offer the consent prompt when it awaits it.
    var onSaved: ((MitmModule?) -> Void)? = nil

    @EnvironmentObject private var moduleStore: MitmModuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(module: MitmModule?, initialText: String, onSaved: ((MitmModule?) -> Void)? = nil) {
        self.module = module
        self.initialText = initialText
        self.onSaved = onSaved
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
                            let saved: MitmModule?
                            if let module {
                                saved = await moduleStore.edit(module, text: text)
                            } else {
                                saved = await moduleStore.addFromText(text, fileName: nil)
                            }
                            if moduleStore.lastError == nil {
                                dismiss()
                                onSaved?(saved)
                            }
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
            .font(.system(size: 13, weight: .semibold))
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
