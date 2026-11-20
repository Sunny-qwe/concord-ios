import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreImage

// MARK: - Profiles (FlClash: lib/views/profiles/profiles.dart)
//
// FlClash structure, 1:1 where the iOS app has an equivalent:
// AppBar [节点来源 globe, 可视化配置 sliders, 更新 sync (only when
// profiles exist), 排序 sort (only when profiles exist), + addCircle
// menu (only when profiles exist)]; body is an empty state
// (NullStatus) or a grid of profile cards (LazyVGrid adaptive min
// 300pt -> 1 column on a 390pt iPhone). Card tap = activate/select;
// long-press = context menu (编辑 / 扩展 / 同步 (URL) / 更多 submenu /
// 删除）. Reorder lives in its own sheet (配置排序）, never as
// long-press-to-reorder on the page. The API-tool sections that used
// to live on this page moved to ProfileToolsView (Tools -> 订阅工具）.
//
// Differences vs FlClash, all honest:
// - No .custom ProfileKind exists in this app (only url/file), so
//   every profile takes the non-custom menu path; there is no rename
//   action (renaming happens via the Edit page's name field).
// - No subscriptionInfo (used/total traffic, expiry) is stored on
//   Profile, so the card subtitle is the FlClash fallback:
//   远程 (URL) / 本地 (file).
// - No provider-in-use lookup exists (providers are per-config YAML,
//   not profile-linked), so delete always uses the plain
//   "确定删除当前{label}吗？" text, never the provider-in-use variant.
// - "从手机发送" is TV-only in FlClash and has no iOS equivalent;
//   it is skipped.
// - 运行时配置 opens the merged-config preview (FlClash
//   profiles.dart:532-540); the YAML editor is reached from the
//   Edit page's file row instead.

enum ProfileNavDestination: Hashable {
    case nodeSources
    case visualConfig
    case customSubscriptions
    case customSubscription(UUID)
    case extend(UUID)
    case edit(UUID)
}

struct ProfilesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var navPath: [ProfileNavDestination] = []
    @State private var showUnifiedImport = false
    @State private var showScanImport = false
    @State private var scannedText: String?
    @State private var showFileImporter = false
    @State private var showReorder = false
    @State private var reorderDraft: [Profile] = []
    @State private var previewProfile: Profile?
    @State private var previewInitialTab: ProfilePreviewView.PreviewTab = .yaml
    @State private var qrProfile: Profile?
    @State private var exportURL: URL?
    @State private var deleteTarget: Profile?
    @State private var updatingIDs: Set<UUID> = []
    @State private var isUpdatingAll = false
    @State private var copyNotice: String?
    @State private var alertMessage: String?
    /// Groups count per profile, parsed from local YAML
    /// (FlClash _GroupsCountChip, profiles.dart:585).
    @State private var groupCounts: [UUID: Int] = [:]

    private var hasProfiles: Bool { !profileStore.profiles.isEmpty }

    var body: some View {
        NavigationStack(path: $navPath) {
            // FlClash profiles.dart:230-262 _revealSelected: open
            // with the current profile visible.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if let notice = copyNotice {
                            Text(notice)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if profileStore.profiles.isEmpty {
                            emptyState
                        } else {
                            profileGrid
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    refreshGroupCounts()
                    if let active = profileStore.activeProfile {
                        scrollProxy.scrollTo(active.id, anchor: .center)
                    }
                }
                .onChange(of: profileStore.profiles.map(\.id)) { _, _ in
                    refreshGroupCounts()
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            .navigationTitle("title.profiles".l10n)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navPath.append(.nodeSources) } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("节点来源")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navPath.append(.visualConfig) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("可视化配置")
                }
                if hasProfiles {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await updateAll() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("更新")
                        .disabled(isUpdatingAll)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            reorderDraft = profileStore.profiles
                            showReorder = true
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("排序")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            addProfileMenuItems
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel("添加配置")
                    }
                }
            }
            .navigationDestination(for: ProfileNavDestination.self) { destination in
                switch destination {
                case .nodeSources:
                    NodeSourcesView()
                case .visualConfig:
                    VisualConfigView()
                case .customSubscriptions:
                    CustomSubscriptionListView()
                case .customSubscription(let id):
                    CustomSubscriptionEditorView(subscriptionID: id)
                case .extend(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        ExtendConfigView(profile: profile)
                    } else {
                        ContentUnavailableView("订阅已删除", systemImage: "trash")
                    }
                case .edit(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        EditProfileView(profile: profile)
                    } else {
                        ContentUnavailableView("订阅已删除", systemImage: "trash")
                    }
                }
            }
            .sheet(isPresented: $showUnifiedImport, onDismiss: { scannedText = nil }) {
                UnifiedImportView(profileStore: profileStore, initialText: scannedText ?? "", autoImport: scannedText != nil)
            }
            .sheet(isPresented: $showScanImport) {
                ScanImportView { text in
                    scannedText = text
                    showUnifiedImport = true
                }
            }
            .sheet(isPresented: $showReorder) {
                reorderSheet
            }
            .sheet(item: $previewProfile) { profile in
                ProfilePreviewView(profile: profile, initialTab: previewInitialTab)
            }
            .sheet(item: $qrProfile) { profile in
                ProfileQRCodeView(profile: profile)
            }
            .sheet(isPresented: Binding(
                get: { exportURL != nil },
                set: { if !$0 { exportURL = nil } }
            )) {
                if let url = exportURL {
                    NavigationStack {
                        VStack(spacing: 16) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 17, weight: .semibold))
                            ShareLink(item: url) {
                                Label("分享配置文件", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ConcordTheme.accent)
                            Text("导出成功")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(24)
                        .navigationTitle("导出文件")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { exportURL = nil }
                            }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.yaml, UTType.plainText]) { result in
                handlePickedFile(result)
            }
            // One alert for the whole page (two .alert modifiers on
            // the same view fight each other): it shows either the
            // delete confirmation or a plain message alert.
            .alert("提示", isPresented: Binding(
                get: { alertMessage != nil || deleteTarget != nil },
                set: { if !$0 { alertMessage = nil; deleteTarget = nil } }
            )) {
                if deleteTarget != nil {
                    Button("删除", role: .destructive) {
                        if let profile = deleteTarget {
                            profileStore.delete(profile)
                        }
                        deleteTarget = nil
                    }
                    Button("取消", role: .cancel) { deleteTarget = nil }
                } else {
                    Button("common.ok".l10n, role: .cancel) {}
                }
            } message: {
                if let profile = deleteTarget {
                    Text("确定删除当前\(profile.name)吗？")
                } else {
                    Text(alertMessage ?? "")
                }
            }
        }
    }

    // MARK: - Add menu (FlClash AddProfileMenu, minus TV-only
    // "从手机发送" which has no iOS equivalent)

    @ViewBuilder
    private var addProfileMenuItems: some View {
        Button { navPath.append(.nodeSources) } label: {
            Label("节点来源", systemImage: "list.bullet")
                .font(.system(size: 15))
        }
        Button { showScanImport = true } label: {
            Label("扫码", systemImage: "qrcode.viewfinder")
                .font(.system(size: 15))
        }
        Button { showFileImporter = true } label: {
            Label("文件", systemImage: "doc")
                .font(.system(size: 15))
        }
        Button { showUnifiedImport = true } label: {
            Label("链接", systemImage: "link")
                .font(.system(size: 15))
        }
        Section {
            // FlClash add.dart:137-149: create the custom profile
            // at once and open its editor (isNew). The editor has
            // no isNew flag of its own — it opens the fresh,
            // still-unnamed subscription for editing, which is the
            // same flow.
            Button {
                let sub = CustomSubscriptionStore().create(name: "自定义订阅")
                navPath.append(.customSubscription(sub.id))
            } label: {
                Label("自定义订阅", systemImage: "doc.badge.gearshape")
                    .font(.system(size: 15))
            }
        }
    }

    // MARK: - Empty state (FlClash NullStatus)

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "暂无配置",
                systemImage: "square.stack",
                description: Text("添加一个配置文件后即可开始使用")
            )
            Menu {
                addProfileMenuItems
            } label: {
                Label("添加配置", systemImage: "plus.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(ConcordTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Grid of cards (FlClash _ProfilesGrid / ProfileItem)

    private var profileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
            spacing: 12
        ) {
            ForEach(profileStore.profiles) { profile in
                profileCard(profile)
                    .id(profile.id)
            }
        }
    }

    private func profileCard(_ profile: Profile) -> some View {
        Button {
            Task { await activate(profile) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.kind == .url ? "远程" : "本地")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // FlClash _GroupsCountChip (profiles.dart:585):
                    // the number of proxy groups, parsed locally.
                    if let count = groupCounts[profile.id], count > 0 {
                        Text("\(count) 个分组")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(ConcordTheme.accent)
                    }
                    if let note = profile.note {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if updatingIDs.contains(profile.id) {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else if let updated = profile.updatedAt {
                    Text(ConcordRelativeTime.string(since: updated))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if profile.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(16)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(profile.isActive ? ConcordTheme.accent : Color.clear, lineWidth: 2)
            )
            .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        // FlClash profiles.dart:614: no menu while updating.
        .contextMenu {
            if !updatingIDs.contains(profile.id) && !isUpdatingAll {
                Button { navPath.append(.edit(profile.id)) } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                        .font(.system(size: 15))
                }
                Button { navPath.append(.extend(profile.id)) } label: {
                    Label("扩展", systemImage: "plus.square.on.square")
                        .font(.system(size: 15))
                }
                if profile.kind == .url {
                    Button { Task { await sync(profile) } } label: {
                        Label("同步", systemImage: "arrow.clockwise")
                            .font(.system(size: 15))
                    }
                }
                Menu("更多") {
                    // FlClash profiles.dart:532-540: 运行时配置 opens
                    // the merged-config preview (the 生效配置 tab).
                    Button {
                        previewInitialTab = .built
                        previewProfile = profile
                    } label: {
                        Label("运行时配置", systemImage: "eye")
                            .font(.system(size: 15))
                    }
                    if profile.kind == .url {
                        Button { copyLink(profile) } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                                .font(.system(size: 15))
                        }
                        Button { qrProfile = profile } label: {
                            Label("二维码", systemImage: "qrcode")
                                .font(.system(size: 15))
                        }
                    }
                    Button { export(profile) } label: {
                        Label("导出文件", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15))
                    }
                }
                Button(role: .destructive) { deleteTarget = profile } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 15))
                }
            }
        }
    }

    // MARK: - Reorder sheet (FlClash ReorderableProfilesSheet)

    private var reorderSheet: some View {
        NavigationStack {
            List {
                ForEach(reorderDraft) { profile in
                    Text(profile.name)
                        .font(.system(size: 17, weight: .semibold))
                }
                .onMove { from, to in
                    reorderDraft.move(fromOffsets: from, toOffset: to)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("配置排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showReorder = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { 
                        profileStore.reorderProfiles(reorderDraft)
                        showReorder = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("保存")
                }
            }
        }
    }

    // MARK: - Actions

    private func activate(_ profile: Profile) async {
        await profileStore.activate(profile)
        if let error = profileStore.lastError {
            alertMessage = error
        }
    }

    private func sync(_ profile: Profile) async {
        guard profile.kind == .url else { return }
        updatingIDs.insert(profile.id)
        defer { updatingIDs.remove(profile.id) }
        await profileStore.update(profile)
        if let error = profileStore.lastError {
            alertMessage = error
        }
    }

    private func updateAll() async {
        guard !isUpdatingAll else { return }
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        let urlProfiles = profileStore.profiles.filter { $0.kind == .url }
        for profile in urlProfiles {
            updatingIDs.insert(profile.id)
        }
        defer { updatingIDs.removeAll() }
        // FlClash profiles.dart:52-76: one failure message per
        // failed profile, shown together — not just the last error.
        var failures: [(name: String, error: String)] = []
        for profile in urlProfiles {
            await profileStore.update(profile)
            if let error = profileStore.lastError {
                failures.append((profile.name, error))
            }
        }
        if !failures.isEmpty {
            alertMessage = "更新失败（\(failures.count) 个）：\n"
                + failures.map { "· \($0.name)：\($0.error)" }.joined(separator: "\n")
        }
    }

    /// Groups counts for the cards, from the local YAML parse
    /// (FlClash _GroupsCountChip).
    private func refreshGroupCounts() {
        var counts: [UUID: Int] = [:]
        for profile in profileStore.profiles {
            if let groups = profileStore.localProxyGroups(for: profile) {
                counts[profile.id] = groups.groups.count
            }
        }
        groupCounts = counts
    }

    private func copyLink(_ profile: Profile) {
        guard let urlString = profile.urlString else { return }
        UIPasteboard.general.string = urlString
        copyNotice = "复制成功"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            copyNotice = nil
        }
    }

    private func export(_ profile: Profile) {
        guard let url = profileStore.exportFileURL(for: profile) else {
            alertMessage = "导出失败：找不到该订阅的本地文件"
            return
        }
        exportURL = url
    }

    /// The + menu's 文件 item: read the picked .yaml through the
    /// security-scoped URL, then reuse UnifiedImporter's file path
    /// (importFileData -> importYamlDocument -> addFromFile). A
    /// failed read or a failed import surfaces in an alert with the
    /// importer's summary text — never swallowed silently.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                alertMessage = "读取文件失败：\(error.localizedDescription)"
                return
            }
            let importer = UnifiedImporter(profileStore: profileStore)
            Task { @MainActor in
                await importer.importFileData(data, fileName: url.lastPathComponent)
                if importer.results.allSatisfy({ !$0.succeeded }) {
                    alertMessage = importer.summaryText ?? "导入失败"
                }
            }
        case .failure(let error):
            alertMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - QR code sheet (FlClash dialogs.showQrCode)

private struct ProfileQRCodeView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss

    private var qrImage: UIImage? {
        guard let urlString = profile.urlString,
              let data = urlString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                } else {
                    Text("无法生成二维码：该订阅没有链接")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if let urlString = profile.urlString {
                    Text(urlString)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                Text("在另一台设备上用 FlClash 扫码即可导入此配置。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
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
    @State private var duplicateError: String?

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FlClash add.dart:76-79: the link form knows the existing
    /// URLs and refuses a duplicate.
    private var isDuplicateURL: Bool {
        guard !trimmedURL.isEmpty else { return false }
        return profileStore.profiles.contains {
            $0.urlString?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedURL
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅链接") {
                    TextField("名称（可选）", text: $name)
                        .font(.system(size: 17))
                    TextField("https://…/subscribe.yaml", text: $urlString)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if isDuplicateURL {
                        Text("这个订阅链接已经添加过了。")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                    Button("添加订阅") {
                        Task {
                            if isDuplicateURL {
                                duplicateError = "这个订阅链接已经添加过了。"
                                return
                            }
                            await profileStore.addFromURL(name: name, urlString: urlString)
                            dismiss()
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .disabled(urlString.isEmpty || isDuplicateURL)
                    if let duplicateError {
                        Text(duplicateError)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
                Section("本地文件") {
                    Button("导入本地配置文件（.yaml / .yml）") {
                        dismiss()
                        showImporter = true
                    }
                    .font(.system(size: 17, weight: .semibold))
                    Text("支持 Clash / mihomo YAML。导入后文件保存在 App Group 容器，扩展与主 App 共享。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("订阅更新调用 convert.subscription / provider.update；切换订阅调用 config.apply + profile.inspect。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
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
    /// The tab to open on: 运行时配置 opens the merged config.
    var initialTab: PreviewTab = .yaml
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
                            Text(error).font(.system(size: 13)).foregroundStyle(.red)
                        } else if let proxies = convertedProxies {
                            if proxies.isEmpty {
                                Text("该订阅没有解析出节点").font(.system(size: 13)).foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(proxies.enumerated()), id: \.offset) { _, proxy in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(proxy.objectValue?["name"]?.stringValue ?? "—").font(.system(size: 17, weight: .semibold))
                                        Text("\(proxy.objectValue?["type"]?.stringValue ?? "—") · \(proxy.objectValue?["server"]?.stringValue ?? "—")")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                case .built:
                    ScrollView {
                        if let error = previewError {
                            Text(error).font(.system(size: 13)).foregroundStyle(.red).padding()
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
            .background(ConcordTheme.pageBackground)
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                tab = initialTab
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
