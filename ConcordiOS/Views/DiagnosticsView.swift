import SwiftUI

// MARK: - Diagnostics (FlClash: Tools -> 可靠性中心)
// Status + profile + MITM module counts, network health checks,
// per-module parse reports, config preflight, Geo resource check
// and recent issues. VPN evidence comes from the extension's
// vpn-diagnostics.json + vpn-startup.json in the App Group (the
// same files TunnelManager reads startedAt from); peak memory is
// NOT written by our extension, so that row honestly says so
// instead of inventing a number.

/// VPN evidence read from the extension's diagnostic files
/// (upstream diagnostics.dart VpnDiagnosticSnapshot): our
/// vpn-diagnostics.json carries stage / startedAt / updatedAt /
/// pid / packet counters (PacketTunnelProvider.writeVPNDiagnostics)
/// — no peak-footprint-bytes and no samples array, so those two
/// upstream rows have no source here. The startup record comes
/// from vpn-startup.json (TunnelStartupDiagnosticRecord).
private struct VpnEvidence {
    let stage: String?
    let startedAt: Date?
    let updatedAt: Date?
    let pid: Int?
    let packetsIn: Int?
    let packetsOut: Int?
    let packetsDroppedFull: Int?
    let lastCoreMessageAt: Date?
    let startupStage: String?
    let startupDetail: String?
    let startupDate: Date?

    static func load() -> VpnEvidence? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else { return nil }
        var stage: String?
        var startedAt: Date?
        var updatedAt: Date?
        var pid: Int?
        var packetsIn: Int?
        var packetsOut: Int?
        var packetsDroppedFull: Int?
        var lastCoreMessageAt: Date?
        var sawDiagnostics = false
        if let data = try? Data(contentsOf: container.appendingPathComponent("vpn-diagnostics.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sawDiagnostics = true
            stage = json["stage"] as? String
            startedAt = (json["startedAt"] as? Int64).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            updatedAt = (json["updatedAt"] as? Int64).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            pid = json["pid"] as? Int
            packetsIn = json["packetsIn"] as? Int
            packetsOut = json["packetsOut"] as? Int
            packetsDroppedFull = json["packetsDroppedFull"] as? Int
            lastCoreMessageAt = (json["lastCoreMessageAt"] as? Int64).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        }
        var startupStage: String?
        var startupDetail: String?
        var startupDate: Date?
        if let data = try? Data(contentsOf: container.appendingPathComponent("vpn-startup.json")),
           let record = try? JSONDecoder().decode(TunnelStartupDiagnosticRecord.self, from: data) {
            startupStage = record.stage
            startupDetail = record.detail
            startupDate = record.date
        }
        guard sawDiagnostics || startupStage != nil else { return nil }
        return VpnEvidence(
            stage: stage, startedAt: startedAt, updatedAt: updatedAt, pid: pid,
            packetsIn: packetsIn, packetsOut: packetsOut,
            packetsDroppedFull: packetsDroppedFull,
            lastCoreMessageAt: lastCoreMessageAt,
            startupStage: startupStage, startupDetail: startupDetail,
            startupDate: startupDate)
    }
}

private struct GeoFileRow: Identifiable {
    var id: String { name }
    let name: String
    let size: Int64
    let modified: Date?
}

struct DiagnosticsView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var ruleStore: RuleStore
    let navigate: (ToolsDestination) -> Void
    @State private var exportURL: URL?
    @State private var exportMessage: String?
    @State private var evidence: VpnEvidence?
    @State private var geoFiles: [GeoFileRow] = []
    @State private var isLoading = false
    @State private var isRepairingGeo = false
    @State private var refreshError: String?
    @State private var geoMessage: String?

    var body: some View {
        List {
            Section("状态") {
                labeled("VPN 状态", proxyStore.isRunning ? "运行中" : "未运行")
                labeled("当前配置", profileStore.activeProfile?.name ?? "无")
                labeled("MITM 模块", "\(mitmModuleStore.modules.filter(\.enabled).count) / \(mitmModuleStore.modules.count) 已启用")
            }
            Section("检查") {
                diagnosticsRow(icon: "network", title: "网络健康", subtitle: "出口 IP 与服务连通性", destination: .diagnosticsHealth)
                diagnosticsRow(icon: "square.stack.3d.up", title: "模块审计", subtitle: "每个模块的解析报告", destination: .diagnosticsAudit)
                diagnosticsRow(icon: "checkmark.shield", title: "配置预检", subtitle: "构建并校验当前配置", destination: .diagnosticsPreflight)
                diagnosticsRow(icon: "globe", title: "Geo 资源", subtitle: "Geo 文件检查与修复", destination: .resources)
            }
            // VPN evidence (G-M1): peak memory / last sample / last
            // stage / startup record, from the extension's files.
            Section("VPN 证据") {
                if let evidence {
                    labeled("峰值内存", "无记录（扩展未写入峰值内存）")
                    labeled("上次采样", evidence.updatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "无记录")
                    labeled("上次阶段", evidence.stage ?? "无记录")
                    if let startedAt = evidence.startedAt {
                        labeled("启动时间", startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let pid = evidence.pid {
                        labeled("扩展进程", "PID \(pid)")
                    }
                    if let packetsIn = evidence.packetsIn, let packetsOut = evidence.packetsOut {
                        labeled("收发包", "收 \(packetsIn) · 发 \(packetsOut)")
                    }
                    if let dropped = evidence.packetsDroppedFull {
                        labeled("丢包（队列满）", "\(dropped)")
                    }
                    if let lastCore = evidence.lastCoreMessageAt {
                        labeled("最后核心消息", lastCore.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let startupStage = evidence.startupStage {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启动记录")
                            Text("\(startupStage)\n\(evidence.startupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")\(evidence.startupDetail.map { "\n\($0)" } ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("无诊断记录：扩展没有写入 VPN 诊断文件（峰值内存、上次采样、上次阶段均不可用）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // Geo resources (G-M2): each file with its size, a
            // repair row, and a Resources link — upstream
            // diagnostics.dart:201-221.
            Section("Geo 资源") {
                if geoFiles.isEmpty {
                    Text("容器里没有找到 Geo 文件（MMDB / ASN / GeoSite）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(geoFiles) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.footnote)
                            Text("\(ConcordFormat.bytes(file.size))\(file.modified.map { " · 更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(isRepairingGeo ? "修复中…" : "修复 Geo 资源") {
                    Task { await repairGeo() }
                }
                .disabled(isRepairingGeo)
                diagnosticsRow(icon: "archivebox", title: "资源", subtitle: "Geo 文件检查与修复", destination: .resources)
                if let geoMessage {
                    Text(geoMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // FlClash diagnostics.dart:66: export the logs from
            // this page (the Logs page itself already has share).
            // The export action lives in the app bar (G-M3); the
            // share link appears here once exported.
            Section("日志") {
                if let exportURL {
                    ShareLink("分享导出的日志文件", item: exportURL)
                }
                if let exportMessage {
                    Text(exportMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let refreshError {
                Section {
                    Text("刷新失败：\(refreshError)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("最近问题（最近 8 条错误/警告日志）") {
                let issues = logStore.entries.filter {
                    ["ERROR", "WARN", "WARNING"].contains($0.level.uppercased())
                }.suffix(8).reversed()
                if issues.isEmpty {
                    Text("暂无错误或警告日志。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // Upstream diagnostics.dart:186-192: newest
                    // first, title = timestamp, subtitle = payload
                    // (max 4 lines, redacted).
                    ForEach(Array(issues)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ConcordFormat.time(entry.time))
                                .font(.footnote)
                            Text(LogStore.redactForExport(entry.text))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
                diagnosticsRow(icon: "doc.text", title: "日志", subtitle: "打开日志页", destination: .logs)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("可靠性中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportLogs() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出日志")
            }
        }
        .task { await refreshAll() }
    }

    /// Reloads the VPN evidence, the Geo file list and the recent
    /// issues (G-M3: refresh in the app bar with a loading state).
    private func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        evidence = VpnEvidence.load()
        scanGeoFiles()
        await logStore.refresh()
        refreshError = logStore.lastError
    }

    /// Scan the App Group container root for Geo database files
    /// (same loose name match as ResourcesView's scanGeoFiles: the
    /// core's home is the container itself).
    private func scanGeoFiles() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: container.path) else {
            geoFiles = []
            return
        }
        geoFiles = names.compactMap { name in
            let lower = name.lowercased()
            guard lower.contains("mmdb") || lower.contains("geo") || lower.contains("asn")
                    || lower.contains("country") || lower.hasSuffix(".dat") else {
                return nil
            }
            let url = container.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attributes?[.modificationDate] as? Date
            return GeoFileRow(name: name, size: size, modified: modified)
        }.sorted { $0.name < $1.name }
    }

    /// Repair Geo resources (upstream diagnostics.dart repair row:
    /// CoreController.initGeo): re-update all three Geo kinds, then
    /// rescan the container.
    private func repairGeo() async {
        isRepairingGeo = true
        defer { isRepairingGeo = false }
        for kind in ["MMDB", "ASN", "GEOSITE"] {
            await ruleStore.geoUpdate(kind: kind)
        }
        if let error = ruleStore.lastError {
            geoMessage = "修复失败：\(error)"
        } else {
            geoMessage = ruleStore.providerActionMessage ?? "Geo 资源修复已开始（后台进行）。"
        }
        scanGeoFiles()
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    /// Writes the current log entries to a .log file in tmp and
    /// offers it through a ShareLink.
    private func exportLogs() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("concord-logs-\(stamp).log")
        do {
            try logStore.exportText.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            exportMessage = "已导出 \(logStore.entries.count) 条日志。"
        } catch {
            exportURL = nil
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func diagnosticsRow(icon: String, title: String, subtitle: String, destination: ToolsDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(ConcordTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Network health

/// One health-check result (upstream health_check.dart _results):
/// the checked exit/service, a detail line, whether it passed,
/// and the probed IP (masked when hide-IP is on).
private struct HealthResult: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let passed: Bool
    let ip: String?
}

struct NetworkHealthView: View {
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var results: [HealthResult] = []
    @State private var errorMessage: String?
    @State private var isChecking = false
    @State private var checkedAt: Date?
    /// The route at check time (selected outbound + VPN state):
    /// results go stale when it moves (upstream health_check.dart
    /// _checkedRoute / routeTrackerProvider).
    @State private var checkedRoute: String?

    private var currentRoute: String {
        "\(proxyStore.selectedOutbound ?? "—")|\(proxyStore.isRunning)"
    }

    private var isStale: Bool {
        guard checkedAt != nil, let checkedRoute else { return false }
        return checkedRoute != currentRoute || !proxyStore.isRunning
    }

    var body: some View {
        List {
            Section {
                Text("依次检查直连出口、代理出口、Google 和 YouTube。检测通过内核和当前分流规则发起，不修改配置；检测成功不代表所有 App 都可用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(isChecking ? "探测中…" : "运行检查") {
                    Task { await check() }
                }
                .disabled(isChecking || !proxyStore.isRunning)
                Text(proxyStore.isRunning ? "依次检查直连出口、代理出口、Google 和 YouTube。" : "请先启动 VPN，再运行检查。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let checkedAt {
                    labeled("检查于", checkedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if isStale {
                Section {
                    Text("连接或策略已变化，请重新检查。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("检查结果") {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if results.isEmpty {
                    Text(isChecking ? "正在探测…" : "尚未探测")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                Text(staleDetail(for: result))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Upstream trailing verdict: ✓ passed,
                            // ! failed, — while stale.
                            Text(isStale ? "—" : (result.passed ? "✓" : "!"))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(result.passed ? .green : .red)
                        }
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("网络健康")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await check() }
                } label: {
                    if isChecking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isChecking || !proxyStore.isRunning)
                .accessibilityLabel("运行检查")
            }
        }
        .task {
            // G-M7: the check is disabled unless the VPN is running
            // (upstream healthRequiresVpn) — no auto-run with the
            // VPN off.
            if proxyStore.isRunning {
                await check()
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    /// The result detail line: the IP (masked when hide-IP is on)
    /// plus the chains/status detail; while stale, the
    /// route-changed note replaces every detail (upstream).
    private func staleDetail(for result: HealthResult) -> String {
        if isStale { return "连接或策略已变化，请重新检查。" }
        if let ip = result.ip {
            let shown = settingsStore.hideIp ? "••••••••" : ip
            return result.detail.isEmpty ? shown : "\(shown)\n\(result.detail)"
        }
        return result.detail
    }

    /// Probes BOTH outbounds through the core (upstream
    /// health_check.dart lookupOutboundIp on directOutbound and
    /// routedOutbound, 10 s each) plus Google/YouTube service
    /// checks. The direct exit is the core's DIRECT outbound — a
    /// routing decision, not a phone-egress measurement (the old
    /// client-side URLSession probe said "手机直连" while the VPN
    /// tunnel still carried the traffic).
    private func check() async {
        guard proxyStore.isRunning else {
            errorMessage = "请先启动 VPN，再运行检查。"
            return
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        results = []
        errorMessage = nil
        checkedAt = Date()
        checkedRoute = currentRoute
        // Direct exit via the core's DIRECT outbound.
        do {
            let direct = try await client.probeOutboundIp(proxy: "DIRECT", timeout: 10_000)
            if let error = direct.error {
                results.append(HealthResult(title: "直连出口", detail: error, passed: false, ip: nil))
            } else {
                results.append(HealthResult(
                    title: "直连出口",
                    detail: direct.chains.isEmpty ? "" : direct.chains.joined(separator: " → "),
                    passed: !direct.body.isEmpty,
                    ip: direct.body.isEmpty ? nil : direct.body))
            }
        } catch {
            results.append(HealthResult(
                title: "直连出口", detail: error.localizedDescription, passed: false, ip: nil))
        }
        // Routed exit via the core (unpinned proxy = routed).
        do {
            let routed = try await client.probeOutboundIp(timeout: 10_000)
            if let error = routed.error {
                results.append(HealthResult(title: "当前规则出口", detail: error, passed: false, ip: nil))
            } else {
                results.append(HealthResult(
                    title: "当前规则出口",
                    detail: routed.chains.isEmpty ? "" : routed.chains.joined(separator: " → "),
                    passed: !routed.body.isEmpty,
                    ip: routed.body.isEmpty ? nil : routed.body))
            }
        } catch {
            results.append(HealthResult(
                title: "当前规则出口", detail: error.localizedDescription, passed: false, ip: nil))
        }
        // Google + YouTube service checks.
        do {
            let proxy = proxyStore.selectedOutbound ?? "DIRECT"
            let services = try await client.probeServices(proxy: proxy, names: ["google", "youtube"], timeout: 10_000)
            for name in ["google", "youtube"] {
                guard let item = services.first(where: { $0.name.lowercased() == name }) else {
                    results.append(HealthResult(title: name, detail: "服务失败", passed: false, ip: nil))
                    continue
                }
                let statusText = serviceStatusLabel(item.status)
                var detail = statusText
                if let delay = item.delay { detail += " · \(delay) ms" }
                if let chains = item.chains, !chains.isEmpty { detail += "\n\(chains.joined(separator: " → "))" }
                results.append(HealthResult(
                    title: name, detail: detail,
                    passed: item.status == "available", ip: nil))
            }
        } catch {
            for name in ["google", "youtube"] {
                results.append(HealthResult(title: name, detail: error.localizedDescription, passed: false, ip: nil))
            }
        }
    }

    private func serviceStatusLabel(_ status: String) -> String {
        switch status {
        case "available": return "可用"
        case "unavailable": return "不可用"
        case "restricted": return "受限"
        case "disallowed-isp": return "运营商限制"
        case "blocked": return "被墙"
        case "unsupported-region": return "地区不支持"
        case "originals-only": return "仅自制剧"
        case "coming-soon": return "即将推出"
        case "timeout": return "超时"
        case "failed": return "失败"
        case "": return "未判断"
        default: return status
        }
    }
}

// MARK: - Module audit

struct ModuleAuditView: View {
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    let navigate: (ToolsDestination) -> Void
    /// Re-parsed reports, keyed by module id: refresh() re-runs
    /// the audit for every module (upstream module_audit.dart
    /// re-audits on appear and whenever the modules change).
    @State private var reports: [String: ModuleAudit] = [:]
    @State private var checkedAt: Date?
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section {
                Text("检查本地规则、跳过的条目和缺失的脚本资源。这是离线解析检查，不代表脚本已执行或规则已命中。点详情可查看内核校验。HTTPS 重写还需要信任证书和匹配的域名；使用证书固定的 App 可能拒绝解密。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    navigate(.mitmModules)
                } label: {
                    HStack {
                        Text("MITM 模块")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if let checkedAt {
                    Text("上次检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if mitmModuleStore.modules.isEmpty {
                Section {
                    Text("没有 MITM 模块。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(mitmModuleStore.modules) { module in
                Section(module.name) {
                    labeled("状态", module.enabled ? "已启用" : "已禁用")
                    if let audit = reports[module.id] {
                        // Parse verdict (upstream module_audit.dart:
                        // needs-attention vs passed).
                        let needsAttention = !audit.skipped.isEmpty || !audit.missingResources.isEmpty
                        labeled("解析结果", needsAttention ? "存在需要处理的条目，请查看详情。" : "已解析，运行效果仍需验证。")
                        labeled("已解析规则数", "\(audit.rules)")
                        labeled("脚本数", "\(audit.scripts)")
                        labeled("跳过的条目数", "\(audit.skipped.count)")
                        labeled("缺失资源数", "\(audit.missingResources.count)")
                        labeled("MITM 域名条目数", "\(audit.hostnames)")
                        if !audit.skipped.isEmpty {
                            Text("跳过 \(audit.skipped.count) 项：")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(audit.skipped, id: \.self) { skip in
                                Text(skip)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !audit.missingResources.isEmpty {
                            Text("缺失资源 \(audit.missingResources.count) 个：\(audit.missingResources.joined(separator: "、"))")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if audit.skipped.isEmpty && audit.missingResources.isEmpty {
                            Text("解析正常，无跳过或缺失。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("模块文本缺失，请重新导入。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    NavigationLink("查看详情和不支持的条目") {
                        MitmModuleDetailView(moduleId: module.id).concordNavBarBackground()
                    }
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("模块审计")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("重新审计")
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var fresh: [String: ModuleAudit] = [:]
        for module in mitmModuleStore.modules {
            if let audit = mitmModuleStore.audit(module: module) {
                fresh[module.id] = audit
            }
        }
        reports = fresh
        checkedAt = Date()
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Config preflight

struct ConfigPreflightView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    let navigate: (ToolsDestination) -> Void
    @State private var issues: [ConcordIssue]?
    @State private var builtLength: Int?
    @State private var message: String?
    @State private var isRunning = false
    /// Inputs the last check ran against (upstream
    /// health_check.dart _checkedInputs: profile / patch config /
    /// MITM modules): when they move, the result is stale.
    @State private var checkedSignature: String?

    /// The current inputs, as a signature string. The patch config
    /// is not readable from this page, so the signature covers the
    /// active profile and the MITM modules (names + enabled state).
    private var currentSignature: String {
        let profile = profileStore.activeProfile?.name ?? "—"
        let modules = mitmModuleStore.modules
            .map { "\($0.id)=\($0.enabled ? 1 : 0)" }
            .joined(separator: ",")
        return "\(profile)|\(modules)"
    }

    private var isStale: Bool {
        guard let checkedSignature else { return false }
        return checkedSignature != currentSignature
    }

    var body: some View {
        List {
            Section {
                Text("用 profile.build 构建当前配置的完整文本，再用 config.validate 校验。预检检查配置解析，不验证节点是否可达；资源文件单独检查。实际应用时，内核仍会校验完整路由配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("预检结果") {
                if let builtLength {
                    labeled("构建后配置", "\(builtLength) 字节")
                }
                if isStale {
                    Text("配置已变化，请重新预检。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let issues {
                    if issues.isEmpty {
                        Text("配置解析通过。")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(issues.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issues[index].message)
                                if let path = issues[index].path {
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("尚未预检")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button(isRunning ? "预检中…" : "开始预检") {
                    Task { await run() }
                }
                .disabled(isRunning)
            }
            // Config protection (upstream health_check.dart): the
            // core refuses a bad new config and keeps the running
            // one; this section states that and links Resources.
            Section("配置拒绝保护") {
                Text("内核在应用前拒绝新配置时，会保留现有运行配置，并在可用时恢复之前选中的配置。这不能恢复被系统终止的 VPN，也不能代替备份。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    navigate(.resources)
                } label: {
                    HStack {
                        Text("资源")
                        Spacer()
                        Text("Geo 资源检查")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("配置预检")
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func run() async {
        guard let profile = profileStore.activeProfile,
              let path = profileStore.absolutePathForPreflight(profile) else {
            message = "没有可预检的当前配置"
            return
        }
        isRunning = true
        defer { isRunning = false }
        checkedSignature = currentSignature
        do {
            let text = try await profileStore.client.profileBuild(profilePath: path)
            builtLength = text.utf8.count
            // config.validate reads a file: write the built text into
            // the App Group so the extension can read it.
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID) else {
                message = "App Group 容器不可用"
                return
            }
            let tempURL = container.appendingPathComponent("preflight.yaml")
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            issues = try await profileStore.client.configValidate(profilePath: tempURL.path)
            message = nil
        } catch {
            issues = nil
            message = "预检失败：\(error.localizedDescription)"
        }
    }
}
