import SwiftUI
import UniformTypeIdentifiers

// MARK: - Icon sets (FlClash: IconSetsView, lib/views/config/icon_sets.dart)
// FlClash icon sets are downloadable packs (remote URL or local
// file) that map proxy types to custom images, synced and managed
// in-app. The Concord core has NO icon-set interface (see
// AdvancedConfigView.swift), so this port is CLIENT-SIDE ONLY.
// Built-in pack (v0.2.141: only 默认 remains — the 彩色 and 线条
// packs were deleted, C17-d1) maps each proxy / group type to an
// SF Symbol in the theme accent. Imported packs (v0.2.54) are the upstream format — the
// Quantumult X / Loon gallery JSON {"name": ..., "icons":
// [{"name": ..., "url": ...}]} (FlClash parseIconSet,
// models/common.dart:1008) — downloaded from a URL or picked from
// a file, synced, renamed and deleted in-app, exactly like
// upstream's importUrl / importContent / sync / edit / delete.
// Imported icons render in this page's preview and in Resources;
// the Proxies list still renders SF Symbols (it reads
// symbol(for:) / color(for:), which fall back to the built-in
// symbols for imported packs); remote images are not rendered
// there (the iconView helper was removed as unused in v0.2.144).

// MARK: - Store

final class IconSetStore: ObservableObject {
    static let shared = IconSetStore()
    static let storageKey = "ConcordiOS.iconSet.pack.v1"

    struct Pack: Identifiable {
        let id: String
        let name: String
        let description: String
        /// Per-type SF Symbol; missing types fall back to "circle.fill".
        let symbols: [String: String]
        /// Per-type tint; nil means the theme accent for every type.
        let colors: [String: Color]?
    }

    /// Proxy / group type -> SF Symbol, shared by every pack.
    static let typeSymbols: [String: String] = [
        "shadowsocks": "bolt.fill",
        "vmess": "waveform",
        "vless": "waveform.circle.fill",
        "trojan": "shield.fill",
        "hysteria2": "wind",
        "hysteria": "wind",
        "tuic": "paperplane.fill",
        "socks5": "arrow.left.arrow.right",
        "socks": "arrow.left.arrow.right",
        "http": "globe",
        "snell": "bolt.circle",
        "wireguard": "lock.shield.fill",
        "anytls": "key.fill",
        "openvpn": "lock.fill",
        "select": "list.bullet",
        "url-test": "speedometer",
        "fallback": "arrow.triangle.2.circlepath",
        "load-balance": "square.stack.3d.up.fill",
        "smart": "sparkles",
        "relay": "link",
        "direct": "arrow.up.right",
        "reject": "nosign",
        "dns": "server.rack",
    ]

    /// The proxy types shown in the preview grid.
    static let previewTypes = ["shadowsocks", "vmess", "vless", "trojan", "hysteria2", "tuic", "socks5", "http", "snell", "wireguard", "openvpn", "select", "url-test", "fallback", "load-balance", "smart", "relay", "direct", "reject", "dns"]

    /// v0.2.141 (C17-d1): the built-ins are down to the single
    /// 默认 pack — the 彩色 pack (per-type colours, typeColors)
    /// and the 线条 pack (outline symbols) are gone. Without its
    /// colours the 彩色 pack duplicated 默认；the 线条 pack was
    /// ours-only (upstream has no icon-set variants). Stale
    /// persisted ids ("color" / "outline") fall back to default
    /// via the init / reload guards below.
    static let packs: [Pack] = [
        Pack(id: "default", name: "默认", description: "系统图标，按主题色显示", symbols: typeSymbols, colors: nil),
    ]

    @Published var selectedPackID: String {
        didSet { save() }
    }

    var selectedPack: Pack {
        Self.packs.first { $0.id == selectedPackID } ?? Self.packs[0]
    }

    /// Whether the selected pack is an imported one.
    var selectedImportedPack: ImportedPack? {
        importedPacks.first { $0.id == selectedPackID }
    }

    private init() {
        selectedPackID = UserDefaults.standard.string(forKey: Self.storageKey) ?? "default"
        loadImported()
        if Self.packs.first(where: { $0.id == selectedPackID }) == nil
            && importedPacks.first(where: { $0.id == selectedPackID }) == nil {
            selectedPackID = "default"
        }
    }

    /// Re-read the persisted pack (used after a backup restore:
    /// the restore writes the key behind this store's back).
    /// Assigning through the property would re-save the same value,
    /// so this reads the key directly and only publishes a change.
    func reload() {
        loadImported()
        let saved = UserDefaults.standard.string(forKey: Self.storageKey) ?? "default"
        let packID = Self.packs.contains(where: { $0.id == saved })
            || importedPacks.contains(where: { $0.id == saved }) ? saved : "default"
        if packID != selectedPackID {
            selectedPackID = packID
        }
    }

    private func save() {
        UserDefaults.standard.set(selectedPackID, forKey: Self.storageKey)
    }

    // MARK: - Imported packs (FlClash icon_sets.dart)

    /// One imported icon (FlClash IconSetIcon): a name + an http(s)
    /// image URL.
    struct ImportedIcon: Codable, Equatable, Identifiable {
        var id: String { url }
        let name: String
        let url: String
    }

    /// One imported icon set (FlClash IconSet): a name, an optional
    /// source URL ("" = imported from a file), its icons, and the
    /// last sync time. Stored as JSON in UserDefaults.
    struct ImportedPack: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var url: String
        var icons: [ImportedIcon]
        var lastUpdate: Date

        var isRemote: Bool { !url.isEmpty }
    }

    static let importedStorageKey = "ConcordiOS.iconSet.imported.v1"

    @Published var importedPacks: [ImportedPack] = []
    /// Last import / sync / edit message for the page (and
    /// Resources, which shows per-set update buttons).
    @Published var actionMessage: String?
    @Published var lastError: String?
    /// The ids of packs currently syncing (per-item spinner).
    @Published var syncingIDs: Set<String> = []

    private func loadImported() {
        guard let data = UserDefaults.standard.data(forKey: Self.importedStorageKey),
              let packs = try? JSONDecoder().decode([ImportedPack].self, from: data) else {
            importedPacks = []
            return
        }
        importedPacks = packs
    }

    private func saveImported() {
        guard let data = try? JSONEncoder().encode(importedPacks) else { return }
        UserDefaults.standard.set(data, forKey: Self.importedStorageKey)
    }

    /// Parses the upstream icon-set format (FlClash parseIconSet,
    /// models/common.dart:1008): `{"name": ..., "icons": [{"name":
    /// ..., "url": ...}]}`. Only http(s) URLs are kept, duplicates
    /// by URL are dropped, an unnamed icon takes the URL file stem.
    /// Throws when the document is not an icon set or has no icons.
    static func parseIconSet(_ content: String) throws -> (name: String, icons: [ImportedIcon]) {
        guard let data = content.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIcons = document["icons"] as? [[String: Any]] else {
            throw IconSetImportError.invalidFormat
        }
        var seen: Set<String> = []
        var icons: [ImportedIcon] = []
        for item in rawIcons {
            guard let url = item["url"] as? String,
                  let parsed = URL(string: url),
                  parsed.scheme?.hasPrefix("http") == true,
                  parsed.host != nil,
                  seen.insert(url).inserted else { continue }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            icons.append(ImportedIcon(
                name: (name?.isEmpty == false) ? name! : parsed.deletingPathExtension().lastPathComponent,
                url: url))
        }
        guard !icons.isEmpty else { throw IconSetImportError.noIcons }
        let name = (document["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return (name: name, icons: icons)
    }

    enum IconSetImportError: LocalizedError {
        case invalidFormat
        case noIcons
        case badURL

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "不是有效的图标集（应为 {\"name\": ..., \"icons\": [{\"name\": ..., \"url\": ...}]}）"
            case .noIcons: return "图标集里没有可用的图标（需要至少一个 http(s) 链接）"
            case .badURL: return "链接无效，应为 http(s) 链接"
            }
        }
    }

    /// Downloads an icon-set document (2xx only; an HTML error page
    /// parses as nothing, so it surfaces as a format error).
    private func downloadIconSet(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw IconSetImportError.invalidFormat
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Imports from a URL (FlClash _handleImportFromUrl /
    /// importUrl). An already-imported URL is synced instead of
    /// duplicated; the name is the given name, else the parsed
    /// name, else the URL file stem.
    @MainActor
    func importFromURL(_ urlString: String, name: String = "") async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true, url.host != nil else {
            lastError = IconSetImportError.badURL.localizedDescription
            actionMessage = nil
            return
        }
        if let existing = importedPacks.first(where: { $0.url == url.absoluteString }) {
            await syncPack(existing)
            return
        }
        do {
            let content = try await downloadIconSet(from: url)
            let parsed = try Self.parseIconSet(content)
            let stem = url.deletingPathExtension().lastPathComponent
            let packName = [name.trimmingCharacters(in: .whitespaces), parsed.name, stem]
                .first { !$0.isEmpty } ?? "图标集"
            let pack = ImportedPack(id: UUID().uuidString, name: packName,
                                    url: url.absoluteString, icons: parsed.icons,
                                    lastUpdate: Date())
            importedPacks.append(pack)
            saveImported()
            lastError = nil
            actionMessage = "已导入图标集 \(packName)（\(parsed.icons.count) 个图标）"
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            actionMessage = nil
        }
    }

    /// Imports from file content (FlClash _handleImportFromFile /
    /// importContent). The pack has no source URL, so it cannot be
    /// synced — only renamed or deleted.
    @MainActor
    func importFromFile(fileName: String, content: String) {
        do {
            let parsed = try Self.parseIconSet(content)
            let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            let packName = [parsed.name, stem].first { !$0.isEmpty } ?? "图标集"
            let pack = ImportedPack(id: UUID().uuidString, name: packName,
                                    url: "", icons: parsed.icons,
                                    lastUpdate: Date())
            importedPacks.append(pack)
            saveImported()
            lastError = nil
            actionMessage = "已导入图标集 \(packName)（\(parsed.icons.count) 个图标）"
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            actionMessage = nil
        }
    }

    /// Re-downloads a remote pack (FlClash sync). A user-edited
    /// name is kept; otherwise the parsed name is taken. A pack
    /// deleted or re-pointed while syncing is left alone.
    @MainActor
    func syncPack(_ pack: ImportedPack) async {
        guard pack.isRemote, let url = URL(string: pack.url) else { return }
        syncingIDs.insert(pack.id)
        defer { syncingIDs.remove(pack.id) }
        do {
            let content = try await downloadIconSet(from: url)
            let parsed = try Self.parseIconSet(content)
            guard let index = importedPacks.firstIndex(where: { $0.id == pack.id }) else { return }
            guard importedPacks[index].url == pack.url else { return }
            if importedPacks[index].name == pack.name {
                importedPacks[index].name = parsed.name.isEmpty ? pack.name : parsed.name
            }
            importedPacks[index].icons = parsed.icons
            importedPacks[index].lastUpdate = Date()
            saveImported()
            lastError = nil
            actionMessage = "已同步图标集 \(importedPacks[index].name)（\(parsed.icons.count) 个图标）"
        } catch {
            lastError = "同步失败：\(error.localizedDescription)"
            actionMessage = nil
        }
    }

    /// Renames a pack (FlClash _handleEditOptions for a local pack).
    func renamePack(_ pack: ImportedPack, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = importedPacks.firstIndex(where: { $0.id == pack.id }) else { return }
        importedPacks[index].name = trimmed
        saveImported()
        actionMessage = "已重命名为 \(trimmed)"
        lastError = nil
    }

    /// Changes a remote pack's name and URL (FlClash
    /// _handleEditOptions for a remote pack): an unchanged URL only
    /// renames; a changed URL re-syncs from the new address.
    @MainActor
    func updatePack(_ pack: ImportedPack, name: String, url: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty,
              let index = importedPacks.firstIndex(where: { $0.id == pack.id }) else { return }
        guard trimmedURL != pack.url else {
            renamePack(pack, name: trimmedName)
            return
        }
        guard let parsedURL = URL(string: trimmedURL),
              parsedURL.scheme?.hasPrefix("http") == true, parsedURL.host != nil else {
            lastError = IconSetImportError.badURL.localizedDescription
            actionMessage = nil
            return
        }
        importedPacks[index].name = trimmedName
        importedPacks[index].url = trimmedURL
        saveImported()
        await syncPack(importedPacks[index])
    }

    /// Deletes a pack (FlClash _handleDelete). A selected pack falls
    /// back to the built-in default pack.
    func deletePack(_ pack: ImportedPack) {
        importedPacks.removeAll { $0.id == pack.id }
        if selectedPackID == pack.id {
            selectedPackID = "default"
        }
        saveImported()
        actionMessage = "已删除图标集 \(pack.name)"
        lastError = nil
    }

    /// The SF Symbol for a proxy / group type in the selected pack.
    func symbol(for type: String) -> String {
        selectedPack.symbols[type.lowercased()] ?? "circle.fill"
    }

    /// The tint for a proxy / group type in the selected pack.
    func color(for type: String) -> Color {
        selectedPack.colors?[type.lowercased()] ?? ConcordTheme.accent
    }

    /// The icon view used by the proxies list.
    func icon(for type: String, size: CGFloat = 10) -> some View {
        Image(systemName: symbol(for: type))
            .font(.system(size: size))
            .foregroundStyle(color(for: type))
    }
}

// MARK: - View

struct IconSetsView: View {
    @ObservedObject private var iconSetStore = IconSetStore.shared
    @State private var importName = ""
    @State private var importURL = ""
    @State private var showImporter = false
    /// Local-pack rename dialog (upstream showCommonDialog
    /// InputDialog, icon_sets.dart:67) — the item itself is the
    /// source; the name field binds to it.
    @State private var renamingPack: IconSetStore.ImportedPack?
    /// Remote-pack edit form sheet (upstream showNamedUrlForm →
    /// showFormSheet): the form's fields live in the sheet and
    /// are initialised from the item.
    @State private var editingRemotePack: IconSetStore.ImportedPack?
    @State private var deletingPack: IconSetStore.ImportedPack?

    var body: some View {
        List {
            Section {
                ForEach(IconSetStore.packs) { pack in
                    Button {
                        iconSetStore.selectedPackID = pack.id
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                ForEach(["shadowsocks", "vmess", "trojan", "direct"], id: \.self) { type in
                                    Image(systemName: pack.symbols[type] ?? "circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(pack.colors?[type] ?? ConcordTheme.accent)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(.label))
                                Text(pack.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if iconSetStore.selectedPackID == pack.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("图标集只影响本 App 内代理列表里节点类型旁的小图标。核心没有图标集接口，所以这里是纯客户端设置。")
                    .font(.footnote)
            }

            // FlClash icon_sets.dart _handleImportFromUrl /
            // _handleImportFromFile: import a pack from a link or a
            // file. The format is the upstream one (Quantumult X /
            // Loon gallery JSON); an already-imported link syncs
            // instead of duplicating.
            Section("导入图标集") {
                TextField("名称（可选，留空用文件里的名字）", text: $importName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("图标集链接（JSON）", text: $importURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("导入") {
                        Task { await iconSetStore.importFromURL(importURL, name: importName) }
                    }
                    .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("从文件导入…") {
                        showImporter = true
                    }
                }
                if let error = iconSetStore.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if let message = iconSetStore.actionMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("上游格式：Quantumult X / Loon 图标库 JSON（{\"name\": ..., \"icons\": [{\"name\": ..., \"url\": ...}]}），按名称匹配代理类型。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !iconSetStore.importedPacks.isEmpty {
                Section("已导入") {
                    ForEach(iconSetStore.importedPacks) { pack in
                        HStack(spacing: 12) {
                            Button {
                                iconSetStore.selectedPackID = pack.id
                            } label: {
                                HStack(spacing: 12) {
                                    packCover(pack)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.name)
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Color(.label))
                                        Text("\(pack.icons.count) 个图标 · \(pack.isRemote ? "远程" : "本地文件") · 更新于 \(pack.lastUpdate.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if iconSetStore.syncingIDs.contains(pack.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else if iconSetStore.selectedPackID == pack.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                            Menu {
                                if pack.isRemote {
                                    Button("同步") {
                                        Task { await iconSetStore.syncPack(pack) }
                                    }
                                }
                                Button("选项…") {
                                    deletingPack = nil
                                    if pack.isRemote {
                                        editingRemotePack = pack
                                    } else {
                                        renamingPack = pack
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    renamingPack = nil
                                    editingRemotePack = nil
                                    deletingPack = pack
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("预览：\(previewTitle)") {
                if let imported = iconSetStore.selectedImportedPack {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                        ForEach(Array(imported.icons.prefix(18))) { icon in
                            VStack(spacing: 4) {
                                AsyncImage(url: URL(string: icon.url)) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                Text(icon.name)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if imported.icons.count > 18 {
                        Text("共 \(imported.icons.count) 个图标，这里只预览前 18 个。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                        ForEach(IconSetStore.previewTypes, id: \.self) { type in
                            VStack(spacing: 4) {
                                iconSetStore.icon(for: type, size: 18)
                                    .frame(width: 28, height: 28)
                                Text(type)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("导入的图标按名称匹配代理类型；代理列表暂仍用内置图标显示，待列表渲染接入远程图标。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .scrollContentBackground(.hidden)
        .font(.footnote.weight(.semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("图标集")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    iconSetStore.lastError = "读取文件失败或文件为空"
                    return
                }
                iconSetStore.importFromFile(
                    fileName: url.lastPathComponent,
                    content: String(decoding: data, as: UTF8.self))
            case .failure(let error):
                iconSetStore.lastError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        // Remote-pack edit is a form sheet (upstream
        // showNamedUrlForm → showFormSheet); a local pack has no
        // URL to edit, so it uses the rename dialog below.
        .sheet(item: $editingRemotePack) { pack in
            IconSetEditSheet(pack: pack) { name, url in
                Task { await iconSetStore.updatePack(pack, name: name, url: url) }
            }
            .formSheetChrome()
        }
        // Local-pack rename is a centred input dialog (upstream
        // showCommonDialog InputDialog), not a sheet.
        .alert("重命名图标集", isPresented: Binding(
            get: { renamingPack != nil },
            set: { if !$0 { renamingPack = nil } }
        )) {
            TextField("名称", text: Binding(
                get: { renamingPack?.name ?? "" },
                set: { renamingPack?.name = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button("保存") {
                if let pack = renamingPack {
                    iconSetStore.renamePack(pack, name: pack.name)
                }
                renamingPack = nil
            }
            .disabled((renamingPack?.name.trimmingCharacters(in: .whitespaces).isEmpty) ?? true)
            Button("取消", role: .cancel) { renamingPack = nil }
        }
        .alert(
            "删除这个图标集吗？",
            isPresented: Binding(
                get: { deletingPack != nil },
                set: { if !$0 { deletingPack = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let pack = deletingPack {
                    iconSetStore.deletePack(pack)
                }
                deletingPack = nil
            }
            Button("取消", role: .cancel) { deletingPack = nil }
        } message: {
            if let pack = deletingPack {
                Text("将删除图标集「\(pack.name)」。")
            }
        }
    }

    private var previewTitle: String {
        iconSetStore.selectedImportedPack?.name ?? iconSetStore.selectedPack.name
    }

    /// The pack's cover: its first icon, or a placeholder.
    private func packCover(_ pack: IconSetStore.ImportedPack) -> some View {
        Group {
            if let first = pack.icons.first, let url = URL(string: first.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
        }
    }
}

/// Rename a remote pack (and change its URL — a changed URL
/// re-syncs, FlClash _handleEditOptions). The fields live in the
/// sheet, initialised from the item — no separate parent state.
private struct IconSetEditSheet: View {
    let pack: IconSetStore.ImportedPack
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var showDiscardConfirm = false

    init(pack: IconSetStore.ImportedPack, onSave: @escaping (String, String) -> Void) {
        self.pack = pack
        self.onSave = onSave
        _name = State(initialValue: pack.name)
        _url = State(initialValue: pack.url)
    }

    private var error: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名称不能为空" }
        if pack.isRemote {
            let value = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: value),
                  parsed.scheme?.hasPrefix("http") == true, parsed.host != nil else {
                return "链接无效，应为 http(s) 链接"
            }
        }
        return nil
    }

    /// Dirty once name or URL differs from the pack as opened.
    private var isDirty: Bool {
        name != pack.name || url != pack.url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if pack.isRemote {
                        TextField("链接", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("改了链接后保存时会从新地址重新同步。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("本地文件导入的图标集没有来源链接，不能同步。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .navigationTitle("图标集选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, url)
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }
}
