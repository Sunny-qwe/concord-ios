import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Import page (one item at a time)
// Paste ONE subscription link, node share link or a whole YAML
// config — the page detects what it is, imports just that one, and
// activates it. A second link is pasted separately (the user asked
// for one-at-a-time, not batch). Link subscriptions that return
// base64 node links are decoded and rebuilt into a Clash config by
// ProfileStore, so they import like any other subscription.

struct UnifiedImportView: View {
    let profileStore: ProfileStore

    @StateObject private var importer: UnifiedImporter
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""
    @State private var profileName = ""
    @State private var showFileImporter = false
    @State private var showLegacyAdd = false
    @State private var clipboardNotice: String?

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        _importer = StateObject(wrappedValue: UnifiedImporter(profileStore: profileStore))
    }

    /// The single item currently in the field, if recognisable.
    private var detectedKind: ImportKind {
        UnifiedImporter.singleItemKind(importText)
    }

    private var isRecognised: Bool {
        detectedKind != .unknown
    }

    private var canImport: Bool {
        !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !importer.isImporting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    linkCard
                    nameCard
                    importButton
                    if !importer.results.isEmpty {
                        resultsSection
                    }
                    if let summary = importer.summaryText {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actionsCard
                    tipText
                }
                .padding(16)
            }
            .concordPageBackground()
            .navigationTitle("导入配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if importText.isEmpty,
                   let clip = UIPasteboard.general.string,
                   let item = UnifiedImporter.singleItemText(clip) {
                    importText = item
                    clipboardNotice = "已从剪贴板填入一条\(UnifiedImporter.singleItemKind(clip).rawValue)，检查后点「导入」"
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.yaml, UTType.plainText]) { result in
                if case .success(let url) = result,
                   let data = try? Data(contentsOf: url) {
                    Task { await importer.importFileData(data, fileName: url.lastPathComponent) }
                }
            }
            .sheet(isPresented: $showLegacyAdd) {
                // The legacy sheet's "从文件导入" button drives this
                // view's file importer. The picker cannot present
                // while the legacy sheet is still on screen, so
                // dismiss the sheet first and open the picker after
                // the dismissal animation.
                AddProfileView(showImporter: Binding(
                    get: { showFileImporter },
                    set: { newValue in
                        if newValue {
                            showLegacyAdd = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                showFileImporter = true
                            }
                        } else {
                            showFileImporter = false
                        }
                    }
                ))
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ConcordTheme.accent.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ConcordTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("导入订阅或节点")
                    .font(.system(size: 17, weight: .bold))
                Text("一次导入一个：粘贴一条订阅链接或节点链接，点导入就行。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .concordCard()
    }

    // MARK: - Link field

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("链接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kindChip
                }
            }
            HStack(spacing: 8) {
                TextField("粘贴订阅链接或节点链接", text: $importText)
                    .font(.system(size: 15))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(1)
                if !importText.isEmpty {
                    Button {
                        importText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    if let clip = UIPasteboard.general.string,
                       let item = UnifiedImporter.singleItemText(clip) {
                        importText = item
                        clipboardNotice = "已填入一条\(UnifiedImporter.singleItemKind(clip).rawValue)"
                    } else {
                        clipboardNotice = "剪贴板里没有可导入的链接"
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(ConcordTheme.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 14))
            Text("支持订阅链接（http / https）、ss / vmess / trojan / vless 等节点链接，或整段 YAML 配置。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let notice = clipboardNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(ConcordTheme.accent)
            }
        }
        .concordCard()
    }

    private var kindChip: some View {
        Text(detectedKind.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (isRecognised ? ConcordTheme.accent : Color.red).opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isRecognised ? ConcordTheme.accent : Color.red)
    }

    // MARK: - Name field

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("名称（可选）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("例如：我的订阅", text: $profileName)
                .font(.system(size: 15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 14))
            Text("不填就用链接的域名当名字；节点链接会生成「我的节点」。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .concordCard()
    }

    // MARK: - Import button

    private var importButton: some View {
        Button {
            Task {
                await importer.importText(importText, name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : profileName.trimmingCharacters(in: .whitespacesAndNewlines))
                // Success: clear the field so the next link can be
                // pasted straight away. Failure: keep the text so
                // the user can fix it.
                if importer.activatedName != nil {
                    importText = ""
                    profileName = ""
                    clipboardNotice = nil
                }
            }
        } label: {
            Group {
                if importer.isImporting {
                    ProgressView().tint(.white)
                } else {
                    Text("导入").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .tint(ConcordTheme.accent)
        .disabled(!canImport)
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入结果")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(importer.results) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.kind.rawValue)
                                .font(.system(size: 10))
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(ConcordTheme.accent)
                            Text(result.line)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(result.message)
                            .font(.system(size: 13))
                    }
                    Spacer()
                }
                .padding(12)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
            }
        }
    }

    // MARK: - Secondary actions

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button { showFileImporter = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(ConcordTheme.accent)
                        .frame(width: 24)
                    Text("从文件导入")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            Divider()
            Button { showLegacyAdd = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(ConcordTheme.accent)
                        .frame(width: 24)
                    Text("使用旧版添加方式")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .concordCard()
    }

    private var tipText: some View {
        Text("导入成功后会自动切换到这个配置，去仪表盘点播放键启动即可；首次安装需先在系统设置里信任开发者证书。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}
