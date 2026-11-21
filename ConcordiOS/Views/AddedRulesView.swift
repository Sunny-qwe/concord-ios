import SwiftUI

// MARK: - Added rules (FlClash: Tools -> 进阶配置 -> 附加规则)
// Extra Clash rules prepended before the profile's own rules via
// the config.apply overlay (see AddedRulesStore). The list is
// validated locally (type / value / policy) and takes effect at
// the next VPN start.

struct AddedRulesView: View {
    @StateObject private var rulesStore = AddedRulesStore()
    @State private var newRule = ""
    @State private var errorMessage: String?
    @State private var searchText = ""

    /// Search filters the shown rows (FlClash rules.dart search);
    /// drag reorder only applies to the unfiltered list.
    private var visibleRules: [String] {
        guard !searchText.isEmpty else { return rulesStore.rules }
        return rulesStore.rules.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                Text("附加规则会排在订阅自带规则之前，优先匹配。格式：类型,值,策略，例如 DOMAIN-SUFFIX,example.com,PROXY。保存后重启 VPN 生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("附加规则（\(rulesStore.rules.count) 条）") {
                if searchText.isEmpty {
                    ForEach(rulesStore.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                    }
                    .onDelete { offsets in
                        rulesStore.rules.remove(atOffsets: offsets)
                        rulesStore.save()
                    }
                    .onMove { from, to in
                        rulesStore.rules.move(fromOffsets: from, toOffset: to)
                        rulesStore.save()
                    }
                } else {
                    if visibleRules.isEmpty {
                        Text("没有匹配的规则")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleRules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let rule = visibleRules[index]
                            rulesStore.rules.removeAll { $0 == rule }
                        }
                        rulesStore.save()
                    }
                }
                HStack {
                    TextField("DOMAIN-SUFFIX,example.com,PROXY", text: $newRule)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("添加") {
                        addRule()
                    }
                    .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .navigationTitle("附加规则")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索规则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private func addRule() {
        let rule = newRule.trimmingCharacters(in: .whitespaces)
        if let problem = AddedRulesStore.validationError(for: rule) {
            errorMessage = problem
            return
        }
        if rulesStore.rules.contains(rule) {
            errorMessage = "这条规则已存在"
            return
        }
        errorMessage = nil
        rulesStore.rules.append(rule)
        rulesStore.save()
        newRule = ""
    }
}
