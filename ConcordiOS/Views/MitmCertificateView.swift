import SwiftUI
import Security

// MARK: - MITM certificate settings (FlClash: Tools -> MITM证书设置)
// The certificate side of MITM: CA status, generate, validate,
// issue a leaf certificate, share the CA PEM. The CA itself must
// be installed and trusted by the user in iOS Settings — the app
// cannot install a trusted CA. The exchange log lives in MitmView
// (reachable from 常规）.
//
// Trust check (FlClash: lib/common/mitm_trust.dart
// IOSMitmTrustStore.check): the core signs a leaf for
// mitm-check.concord.invalid and the leaf is evaluated against the
// system trust store with SecTrust. It only runs locally and never
// leaves the device: a pass means the CA is installed AND fully
// trusted; a fail means it is missing or its "fully trust" switch
// is still off in Settings → General → About → Certificate Trust
// Settings. The check cannot tell those two apart — iOS does not
// let an app list the system store — so the UI says so.

struct MitmCertificateView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var issueHost = ""
    @State private var trustResult: MitmTrustResult?
    @State private var isCheckingTrust = false
    @State private var showRegenerateConfirm = false
    @State private var regenerateNote: String?

    var body: some View {
        List {
            Section {
                Text("MITM 需要把 CA 证书装到系统里并信任：在「设置 → 通用 → VPN 与设备管理」安装描述文件，再到「关于本机 → 证书信任设置」里打开完全信任。应用本身装不了系统证书。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("CA 证书") {
                if settingsStore.mitmAvailable, let info = settingsStore.mitmCertificate {
                    labeled("主题", info.subject)
                    labeled("指纹", info.fingerprint)
                    labeled("有效期自", info.notBefore)
                    labeled("有效期至", info.notAfter)
                    ShareLink("分享 CA 证书（PEM）", item: info.pem)
                } else {
                    Text(settingsStore.mitmStatusMessage ?? "尚未读取 CA 状态")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("刷新 CA 状态") {
                    Task { await settingsStore.refreshMitmStatus() }
                }
                Button("生成 CA 证书") {
                    Task { _ = await generateCertificate() }
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
                            if await generateCertificate() {
                                regenerateNote = "已生成新的 CA 证书。旧 CA 还留在 iPhone「设置 → 通用 → VPN 与设备管理」里，请先删掉旧的，再安装并完全信任新的 CA，否则 HTTPS 解密会失败。"
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("旧 CA 会失效，所有用旧 CA 解密过的配置都要换新 CA。生成后需要重新安装并信任新 CA。")
                }
                if let regenerateNote {
                    Text(regenerateNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("信任检测") {
                Text("检测会请核心签发一张 mitm-check.concord.invalid 的叶证书，再用系统信任库验证它（只在本地验证，不联网）。通过 = CA 已安装且已完全信任；不通过 = CA 还没装，或装了但没在「证书信任设置」里打开完全信任——本应用无法区分这两种情况。")
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
            Section("MITM 配置") {
                Toggle("启用 MITM", isOn: $settingsStore.mitmEnabled)
                Toggle("解密 TLS", isOn: $settingsStore.mitmDecryptTls)
                NavigationLink {
                    MitmHostnameEditorView()
                } label: {
                    HStack {
                        Text("解密主机名")
                        Spacer()
                        Text(mitmHostnameSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button("校验 MITM 配置") {
                    Task { await settingsStore.validateMitmConfig() }
                }
                if !settingsStore.mitmIssues.isEmpty {
                    ForEach(settingsStore.mitmIssues, id: \.self) { issue in
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Button("保存并应用") {
                    Task { await settingsStore.applyMitmSettings() }
                }
            }
            Section("签发叶证书") {
                TextField("主机名，如 example.com", text: $issueHost)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("签发") {
                    Task { await settingsStore.issueMitmCertificate(host: issueHost) }
                }
                .disabled(issueHost.trimmingCharacters(in: .whitespaces).isEmpty)
                if let pem = settingsStore.mitmIssuedPem {
                    ShareLink("分享叶证书（PEM）", item: pem)
                }
            }
            if let message = settingsStore.mitmStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("MITM 证书设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settingsStore.refreshMitmStatus()
        }
        // FlClash mitm.dart:53-73: re-check trust when the app
        // comes back from iOS Settings (the user may just have
        // installed / trusted the CA there). Only re-runs when a CA
        // is present and the core is live; it never overwrites the
        // result with a "cannot check" while there is nothing to
        // check.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  !isCheckingTrust,
                  settingsStore.mitmAvailable,
                  settingsStore.mitmCertificate != nil,
                  settingsStore.client.mode == .live else { return }
            Task { await checkTrust() }
        }
    }

    private var mitmHostnameSummary: String {
        let count = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.count
        return count == 0 ? "未设置" : "\(count) 个域名"
    }

    /// Generates the CA. Tunnel running (or sample mode) → the
    /// tunnel core, exactly as before
    /// (SettingsStore.generateMitmCertificate). Tunnel off in live
    /// mode → the in-app core (AppCore, v0.2.35 Item C):
    /// ensureStarted boots the same core in-process, then
    /// mitm.generateCertificate runs there — the FlClash behaviour
    /// ("证书没有开启 VPN 也是可以生成证书"). A boot/generation
    /// failure writes the REAL AppCore error into
    /// mitmStatusMessage: never the old "VPN 隧道未运行" message,
    /// and never a success for a failed generation (the return
    /// value gates the regenerate note). Returns true only when
    /// the core actually returned a CA certificate.
    @MainActor
    private func generateCertificate() async -> Bool {
        guard settingsStore.client.mode == .live,
              !TunnelManager.shared.isRunning else {
            await settingsStore.generateMitmCertificate()
            return settingsStore.mitmStatusMessage?.hasPrefix("CA 已生成") == true
        }
        do {
            try await AppCore.shared.ensureStarted()
            let cert = try await AppCore.shared.mitmGenerateCertificate()
            settingsStore.mitmCertificate = cert.certificate
            if let info = cert.certificate {
                // A successful MITM call proves the in-app core has
                // the mitm capability, so the regenerate / trust-
                // check buttons (gated on mitmAvailable) become
                // usable without a tunnel-core refresh; the next
                // tunnel-core refresh re-reads the real value.
                settingsStore.mitmAvailable = true
                settingsStore.mitmCaFingerprint = info.fingerprint
                // The CA was generated in the app core's own home;
                // the tunnel core reads its CA from the App Group
                // container instead, so sync the files there — or
                // the next VPN start would generate a DIFFERENT CA
                // that does not match the one the user installs and
                // trusts. A failed / skipped sync is reported
                // honestly in the message; generation still counts
                // as a success (return true) because the CA itself
                // exists, but the message must NOT claim the tunnel
                // will use it.
                var message = "CA 已生成：\(info.subject)，指纹 \(info.fingerprint)"
                do {
                    switch try AppCore.shared.syncGeneratedCAToTunnel() {
                    case .synced:
                        message += "，已同步到隧道"
                    case .tunnelAlreadyHadCA:
                        message += "。注意：隧道里已有另一份 CA，未覆盖——下次启动 VPN 时隧道仍会使用旧 CA；如需隧道使用新 CA，请在 VPN 开启时重新生成一次"
                    case .nothingToSync:
                        message += "。注意：本机找不到刚生成的 CA 文件，未能同步到隧道——下次启动 VPN 时隧道可能会生成另一份 CA，请在 VPN 开启时重新生成一次"
                    }
                } catch {
                    message += "。注意：CA 未能同步到隧道（\(error.localizedDescription)）——下次启动 VPN 时隧道可能会生成另一份 CA，请在 VPN 开启时重新生成一次"
                }
                settingsStore.mitmStatusMessage = message
                settingsStore.save()
                return true
            }
            settingsStore.mitmStatusMessage = "生成后仍无 CA 证书返回"
            return false
        } catch {
            // The tunnel started between the guard above and the
            // boot: use the tunnel core instead of reporting a
            // delay-test-worded error.
            if case AppCoreError.tunnelRunning = error {
                await settingsStore.generateMitmCertificate()
                return settingsStore.mitmStatusMessage?.hasPrefix("CA 已生成") == true
            }
            settingsStore.mitmStatusMessage = "生成 CA 失败：\(error.localizedDescription)"
            return false
        }
    }

    /// FlClash IOSMitmTrustStore.check, in-process: the core signs
    /// a leaf for the check host (mitm.issueCertificate) and the
    /// leaf is evaluated against the system trust store. No CA, no
    /// live core, or a failed issuance means "cannot check", not
    /// "untrusted" — those are reported separately.
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
        do {
            let leafPem = try await settingsStore.client
                .mitmIssueCertificate(host: MitmTrustResult.checkHost).pem
            guard let leafData = Self.derData(fromPEM: leafPem),
                  let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "无法检测：核心签发的叶证书读不出来")
                return
            }
            var trust: SecTrust?
            let policy = SecPolicyCreateSSL(true, MitmTrustResult.checkHost as CFString)
            guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess,
                  let trust else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "无法检测：系统信任评估创建失败")
                return
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                trustResult = MitmTrustResult(
                    isReady: true,
                    message: "CA 已安装并受信任：HTTPS 可以解密")
            } else {
                trustResult = MitmTrustResult(
                    isReady: false,
                    message: "CA 未受信任：还没安装，或安装后没在「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任")
            }
        } catch {
            trustResult = MitmTrustResult(
                isReady: false,
                message: "无法检测：\(error.localizedDescription)")
        }
    }

    /// PEM text to DER bytes (strip the armor lines, base64-decode).
    private static func derData(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: body)
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
}

/// One trust-check outcome (FlClash MitmTrustCheck, iOS subset:
/// ready / untrusted — iOS cannot tell "not installed" from
/// "installed but not fully trusted", so both are "untrusted" with
/// the explanation in the message).
private struct MitmTrustResult {
    /// The leaf the core signs for the trust store to verify
    /// (FlClash mitmCheckHost, renamed for this app).
    static let checkHost = "mitm-check.concord.invalid"

    var isReady: Bool
    var message: String
}

// MARK: - MITM hostname list editor (FlClash: _MitmHostnameView,
// lib/views/config/mitm.dart:682-760)
// One hostname per row: in-place edit, swipe delete, drag reorder,
// per-line validation, plus a bulk quick-edit (one per line).
// Stored as the comma-joined string in SettingsStore.mitmHostnames,
// exactly as the MITM section read it before.

struct MitmHostnameEditorView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var hostnames: [String] = []
    @State private var newHostname = ""
    @State private var addError: String?
    @State private var showBulkEdit = false
    @State private var bulkText = ""

    private var invalidHostnames: [String] {
        hostnames.filter { !Self.isValidHostname($0) }
    }

    var body: some View {
        List {
            Section {
                Text("解密这些域名的 HTTPS 流量：支持 *.example.com 这样的通配符。改动后保存，下次启动 VPN 时生效（VPN 运行时在 常规 页点「应用 MITM 设置」立即生效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("解密主机名（\(hostnames.count) 个）") {
                if hostnames.isEmpty {
                    Text("还没有域名：MITM 开启后只解密这里列出的域名。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(hostnames.enumerated()), id: \.offset) { index, _ in
                    HostnameRowView(hostnames: $hostnames, index: index)
                }
                .onDelete { offsets in
                    hostnames.remove(atOffsets: offsets)
                    save()
                }
                .onMove { from, to in
                    hostnames.move(fromOffsets: from, toOffset: to)
                    save()
                }
                HStack {
                    TextField("添加域名", text: $newHostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        addHostname()
                    }
                    .disabled(newHostname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError {
                    Text(addError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !invalidHostnames.isEmpty {
                    Text("格式不对的域名（不会生效）：\(invalidHostnames.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("批量编辑（每行一个）") {
                    bulkText = hostnames.joined(separator: "\n")
                    showBulkEdit = true
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("解密主机名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .onAppear {
            hostnames = settingsStore.mitmHostnames
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        .onChange(of: hostnames) { _, _ in save() }
        .sheet(isPresented: $showBulkEdit) {
            NavigationStack {
                List {
                    Section {
                        TextEditor(text: $bulkText)
                            .frame(minHeight: 320)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        Text("每行一个域名，空行会被忽略。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("保存") {
                            hostnames = bulkText
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            save()
                            showBulkEdit = false
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .navigationTitle("批量编辑主机名")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消") { showBulkEdit = false }
                    }
                }
            }
        }
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

    private func save() {
        settingsStore.mitmHostnames = hostnames.joined(separator: ", ")
        settingsStore.save()
    }

    /// A hostname, optionally with a "*." wildcard prefix.
    static func isValidHostname(_ value: String) -> Bool {
        var host = value
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
private struct HostnameRowView: View {
    @Binding var hostnames: [String]
    let index: Int

    var body: some View {
        HStack {
            TextField("域名，如 *.example.com", text: Binding(
                get: { hostnames[index] },
                set: { hostnames[index] = $0 }
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
