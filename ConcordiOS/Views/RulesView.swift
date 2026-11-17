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
        NavigationStack {
            List {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("规则为示例数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("规则集提供方（provider.list）") {
                    if ruleStore.ruleProviders.isEmpty {
                        Text("暂无规则提供方")
                            .font(.caption)
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
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(provider.vehicleType)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("重新编译") {
                                    Task { await ruleStore.compileRuleSet(provider) }
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    if let message = ruleStore.providerActionMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("过滤表达式校验（validate.filters）") {
                    TextEditor(text: $filterText)
                        .frame(minHeight: 64)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("每行一条过滤表达式：代理组 filter: 用的反引号分隔正则列表，例如 (?i)港|hk 或 hk`jp。空行会被忽略。")
                        .font(.caption)
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
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = ruleStore.filterCheckMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if !ruleStore.filterIssues.isEmpty {
                        ForEach(ruleStore.filterIssues, id: \.message) { issue in
                            Text("第 \(issue.index.map { "\($0 + 1)" } ?? "？") 条：\(issue.message)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("路由复核（route.check）") {
                    if routedServices.isEmpty {
                        Text("暂无可复核的路由：先在仪表盘运行服务检测（probe.services），探测会记录路由命中；之后回来点「重新验证」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(routedServices) { service in
                            HStack {
                                Text(service.name)
                                Spacer()
                                Text("\(service.hits?.count ?? 0) 条命中")
                                    .font(.caption)
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
                                    .font(.caption)
                                    .foregroundStyle(held ? .green : .orange)
                            }
                        }
                        Text("epoch \(result.epoch) / version \(result.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = ruleStore.routeCheckMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("route.check 不是测网址的工具：它复核的是上一次探测记录的路由命中（host → 代理 → 出口），看配置变化后这些路由是否还走原来的出口。")
                        .font(.caption)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ruleStore.filtered.enumerated()), id: \.element.id) { index, rule in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(rule.type)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12), in: Capsule())
                                        Text(rule.payload.isEmpty ? "—" : rule.payload)
                                            .font(.body)
                                            .lineLimit(2)
                                    }
                                    Text("→ \(rule.target)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    if let updated = ruleStore.lastUpdated {
                        Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = ruleStore.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
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
            .task { if ruleStore.rules.isEmpty { await ruleStore.refresh() } }
            .sheet(isPresented: Binding(
                get: { ruleStore.dumpedRuleSetName != nil },
                set: { if !$0 { ruleStore.dumpedRuleSetName = nil } }
            )) {
                RuleSetDumpView(name: ruleStore.dumpedRuleSetName ?? "", text: ruleStore.dumpedRuleSetText ?? "")
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
