import SwiftUI
import UIKit

// MARK: - Import from link (FlClash: lib/views/profiles/add.dart)
// ONE of the three separate add entries (the others are the 文件
// picker and the 扫码 page, both reached from the Profiles + menu —
// not from this page). Paste ONE subscription link, node share link
// or a whole YAML config — the page detects what it is, imports just
// that one, and activates it. A second link is pasted separately
// (the user asked for one-at-a-time, not batch). Link subscriptions
// that return base64 node links are decoded and rebuilt into a Clash
// config by ProfileStore, so they import like any other subscription.
// The QR scanner feeds this same form (ProfilesView hands the
// scanned text in with autoImport).

struct UnifiedImportView: View {
    let profileStore: ProfileStore

    @StateObject private var importer: UnifiedImporter
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""
    @State private var profileName = ""
    @State private var clipboardNotice: String?
    /// Text handed in by the QR scanner (ProfilesView): filled into
    /// the field and imported automatically when `autoImport` is set.
    private let initialText: String
    private let autoImport: Bool

    init(profileStore: ProfileStore, initialText: String = "", autoImport: Bool = false) {
        self.profileStore = profileStore
        self.initialText = initialText
        self.autoImport = autoImport
        _importer = StateObject(wrappedValue: UnifiedImporter(profileStore: profileStore))
        _importText = State(initialValue: initialText)
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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    tipText
                }
                .padding(16)
            }
            .concordPageBackground()
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if autoImport, !importText.isEmpty {
                    await performImport()
                    return
                }
                if importText.isEmpty,
                   let clip = UIPasteboard.general.string,
                   let item = UnifiedImporter.singleItemText(clip) {
                    importText = item
                    clipboardNotice = "已从剪贴板填入一条\(UnifiedImporter.singleItemKind(clip).rawValue)，检查后点「导入」"
                }
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
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ConcordTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("导入订阅或节点")
                    .font(.body.weight(.bold))
                Text("一次导入一个：粘贴一条订阅链接或节点链接，点导入就行。")
                    .font(.footnote)
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kindChip
                }
            }
            HStack(spacing: 8) {
                TextField("粘贴订阅链接或节点链接", text: $importText)
                    .font(.footnote.weight(.semibold))
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
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(ConcordTheme.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 14))
            Text("支持订阅链接（http / https）、ss / vmess / trojan / vless 等节点链接，或整段 YAML 配置。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let notice = clipboardNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.accent)
            }
        }
        .concordCard()
    }

    private var kindChip: some View {
        Text(detectedKind.rawValue)
            .font(.caption2.weight(.semibold))
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("例如：我的订阅", text: $profileName)
                .font(.footnote.weight(.semibold))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 14))
            Text("不填就用链接的域名当名字；节点链接会生成「我的节点」。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .concordCard()
    }

    // MARK: - Import button

    private var importButton: some View {
        Button {
            Task { await performImport() }
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

    /// Import the field's content through UnifiedImporter (also
    /// used by the QR scanner, which fills the field first).
    private func performImport() async {
        await importer.importText(importText, name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : profileName.trimmingCharacters(in: .whitespacesAndNewlines))
        // Success: clear the field so the next link can be pasted
        // straight away. Failure: keep the text so the user can
        // fix it.
        if importer.activatedName != nil {
            importText = ""
            profileName = ""
            clipboardNotice = nil
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入结果")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(importer.results) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.kind.rawValue)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(ConcordTheme.accent)
                            Text(result.line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(result.message)
                            .font(.footnote)
                    }
                    Spacer()
                }
                .padding(12)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
            }
        }
    }

    private var tipText: some View {
        Text("导入成功后会自动切换到这个配置，去仪表盘点播放键启动即可；首次安装需先在系统设置里信任开发者证书。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
