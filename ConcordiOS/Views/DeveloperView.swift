import SwiftUI

// MARK: - Developer (FlClash: Tools -> 开发者模式）
// Only shown when developerMode is on (ToolsView gates the row).
// V-M2: there is no crash test here — the iOS staticlib was built
// without the debug feature, so debug.crash answers "method not
// found" and nothing crashes. The test section says so instead of
// offering a button that cannot work.

struct DeveloperView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var logStore: LogStore
    @State private var message: String?
    @State private var showingClearConfirm = false
    /// V-D1: the message test shows one banner per banner level
    /// (upstream developer.dart loops BannerLevel.values). The
    /// levels come from prism_ui, which is absent from both
    /// reference checkouts, so the four conventional levels are
    /// used; they auto-dismiss after 4 s.
    @State private var testBanners: [DevBanner] = []
    @State private var bannerTask: Task<Void, Never>?
    @State private var isDownloadTesting = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.24"
    }

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
            if !testBanners.isEmpty {
                Section("消息测试") {
                    ForEach(testBanners) { banner in
                        HStack(spacing: 8) {
                            Image(systemName: banner.level.icon)
                                .foregroundStyle(banner.level.color)
                            Text("\(banner.level.rawValue)：这是一条开发者测试消息")
                                .font(.footnote)
                        }
                    }
                }
            }
            Section("测试") {
                Button("消息测试") {
                    runMessageTest()
                }
                Button("日志测试（写入 1000 条测试日志）") {
                    runLogsTest()
                }
                // V-M2: no crash-test button — the core was built
                // without the debug feature, so it cannot crash on
                // demand. The row below explains this.
                Text("崩溃测试不可用：iOS 核心静态库构建时未开启 debug 功能，debug.crash 会返回“方法不存在”，无法让核心崩溃。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isDownloadTesting ? "下载测试中…" : "更新下载测试") {
                    Task { await runDownloadTest() }
                }
                .disabled(isDownloadTesting)
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
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("开发者模式")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除全部数据？", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { clearAllData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("订阅、配置、设置、主题、MITM 模块都会被删除，此操作不可撤销。")
        }
    }

    /// V-D1: one banner per banner level, like upstream's loop
    /// over BannerLevel.values.
    private func runMessageTest() {
        testBanners = DevBannerLevel.allCases.map { DevBanner(level: $0) }
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            testBanners = []
        }
    }

    /// V-D2: upstream's logs test writes 1000 random strings of
    /// 20–200 characters via the logs provider. Ours appends them
    /// to the log store directly (the store merges on refresh, so
    /// the test entries survive the next refresh — the old message
    /// claiming they are overwritten was wrong).
    private func runLogsTest() {
        let now = Int64(Date().timeIntervalSince1970)
        let batch = (0..<1000).map { i in
            ConcordLogEntry(level: "info", time: now + Int64(i), text: Self.randomTestString())
        }
        logStore.entries.append(contentsOf: batch)
        message = "已写入 1000 条随机测试日志（每条 20–200 字符），用于测试日志渲染与滚动；下次刷新日志时仍会保留。"
    }

    private static func randomTestString() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let length = Int.random(in: 20...200)
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    /// V-M3: a real download test — fetch the latest release, find
    /// its .ipa asset, download it to a temporary file, report the
    /// bytes, and delete it. When the release carries no .ipa the
    /// test says so instead of failing silently.
    private func runDownloadTest() async {
        isDownloadTesting = true
        defer { isDownloadTesting = false }
        message = "正在查询最新版本…"
        guard let release = await UpdateChecker.checkRelease(currentVersion: version) else {
            message = "更新检查失败（网络或 GitHub API 不可用）"
            return
        }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }),
              let url = URL(string: asset.downloadUrl) else {
            message = "最新版本 \(release.tag) 没有 IPA 文件可下载（仅源码包或其他文件）"
            return
        }
        message = "正在下载 \(asset.name)…"
        do {
            let (tmpUrl, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: tmpUrl) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                message = "下载失败：服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: tmpUrl.path)[.size] as? Int64) ?? asset.size
            message = "下载测试成功：\(asset.name) 共 \(ConcordFormat.bytes(bytes))，临时文件已删除。"
        } catch {
            message = "下载失败：\(error.localizedDescription)"
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

/// One banner shown by the message test (V-D1).
private struct DevBanner: Identifiable {
    let id = UUID()
    let level: DevBannerLevel
}

/// The banner levels (upstream BannerLevel, from prism_ui): the
/// four conventional levels — info, success, warning, error.
/// prism_ui is absent from both reference checkouts, so this set
/// is the standard one, not a code-verified copy.
private enum DevBannerLevel: String, CaseIterable {
    case info = "信息"
    case success = "成功"
    case warning = "警告"
    case error = "错误"

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
