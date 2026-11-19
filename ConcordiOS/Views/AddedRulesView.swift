import SwiftUI

// MARK: - Added rules (FlClash: Tools -> 进阶配置 -> 附加规则)
// Extra Clash rules prepended before the profile's own rules via
// the config.apply overlay (see AddedRulesStore). The list is
// validated locally (type / value / policy) and takes effect at
// the next VPN start, or immediately when the tunnel runs and the
// user taps 重新应用.

struct AddedRulesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var rulesStore = AddedRulesStore()
    @State private var newRule = ""
    @State private var errorMessage: String?
    @State private var applyMessage: String?

    var body: some View {
        List {
            Section {
                Text("附加规则会排在订阅自带规则之前，优先匹配。格式：类型,值,策略，例如 DOMAIN-SUFFIX,example.com,PROXY。保存后重启 VPN 生效，VPN 运行时可点「重新应用」立即生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("附加规则（\(rulesStore.rules.count) 条）") {
                ForEach(rulesStore.rules, id: \.self) { rule in
                    Text(rule)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    rulesStore.rules.remove(atOffsets: offsets)
                    rulesStore.save()
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
            Section {
                Button("校验全部规则") {
                    validateAll()
                }
                Button("重新应用（VPN 运行时立即生效）") {
                    Task {
                        applyMessage = await profileStore.reapplyActive() ?? "VPN 未运行：已保存，下次启动 VPN 时生效"
                    }
                }
                if let applyMessage {
                    Text(applyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("附加规则")
        .navigationBarTitleDisplayMode(.inline)
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

    private func validateAll() {
        for rule in rulesStore.rules {
            if let problem = AddedRulesStore.validationError(for: rule) {
                errorMessage = "\(rule)：\(problem)"
                return
            }
        }
        errorMessage = rulesStore.rules.isEmpty ? "没有规则可校验" : "全部 \(rulesStore.rules.count) 条规则格式正确"
    }
}
