import SwiftUI
import UniformTypeIdentifiers

/// Upstream String.webUri (FlClash common/string.dart:13-22):
/// http/https/ftp with a host. The URL-input dialog's validator
/// (showUrlInput: empty → "值不能为空", not a URL → "值必须为URL").
private func isMitmModuleURL(_ text: String) -> Bool {
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "ftp"].contains(scheme),
          let host = url.host, !host.isEmpty else { return false }
    return true
}

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
    /// v0.2.85 (upstream mitm_modules.dart:160,189): no import
    /// sheet — URL import is an input dialog, file import is the
    /// system file picker; blank module is a page push (EditorPage).
    /// v0.2.137: the paste-import sheet is gone too (upstream has
    /// URL / file / editor only).
    @State private var showImportURLDialog = false
    @State private var showImportFilePicker = false
    @State private var showBlankEditorPage = false
    @State private var consentModule: MitmModule?
    @State private var showConsentAlert = false
    @State private var deleteModule: MitmModule?
    @State private var showDeleteConfirm = false
    /// Live per-module status from the core (mitm.moduleStatus),
    /// keyed by module name. Refreshed on appear, on pull-to-refresh
    /// and when the VPN comes up.
    @State private var statusByName: [String: ConcordMitmModuleStatus] = [:]
    /// The last status-fetch failure, shown briefly inside an
    /// expanded row — status is advisory, never a banner.
    @State private var statusError: String?
    @State private var isLoadingStatus = false
    /// Detail page target: the row tap now expands the row in place,
    /// so detail navigation is programmatic instead of a
    /// NavigationLink inside the row.
    @State private var detailModule: MitmModule?
    /// MuYu's restart tip (showMitmRestartTip): a module was
    /// switched while the VPN runs with MITM on — the change is
    /// re-applied live, but restarting the tunnel is the sure path.
    /// Dismissed with ×, or by restarting.
    @State private var showRestartTip = false
    @State private var isRestartingVpn = false
    /// The confirm dialog for a module operation that failed
    /// (upstream safeRun silence:false): title = module name,
    /// content = the failure. The core-down case is the core tip
    /// sentence ("核心未运行，请在核心启动后重试"); anything else is
    /// the store's lastError. Ticked by the store's
    /// coreUnavailableCount, so add/edit/update failures from the
    /// editor sheet — which has no list display slot —
    /// still surface here.
    @State private var listErrorTitle = ""
    @State private var listErrorMessage = ""
    @State private var showListErrorAlert = false
    /// The row menu's URL editor (upstream _editModuleUrl): the
    /// module being moved and its new URL text.
    @State private var urlEditModule: MitmModule?
    @State private var urlEditText = ""
    @State private var urlEditError: String?
    @State private var showUrlEditDialog = false
    /// The row menu's 编辑 target for a local module (upstream
    /// openMitmModuleEditor): a different type from MitmModule so
    /// its navigationDestination(item:) does not clash with the
    /// detail page's (two destinations for the same type conflict).
    @State private var editTarget: EditTarget?

    /// A row-menu "编辑" target (see editTarget).
    private struct EditTarget: Identifiable, Hashable {
        let module: MitmModule
        var id: String { module.id }
    }

    var body: some View {
        List {
            restartTipSection
            if moduleStore.modules.isEmpty {
                Text("暂无模块")
                    .font(.body)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            ForEach(moduleStore.modules) { module in
                moduleRow(for: module)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.pushedPageClearance)
        .contentMargins(.top, 40)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: "模块")
        .concordNavBarBackground()
        .toolbar {
            modulesToolbar
        }
        .task { await refreshStatus() }
        .refreshable { await refreshStatus() }
        .onChange(of: tunnelManager.isRunning) { _, running in
            if running {
                Task { await refreshStatus() }
            } else {
                // The status belongs to the running core — once the
                // VPN stops it is stale, so drop it (the expanded
                // row falls back to "暂无状态").
                statusByName = [:]
                statusError = nil
            }
        }
        .onChange(of: settingsStore.mitmEnabled) { _, enabled in
            if enabled {
                Task { await refreshStatus() }
            } else {
                statusByName = [:]
                statusError = nil
            }
        }
        .navigationDestination(item: $detailModule) { module in
            MitmModuleDetailView(moduleId: module.id)
        }
        // Upstream openMitmModuleEditor pushes EditorPage
        // (module_editor.dart:48) — the row menu's 编辑 for a local
        // module, a full page push, not a sheet. The text file can
        // be missing: that renders an error page, never a blank
        // sheet (see the detail page's editor destination).
        .navigationDestination(item: $editTarget) { target in
            if let text = moduleStore.text(of: target.module) {
                MitmModuleTextEditorView(
                    module: target.module,
                    initialText: text,
                    onSaved: { saved in offerConsent(saved) },
                    pushed: true
                )
            } else {
                List {
                    Section {
                        Text("模块文本丢失，请重新导入。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .contentMargins(.top, 40)
                .scrollContentBackground(.hidden)
                .background(ConcordTheme.pageBackground)
                .upstreamNavBar(title: target.module.name)
                .concordNavBarBackground()
            }
        }
        // Upstream mitm_modules.dart:160: URL import is an input
        // dialog (dialogs.showUrlInput), not a sheet.
        .alert("从链接导入模块", isPresented: $showImportURLDialog) {
            TextField("模块链接，每行一个", text: $urlText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("导入") {
                Task { await importURLs() }
            }
        } message: {
            Text("每行一个模块链接，也支持 surge:// / loon:// 安装链接。")
        }
        // Upstream _editModuleUrl (mitm_modules.dart:147): the
        // module's subscription URL is edited in a URL-input dialog
        // (dialogs.showUrlInput, title "URL").
        .alert("URL", isPresented: $showUrlEditDialog) {
            TextField("模块链接", text: $urlEditText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                urlEditModule = nil
                urlEditError = nil
            }
            Button("保存") {
                Task { await saveUrlEdit() }
            }
        } message: {
            Text(urlEditError ?? "输入新的订阅链接。")
        }
        // Upstream mitm_modules.dart:189: file import is the
        // system file picker.
        .fileImporter(isPresented: $showImportFilePicker, allowedContentTypes: [UTType.plainText]) { result in
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
        // Upstream openMitmModuleEditor(module: null) pushes
        // EditorPage (module_editor.dart:48) — a full page push,
        // not a sheet.
        .navigationDestination(isPresented: $showBlankEditorPage) {
            MitmModuleTextEditorView(
                module: nil,
                initialText: MitmModuleStore.blankTemplate(name: "新模块"),
                onSaved: { saved in offerConsent(saved) },
                pushed: true
            )
        }
        // The consent prompt (fork `answerMitmModule`): what turning
        // the module on asks about — unreadable file, scripts,
        // skipped verification, limited clients. Cancelling records
        // the decline, so the module stops awaiting consent.
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
        // The confirm dialog for a failed module operation (item 7).
        .alert(listErrorTitle, isPresented: $showListErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(listErrorMessage)
        }
        .onChange(of: moduleStore.coreUnavailableCount) { _, _ in
            // A pushed detail page shows the dialog itself (its own
            // onChange); this one only fires for list-level
            // failures — imports, the row menu, the blank editor and
            // the paste sheet.
            guard detailModule == nil else { return }
            listErrorTitle = moduleStore.coreUnavailableName
            listErrorMessage = "核心未运行，请在核心启动后重试"
            showListErrorAlert = true
        }
    }

    /// The restart-tip banner (MuYu showMitmRestartTip), as its own
    /// section so the list body stays small enough to type-check
    /// (v0.2.85 CI run #241 timeout).
    @ViewBuilder
    private var restartTipSection: some View {
        if showRestartTip {
            Section {
                HStack {
                    Text("VPN 相关配置已改动，点击重启")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(isRestartingVpn ? "重启中…" : "重启 VPN") {
                        Task { await restartVpn() }
                    }
                    .font(.footnote)
                    .disabled(isRestartingVpn)
                    Button(action: { showRestartTip = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .buttonStyle(.plain)
                    .accessibilityLabel("不再提示")
                }
            }
        }
    }

    /// One module row, as a helper so the ForEach in `body` is a
    /// one-liner: the 15-param MitmModuleRow call timed out the
    /// type-checker when inlined (v0.2.85 CI run #241).
    private func moduleRow(for module: MitmModule) -> some View {
        MitmModuleRow(
            module: module,
            status: statusByName[module.name],
            statusError: statusError,
            isLoadingStatus: isLoadingStatus,
            onToggle: { on in toggle(module, on: on) },
            onMoveUp: { Task { await moduleStore.moveUp(module) } },
            onMoveDown: { Task { await moduleStore.moveDown(module) } },
            onDelete: {
                deleteModule = module
                showDeleteConfirm = true
            },
            onShowDetail: { detailModule = module },
            onExpand: { Task { await refreshStatusIfNeeded() } },
            onUpdate: { Task { await updateModule(module) } },
            onEditUrl: {
                urlEditModule = module
                urlEditText = module.url ?? ""
                urlEditError = nil
                showUrlEditDialog = true
            },
            onEdit: { editTarget = EditTarget(module: module) }
        )
    }

    /// The row menu's 更新 (upstream _updateModule): re-downloads
    /// the module, then offers the consent prompt when it awaits
    /// it. A download failure surfaces in the error dialog; the
    /// core-down case fires from the store's coreUnavailableCount
    /// onChange too — same title and message.
    private func updateModule(_ module: MitmModule) async {
        if let updated = await moduleStore.update(module) {
            offerConsent(updated)
        } else if let error = moduleStore.lastError {
            listErrorTitle = module.name
            listErrorMessage = error
            showListErrorAlert = true
        }
    }

    /// Saves the URL-edit dialog (upstream _editModuleUrl):
    /// validates like showUrlInput (empty → "值不能为空", not a URL
    /// → "值必须为URL"), returns silently when unchanged, then
    /// moves the module with changeUrl and offers the consent prompt
    /// when it awaits it. A failed check re-opens the dialog with
    /// the error as its message (upstream's dialog stays open on a
    /// validation error); the core-down case is the store event's
    /// confirm dialog instead, so the dialog just closes.
    private func saveUrlEdit() async {
        guard let module = urlEditModule else { return }
        let url = urlEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            urlEditError = "值不能为空"
            reopenUrlEditDialog()
            return
        }
        if !isMitmModuleURL(url) {
            urlEditError = "值必须为URL"
            reopenUrlEditDialog()
            return
        }
        if url == module.url {
            urlEditModule = nil
            urlEditError = nil
            return
        }
        if let updated = await moduleStore.changeUrl(module, url: url) {
            urlEditModule = nil
            urlEditError = nil
            offerConsent(updated)
        } else if let error = moduleStore.lastError {
            if error == "核心未运行，请在核心启动后重试" {
                urlEditModule = nil
                urlEditError = nil
            } else {
                // Duplicate ("模块当前已存在") or download failure:
                // back into the dialog with the error as its message.
                urlEditError = error
                reopenUrlEditDialog()
            }
        }
    }

    /// Re-presents the URL-edit dialog on the next runloop turn:
    /// setting isPresented synchronously inside the dismissing
    /// button's action is swallowed by the dismissal.
    private func reopenUrlEditDialog() {
        DispatchQueue.main.async { showUrlEditDialog = true }
    }

    @ToolbarContentBuilder
    private var modulesToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            UpstreamBarButtonMenu(systemName: "plus.circle", label: "导入模块") {
                Button("新建模块") { showBlankEditorPage = true }
                Button("通过URL导入") {
                    urlText = ""
                    showImportURLDialog = true
                }
                Button("通过文件导入") { showImportFilePicker = true }
            }
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
    /// land here; anything else is asked when the module is enabled
    /// via its toggle.
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
        Task {
            await moduleStore.setEnabled(module, on: on)
            showRestartTipIfNeeded()
        }
    }

    /// MuYu showMitmRestartTip's gate, on iOS: only when the VPN
    /// is running and MITM is on (the tip's tap restarts it).
    private func showRestartTipIfNeeded() {
        if tunnelManager.isRunning && settingsStore.mitmEnabled {
            showRestartTip = true
        }
    }

    /// Restarts the tunnel (stop, then start) and clears the tip.
    private func restartVpn() async {
        isRestartingVpn = true
        defer { isRestartingVpn = false }
        await tunnelManager.stop()
        do {
            try await tunnelManager.start()
            showRestartTip = false
        } catch {
            moduleStore.lastError = "重启 VPN 失败：\(error.localizedDescription)"
        }
    }

    /// Reads the core's per-module status (mitm.moduleStatus). The
    /// handler is gated by mitm_enabled() in the core, and the sample
    /// transport would answer with sample data — so this only calls
    /// when the client is live, the VPN is up and MITM is on.
    /// Otherwise it clears the status (the expanded row falls back
    /// to "暂无状态") instead of failing loudly.
    private func refreshStatus() async {
        guard client.mode == .live else {
            statusByName = [:]
            statusError = nil
            return
        }
        guard tunnelManager.isRunning else {
            statusByName = [:]
            statusError = nil
            return
        }
        guard settingsStore.mitmEnabled else {
            statusByName = [:]
            statusError = nil
            return
        }
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
        // Audit B41: dedup on the URL the link names, not the raw
        // line — an install link (surge://…) never equals the
        // http(s) URL the import stores, so it imported twice.
        let existingURLs = Set(moduleStore.modules.compactMap(\.url))
        var imported = 0
        for line in lines {
            let extracted = mitmModuleUrls(line).first ?? line
            guard !existingURLs.contains(extracted) else { continue }
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
    /// The last status-fetch failure, shown briefly in the row.
    let statusError: String?
    let isLoadingStatus: Bool
    let onToggle: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    /// Opens the module detail page (the row tap itself now expands
    /// the row in place instead of navigating).
    let onShowDetail: () -> Void
    /// Called when the row expands, so the list can load the status
    /// if it has none yet.
    let onExpand: () -> Void
    /// The long-press menu's 更新: re-downloads the module.
    let onUpdate: () -> Void
    /// The long-press menu's URL: edits the subscription URL.
    let onEditUrl: () -> Void
    /// The long-press menu's 编辑: opens the text editor.
    let onEdit: () -> Void

    @EnvironmentObject private var moduleStore: MitmModuleStore
    /// Tapping the row expands it in place to show the core's live
    /// status for this module.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // v0.2.68 (MuYu): collapsed row = name + "远程"/"本地"
            // subtitle + toggle on the RIGHT. Sort arrows,
            // description and update time move into the expanded
            // detail below.
            HStack(spacing: 10) {
                Button(action: toggleExpand) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(module.name)
                            .font(.body)
                            .foregroundStyle(Color(.label))
                            .lineLimit(1)
                        Text(module.url != nil ? "远程" : "本地")
                            .font(.subheadline)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { module.enabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(UpstreamToggleStyle(hidesLabel: true))
                .labelsHidden()
            }
            if isExpanded {
                Rectangle()
                    .fill(Color(.label).opacity(0.14))
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.top, 8)
                expandedDetail
                    .padding(.top, 8)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            rowContextMenu
        }
    }

    /// The long-press menu (upstream _MitmModuleRow
    /// ContextMenuRegion): remote modules 更新 / URL / 删除, local
    /// modules 编辑 / 删除.
    @ViewBuilder
    private var rowContextMenu: some View {
        if module.url != nil {
            Button("更新", action: onUpdate)
            Button("URL", action: onEditUrl)
        } else {
            Button("编辑", action: onEdit)
        }
        Button("删除", role: .destructive, action: onDelete)
    }

    /// The expanded detail: the sort arrows, the description /
    /// update time, and the core's live status (kept per the
    /// 2026-11-20 user decision).
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // v0.2.137: the badges are gone (链接 / N 脚本 /
                // 待确认 / N 跳过 — ours-only; upstream's row shows
                // only the sort arrows here). Consent is not
                // stranded: enabling via the toggle asks first, and
                // offerConsent fires after import / update / URL
                // change.
                Spacer()
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(moduleStore.modules.first?.id == module.id)
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .disabled(moduleStore.modules.last?.id == module.id)
            }
            .foregroundStyle(ConcordTheme.onSurfaceVariant)
            if !module.description.isEmpty {
                Text(module.description)
                    .font(.subheadline)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .lineLimit(2)
            }
            Text("更新于 \(ConcordRelativeTime.string(since: module.lastUpdateTime))")
                .font(.subheadline)
                .foregroundStyle(ConcordTheme.onSurfaceVariant)
            statusArea
        }
    }

    private func toggleExpand() {
        isExpanded.toggle()
        if isExpanded { onExpand() }
    }

    /// The expanded area: the core's live status for this module,
    /// or an honest note when there is none. The detail action
    /// lives here too — the row tap is expansion now, so the detail
    /// page is one tap away from the expanded row.
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                statusContent(status)
            } else if isLoadingStatus {
                ProgressView()
                    .controlSize(.small)
            } else if let statusError {
                Text("拉取状态失败：\(statusError)")
                    .font(.footnote).foregroundStyle(.red)
            } else {
                Text("暂无状态")
                    .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            HStack(spacing: 16) {
                Button("详情", action: onShowDetail)
            }
            .font(.footnote)
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
                .font(.footnote)
                .foregroundStyle(status.inForce ? Color.green : ConcordTheme.onSurfaceVariant)
            if let problem = status.problem {
                Text(problemText(problem))
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let off = status.off {
                Text(off.reason == "requirement"
                     ? "整体不生效：前置条件不满足"
                     : "整体不生效：前置条件无法读取")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !status.resources.isEmpty {
                Text("远程资源（\(status.resources.count)）")
                    .font(.footnote).fontWeight(.semibold)
                ForEach(Array(status.resources.enumerated()), id: \.offset) { _, resource in
                    resourceRow(resource)
                }
            }
            if !status.refusedRules.isEmpty {
                Text("被拒绝的规则（\(status.refusedRules.count)）")
                    .font(.footnote).fontWeight(.semibold)
                ForEach(Array(status.refusedRules.enumerated()), id: \.offset) { _, rule in
                    Text("第 \(rule.line) 行：\(rule.detail)")
                        .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                    .font(.footnote).fontWeight(.semibold)
                Text(resourceStateLabel(resource.state))
                    .font(.footnote)
                    .foregroundStyle(resourceStateColor(resource.state))
                if !resource.lines.isEmpty {
                    Text("行 \(resource.lines.map(String.init).joined(separator: "、"))")
                        .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
            }
            Text(resource.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                .lineLimit(2)
            if let file = resource.file, !file.isEmpty {
                Text("已存为 \(file)")
                    .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            if let error = resource.error {
                Text("拉取失败（\(error.reason)\(error.status.map { " \($0)" } ?? "")）：\(error.detail)")
                    .font(.footnote).foregroundStyle(.orange)
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

    @State private var showEditorPage = false
    @State private var showDeleteConfirm = false
    @State private var showConsent = false
    @State private var runMessage: String?
    @State private var runResult: JSONValue?
    @State private var runningScript: String?
    @State private var validateMessage: String?
    @State private var validateIssues: [String: [ConcordMitmIssue]]?
    @State private var isValidating = false
    @State private var coreContent: MitmModuleContent?
    /// MuYu's restart tip (see the list view): shown after the
    /// module is switched while the VPN runs with MITM on.
    @State private var showRestartTip = false
    @State private var isRestartingVpn = false
    /// Attachments (local modules only): file import + detach
    /// confirm state.
    @State private var showAttachmentImporter = false
    @State private var detachAttachment: String?
    @State private var showDetachConfirm = false
    /// The confirm dialog for a module operation that failed
    /// (upstream safeRun silence:false): title = module name,
    /// content = the failure — the core tip sentence when the core
    /// is down, the store's lastError otherwise. Ticked by the
    /// store's coreUnavailableCount, so edit (editor page),
    /// setArguments and update failures all surface here.
    @State private var detailErrorTitle = ""
    @State private var detailErrorMessage = ""
    @State private var showDetailErrorAlert = false
    /// The 来源 row's URL editor (upstream _editModuleUrl): the
    /// module being moved and its new URL text.
    @State private var urlEditModule: MitmModule?
    @State private var urlEditText = ""
    @State private var urlEditError: String?
    @State private var showUrlEditDialog = false

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
            detailRestartTipSection
            detailInfoSection
            localAttachmentsSection
            parsedContentSection
            detailActionsSection
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.pushedPageClearance)
        .contentMargins(.top, 40)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: module?.name ?? "模块")
        .concordNavBarBackground()
        .task(id: moduleId) {
            coreContent = nil
            if let module, client.mode == .live, tunnelManager.isRunning {
                coreContent = await moduleStore.coreParsedContent(for: module)
            }
        }
        // Upstream openMitmModuleEditor pushes EditorPage
        // (module_editor.dart:83) — a full page push, not a sheet.
        // The text file can be missing (text(of:) returns nil):
        // that renders an error page, never a blank sheet — the
        // old .sheet(isPresented:) body had no else, so a missing
        // text file showed an empty sheet with no way out.
        .navigationDestination(isPresented: $showEditorPage) {
            if let module, let text = moduleStore.text(of: module) {
                MitmModuleTextEditorView(
                    module: module,
                    initialText: text,
                    onSaved: { saved in
                        if let saved, moduleStore.awaitsConsent(saved) {
                            showConsent = true
                        }
                    },
                    pushed: true
                )
            } else {
                List {
                    Section {
                        Text("模块文本丢失，请重新导入。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .contentMargins(.top, 40)
                .scrollContentBackground(.hidden)
                .background(ConcordTheme.pageBackground)
                .upstreamNavBar(title: module?.name ?? "模块")
                .concordNavBarBackground()
            }
        }
        .fileImporter(isPresented: $showAttachmentImporter, allowedContentTypes: [UTType.data]) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let module, let data = try? Data(contentsOf: url) else {
                    moduleStore.lastError = "读取附件失败：不是可读文件"
                    return
                }
                Task { await moduleStore.attachFile(module, fileName: url.lastPathComponent, data: data) }
            case .failure(let error):
                moduleStore.lastError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("移除附件", isPresented: $showDetachConfirm) {
            Button("取消", role: .cancel) { detachAttachment = nil }
            Button("移除", role: .destructive) {
                if let module, let name = detachAttachment {
                    detachAttachment = nil
                    Task { await moduleStore.detachAttachment(module, name: name) }
                }
            }
        } message: {
            Text("移除附件“\(detachAttachment ?? "")”？引用它的 Map Local 行会失效。")
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
                    Task { await moduleStore.answerConsent(module, agreed: false, content: shownContent) }
                }
            }
            Button("启用") {
                if let module {
                    Task { await moduleStore.answerConsent(module, agreed: true, content: shownContent) }
                }
            }
        } message: {
            Text(detailConsentMessage)
        }
        // The confirm dialog for a failed module operation (item 7).
        .alert(detailErrorTitle, isPresented: $showDetailErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(detailErrorMessage)
        }
        .onChange(of: moduleStore.coreUnavailableCount) { _, _ in
            detailErrorTitle = moduleStore.coreUnavailableName
            detailErrorMessage = "核心未运行，请在核心启动后重试"
            showDetailErrorAlert = true
        }
        // Upstream _editModuleUrl (mitm_modules.dart:147): the
        // module's subscription URL is edited in a URL-input dialog
        // (dialogs.showUrlInput, title "URL").
        .alert("URL", isPresented: $showUrlEditDialog) {
            TextField("模块链接", text: $urlEditText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                urlEditModule = nil
                urlEditError = nil
            }
            Button("保存") {
                Task { await saveUrlEdit() }
            }
        } message: {
            Text(urlEditError ?? "输入新的订阅链接。")
        }
    }

    /// The restart-tip banner (MuYu showMitmRestartTip), as its own
    /// section so the detail body stays small enough to type-check
    /// (v0.2.86: the ~180-line detail body was already over the
    /// 150-line risk limit before Batch 2 added to it).
    @ViewBuilder
    private var detailRestartTipSection: some View {
        if showRestartTip {
            Section {
                HStack {
                    Text("VPN 相关配置已改动，点击重启")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(isRestartingVpn ? "重启中…" : "重启 VPN") {
                        Task { await restartVpn() }
                    }
                    .font(.footnote)
                    .disabled(isRestartingVpn)
                    Button(action: { showRestartTip = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    .buttonStyle(.plain)
                    .accessibilityLabel("不再提示")
                }
            }
        }
    }

    /// The info section (enabled toggle, description, source, last
    /// update), as its own section so the detail body stays small
    /// enough to type-check (see detailRestartTipSection).
    @ViewBuilder
    private var detailInfoSection: some View {
        if let module {
            // FlClash mitm_modules.dart detail build: the
            // enabled toggle is the first section, its footer
            // the about text (description + system tip).
            // Upstream toggle title is `enabled` = 已开启.
            Section {
                Toggle("已开启", isOn: Binding(
                    get: { module.enabled },
                    set: { on in toggleDetail(module, on: on) }
                ))
                .toggleStyle(UpstreamToggleStyle())
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !module.description.isEmpty {
                        Text(module.description)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                    if let tip = module.systemTip {
                        Text(tip)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let message = moduleStore.applyMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
            }
            Section("来源") {
                if let url = module.url {
                    // Upstream _sourceItems: the 来源 row opens the
                    // URL editor when the module is remote.
                    Button(action: {
                        urlEditModule = module
                        urlEditText = url
                        urlEditError = nil
                        showUrlEditDialog = true
                    }) {
                        LabeledContent("来源", value: url)
                    }
                    .buttonStyle(.plain)
                } else {
                    LabeledContent("来源", value: "本地")
                }
                LabeledContent("上次更新", value: ConcordRelativeTime.string(since: module.lastUpdateTime))
            }
        }
    }

    /// The actions section (update / edit / validate / delete), as
    /// its own section so the detail body stays small enough to
    /// type-check (see detailRestartTipSection).
    @ViewBuilder
    private var detailActionsSection: some View {
        if let module {
            Section("操作") {
                if module.url != nil {
                    Button("更新（重新下载）") {
                        Task {
                            // FlClash mitm_modules.dart:224:
                            // consent right after an update that
                            // brings new scripts — the module now
                            // awaits consent persistently, so the
                            // prompt is offered when it does.
                            if let updated = await moduleStore.update(module) {
                                if moduleStore.awaitsConsent(updated) {
                                    showConsent = true
                                }
                            } else if let error = moduleStore.lastError {
                                // A download failure surfaces here;
                                // the core-down case also ticks
                                // coreUnavailableCount, so the confirm
                                // dialog fires from its onChange too
                                // — same title and message, so the
                                // double set is harmless.
                                detailErrorTitle = module.name
                                detailErrorMessage = error
                                showDetailErrorAlert = true
                            }
                        }
                    }
                    .foregroundStyle(Color(.label))
                    .disabled(moduleStore.isBusy)
                }
                Button("编辑原文") { showEditorPage = true }
                    .foregroundStyle(Color(.label))
                if client.mode == .live && tunnelManager.isRunning {
                    Button("校验合并后的 MITM 配置") {
                        Task { await validate() }
                    }
                    .foregroundStyle(Color(.label))
                    .disabled(isValidating)
                }
                if isValidating { ProgressView() }
                if let message = validateMessage {
                    Text(message).font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
                validationIssuesSection
                Button("删除模块", role: .destructive) { showDeleteConfirm = true }
            }
        }
    }

    /// Local-file attachments (FlClash mitm_modules.dart:629-633,
    /// local modules only), as its own section so the detail body
    /// stays small enough to type-check (v0.2.85 CI run #241).
    @ViewBuilder
    private var localAttachmentsSection: some View {
        if let module, module.url == nil {
            Section("附件") {
                let attachments = moduleStore.attachments(of: module)
                if attachments.isEmpty {
                    Text("还没有本地附件。Map Local 行里 data=引用的文件可以先贴在这里，模块会用它。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
                ForEach(attachments, id: \.self) { name in
                    HStack {
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            detachAttachment = name
                            showDetachConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除附件 \(name)")
                    }
                }
                Button("添加本地文件") { showAttachmentImporter = true }
                    .foregroundStyle(Color(.label))
                Text("附件按内容命名存在核心资源目录；Map Local 行用 data=文件名引用它。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                if let error = moduleStore.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    /// The parsed content, arguments and per-line script runner, as
    /// its own section so the detail body stays small enough to
    /// type-check (v0.2.85 CI run #241). The nested `if let module`
    /// keeps the "text lost" else branch firing only when a module
    /// exists but its content is nil — exactly as before.
    @ViewBuilder
    private var parsedContentSection: some View {
        if let module {
            if let content = shownContent {
                // Upstream MitmModuleView order (mitm_modules.dart):
                // 参数 / 资源 / 网络设置 / 规则 — arguments and
                // network come before the rules lists.
                if !content.arguments.isEmpty {
                    MitmModuleArgumentsSection(
                        module: module,
                        arguments: content.arguments,
                        onAwaitingConsent: { showConsent = true }
                    )
                }

                // FlClash mitm_modules.dart:803: the network
                // changes this module asks for (from its parsed
                // content), with the upstream risk footer. A later
                // ENABLED module that replaces a change is named
                // (upstream MitmNetworkChange.replacedBy,
                // providers/mitm.dart:492 — the LAST replacer).
                if !content.network.isEmpty {
                    Section {
                        ForEach(Array(networkChanges(of: content.network).enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.title)
                                    .font(.body)
                                Text(change.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            }
                        }
                    } header: {
                        Text("网络设置")
                    } footer: {
                        Text("启用时会覆盖下列网络设置。")
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }

                Section {
                    if content.coreParsed {
                        coreNote(content: content)
                    }
                    linesRow(title: "主机名", key: "hostname", section: "mitm", lines: content.insertedHostname + content.hostname, content: content)
                    linesRow(title: "URL 重写", key: "url-rewrite", section: "url rewrite", lines: content.urlRewrite, content: content)
                    linesRow(title: "Header 重写", key: "header-rewrite", section: "header rewrite", lines: content.headerRewrite, content: content)
                    linesRow(title: "Body 重写", key: "body-rewrite", section: "body rewrite", lines: content.bodyRewrite, content: content)
                    linesRow(title: "本地映射", key: "map-local", section: "map local", lines: content.mapLocal, content: content)
                    linesRow(title: "请求体替换", key: "request-body-mock", section: "request body mock", lines: content.requestBodyMock, content: content)
                    linesRow(title: "不校验证书的主机", key: nil, section: "mitm", lines: content.skipVerifyHostname, content: content)
                    linesRow(title: "客户端地址", key: nil, section: "mitm", lines: content.clientSourceAddress, content: content)
                    linesRow(title: "脚本", key: "script", section: "script", lines: content.script, content: content)
                    linesRow(title: "分流规则", key: "rules", section: "rule", lines: content.rules, content: content, note: extendedMatchingNote(for: content))
                    linesRow(title: "待下载资源", key: nil, section: "", lines: content.resourceUrls.sorted(), content: content)
                    if !content.skipped.isEmpty {
                        NavigationLink("忽略的行（\(content.skipped.count)）") {
                            MitmModuleSkippedView(skipped: content.skipped).concordNavBarBackground()
                        }
                    }
                } header: {
                    Text("规则")
                } footer: {
                    Text("先于配置自身的规则匹配。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        }
                        if let runMessage {
                            Text(runMessage)
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Upstream mitmModuleNetworkChanges (providers/mitm.dart:492)
    /// + mitmNetworkChangeTitle / mitmNetworkChangeValue
    /// (module_editor.dart:19-55): the module's network changes as
    /// title / subtitle rows. A change is "replaced" by the LAST
    /// later ENABLED module whose network replaces it
    /// (MitmNetworkChange.replacedBy, mitm_network.dart:237).
    /// `overridesYours` is NOT computed: it needs the profile's DNS
    /// overrides mapped onto these keys, which is too risky for
    /// this batch — the footer warning covers it.
    private func networkChanges(of network: MitmModuleNetwork) -> [(title: String, subtitle: String)] {
        var rows: [(title: String, subtitle: String)] = []
        // The later ENABLED modules, in list order, with their
        // parsed networks (Swift parse — the core parse exists only
        // for the shown module).
        var later: [(name: String, network: MitmModuleNetwork)] = []
        if let module {
            var pastSelf = false
            for other in moduleStore.modules {
                if other.id == module.id { pastSelf = true; continue }
                guard pastSelf, other.enabled else { continue }
                guard let parsed = moduleStore.parsedContent(for: other), !parsed.network.isEmpty else { continue }
                later.append((name: other.name, network: parsed.network))
            }
        }
        func replacedBy(key: String, domain: String? = nil) -> String? {
            var found: String?
            for other in later {
                let replaces: Bool
                if let domain {
                    let entries = key == "nameserver-policy" ? other.network.nameserverPolicy : other.network.hosts
                    replaces = entries.contains(where: { $0.domain == domain })
                } else {
                    replaces = other.network.editOf(key)?.replace == true
                }
                if replaces { found = other.name }
            }
            return found
        }
        func subtitle(value: String, key: String, domain: String? = nil) -> String {
            if let name = replacedBy(key: key, domain: domain) {
                return "\(value)\n已被模块 \(name) 覆盖"
            }
            return value
        }
        func editValue(_ edit: MitmListEdit) -> String {
            if edit.replace {
                return "替换为 \(edit.values.joined(separator: ", "))"
            }
            var parts: [String] = []
            if !edit.before.isEmpty {
                parts.append("在前面添加 \(edit.before.joined(separator: ", "))")
            }
            if !edit.after.isEmpty {
                parts.append("添加 \(edit.after.joined(separator: ", "))")
            }
            return parts.joined(separator: "\n")
        }
        func addEdit(title: String, key: String, edit: MitmListEdit?) {
            guard let edit else { return }
            rows.append((title: title, subtitle: subtitle(value: editValue(edit), key: key)))
        }
        addEdit(title: "Nameserver", key: "dns-server", edit: network.nameserver)
        addEdit(title: "Default Nameserver", key: "default-nameserver", edit: network.defaultNameserver)
        addEdit(title: "Fake-IP过滤", key: "fake-ip-filter", edit: network.fakeIpFilter)
        for entry in network.nameserverPolicy {
            let value = "\(entry.domain) → \(entry.values.joined(separator: ", "))"
            rows.append((title: "Nameserver Policy", subtitle: subtitle(value: value, key: "nameserver-policy", domain: entry.domain)))
        }
        for entry in network.hosts {
            let value = "\(entry.domain) → \(entry.values.joined(separator: ", "))"
            rows.append((title: "Hosts", subtitle: subtitle(value: value, key: "hosts", domain: entry.domain)))
        }
        if !network.routeAddress.isEmpty {
            let value = "添加 \(network.routeAddress.joined(separator: ", "))"
            rows.append((title: "路由地址", subtitle: subtitle(value: value, key: "route-address")))
        }
        addEdit(title: "排除路由地址", key: "route-exclude-address", edit: network.routeExcludeAddress)
        addEdit(title: "排除域名", key: "bypass-domain", edit: network.bypassDomain)
        return rows
    }

    /// The merged-config validation issues (grouped by list), as its
    /// own view so the detail body stays small enough to type-check:
    /// the nested ForEach with the `Text("第 \(issue.index + 1)...")`
    /// line timed out the type-checker when inlined (v0.2.85 CI
    /// run #241).
    @ViewBuilder
    private var validationIssuesSection: some View {
        if let issues = validateIssues, !issues.isEmpty {
            ForEach(issues.keys.sorted(), id: \.self) { list in
                VStack(alignment: .leading, spacing: 2) {
                    Text(list).font(.footnote).fontWeight(.semibold)
                    ForEach(issues[list] ?? [], id: \.index) { issue in
                        Text("第 \(issue.index + 1) 行：\(issue.message)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// The prompt for this module (title / message), like the
    /// list's — but from the core's parse when the tunnel is
    /// running, so the declared-script count is the core's (audit
    /// B42; the list keeps the Swift parser's).
    private var detailConsentTitle: String {
        module.flatMap { moduleStore.consentPrompt(for: $0, content: shownContent)?.title } ?? "启用此模块？"
    }

    private var detailConsentMessage: String {
        module.flatMap { moduleStore.consentPrompt(for: $0, content: shownContent)?.message } ?? ""
    }

    /// The detail page's own enable toggle, with the same consent
    /// gate as the list row.
    private func toggleDetail(_ module: MitmModule, on: Bool) {
        if on, moduleStore.consentPrompt(for: module, content: shownContent) != nil {
            showConsent = true
            return
        }
        Task {
            await moduleStore.setEnabled(module, on: on)
            showRestartTipIfNeeded()
        }
    }

    /// Saves the URL-edit dialog (upstream _editModuleUrl) — the
    /// list's saveUrlEdit, but the consent prompt here is the
    /// detail's own showConsent flag.
    private func saveUrlEdit() async {
        guard let module = urlEditModule else { return }
        let url = urlEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            urlEditError = "值不能为空"
            reopenUrlEditDialog()
            return
        }
        if !isMitmModuleURL(url) {
            urlEditError = "值必须为URL"
            reopenUrlEditDialog()
            return
        }
        if url == module.url {
            urlEditModule = nil
            urlEditError = nil
            return
        }
        if let updated = await moduleStore.changeUrl(module, url: url) {
            urlEditModule = nil
            urlEditError = nil
            if moduleStore.awaitsConsent(updated) {
                showConsent = true
            }
        } else if let error = moduleStore.lastError {
            if error == "核心未运行，请在核心启动后重试" {
                urlEditModule = nil
                urlEditError = nil
            } else {
                // Duplicate ("模块当前已存在") or download failure:
                // back into the dialog with the error as its message.
                urlEditError = error
                reopenUrlEditDialog()
            }
        }
    }

    /// Re-presents the URL-edit dialog on the next runloop turn:
    /// setting isPresented synchronously inside the dismissing
    /// button's action is swallowed by the dismissal.
    private func reopenUrlEditDialog() {
        DispatchQueue.main.async { showUrlEditDialog = true }
    }

    /// MuYu showMitmRestartTip's gate, on iOS: only when the VPN
    /// is running and MITM is on (the tip's tap restarts it).
    private func showRestartTipIfNeeded() {
        if tunnelManager.isRunning && settingsStore.mitmEnabled {
            showRestartTip = true
        }
    }

    /// Restarts the tunnel (stop, then start) and clears the tip.
    private func restartVpn() async {
        isRestartingVpn = true
        defer { isRestartingVpn = false }
        await tunnelManager.stop()
        do {
            try await tunnelManager.start()
            showRestartTip = false
        } catch {
            moduleStore.lastError = "重启 VPN 失败：\(error.localizedDescription)"
        }
    }

    /// Upstream MitmModuleView: the "路由规则" item's note, shown
    /// only when the count is > 0 (0 => null). The count comes from
    /// the core's rules (parseWithCore) — the Swift parser never
    /// sets it, so offline there is no note, exactly as upstream
    /// shows no rules section at all without the core.
    private func extendedMatchingNote(for content: MitmModuleContent) -> String? {
        content.coreExtendedMatchingCount == 0 ? nil : "其中 \(content.coreExtendedMatchingCount) 条使用扩展匹配"
    }

    /// One MITM list as an openable row (upstream _linesItem):
    /// the count, or how many lines are flagged invalid out of the
    /// count, opening the list's lines. Empty lists stay a plain
    /// count row. The script list's lines get a run button, like
    /// upstream's per-line run menu.
    @ViewBuilder
    private func linesRow(title: String, key: String?, section: String, lines: [String], content: MitmModuleContent, note: String? = nil) -> some View {
        let issues = lineIssues(for: key, section: section, lines: lines, content: content)
        let invalid = lines.filter { issues[$0] != nil }.count
        if lines.isEmpty {
            LabeledContent(title, value: "0")
        } else {
            NavigationLink {
                MitmModuleLinesView(
                    title: title,
                    lines: lines,
                    issues: issues,
                    onRun: key == "script" ? { line in Task { await runScriptLine(line) } } : nil,
                    runningScript: runningScript,
                    canRun: module?.enabled == true && settingsStore.mitmEnabled
                )
                .concordNavBarBackground()
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(invalid == 0 ? "\(lines.count) 条" : "\(invalid) 条无效 · 共 \(lines.count) 条")
                        if let note {
                            Text(note)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                }
            }
        }
    }

    /// Per-line issue flags for one list (upstream _linesItem
    /// `issues`, keyed by line text, each value the issue lines in
    /// display order): the core's issues for this list, matched to
    /// lines by the raw module line they name (an issue's `index`
    /// is the module line), plus the Swift parser's skipped lines
    /// in this section, by line text, plus — for the `hostname`
    /// list — one "<host>: <reason>" line per item the core could
    /// not read (core 78ee46f, additive: the aggregated line
    /// message stays first when it matches at all). A rendered
    /// line that differs from its raw line (a map-local line whose
    /// file resolved to a content-hash name, a script line whose
    /// path resolved) matches neither — the flag then stays on the
    /// core note / validate output instead.
    private func lineIssues(for key: String?, section: String, lines: [String], content: MitmModuleContent) -> [String: [String]] {
        var out: [String: [String]] = [:]
        if let key,
           let rawText = module.flatMap({ moduleStore.text(of: $0) }),
           let issues = content.coreIssuesByList[key] {
            let rawLines = rawText.components(separatedBy: .newlines)
            for issue in issues {
                guard rawLines.indices.contains(issue.index) else { continue }
                let raw = rawLines[issue.index].trimmingCharacters(in: .whitespaces)
                for line in lines where line.trimmingCharacters(in: .whitespaces) == raw {
                    out[line, default: []].append(issue.message)
                }
            }
        }
        if !section.isEmpty {
            for skip in content.skipped where skip.section.lowercased() == section.lowercased() {
                let raw = skip.line.trimmingCharacters(in: .whitespaces)
                for line in lines where line.trimmingCharacters(in: .whitespaces) == raw {
                    out[line, default: []].append("\(skip.section) · \(skip.reason.label)")
                }
            }
        }
        for (line, reasons) in lineHostReasons(for: key, lines: lines, content: content) {
            out[line, default: []].append(contentsOf: reasons)
        }
        return out
    }

    /// Per-item hostname reasons (core 78ee46f): "<host>: <reason>"
    /// for each hostname the core could not read, matched to the
    /// displayed hostname line. The displayed lines are the Swift
    /// parser's individual entries (a `hostname = …` line is split
    /// on commas), while the core's `host` is the item as written
    /// minus a leading '-', with the port split out — so an entry
    /// matches its displayed line as `host`, `-host`, `host:port`
    /// or `-host:port`. Note this is also the first visible signal
    /// for a bad hostname in this list: the aggregated line message
    /// above never matches here, because the raw line is
    /// `hostname = …` while the displayed line is one entry.
    private func lineHostReasons(for key: String?, lines: [String], content: MitmModuleContent) -> [String: [String]] {
        guard key == "hostname" else { return [:] }
        var out: [String: [String]] = [:]
        for entries in content.coreHostnameEntriesByLine.values {
            for entry in entries {
                guard let reason = entry.reason, !reason.isEmpty else { continue }
                var candidates = [entry.host, "-\(entry.host)"]
                if let port = entry.port {
                    candidates.append("\(entry.host):\(port)")
                    candidates.append("-\(entry.host):\(port)")
                }
                for line in lines where candidates.contains(line.trimmingCharacters(in: .whitespaces)) {
                    out[line, default: []].append("\(entry.host): \(reason)")
                }
            }
        }
        return out
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
            runResult = ConcordSampleData.jsonValue(try await client.mitmRunScript(name: name).result)
            runMessage = "脚本 \(name) 已运行"
        } catch {
            runResult = nil
            runMessage = "运行失败：\(error.localizedDescription)"
        }
    }

    /// The core's report for this module (mitm.readModule): what
    /// format it read, whether the module takes effect as a whole,
    /// and the lines it does not take. A short note, not a redesign.
    private func coreNote(content: MitmModuleContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("核心已解析（\(content.coreFormat ?? "?")）")
                .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
            if let off = content.coreOffReason {
                Text("该模块整体不生效：\(off == "requirement" ? "前置条件不满足" : "前置条件无法读取")")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if content.coreAsksConsent {
                Text("该模块会改动 DNS / hosts / 路由等你未设置的项")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if content.coreIssueCount > 0 {
                Text("核心有 \(content.coreIssueCount) 行无法读取（见下方校验）")
                    .font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            ForEach(Array(content.coreIgnored.prefix(10)), id: \.self) { line in
                Text(line).font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            if content.coreIgnored.count > 10 {
                Text("等 \(content.coreIgnored.count) 行").font(.footnote).foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                        .font(.body)
                    if let description = argument.description, !description.isEmpty {
                        Text(description).font(.subheadline).foregroundStyle(ConcordTheme.onSurfaceVariant)
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
                        .labelsHidden()
                        .toggleStyle(UpstreamToggleStyle(hidesLabel: true))
                    }
                }
            }
            // FlClash mitm_modules.dart:570-595: arguments save on
            // each change — no Save button. Discrete controls
            // (toggle / select) save immediately; text input saves
            // on submit, so typing does not re-parse per keystroke.
            if let savedMessage {
                Text(savedMessage).font(.footnote).foregroundStyle(.green)
            }
            Text("参数会填进模块的每一行（Surge 的 {{{参数}}}、Loon 的 ${参数}、Stash 的 ${args.参数}）。改参数后需要资源的行会重新下载。")
                .font(.footnote)
                .foregroundStyle(ConcordTheme.onSurfaceVariant)
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

// MARK: - One MITM list's lines

/// One MITM list's lines, each with why the core or the parser
/// flags it, and a run button on script lines (upstream
/// _MitmModuleLinesView + _linesItem: `issues` keyed by line text,
/// each value the issue lines in display order (the aggregated line
/// message first, then per-item hostname reasons),
/// `MitmTaskRunning` spinner on the line being run).
struct MitmModuleLinesView: View {
    let title: String
    let lines: [String]
    /// line text → issue lines, in display order.
    let issues: [String: [String]]
    /// Script lists only: runs one line (the module must be
    /// enabled and MITM on — `canRun`); `runningScript` is the
    /// name of the line currently running, if any.
    var onRun: ((String) -> Void)? = nil
    var runningScript: String? = nil
    var canRun: Bool = false

    var body: some View {
        List {
            if lines.isEmpty {
                Text("没有内容")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let onRun, canRun {
                            let name = MitmModuleDetailView.scriptName(of: line)
                            Button(runningScript == name ? "运行中…" : "运行") {
                                onRun(line)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(runningScript != nil)
                        }
                    }
                    if let issueLines = issues[line] {
                        ForEach(issueLines, id: \.self) { issue in
                            Text(issue)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.pushedPageClearance)
        .contentMargins(.top, 40)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: title)
        .concordNavBarBackground()
    }
}

// MARK: - Skipped lines

struct MitmModuleSkippedView: View {
    let skipped: [MitmModuleSkip]

    var body: some View {
        List {
            Section {
                Text("这些行 FlClash 也带不过来：原因写在每行下面。改模块原文可以去掉它们。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            }
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, skip in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skip.line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("\(skip.section) · \(skip.reason.label)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.pushedPageClearance)
        .contentMargins(.top, 40)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .upstreamNavBar(title: "忽略的行")
        .concordNavBarBackground()
    }
}

// MARK: - Paste import

// MARK: - Text editor (new blank / edit existing)
//
// Not private: the exchange detail page (MitmView) opens it with
// a REJECT / map-local line already added (upstream
// openMitmModuleEditor with `edit`).

struct MitmModuleTextEditorView: View {
    let module: MitmModule?
    let initialText: String
    /// Called with the saved module after a successful save, so the
    /// caller can offer the consent prompt when it awaits it.
    var onSaved: ((MitmModule?) -> Void)? = nil
    /// Upstream openMitmModuleEditor pushes EditorPage: when true
    /// the editor renders as a pushed page in the caller's stack
    /// (no own NavigationStack, no 取消 button — the back chevron
    /// dismisses); when false it is the old sheet with its own
    /// stack and 取消 button.
    let pushed: Bool

    @EnvironmentObject private var moduleStore: MitmModuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(module: MitmModule?, initialText: String, onSaved: ((MitmModule?) -> Void)? = nil, pushed: Bool = false) {
        self.module = module
        self.initialText = initialText
        self.onSaved = onSaved
        self.pushed = pushed
        _text = State(initialValue: initialText)
    }

    var body: some View {
        if pushed {
            editorContent
                .contentMargins(.top, 40)
                .upstreamNavBar(title: module?.name ?? "新建模块")
                .concordNavBarBackground()
        } else {
            NavigationStack {
                editorContent
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

    /// The editor page itself, shared by the sheet and pushed forms.
    private var editorContent: some View {
        List {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 420)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("支持 Surge、Loon、Quantumult X 和 Stash 覆写语法。保存后会重新解析、重新下载资源；带新脚本的模块会先暂停。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    if module == nil {
                        Text("空白模板本身还不是一个模块：先加一行规则、重写或域名再保存。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
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
                    .foregroundStyle(Color(.label))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || moduleStore.isBusy)
                    if let error = moduleStore.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
    }
}
