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
    @State private var showUnifiedImport = false
    @State private var showCustomSubscriptionImport = false
    @State private var showScanImport = false
    @State private var scannedText: String?
    @State private var showFileImporter = false
    @State private var showReorder = false
    @State private var reorderDraft: [Profile] = []
    @State private var qrProfile: Profile?
    @State private var renameTarget: CustomSubscription?
    @State private var renameText = ""
    @State private var exportURL: URL?
    @State private var deleteTarget: Profile?
    @State private var updatingIDs: Set<UUID> = []
    @State private var isUpdatingAll = false
    @State private var copyNotice: String?
    @State private var alertMessage: String?

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
                    // MuYu (v0.2.68): ONE capsule holding refresh +
                    // sort, plus a SEPARATE ＋ circle button. The
                    // globe (节点来源） and slider (可视化配置） move
                    // into the ＋ menu (see addProfileMenuItems) —
                    // no feature is lost.
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Button { Task { await updateAll() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("更新")
                            .disabled(isUpdatingAll)
                            Divider()
                                .frame(height: 16)
                            Button {
                                reorderDraft = profileStore.profiles
                                showReorder = true
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                            .accessibilityLabel("排序")
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
                case .preview(let id):
                    if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                        ProfilePreviewView(profile: profile)
                    } else {
                        ContentUnavailableView("订阅已删除", systemImage: "trash")
                    }
                }
            }
            .sheet(isPresented: $showUnifiedImport, onDismiss: { scannedText = nil }) {
                UnifiedImportView(profileStore: profileStore, initialText: scannedText ?? "", autoImport: scannedText != nil)
            }
            .sheet(isPresented: $showCustomSubscriptionImport) {
                CustomSubscriptionImportView(store: customStore) { sub in
                    navPath.append(.customSubscription(sub.id))
                }
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
                                .font(.headline)
                            ShareLink(item: url) {
                                Label("分享配置文件", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ConcordTheme.accent)
                            Text("导出成功")
                                .font(.footnote)
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
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("订阅名称", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("保存") {
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
                Button("取消", role: .cancel) { renameTarget = nil }
            } message: {
                Text("为自定义订阅改一个名字。")
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
                    Button("取消", role: .cancel) { deleteTarget = nil }
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
        // v0.2.68 (MuYu): 节点来源 / 可视化配置 moved here from
        // the top bar — the top bar now holds only the
        // refresh+sort capsule and the ＋ button.
        Button { navPath.append(.nodeSources) } label: {
            Label("节点来源", systemImage: "globe")
                .font(.subheadline)
        }
        Button { navPath.append(.visualConfig) } label: {
            Label("可视化配置", systemImage: "slider.horizontal.3")
                .font(.subheadline)
        }
        Button { showScanImport = true } label: {
            Label("扫码", systemImage: "qrcode.viewfinder")
                .font(.subheadline)
        }
        Button { showFileImporter = true } label: {
            Label("文件", systemImage: "doc")
                .font(.subheadline)
        }
        Button { showUnifiedImport = true } label: {
            Label("链接", systemImage: "link")
                .font(.subheadline)
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
                    .font(.subheadline)
            }
            // v0.2.55: import a Clash-style YAML file/URL as a custom
            // subscription (groups/providers/rules only; nodes are
            // rejected with an explanation — see CustomSubscriptionImport).
            Button { showCustomSubscriptionImport = true } label: {
                Label("导入自定义订阅（YAML）", systemImage: "arrow.down.doc")
                    .font(.subheadline)
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
                    Text("\(sub.groups.count) 分组 · \(sub.rules.count) 规则 · \(sub.proxyProviders.count + sub.ruleProviders.count) 提供方")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if sub.groups.count > 0 {
                        Text("\(sub.groups.count) 个分组")
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
                Label("编辑", systemImage: "square.and.pencil")
                    .font(.subheadline)
            }
            Button {
                renameTarget = sub
                renameText = sub.name
            } label: {
                Label("重命名", systemImage: "pencil")
                    .font(.subheadline)
            }
            Button(role: .destructive) { customStore.delete(sub) } label: {
                Label("删除", systemImage: "trash")
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
                    Label("编辑", systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
                Button { navPath.append(.extend(profile.id)) } label: {
                    Label("扩展", systemImage: "plus.square.on.square")
                        .font(.subheadline)
                }
                if profile.kind == .url {
                    Button { Task { await sync(profile) } } label: {
                        Label("同步", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
                Menu("更多") {
                    // FlClash profiles.dart:532-540: 运行时配置 opens
                    // the merged-config preview (the 生效配置 tab).
                    Button {
                        navPath.append(.preview(profile.id))
                    } label: {
                        Label("运行时配置", systemImage: "eye")
                            .font(.subheadline)
                    }
                    if profile.kind == .url {
                        Button { copyLink(profile) } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        Button { qrProfile = profile } label: {
                            Label("二维码", systemImage: "qrcode")
                                .font(.subheadline)
                        }
                    }
                    Button { export(profile) } label: {
                        Label("导出文件", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
                Button(role: .destructive) { deleteTarget = profile } label: {
                    Label("删除", systemImage: "trash")
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

    /// Custom subscriptions that use this profile as a proxy
    /// provider (FlClash profilesAction.providerUsers): deleting
    /// the profile breaks their provider reference, so the confirm
    /// names them (profiles.dart:288-310 providerInUse).
    private func providerUsers(of profile: Profile) -> [String] {
        customStore.subscriptions
            .filter { $0.proxyProviders.contains(where: { $0.name == profile.name }) }
            .map { $0.name }
    }

    private func deleteMessage(for profile: Profile) -> String {
        let users = providerUsers(of: profile)
        guard !users.isEmpty else { return "确定删除当前\(profile.name)吗？" }
        return "「\(profile.name)」正被以下自定义订阅用作提供方：\(users.joined(separator: "、"))。删除后这些订阅的提供方引用会失效。确定删除当前\(profile.name)吗？"
    }

    /// Card subtitle for one profile: bare "X / Y" (MuYu,
    /// v0.2.68 — no "已用"/"共" prefixes) when the provider sent
    /// subscription-userinfo, else 远程 / 本地.
    private func profileSubtitle(_ profile: Profile) -> String {
        if profile.kind == .url, let line = profile.subscriptionInfo?.usageLine {
            return line
        }
        return profile.kind == .url ? "远程" : "本地"
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
        NavigationStack {
            VStack(spacing: 16) {
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
                    Text("无法生成二维码：该订阅没有链接")
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
                Text("在另一台设备上用 FlClash 扫码即可导入此配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let image = await Task.detached(priority: .userInitiated) {
                    Self.makeQRImage(for: profile)
                }.value
                qrImage = image
                qrGenerated = true
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
                    TextField("在配置中查找", text: $findText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !findText.isEmpty {
                        Text(matchCount > 0 ? "\(matchCount) 处" : "无匹配")
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
                    Button(copied ? "已复制" : "复制") {
                        if let built = builtText {
                            UIPasteboard.general.string = built
                            copied = true
                        }
                    }
                    .disabled(builtText == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
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
