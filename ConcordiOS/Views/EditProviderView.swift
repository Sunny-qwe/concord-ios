import SwiftUI

// MARK: - Edit provider (FlClash providers.dart _EditProviderView)
//
// FlClash's edit opens the provider's text in the editor and saves
// it back with provider.sideLoad. The core does not expose a
// provider URL (ConcordProviderInfo has no url field), so this form
// takes the name plus a fresh link: saving downloads the link and
// side-loads the content under that name (provider.sideLoad).
// Renaming alone creates the provider under the new name — the old
// name is left alone, since the core has no rename/delete for
// providers.

struct EditProviderView: View {
    let provider: ConcordProviderInfo

    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var urlString = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var errorMessage: String?
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
                    Text("核心不保存提供方的订阅链接：这里重新填写链接，保存时会下载内容并以该名称载入（provider.sideLoad）。改名相当于用新名称载入一份，旧名称的提供方保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var isRuleSet: Bool { provider.type == "rule" }

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
