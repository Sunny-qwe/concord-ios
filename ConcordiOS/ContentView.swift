import SwiftUI

// MARK: - Full-interface skeleton (FlClash-like)
// Tabs: 首页/开关, 代理, 规则, 连接, 流量, 日志, 设置/订阅导入
// Scaffold only: views show placeholder data from ProxyStore / ConfigStore.
// TODO: wire each tab to live Concord data once the iOS staticlib API exists.

struct ContentView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "power") }
            ProxyView()
                .tabItem { Label("代理", systemImage: "globe") }
            RulesView()
                .tabItem { Label("规则", systemImage: "list.bullet") }
            ConnectionsView()
                .tabItem { Label("连接", systemImage: "arrow.left.arrow.right") }
            TrafficView()
                .tabItem { Label("流量", systemImage: "chart.bar") }
            LogsView()
                .tabItem { Label("日志", systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gear") }
        }
    }
}

// MARK: - 首页 / 开关

struct HomeView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(proxyStore.isRunning ? "运行中" : "已停止")
                                .font(.headline)
                            Text(configStore.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(proxyStore.isRunning ? "停止" : "启动") {
                            proxyStore.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Section("当前配置") {
                    Text(configStore.lastUpdated.map { "上次更新：\($0.formatted())" } ?? "尚未导入配置")
                }
                Section("流量（占位）") {
                    Text("上行：\(proxyStore.uploadBytes) B")
                    Text("下行：\(proxyStore.downloadBytes) B")
                }
            }
            .navigationTitle("Concord iOS")
        }
    }
}

// MARK: - 代理

struct ProxyView: View {
    @EnvironmentObject private var proxyStore: ProxyStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(proxyStore.groups) { group in
                    Section("\(group.name) · \(group.type)") {
                        ForEach(group.nodes) { node in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(node.name)
                                    Text(node.type).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if group.selectedNodeName == node.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { proxyStore.select(node: node, in: group) }
                        }
                    }
                }
            }
            .navigationTitle("代理")
            .toolbar {
                Button("测速") { proxyStore.testLatency() }
            }
        }
    }
}

// MARK: - 规则

struct RulesView: View {
    var body: some View {
        NavigationStack {
            List {
                // TODO: load rules from the active config.yaml and show
                // hit counts once Concord exposes them on iOS.
                Text("规则列表尚未接通 Concord（占位）")
                Text("GEOIP / GEOSITE / DOMAIN 等规则将从 config.yaml 解析")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("规则")
        }
    }
}

// MARK: - 连接

struct ConnectionsView: View {
    @EnvironmentObject private var proxyStore: ProxyStore

    var body: some View {
        NavigationStack {
            List {
                if proxyStore.connections.isEmpty {
                    Text("暂无活动连接（占位）")
                } else {
                    ForEach(proxyStore.connections) { conn in
                        VStack(alignment: .leading) {
                            Text(conn.host)
                            Text("\(conn.rule) · \(conn.proxy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("连接")
        }
    }
}

// MARK: - 流量

struct TrafficView: View {
    @EnvironmentObject private var proxyStore: ProxyStore

    var body: some View {
        NavigationStack {
            List {
                Text("上行：\(proxyStore.uploadBytes) B")
                Text("下行：\(proxyStore.downloadBytes) B")
                Text("实时流量图尚未实现（占位）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("流量")
        }
    }
}

// MARK: - 日志

struct LogsView: View {
    @EnvironmentObject private var proxyStore: ProxyStore

    var body: some View {
        NavigationStack {
            List(proxyStore.logs, id: \.self) { log in
                Text(log).font(.caption)
            }
            .navigationTitle("日志")
        }
    }
}

// MARK: - 设置 / 订阅导入

struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @State private var urlText = ""
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅导入") {
                    TextField("订阅链接 (Clash/mihomo YAML)", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("导入订阅") {
                        Task { await configStore.importSubscription(from: urlText) }
                    }
                    Button("导入本地配置文件") { showImporter = true }
                    Text(configStore.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("Concord iOS 骨架 v0.1.0")
                    Text("核心：chen08209/concord（Rust，GPL-3.0-or-later）")
                    Text("状态：骨架，未接通 Concord，未在真机验证")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.yaml]) { result in
                // TODO: handle .yml as well; validate YAML before saving.
                if case .success(let url) = result,
                   let data = try? Data(contentsOf: url) {
                    configStore.importLocalFile(data: data)
                }
            }
        }
    }
}
