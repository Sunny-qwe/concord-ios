import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup / restore (Tools / Settings -> 备份与恢复)
// Export: BackupStore builds ONE zip (all App Group files + the
// UserDefaults blobs) in tmp; ShareLink shares it (隔空投送、存到
// 「文件」、发给自己都行). Import: fileImporter picks a .zip, the
// store validates it and restores all-or-nothing. A corrupt file
// reports a clear error and changes nothing — the message says so.
//
// After a successful restore the stores are reloaded here (profiles
// / settings / MITM modules / theme) and the active profile is
// re-applied live when the tunnel is running.

struct BackupView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var client: ConcordClient

    @StateObject private var backupStore = BackupStore()

    @State private var backupURL: URL?
    @State private var showImporter = false
    @State private var showRestoreConfirm = false
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
    @AppStorage("ConcordiOS.webdav.fileName") private var webdavFileName = "concord-ios-backup.zip"
    @State private var webdavStatus: String?
    @State private var webdavConnected: Bool?

    var body: some View {
        List {
            Section("导出备份") {
                Text("备份包含：全部订阅配置、设置（通用 / TUN / DNS / MITM）、MITM 模块、主题和核心模式。实时快照（流量、连接、日志）不备份，下次打开 App 时会自动重新生成。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    Task { await createBackup() }
                } label: {
                    Label("生成备份文件", systemImage: "archivebox")
                }
                .disabled(backupStore.isWorking)
                if let backupURL {
                    ShareLink(item: backupURL, preview: SharePreview("Concord 备份", image: Image(systemName: "archivebox"))) {
                        Label("分享备份文件", systemImage: "square.and.arrow.up")
                    }
                    Text("备份文件：\(backupURL.lastPathComponent)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Section("导入备份") {
                Text("导入会替换当前全部订阅、设置和 MITM 模块。恢复前会先完整校验备份文件，损坏的备份不会改动任何数据；恢复后各页面会自动重新加载，VPN 正在运行时建议重启一次 VPN。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Picker("恢复选项", selection: $restoreScope) {
                    ForEach(BackupStore.RestoreScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                Text(restoreScope == .all
                     ? "恢复全部数据：所有文件与设置都被备份里的内容替换。"
                     : "仅恢复配置：只恢复订阅与配置，设置、主题、MITM 模块保持不变。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Label("选择备份文件…", systemImage: "square.and.arrow.down")
                }
                .disabled(backupStore.isWorking)
            }

            Section("WebDAV 远程备份") {
                HStack {
                    Circle()
                        .fill(webdavConnected == nil ? Color.gray : (webdavConnected! ? Color.green : Color.red))
                        .frame(width: 10, height: 10)
                    Text(webdavConnected == nil ? "未测试" : (webdavConnected! ? "已连接" : "连接失败"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                TextField("WebDAV 地址，如 https://dav.example.com/backup/", text: $webdavURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $webdavUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $webdavPassword)
                TextField("备份文件名", text: $webdavFileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("测试连接") {
                    Task { await testWebDAV() }
                }
                .disabled(webdavURL.trimmingCharacters(in: .whitespaces).isEmpty || backupStore.isWorking)
                Button("上传当前备份到 WebDAV") {
                    Task { await uploadToWebDAV() }
                }
                .disabled(webdavURL.trimmingCharacters(in: .whitespaces).isEmpty || backupStore.isWorking)
                Button("从 WebDAV 下载并恢复") {
                    Task { await downloadFromWebDAV() }
                }
                .disabled(webdavURL.trimmingCharacters(in: .whitespaces).isEmpty || backupStore.isWorking)
                if let webdavStatus {
                    Text(webdavStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if backupStore.isWorking {
                Section {
                    ProgressView("正在处理…")
                }
            }
            if let message {
                Section {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .navigationTitle("备份与恢复")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedURL = url
                    showRestoreConfirm = true
                }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("确定要恢复这个备份吗？", isPresented: $showRestoreConfirm) {
            Button("恢复", role: .destructive) {
                Task { await restoreBackup() }
            }
            Button("取消", role: .cancel) { pickedURL = nil }
        } message: {
            Text(restoreScope == .all
                 ? "当前全部订阅、设置和 MITM 模块会被备份里的内容替换。"
                 : "只恢复备份里的订阅与配置，设置、主题、MITM 模块保持不变。")
        }
    }

    private var webdavAccount: WebDAVAccount {
        WebDAVAccount(url: webdavURL, username: webdavUsername, password: webdavPassword, fileName: webdavFileName)
    }

    private func testWebDAV() async {
        backupStore.isWorking = true
        defer { backupStore.isWorking = false }
        do {
            try await WebDAVClient(account: webdavAccount).testConnection()
            webdavConnected = true
            webdavStatus = "WebDAV 连接成功"
        } catch {
            webdavConnected = false
            webdavStatus = "WebDAV 连接失败：\(error.localizedDescription)"
        }
    }

    private func uploadToWebDAV() async {
        backupStore.isWorking = true
        defer { backupStore.isWorking = false }
        do {
            let url = try await backupStore.createBackup()
            backupURL = url
            let data = try Data(contentsOf: url)
            try await WebDAVClient(account: webdavAccount).upload(data)
            webdavConnected = true
            webdavStatus = "已上传到 WebDAV：\(webdavFileName)"
        } catch {
            webdavStatus = "上传失败：\(error.localizedDescription)"
        }
    }

    private func downloadFromWebDAV() async {
        backupStore.isWorking = true
        defer { backupStore.isWorking = false }
        do {
            let data = try await WebDAVClient(account: webdavAccount).download()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(webdavFileName.isEmpty ? "concord-ios-backup.zip" : webdavFileName)
            try data.write(to: tempURL, options: .atomic)
            pickedURL = tempURL
            showRestoreConfirm = true
            webdavStatus = "已下载备份，请确认恢复"
        } catch {
            webdavStatus = "下载失败：\(error.localizedDescription)"
        }
    }

    private func createBackup() async {
        backupStore.isWorking = true
        message = nil
        errorMessage = nil
        do {
            backupURL = try await backupStore.createBackup()
            message = "备份已生成，点「分享备份文件」保存或发送。"
        } catch {
            errorMessage = "生成备份失败：\(error.localizedDescription)"
        }
        backupStore.isWorking = false
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
            let summary = try await backupStore.restore(from: pickedURL, scope: restoreScope)
            // Reload every store that keeps its state on disk, so the
            // pages show the restored data without restarting the app.
            profileStore.reload()
            settingsStore.reload()
            mitmModuleStore.reload()
            themeStore.reload()
            client.reloadMode()
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
