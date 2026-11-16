import SwiftUI

// MARK: - Rules (FlClash: config/rules.dart + rule providers)
// FlClash shows the rules in force (rule.list, in match order) and the
// rule providers (provider.list, type == rule). Rules are read-only
// here — editing a rule means editing the profile YAML (Profiles page),
// as in FlClash's editor.

struct RulesView: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient

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
                            }
                        }
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
        }
    }
}
