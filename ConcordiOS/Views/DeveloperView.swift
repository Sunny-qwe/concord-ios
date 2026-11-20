import SwiftUI

// MARK: - Developer (FlClash: Tools -> 开发者模式）
// Only shown when developerMode is on (ToolsView gates the row).
// The crash test sends debug.crash — the iOS staticlib was built
// without the debug feature, so the core answers "method not
// found" and nothing crashes; the message says so.

struct DeveloperView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var logStore: LogStore
    @State private var message: String?
    @State private var showingClearConfirm = false

    var body: some View {
        List {
            Section("开发者模式") {
                Toggle("开发者模式", isOn: $settingsStore.developerMode)
                    .onChange(of: settingsStore.developerMode) { _, _ in
                        settingsStore.save()
                    }
                Text("开启后工具页显示本页入口；关闭后本页从工具页消失。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("测试") {
                Button("消息测试") {
                    message = "测试消息：这是一条开发者测试消息（\(Date().formatted(date: .omitted, time: .standard))）"
                }
                Button("日志测试（写入 1000 条测试日志）") {
                    let now = Int64(Date().timeIntervalSince1970)
                    let batch = (0..<1000).map { i in
                        ConcordLogEntry(level: "info", time: now + Int64(i), text: "测试日志 #\(i)")
                    }
                    logStore.entries.append(contentsOf: batch)
                    message = "已写入 1000 条测试日志（下次刷新日志时被核心日志覆盖）"
                }
                Button("崩溃测试") {
                    Task { await settingsStore.crashCore() }
                }
                Button("更新下载测试") {
                    Task {
                        if let result = await UpdateChecker.check() {
                            message = "更新检查成功：最新提交 \(String(result.sha.prefix(7))) — \(result.message)"
                        } else {
                            message = "更新检查失败（网络或 GitHub API 不可用）"
                        }
                    }
                }
                if let crashMessage = settingsStore.crashMessage {
                    Text(crashMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("数据") {
                Button("清理缓存") {
                    pruneCache()
                }
                Button("清除全部数据", role: .destructive) {
                    showingClearConfirm = true
                }
                Text("清除全部数据会删掉 App Group 容器里的所有文件（订阅、配置、设置、MITM 模块）和保存的偏好，之后请重启应用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("开发者模式")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除全部数据？", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { clearAllData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("订阅、配置、设置、主题、MITM 模块都会被删除，此操作不可撤销。")
        }
    }

    private func pruneCache() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            message = "App Group 容器不可用"
            return
        }
        var removed = 0
        for name in ["snapshots", "preflight.yaml"] {
            let url = container.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        message = removed > 0 ? "已清理缓存（\(removed) 项）" : "没有可清理的缓存"
    }

    private func clearAllData() {
        for key in ["ConcordiOS.profiles.v1", "ConcordiOS.settings.v1", "ConcordiOS.theme.v1", "ConcordiOS.mode.v1", UpdateChecker.lastSeenHeadKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: container.path) {
            for item in contents {
                try? FileManager.default.removeItem(at: container.appendingPathComponent(item))
            }
        }
        message = "已清除全部数据，请重启应用"
    }
}
