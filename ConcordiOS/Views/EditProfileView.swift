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
// - Auto-update is stored and updateDueProfiles() honors the
//   per-profile switch + interval; the 20-minute timer that calls
//   it is wired by another worker — until then manual 更新 remains
//   the path (the page still says so below).
// - The age key is stored per profile and never logged; it is now
//   consumed on download / update / file upload via the core's
//   config.decrypt (ProfileStore), which needs a running tunnel.
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
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section {
                fieldRow(label: "名称", invalid: isNameInvalid, error: isNameInvalid ? "请填写名称" : nil) {
                    TextField("必填", text: $name)
                        .font(.footnote.weight(.semibold))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if isURLProfile {
                    fieldRow(label: "链接", invalid: isURLInvalid, error: isURLInvalid ? "订阅链接无效，应为 http(s) 链接" : nil) {
                        TextField("必填", text: $urlString)
                            .font(.footnote.weight(.semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                fieldRow(label: "age 私钥") {
                    SecureField("可选", text: $ageSecretKey)
                        .font(.footnote.weight(.semibold))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("私钥仅保存在本机，不会被记录到日志。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isURLProfile {
                Section {
                    Toggle("自动更新", isOn: $autoUpdate)
                        .font(.footnote.weight(.semibold))
                    if autoUpdate {
                        HStack(spacing: 8) {
                            Text("更新间隔")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(isIntervalInvalid ? .red : .primary)
                            Spacer()
                            TextField("必填", text: $intervalText)
                                .font(.footnote.weight(.semibold))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                                .foregroundStyle(isIntervalInvalid ? .red : .primary)
                            Text("分钟")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if isIntervalInvalid {
                            Text("请填写有效的自动更新间隔（分钟）")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Text("开启后应用会每 20 分钟检查一次，到期的订阅会自动更新；也可随时手动点「更新」立即同步订阅。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button { showEditor = true } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("配置文件")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(fileSubtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formattedFileSize)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { showEditor = true } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                            .font(.subheadline)
                    }
                    Button { showFileImporter = true } label: {
                        Label("上传", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
                if pendingFileData != nil {
                    Text("已选择新文件，保存后才会替换原配置文件。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
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
            ConfigEditorView(targetProfile: profile).concordNavBarBackground()
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(invalid ? .red : .secondary)
            content()
            if let error {
                Text(error)
                    .font(.footnote)
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
        // FlClash edit.dart: a staged file wins over a URL change —
        // the file branch saves the file and never re-downloads in
        // the same save, so the upload cannot be overwritten by a
        // fresh download (B13). And meta is persisted only AFTER
        // the file write succeeds, so a file failure leaves no
        // partial save behind (B14).
        if let data = pendingFileData {
            await profileStore.updateProfileFile(
                profile, data: data,
                ageSecretKey: trimmedKey.isEmpty ? nil : trimmedKey
            )
            if let error = profileStore.lastError {
                validationError = error
                return
            }
        }
        let keyChanged = (profile.ageSecretKey ?? "") != trimmedKey
        let urlChanged = profileStore.updateProfileMeta(
            profile,
            name: trimmedName,
            urlString: isURLProfile ? trimmedURL : profile.urlString,
            ageSecretKey: trimmedKey.isEmpty ? nil : trimmedKey,
            autoUpdate: effectiveAutoUpdate,
            autoUpdateIntervalMinutes: effectiveAutoUpdate ? interval : profile.autoUpdateIntervalMinutes
        )
        // A file was just uploaded: do not re-download over it in
        // this save, even when the URL (or key) also changed. The
        // next manual / automatic update will fetch from the new
        // URL; the auto-update prompt above already warned about
        // that when auto-update is on.
        guard pendingFileData == nil else {
            // FlClash edit.dart dispose(): saving auto-applies the
            // profile — a saved edit to the ACTIVE profile takes
            // effect without a manual re-apply.
            await applyIfActive()
            dismiss()
            return
        }
        // FlClash edit.dart hasUpdate = URL or age-key changed:
        // either one re-downloads (the key is needed to decrypt an
        // age-encrypted download).
        if urlChanged || keyChanged,
           let fresh = profileStore.profiles.first(where: { $0.id == profile.id }) {
            await profileStore.update(fresh)
            if let error = profileStore.lastError {
                validationError = error
                return
            }
        }
        await applyIfActive()
        dismiss()
    }

    /// FlClash edit.dart dispose() autoApplyProfile: after a
    /// successful save, re-apply the profile when it is the active
    /// one, so the edit takes effect live (or at next start when
    /// the VPN is off — reapplyActive handles that).
    private func applyIfActive() async {
        guard profile.id == profileStore.activeProfile?.id else { return }
        _ = await profileStore.reapplyActive()
    }
}
