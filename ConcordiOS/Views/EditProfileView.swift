import SwiftUI
import UniformTypeIdentifiers

// MARK: - Edit profile (FlClash: lib/views/profiles/edit.dart)
//
// Name field, URL field (URL profiles only), age 私钥 field,
// auto-update toggle + interval (minutes), profile file item
// (size + last modified, tap -> ConfigEditorView, menu 编辑 / 上传）.
// Save (check button) validates like FlClash and calls
// ProfileStore.updateProfileMeta; when the URL changed it also
// re-downloads via update (FlClash behavior).
//
// Honest gaps, stated in the UI:
// - Auto-update is stored but no periodic scheduler is wired yet;
//   manual 更新 remains the path.
// - The age key is stored per profile and never logged; verified in
//   code, it is never read back anywhere (no download or decrypt
//   path consumes it yet).
// - ConfigEditorView now edits THIS profile's file (v0.2.32),
//   active or not, so the file row's editor opens the right file.
// - An uploaded file is staged until save (FlClash stages its
//   _fileData the same way); backing out discards it.

struct EditProfileView: View {
    let profile: Profile
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var urlString: String
    @State private var ageSecretKey: String
    @State private var autoUpdate: Bool
    @State private var intervalText: String
    @State private var validationError: String?
    @State private var fileInfo: (size: Int, lastModified: Date?)?
    @State private var pendingFileData: Data?
    @State private var pendingFileSize: Int?
    @State private var showFileImporter = false
    @State private var showEditor = false
    @State private var uploadError: String?
    @State private var isSaving = false
    @State private var showAutoUpdatePrompt = false
    @State private var showDiscardAlert = false

    init(profile: Profile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _urlString = State(initialValue: profile.urlString ?? "")
        _ageSecretKey = State(initialValue: profile.ageSecretKey ?? "")
        _autoUpdate = State(initialValue: profile.autoUpdate)
        _intervalText = State(initialValue: profile.autoUpdateIntervalMinutes.map(String.init) ?? "1440")
    }

    private var isURLProfile: Bool { profile.kind == .url }

    /// Unsaved changes (FlClash edit.dart PopGuard): edited fields
    /// or a staged file.
    private var isDirty: Bool {
        name != profile.name
            || urlString != (profile.urlString ?? "")
            || ageSecretKey != (profile.ageSecretKey ?? "")
            || autoUpdate != profile.autoUpdate
            || (autoUpdate && intervalText != (profile.autoUpdateIntervalMinutes.map(String.init) ?? "1440"))
            || pendingFileData != nil
    }

    // MARK: Field-level validity (FlClash edit.dart:420-424:
    // ErrorBanner + per-field invalid flags)
    private var isNameInvalid: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isURLInvalid: Bool {
        guard isURLProfile else { return false }
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty || URL(string: url)?.scheme?.hasPrefix("http") != true
    }

    private var isIntervalInvalid: Bool {
        guard isURLProfile, autoUpdate else { return false }
        guard let minutes = Int(intervalText), minutes > 0 else { return true }
        return false
    }

    private var displayedFileSize: Int {
        pendingFileSize ?? fileInfo?.size ?? 0
    }

    private var displayedLastModified: Date? {
        pendingFileData == nil ? fileInfo?.lastModified : Date()
    }

    private var validationIssue: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写名称"
        }
        guard isURLProfile else { return nil }
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            return "请填写订阅链接"
        }
        guard URL(string: url)?.scheme?.hasPrefix("http") == true else {
            return "订阅链接无效"
        }
        if autoUpdate {
            guard let minutes = Int(intervalText), minutes > 0 else {
                return "请填写有效的自动更新间隔（分钟）"
            }
        }
        return nil
    }

    var body: some View {
        List {
            if let validationError {
                Section {
                    Text(validationError)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }
            Section {
                fieldRow(label: "名称", invalid: isNameInvalid, error: isNameInvalid ? "请填写名称" : nil) {
                    TextField("必填", text: $name)
                        .font(.system(size: 13, weight: .semibold))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if isURLProfile {
                    fieldRow(label: "链接", invalid: isURLInvalid, error: isURLInvalid ? "订阅链接无效，应为 http(s) 链接" : nil) {
                        TextField("必填", text: $urlString)
                            .font(.system(size: 13, weight: .semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                fieldRow(label: "age 私钥") {
                    SecureField("可选", text: $ageSecretKey)
                        .font(.system(size: 13, weight: .semibold))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("私钥仅保存在本机，不会被记录到日志。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if isURLProfile {
                Section {
                    Toggle("自动更新", isOn: $autoUpdate)
                        .font(.system(size: 13, weight: .semibold))
                    if autoUpdate {
                        HStack(spacing: 8) {
                            Text("更新间隔")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isIntervalInvalid ? .red : .primary)
                            Spacer()
                            TextField("必填", text: $intervalText)
                                .font(.system(size: 13, weight: .semibold))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                                .foregroundStyle(isIntervalInvalid ? .red : .primary)
                            Text("分钟")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        if isIntervalInvalid {
                            Text("请填写有效的自动更新间隔（分钟）")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }
                    }
                    Text("自动更新尚未接入定时器：打开后只会保存设置，仍需手动点「更新」同步订阅。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button { showEditor = true } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("配置文件")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(fileSubtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formattedFileSize)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { showEditor = true } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                            .font(.system(size: 15))
                    }
                    Button { showFileImporter = true } label: {
                        Label("上传", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15))
                    }
                }
                if pendingFileData != nil {
                    Text("已选择新文件，保存后才会替换原配置文件。")
                        .font(.system(size: 13))
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
        }
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if isDirty {
                        showDiscardAlert = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel("保存")
                .disabled(isSaving)
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            ConfigEditorView(targetProfile: profile)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.yaml, UTType.plainText]) { result in
            handlePickedFile(result)
        }
        .alert("提示", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("common.ok".l10n, role: .cancel) {}
        } message: {
            Text(uploadError ?? "")
        }
        // FlClash edit.dart:290-300: replacing the file while
        // auto-update is on asks whether to turn auto-update off.
        .alert("手动替换了配置文件", isPresented: $showAutoUpdatePrompt) {
            Button("关闭自动更新并保存") {
                Task { await saveConfirmed(turnOffAutoUpdate: true) }
            }
            Button("保持自动更新并保存") {
                Task { await saveConfirmed(turnOffAutoUpdate: false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个订阅开了自动更新，下次自动更新会把你手动换的文件覆盖掉。是否关闭自动更新？")
        }
        // FlClash edit.dart:336-352 PopGuard: backing out with a
        // staged file asks first.
        .alert("有未保存的修改", isPresented: $showDiscardAlert) {
            Button("保存并返回") {
                Task { await save() }
            }
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回会丢弃还没保存的修改和已选择的文件。")
        }
        .task {
            fileInfo = profileStore.profileFileInfo(profile)
        }
    }

    private var fileSubtitle: String {
        if let modified = displayedLastModified {
            return ConcordRelativeTime.string(since: modified)
        }
        return "未知"
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(displayedFileSize), countStyle: .file)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, invalid: Bool = false, error: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(invalid ? .red : .secondary)
            content()
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// Upload stages the file until save (FlClash stages _fileData
    /// the same way). The picked file is read through the
    /// security-scoped URL; a failed read is shown in an alert,
    /// never swallowed.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingFileData = data
                pendingFileSize = data.count
            } catch {
                uploadError = "读取文件失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            uploadError = "选择文件失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        if let issue = validationIssue {
            validationError = issue
            return
        }
        // C6: a manual file replacement while auto-update is on
        // asks whether to turn auto-update off first.
        if pendingFileData != nil, autoUpdate {
            showAutoUpdatePrompt = true
            return
        }
        await saveConfirmed(turnOffAutoUpdate: false)
    }

    private func saveConfirmed(turnOffAutoUpdate: Bool) async {
        isSaving = true
        defer { isSaving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = ageSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = Int(intervalText)
        let effectiveAutoUpdate = turnOffAutoUpdate ? false : autoUpdate
        let urlChanged = profileStore.updateProfileMeta(
            profile,
            name: trimmedName,
            urlString: isURLProfile ? trimmedURL : profile.urlString,
            ageSecretKey: trimmedKey.isEmpty ? nil : trimmedKey,
            autoUpdate: effectiveAutoUpdate,
            autoUpdateIntervalMinutes: effectiveAutoUpdate ? interval : profile.autoUpdateIntervalMinutes
        )
        if let data = pendingFileData {
            await profileStore.updateProfileFile(profile, data: data)
            if let error = profileStore.lastError {
                validationError = error
                return
            }
        }
        if urlChanged,
           let fresh = profileStore.profiles.first(where: { $0.id == profile.id }) {
            await profileStore.update(fresh)
            if let error = profileStore.lastError {
                validationError = error
                return
            }
        }
        dismiss()
    }
}
