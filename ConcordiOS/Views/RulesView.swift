import SwiftUI

// MARK: - Rules (FlClash: config/rules.dart + rule providers)
// FlClash shows the rules in force (rule.list, in match order) and the
// rule providers (provider.list, type == rule). Rules are read-only
// here — editing a rule means editing the profile YAML (Profiles page),
// as in FlClash's editor.

struct RulesView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient
    /// Provider-detail page (upstream EditorPage) — local state,
    /// not the shared ruleStore.providerDetail (same P2
    /// cross-trigger as ProvidersView: EditProviderView's detail
    /// load must not present anything here). A Bool + stored
    /// value, not navigationDestination(item:): ConcordProviderInfo
    /// is not Hashable (and its model file is outside this change),
    /// so the item form cannot be used.
    @State private var detailProvider: ConcordProviderInfo?
    @State private var showDetailPage = false

    var body: some View {
        // No NavigationStack here on purpose: this page is pushed
        // from the Tools tab, whose stack provides the navigation
        // bar. (The sheet sub-views below keep their own stacks.)
        List {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("规则为示例数据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("规则集提供方（provider.list）") {
                    if ruleStore.ruleProviders.isEmpty {
                        Text("暂无规则提供方")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ruleStore.ruleProviders) { provider in
                            Button {
                                Task {
                                    await ruleStore.loadProviderDetail(provider)
                                    if let detail = ruleStore.providerDetail {
                                        detailProvider = detail
                                        ruleStore.providerDetail = nil
                                        showDetailPage = true
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.name)
                                            .font(.footnote)
                                        Text("\(provider.behavior ?? provider.format ?? "") · \(provider.count) 条")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(provider.vehicleType)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("详情") {
                                    Task {
                                        await ruleStore.loadProviderDetail(provider)
                                        if let detail = ruleStore.providerDetail {
                                            detailProvider = detail
                                            ruleStore.providerDetail = nil
                                            showDetailPage = true
                                        }
                                    }
                                }
                                .tint(ConcordTheme.accent)
                                Button("更新") {
                                    Task { await ruleStore.updateProvider(provider) }
                                }
                                .tint(ConcordTheme.accent)
                                Button("重新编译") {
                                    Task { await ruleStore.compileRuleSet(provider) }
                                }
                                .tint(ConcordTheme.accent)
                            }
                        }
                    }
                    if let message = ruleStore.providerActionMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ruleStore.filtered.enumerated()), id: \.element.id) { index, rule in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(rule.type)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12), in: Capsule())
                                        Text(rule.payload.isEmpty ? "—" : rule.payload)
                                            .font(.footnote)
                                            .lineLimit(2)
                                    }
                                    Text("→ \(rule.target)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .listStyle(.insetGrouped)
            .navigationTitle("规则")
            .navigationBarTitleDisplayMode(.inline)
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
            }
            .navigationDestination(isPresented: $showDetailPage) {
                if let detail = detailProvider {
                    ProviderDetailView(provider: detail)
                        .concordNavBarBackground()
                }
            }
    }
}

// One provider's full detail (provider.get). Unlike provider.list,
// the result carries `subscriptionInfo` when the provider is a
// subscription. A pushed page (upstream EditorPage) — no own
// NavigationStack, no 完成 button.
struct ProviderDetailView: View {
    let provider: ConcordProviderInfo

    var body: some View {
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
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
