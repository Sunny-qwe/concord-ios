import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreImage

// MARK: - Profiles (FlClash: lib/views/profiles/profiles.dart)
//
// FlClash structure, 1:1 where the iOS app has an equivalent:
// AppBar [更新 sync (only when profiles exist), 排序 sort (only
// when profiles exist), + addCircle menu (only when profiles
// exist)]; body is an empty state (NullStatus) or a grid of
// profile cards (LazyVGrid adaptive min 300pt -> 1 column on a
// 390pt iPhone). Upstream's AppBar also carries 节点来源 /
// 可视化配置 entries, but add.dart has no such entries — ours
// were removed in v0.2.146 (R-D3). Card tap = activate/select;
// long-press = context menu (编辑 / 扩展 / 同步 (URL) / 更多 submenu /
// 删除）. Reorder lives in its own sheet (配置排序）, never as
// long-press-to-reorder on the page. The API-tool sections that used
// to live on this page were removed in v0.2.41 (no UI surface left);
// the underlying ProfileStore/ConcordClient methods remain.
//
// Differences vs FlClash, all honest:
// - No .custom ProfileKind exists in this app (only url/file), so
//   every profile takes the non-custom menu path; there is no rename
//   action (renaming happens via the Edit page's name field).
//   Custom subscriptions are a separate model
//   (CustomSubscriptionStore) and render as their own cards in the
//   same grid below the profiles (FlClash _ProfilesGridView by
//   type); the groups-count chip lives only on those custom cards,
//   never on url/file cards (FlClash profiles.dart:532-533).
// - subscriptionInfo (used/total traffic, expiry) is stored on
//   Profile from the download's subscription-userinfo header, so
//   the card subtitle is the FlClash usage line when present and
//   the 远程 (URL) / 本地 (file) fallback otherwise; expiry shows
//   as "剩余 N 天" (≤ 7 天红色警告）.
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
    case customSubscription(UUID)
    case extend(UUID)
    case edit(UUID)
    case preview(UUID)
    /// QR-code scan import (upstream BaseNavigator.push(ScanPage),
    /// add.dart:31) — a full page push that returns the scanned
    /// text on pop, never a second sheet stacked on the scan.
    case scan
}

/// The unified-import form's single item: the text handed in and
/// whether to auto-import it ("" / false from the + menu, the
/// scanned text / true from the scan page).
private struct UnifiedImportDraft: Identifiable {
    let id = UUID()
    let text: String
    let autoImport: Bool
}

/// The exported profile file for the system save-file picker
/// (upstream _handleExportFile).
private struct ProfileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.yaml] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ProfilesView: View {
    /// Picker mode (FlClash profiles.dart:32-38,108-131): as a
    /// dashboard sheet the page hides all bar actions and the add
    /// menu and skips reveal-selected. Used from the dashboard
    /// profile detail (dashboard/widgets/profile_detail.dart:36).
    let picker: Bool

    init(picker: Bool = false) { self.picker = picker }

    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customStore = CustomSubscriptionStore()
    @State private var navPath: [ProfileNavDestination] = []
    /// Unified import form (upstream showNamedUrlsForm /
    /// showFormSheet): ONE item is the single source — the text
    /// handed in ("" from the + menu, the scanned text from the
    /// scan page) and whether to auto-import it. No separate Bool
    /// + scanned-text state.
    @State private var unifiedImportDraft: UnifiedImportDraft?
    @State private var showCustomSubscriptionImport = false
    @State private var showFileImporter = false
    @State private var showReorder = false
    @State private var reorderDraft: [Profile] = []
    @State private var qrProfile: Profile?
    @State private var renameTarget: CustomSubscription?
    @State private var renameText = ""
    /// Export (upstream _handleExportFile): the system save-file
    /// picker + a success banner — no share sheet. The document
    /// is the single source for the fileExporter.
    @State private var showFileExporter = false
    @State private var exportDocument: ProfileExportDocument?
    @State private var exportFileName = "config.yaml"
    @State private var deleteTarget: Profile?
    @State private var updatingIDs: Set<UUID> = []
    @State private var isUpdatingAll = false
    @State private var copyNotice: String?
    @State private var alertMessage: String?
    /// The + menu's 文件 importer, kept alive so the age-key
    /// prompt (below) can retry the same file with the key.
    @State private var fileImporter: UnifiedImporter?
    @State private var showAgeKeyPrompt = false
    @State private var ageKeyInput = ""

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
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if profileStore.profiles.isEmpty && customStore.subscriptions.isEmpty {
                            emptyState
                        } else {
                            profileGrid
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, ConcordTheme.tabBarClearance)
                }
                .onAppear {
                    if !picker, let active = profileStore.activeProfile {
                        scrollProxy.scrollTo(active.id, anchor: .center)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ConcordTheme.pageBackground)
            // FlClash pageTitle is 24pt semibold on a tab page
            // (scaffold.dart:780: compactTitle is false — isCompact
            // is true only for bottom/form sheets, sheet.dart:42,
            // and pushed is false at a tab root). SwiftUI's inline
            // title is fixed at 17pt, so the title is a leading
            // toolbar item instead. Pushed pages keep their 17pt
            // inline title.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("title.profiles".l10n)
                        .font(.system(size: 24, weight: .bold))
                }
                if hasProfiles && !picker {
                    // Top bar holds only the refresh+sort capsule
                    // and the ＋ button (upstream add.dart has no
                    // 节点来源 / 可视化配置 entries — they were
                    // removed from the ＋ menu in v0.2.146; the
                    // destination views still exist and stay
                    // reachable from their own links).
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Button { Task { await updateAll() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("common.update".l10n)
                            .disabled(isUpdatingAll)
                            Divider()
                                .frame(height: 16)
                            Button {
                                reorderDraft = profileStore.profiles
                                showReorder = true
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                            .accessibilityLabel("profiles.sort".l10n)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ConcordTheme.cardBackground, in: Capsule())
                    }
                    // v0.2.72: the + gets the same white circular
                    // background as the neighbouring pill and the
                    // Proxies ⋯ button — the bare plus.circle outline
                    // had no rounded background (IMG_1216). Plain
                    // `plus` on the circle (plus.circle would draw
                    // a second circle outline inside it).
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            addProfileMenuItems
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(ConcordTheme.cardBackground, in: Circle())
                        }
                        .accessibilityLabel("profiles.add".l10n)
                    }
                }
            }
            .navigationDestination(for: ProfileNavDestination.self) { destination in
                // v0.2.83 white-bar fix: the bar blends with the page
                // background on every Profiles sub-page.
                Group {
                    switch destination {
                    case .nodeSources:
                    NodeSourcesView()
                case .visualConfig:
                    VisualConfigView()
                case .customSubscription(let id):
                    CustomSubscriptionEditorView(subscriptionID: id)
                case .extend(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        ExtendConfigView(profile: profile)
                    } else {
                        ContentUnavailableView("profiles.deleted".l10n, systemImage: "trash")
                    }
                case .edit(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        EditProfileView(profile: profile)
                    } else {
                        ContentUnavailableView("profiles.deleted".l10n, systemImage: "trash")
                    }
                case .preview(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        ProfilePreviewView(profile: profile)
                    } else {
                        ContentUnavailableView("profiles.deleted".l10n, systemImage: "trash")
                    }
                case .scan:
                    // ScanImportView keeps its own NavigationStack
                    // (it was built as a sheet) and its 取消 button
                    // pops the page; on a good scan it calls
                    // onScanned and dismisses itself, and the
                    // unified-import form opens from the draft.
                    ScanImportView { text in
                        unifiedImportDraft = UnifiedImportDraft(text: text, autoImport: true)
                    }
                    }
                }
                .concordNavBarBackground()
            }
            .sheet(item: $unifiedImportDraft) { draft in
                UnifiedImportView(profileStore: profileStore, initialText: draft.text, autoImport: draft.autoImport)
                    .formSheetChrome()
            }
            .sheet(isPresented: $showCustomSubscriptionImport) {
                CustomSubscriptionImportView(store: customStore) { sub in
                    navPath.append(.customSubscription(sub.id))
                }
                .formSheetChrome()
            }
            .sheet(isPresented: $showReorder) {
                reorderSheet
                    .formSheetChrome()
            }
            // QR code is a floating dialog (upstream dialogs
            // .showQrCode → showCommonDialog AlertDialog with a
            // 关闭 button), not a sheet: a dimmed scrim + a
            // centred card. Tapping the scrim closes it too.
            .overlay {
                if let profile = qrProfile {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture { qrProfile = nil }
                        ProfileQRCodeDialog(profile: profile) {
                            qrProfile = nil
                        }
                        .padding(.horizontal, 32)
                    }
                }
            }
            // Export: the system save-file picker; success shows
            // the green banner, failure an alert (upstream
            // _handleExportFile, profiles.dart:381).
            .fileExporter(isPresented: $showFileExporter, document: exportDocument, contentType: .yaml, defaultFilename: exportFileName) { result in
                switch result {
                case .success:
                    copyNotice = "profiles.notice.exportOk".l10n
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        copyNotice = nil
                    }
                case .failure(let error):
                    alertMessage = "\("profiles.notice.exportFailed".l10n)\(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.yaml, UTType.plainText]) { result in
                handlePickedFile(result)
            }
            // Age-encrypted file import (upstream _withAgeSecretKey):
            // the picked file needs its key before it can be
            // decrypted. A sheet, not a third .alert on this view
            // (two .alert modifiers already fight each other here).
            .sheet(isPresented: $showAgeKeyPrompt) {
                NavigationStack {
                    Form {
                        Section {
                            SecureField("age 私钥", text: $ageKeyInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } header: {
                            Text("该文件是 age 加密的")
                        } footer: {
                            Text("输入私钥解密后导入。私钥仅保存在本机（随订阅保存，用于以后更新）。")
                                .font(.footnote)
                        }
                    }
                    .navigationTitle("age 私钥")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") {
                                fileImporter?.pendingAgeFile = nil
                                fileImporter = nil
                                ageKeyInput = ""
                                showAgeKeyPrompt = false
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("导入") {
                                let key = ageKeyInput
                                ageKeyInput = ""
                                showAgeKeyPrompt = false
                                Task { @MainActor in
                                    guard let importer = fileImporter,
                                          let pending = importer.pendingAgeFile else { return }
                                    await importer.importFileData(pending.data, fileName: pending.fileName, ageSecretKey: key)
                                    if importer.results.allSatisfy({ !$0.succeeded }) {
                                        alertMessage = importer.summaryText ?? "profiles.notice.importFailed".l10n
                                    }
                                    fileImporter = nil
                                }
                            }
                            .disabled(ageKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .formSheetChrome()
            }
            .alert("profiles.rename.title".l10n, isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("profiles.rename.namePlaceholder".l10n, text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("common.save".l10n) {
                    if let target = renameTarget {
                        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            var copy = target
                            copy.name = name
                            customStore.update(copy)
                        }
                    }
                    renameTarget = nil
                }
                Button("common.cancel".l10n, role: .cancel) { renameTarget = nil }
            } message: {
                Text("profiles.rename.hint".l10n)
            }
            // One alert for the whole page (two .alert modifiers on
            // the same view fight each other): it shows either the
            // delete confirmation or a plain message alert.
            .alert("profiles.notice.title".l10n, isPresented: Binding(
                get: { alertMessage != nil || deleteTarget != nil },
                set: { if !$0 { alertMessage = nil; deleteTarget = nil } }
            )) {
                if deleteTarget != nil {
                    Button("common.delete".l10n, role: .destructive) {
                        if let profile = deleteTarget {
                            deleteTarget = nil
                            // FlClash deleteProfile: deleting the
                            // active profile switches to the next one
                            // (or stops the VPN when none remain) —
                            // never leaves the tunnel running deleted
                            // config.
                            Task {
                                await profileStore.deleteProfile(profile)
                                if let error = profileStore.lastError {
                                    alertMessage = error
                                }
                            }
                        } else {
                            deleteTarget = nil
                        }
                    }
                    Button("common.cancel".l10n, role: .cancel) { deleteTarget = nil }
                } else {
                    Button("common.ok".l10n, role: .cancel) {}
                }
            } message: {
                if let profile = deleteTarget {
                    Text(deleteMessage(for: profile))
                } else {
                    Text(alertMessage ?? "")
                }
            }
        }
        .toolbarBackground(ConcordTheme.pageBackground, for: .navigationBar)
    }

    // MARK: - Add menu (FlClash AddProfileMenu, minus TV-only
    // "从手机发送" which has no iOS equivalent)

    @ViewBuilder
    private var addProfileMenuItems: some View {
        Button { navPath.append(.scan) } label: {
            Label("profiles.addMenu.scan".l10n, systemImage: "qrcode.viewfinder")
                .font(.subheadline)
        }
        Button { showFileImporter = true } label: {
            Label("profiles.addMenu.file".l10n, systemImage: "doc")
                .font(.subheadline)
        }
        Button { unifiedImportDraft = UnifiedImportDraft(text: "", autoImport: false) } label: {
            Label("profiles.addMenu.link".l10n, systemImage: "link")
                .font(.subheadline)
        }
        Section {
            // FlClash add.dart:137-149: create the custom profile
            // at once and open its editor (isNew). The editor has
            // no isNew flag of its own — it opens the fresh,
            // still-unnamed subscription for editing, which is the
            // same flow.
            Button {
                let sub = CustomSubscriptionStore().create(name: "profiles.new.defaultName".l10n)
                navPath.append(.customSubscription(sub.id))
            } label: {
                Label("profiles.new.defaultName".l10n, systemImage: "doc.badge.gearshape")
                    .font(.subheadline)
            }
            // v0.2.55: import a Clash-style YAML file/URL as a custom
            // subscription (groups/providers/rules only; nodes are
            // rejected with an explanation — see CustomSubscriptionImport).
            Button { showCustomSubscriptionImport = true } label: {
                Label("profiles.addMenu.importCustom".l10n, systemImage: "arrow.down.doc")
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Empty state (FlClash NullStatus)

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "profiles.empty.title".l10n,
                systemImage: "square.stack",
                description: Text("profiles.empty.hint".l10n)
            )
            Menu {
                addProfileMenuItems
            } label: {
                Label("profiles.add".l10n, systemImage: "plus.circle")
                    .font(.headline)
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
    //
    // FlClash renders custom subscriptions directly in this grid
    // (_ProfilesGridView by type); the separate custom-subscription
    // list page is gone, so the custom cards live here, with tap
    // opening CustomSubscriptionEditorView directly.

    private var profileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
            spacing: 12
        ) {
            ForEach(profileStore.profiles) { profile in
                profileCard(profile)
                    .id(profile.id)
            }
            ForEach(customStore.subscriptions) { sub in
                customSubscriptionCard(sub)
                    .id(sub.id)
            }
        }
    }

    /// A custom subscription as a grid card (FlClash custom
    /// ProfileItem): name, counts subtitle, and the groups-count
    /// chip — the chip FlClash shows ONLY on custom cards
    /// (profiles.dart:532-533, _GroupsCountChip). Tap opens the
    /// editor directly; rename lives in the editor's name field.
    private func customSubscriptionCard(_ sub: CustomSubscription) -> some View {
        Button {
            navPath.append(.customSubscription(sub.id))
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sub.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(String(format: "profiles.summary.counts".l10n, "\(sub.groups.count)", "\(sub.rules.count)", "\(sub.proxyProviders.count + sub.ruleProviders.count)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if sub.groups.count > 0 {
                        Text(String(format: "profiles.summary.groups".l10n, "\(sub.groups.count)"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(ConcordTheme.accent)
                    }
                }
                Spacer()
                if let active = profileStore.activeProfile,
                   CustomSubscriptionStore.bakedSubscriptionID(for: active.id) == sub.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(16)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.cardRadius))
            .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { navPath.append(.customSubscription(sub.id)) } label: {
                Label("common.edit".l10n, systemImage: "square.and.pencil")
                    .font(.subheadline)
            }
            Button {
                renameTarget = sub
                renameText = sub.name
            } label: {
                Label("profiles.rename.title".l10n, systemImage: "pencil")
                    .font(.subheadline)
            }
            Button(role: .destructive) { customStore.delete(sub) } label: {
                Label("common.delete".l10n, systemImage: "trash")
                    .font(.subheadline)
            }
        }
    }

    private func profileCard(_ profile: Profile) -> some View {
        Button {
            Task { await activate(profile) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    // MuYu (v0.2.68): expiry renders as a DATE
                    // pill ("2026-12-03", accent text on accent
                    // low-opacity background), not "剩余 N 天".
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let info = profile.subscriptionInfo,
                           profile.kind == .url,
                           let dateText = info.expiryDateString {
                            Text(dateText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(ConcordTheme.accent)
                                .lineLimit(1)
                        }
                    }
                    // FlClash card subtitle: the usage line when
                    // the provider sent subscription-userinfo, else
                    // the 远程 / 本地 fallback.
                    Text(profileSubtitle(profile))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // FlClash _GroupsCountChip (profiles.dart:585)
                    // shows ONLY on custom-type profile cards, and
                    // this app has no custom ProfileKind — so no
                    // chip on url/file cards. Custom subscriptions
                    // get the chip on their own grid cards below.
                    // FlClash's Profile model has no note field, so
                    // there is no note row here either.
                }
                Spacer()
                if updatingIDs.contains(profile.id) {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else if let updated = profile.updatedAt {
                    Text(ConcordRelativeTime.string(since: updated))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if profile.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(ConcordTheme.accent)
                }
            }
            .padding(16)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.cardRadius))
            .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !updatingIDs.contains(profile.id) && !isUpdatingAll {
                Button { navPath.append(.edit(profile.id)) } label: {
                    Label("common.edit".l10n, systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
                Button { navPath.append(.extend(profile.id)) } label: {
                    Label("profiles.menu.extend".l10n, systemImage: "plus.square.on.square")
                        .font(.subheadline)
                }
                if profile.kind == .url {
                    Button { Task { await sync(profile) } } label: {
                        Label("profiles.menu.sync".l10n, systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
                Menu("common.more".l10n) {
                    // FlClash profiles.dart:532-540: 运行时配置 opens
                    // the merged-config preview (the 生效配置 tab).
                    Button {
                        navPath.append(.preview(profile.id))
                    } label: {
                        Label("profiles.menu.runtimeConfig".l10n, systemImage: "eye")
                            .font(.subheadline)
                    }
                    if profile.kind == .url {
                        Button { copyLink(profile) } label: {
                            Label("profiles.menu.copyLink".l10n, systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        Button { qrProfile = profile } label: {
                            Label("profiles.menu.qrCode".l10n, systemImage: "qrcode")
                                .font(.subheadline)
                        }
                    }
                    Button { export(profile) } label: {
                        Label("profiles.menu.exportFile".l10n, systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
                Button(role: .destructive) { deleteTarget = profile } label: {
                    Label("common.delete".l10n, systemImage: "trash")
                        .font(.subheadline)
                }
            }
        }
    }

    // MARK: - Reorder sheet (FlClash ReorderableProfilesSheet)

    private var reorderSheet: some View {
        NavigationStack {
            List {
                ForEach(reorderDraft) { profile in
                    HStack {
                        Text(profile.name)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in
                    reorderDraft.move(fromOffsets: from, toOffset: to)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("profiles.reorder.title".l10n)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel".l10n) { showReorder = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { 
                        profileStore.reorderProfiles(reorderDraft)
                        showReorder = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("common.save".l10n)
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
            alertMessage = "\("profiles.notice.updateFailedPrefix".l10n)\(failures.count)\("profiles.notice.updateFailedSuffix".l10n)\n"
                + failures.map { "· \($0.name)：\($0.error)" }.joined(separator: "\n")
        }
    }

    /// Custom subscriptions that use this profile as a
    /// provider (FlClash profilesAction.providerUsers): deleting
    /// the profile breaks their provider reference, so the confirm
    /// names them (profiles.dart:288-310 providerInUse).
    ///
    /// Upstream asks the core's reference graph (its database
    /// profileIdsUsing / profileIdsUsingRuleProvider); the core
    /// has no such query and no profile concept, so this is the
    /// Swift-side equivalent over the stored custom
    /// subscriptions: a subscription references the profile when
    /// a group USES it (`use:` — upstream checks only proxy-kind
    /// use, providers/actions/profiles.dart:82-92) or a RULE-SET
    /// rule names it as its payload. DEFINING a provider of that
    /// name is NOT use — the definition has its own URL and the
    /// profile is never consulted for it — so the old
    /// proxyProviders / ruleProviders name match was a false
    /// positive (the dialog claimed the profile was in use when
    /// nothing referenced it) and is dropped. Name-based, like
    /// the bake linkage — a provider is referenced by name,
    /// never by id.
    private func providerUsers(of profile: Profile) -> [String] {
        customStore.subscriptions
            .filter { sub in
                sub.groups.contains(where: { $0.useProviders.contains(profile.name) })
                || sub.rules.contains(where: { $0.type == "RULE-SET" && $0.content == profile.name })
            }
            .map { $0.name }
    }

    private func deleteMessage(for profile: Profile) -> String {
        let users = providerUsers(of: profile)
        guard !users.isEmpty else { return "\("profiles.delete.confirmPrefix".l10n)\(profile.name)\("profiles.delete.confirmSuffix".l10n)" }
        return "\("common.quote.open".l10n)\(profile.name)\("profiles.delete.usedByPrefix".l10n)\(users.joined(separator: "common.listSeparator".l10n))\("profiles.delete.usedByMiddle".l10n)\("profiles.delete.confirmPrefix".l10n)\(profile.name)\("profiles.delete.confirmSuffix".l10n)"
    }

    /// Card subtitle for one profile: bare "X / Y" (MuYu,
    /// v0.2.68 — no "已用"/"共" prefixes) when the provider sent
    /// subscription-userinfo, else 远程 / 本地.
    private func profileSubtitle(_ profile: Profile) -> String {
        if profile.kind == .url, let line = profile.subscriptionInfo?.usageLine {
            return line
        }
        return profile.kind == .url ? "common.remote".l10n : "common.local".l10n
    }

    private func copyLink(_ profile: Profile) {
        guard let urlString = profile.urlString else { return }
        UIPasteboard.general.string = urlString
        copyNotice = "profiles.notice.copyOk".l10n
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            copyNotice = nil
        }
    }

    /// Export (upstream _handleExportFile, profiles.dart:381):
    /// open the system save-file picker for the profile's local
    /// file; the success banner / failure alert come from the
    /// fileExporter's completion.
    private func export(_ profile: Profile) {
        guard let url = profileStore.exportFileURL(for: profile) else {
            alertMessage = "profiles.notice.exportNoFile".l10n
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            alertMessage = "profiles.notice.exportUnreadable".l10n
            return
        }
        exportDocument = ProfileExportDocument(data: data)
        exportFileName = url.lastPathComponent
        showFileExporter = true
    }

    /// The + menu's 文件 item: read the picked .yaml through the
    /// security-scoped URL, then reuse UnifiedImporter's file path
    /// (importFileData -> importYamlDocument -> addFromFile). A
    /// failed read or a failed import surfaces in an alert with the
    /// importer's summary text — never swallowed silently. An
    /// age-encrypted file opens the key prompt instead (the
    /// importer keeps the pending file); no failure alert is
    /// shown for that case.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                alertMessage = "\("profiles.notice.readFailed".l10n)\(error.localizedDescription)"
                return
            }
            let importer = UnifiedImporter(profileStore: profileStore)
            fileImporter = importer
            Task { @MainActor in
                await importer.importFileData(data, fileName: url.lastPathComponent)
                if importer.pendingAgeFile != nil {
                    showAgeKeyPrompt = true
                    return
                }
                fileImporter = nil
                if importer.results.allSatisfy({ !$0.succeeded }) {
                    alertMessage = importer.summaryText ?? "profiles.notice.importFailed".l10n
                }
            }
        case .failure(let error):
            alertMessage = "\("providers.import.pickFileFailed".l10n)\(error.localizedDescription)"
        }
    }
}

// MARK: - QR code sheet (FlClash dialogs.showQrCode)

/// QR-code dialog (upstream dialogs.showQrCode → showCommonDialog
/// AlertDialog): a centred floating card over a dimmed scrim, not
/// a sheet. The scrim tap (in the overlay) and the 关闭 button
/// both close it.
private struct ProfileQRCodeDialog: View {
    let profile: Profile
    let onClose: () -> Void
    /// Generated off the main thread (see the .task below): the
    /// CIFilter + CIContext render used to run inside body
    /// evaluation and stall the sheet's first frame, title included.
    @State private var qrImage: UIImage?
    @State private var qrGenerated = false

    private static func makeQRImage(for profile: Profile) -> UIImage? {
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
        VStack(spacing: 16) {
            Text(profile.name)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            } else if !qrGenerated {
                ProgressView()
                    .frame(width: 240, height: 240)
            } else {
                Text("profiles.qr.noLink".l10n)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let urlString = profile.urlString {
                Text(urlString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            Text("profiles.qr.hint".l10n)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("common.close".l10n) { onClose() }
                .buttonStyle(.borderedProminent)
                .tint(ConcordTheme.accent)
        }
        .padding(24)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .task {
            let image = await Task.detached(priority: .userInitiated) {
                Self.makeQRImage(for: profile)
            }.value
            qrImage = image
            qrGenerated = true
        }
    }
}

// Profile preview (FlClash profiles/preview.dart): ONLY the
// built-config editor — PreviewProfileView is an EditorPage over the
// merged effective config (profile.build). There are no "原始 YAML"
// or "节点列表" tabs; the raw YAML is read from the Edit page's file
// row and the node list lives in Proxies.
struct ProfilePreviewView: View {
    let profile: Profile
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var builtText: String?
    @State private var previewError: String?
    /// Find + copy affordances (FlClash preview IS an EditorPage,
    /// preview.dart:12-21 — read-only in practice, but with the
    /// editor's find/selection/copy surface; ours was a bare Text).
    @State private var findText = ""
    @State private var copied = false

    private var matchCount: Int {
        guard let built = builtText, !findText.isEmpty else { return 0 }
        return built.components(separatedBy: findText).count - 1
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("profiles.editor.findPlaceholder".l10n, text: $findText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !findText.isEmpty {
                        Text(matchCount > 0 ? "\(matchCount)\("profiles.editor.matchCountSuffix".l10n)" : "profiles.editor.noMatch".l10n)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button { findText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                ScrollView {
                    if let error = previewError {
                        Text(error).font(.footnote).foregroundStyle(.red).padding()
                    } else if let built = builtText {
                        Text(built)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        ProgressView().padding()
                    }
                }
                // v0.2.66: tab-bar clearance for pushed pages
                .contentMargins(.bottom, ConcordTheme.tabBarClearance)
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "common.copied".l10n : "common.copy".l10n) {
                        if let built = builtText {
                            UIPasteboard.general.string = built
                            copied = true
                        }
                    }
                    .disabled(builtText == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".l10n) { dismiss() }
                }
            }
            .task {
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
