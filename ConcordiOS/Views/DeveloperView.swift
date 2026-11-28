import SwiftUI

// MARK: - Developer (FlClash: Tools -> 开发者模式）
// Only shown when developerMode is on (ToolsView gates the row).
// v0.2.153: the crash test (upstream developer.dart crashTest)
// and the MITM memory-pressure control (core.setPressure, no
// upstream UI) are back here — both were cut in v0.2.141 with
// the Settings developer section. The release core still
// answers "method not found" to debug.crash; crashCore shows
// the core's answer instead of pretending it crashed.

struct DeveloperView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var logStore: LogStore
    // V-D4/V-D5 (v0.2.138): the prune and clear scans need the
    // live profile ids, the core's provider list, and the client
    // for profile.clearEffect.
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient
    @State private var message: String?
    @State private var showingClearConfirm = false
    /// v0.2.153: the crash-test confirm (restored with the button).
    @State private var showCrashConfirm = false
    /// v0.2.153 audit B2: the pressure Picker binds this local
    /// selection, NOT $settingsStore.pressureLevel — setPressure
    /// only commits pressureLevel on success, so binding the
    /// store directly would show a level the core never applied
    /// after a failed apply (sample mode / tunnel stopped).
    @State private var pressureSelection = 0
    /// V-M1 (v0.2.138): the live-status test sheet.
    @State private var showLiveStatusTest = false
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    UpstreamCardSection(header: "开发者模式") {
                        devToggleRow("开发者模式", isOn: $settingsStore.developerMode)
                            .onChange(of: settingsStore.developerMode) { _, _ in
                                settingsStore.save()
                            }
                    }
                    Text("开启后工具页显示本页入口；关闭后本页从工具页消失。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                if !testBanners.isEmpty {
                    UpstreamCardSection(header: "消息测试") {
                        ForEach(Array(testBanners.enumerated()), id: \.element.id) { index, banner in
                            HStack(spacing: 16) {
                                Image(systemName: banner.level.icon)
                                    .font(.system(size: 22, weight: .regular))
                                    .foregroundStyle(banner.level.color)
                                    .frame(width: 24, height: 24)
                                Text("\(banner.level.rawValue)：这是一条开发者测试消息")
                                    .font(.body)
                                    .foregroundStyle(Color(.label))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 56)
                            if index < testBanners.count - 1 {
                                UpstreamDivider(leading: 16)
                            }
                        }
                    }
                }
                UpstreamCardSection(header: "测试") {
                    devButtonRow("消息测试") {
                        runMessageTest()
                    }
                    UpstreamDivider(leading: 16)
                    devButtonRow("日志测试（写入 1000 条测试日志）") {
                        runLogsTest()
                    }
                    UpstreamDivider(leading: 16)
                    // v0.2.153: the crash test is back (cut in v0.2.141,
                    // restored by the full-completion order) at
                    // upstream's own location (developer.dart crashTest).
                    // The release core still answers "method not
                    // found" — crashCore surfaces the core's answer
                    // below instead of pretending it crashed.
                    devButtonRow("让核心崩溃（debug.crash）", role: .destructive) {
                        showCrashConfirm = true
                    }
                    if let crashMessage = settingsStore.crashMessage {
                        UpstreamDivider(leading: 16)
                        Text(crashMessage)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    UpstreamDivider(leading: 16)
                    devButtonRow(isDownloadTesting ? "下载测试中…" : "更新下载测试") {
                        Task { await runDownloadTest() }
                    }
                    .disabled(isDownloadTesting)
                    UpstreamDivider(leading: 16)
                    // V-M1 (v0.2.138): upstream's live-status preview
                    // (views/developer.dart liveStatusTest ->
                    // showLiveStatusPreview, views/dashboard/widgets/
                    // live_status.dart:66). Ours has no core/update/
                    // consent cards, so the preview opens the warnings
                    // deck with upstream's five sample warnings — the
                    // one live-status card this app has.
                    devButtonRow("实时状态卡片测试") {
                        showLiveStatusTest = true
                    }
                }
                // v0.2.153: the MITM memory-pressure control is back
                // (cut in v0.2.141 with the Settings developer
                // section). Upstream has no pressure UI anywhere —
                // core.setPressure is a core debug control — so it
                // lives here with the other developer tools instead
                // of in Settings.
                VStack(alignment: .leading, spacing: 12) {
                    UpstreamCardSection(header: "MITM 内存压力") {
                        Picker("MITM 内存压力（core.setPressure）", selection: $pressureSelection) {
                            Text("0 无压力").tag(0)
                            Text("1 停止脚本").tag(1)
                            Text("2 停止保存请求体").tag(2)
                            Text("3 仅中继").tag(3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                        UpstreamDivider(leading: 16)
                        devButtonRow("设置内存压力") {
                            Task {
                                await settingsStore.setPressure(level: pressureSelection)
                                // Snap back to the applied level: on a
                                // failed apply pressureLevel is untouched,
                                // so the Picker shows what the core has.
                                pressureSelection = settingsStore.pressureLevel
                            }
                        }
                        if let pressureMessage = settingsStore.pressureMessage {
                            UpstreamDivider(leading: 16)
                            Text(pressureMessage)
                                .font(.footnote)
                                .foregroundStyle(ConcordTheme.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                    Text("压力只升不降（核心在一段时间后自动解除），只影响 MITM 抓包的内存占用：等级 1 停止运行脚本、2 停止保存请求体、3 仅中继流量。MITM 关闭时不起作用。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                }
                // Upstream order (developer.dart:20-100): 清除全部数据
                // before 清理缓存.
                VStack(alignment: .leading, spacing: 12) {
                    UpstreamCardSection(header: "数据") {
                        devButtonRow("清除全部数据", role: .destructive) {
                            showingClearConfirm = true
                        }
                        UpstreamDivider(leading: 16)
                        devButtonRow("清理缓存") {
                            Task { await pruneCache() }
                        }
                    }
                    Text("将删除所有配置、设置和本地数据，随后关闭应用。重新打开即可从头开始。")
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // v0.2.66: tab-bar clearance for pushed pages.
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "开发者模式")
        .onAppear { pressureSelection = settingsStore.pressureLevel }
        .alert("确定要让核心崩溃吗？", isPresented: $showCrashConfirm) {
            Button("崩溃", role: .destructive) {
                Task { await settingsStore.crashCore() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("debug.crash 会让核心进程立即中止，VPN 隧道随之断开，仅用于调试。注意：iOS 的发布版核心没有编译 debug 功能，调用会被核心拒绝，实际不会崩溃。")
        }
        .alert("确定要清除所有数据？", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { Task { await clearAllData() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有配置、设置和本地数据，随后关闭应用。重新打开即可从头开始。")
        }
        // V-M1 (v0.2.138): the live-status preview sheet — the
        // same chrome as the Dashboard live-status deck
        // (ConfigWarningsDeck).
        .sheet(isPresented: $showLiveStatusTest) {
            ConfigWarningsDeck(warnings: Self.sampleLiveStatusWarnings)
                .concordCard()
                .padding()
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(ConcordTheme.pageBackground)
                .presentationCornerRadius(28)
        }
    }

    /// One toggle row: 17pt title, upstream switch (the style
    /// renders the label + the 52x32 track, and the whole row
    /// toggles, as upstream's ListItem.toggle).
    private func devToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.body)
            .foregroundStyle(Color(.label))
            .toggleStyle(UpstreamToggleStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
    }

    /// One button row: 17pt title, red when destructive.
    private func devButtonRow(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action)
            .font(.body)
            .foregroundStyle(role == .destructive ? Color.red : Color(.label))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
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

    /// V-D4 (v0.2.138, aligned v0.2.145): prune scope matches upstream's
    /// shakingStore (lib/providers/actions/store.dart:10) +
    /// shakeOrphanFiles (lib/common/task.dart:449-520): delete ORPHAN
    /// files — profile YAMLs with no profile, provider-cache files
    /// with no provider, script files with no registered script.
    /// The live sets come from the app's own stores; a directory
    /// whose live list cannot be read is SKIPPED, never emptied on
    /// a guess (upstream's lists leave out rows they cannot read,
    /// and the tables may not hold an optimistic write yet). Files
    /// are matched by stem: profiles/<uuid>.yaml (upstream: numeric
    /// ids, ours are UUIDs), the provider cache dirs providers/ +
    /// providers/proxies/ + rules/ + proxies/ by the core's provider
    /// `path` stems — upstream's DB fileNames, never the display
    /// name (a renamed provider keeps its file) — and
    /// mitm/scripts/<id>.js. Anything else — the scripts.json
    /// registry, subdirectories — is left alone. The generated
    /// cache (snapshots + preflight.yaml) is NOT touched: upstream
    /// never deletes generated cache, it is regenerated on demand.
    private func pruneCache() async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
            message = "App Group 容器不可用"
            return
        }
        var removed = 0
        var skipped: [String] = []

        // Live profiles: ProfileStore loads synchronously from
        // UserDefaults at launch, so its ids are always available.
        let liveProfiles = Set(profileStore.profiles.map { $0.id.uuidString })
        removed += shakeDirectory(container.appendingPathComponent("profiles"),
                                  extensions: ["yaml"], liveStems: liveProfiles)

        // Live providers: the list comes from the core, so refresh
        // first. If the list is still empty afterwards, the
        // providers dirs are SKIPPED — an empty list after a
        // failed refresh proves nothing, and emptying them would
        // delete live files. The live set is the providers'
        // cached-file stems (upstream's DB fileNames): the core's
        // provider `path` IS the cached file ("providers/
        // example.yaml", "rules/geosite-cn.yaml", "proxies/<md5>").
        // Empty paths and URLs carry no file to keep.
        await ruleStore.refresh()
        if !ruleStore.providers.isEmpty {
            let liveProviderFiles = Set(ruleStore.providers.compactMap { provider -> String? in
                let path = provider.path
                guard !path.isEmpty, !path.contains("://") else { return nil }
                let stem = (path as NSString).deletingPathExtension
                return (stem as NSString).lastPathComponent
            })
            // The provider cache dirs (AppCore ProviderCacheSeed
            // .cacheDirs, plus the providers/proxies/ subdir the
            // core uses for HTTP proxy providers): upstream shakes
            // the provider-cache dir by fileNames.
            for dir in ["providers", "providers/proxies", "rules", "proxies"] {
                removed += shakeDirectory(container.appendingPathComponent(dir),
                                          extensions: ["yaml", "yml", "mrs", "dat", ""], liveStems: liveProviderFiles)
            }
        } else {
            skipped.append("提供方")
        }

        // Live scripts: MitmScriptStore loads its registry
        // synchronously from scripts.json at init.
        let liveScripts = Set(MitmScriptStore().scripts.map { $0.id })
        removed += shakeDirectory(container.appendingPathComponent("mitm/scripts"),
                                  extensions: ["js"], liveStems: liveScripts)

        if skipped.isEmpty {
            message = removed > 0 ? "已清理缓存（\(removed) 项）" : "没有可清理的缓存"
        } else {
            message = "已清理缓存（\(removed) 项）；\(skipped.joined(separator: "、"))未刷新，跳过"
        }
    }

    /// Delete files in `dir` whose name stem is not in
    /// `liveStems`, keeping only the given extensions. A missing
    /// dir is a no-op; subdirectories are never deleted.
    private func shakeDirectory(_ dir: URL, extensions: [String], liveStems: Set<String>) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let ext = (name as NSString).pathExtension
            guard extensions.contains(ext) else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard !liveStems.contains(stem) else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// V-D5 (v0.2.138): clear scope matches upstream's
    /// handleClear (lib/providers/actions/store.dart:39) +
    /// clearAppData (lib/common/app_data.dart:7): clearEffect per
    /// profile (the core's per-profile downloads, best-effort),
    /// clear ALL preferences, delete the profile files, then EXIT
    /// the app (upstream handleExit) — the old "请重启应用" note
    /// is gone. Upstream keeps scripts / provider files / MITM
    /// module files: only their RECORDS are cleared (the profiles
    /// dir + the modules/scripts registries), the orphaned files
    /// are left for the next prune — so the whole App Group
    /// container is NOT deleted any more.
    private func clearAllData() async {
        // 1. clearEffect per numeric core-side profile id,
        // best-effort (upstream: try/catch per profile, warn and
        // continue). Our profiles are UUIDs and the app never
        // learns numeric core ids — config.apply takes no profile
        // id, and no profile.* RPC creates or returns one — so ids
        // are discovered by scanning the core homes'
        // profiles/providers/ dirs (the exact path the core's
        // clear_effect deletes, engine/src/ops.rs:122-137). The
        // scan is usually empty, so the RPC loop usually calls
        // nothing — but the cleanup must not be skipped on that
        // account: clear_effect's whole effect is deleting
        // profiles/providers/<id>, so delete the whole
        // profiles/providers/ dir in both homes directly. That is
        // clearEffect for every profile at once, including the
        // in-memory ones whose numeric ids are unknowable — and it
        // also covers the in-app core's home, which the tunnel
        // core's RPC never reaches. Per-profile downloads are
        // cache: the core re-downloads them on next use.
        for id in coreProfileIds() {
            try? await client.profileClearEffect(profileId: id)
        }
        for home in coreHomes() {
            try? FileManager.default.removeItem(
                at: home.appendingPathComponent("profiles/providers", isDirectory: true))
        }
        // 2. All preferences (upstream clearPreferences): every
        // ConcordiOS.* key, plus AppleLanguages (the language
        // choice resets to the system language with the rest).
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ConcordiOS.") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "AppleLanguages")
        // 3. The record files: the profiles dir, the MITM modules
        // registry and the scripts registry (the app's equivalents
        // of upstream's deleted Drift tables). Script .js files,
        // provider .yaml files and MITM module files stay as
        // orphans until the next prune, exactly like upstream.
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) {
            let fm = FileManager.default
            try? fm.removeItem(at: container.appendingPathComponent("profiles"))
            try? fm.removeItem(at: container.appendingPathComponent("mitm-modules/modules.json"))
            try? fm.removeItem(at: container.appendingPathComponent("mitm/scripts/scripts.json"))
        }
        // 4. Stop the tunnel first — a running tunnel would keep
        // proxying on the deleted config — then exit, like
        // upstream's handleExit (which closes the window and the
        // core).
        await TunnelManager.shared.stop()
        exit(0)
    }

    /// Both core homes (the in-app core's Application Support dir
    /// and the App Group container the tunnel core uses): the
    /// per-profile provider-download dirs live under each.
    private func coreHomes() -> [URL] {
        let fm = FileManager.default
        var homes: [URL] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            homes.append(support.appendingPathComponent("ConcordAppCore", isDirectory: true))
        }
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) {
            homes.append(container)
        }
        return homes
    }

    /// Numeric core-side profile ids, from the core homes'
    /// profiles/providers/ dirs (upstream's clearEffect takes the
    /// profile's numeric id; ours are UUIDs, so the ids are only
    /// discoverable from the core's own download dirs).
    private func coreProfileIds() -> [Int64] {
        var ids: [Int64] = []
        for home in coreHomes() {
            let dir = home.appendingPathComponent("profiles/providers", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                if let id = Int64(name) { ids.append(id) }
            }
        }
        return ids
    }

    /// V-M1 (v0.2.138): upstream's five sample warnings for the
    /// live-status preview (views/dashboard/widgets/live_status
    /// .dart:96-115), verbatim — the core's real warnings are in
    /// English too, so the mock matches what the deck shows in
    /// production.
    private static let sampleLiveStatusWarnings: [ConcordWarning] = [
        ConcordWarning(level: "warning", code: nil, path: "proxies[12]", message: "masque is not supported, the proxy was removed"),
        ConcordWarning(level: "warning", code: nil, path: "sniffer.override", message: "unknown key"),
        ConcordWarning(level: "warning", code: nil, path: "rules[48]", message: "the rule names a missing group and goes to DIRECT instead"),
        ConcordWarning(level: "warning", code: nil, path: "tun.stack", message: "mixed runs as the userspace stack"),
        ConcordWarning(level: "warning", code: nil, path: "external-ui", message: "key is not supported by this core and is ignored"),
    ]
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

