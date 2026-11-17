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
