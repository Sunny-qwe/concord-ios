import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup / restore (Tools / Settings -> 备份与恢复)
// Export: FlClash format (config.json + database.sqlite + the
// profile / script / provider / MITM files), built by
// FlClashExport and shared via ShareLink (隔空投送、存到「文件」、
// 发给自己都行); a real FlClash can restore it directly. Import:
// the restore-option dialog (all / onlyProfiles) comes BEFORE
// the file picker (upstream order); the file is auto-detected —
// config.json present means FlClash format, a manifest.json with
// format concord-ios-backup means the old format, which still
// restores through BackupStore.restore. A corrupt file reports a
// clear error and changes nothing — the message says so.
//
// After a successful restore the stores are reloaded here (profiles
// / settings / MITM modules / theme) and the active profile is
// re-applied live when the tunnel is running.
//
// v0.2.159: sections, order and wording follow upstream
// backup_and_restore.dart (远程 / 本地 / 选项). Kept, restyled
// only: the generate + share export (the iOS equivalent of
// upstream's desktop save-file picker) and the inline WebDAV
// fields (upstream uses a WebDAVForm sheet).

struct BackupView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var fontStore: FontStore
    @EnvironmentObject private var proxyStyleStore: ProxyStyleStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var client: ConcordClient

    @StateObject private var backupStore = BackupStore()

    @State private var backupURL: URL?
    @State private var showImporter = false
    @State private var showScopeDialog = false
    /// What happens after the restore-options dialog is dismissed:
    /// pick a local file, or restore a file just downloaded from
    /// WebDAV. Upstream (backup_and_restore.dart:94) asks the
    /// restore option BEFORE the file is picked, and there is no
    /// second confirm afterwards — the dialog IS the choice.
    private enum PendingAfterScope {
        case pickFile
        case restoreDownload
    }
    @State private var pendingAfterScope: PendingAfterScope?
    @State private var pickedURL: URL?
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var restoreScope: BackupStore.RestoreScope = .all
    // WebDAV account (FlClash: 备份与恢复 -> WebDAV 远程备份）.
    // Stored in UserDefaults like the other app settings; FlClash
    // keeps its WebDAV credentials in its own database the same way.
    @AppStorage("ConcordiOS.webdav.url") private var webdavURL = ""
    @AppStorage("ConcordiOS.webdav.username") private var webdavUsername = ""
    @AppStorage("ConcordiOS.webdav.password") private var webdavPassword = ""
    @AppStorage("ConcordiOS.webdav.fileName") private var webdavFileName = "backup.zip"
    @State private var webdavStatus: String?
    /// Live WebDAV connectivity (FlClash DAVConnectionController,
    /// a ValueNotifier<bool?>: null = testing spinner, true =
    /// green, false = red). The extra .unconfigured covers the
    /// no-account case — upstream shows no indicator at all
    /// without a saved account; ours shows a grey "未配置" dot.
    /// The manual "测试连接" button is gone (upstream has none):
    /// the indicator re-tests itself whenever the account changes.
    private enum WebDAVConnectionState {
        case unconfigured, testing, connected, failed
    }
    @State private var webdavState: WebDAVConnectionState = .unconfigured
    /// Request-id guard (upstream _requestId): only the newest
    /// test may write the indicator, so a slow earlier ping can
    /// never overwrite a newer result.
    @State private var webdavTestID = 0
    /// The credentials of the last completed test (upstream
    /// _lastProps, file name excluded): unchanged credentials are
    /// not re-pinged.
    @State private var lastTestedWebDAVAccount: WebDAVAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 远程 (upstream first section): the WebDAV account
                // inline (upstream: WebDAVForm sheet) + the remote
                // backup / restore rows.
                UpstreamCardSection(header: "远程") {
                    HStack(spacing: 8) {
                        // Upstream _DavConnectionIndicator next to the
                        // "连接状态" label: a 12pt spinner while testing,
                        // a green dot when connected, a red dot on failure.
                        switch webdavState {
                        case .unconfigured:
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 12, height: 12)
                            Text("未配置")
                                .font(.body)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        case .testing:
                            ProgressView()
                                .controlSize(.small)
                            Text("正在检测…")
                                .font(.body)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        case .connected:
                            Circle()
                                .fill(Color.green)
                                .frame(width: 12, height: 12)
                            Text("已连接")
                                .font(.body)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        case .failed:
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                            Text("连接失败")
                                .font(.body)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    TextField("WebDAV 地址，如 https://dav.example.com/backup/", text: $webdavURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: webdavURL) { _, _ in scheduleWebDAVTest() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    TextField("用户名", text: $webdavUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: webdavUsername) { _, _ in scheduleWebDAVTest() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    SecureField("密码", text: $webdavPassword)
                        .onChange(of: webdavPassword) { _, _ in scheduleWebDAVTest() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    TextField("备份文件名", text: $webdavFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    backupActionRow(icon: "square.and.arrow.up", title: "上传当前备份到 WebDAV") {
                        Task { await uploadToWebDAV() }
                    }
                    .disabled(webdavURL.trimmingCharacters(in: .whitespaces).isEmpty || backupStore.isWorking)
                    UpstreamDivider()
                    backupActionRow(icon: "square.and.arrow.down", title: "从 WebDAV 下载并恢复") {
                        Task { await downloadFromWebDAV() }
                    }
                    .disabled(webdavURL.trimmingCharacters(in: .whitespaces).isEmpty || backupStore.isWorking)
                    if let webdavStatus {
                        UpstreamDivider()
                        Text(webdavStatus)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }

                // 本地 (upstream second section): backup + restore.
                VStack(alignment: .leading, spacing: 12) {
                    UpstreamCardSection(header: "本地") {
                        backupActionRow(icon: "archivebox", title: "生成备份文件") {
                            Task { await createBackup() }
                        }
                        .disabled(backupStore.isWorking)
                        if let backupURL {
                            UpstreamDivider()
                            ShareLink(item: backupURL, preview: SharePreview("FlClash 备份", image: Image(systemName: "archivebox"))) {
                                HStack(spacing: 16) {
                                    UpstreamRowIcon(systemName: "square.and.arrow.up")
                                    Text("分享备份文件")
                                        .font(.body)
                                        .foregroundStyle(Color(.label))
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            UpstreamDivider()
                            Text("备份文件：\(backupURL.lastPathComponent)")
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        UpstreamDivider(leading: 16)
                        backupActionRow(icon: "square.and.arrow.down", title: "选择备份文件…") {
                            pendingAfterScope = .pickFile
                            showScopeDialog = true
                        }
                        .disabled(backupStore.isWorking)
                    }
                    Text("备份为 FlClash 格式（config.json + database.sqlite + 配置文件），文件名 FlClash_backup_YYYY-MM-DD.zip，可在 FlClash 里直接恢复。实时快照（流量、连接、日志）和地理数据库不备份，下次打开 App 时会自动重新生成。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                // 选项 (upstream third section): the restore strategy.
                VStack(alignment: .leading, spacing: 12) {
                    UpstreamCardSection(header: "选项") {
                        Picker("恢复策略", selection: $backupStore.restoreStrategy) {
                            ForEach(BackupStore.RestoreStrategy.allCases) { strategy in
                                Text(strategy.label).tag(strategy)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(16)
                        UpstreamDivider(leading: 16)
                        Text(backupStore.restoreStrategy == .compatible
                             ? "兼容模式：备份里没有的订阅、设置和 MITM 模块保留原样。"
                             : "覆盖模式：按备份内容完全替换恢复范围里的数据。")
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        UpstreamDivider(leading: 16)
                        Text(backupStore.restoreStrategy.detail)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    Text("支持 FlClash 格式和本站旧格式备份，自动识别，无需选择。导入前会先完整校验备份文件，损坏的备份不会改动任何数据；恢复后各页面会自动重新加载，VPN 正在运行时建议重启一次 VPN。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }

                if backupStore.isWorking {
                    ProgressView("正在处理…")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // v0.2.66: tab-bar clearance for pushed pages.
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "备份与恢复")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedURL = url
                    // The scope was already chosen in the dialog
                    // before the picker opened; restore directly.
                    Task { await restoreBackup() }
                }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        // Upstream _pickRestoreOption →
        // dialogs.showCommonDialog<RestoreOption>
        // (RestoreOptionsDialog) (backup_and_restore.dart:94): the
        // all / onlyProfiles choice, BEFORE the file is picked.
        // "仅恢复配置" is upstream's trap in plain words: it still
        // restores all the data (profiles, rules, scripts, MITM
        // modules) and only keeps the current settings.
        .alert("恢复备份", isPresented: $showScopeDialog) {
            Button("取消", role: .cancel) { pendingAfterScope = nil }
            Button("恢复所有数据") {
                restoreScope = .all
                proceedAfterScope()
            }
            Button("仅恢复配置文件") {
                restoreScope = .profilesOnly
                proceedAfterScope()
            }
        } message: {
            Text("恢复所有数据：备份里的配置与设置全部恢复。仅恢复配置文件：备份里的数据全部恢复，但保持当前设置不变。")
        }
        .task {
            // Live WebDAV indicator (FlClash shows the account state
            // on the page; DAVConnectionController.update runs on
            // page init): ping once on appear when an address is
            // already filled in. Later edits re-test themselves
            // through the debounced scheduleWebDAVTest.
            if !webdavURL.trimmingCharacters(in: .whitespaces).isEmpty {
                await testWebDAV()
            }
        }
    }

    /// One action row: grey leading icon + 17pt title.
    private func backupActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                UpstreamRowIcon(systemName: icon)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Runs after the scope dialog dismisses, so the file picker
    /// is not presented while the dialog is still up.
    private func proceedAfterScope() {
        let pending = pendingAfterScope
        pendingAfterScope = nil
        DispatchQueue.main.async {
            switch pending {
            case .pickFile:
                showImporter = true
            case .restoreDownload:
                Task { await restoreBackup() }
            case .none:
                break
            }
        }
    }

    private var webdavAccount: WebDAVAccount {
        WebDAVAccount(url: webdavURL, username: webdavUsername, password: webdavPassword, fileName: webdavFileName)
    }

    /// Re-tests the connection ~0.8 s after the last account edit
    /// (upstream calls update() when the saved account changes;
    /// the debounce keeps per-keystroke pings from spamming the
    /// server while the user is still typing). A newer scheduled
    /// test cancels an older one via the request id.
    private func scheduleWebDAVTest() {
        webdavTestID += 1
        let requestID = webdavTestID
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard requestID == webdavTestID else { return }
            await testWebDAV()
        }
    }

    /// Pings the current account and drives the live indicator
    /// (FlClash DAVConnectionController.update): unchanged
    /// credentials (file name excluded) are not re-pinged, and
    /// only the newest test may write the result. @MainActor: the
    /// @State writes after the ping await must land on the main
    /// thread.
    @MainActor
    private func testWebDAV() async {
        let account = webdavAccount
        guard !account.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            webdavState = .unconfigured
            return
        }
        if let tested = lastTestedWebDAVAccount,
           tested.url == account.url,
           tested.username == account.username,
           tested.password == account.password {
            return
        }
        webdavTestID += 1
        let requestID = webdavTestID
        webdavState = .testing
        do {
            try await WebDAVClient(account: account).testConnection()
            guard requestID == webdavTestID else { return }
            lastTestedWebDAVAccount = account
            webdavState = .connected
            webdavStatus = "WebDAV 连接成功"
        } catch {
            guard requestID == webdavTestID else { return }
            lastTestedWebDAVAccount = account
            webdavState = .failed
            webdavStatus = "WebDAV 连接失败：\(error.localizedDescription)"
        }
    }

    /// @MainActor like testWebDAV: the @State writes after the
    /// upload await must land on the main thread.
    @MainActor
    private func uploadToWebDAV() async {
        backupStore.isWorking = true
        defer { backupStore.isWorking = false }
        do {
            guard let context = flClashExportContext() else {
                throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "App Group 容器不可用"])
            }
            let url = try await backupStore.createFlClashBackup(context: context)
            backupURL = url
            let data = try Data(contentsOf: url)
            try await WebDAVClient(account: webdavAccount).upload(data)
            // A successful upload proves the account works.
            lastTestedWebDAVAccount = webdavAccount
            webdavState = .connected
            webdavStatus = "已上传到 WebDAV：\(webdavFileName)"
        } catch {
            webdavStatus = "上传失败：\(error.localizedDescription)"
        }
    }

    /// @MainActor like testWebDAV: the @State writes after the
    /// download await must land on the main thread.
    @MainActor
    private func downloadFromWebDAV() async {
        backupStore.isWorking = true
        defer { backupStore.isWorking = false }
        do {
            let data = try await WebDAVClient(account: webdavAccount).download()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(webdavFileName.isEmpty ? "backup.zip" : webdavFileName)
            try data.write(to: tempURL, options: .atomic)
            pickedURL = tempURL
            webdavStatus = "已下载备份，请选择恢复选项"
            // Same order as a local file: the restore dialog first,
            // then the restore itself (via the dialog's choice).
            pendingAfterScope = .restoreDownload
            showScopeDialog = true
        } catch {
            webdavStatus = "下载失败：\(error.localizedDescription)"
        }
    }

    private func createBackup() async {
        backupStore.isWorking = true
        message = nil
        errorMessage = nil
        do {
            guard let context = flClashExportContext() else {
                throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "App Group 容器不可用"])
            }
            backupURL = try await backupStore.createFlClashBackup(context: context)
            message = "备份已生成（FlClash 格式），点「分享备份文件」保存或发送。"
        } catch {
            errorMessage = "生成备份失败：\(error.localizedDescription)"
        }
        backupStore.isWorking = false
    }

    /// Snapshot everything the FlClash export needs. The file-backed
    /// stores that are not environment objects (MITM scripts,
    /// custom proxies, added rules, extend settings, overrides)
    /// are read through fresh instances, which load from disk on
    /// init; the live stores re-read from disk when their page
    /// next opens, so the snapshot cannot go stale.
    private func flClashExportContext() -> FlClashExportContext? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            return nil
        }
        var yamls: [UUID: String] = [:]
        for profile in profileStore.profiles {
            let url = container.appendingPathComponent("profiles/\(profile.id.uuidString).yaml")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                yamls[profile.id] = text
            }
        }
        let scriptStore = MitmScriptStore()
        var scriptContents: [String: String] = [:]
        for script in scriptStore.scripts {
            if let content = scriptStore.content(of: script) {
                scriptContents[script.id] = content
            }
        }
        var moduleTexts: [String: String] = [:]
        for module in mitmModuleStore.modules {
            if let text = mitmModuleStore.text(of: module) {
                moduleTexts[module.id] = text
            }
        }
        let proxyStore = CustomProxyStore()
        let addedStore = AddedRulesStore()
        let extendStore = ExtendConfigStore()
        let overrideStore = OverrideStore.shared
        return FlClashExportContext(
            profiles: profileStore.profiles, profileYAMLs: yamls,
            settings: settingsStore, theme: themeStore,
            proxyStyle: proxyStyleStore, webdav: webdavAccount,
            restoreStrategy: backupStore.restoreStrategy,
            mitmModules: mitmModuleStore.modules,
            mitmModuleTexts: moduleTexts,
            mitmScripts: scriptStore.scripts,
            mitmScriptContents: scriptContents,
            customProxies: proxyStore.proxies,
            rawProxies: proxyStore.rawProxies,
            addedRules: addedStore.rules,
            disabledAddedRules: addedStore.disabledRules,
            extendSettings: extendStore.settingsByProfile,
            overrideGlobal: overrideStore.global,
            overrideProfiles: overrideStore.profiles,
            container: container)
    }

    private func restoreBackup() async {
        guard let pickedURL else { return }
        backupStore.isWorking = true
        message = nil
        errorMessage = nil
        defer {
            backupStore.isWorking = false
            self.pickedURL = nil
        }
        do {
            let summary = try await backupStore.restoreAutoDetect(
                from: pickedURL, scope: restoreScope,
                strategy: backupStore.restoreStrategy,
                settings: settingsStore, theme: themeStore,
                proxyStyle: proxyStyleStore)
            // Reload every store that keeps its state on disk, so the
            // pages show the restored data without restarting the app
            // (audit B8): the UserDefaults-backed ones re-read their
            // keys, and the live-data ones re-pull from the core.
            // IconSetStore is a singleton, not an environment object.
            profileStore.reload()
            settingsStore.reload()
            mitmModuleStore.reload()
            themeStore.reload()
            fontStore.reload()
            proxyStyleStore.reload()
            IconSetStore.shared.reload()
            client.reloadMode()
            await proxyStore.refresh()
            await ruleStore.refresh()
            await dnsStore.refresh()
            await trafficStore.refresh()
            message = summary
            // Re-apply the restored active profile live when the
            // tunnel is running; otherwise it takes effect at the
            // next VPN start (the files are already in place).
            if let reapplyMessage = await profileStore.reapplyActive() {
                message = summary + "\n" + reapplyMessage
            }
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
        }
    }
}
