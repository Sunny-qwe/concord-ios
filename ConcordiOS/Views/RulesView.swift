import SwiftUI

// MARK: - Rules (FlClash: config/rules.dart + rule providers)
// FlClash shows the rules in force (rule.list, in match order) and the
// rule providers (provider.list, type == rule). Rules are read-only
// here — editing a rule means editing the profile YAML (Profiles page),
// as in FlClash's editor.

struct RulesView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    /// Filter expressions to validate, one per line (validate.filters).
    @State private var filterText = ""
    @State private var filterExtractMessage: String?

    /// The non-empty filter lines from the editor.
    private var filterLines: [String] {
        filterText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Services whose last probe.services answer recorded route hits
    /// (route.check re-validates those hits).
    private var routedServices: [ConcordServiceItem] {
        trafficStore.services.filter { !($0.hits ?? []).isEmpty }
    }

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (The sheet sub-views below keep their own stacks.)
        List {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("规则为示例数据")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("规则集提供方（provider.list）") {
                    if ruleStore.ruleProviders.isEmpty {
                        Text("暂无规则提供方")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ruleStore.ruleProviders) { provider in
                            Button {
                                Task { await ruleStore.dumpRuleSet(provider) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.name)
                                        Text("\(provider.behavior ?? provider.format ?? "") · \(provider.count) 条")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(provider.vehicleType)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("详情") {
                                    Task { await ruleStore.loadProviderDetail(provider) }
                                }
                                .tint(.blue)
                                Button("健康检查") {
                                    Task { await ruleStore.healthCheckProvider(provider) }
                                }
                                .tint(.green)
                                Button("重新编译") {
                                    Task { await ruleStore.compileRuleSet(provider) }
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    if let message = ruleStore.providerActionMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Section("过滤表达式校验（validate.filters）") {
                    TextEditor(text: $filterText)
                        .frame(minHeight: 64)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Text("每行一条过滤表达式：代理组 filter: 用的反引号分隔正则列表，例如 (?i)港|hk 或 hk`jp。空行会被忽略。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("从当前配置提取") {
                            Task {
                                switch await profileStore.extractActiveProfileFilters() {
                                case .success(let pairs):
                                    if pairs.isEmpty {
                                        filterExtractMessage = "当前配置里没有带 filter 的代理组"
                                    } else {
                                        filterText = pairs.map { $0.filter }.joined(separator: "\n")
                                        filterExtractMessage = "已提取 \(pairs.count) 条（组：\(pairs.map { $0.group }.joined(separator: "、"))）"
                                    }
                                case .failure(let error):
                                    filterExtractMessage = "提取失败：\(error.localizedDescription)"
                                }
                            }
                        }
                        Button("校验") {
                            Task { await ruleStore.validateFilters(filterLines) }
                        }
                        .disabled(filterLines.isEmpty)
                    }
                    if let message = filterExtractMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let message = ruleStore.filterCheckMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !ruleStore.filterIssues.isEmpty {
                        ForEach(ruleStore.filterIssues, id: \.message) { issue in
                            Text("第 \(issue.index.map { "\($0 + 1)" } ?? "？") 条：\(issue.message)")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("路由复核（route.check）") {
                    if routedServices.isEmpty {
                        Text("暂无可复核的路由：先在仪表盘运行服务检测（probe.services），探测会记录路由命中；之后回来点「重新验证」。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(routedServices) { service in
                            HStack {
                                Text(service.name)
                                Spacer()
                                Text("\(service.hits?.count ?? 0) 条命中")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("重新验证这些路由") {
                            Task {
                                await ruleStore.routeCheck(
                                    routes: routedServices.map { $0.hits ?? [] },
                                    labels: routedServices.map { $0.name })
                            }
                        }
                    }
                    if let result = ruleStore.routeCheckResult {
                        ForEach(Array(zip(ruleStore.routeCheckLabels, result.held).enumerated()), id: \.offset) { item in
                            let (label, held) = item.element
                            HStack {
                                Text(label)
                                Spacer()
                                Text(held ? "仍有效" : "已变化")
                                    .font(.system(size: 10))
                                    .foregroundStyle(held ? .green : .orange)
                            }
                        }
                        Text("epoch \(result.epoch) / version \(result.version)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let message = ruleStore.routeCheckMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("route.check 不是测网址的工具：它复核的是上一次探测记录的路由命中（host → 代理 → 出口），看配置变化后这些路由是否还走原来的出口。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("路由状态（route.watch）") {
                    if let stamp = ruleStore.routeStamp {
                        LabeledContent("epoch", value: "\(stamp.epoch)")
                        LabeledContent("version", value: "\(stamp.version)")
                        LabeledContent("监听器", value: stamp.running ? "运行中" : "未运行")
                    } else {
                        Text("尚未读取路由状态")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button("刷新路由状态") {
                        Task { await ruleStore.refreshRouteStamp() }
                    }
                    if let message = ruleStore.routeStampMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("路由表每次变化时 epoch / version 都会推进；监听器状态表示路由监听是否在运行。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("生效规则（rule.list，按匹配顺序）") {
                    Picker("类型", selection: $ruleStore.typeFilter) {
                        ForEach(ruleStore.ruleTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    if ruleStore.filtered.isEmpty {
                        Text("没有匹配的规则")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ruleStore.filtered.enumerated()), id: \.element.id) { index, rule in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(rule.type)
                                            .font(.system(size: 10))
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12), in: Capsule())
                                        Text(rule.payload.isEmpty ? "—" : rule.payload)
                                            .font(.system(size: 13))
                                            .lineLimit(2)
                                    }
                                    Text("→ \(rule.target)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    if let updated = ruleStore.lastUpdated {
                        Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let error = ruleStore.lastError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .listStyle(.insetGrouped)
            .navigationTitle("规则")
            .searchable(text: $ruleStore.searchText, prompt: "搜索规则内容或目标")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await ruleStore.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await ruleStore.refresh() }
            .task {
                if ruleStore.rules.isEmpty { await ruleStore.refresh() }
                await ruleStore.refreshRouteStamp()
            }
            .sheet(isPresented: Binding(
                get: { ruleStore.dumpedRuleSetName != nil },
                set: { if !$0 { ruleStore.dumpedRuleSetName = nil } }
            )) {
                RuleSetDumpView(name: ruleStore.dumpedRuleSetName ?? "", text: ruleStore.dumpedRuleSetText ?? "")
            }
            .sheet(isPresented: Binding(
                get: { ruleStore.providerDetail != nil },
                set: { if !$0 { ruleStore.providerDetail = nil } }
            )) {
                if let detail = ruleStore.providerDetail {
                    ProviderDetailView(provider: detail)
                }
            }
    }
}

// Dumped rules of one rule-set provider (ruleSet.dump).
struct RuleSetDumpView: View {
    let name: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "该规则集没有可显示的规则" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// One provider's full detail (provider.get). Unlike provider.list,
// the result carries `subscriptionInfo` when the provider is a
// subscription.
struct ProviderDetailView: View {
    let provider: ConcordProviderInfo
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ruleStore: RuleStore

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("名称", value: provider.name)
                LabeledContent("类型", value: provider.type)
                LabeledContent("传输", value: provider.vehicleType)
                LabeledContent("条目", value: "\(provider.count)")
                LabeledContent("路径", value: provider.path)
                if let updatedAt = provider.updatedAt {
                    LabeledContent("更新于", value: Date(timeIntervalSince1970: TimeInterval(updatedAt)).formatted(date: .abbreviated, time: .shortened))
                }
                if let testUrl = provider.testUrl {
                    LabeledContent("测速地址", value: testUrl)
                }
                if let expectedStatus = provider.expectedStatus {
                    LabeledContent("期望状态码", value: expectedStatus)
                }
                if let behavior = provider.behavior {
                    LabeledContent("行为", value: behavior)
                }
                if let format = provider.format {
                    LabeledContent("格式", value: format)
                }
                if let subscription = provider.subscriptionInfo {
                    Section("订阅流量") {
                        LabeledContent("已上传", value: ByteCountFormatter.string(fromByteCount: subscription.upload, countStyle: .file))
                        LabeledContent("已下载", value: ByteCountFormatter.string(fromByteCount: subscription.download, countStyle: .file))
                        LabeledContent("总量", value: ByteCountFormatter.string(fromByteCount: subscription.total, countStyle: .file))
                        LabeledContent("到期", value: Date(timeIntervalSince1970: TimeInterval(subscription.expire)).formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Button("健康检查（provider.healthCheck）") {
                        Task { await ruleStore.healthCheckProvider(provider) }
                    }
                    Text("健康检查在后台进行，触发后稍等再刷新列表查看。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let message = ruleStore.providerActionMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
