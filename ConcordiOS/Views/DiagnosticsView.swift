import SwiftUI

// MARK: - Diagnostics (FlClash: Tools -> 可靠性中心)
// Status + profile + MITM module counts, network health checks,
// per-module parse reports, config preflight, Geo resource check
// and recent issues. VPN evidence (peak memory, last sample,
// last stage) has no source: our extension does not write a VPN
// diagnostics file, so the page says so honestly instead of
// inventing numbers.

struct DiagnosticsView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore
    @EnvironmentObject private var logStore: LogStore
    let navigate: (ToolsDestination) -> Void

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
            Section("VPN 证据") {
                Text("无诊断记录：扩展没有写入 VPN 诊断文件（峰值内存、上次采样、上次阶段均不可用）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("最近问题（最近 8 条错误/警告日志）") {
                let issues = logStore.entries.filter {
                    ["ERROR", "WARN", "WARNING"].contains($0.level.uppercased())
                }.suffix(8)
                if issues.isEmpty {
                    Text("暂无错误或警告日志。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(issues) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.footnote)
                                .lineLimit(2)
                            Text("\(entry.level.uppercased()) · \(ConcordFormat.time(entry.time))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("可靠性中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func diagnosticsRow(icon: String, title: String, subtitle: String, destination: ToolsDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Network health

struct NetworkHealthView: View {
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var proxyStore: ProxyStore
    @State private var exitIp: ConcordOutboundIp?
    @State private var exitError: String?
    @State private var services: [ConcordServiceItem] = []
    @State private var servicesError: String?
    @State private var isChecking = false

    var body: some View {
        List {
            Section {
                Text("出口 IP 走当前出站代理探测；服务检查用当前选中的节点测 Google、YouTube 等。核心没有「直连出口」的探测接口，直连检查暂不可用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("出口 IP") {
                if let exitIp {
                    labeled("IP", exitIp.body)
                    labeled("延迟", "\(exitIp.delay) ms")
                    if !exitIp.chains.isEmpty {
                        labeled("链路", exitIp.chains.joined(separator: " → "))
                    }
                    if let error = exitIp.error {
                        Text("探测返回错误：\(error)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } else if let exitError {
                    Text(exitError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("尚未探测")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("服务检查") {
                if let servicesError {
                    Text(servicesError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if services.isEmpty {
                    Text("尚未探测")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(item.status)
                                .foregroundStyle(item.status.lowercased() == "ok" ? .green : .red)
                            if let delay = item.delay {
                                Text("\(delay) ms")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                    }
                }
            }
            Section {
                Button(isChecking ? "探测中…" : "开始探测") {
                    Task { await check() }
                }
                .disabled(isChecking)
            }
        }
        .navigationTitle("网络健康")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            exitIp = try await client.probeOutboundIp()
            exitError = nil
        } catch {
            exitIp = nil
            exitError = "出口 IP 探测失败：\(error.localizedDescription)"
        }
        do {
            let proxy = proxyStore.selectedOutbound ?? "DIRECT"
            services = try await client.probeServices(proxy: proxy, names: ["google", "youtube"])
            servicesError = nil
        } catch {
            services = []
            servicesError = "服务检查失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Module audit

struct ModuleAuditView: View {
    @EnvironmentObject private var mitmModuleStore: MitmModuleStore

    var body: some View {
        List {
            Section {
                Text("每个模块重新解析后的报告：贡献的规则、脚本、域名数，被跳过的内容，以及缺失的已下载资源。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    if let audit = mitmModuleStore.audit(module: module) {
                        labeled("规则", "\(audit.rules) 条")
                        labeled("脚本", "\(audit.scripts) 个")
                        labeled("域名", "\(audit.hostnames) 个")
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
                }
            }
        }
        .navigationTitle("模块审计")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var issues: [ConcordIssue]?
    @State private var builtLength: Int?
    @State private var message: String?
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                Text("用 profile.build 构建当前配置的完整文本，再用 config.validate 校验。构建失败或校验问题会列在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("预检结果") {
                if let builtLength {
                    labeled("构建后配置", "\(builtLength) 字节")
                }
                if let issues {
                    if issues.isEmpty {
                        Text("校验通过，没有问题。")
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
        }
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
