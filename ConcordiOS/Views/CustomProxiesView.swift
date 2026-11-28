import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared form-sheet chrome + dirty-discard guard
//
// Upstream FlClash form sheets go through showFormSheet /
// showSnapSheet (plugins/prism_ui/lib/sheet.dart): detents
// [9/16, 0.9], tap-scrim dismiss, corner radius 38 (28pt here,
// the stats-sheet value at DashboardView.swift:540). Every form
// sheet in the Config/Settings area uses formSheetChrome().
// Upstream NestedFormSheet also intercepts dismiss and asks
// save-changes when the form is dirty. SwiftUI cannot intercept
// the swipe-down gesture itself, so while a form is dirty the
// swipe is blocked (interactiveDismissDisabled) and the Cancel
// button asks whether to discard — DiscardChangesGuard, applied
// to the form's root with the form's own isDirty flag.

/// Upstream form-sheet chrome: opens at the short detent, drags
/// to 90%, page background, 28pt corners (stats-sheet pattern).
extension View {
    func formSheetChrome() -> some View {
        presentationDetents([.fraction(0.5625), .fraction(0.9)])
            .presentationBackground(ConcordTheme.pageBackground)
            .presentationCornerRadius(28)
    }
}

/// Dirty-discard guard for edit-form sheets. `isDirty` is the
/// form's own flag; `showConfirm` drives the alert; `onDiscard`
/// dismisses the sheet. Cancel buttons call
/// `if isDirty { showConfirm = true } else { dismiss() }`.
struct DiscardChangesGuard: ViewModifier {
    var isDirty: Bool
    @Binding var showConfirm: Bool
    var onDiscard: () -> Void

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty)
            .alert("放弃未保存的修改？", isPresented: $showConfirm) {
                Button("放弃修改", role: .destructive, action: onDiscard)
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("已做的修改尚未保存。")
            }
    }
}

extension View {
    func discardChangesGuard(isDirty: Bool, showConfirm: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        modifier(DiscardChangesGuard(isDirty: isDirty, showConfirm: showConfirm, onDiscard: onDiscard))
    }
}

// MARK: - Custom proxies (FlClash: Tools -> 进阶配置 -> 代理)
// User-defined proxies, merged into the active profile's YAML
// under `proxies:` (see CustomProxyStore — the config.apply
// overlay cannot carry proxies, the profile owns them). Each
// proxy is validated against the core (validate.proxies) before
// it is saved. Subscription updates re-apply them (ProfileStore).

struct CustomProxiesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var store = CustomProxyStore()
    @StateObject private var customStore = CustomSubscriptionStore()
    @State private var editing: CustomProxy?
    @State private var editingRawItem: RawProxyEditItem?
    @State private var message: String?
    @State private var createdSubscriptionID: UUID?
    @State private var showCreatedEditor = false
    /// OpenVPN import (v0.2.155): link-import sheet, .ovpn
    /// file importer, and the parse warnings shown in the form
    /// the import opens (cleared whenever the form opens for
    /// anything else).
    @State private var showOpenVPNImportSheet = false
    @State private var showOvpnFileImporter = false
    @State private var importWarnings: [String] = []

    var body: some View {
        List {
            Section {
                Text("自定义节点会写进当前配置的 proxies: 段，之后可以在代理组里选用。订阅更新后会自动重新写回。保存前先用核心校验节点是否可用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    let created = customStore.create(name: "未命名自定义订阅")
                    createdSubscriptionID = created.id
                    showCreatedEditor = true
                } label: {
                    Label("完整自定义订阅编辑器（分组 / 拨号器 / 提供方 / 规则）", systemImage: "doc.badge.gearshape")
                        .font(.footnote)
                }
            }
            Section(header: Text("自定义代理（\(store.proxies.count) 个）").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                ForEach(store.proxies) { proxy in
                    Button {
                        importWarnings = []
                        editing = proxy
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proxy.name)
                                // Upstream _NodeItem (custom_proxies.dart):
                                // subtitle is the proxy type only.
                                Text(proxy.type)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.proxies.remove(atOffsets: offsets)
                    store.save()
                    Task { await bakeIntoProfile() }
                }
                Button {
                    importWarnings = []
                    editing = CustomProxy()
                } label: {
                    Label("添加代理", systemImage: "plus")
                }
                // OpenVPN import (v0.2.155): parses a .ovpn file
                // or an openvpn:// link into a prefilled form —
                // never a silent save (see OpenVPNImport).
                Button {
                    showOpenVPNImportSheet = true
                } label: {
                    Label("导入 OpenVPN 链接", systemImage: "link")
                }
                Button {
                    showOvpnFileImporter = true
                } label: {
                    Label("导入 .ovpn 文件", systemImage: "doc.badge.plus")
                }
            }
            // "添加到本地"的节点 (rawProxies): the full definition
            // as the core wrote it — ws-opts / grpc-opts /
            // reality-opts / flow / alpn included. They used to be
            // invisible here and undeletable anywhere; now they are
            // listed with edit + delete. Edit only touches
            // name / server / port (the form cannot express the
            // rest, so the remaining keys are kept verbatim).
            Section(header: Text("本地添加的节点（\(store.rawProxies.count) 个）").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                if store.rawProxies.isEmpty {
                    Text("还没有通过「添加到本地」加入的节点。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.rawProxies.enumerated()), id: \.offset) { index, definition in
                    Button {
                        editingRawItem = RawProxyEditItem(index: index)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(definition.objectValue?["name"]?.stringValue ?? "—")
                                // Ours-only row (no upstream counterpart):
                                // keep type · server:port — the type
                                // alone does not identify a raw node.
                                Text("\(definition.objectValue?["type"]?.stringValue ?? "—") · \(definition.objectValue?["server"]?.stringValue ?? "—"):\(rawPortText(definition))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    deleteRawProxies(at: offsets)
                }
            }
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .contentMargins(.top, 40)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "代理")
        .sheet(item: $editing) { proxy in
            CustomProxyFormView(proxy: proxy, isNew: !store.proxies.contains(where: { $0.id == proxy.id }), importWarnings: importWarnings) { saved in
                // The form only dismisses when this returns true:
                // a failed core validation keeps the sheet open so
                // the user can fix the node instead of re-typing
                // it (v0.2.151 B2 — pasted PEM blocks are long).
                await saveProxy(saved)
            }
            .formSheetChrome()
        }
        // OpenVPN link import (v0.2.155): on success the parsed
        // node opens in the form prefilled, with its warnings.
        .sheet(isPresented: $showOpenVPNImportSheet) {
            OpenVPNImportSheetView { result in
                openImported(result)
            }
            .formSheetChrome()
        }
        // .ovpn file import (v0.2.155): same prefilled-form flow
        // as the link import (SettingsView provider import uses
        // the same .plainText/.data fileImporter pattern).
        .fileImporter(isPresented: $showOvpnFileImporter, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    importWarnings = []
                    message = "导入失败：无法读取文件内容"
                    return
                }
                do {
                    let parsed = try OpenVPNImport.parseOvpn(text, suggestedName: url.deletingPathExtension().lastPathComponent)
                    openImported(parsed)
                } catch {
                    importWarnings = []
                    message = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                importWarnings = []
                message = "选择文件失败：\(error.localizedDescription)"
            }
        }
        // Raw ("添加到本地") edit: ours-only, stays a sheet, but
        // single-item (the old Bool + index + if-let could show a
        // stale/blank form for a deleted row).
        .sheet(item: $editingRawItem) { item in
            if store.rawProxies.indices.contains(item.index) {
                RawProxyEditView(definition: store.rawProxies[item.index]) { saved in
                    store.rawProxies[item.index] = saved
                    store.save()
                    Task { await bakeIntoProfile() }
                } onDelete: {
                    deleteRawProxies(at: IndexSet(integer: item.index))
                }
                .formSheetChrome()
            }
        }
        .navigationDestination(isPresented: $showCreatedEditor) {
            if let createdSubscriptionID {
                CustomSubscriptionEditorView(subscriptionID: createdSubscriptionID).concordNavBarBackground()
            }
        }
    }

    private func rawPortText(_ definition: JSONValue) -> String {
        guard let port = definition.objectValue?["port"] else { return "—" }
        if case .int(let value) = port { return String(value) }
        if case .double(let value) = port { return String(Int(value)) }
        return "—"
    }

    /// Deletes raw ("添加到本地") nodes for real: removed from
    /// the store, persisted, and re-baked out of the profile.
    private func deleteRawProxies(at offsets: IndexSet) {
        store.rawProxies.remove(atOffsets: offsets)
        store.save()
        editingRawItem = nil
        Task { await bakeIntoProfile() }
    }

    /// Opens a parsed OpenVPN import in the form, prefilled,
    /// with its parse warnings (v0.2.155). The name is deduped
    /// against both the form proxies and the raw ("添加到本地")
    /// nodes — a duplicate proxy name would fail the core parse
    /// at bake time.
    private func openImported(_ result: OpenVPNImport.Result) {
        var proxy = result.proxy
        proxy.name = uniqueProxyName(proxy.name)
        importWarnings = result.warnings
        editing = proxy
    }

    /// A proxy name not already in the list (same style as
    /// SettingsView.uniqueProviderName): the base name, or
    /// base-2, base-3, …
    private func uniqueProxyName(_ base: String) -> String {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = clean.isEmpty ? "OpenVPN" : clean
        let existing = Set(store.proxies.map { $0.name }
            + store.rawProxies.compactMap { $0.objectValue?["name"]?.stringValue })
        guard existing.contains(stem) else { return stem }
        var index = 2
        while existing.contains("\(stem)-\(index)") { index += 1 }
        return "\(stem)-\(index)"
    }

    /// Validates against the core, then saves + re-bakes. Returns
    /// nil on success, or the failure message: the form stays
    /// open and shows it so the user can fix the node.
    private func saveProxy(_ proxy: CustomProxy) async -> String? {
        // Validate against the core before saving.
        do {
            let issues = try await profileStore.client.validateProxies(proxies: [proxyJSONValue(proxy)])
            if !issues.isEmpty {
                message = "节点校验未通过：\(issues[0].message)"
                return message
            }
        } catch {
            message = "校验失败（核心未连接）：\(error.localizedDescription)"
            return message
        }
        if let index = store.proxies.firstIndex(where: { $0.id == proxy.id }) {
            store.proxies[index] = proxy
        } else {
            store.proxies.append(proxy)
        }
        store.save()
        await bakeIntoProfile()
        return nil
    }

    /// Write the current custom proxies into the active profile's
    /// YAML and re-apply live when the tunnel runs.
    private func bakeIntoProfile() async {
        guard var text = profileStore.activeProfileYAML() else {
            message = "没有可写入的当前配置（先导入一个订阅）"
            return
        }
        text = CustomProxyStore.bakeCurrent(into: text)
        message = await profileStore.saveActiveProfileYAML(text)
        if let live = await profileStore.reapplyActive() {
            message = (message ?? "") + " " + live
        }
    }

    /// The proxy as a JSON value, for validate.proxies. Per-type
    /// keys only: an unknown key reaches the core parser as a
    /// note, so a leaked `uuid` / `tls` / `sni` on an openvpn
    /// node would muddy its validation.
    private func proxyJSONValue(_ proxy: CustomProxy) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(proxy.name), "type": .string(proxy.type),
            "server": .string(proxy.server), "port": .int(Int64(proxy.port)),
        ]
        switch proxy.type {
        case "openvpn":
            if proxy.ovpnProto.lowercased() == "tcp" { dict["proto"] = .string("tcp") }
            if !proxy.ovpnCa.isEmpty { dict["ca"] = .string(proxy.ovpnCa) }
            if !proxy.ovpnCert.isEmpty { dict["cert"] = .string(proxy.ovpnCert) }
            if !proxy.ovpnKey.isEmpty { dict["key"] = .string(proxy.ovpnKey) }
            if !proxy.ovpnTlsAuth.isEmpty { dict["tls-auth"] = .string(proxy.ovpnTlsAuth) }
            if !proxy.ovpnTlsCrypt.isEmpty { dict["tls-crypt"] = .string(proxy.ovpnTlsCrypt) }
            if !proxy.ovpnTlsCryptV2.isEmpty { dict["tls-crypt-v2"] = .string(proxy.ovpnTlsCryptV2) }
            if proxy.ovpnKeyDirection == "0" || proxy.ovpnKeyDirection == "1" {
                dict["key-direction"] = .string(proxy.ovpnKeyDirection)
            }
            if !proxy.ovpnUsername.isEmpty { dict["username"] = .string(proxy.ovpnUsername) }
            if !proxy.password.isEmpty { dict["password"] = .string(proxy.password) }
            if !proxy.cipher.isEmpty { dict["cipher"] = .string(proxy.cipher) }
            let dataCiphers = CustomProxy.splitList(proxy.ovpnDataCiphers)
            if !dataCiphers.isEmpty { dict["data-ciphers"] = .array(dataCiphers.map(JSONValue.string)) }
            if !proxy.ovpnDataCiphersFallback.isEmpty { dict["data-ciphers-fallback"] = .string(proxy.ovpnDataCiphersFallback) }
            if !proxy.ovpnAuth.isEmpty { dict["auth"] = .string(proxy.ovpnAuth) }
            if proxy.ovpnCompLzo { dict["comp-lzo"] = .string("yes") }
            if proxy.ovpnPing > 0 { dict["ping"] = .int(Int64(proxy.ovpnPing)) }
            if proxy.ovpnPingRestart > 0 { dict["ping-restart"] = .int(Int64(proxy.ovpnPingRestart)) }
            if proxy.ovpnTranWindow > 0 { dict["tran-window"] = .int(Int64(proxy.ovpnTranWindow)) }
            if proxy.ovpnHandshakeTimeout > 0 { dict["handshake-timeout"] = .int(Int64(proxy.ovpnHandshakeTimeout)) }
            if proxy.ovpnMtu > 0 { dict["mtu"] = .int(Int64(proxy.ovpnMtu)) }
            if proxy.ovpnRemoteDnsResolve { dict["remote-dns-resolve"] = .bool(true) }
            let dns = CustomProxy.splitCommaList(proxy.ovpnDns)
            if !dns.isEmpty { dict["dns"] = .array(dns.map(JSONValue.string)) }
            dict["udp"] = .bool(true)
        default:
            if !proxy.password.isEmpty { dict["password"] = .string(proxy.password) }
            if !proxy.uuid.isEmpty { dict["uuid"] = .string(proxy.uuid) }
            if !proxy.cipher.isEmpty { dict["cipher"] = .string(proxy.cipher) }
            if proxy.tls { dict["tls"] = .bool(true) }
            if !proxy.sni.isEmpty { dict["servername"] = .string(proxy.sni) }
            if !proxy.network.isEmpty { dict["network"] = .string(proxy.network) }
            if proxy.udp { dict["udp"] = .bool(true) }
        }
        return .object(dict)
    }
}

// MARK: - OpenVPN import (.ovpn file + openvpn:// link, v0.2.155)

/// Parses .ovpn profiles into a CustomProxy (type openvpn).
///
/// The accepted `openvpn://` forms (researched 2026-11-28; there
/// is NO standard for embedding a config or credentials in the
/// URL itself):
/// 1. `openvpn://import-profile/<https-url>` — the official
///    OpenVPN Connect form (Access Server 2.11+ token URL): the
///    inner https URL serves a .ovpn file, which is downloaded
///    and parsed.
/// 2. A plain `https://…` / `http://…` URL — OpenVPN Connect
///    "Import from URL": the URL serves a .ovpn file.
/// 3. `openvpn://<base64>` — BEST-EFFORT only: base64 / base64url
///    of .ovpn text. No official standard documents this form;
///    it is accepted as a fallback and the error message says so.
/// 4. Raw .ovpn text pasted into the link field (multi-line,
///    has a `remote` line) — parsed directly.
///
/// Flow: parse → the caller opens CustomProxyFormView prefilled
/// (type openvpn) with the warnings, so the user reviews, fills
/// username/password if needed, and saves. Save runs the existing
/// `validate.proxies` path — a failed validation keeps the form
/// open with the core's error. Only an unbuildable profile is a
/// hard error (empty content, no `remote`, download failure,
/// invalid link); everything else is a warning shown in the form
/// (missing CA, file-referenced CA/cert/key, auth-user-pass
/// without credentials, ignored directives) — never silently
/// dropped.
enum OpenVPNImport {
    struct Result {
        var proxy: CustomProxy
        var warnings: [String]
    }

    enum ImportError: Error, LocalizedError {
        case emptyFile
        case noRemote
        case invalidLink
        case downloadFailed(String)
        case notOvpnText

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "文件为空"
            case .noRemote:
                return "没有找到 remote（服务器地址），不是有效的 .ovpn 文件"
            case .invalidLink:
                return "链接无效：支持 openvpn://import-profile/<https 链接>、https://… .ovpn 直链、openvpn://<base64 配置>，或直接粘贴 .ovpn 文本"
            case .downloadFailed(let detail):
                return "下载失败：\(detail)"
            case .notOvpnText:
                return "下载的内容不是有效的 .ovpn 文件"
            }
        }
    }

    /// Import from a link (the four accepted forms above).
    static func importLink(_ rawLink: String) async throws -> Result {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { throw ImportError.invalidLink }
        // Raw .ovpn text pasted into the field. No newline
        // requirement (v0.2.155 audit N8): a one-line paste such
        // as `remote vpn.example.com 1194` is still a profile —
        // looksLikeOvpn is the discriminator, a URL never has a
        // line starting with `remote`.
        if looksLikeOvpn(link) {
            return try parseOvpn(link)
        }
        if link.hasPrefix("openvpn://") {
            let rest = String(link.dropFirst("openvpn://".count))
            if rest.hasPrefix("import-profile/") {
                var inner = String(rest.dropFirst("import-profile/".count))
                if let decoded = inner.removingPercentEncoding { inner = decoded }
                guard let url = URL(string: inner),
                      url.scheme == "https" || url.scheme == "http" else {
                    throw ImportError.invalidLink
                }
                let text = try await downloadOvpn(from: url)
                return try parseOvpn(text, suggestedName: url.deletingPathExtension().lastPathComponent)
            }
            // `openvpn://https://…` (no import-profile prefix):
            // treat as a plain profile URL.
            if rest.hasPrefix("https://") || rest.hasPrefix("http://"),
               let url = URL(string: rest) {
                let text = try await downloadOvpn(from: url)
                return try parseOvpn(text, suggestedName: url.deletingPathExtension().lastPathComponent)
            }
            // Best-effort base64 of .ovpn text (no official
            // standard — see the header comment).
            if let data = decodeBase64Flexible(rest),
               let text = String(data: data, encoding: .utf8),
               looksLikeOvpn(text) {
                return try parseOvpn(text)
            }
            throw ImportError.invalidLink
        }
        if link.hasPrefix("https://") || link.hasPrefix("http://") {
            guard let url = URL(string: link) else { throw ImportError.invalidLink }
            let text = try await downloadOvpn(from: url)
            return try parseOvpn(text, suggestedName: url.deletingPathExtension().lastPathComponent)
        }
        throw ImportError.invalidLink
    }

    /// Does this text look like a .ovpn profile? At least one
    /// directive line whose first token is `remote`.
    static func looksLikeOvpn(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            tokenize(stripComment(line)).first?.lowercased() == "remote"
        }
    }

    /// Download a .ovpn file: 2xx only, HTML error pages
    /// rejected (same as the SettingsView provider URL import),
    /// UTF-8 text, and it must look like a profile.
    private static func downloadOvpn(from url: URL) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ImportError.downloadFailed(error.localizedDescription)
        }
        // v0.2.155 audit N7: report the status code, and report
        // an empty body as empty — neither is "异常状态".
        guard let http = response as? HTTPURLResponse else {
            throw ImportError.downloadFailed("服务器返回异常状态")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ImportError.downloadFailed("服务器返回状态码 \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw ImportError.downloadFailed("服务器返回了空内容")
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("text/html") {
            throw ImportError.downloadFailed("服务器返回的是网页，不是 .ovpn 文件")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.notOvpnText
        }
        guard looksLikeOvpn(text) else { throw ImportError.notOvpnText }
        return text
    }

    /// Base64 or base64url, padding optional, inner whitespace
    /// tolerated.
    private static func decodeBase64Flexible(_ text: String) -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        cleaned = cleaned.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    /// Parse .ovpn text into a prefilled openvpn proxy.
    /// `suggestedName` is the file stem for file imports (or
    /// empty — the remote host is used then). Throws only when
    /// no node can be built at all (empty content / no remote).
    static func parseOvpn(_ text: String, suggestedName: String = "") throws -> Result {
        // Strip a UTF-8 BOM; split on \n and trim \r (CRLF).
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyFile
        }
        var remotes: [(host: String, port: Int?, proto: String?)] = []
        var portDirective: Int?
        var protoDirective: String?
        var dev: String?
        var caBlock = ""
        var certBlock = ""
        var keyBlock = ""
        var tlsAuthBlock = ""
        var tlsCryptBlock = ""
        var tlsCryptV2Block = ""
        var keyDirection = ""
        var fileRefs: [(label: String, file: String)] = []
        var authUserPass = false
        var authUserPassFile: String?
        var cipher = ""
        var dataCiphers = ""
        var dataCiphersFallback = ""
        var auth = ""
        var compLzo = false
        var ping = 0
        var pingRestart = 0
        var tranWindow = 0
        var handshakeTimeout = 0
        var mtu = 0
        var dns: [String] = []
        var ignored: [String] = []
        var intWarnings: [String] = []

        func noteIgnored(_ key: String) {
            if !ignored.contains(key) { ignored.append(key) }
        }

        // Walk the lines; inline blocks (<ca>…</ca> etc.) are
        // captured verbatim, everything else is a directive.
        // A <connection> block's inner lines are directives too
        // (its remotes count toward first-wins).
        let lines = cleaned.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            guard !rawLine.isEmpty else { continue }
            // A trailing comment after the tag still opens the
            // block (v0.2.155 audit N8): `<ca> # comment`.
            let tagLine = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if tagLine.hasPrefix("<"), tagLine.hasSuffix(">"), !tagLine.hasPrefix("</") {
                let tag = String(tagLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                var blockLines: [String] = []
                var closed = false
                while index < lines.count {
                    let inner = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    index += 1
                    // A trailing comment after the closing tag
                    // still closes the block (v0.2.155 audit N6).
                    if stripComment(inner).trimmingCharacters(in: .whitespaces).lowercased() == "</\(tag)>" {
                        closed = true
                        break
                    }
                    blockLines.append(inner)
                }
                // An unclosed block swallows the rest of the file
                // into the block (directives after it included) —
                // never silently: warn, so the user sees why the
                // node may be missing a remote or credentials.
                if !closed {
                    intWarnings.append("「<\(tag)>」块没有闭合，其后的内容已全部并入该块")
                }
                let block = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                switch tag {
                case "ca": caBlock = block
                case "cert": certBlock = block
                case "key": keyBlock = block
                case "tls-auth": tlsAuthBlock = block
                case "tls-crypt": tlsCryptBlock = block
                case "tls-crypt-v2": tlsCryptV2Block = block
                case "connection": break // handled below
                case "pkcs12":
                    noteIgnored("pkcs12")
                default:
                    noteIgnored("<\(tag)>")
                }
                // A <connection> block's lines are directives, so
                // re-run them through the directive parser.
                if tag == "connection" {
                    for inner in blockLines {
                        parseDirectiveLine(inner, into: &remotes, portDirective: &portDirective, protoDirective: &protoDirective, dev: &dev, fileRefs: &fileRefs, keyDirection: &keyDirection, authUserPass: &authUserPass, authUserPassFile: &authUserPassFile, cipher: &cipher, dataCiphers: &dataCiphers, dataCiphersFallback: &dataCiphersFallback, auth: &auth, compLzo: &compLzo, ping: &ping, pingRestart: &pingRestart, tranWindow: &tranWindow, handshakeTimeout: &handshakeTimeout, mtu: &mtu, dns: &dns, ignored: &ignored, intWarnings: &intWarnings)
                    }
                }
                continue
            }
            parseDirectiveLine(rawLine, into: &remotes, portDirective: &portDirective, protoDirective: &protoDirective, dev: &dev, fileRefs: &fileRefs, keyDirection: &keyDirection, authUserPass: &authUserPass, authUserPassFile: &authUserPassFile, cipher: &cipher, dataCiphers: &dataCiphers, dataCiphersFallback: &dataCiphersFallback, auth: &auth, compLzo: &compLzo, ping: &ping, pingRestart: &pingRestart, tranWindow: &tranWindow, handshakeTimeout: &handshakeTimeout, mtu: &mtu, dns: &dns, ignored: &ignored, intWarnings: &intWarnings)
        }

        guard let firstRemote = remotes.first else { throw ImportError.noRemote }
        // `remote [host] 1194 udp`: the host may be bracketed
        // IPv6 ([2001:db8::1]) — the core takes the bare address.
        let host = firstRemote.host.hasPrefix("[") && firstRemote.host.hasSuffix("]")
            ? String(firstRemote.host.dropFirst().dropLast()) : firstRemote.host
        let port = firstRemote.port ?? portDirective ?? 1194

        var warnings: [String] = []
        if remotes.count > 1 {
            warnings.append("文件中有 \(remotes.count) 个 remote，只用了第一个（\(host):\(port)），其余的已忽略")
        }
        // Proto: the core only accepts udp / tcp (openvpn.rs) —
        // udp6/tcp6 are mapped with a warning, tcp-server is a
        // server config (warned, treated as tcp).
        let rawProto = (firstRemote.proto ?? protoDirective ?? "udp").lowercased()
        var proto = "udp"
        switch rawProto {
        case "udp", "udp4": proto = "udp"
        case "udp6":
            proto = "udp"
            warnings.append("proto udp6 不受核心支持，已按 udp 导入")
        case "tcp", "tcp-client", "tcp4", "tcp4-client", "tcp6", "tcp6-client":
            proto = "tcp"
            if rawProto.contains("6") {
                warnings.append("proto \(rawProto) 不受核心支持，已按 tcp 导入")
            }
        case "tcp-server":
            proto = "tcp"
            warnings.append("这是服务器端配置（proto tcp-server），已按客户端导入，可能无法连接")
        default:
            warnings.append("proto \(rawProto) 不受支持，已按 udp 导入")
        }
        // A `proto` directive that loses to the remote line's
        // own proto is dropped, not silently (v0.2.155 audit
        // N5): in OpenVPN the remote's proto wins, but the user
        // should know the directive was ignored.
        if let remoteProto = firstRemote.proto, let directive = protoDirective,
           remoteProto.lowercased() != directive.lowercased() {
            warnings.append("remote 自带协议 \(remoteProto)，忽略了 proto 指令的 \(directive)")
        }
        if let dev, !dev.isEmpty {
            if dev.lowercased() != "tun" {
                warnings.append("dev \(dev) 不受核心支持（仅支持 tun），已按 tun 导入")
            }
        }
        // Cipher / auth allow-lists (v0.2.155 audit N1 — core
        // openvpn.rs OPENVPN_CIPHERS / OPENVPN_AUTHS at faaadad,
        // with the core's normalization: cipher trim + upper,
        // "" → AES-128-GCM, "AES-CBC" → AES-128-CBC; auth trim +
        // upper, "" → SHA256, "SHA-1" → SHA1). cipher/auth ARE
        // caught by validate.proxies at save, but the import
        // should name the bad value up front. data-ciphers
        // entries and data-ciphers-fallback are NEVER validated
        // by the core (stored verbatim), so an invalid one passes
        // save and only fails at tunnel connect — warn here.
        let supportedCiphers: Set<String> = ["AES-128-GCM", "AES-192-GCM", "AES-256-GCM", "AES-128-CBC", "AES-192-CBC", "AES-256-CBC", "CHACHA20-POLY1305"]
        let supportedAuths: Set<String> = ["MD5", "SHA1", "SHA256", "SHA384", "SHA512"]
        let cipherValue = cipher.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !cipherValue.isEmpty {
            let normalized = cipherValue == "AES-CBC" ? "AES-128-CBC" : cipherValue
            if !supportedCiphers.contains(normalized) {
                warnings.append("cipher「\(cipher)」不受核心支持，保存时会校验失败")
            }
        }
        let authValue = auth.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !authValue.isEmpty {
            let normalized = authValue == "SHA-1" ? "SHA1" : authValue
            if !supportedAuths.contains(normalized) {
                warnings.append("auth「\(auth)」不受核心支持，保存时会校验失败")
            }
        }
        for bad in dataCiphers.components(separatedBy: CharacterSet(charactersIn: ":,")) {
            let entry = bad.trimmingCharacters(in: .whitespacesAndNewlines)
            if !entry.isEmpty && !supportedCiphers.contains(entry.uppercased()) {
                warnings.append("data-ciphers 中的「\(entry)」不受核心支持，核心保存时不校验，连接时可能失败")
            }
        }
        let fallbackValue = dataCiphersFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallbackValue.isEmpty && !supportedCiphers.contains(fallbackValue.uppercased()) {
            warnings.append("data-ciphers-fallback「\(dataCiphersFallback)」不受核心支持，核心保存时不校验，连接时可能失败")
        }
        // key-direction other than 0/1 is dropped by
        // proxyJSONValue/yamlLines before validation ever sees
        // it (audit N2) — warn at parse time instead of silently
        // saving a node that differs from the .ovpn.
        if !keyDirection.isEmpty && keyDirection != "0" && keyDirection != "1" {
            warnings.append("key-direction「\(keyDirection)」不受核心支持（仅支持 0 / 1），已忽略")
        }
        // tls mutual exclusion (audit N3): the core rejects it
        // at save, but the import should name the conflict.
        if !tlsAuthBlock.isEmpty && !tlsCryptBlock.isEmpty {
            warnings.append("tls-auth 与 tls-crypt 不能同时设置，保存时会校验失败")
        }
        if !tlsCryptV2Block.isEmpty && (!tlsAuthBlock.isEmpty || !tlsCryptBlock.isEmpty) {
            warnings.append("tls-crypt-v2 不能与 tls-auth / tls-crypt 同时设置，保存时会校验失败")
        }
        // File-referenced credentials: the files are not here,
        // so the field stays empty for the user to paste in the
        // form (never a silent drop).
        for ref in fileRefs {
            // v0.2.155 audit N5: when the directive AND its inline
            // block are both present, the block supplies the value
            // — the file-ref warning would be spurious.
            let hasInline: Bool
            switch ref.label {
            case "CA": hasInline = !caBlock.isEmpty
            case "客户端证书": hasInline = !certBlock.isEmpty
            case "客户端密钥": hasInline = !keyBlock.isEmpty
            case "tls-auth": hasInline = !tlsAuthBlock.isEmpty
            case "tls-crypt": hasInline = !tlsCryptBlock.isEmpty
            default: hasInline = !tlsCryptV2Block.isEmpty
            }
            if !hasInline {
                warnings.append("\(ref.label)是文件引用「\(ref.file)」，未导入——请在表单中粘贴证书内容")
            }
        }
        // Credentials: a file-referenced item counts as present
        // for the checks below — the file-ref warning above
        // already tells the user to paste it, so the missing-CA
        // warning must not double-fire (audit N4), and a lone
        // cert or lone key must warn: the core requires the pair
        // (audit N3 — neither branch fired for cert-without-key).
        let hasCa = !caBlock.isEmpty || fileRefs.contains { $0.label == "CA" }
        let hasCert = !certBlock.isEmpty || fileRefs.contains { $0.label == "客户端证书" }
        let hasKey = !keyBlock.isEmpty || fileRefs.contains { $0.label == "客户端密钥" }
        if !hasCa {
            warnings.append("没有 CA 证书：请在表单中粘贴 CA 证书，否则保存时会校验失败")
        }
        if hasCert != hasKey {
            warnings.append("证书与密钥不完整：只导入了\(hasCert ? "证书" : "密钥")，两者必须成对填写")
        }
        if authUserPass, !hasCert, !hasKey {
            if let file = authUserPassFile {
                warnings.append("需要用户名和密码（auth-user-pass 来自文件 \(file)）：请在表单中填写")
            } else {
                warnings.append("需要用户名和密码（auth-user-pass）：请在表单中填写")
            }
        } else if !hasCert, !hasKey {
            warnings.append("没有认证信息：请填写证书 + 密钥，或在表单中填写用户名（需 auth-user-pass）")
        }
        warnings.append(contentsOf: intWarnings)
        if !ignored.isEmpty {
            let shown = ignored.prefix(8).joined(separator: "、")
            let extra = ignored.count > 8 ? " 等 \(ignored.count) 条" : ""
            warnings.append("已忽略 \(ignored.count) 条本应用不支持的指令：\(shown)\(extra)")
        }

        var proxy = CustomProxy()
        let name = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.name = name.isEmpty ? host : name
        proxy.type = "openvpn"
        proxy.server = host
        proxy.port = port
        proxy.ovpnProto = proto
        proxy.ovpnCa = caBlock
        proxy.ovpnCert = certBlock
        proxy.ovpnKey = keyBlock
        proxy.ovpnTlsAuth = tlsAuthBlock
        proxy.ovpnTlsCrypt = tlsCryptBlock
        proxy.ovpnTlsCryptV2 = tlsCryptV2Block
        proxy.ovpnKeyDirection = keyDirection
        proxy.cipher = cipher
        proxy.ovpnDataCiphers = dataCiphers
        proxy.ovpnDataCiphersFallback = dataCiphersFallback
        proxy.ovpnAuth = auth
        proxy.ovpnCompLzo = compLzo
        proxy.ovpnPing = ping
        proxy.ovpnPingRestart = pingRestart
        proxy.ovpnTranWindow = tranWindow
        proxy.ovpnHandshakeTimeout = handshakeTimeout
        proxy.ovpnMtu = mtu
        proxy.ovpnDns = dns.joined(separator: ", ")
        proxy.udp = true
        return Result(proxy: proxy, warnings: warnings)
    }

    /// One directive line (comments already stripped by the
    /// caller for top-level lines; connection-block lines are
    /// stripped here). Unknown directives are recorded in
    /// `ignored`, never silently dropped.
    private static func parseDirectiveLine(
        _ rawLine: String,
        into remotes: inout [(host: String, port: Int?, proto: String?)],
        portDirective: inout Int?,
        protoDirective: inout String?,
        dev: inout String?,
        fileRefs: inout [(label: String, file: String)],
        keyDirection: inout String,
        authUserPass: inout Bool,
        authUserPassFile: inout String?,
        cipher: inout String,
        dataCiphers: inout String,
        dataCiphersFallback: inout String,
        auth: inout String,
        compLzo: inout Bool,
        ping: inout Int,
        pingRestart: inout Int,
        tranWindow: inout Int,
        handshakeTimeout: inout Int,
        mtu: inout Int,
        dns: inout [String],
        ignored: inout [String],
        intWarnings: inout [String]
    ) {
        let tokens = tokenize(stripComment(rawLine))
        guard let key = tokens.first?.lowercased() else { return }
        // (No nested closures here: a nested function may not
        // capture an inout parameter, so both helpers take the
        // array as an explicit inout argument.)
        func noteIgnored(_ key: String, list: inout [String]) {
            if !list.contains(key) { list.append(key) }
        }
        func intValue(_ raw: String?, name: String, warnings: inout [String]) -> Int {
            guard let raw, let value = Int(raw), value >= 0 else {
                warnings.append("指令 \(name) 的值无效，已忽略")
                return 0
            }
            return value
        }
        switch key {
        case "remote":
            guard tokens.count >= 2 else { return }
            let host = tokens[1]
            // An unparseable / out-of-range port is ignored
            // (with a warning) instead of landing as 0 — the
            // final port then falls back to the `port` directive
            // or 1194 (audit N2).
            var port: Int?
            if tokens.count >= 3 {
                if let value = Int(tokens[2]), value > 0, value <= 65535 {
                    port = value
                } else {
                    intWarnings.append("remote 的端口「\(tokens[2])」无效，已忽略")
                }
            }
            let proto = tokens.count >= 4 ? tokens[3] : nil
            remotes.append((host: host, port: port, proto: proto))
        case "proto":
            if tokens.count >= 2 { protoDirective = tokens[1] }
        case "port":
            // Invalid values must NOT land as 0 (audit N2):
            // a 0 port would reach the form with Save disabled
            // and no explanation. Only a valid 1–65535 value is
            // kept; anything else is warned and ignored, so the
            // final port falls back to the remote port or 1194.
            if tokens.count >= 2 {
                let value = intValue(tokens[1], name: "port", warnings: &intWarnings)
                if value > 0, value <= 65535 {
                    portDirective = value
                } else if value > 65535 {
                    intWarnings.append("指令 port 的值超出范围（1–65535），已忽略")
                }
            }
        case "dev":
            if tokens.count >= 2 { dev = tokens[1] }
        case "dev-type":
            if tokens.count >= 2 { dev = tokens[1] }
        case "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2":
            // Inline content comes from <…> blocks; a directive
            // with an argument is a file reference the import
            // cannot resolve (the file is not here).
            guard tokens.count >= 2 else { return }
            let label: String
            switch key {
            case "ca": label = "CA"
            case "cert": label = "客户端证书"
            case "key": label = "客户端密钥"
            case "tls-auth": label = "tls-auth"
            case "tls-crypt": label = "tls-crypt"
            default: label = "tls-crypt-v2"
            }
            fileRefs.append((label: label, file: tokens[1]))
            if key == "tls-auth", tokens.count >= 3 {
                keyDirection = tokens[2]
            }
        case "key-direction":
            if tokens.count >= 2 { keyDirection = tokens[1] }
        case "auth-user-pass":
            authUserPass = true
            if tokens.count >= 2 { authUserPassFile = tokens[1] }
        case "cipher":
            if tokens.count >= 2 { cipher = tokens[1] }
        case "data-ciphers":
            if tokens.count >= 2 {
                // .ovpn separates with ':' (or spaces) — the
                // form's splitList splits on ',' and ':'.
                dataCiphers = tokens[1...].joined(separator: ":")
            }
        case "data-ciphers-fallback":
            if tokens.count >= 2 { dataCiphersFallback = tokens[1] }
        case "auth":
            if tokens.count >= 2 { auth = tokens[1] }
        case "comp-lzo":
            compLzo = tokens.count < 2
                || tokens[1].lowercased() == "yes"
                || tokens[1].lowercased() == "adaptive"
        case "ping":
            if tokens.count >= 2 { ping = intValue(tokens[1], name: "ping", warnings: &intWarnings) }
        case "ping-restart":
            if tokens.count >= 2 { pingRestart = intValue(tokens[1], name: "ping-restart", warnings: &intWarnings) }
        case "tran-window":
            if tokens.count >= 2 { tranWindow = intValue(tokens[1], name: "tran-window", warnings: &intWarnings) }
        case "handshake-timeout":
            if tokens.count >= 2 { handshakeTimeout = intValue(tokens[1], name: "handshake-timeout", warnings: &intWarnings) }
        case "mtu":
            if tokens.count >= 2 { mtu = intValue(tokens[1], name: "mtu", warnings: &intWarnings) }
        case "dhcp-option":
            // Only DNS is mappable (ovpnDns); DOMAIN and the
            // rest go to the ignored summary.
            if tokens.count >= 3, tokens[1].lowercased() == "dns" {
                dns.append(tokens[2])
            } else {
                noteIgnored(key, list: &ignored)
            }
        case "client", "nobind", "persist-key", "persist-tun", "verb", "mute",
             "pull", "resolv-retry", "auth-nocache", "reneg-sec",
             "explicit-exit-notify", "remote-cert-tls", "verify-x509-name",
             "float", "fast-io", "mssfix", "fragment", "tun-mtu", "link-mtu",
             "replay-window", "auth-retry", "connect-retry", "connect-timeout",
             "server-poll-timeout", "inactive", "topology", "ifconfig",
             "setenv", "script-security", "up", "down", "keysize",
             "tls-version-min", "tls-cipher", "route", "route-ipv6",
             "redirect-gateway", "route-delay", "route-metric",
             "dhcp-renew", "dhcp-release", "register-dns", "block-outside-dns",
             "allow-recursive-routing", "remap-usr1", "tls-exit",
             "connect-retry-max", "keepalive", "replay-persist":
            noteIgnored(key, list: &ignored)
        default:
            noteIgnored(key, list: &ignored)
        }
    }

    /// Cut a `#` / `;` comment: at line start or preceded by
    /// whitespace, and not inside double quotes. PEM blocks are
    /// never passed through here (they are captured verbatim),
    /// so their base64 is safe either way.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes, (ch == "#" || ch == ";"),
               previous == nil || previous!.isWhitespace {
                return String(line[..<index])
            }
            previous = ch
            index = line.index(after: index)
        }
        return line
    }

    /// Split a directive line on whitespace, respecting double
    /// quotes (quotes are removed).
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Import an OpenVPN node from a link (v0.2.155): openvpn://
/// import-profile / plain https .ovpn URL / openvpn://base64 /
/// raw .ovpn text. Parses into a CustomProxy and hands it to the
/// caller, which opens the proxy form prefilled (with the parse
/// warnings) so the user can review and save.
private struct OpenVPNImportSheetView: View {
    var onImport: (OpenVPNImport.Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("OpenVPN 链接").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    TextField("openvpn://… 或 https://… .ovpn", text: $linkText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("支持四种：openvpn://import-profile/<https 链接>（官方 OpenVPN Connect 格式）、https://… .ovpn 直链、openvpn://<base64 配置>、直接粘贴 .ovpn 文本。也可以用代理页的「导入 .ovpn 文件」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(isImporting ? "导入中…" : "导入") {
                        Task { await importLink() }
                    }
                    .disabled(isImporting || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("导入 OpenVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func importLink() async {
        errorMessage = nil
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await OpenVPNImport.importLink(linkText)
            onImport(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Proxy form

struct CustomProxyFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: CustomProxy
    /// The proxy as opened (dirty = changed since open).
    private let original: CustomProxy
    @State private var showDiscardConfirm = false
    /// Last save failure, shown in the form (v0.2.151 B2: the
    /// sheet no longer dismisses on a failed validation).
    @State private var saveError: String?
    /// Parse warnings from an OpenVPN import (v0.2.155): shown
    /// at the top of the form so the user reviews them before
    /// saving. Empty for hand-written / edited nodes.
    private let importWarnings: [String]
    let isNew: Bool
    /// Validates + saves; nil = saved (dismiss), otherwise the
    /// failure message to show in the form (stay open).
    let onSave: (CustomProxy) async -> String?

    init(proxy: CustomProxy, isNew: Bool = false, importWarnings: [String] = [], onSave: @escaping (CustomProxy) async -> String?) {
        _proxy = State(initialValue: proxy)
        self.original = proxy
        self.isNew = isNew
        self.importWarnings = importWarnings
        self.onSave = onSave
    }

    private var isDirty: Bool { proxy != original }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                // v0.2.155: what the .ovpn / link import could
                // not map cleanly (missing CA, file-referenced
                // certificates, auth-user-pass without
                // credentials, ignored directives) — the user
                // completes it here; save-time validate.proxies
                // enforces the core's requirements.
                if !importWarnings.isEmpty {
                    Section(header: Text("导入提示").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                        ForEach(Array(importWarnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("请检查上面这些提示再保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(header: Text("基本").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    TextField("名称", text: $proxy.name)
                    Picker("类型", selection: $proxy.type) {
                        ForEach(CustomProxy.types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    TextField("服务器", text: $proxy.server)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", value: $proxy.port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section(header: Text("认证").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    if proxy.type == "openvpn" {
                        TextField("用户名", text: $proxy.ovpnUsername)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("密码", text: $proxy.password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("证书认证和用户名认证二选一：填了证书 + 密钥就不用用户名；只用用户名也可以（密码可空）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if proxy.type == "vmess" || proxy.type == "vless" {
                        TextField("UUID", text: $proxy.uuid)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        TextField("密码", text: $proxy.password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    if proxy.type == "ss" || proxy.type == "vmess" {
                        TextField("加密方式，如 aes-128-gcm", text: $proxy.cipher)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                if proxy.type == "openvpn" {
                    Section(header: Text("证书").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                        Text("CA 证书（必填，PEM 文本）")
                        TextEditor(text: $proxy.ovpnCa)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("客户端证书（与密钥一起填才生效）")
                        TextEditor(text: $proxy.ovpnCert)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("客户端密钥")
                        TextEditor(text: $proxy.ovpnKey)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-auth（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsAuth)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-crypt（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsCrypt)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("tls-crypt-v2（三选一，可不填）")
                        TextEditor(text: $proxy.ovpnTlsCryptV2)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 64)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Picker("密钥方向", selection: $proxy.ovpnKeyDirection) {
                            Text("不设置").tag("")
                            Text("0").tag("0")
                            Text("1").tag("1")
                        }
                        Text("tls-auth 和 tls-crypt 不能同时填；tls-crypt-v2 不能和前两者同时填。保存前会用核心校验，不合要求会报错。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section(header: Text("加密").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                        Picker("协议", selection: $proxy.ovpnProto) {
                            Text("UDP").tag("udp")
                            Text("TCP").tag("tcp")
                        }
                        Picker("加密方式", selection: $proxy.cipher) {
                            Text("默认（AES-128-GCM）").tag("")
                            ForEach(CustomProxy.openvpnCiphers, id: \.self) { cipher in
                                Text(cipher).tag(cipher)
                            }
                        }
                        TextField("data-ciphers，多个用逗号隔开", text: $proxy.ovpnDataCiphers)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Picker("备用加密", selection: $proxy.ovpnDataCiphersFallback) {
                            Text("不设置").tag("")
                            ForEach(CustomProxy.openvpnCiphers, id: \.self) { cipher in
                                Text(cipher).tag(cipher)
                            }
                        }
                        Picker("认证摘要", selection: $proxy.ovpnAuth) {
                            Text("默认（SHA256）").tag("")
                            ForEach(CustomProxy.openvpnAuths, id: \.self) { auth in
                                Text(auth).tag(auth)
                            }
                        }
                        Toggle("comp-lzo", isOn: $proxy.ovpnCompLzo)
                            .toggleStyle(UpstreamToggleStyle())
                    }
                    Section(header: Text("高级").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                        TextField("ping（秒，0 = 不设置）", value: $proxy.ovpnPing, format: .number)
                            .keyboardType(.numberPad)
                        TextField("ping-restart（秒，0 = 不设置）", value: $proxy.ovpnPingRestart, format: .number)
                            .keyboardType(.numberPad)
                        TextField("tran-window（秒，0 = 不设置）", value: $proxy.ovpnTranWindow, format: .number)
                            .keyboardType(.numberPad)
                        TextField("handshake-timeout（秒，0 = 不设置）", value: $proxy.ovpnHandshakeTimeout, format: .number)
                            .keyboardType(.numberPad)
                        TextField("MTU（0 = 默认）", value: $proxy.ovpnMtu, format: .number)
                            .keyboardType(.numberPad)
                        Toggle("remote-dns-resolve", isOn: $proxy.ovpnRemoteDnsResolve)
                            .toggleStyle(UpstreamToggleStyle())
                        TextField("DNS，多个用逗号隔开", text: $proxy.ovpnDns)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                if proxy.type != "openvpn" {
                    Section(header: Text("传输").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                        if proxy.type == "vmess" || proxy.type == "vless" || proxy.type == "trojan" {
                            Toggle("TLS", isOn: $proxy.tls)
                            .toggleStyle(UpstreamToggleStyle())
                            TextField("SNI / servername", text: $proxy.sni)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        if proxy.type == "vmess" || proxy.type == "vless" {
                            TextField("网络，如 ws / grpc", text: $proxy.network)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        Toggle("UDP", isOn: $proxy.udp)
                            .toggleStyle(UpstreamToggleStyle())
                    }
                }
            }
            .navigationTitle(proxy.id.isEmpty || isNew ? "添加代理" : "编辑代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if let error = await onSave(proxy) {
                                saveError = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(proxy.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.server.trimmingCharacters(in: .whitespaces).isEmpty
                        || proxy.port <= 0)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }
}

// MARK: - Raw ("添加到本地") node editor

/// Single-item trigger for the raw-node edit sheet (the row index
/// as the item identity).
private struct RawProxyEditItem: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Edits one raw node definition losslessly for the fields the
/// form can express (name / server / port); every other key
/// (ws-opts, grpc-opts, reality-opts, flow, alpn, …) is kept
/// verbatim in the JSON object. The full definition is shown
/// below so the user can see what is preserved. Delete removes
/// the node from the store (and, via the caller's re-bake, from
/// the profile) for real.
struct RawProxyEditView: View {
    let definition: JSONValue
    var onSave: (JSONValue) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var server: String
    @State private var portText: String
    /// The values as opened (dirty = changed since open).
    private let originalName: String
    private let originalServer: String
    private let originalPortText: String
    @State private var showDiscardConfirm = false

    init(definition: JSONValue, onSave: @escaping (JSONValue) -> Void, onDelete: @escaping () -> Void) {
        self.definition = definition
        self.onSave = onSave
        self.onDelete = onDelete
        let object = definition.objectValue ?? [:]
        _name = State(initialValue: object["name"]?.stringValue ?? "")
        _server = State(initialValue: object["server"]?.stringValue ?? "")
        var port = ""
        if let value = object["port"], case .int(let number) = value {
            port = String(number)
        }
        _portText = State(initialValue: port)
        self.originalName = object["name"]?.stringValue ?? ""
        self.originalServer = object["server"]?.stringValue ?? ""
        self.originalPortText = port
    }

    private var isDirty: Bool {
        name != originalName || server != originalServer || portText != originalPortText
    }

    private var yamlText: String {
        YAMLValue.proxyItemLines(for: definition, indent: 2).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基本").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    TextField("名称", text: $name)
                    TextField("服务器", text: $server)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    Text("只能改这三项：其余参数（传输选项等）不在表单里，会按原样保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(header: Text("完整定义（原样保留）").font(.headline).foregroundStyle(ConcordTheme.onSurfaceVariant)) {
                    Text(yamlText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Button("删除此节点", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑本地节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .discardChangesGuard(isDirty: isDirty, showConfirm: $showDiscardConfirm) { dismiss() }
    }

    private func save() {
        guard var dict = definition.objectValue else { return }
        dict["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
        if !trimmedServer.isEmpty { dict["server"] = .string(trimmedServer) }
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)), port > 0 {
            dict["port"] = .int(Int64(port))
        }
        onSave(.object(dict))
    }
}
