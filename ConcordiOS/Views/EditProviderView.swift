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
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button(isSaving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty || trimmedURL.isEmpty)
                    if let message {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("编辑提供方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
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
