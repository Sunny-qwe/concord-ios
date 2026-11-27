import SwiftUI
import UniformTypeIdentifiers

// MARK: - 自定义订阅 YAML 导入（v0.2.55）
//
// 从链接下载或从文件读取一份 Clash 风格 YAML，经 YamlParser 解析、
// CustomSubscriptionImporter 映射后存为自定义订阅（CustomSubscriptionStore）。
// 同名订阅已存在时只弹一次确认框，确认后替换（保留原 id，烘焙映射不断），
// 取消则不做任何改动。解析或映射失败时显示中文错误并保持原样——
// 绝不静默丢弃内容。

struct CustomSubscriptionImportView: View {
    @ObservedObject var store: CustomSubscriptionStore
    /// The real ProfileStore (v0.2.148): provider profiles are
    /// created through it at save time. Passed explicitly from
    /// ProfilesView (`.environmentObject(profileStore)` on the
    /// sheet) rather than relying on environment inheritance.
    @EnvironmentObject var profileStore: ProfileStore
    let onImported: (CustomSubscription) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var result: CustomSubscriptionImportResult?
    @State private var savedSubscription: CustomSubscription?
    @State private var pendingResult: CustomSubscriptionImportResult?
    @State private var showFileImporter = false
    @State private var showReplaceConfirm = false
    /// Provider-creation failures from the last save (v0.2.148):
    /// a failed provider download keeps the http fallback and is
    /// noted here — the import itself still succeeds.
    @State private var providerProfileNotes: [String] = []

    var body: some View {
        NavigationStack {
            List {
                if result == nil {
                    Section {
                        TextField("订阅名称", text: $name)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("名称取自文件或链接，也可自己改；同名订阅导入时会先问你是否替换。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("名称")
                    }
                    Section {
                        TextField("https://…/config.yaml", text: $urlText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button {
                            Task { await importFromURL() }
                        } label: {
                            if isLoading {
                                ProgressView()
                            } else {
                                Label("下载并导入", systemImage: "arrow.down.doc")
                            }
                        }
                        .disabled(isLoading || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从文件导入（.yaml）", systemImage: "doc")
                        }
                        .disabled(isLoading)
                    } header: {
                        Text("来源")
                    } footer: {
                        Text("导入分组、提供方、规则和节点（proxies 会导入到本地节点）；dns / ntp / sniffer / tun 区会导入到订阅的配置区；其余顶层配置项与自定义订阅无关，会在导入结果里列出。")
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        } header: {
                            Text("导入失败")
                        }
                    }
                } else if let result, let saved = savedSubscription {
                    Section {
                        Text("已导入「\(saved.name)」")
                            .font(.headline)
                        Text("\(result.subscription.groups.count) 分组 · \(result.subscription.proxyProviders.count + result.subscription.ruleProviders.count) 提供方 · \(result.subscription.rules.count) 规则")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !saved.providerProfileMap.isEmpty || !saved.ruleProviderMap.isEmpty {
                            Text("其中 \(saved.providerProfileMap.count) 个代理提供方已创建为订阅，\(saved.ruleProviderMap.count) 个规则提供方已下载")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !providerProfileNotes.isEmpty {
                        Section {
                            ForEach(providerProfileNotes, id: \.self) { note in
                                Text(note)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("提供方订阅")
                        }
                    }
                    if !result.ignoredTopLevelKeys.isEmpty {
                        Section {
                            Text("以下顶层配置项与自定义订阅无关，未导入：\(result.ignoredTopLevelKeys.joined(separator: "、"))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("未导入的内容")
                        }
                    }
                    if !result.notes.isEmpty {
                        Section {
                            ForEach(result.notes, id: \.self) { note in
                                Text(note)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("说明")
                        }
                    }
                    Section {
                        Button {
                            dismiss()
                            onImported(saved)
                        } label: {
                            Label("打开编辑", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("导入自定义订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                if result != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.yaml, UTType.plainText]) { picked in
                handlePickedFile(picked)
            }
            .alert("替换已有订阅", isPresented: $showReplaceConfirm) {
                Button("替换", role: .destructive) {
                    if let pending = pendingResult {
                        Task { await saveResult(pending, replacing: true) }
                    }
                    pendingResult = nil
                }
                Button("取消", role: .cancel) { pendingResult = nil }
            } message: {
                if let pending = pendingResult {
                    Text("已存在同名自定义订阅「\(pending.subscription.name)」，替换会用导入的内容覆盖它。确定替换吗？")
                }
            }
        }
    }

    // MARK: - 导入

    private func importFromURL() async {
        let rawURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL), url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "链接无效：请输入 http(s) 链接"
            return
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = suggestedName(from: url)
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let imported = try await CustomSubscriptionImporter.fetchAndImport(name: displayName(), from: url)
            finishImport(imported)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handlePickedFile(_ picked: Result<URL, Error>) {
        switch picked {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                errorMessage = "读取文件失败：\(error.localizedDescription)"
                return
            }
            guard data.count <= 2 * 1024 * 1024 else {
                errorMessage = "文件过大（超过 2MB），无法导入"
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "文件不是 UTF-8 编码，无法导入"
                return
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
            do {
                let imported = try CustomSubscriptionImporter.importSubscription(name: displayName(), yamlText: text)
                finishImport(imported)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }

    /// 导入成功后的处理：同名则弹一次替换确认，否则直接保存。
    /// Saving is async (v0.2.148): provider profiles are
    /// downloaded at save time.
    private func finishImport(_ imported: CustomSubscriptionImportResult) {
        errorMessage = nil
        if store.subscriptions.contains(where: { $0.name == imported.subscription.name }) {
            pendingResult = imported
            showReplaceConfirm = true
        } else {
            Task { await saveResult(imported, replacing: false) }
        }
    }

    private func saveResult(_ imported: CustomSubscriptionImportResult, replacing: Bool) async {
        var subscription = imported.subscription
        if replacing,
           let existing = store.subscriptions.first(where: { $0.name == subscription.name }) {
            subscription.id = existing.id
        }
        var notes: [String] = []
        // Proxy providers with a URL become real URL Profiles
        // (v0.2.148, upstream _importProviders bySource):
        // find-or-create each (dedup by url + age key), then
        // record provider-name → profile in the map so bake can
        // confine the profile's file. A failed download keeps the
        // http fallback and is noted — the import itself still
        // succeeds. The maps start empty on a replace: a provider
        // the new file keeps re-resolves to the same profile
        // through the dedup, a dropped provider's entry goes away
        // with it.
        for pending in imported.pendingProviderProfiles {
            if let profile = await profileStore.findOrCreateProviderProfile(label: pending.label, url: pending.url, ageSecretKey: pending.ageSecretKey) {
                subscription.providerProfileMap[pending.providerName] = ProviderProfileRef(
                    profileId: profile.id, fileToken: FlClashHash.md5Hex("\(pending.providerName)@\(pending.url)"))
            } else {
                notes.append("提供方「\(pending.label)」的订阅下载失败，已保留原链接方式：\(profileStore.lastError ?? "下载失败")")
            }
        }
        // Rule providers with a URL become ClashProvider records
        // (v0.2.148): find-or-create each (dedup by url),
        // download its content, then record provider-name →
        // record in the map. The store is local to this save (it
        // loads its JSON on init; update() persists immediately).
        let clashStore = ClashProviderStore()
        for pending in imported.pendingRuleProviders {
            do {
                let record = try await clashStore.findOrCreate(label: pending.label, url: pending.url, behavior: pending.behavior, format: pending.format)
                subscription.ruleProviderMap[pending.providerName] = RuleProviderRef(
                    clashProviderId: record.id, fileToken: FlClashHash.md5Hex("\(pending.providerName)@\(pending.url)"))
            } catch {
                notes.append("规则提供方「\(pending.label)」下载失败，已保留原链接方式：\(error.localizedDescription)")
            }
        }
        store.update(subscription)
        // v0.2.147: imported node definitions land in the app-wide
        // raw proxy store (deduped by name there), so the imported
        // groups' members resolve when the subscription is baked.
        CustomProxyStore().addRawProxies(imported.proxies)
        providerProfileNotes = notes
        result = imported
        savedSubscription = subscription
    }

    private func displayName() -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "自定义订阅" : trimmed
    }

    private func suggestedName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if !base.isEmpty && base != "/" { return base }
        return url.host ?? "自定义订阅"
    }
}
