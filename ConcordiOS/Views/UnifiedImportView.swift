import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Unified import (one place to import everything)
// Paste subscription links, node share links or a whole YAML config
// — the sheet detects what each line is, imports subscriptions one
// by one, parses node links locally (ss / vmess / trojan / vless)
// and builds a ready-to-use "我的节点" config from them, and saves
// YAML text as a local profile. After the batch finishes, the first
// successful import is activated; the dashboard play button starts
// the VPN. The legacy add sheet is still reachable from here.

struct UnifiedImportView: View {
    let profileStore: ProfileStore

    @StateObject private var importer: UnifiedImporter
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""
    @State private var showFileImporter = false
    @State private var showLegacyAdd = false
    @State private var clipboardNotice: String?

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        _importer = StateObject(wrappedValue: UnifiedImporter(profileStore: profileStore))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("粘贴订阅链接、节点链接或整段配置，自动识别，一次导入。订阅链接每行一个，多个会逐个导入；节点链接会直接解析并生成可用的「我的节点」配置。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $importText)
                        .frame(minHeight: 160)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    if let notice = clipboardNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                importText = clip
                                clipboardNotice = "已填入剪贴板内容"
                            } else {
                                clipboardNotice = "剪贴板里没有文字"
                            }
                        } label: {
                            Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从文件导入", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            importText = ""
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(importText.isEmpty)
                    }
                    Button {
                        Task { await importer.importText(importText) }
                    } label: {
                        Group {
                            if importer.isImporting {
                                ProgressView().tint(.white)
                            } else {
                                Text("开始导入").fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConcordTheme.accent)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importer.isImporting)
                    if !importer.results.isEmpty {
                        resultsSection
                    }
                    if let summary = importer.summaryText {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Button("使用旧版添加方式") { showLegacyAdd = true }
                        .font(.subheadline)
                    Text("导入成功后会自动切换到第一个成功的配置，去仪表盘点播放键启动即可；首次安装需先在系统设置里信任开发者证书。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .concordPageBackground()
            .navigationTitle("统一导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if importText.isEmpty,
                   let clip = UIPasteboard.general.string,
                   !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   UnifiedImporter.looksImportable(clip) {
                    importText = clip
                    clipboardNotice = "已从剪贴板填入内容，检查后点「开始导入」"
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

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入结果")
                .font(.headline)
            ForEach(importer.results) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.kind.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(ConcordTheme.accent)
                            Text(result.line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(result.message)
                            .font(.subheadline)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: ConcordTheme.cardShadow, radius: 6, x: 0, y: 2)
            }
        }
    }
}
