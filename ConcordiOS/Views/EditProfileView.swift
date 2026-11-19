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
// - ConfigEditorView edits the ACTIVE profile's file, so the file
//   row's editor opens the active profile; a note says so when this
//   profile is not active.
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

    init(profile: Profile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _urlString = State(initialValue: profile.urlString ?? "")
        _ageSecretKey = State(initialValue: profile.ageSecretKey ?? "")
        _autoUpdate = State(initialValue: profile.autoUpdate)
        _intervalText = State(initialValue: profile.autoUpdateIntervalMinutes.map(String.init) ?? "1440")
    }

    private var isURLProfile: Bool { profile.kind == .url }

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
                fieldRow(label: "名称") {
                    TextField("必填", text: $name)
                        .font(.system(size: 17))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if isURLProfile {
                    fieldRow(label: "链接") {
                        TextField("必填", text: $urlString)
                            .font(.system(size: 17))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                fieldRow(label: "age 私钥") {
                    SecureField("可选", text: $ageSecretKey)
                        .font(.system(size: 17))
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
                        .font(.system(size: 17))
                    if autoUpdate {
                        HStack(spacing: 8) {
                            Text("更新间隔")
                                .font(.system(size: 17))
                            Spacer()
                            TextField("必填", text: $intervalText)
                                .font(.system(size: 17))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                            Text("分钟")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
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
                if !profile.isActive {
                    Text("文件编辑器打开的是当前已激活的订阅；要编辑此订阅的文件，请先在配置页点它切换为当前订阅。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            ConfigEditorView()
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
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            content()
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
        isSaving = true
        defer { isSaving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = ageSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = Int(intervalText)
        let urlChanged = profileStore.updateProfileMeta(
            profile,
            name: trimmedName,
            urlString: isURLProfile ? trimmedURL : profile.urlString,
            ageSecretKey: trimmedKey.isEmpty ? nil : trimmedKey,
            autoUpdate: autoUpdate,
            autoUpdateIntervalMinutes: autoUpdate ? interval : profile.autoUpdateIntervalMinutes
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
