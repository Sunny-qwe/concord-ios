import SwiftUI

// MARK: - Profile tools (moved out of ProfilesView)
//
// The API-tool sections that used to live on the 订阅 page
// (FlClash profiles page had no such sections; they are this app's
// own core-API surface). Moved as-is — same view code, same store
// calls — only the container changed. Reached from Tools -> 订阅工具.

struct ProfileToolsView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var validationMessage: String?
    @State private var decryptProfileID: UUID?
    @State private var decryptKey = ""
    @State private var decryptSaveName = ""
    @State private var outboundsProfileID: UUID?
    @State private var encodeProfileID: UUID?
    @State private var decodeText = ""
    @State private var decodeSaveName = ""
    @State private var clearEffectID = ""
    @State private var showClearEffectConfirm = false

    private func validateActiveProfile() async {
        switch await profileStore.validateActiveProfile() {
        case .success(let issues):
            profileStore.validationIssues = issues
            validationMessage = issues.isEmpty ? "配置校验通过" : "配置校验发现 \(issues.count) 个问题"
        case .failure(let error):
            validationMessage = "校验失败：\(error.localizedDescription)"
        }
    }

    private func validateActiveProfileProxies() async {
        switch await profileStore.validateActiveProfileProxies() {
        case .success(let issues):
            profileStore.validationIssues = issues
            validationMessage = issues.isEmpty ? "节点配置全部有效" : "节点校验发现 \(issues.count) 个问题"
        case .failure(let error):
            validationMessage = "校验失败：\(error.localizedDescription)"
        }
    }

    var body: some View {
        List {
            if let inspect = profileStore.inspect {
                Section("当前配置检查（profile.inspect）") {
                    LabeledContent("节点", value: "\(inspect.proxies)")
                    LabeledContent("代理组", value: "\(inspect.proxyGroups)")
                    LabeledContent("规则", value: "\(inspect.rules)")
                    LabeledContent("摘要", value: inspect.digest)
                    if !inspect.matchRules.isEmpty {
                        Text("匹配规则：\(inspect.matchRules.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button("校验配置文件（config.validate）") {
                        Task { await validateActiveProfile() }
                    }
                    Button("校验节点配置（validate.proxies）") {
                        Task { await validateActiveProfileProxies() }
                    }
                    if !profileStore.validationIssues.isEmpty {
                        ForEach(profileStore.validationIssues, id: \.message) { issue in
                            Text(issue.message).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    if let message = validationMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }

            if !profileStore.applyWarnings.isEmpty {
                Section("配置警告（config.apply）") {
                    ForEach(profileStore.applyWarnings, id: \.message) { warning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.message).font(.system(size: 13))
                            Text("\(warning.path) · \(warning.level)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !profileStore.profiles.isEmpty {
                Section("解密加密配置（config.decrypt）") {
                    Picker("配置文件", selection: $decryptProfileID) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    SecureField("解密密钥（仅用于本次调用，不保存）", text: $decryptKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("解密") {
                        guard let id = decryptProfileID,
                              let profile = profileStore.profiles.first(where: { $0.id == id }) else { return }
                        Task { await profileStore.decryptProfile(profile, key: decryptKey) }
                    }
                    .disabled(decryptProfileID == nil || decryptKey.isEmpty)
                    if let message = profileStore.decryptMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let result = profileStore.decryptResult, !result.isEmpty {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(12)
                        HStack {
                            TextField("另存为订阅名", text: $decryptSaveName)
                            Button("保存为新订阅") {
                                profileStore.saveDecryptedAsProfile(name: decryptSaveName.isEmpty ? "解密后的配置" : decryptSaveName)
                            }
                        }
                    }
                    Text("加密配置需用密钥解密后才能使用。解密由扩展内的核心执行，需先启动 VPN；密钥只发给本次调用，不会保存。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if !profileStore.profiles.isEmpty {
                Section("出站列表（profile.outbounds）") {
                    Picker("配置文件", selection: $outboundsProfileID) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    Button("读取出站列表") {
                        guard let id = outboundsProfileID,
                              let profile = profileStore.profiles.first(where: { $0.id == id }) else { return }
                        Task { await profileStore.loadOutbounds(profile) }
                    }
                    .disabled(outboundsProfileID == nil)
                    if let message = profileStore.outboundsMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let outbounds = profileStore.outbounds {
                        if !outbounds.proxies.isEmpty {
                            Text("代理（\(outbounds.proxies.count)）").font(.system(size: 10)).foregroundStyle(.secondary)
                            ForEach(outbounds.proxies, id: \.name) { outbound in
                                LabeledContent(outbound.name, value: outbound.type)
                            }
                        }
                        if !outbounds.proxyGroups.isEmpty {
                            Text("代理组（\(outbounds.proxyGroups.count)）").font(.system(size: 10)).foregroundStyle(.secondary)
                            ForEach(outbounds.proxyGroups, id: \.name) { group in
                                LabeledContent(group.name, value: group.type)
                            }
                        }
                    }
                }

                Section("分享链接（convert.encodeLinks）") {
                    Picker("配置文件", selection: $encodeProfileID) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    Button("生成分享链接") {
                        guard let id = encodeProfileID,
                              let profile = profileStore.profiles.first(where: { $0.id == id }) else { return }
                        Task { await profileStore.encodeLinks(profile) }
                    }
                    .disabled(encodeProfileID == nil)
                    if let message = profileStore.encodeMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ForEach(profileStore.encodedLinks, id: \.self) { link in
                        ShareLink(item: link) {
                            Text(link).font(.system(size: 10)).lineLimit(2)
                        }
                    }
                    Text("链接由核心从配置的 proxies 列表生成，点击可分享。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("导入分享链接（convert.decodeLinks）") {
                    TextEditor(text: $decodeText)
                        .frame(minHeight: 100)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Button("解析链接") {
                        Task { await profileStore.decodeLinks(decodeText.components(separatedBy: .newlines)) }
                    }
                    .disabled(decodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let message = profileStore.decodeMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(profileStore.decodedProxies.enumerated()), id: \.offset) { _, proxy in
                        HStack {
                            Text(proxy.objectValue?["name"]?.stringValue ?? "未知节点")
                            Spacer()
                            Text(proxy.objectValue?["type"]?.stringValue ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !profileStore.decodedProxies.isEmpty {
                        HStack {
                            TextField("另存为订阅名", text: $decodeSaveName)
                            Button("保存为新订阅") {
                                profileStore.saveDecodedAsProfile(name: decodeSaveName.isEmpty ? "导入的节点" : decodeSaveName)
                            }
                        }
                    }
                    Text("粘贴的链接只发给核心解析，不会发往任何其他地方；不是链接的行会被忽略。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section("清除订阅生效文件（profile.clearEffect）") {
                    TextField("订阅编号（数字）", text: $clearEffectID)
                        .keyboardType(.numberPad)
                    Button("清除") {
                        showClearEffectConfirm = true
                    }
                    .disabled(Int64(clearEffectID) == nil)
                    .alert("清除已下载的提供方文件？", isPresented: $showClearEffectConfirm) {
                        Button("清除", role: .destructive) {
                            guard let id = Int64(clearEffectID) else { return }
                            Task { await profileStore.clearEffect(profileId: id) }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将删除核心侧订阅 #\(clearEffectID) 的已下载提供方文件。iOS 上订阅没有数字编号，核心通常找不到可清除的内容。")
                    }
                    if let message = profileStore.clearEffectMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("订阅编号是桌面端宿主给订阅分配的数字 ID；iOS 上订阅用 UUID 标识，核心侧没有对应的已下载文件，因此这个操作通常无事可做。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(profileStore.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let error = profileStore.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .listStyle(.insetGrouped)
        .navigationTitle("订阅工具")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Default the decrypt target to a local file profile
            // (encrypted configs are imported as files), else the
            // active profile.
            if decryptProfileID == nil {
                decryptProfileID = profileStore.profiles.first(where: { $0.kind == .file })?.id
                    ?? profileStore.activeProfile?.id
            }
            if outboundsProfileID == nil {
                outboundsProfileID = profileStore.activeProfile?.id
            }
            if encodeProfileID == nil {
                encodeProfileID = profileStore.activeProfile?.id
            }
        }
    }
}
