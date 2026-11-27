import SwiftUI
import Security

// MARK: - MITM options (FlClash: mitm.dart MitmOptionsView, "选项")
// ONE page, as upstream has it (v0.2.143 merged the certificate
// page into this one — the certificate page had no entry point
// since the 136 Tools re-org): install guidance, the CA section
// (details, install / export / generate / regenerate / delete),
// trust detection, the trusted-fingerprint field, the capture
// section and the four toggles. The enable toggle and the hostname
// link are NOT here: upstream keeps them in the Advanced Config
// MITM section (advanced.dart), which our 进阶配置 MITM card
// already mirrors. The CA itself must be installed and trusted
// by the user in iOS Settings — the app cannot install a trusted
// CA. The exchange log lives in MitmView (reachable from 常规）.
// v0.2.137: the "校验 MITM 配置" / "保存并应用" buttons and the
// "签发叶证书" section are gone (upstream mitm.dart has neither —
// it writes config live and has no leaf-issuance UI); the
// validate / apply / issue functions stay in SettingsStore as
// dead code, harmless.
//
// Trust check (FlClash: lib/common/mitm_trust.dart
// IOSMitmTrustStore.check): the core signs a leaf for
// mitm-check.flclash.invalid and the leaf is evaluated against the
// system trust store with SecTrust. It only runs locally and never
// leaves the device: a pass means the CA is installed AND fully
// trusted; a fail means it is missing or its "fully trust" switch
// is still off in Settings → General → About → Certificate Trust
// Settings. The check cannot tell those two apart — iOS does not
// let an app list the system store — so the UI says so.

/// One trust-check outcome (FlClash MitmTrustCheck, iOS subset:
/// ready / untrusted — iOS cannot tell "not installed" from
/// "installed but not fully trusted", so both are "untrusted" with
/// the explanation in the message).
private struct MitmTrustResult {
    /// The leaf the core signs for the trust store to verify
    /// (FlClash mitmCheckHost).
    static let checkHost = "mitm-check.flclash.invalid"

    var isReady: Bool
    var message: String
}

/// Shared trust evaluation (FlClash IOSMitmTrustStore.check),
/// used by MitmOptionsView: issue a leaf for the check host and evaluate it against the system
/// trust store, all locally. Returns nil when the leaf cannot be
/// issued at all (e.g. the in-app core fails to boot) — callers
/// keep their previous result instead of overwriting a good one
/// with "无法检测". Callers guard live mode / CA presence first.
private func mitmTrustCheckResult(settingsStore: SettingsStore) async -> MitmTrustResult? {
    do {
        let leafPem: String
        if TunnelManager.shared.isRunning {
            leafPem = try await settingsStore.client
                .mitmIssueCertificate(host: MitmTrustResult.checkHost).pem
        } else {
            // VPN off: issue the leaf from the in-app core.
            do {
                try await AppCore.shared.ensureStarted()
                leafPem = try await AppCore.shared
                    .mitmIssueCertificate(host: MitmTrustResult.checkHost).pem
            } catch {
                if case AppCoreError.tunnelRunning = error {
                    // The tunnel started mid-check: use it.
                    leafPem = try await settingsStore.client
                        .mitmIssueCertificate(host: MitmTrustResult.checkHost).pem
                } else {
                    return nil
                }
            }
        }
        guard let leafData = mitmDerData(fromPEM: leafPem),
              let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
            return MitmTrustResult(
                isReady: false,
                message: "无法检测：核心签发的叶证书读不出来")
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, MitmTrustResult.checkHost as CFString)
        guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess,
              let trust else {
            return MitmTrustResult(
                isReady: false,
                message: "无法检测：系统信任评估创建失败")
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return MitmTrustResult(
                isReady: true,
                message: "CA 已安装并受信任：HTTPS 可以解密")
        } else {
            return MitmTrustResult(
                isReady: false,
                message: "CA 未受信任：还没安装，或安装后没在「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任")
        }
    } catch {
        return MitmTrustResult(
            isReady: false,
            message: "无法检测：\(error.localizedDescription)")
    }
}

/// PEM text to DER bytes (strip the armor lines, base64-decode).
private func mitmDerData(fromPEM pem: String) -> Data? {
    let body = pem.components(separatedBy: .newlines)
        .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .joined()
    return Data(base64Encoded: body)
}

// MARK: - MITM hostname list editor (FlClash: _MitmHostnameView,
// lib/views/config/mitm.dart:682-760)
// One hostname per row: in-place edit, swipe delete, drag reorder,
// per-line validation, multi-select delete, plus a bulk quick-edit
// (one per line, upstream onQuickEdit).
// Stored as the comma-joined string in SettingsStore.mitmHostnames,
// exactly as the MITM section read it before.

struct MitmHostnameEditorView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var hostnames: [String] = []
    @State private var newHostname = ""
    @State private var addError: String?
    @State private var showAddSheet = false
    @State private var showBulkEdit = false
    @State private var bulkText = ""
    @State private var searchText = ""
    /// Multi-select delete (upstream ListEditorPage): indices into
    /// `hostnames` of the rows currently selected.
    @State private var isSelecting = false
    @State private var selectedIndices: Set<Int> = []

    /// The rows the search shows, as indices into `hostnames`.
    private var visibleIndices: [Int] {
        hostnames.indices.filter {
            searchText.isEmpty || hostnames[$0].localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                if hostnames.isEmpty {
                    Text("暂无主机名")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleIndices, id: \.self) { index in
                    HostnameRowView(
                        hostnames: $hostnames,
                        index: index,
                        isSelecting: isSelecting,
                        isSelected: selectedIndices.contains(index),
                        onToggleSelect: { toggleSelection(index) }
                    )
                }
                .onDelete { offsets in
                    // Offsets are positions in the visible list;
                    // translate them back to `hostnames` indices.
                    for index in offsets.map({ visibleIndices[$0] }).sorted(by: >) {
                        hostnames.remove(at: index)
                    }
                    save()
                }
                .onMove { from, to in
                    // A filtered move would reorder the visible
                    // subset, not the list — only move unfiltered.
                    // No moving while selecting either: a move
                    // shifts indices and would corrupt the
                    // selection.
                    guard searchText.isEmpty, !isSelecting else { return }
                    hostnames.move(fromOffsets: from, toOffset: to)
                    save()
                }
                if !invalidHostnames.isEmpty {
                    Text("格式不对的域名（不会生效）：\(invalidHostnames.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let addError {
                    Text(addError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                // Upstream onQuickEdit (mitm.dart:715): bulk edit
                // is part of upstream's hostname editor, not an
                // ours-only extra.
                Section {
                    Button("批量编辑（每行一个）") {
                        bulkText = hostnames.joined(separator: "\n")
                        showBulkEdit = true
                    }
                    .disabled(isSelecting)
                }
            }
            // v0.2.68 (MuYu): the search is a BOTTOM floating pill,
            // not a top .searchable. While selecting (upstream
            // ListEditorPage multi-select), the pill is replaced by
            // the delete bar.
            if isSelecting {
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("删除所选 (\(selectedIndices.count))")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedIndices.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, ConcordTheme.tabBarClearance + 8)
            } else {
                bottomSearchPill
                    .padding(.horizontal, 16)
                    .padding(.bottom, ConcordTheme.tabBarClearance + 8)
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance + 56)
        .font(.footnote.weight(.semibold))
        .navigationTitle("主机名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "完成" : "选择") {
                    if isSelecting {
                        isSelecting = false
                        selectedIndices.removeAll()
                    } else {
                        isSelecting = true
                    }
                }
                .disabled(hostnames.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newHostname = ""
                    addError = nil
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("添加主机名")
                .disabled(isSelecting)
            }
        }
        .onAppear {
            hostnames = settingsStore.mitmHostnames
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        .onChange(of: hostnames) { _, _ in
            save()
            // A structural change (add / swipe-delete / bulk edit /
            // reorder) shifts indices — drop the selection rather
            // than risk deleting the wrong rows. (Selection
            // toggling itself never touches `hostnames`.)
            if !selectedIndices.isEmpty {
                selectedIndices.removeAll()
            }
            if hostnames.isEmpty {
                isSelecting = false
            }
        }
        // Upstream _handleAddOrUpdate → showListEntryDialog
        // (mitm.dart:692): adding a hostname is a dialog, not a
        // sheet. A failed add writes addError, which the list
        // above shows (the dialog itself closes on tap).
        .alert("添加主机名", isPresented: $showAddSheet) {
            TextField("域名，如 *.example.com", text: $newHostname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                newHostname = ""
                addError = nil
            }
            Button("添加") { addHostname() }
        } message: {
            Text("以 - 开头表示排除该域名（不解密）。支持 *.example.com 这样的通配符。")
        }
        // Upstream _handleQuickEdit → showListQuickEdit
        // (mitm.dart:715): bulk edit is a dialog, not a sheet.
        .alert("批量编辑主机名", isPresented: $showBulkEdit) {
            TextField("每行一个域名", text: $bulkText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("保存") {
                hostnames = bulkText
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                save()
            }
        } message: {
            Text("每行一个域名，空行会被忽略。")
        }
    }

    /// Bottom floating search pill (MuYu): a capsule with a
    /// magnifier, a text field and a clear button, floating above
    /// the list instead of a top .searchable bar.
    private var bottomSearchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ConcordTheme.cardBackground, in: Capsule())
        .shadow(color: ConcordTheme.cardShadow, radius: 8, x: 0, y: 2)
    }

    private var invalidHostnames: [String] {
        hostnames.filter { !Self.isValidHostname($0) }
    }

    private func addHostname() {
        let value = newHostname.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        guard Self.isValidHostname(value) else {
            addError = "格式不对，应为域名或 *.域名，如 *.example.com"
            return
        }
        guard !hostnames.contains(value) else {
            addError = "这个域名已存在"
            return
        }
        addError = nil
        hostnames.append(value)
        newHostname = ""
        save()
    }

    /// Multi-select delete (upstream ListEditorPage): toggle one
    /// row's selection. Indices, not values — two identical
    /// entries stay distinguishable.
    private func toggleSelection(_ index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
    }

    /// Deletes the selected rows (highest index first, so earlier
    /// indices stay valid) and leaves selection mode.
    private func deleteSelected() {
        guard !selectedIndices.isEmpty else { return }
        for index in selectedIndices.sorted(by: >) {
            guard hostnames.indices.contains(index) else { continue }
            hostnames.remove(at: index)
        }
        selectedIndices.removeAll()
        isSelecting = false
        save()
    }

    private func save() {
        settingsStore.mitmHostnames = hostnames.joined(separator: ", ")
        settingsStore.save()
    }

    /// A hostname, optionally with a "*." wildcard prefix and an
    /// optional "-" exclusion prefix.
    static func isValidHostname(_ value: String) -> Bool {
        var host = value
        if host.hasPrefix("-") {
            host = String(host.dropFirst())
        }
        if host.hasPrefix("*.") {
            host = String(host.dropFirst(2))
        }
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."),
              !host.contains("..") else { return false }
        let labels = host.split(separator: ".")
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                return false
            }
        }
        return true
    }
}

/// One MITM hostname row, extracted into its own view so the List
/// body stays trivial for the type checker (the inline row previously
/// timed out type-checking).
///
/// v0.2.68 (MuYu): a per-row radio — filled circle = selected
/// (decrypt this host), hollow circle = unselected (excluded).
/// The radio maps to the existing "-" prefix mechanism: tapping it
/// adds/removes the "-" prefix on the stored entry. The text field
/// shows the hostname without the prefix; editing keeps the
/// prefix state.
private struct HostnameRowView: View {
    @Binding var hostnames: [String]
    let index: Int
    /// Multi-select delete (upstream ListEditorPage): when
    /// selecting, the row shows a checkmark and the whole row
    /// toggles selection — the exclude radio and the text field
    /// are inert, so a tap can never edit while selecting.
    var isSelecting = false
    var isSelected = false
    var onToggleSelect: (() -> Void)? = nil

    private var isExcluded: Bool { hostnames[index].hasPrefix("-") }

    private var displayName: String {
        isExcluded ? String(hostnames[index].dropFirst()) : hostnames[index]
    }

    var body: some View {
        if isSelecting {
            Button(action: { onToggleSelect?() }) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? ConcordTheme.accent : .secondary)
                    Text(displayName)
                        .foregroundStyle(MitmHostnameEditorView.isValidHostname(hostnames[index]) ? Color.primary : Color.red)
                    Spacer()
                    if !MitmHostnameEditorView.isValidHostname(hostnames[index]) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(displayName)" : "选择 \(displayName)")
        } else {
            HStack {
                Button {
                    if isExcluded {
                        hostnames[index] = displayName
                    } else {
                        hostnames[index] = "-" + hostnames[index]
                    }
                } label: {
                    Image(systemName: isExcluded ? "circle" : "circle.fill")
                        .foregroundStyle(isExcluded ? .secondary : ConcordTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExcluded ? "排除，不解密 \(displayName)" : "解密 \(displayName)")
                TextField("域名，如 *.example.com", text: Binding(
                    get: { displayName },
                    set: { hostnames[index] = isExcluded ? "-" + $0 : $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(MitmHostnameEditorView.isValidHostname(hostnames[index]) ? Color.primary : Color.red)
                if !MitmHostnameEditorView.isValidHostname(hostnames[index]) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - MITM options (FlClash: mitm.dart MitmOptionsView, "选项")
// ONE page, as upstream has it (v0.2.143 merged the certificate
// page into this one — it had no entry point since the 136 Tools
// re-org): install guidance, the CA section (details, install /
// export / generate / regenerate / delete, engine note,
// trusted-fingerprint field), trust detection, the capture section
// and the four toggles, in upstream order. The enable toggle and
// the hostname link are NOT here: upstream keeps them in the
// Advanced Config MITM section (advanced.dart), which our
// 进阶配置 MITM card already mirrors. The video's labels:
// 跳过服务器证书验证, HTTP/2, 本机未信任时也解密.
// No "解密 TLS" toggle (upstream has none — enable IS HTTPS
// decryption, v0.2.137).
struct MitmOptionsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    // h2 / decrypt-untrusted live in UserDefaults (@AppStorage in
    // SettingsView too, same keys) — the core reads them via
    // SettingsStore.mitmConfig.
    @AppStorage("ConcordiOS.mitmH2") private var mitmH2 = false
    @AppStorage("ConcordiOS.mitmDecryptUntrusted") private var mitmDecryptUntrusted = false

    @State private var isRestartingVpn = false
    @State private var restartMessage: String?
    @State private var trustResult: MitmTrustResult?
    @State private var isCheckingTrust = false
    @State private var showRegenerateConfirm = false
    @State private var showDeleteCAConfirm = false
    @State private var regenerateNote: String?
    @State private var showExportCAConfirm = false
    @State private var caExportMessage: String?
    @State private var showCAExportAlert = false
    @State private var isInstallingProfile = false
    @State private var installMessage: String?
    @State private var installFailed = false
    @State private var installHint: String?

    private var captureStatusText: String {
        settingsStore.mitmCapture ? "已开启" : "未开启"
    }

    private var trustStatusText: String {
        guard let trustResult else { return "未检测" }
        return trustResult.isReady ? "已信任" : "未信任"
    }

    var body: some View {
        List {
            Section {
                Text("安装分两步：① 点下面的「安装描述文件」，系统会打开安装页面，按提示装好描述文件（装完后在「设置 → 通用 → VPN 与设备管理」里能看到它）；② 去「设置 → 通用 → 关于本机 → 证书信任设置」里打开 FlClash CA 的完全信任。应用本身装不了系统证书，这两步都要手动完成。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            caCertificateSection
            Section("信任检测") {
                Text("检测会请核心签发一张 mitm-check.flclash.invalid 的叶证书，再用系统信任库验证它（只在本地验证，不联网）。通过 = CA 已安装且已完全信任；不通过 = CA 还没装，或装了但没在「证书信任设置」里打开完全信任——本应用无法区分这两种情况。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let trustResult {
                    HStack {
                        Image(systemName: trustResult.isReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(trustResult.isReady ? .green : .orange)
                        Text(trustResult.message)
                            .font(.footnote)
                    }
                }
                if isCheckingTrust {
                    ProgressView()
                }
                Button("检测信任状态") {
                    Task { await checkTrust() }
                }
                .disabled(isCheckingTrust || !settingsStore.mitmAvailable || settingsStore.mitmCertificate == nil)
            }
            Section {
                // 抓包 is a status row in the video, not a toggle:
                // tapping the row flips the capture switch.
                Button {
                    settingsStore.mitmCapture.toggle()
                    settingsStore.save()
                } label: {
                    HStack {
                        Text("抓包")
                            .foregroundStyle(Color(.label))
                        Spacer()
                        Text(captureStatusText)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!settingsStore.mitmAvailable)
                // FlClash clash_config.dart:2264-2272: the capture
                // limit is a picker — desktop [500..20000], default
                // 2000. v0.2.137 restores it (the value was fixed at
                // 64 with no UI since the picker was removed).
                Picker("保留条数", selection: $settingsStore.mitmCaptureEntries) {
                    ForEach([500, 1000, 2000, 5000, 10000, 20000], id: \.self) { value in
                        Text("\(value) 条").tag(value)
                    }
                }
                .disabled(!settingsStore.mitmAvailable)
                .onChange(of: settingsStore.mitmCaptureEntries) { _, _ in settingsStore.save() }
                Button(isRestartingVpn ? "重启中…" : "重启隧道") {
                    Task { await restartVpn() }
                }
                .disabled(isRestartingVpn)
                if let restartMessage {
                    Text(restartMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("MITM 的改动需重启隧道后生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("跳过服务器证书验证", isOn: $settingsStore.mitmSkipServerCertVerify)
                    .disabled(!settingsStore.mitmAvailable)
                    .onChange(of: settingsStore.mitmSkipServerCertVerify) { _, _ in settingsStore.save() }
                Toggle("阻止 QUIC", isOn: $settingsStore.mitmAutoQuicBlock)
                    .disabled(!settingsStore.mitmAvailable)
                    .onChange(of: settingsStore.mitmAutoQuicBlock) { _, _ in settingsStore.save() }
                Toggle("HTTP/2", isOn: $mitmH2)
                    .disabled(!settingsStore.mitmAvailable)
                    .onChange(of: mitmH2) { _, _ in settingsStore.save() }
                Toggle("本机未信任时也解密", isOn: $mitmDecryptUntrusted)
                    .disabled(!settingsStore.mitmAvailable)
                    .onChange(of: mitmDecryptUntrusted) { _, _ in settingsStore.save() }
            }
            if let message = settingsStore.mitmStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("选项")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settingsStore.refreshMitmStatus()
            await checkTrust()
        }
        // FlClash mitm.dart:53-73: re-check trust when the app
        // comes back from iOS Settings (the user may just have
        // installed / trusted the CA there). Only re-runs when a CA
        // is present and the tunnel is running: the auto-check stays
        // tunnel-gated on purpose (a VPN-off check would boot the
        // in-app core on every foreground), while the manual
        // "检测信任状态" button works VPN-off via AppCore (audit
        // B38). Either way a failed check must NOT overwrite a good
        // result with "无法检测".
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  !isCheckingTrust,
                  settingsStore.mitmAvailable,
                  settingsStore.mitmCertificate != nil,
                  settingsStore.client.mode == .live,
                  TunnelManager.shared.isRunning else { return }
            Task { await checkTrust() }
        }
    }

    /// The "CA 证书" section: CA details, install / export /
    /// regenerate / delete (with their nested confirm alerts) and
    /// the upstream engine-capability note, plus the trusted
    /// server-certificate fingerprint field (Q8-kept). Extracted so
    /// the main `body` stays small enough for the type checker.
    @ViewBuilder
    private var caCertificateSection: some View {
        Section("CA 证书") {
            if settingsStore.mitmAvailable, let info = settingsStore.mitmCertificate {
                HStack(spacing: 12) {
                    // The video's CA icon is a green certificate
                    // with a ribbon seal; SF has no equivalent —
                    // checkmark.seal is the closest honest
                    // approximation.
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.subject)
                            .font(.footnote.weight(.semibold))
                        Text(trustStatusText)
                            .font(.caption)
                            .foregroundStyle(trustResult?.isReady == true ? .green : .secondary)
                    }
                    Spacer()
                }
                labeled("指纹", info.fingerprint)
                labeled("有效期自", info.notBefore)
                labeled("有效期至", info.notAfter)
                // Primary entry: the system install flow. The
                // app builds a .mobileconfig with the CA and
                // hands it to iOS, which prompts the install —
                // the app itself cannot install a system CA.
                Button {
                    installProfile()
                } label: {
                    Label("安装描述文件（去 Safari 安装）", systemImage: "arrow.down.doc.fill")
                }
                .disabled(isInstallingProfile)
                if isInstallingProfile {
                    ProgressView()
                }
                if let installHint {
                    Text(installHint)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                if let installMessage {
                    Text(installMessage)
                        .font(.footnote)
                        .foregroundStyle(installFailed ? Color.red : Color.secondary)
                }
                // CA 证书是解密流量的信任根：导出前先确认，
                // 别随手发出去。
                Button("导出 CA 证书（PEM）") {
                    showExportCAConfirm = true
                }
                .alert("导出 CA 证书？", isPresented: $showExportCAConfirm) {
                    Button("导出") { exportCA(pem: info.pem) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("CA 证书是解密流量的信任根，请只导出到自己的设备上使用。")
                }
                .alert("导出 CA 证书", isPresented: $showCAExportAlert) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(caExportMessage ?? "CA 证书已保存。")
                }
            } else {
                Text(settingsStore.mitmStatusMessage ?? "尚未读取 CA 状态")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("生成 CA 证书") {
                Task {
                    if await settingsStore.ensureMitmCertificate() {
                        installHint = "CA 已生成：下一步点「安装描述文件」，按系统提示装好，再去「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任。"
                    }
                }
            }
            // FlClash mitm.dart:253-340 _regenerate: confirm,
            // then generate a new CA. The old CA stays installed
            // in iOS Settings until the user removes it — the
            // note after regenerating says so.
            Button("重新生成 CA 证书", role: .destructive) {
                showRegenerateConfirm = true
            }
            .disabled(!settingsStore.mitmAvailable || settingsStore.mitmCertificate == nil)
            .alert("重新生成 CA 证书吗？", isPresented: $showRegenerateConfirm) {
                Button("重新生成", role: .destructive) {
                    Task {
                        // Only claim a new CA when generation
                        // actually succeeded (Item C rule 2).
                        if await settingsStore.ensureMitmCertificate() {
                            regenerateNote = "已生成新的 CA 证书。旧 CA 还留在 iPhone「设置 → 通用 → VPN 与设备管理」里，请先删掉旧的，再安装并完全信任新的 CA，否则 HTTPS 解密会失败。"
                            await checkTrust()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("旧 CA 会失效，所有用旧 CA 解密过的配置都要换新 CA。生成后需要重新安装并信任新 CA。")
            }
            // FlClash mitm.dart:125-150 (_remove): tapping the
            // certificate offers deletion with a confirm; the
            // installed profile must also be removed by hand in
            // iOS Settings. The core has no remove-CA RPC, so this
            // deletes the CA files from both homes (the proven
            // AppCore.deleteOldCAFiles path) and clears the
            // stored fingerprint / certificate state.
            Button("删除 CA 证书", role: .destructive) {
                showDeleteCAConfirm = true
            }
            .disabled(!settingsStore.mitmAvailable || settingsStore.mitmCertificate == nil)
            .alert("删除 CA 证书吗？", isPresented: $showDeleteCAConfirm) {
                Button("删除", role: .destructive) { deleteCA() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后，MITM 将无法解密 HTTPS，直到重新生成 CA 并安装信任。已装在 iPhone 里的旧描述文件也要手动删除（设置 → 通用 → VPN 与设备管理）。")
            }
            if let regenerateNote {
                Text(regenerateNote)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            // Upstream mitm.dart:441-448 (mitmEngineCompatibility):
            // what the MITM engine does and does not do.
            Text("支持指定域名的 HTTPS 解密、URL 跳转/拦截、请求头和正文重写、本地响应、请求/响应脚本、$httpClient、$task.fetch、计时器与持久存储。脚本有较短的运行时间和大小限制。暂不支持定时/事件脚本、二进制/完整头脚本模式，超大正文原样传输。模块为部分兼容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // v0.2.68 (MuYu): the trusted-server-certificate
            // fingerprint input — the 选项 page (this page) is
            // where it lives now (merged from the certificate
            // page, v0.2.143).
            TextField("受信任的服务器证书指纹（可选）", text: $settingsStore.mitmTrustedFingerprint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: settingsStore.mitmTrustedFingerprint) { _, _ in settingsStore.save() }
            Text("填入某个服务器证书的 SHA-256 指纹后，只信任该指纹的证书（解密 TLS 随之开启）；留空则用本应用 CA 的指纹。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// FlClash IOSMitmTrustStore.check, in-process: the core signs
    /// a leaf for the check host (mitm.issueCertificate) and the
    /// leaf is evaluated against the system trust store. No CA, no
    /// live core, or a failed issuance means "cannot check", not
    /// "untrusted" — those are reported separately.
    ///
    /// Tunnel off: the leaf is issued by the in-app core
    /// (AppCore.mitmIssueCertificate, audit B38) — the manual
    /// "检测信任状态" button works with the VPN off. The
    /// scenePhase auto-check above stays tunnel-gated on purpose:
    /// booting the in-app core on every foreground just to check
    /// trust would be slow. A failed VPN-off check never overwrites
    /// a previous good ("已受信任") result.
    private func checkTrust() async {
        guard settingsStore.client.mode == .live else {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：示例模式没有真实核心")
            return
        }
        guard settingsStore.mitmCertificate != nil else {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：尚未生成 CA 证书")
            return
        }
        isCheckingTrust = true
        defer { isCheckingTrust = false }
        // A failed check never overwrites a previous good result.
        if let checked = await mitmTrustCheckResult(settingsStore: settingsStore) {
            trustResult = checked
        } else if trustResult?.isReady != true {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：应用内核心签发叶证书失败")
        }
    }

    /// System install flow: build a .mobileconfig with the CA and
    /// hand it to iOS, which prompts the user to install the
    /// profile. A success here only means iOS accepted the open —
    /// the app cannot observe whether the user finished installing,
    /// so the message says what to do next instead of claiming the
    /// CA is installed. A failure is reported honestly with the
    /// PEM-share fallback.
    private func installProfile() {
        guard let pem = settingsStore.mitmCertificate?.pem else { return }
        isInstallingProfile = true
        installMessage = nil
        installFailed = false
        MobileConfigInstaller.install(caPEM: pem) { result in
            isInstallingProfile = false
            switch result {
            case .success:
                installHint = nil
                installFailed = false
                installMessage = "已交给系统打开安装页面：按提示装好描述文件，然后去「设置 → 通用 → 关于本机 → 证书信任设置」里打开 FlClash CA 的完全信任，再回来点「检测信任状态」确认。"
            case .failure(let error):
                installFailed = true
                installMessage = "打不开安装页面：\(error.localizedDescription)。可以改用下面的「导出 CA 证书（PEM）」把证书发到电脑上安装。"
            }
        }
    }

    /// Upstream _export (mitm.dart:233): writes the PEM file to
    /// disk and shows an exportSuccess banner — no share sheet.
    /// Documents is visible in the Files app.
    private func exportCA(pem: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FlClash CA.crt")
        guard let url else { return }
        do {
            try pem.write(to: url, atomically: true, encoding: .utf8)
            caExportMessage = "CA 证书已保存到「文件」：FlClash CA.crt"
            showCAExportAlert = true
        } catch {
            installFailed = true
            installMessage = "导出 CA 证书失败：\(error.localizedDescription)"
        }
    }

    /// Deletes the CA (upstream mitm.dart:125-150 _remove). The
    /// core has no remove-CA RPC, so this deletes the CA files
    /// from both homes (the proven AppCore.deleteOldCAFiles path)
    /// and clears the stored fingerprint / certificate state.
    /// No refreshMitmStatus here on purpose: the core caches the
    /// CA in memory (authority.current), so a refresh would report
    /// the deleted CA as still present until the core restarts.
    /// The files are gone; the next tunnel / app restart reports
    /// no CA, and a running tunnel keeps using the in-memory old
    /// CA until it restarts — the message says so.
    private func deleteCA() {
        let deletion = AppCore.deleteOldCAFiles()
        settingsStore.mitmCertificate = nil
        settingsStore.mitmCaFingerprint = ""
        settingsStore.mitmIssuedPem = nil
        settingsStore.save()
        if deletion.hasFailures {
            settingsStore.mitmStatusMessage = "CA 证书删除失败：\(deletion.failures.joined(separator: "；"))，请重试"
        } else if deletion.deleted.isEmpty {
            settingsStore.mitmStatusMessage = "本机没有可删除的 CA 证书文件"
        } else {
            settingsStore.mitmStatusMessage = "CA 证书已删除。正在运行的隧道仍会使用内存中的旧 CA，直到重启；重启后请先生成新 CA，并在「设置 → 通用 → VPN 与设备管理」里删掉旧描述文件、重新安装并完全信任新 CA，否则 HTTPS 解密会失败。"
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Restarts the tunnel (stop, then start) so MITM changes
    /// take effect — same action as the restart tip elsewhere.
    private func restartVpn() async {
        isRestartingVpn = true
        defer { isRestartingVpn = false }
        restartMessage = nil
        await TunnelManager.shared.stop()
        do {
            try await TunnelManager.shared.start()
            restartMessage = "隧道已重启，MITM 改动已生效。"
        } catch {
            restartMessage = "重启隧道失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Shared MITM enable toggle (FlClash MitmEnableItem, mitm.dart:538-581)
// Enabling MITM asks for confirmation with mitmEnableTip, and
// auto-generates a CA when none exists; disabling needs no
// confirm. Used by the Advanced Config MITM card (the merged
// 选项 page, v0.2.143, does not have an enable toggle — upstream
// keeps it in the Advanced Config MITM section).
//
// The confirm reads the live CA first: mitmCertificate is only
// populated when a MITM page refreshed it, and generating over an
// installed-but-unread CA would destroy it (ensureMitmCertificate
// deletes the old CA before regenerating).
struct MitmEnableToggle: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var showEnableConfirm = false
    var onEnabled: (() -> Void)? = nil

    var body: some View {
        Toggle("HTTPS 解密", isOn: Binding(
            get: { settingsStore.mitmEnabled },
            set: { on in
                if on {
                    showEnableConfirm = true
                } else {
                    settingsStore.mitmEnabled = false
                    settingsStore.save()
                }
            }
        ))
        .alert("HTTPS 解密", isPresented: $showEnableConfirm) {
            Button("开启") {
                Task {
                    await settingsStore.refreshMitmStatus()
                    if settingsStore.mitmCertificate == nil {
                        guard await settingsStore.ensureMitmCertificate() else { return }
                    }
                    settingsStore.mitmEnabled = true
                    settingsStore.save()
                    onEnabled?()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，FlClash 能读取发往被解密主机的全部内容，包括 Cookie 和密码。请只为需要改写的主机开启。")
        }
    }
}
