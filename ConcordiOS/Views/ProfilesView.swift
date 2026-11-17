import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profiles (FlClash: ProfilesView, lib/views/profiles/)
// FlClash profiles page: remote (URL) and local profiles, update all,
// per-profile update / edit / preview / delete, active profile switch,
// profile.inspect counts. This page reproduces those actions; the
// config editor itself is the profile YAML file (opened via the
// preview sheet), matching FlClash's editor page on mobile.

struct ProfilesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var configStore: ConfigStore
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var previewProfile: Profile?
    @State private var isUpdating = false
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
        NavigationStack {
            List {
                if profileStore.profiles.isEmpty {
                    ContentUnavailableView("暂无订阅", systemImage: "list.clipboard", description: Text("添加一个订阅链接或导入本地配置文件"))
                }
                ForEach(profileStore.profiles) { profile in
                    Button {
                        Task { await profileStore.activate(profile) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: profile.kind == .url ? "link" : "doc")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.body)
                                HStack(spacing: 6) {
                                    Text(profile.kind.rawValue)
                                    if let updated = profile.updatedAt {
                                        Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let note = profile.note {
                                    Text(note).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if profile.isActive {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("预览") { previewProfile = profile }
                            .tint(.blue)
                        Button("更新") { Task { await profileStore.update(profile) } }
                            .tint(.orange)
                            .disabled(profile.kind != .url)
                        Button("删除", role: .destructive) { profileStore.delete(profile) }
                    }
                }

                if let inspect = profileStore.inspect {
                    Section("当前配置检查（profile.inspect）") {
                        LabeledContent("节点", value: "\(inspect.proxies)")
                        LabeledContent("代理组", value: "\(inspect.proxyGroups)")
                        LabeledContent("规则", value: "\(inspect.rules)")
                        LabeledContent("摘要", value: inspect.digest)
                        if !inspect.matchRules.isEmpty {
                            Text("匹配规则：\(inspect.matchRules.joined(separator: ", "))")
                                .font(.caption)
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
                                Text(issue.message).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let message = validationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !profileStore.applyWarnings.isEmpty {
                    Section("配置警告（config.apply）") {
                        ForEach(profileStore.applyWarnings, id: \.message) { warning in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warning.message).font(.subheadline)
                                Text("\(warning.path) · \(warning.level)")
                                    .font(.caption)
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
                            Text(message).font(.caption).foregroundStyle(.secondary)
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
                            .font(.caption)
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
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        if let outbounds = profileStore.outbounds {
                            if !outbounds.proxies.isEmpty {
                                Text("代理（\(outbounds.proxies.count)）").font(.caption).foregroundStyle(.secondary)
                                ForEach(outbounds.proxies, id: \.name) { outbound in
                                    LabeledContent(outbound.name, value: outbound.type)
                                }
                            }
                            if !outbounds.proxyGroups.isEmpty {
                                Text("代理组（\(outbounds.proxyGroups.count)）").font(.caption).foregroundStyle(.secondary)
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
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(profileStore.encodedLinks, id: \.self) { link in
                            ShareLink(item: link) {
                                Text(link).font(.caption).lineLimit(2)
                            }
                        }
                        Text("链接由核心从配置的 proxies 列表生成，点击可分享。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("导入分享链接（convert.decodeLinks）") {
                        TextEditor(text: $decodeText)
                            .frame(minHeight: 100)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("解析链接") {
                            Task { await profileStore.decodeLinks(decodeText.components(separatedBy: .newlines)) }
                        }
                        .disabled(decodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let message = profileStore.decodeMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(profileStore.decodedProxies.enumerated()), id: \.offset) { _, proxy in
                            HStack {
                                Text(proxy.objectValue?["name"]?.stringValue ?? "未知节点")
                                Spacer()
                                Text(proxy.objectValue?["type"]?.stringValue ?? "")
                                    .font(.caption)
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
                            .font(.caption)
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
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("订阅编号是桌面端宿主给订阅分配的数字 ID；iOS 上订阅用 UUID 标识，核心侧没有对应的已下载文件，因此这个操作通常无事可做。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text(profileStore.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = profileStore.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("订阅")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isUpdating = true
                        Task {
                            await profileStore.updateAll()
                            isUpdating = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isUpdating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddProfileView(showImporter: $showImporter)
            }
            .sheet(item: $previewProfile) { profile in
                ProfilePreviewView(profile: profile)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.yaml]) { result in
                if case .success(let url) = result,
                   let data = try? Data(contentsOf: url) {
                    profileStore.addFromFile(name: url.lastPathComponent, data: data)
                }
            }
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
}

// Add profile sheet (FlClash profiles/add.dart).
struct AddProfileView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @Binding var showImporter: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅链接") {
                    TextField("名称（可选）", text: $name)
                    TextField("https://…/subscribe.yaml", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("添加订阅") {
                        Task {
                            await profileStore.addFromURL(name: name, urlString: urlString)
                            dismiss()
                        }
                    }
                    .disabled(urlString.isEmpty)
                }
                Section("本地文件") {
                    Button("导入本地配置文件（.yaml / .yml）") {
                        dismiss()
                        showImporter = true
                    }
                    Text("支持 Clash / mihomo YAML。导入后文件保存在 App Group 容器，扩展与主 App 共享。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("订阅更新调用 convert.subscription / provider.update；切换订阅调用 config.apply + profile.inspect。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// Profile preview (FlClash profiles/preview.dart): three tabs — the raw
// YAML, the node list the profile yields (convert.subscription) and
// the merged effective config (profile.build).
struct ProfilePreviewView: View {
    let profile: Profile
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = "正在读取…"
    @State private var tab = PreviewTab.yaml
    @State private var convertedProxies: [JSONValue]?
    @State private var builtText: String?
    @State private var previewError: String?

    enum PreviewTab: String, CaseIterable, Identifiable {
        case yaml = "原始 YAML"
        case nodes = "节点列表"
        case built = "生效配置"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("预览", selection: $tab) {
                    ForEach(PreviewTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case .yaml:
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                case .nodes:
                    List {
                        if let error = previewError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if let proxies = convertedProxies {
                            if proxies.isEmpty {
                                Text("该订阅没有解析出节点").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(proxies.enumerated()), id: \.offset) { _, proxy in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(proxy.objectValue?["name"]?.stringValue ?? "—").font(.body)
                                        Text("\(proxy.objectValue?["type"]?.stringValue ?? "—") · \(proxy.objectValue?["server"]?.stringValue ?? "—")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .listStyle(.plain)
                case .built:
                    ScrollView {
                        if let error = previewError {
                            Text(error).font(.caption).foregroundStyle(.red).padding()
                        } else if let built = builtText {
                            Text(built)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            ProgressView().padding()
                        }
                    }
                }
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                // The sample profile has no file on disk; show a note.
                if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
                    .appendingPathComponent("profiles")
                    .appendingPathComponent("\(profile.id.uuidString).yaml"),
                   let data = try? Data(contentsOf: dir) {
                    text = String(data: data, encoding: .utf8) ?? "无法以 UTF-8 解码"
                } else {
                    text = "# \(profile.name)\n# 示例数据：该示例订阅没有本地文件。\n# 真实订阅导入后，这里会显示完整的 YAML 内容。\n# 订阅链接：\(profile.urlString ?? "—")\n"
                }
            }
            .onChange(of: tab) { _, newTab in
                Task {
                    switch newTab {
                    case .yaml: break
                    case .nodes:
                        if convertedProxies == nil {
                            switch await profileStore.convertProfile(profile) {
                            case .success(let proxies):
                                convertedProxies = proxies
                                previewError = nil
                            case .failure(let error):
                                previewError = error.localizedDescription
                            }
                        }
                    case .built:
                        if builtText == nil {
                            switch await profileStore.buildProfileText(profile) {
                            case .success(let built):
                                builtText = built
                                previewError = nil
                            case .failure(let error):
                                previewError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }
}
