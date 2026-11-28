import SwiftUI

// MARK: - Edit provider (FlClash providers.dart _EditProviderView)
//
// FlClash's edit opens the provider's text in the editor and saves
// it back with provider.sideLoad. The core does not expose a
// provider URL (ConcordProviderInfo has no url field), so this form
// takes the name plus a fresh link: saving downloads the link and
// side-loads the content under that name (provider.sideLoad).
// Renaming alone via that flow creates the provider under the new
// name — the old name is left alone, since the core has no
// rename/delete for providers. A TRUE rename (v0.2.156, upstream
// ClashProviders.put) is offered in the "重命名提供方" section for
// confined rule providers: it renames the ClashProvider record and
// rewrites the RULE-SET references in every subscription mapping
// the record.

struct EditProviderView: View {
    let provider: ConcordProviderInfo

    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    /// Custom subscriptions, for resolving a confined rule
    /// provider back to its owning definition + ClashProvider
    /// record (v0.2.156 record rename; same pattern as
    /// ProvidersView's delete swipe).
    @StateObject private var customStore = CustomSubscriptionStore()

    @State private var name: String
    @State private var urlString = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var errorMessage: String?
    /// The ClashProvider record behind this provider, when the
    /// provider is a confined rule provider baked from a custom
    /// subscription (v0.2.156). Nil for profile-defined /
    /// http-cache providers, which have no record to rename.
    @State private var confinedRecord: ClashProvider?
    @State private var isRenaming = false
    /// Provider text editing (FlClash providers.dart _EditProviderView
    /// IS an EditorPage over the provider's text file, load via
    /// _openProviderText, save via _sideLoadProvider). Rule sets load
    /// via core.dumpRuleSet; other providers are read from their file
    /// at `path` (resolved against the App Group container).
    @State private var providerText: String?
    @State private var originalProviderText: String?
    @State private var isLoadingText = false
    @State private var textLoadError: String?
    @State private var isSavingText = false
    /// Subscription info (FlClash providers.dart _TrafficMeter):
    /// provider.get carries subscriptionInfo when the provider is a
    /// subscription.
    @State private var detailInfo: ConcordProviderInfo?

    init(provider: ConcordProviderInfo) {
        self.provider = provider
        _name = State(initialValue: provider.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前提供方") {
                    detailRow("类型", provider.type)
                    detailRow("传输方式", provider.vehicleType)
                    detailRow("条目", "\(provider.count) 条")
                    detailRow("路径", provider.path)
                    if let updatedAt = provider.updatedAt {
                        detailRow(
                            "更新于",
                            Date(timeIntervalSince1970: TimeInterval(updatedAt))
                                .formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let behavior = provider.behavior, !behavior.isEmpty {
                        detailRow("行为", behavior)
                    }
                    if let format = provider.format, !format.isEmpty {
                        detailRow("格式", format)
                    }
                    if let info = detailInfo?.subscriptionInfo {
                        detailRow("已用流量", ByteCountFormatter.string(fromByteCount: info.upload + info.download, countStyle: .file))
                        if info.total > 0 {
                            detailRow("总流量", ByteCountFormatter.string(fromByteCount: info.total, countStyle: .file))
                            ProgressView(value: min(Double(info.upload + info.download) / Double(info.total), 1.0))
                        }
                        if info.expire > 0 {
                            detailRow("到期", Date(timeIntervalSince1970: TimeInterval(info.expire)).formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
                // Provider content (FlClash _EditProviderView +
                // preview): rule sets via core.dumpRuleSet, other
                // providers from their file. Editing saves back with
                // provider.sideLoad under the same name.
                Section("提供方内容") {
                    if isLoadingText {
                        ProgressView("正在读取内容…")
                            .font(.footnote)
                    } else if let text = providerText {
                        TextEditor(text: Binding(
                            get: { providerText ?? "" },
                            set: { providerText = $0 }
                        ))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        Button(isSavingText ? "保存中…" : "保存内容") {
                            Task { await saveText() }
                        }
                        .disabled(isSavingText || providerText == originalProviderText)
                        Text(text.isEmpty ? "内容为空。" : "共 \(text.count) 个字符。保存后以「\(provider.name)」重新载入（provider.sideLoad）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(textLoadError ?? "还没有读取内容。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("读取内容") {
                            Task { await loadText() }
                        }
                    }
                    if let error = ruleStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("编辑") {
                    TextField("提供方名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("订阅链接（https://…）", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("核心不保存提供方的订阅链接：这里重新填写链接，保存时会下载内容并以该名称载入（provider.sideLoad）。只改名称不填链接时，不会真正重命名——要真正重命名请用下面的「重命名提供方」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // True record rename (v0.2.156; upstream
                // ClashProviders.put): only for a confined rule
                // provider — the record label is renamed and every
                // custom subscription mapping the record has its
                // RULE-SET references rewritten, then the active
                // profile is re-applied when it bakes one of them.
                // No URL is needed and no content is re-downloaded.
                if let record = confinedRecord {
                    Section("重命名提供方") {
                        Text("将记录「\(record.label)」真正重命名为上方填写的名称：所有引用该提供方的订阅里的规则集引用都会一起改名，正在使用的配置也会重新应用。不需要重新填写订阅链接。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(isRenaming ? "重命名中…" : "重命名为「\(trimmedName)」") {
                            Task { await renameRecord() }
                        }
                        .disabled(isRenaming || trimmedName.isEmpty || trimmedName == record.label || renameIssue != nil)
                        if let issue = renameIssue {
                            Text(issue)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button(isSaving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty || trimmedURL.isEmpty)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("编辑提供方")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await ruleStore.loadProviderDetail(provider)
                detailInfo = ruleStore.providerDetail
                await loadText()
                // v0.2.156: resolve the ClashProvider record behind
                // a confined rule provider (path
                // <home>/providers/<subID>/rules/<token>) so the
                // rename section can offer a true rename.
                if let owned = CustomSubscriptionStore.ownerOfConfinedRuleProvider(path: provider.path, in: customStore.subscriptions),
                   let ref = owned.sub.ruleProviderMap[owned.provider.name] {
                    confinedRecord = ClashProviderStore().provider(id: ref.clashProviderId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var isRuleSet: Bool { provider.type == "rule" }

    /// Why the record rename to the current name cannot run
    /// (v0.2.156). Nil when the name is unchanged (the button is
    /// disabled instead) or the rename is safe.
    private var renameIssue: String? {
        guard let record = confinedRecord else { return nil }
        if trimmedName.isEmpty { return "请先输入提供方名称" }
        if trimmedName == record.label { return nil }
        return CustomSubscriptionStore.renameClashProviderIssue(recordId: record.id, newLabel: trimmedName)
    }

    /// True record rename (v0.2.156): rename the ClashProvider
    /// record and rewrite every referencing subscription, then
    /// re-apply the active profile when it bakes an affected
    /// subscription so the running engine sees the new name
    /// (apply rebuilds the provider sets fresh; no core RPC).
    /// A re-apply failure is surfaced, not swallowed (logic-audit
    /// B4, delete-flow pattern): the rename itself is already
    /// saved, only the live engine still runs the old names, so
    /// the sheet stays open with the error instead of dismissing
    /// with a false success.
    private func renameRecord() async {
        guard let record = confinedRecord else { return }
        let newName = trimmedName
        if let issue = CustomSubscriptionStore.renameClashProviderIssue(recordId: record.id, newLabel: newName) {
            errorMessage = issue
            return
        }
        isRenaming = true
        defer { isRenaming = false }
        let affected = CustomSubscriptionStore.renameClashProviderRecord(id: record.id, newLabel: newName)
        // The record label is new now even if the live re-apply
        // below fails — refresh the section state so it shows the
        // new label and the button disables.
        confinedRecord = ClashProviderStore().provider(id: record.id)
        // Capture the re-apply failure BEFORE refresh(): a
        // successful refresh clears lastError, which would wipe
        // the failure message.
        var reapplyError: String?
        for subId in affected {
            if await profileStore.reapplyActiveForSubscription(id: subId),
               let error = profileStore.lastError {
                reapplyError = error
                break
            }
        }
        await ruleStore.refresh()
        if let error = reapplyError {
            errorMessage = "重命名已保存，但重新应用配置失败：\(error)（下次启动 VPN 时生效）"
            return
        }
        dismiss()
    }

    private func loadText() async {
        isLoadingText = true
        defer { isLoadingText = false }
        textLoadError = nil
        if isRuleSet {
            await ruleStore.dumpRuleSet(provider)
            if let dumped = ruleStore.dumpedRuleSetText, ruleStore.dumpedRuleSetName == provider.name {
                providerText = dumped
                originalProviderText = dumped
                return
            }
            textLoadError = ruleStore.lastError ?? "读取规则集失败"
            return
        }
        // Non-rule providers: read the file at `path` (relative to
        // the core's home directory, resolved by ConfigStore).
        guard let absolute = ConfigStore.absolutePath(relative: provider.path) else {
            textLoadError = "App Group 容器不可用，无法读取提供方文件"
            return
        }
        do {
            let text = try String(contentsOfFile: absolute, encoding: .utf8)
            providerText = text
            originalProviderText = text
        } catch {
            textLoadError = "读取提供方文件失败：\(error.localizedDescription)"
        }
    }

    private func saveText() async {
        guard let text = providerText else { return }
        isSavingText = true
        defer { isSavingText = false }
        await ruleStore.sideLoadProvider(name: provider.name, data: text)
        if ruleStore.lastError == nil {
            originalProviderText = text
            message = "已保存提供方内容「\(provider.name)」"
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() async {
        guard !trimmedName.isEmpty else {
            errorMessage = "请先输入提供方名称"
            return
        }
        guard let url = URL(string: trimmedURL),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "链接无效，请输入 http(s) 链接"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "下载失败：服务器返回异常状态"
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                errorMessage = "下载失败：内容为空或不是文本"
                return
            }
            await ruleStore.sideLoadProvider(name: trimmedName, data: text)
            if ruleStore.lastError == nil {
                message = "已载入提供方 \(trimmedName)"
                dismiss()
            } else {
                errorMessage = ruleStore.lastError
            }
        } catch {
            errorMessage = "下载失败：\(error.localizedDescription)"
        }
    }
}
