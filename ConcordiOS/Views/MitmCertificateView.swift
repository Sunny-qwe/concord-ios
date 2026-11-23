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
    @State private var showShareCAConfirm = false
    @State private var showCAShareSheet = false
    @State private var isInstallingProfile = false
    @State private var installMessage: String?
    @State private var installFailed = false
    @State private var installHint: String?
    /// MuYu's restart tip (showMitmRestartTip): MITM was switched
    /// while the VPN runs — the change is re-applied live, but
    /// restarting the tunnel is the sure path.
    @State private var showRestartTip = false
    @State private var isRestartingVpn = false

    var body: some View {
        List {
            Section {
                Text("安装分两步：① 点下面的「安装描述文件」，系统会打开安装页面，按提示装好描述文件（装完后在「设置 → 通用 → VPN 与设备管理」里能看到它）；② 去「设置 → 通用 → 关于本机 → 证书信任设置」里打开 Concord CA 的完全信任。应用本身装不了系统证书，这两步都要手动完成。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("CA 证书") {
                if settingsStore.mitmAvailable, let info = settingsStore.mitmCertificate {
                    labeled("主题", info.subject)
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
                    // CA 证书是解密流量的信任根：分享前先确认，
                    // 别随手发出去。
                    Button("分享 CA 证书（PEM）") {
                        showShareCAConfirm = true
                    }
                    .alert("分享 CA 证书？", isPresented: $showShareCAConfirm) {
                        Button("分享") { showCAShareSheet = true }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("CA 证书是解密流量的信任根，请只分享给自己的设备。")
                    }
                    .sheet(isPresented: $showCAShareSheet) {
                        ShareSheet(items: [info.pem])
                    }
                } else {
                    Text(settingsStore.mitmStatusMessage ?? "尚未读取 CA 状态")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("刷新 CA 状态") {
                    Task { await settingsStore.refreshMitmStatus() }
                }
                Button("生成 CA 证书") {
                    Task {
                        if await generateCertificate() {
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
                // Upstream mitm.dart:441-448 (mitmEngineCompatibility):
                // what the MITM engine does and does not do.
                Text("支持指定域名的 HTTPS 解密、URL 跳转/拦截、请求头和正文重写、本地响应、请求/响应脚本、$httpClient、$task.fetch、计时器与持久存储。脚本有较短的运行时间和大小限制。暂不支持定时/事件脚本、二进制/完整头脚本模式，超大正文原样传输。模块为部分兼容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                if showRestartTip {
                    HStack {
                        Text("VPN 相关配置已改动，点击重启")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(isRestartingVpn ? "重启中…" : "重启 VPN") {
                            Task { await restartVpn() }
                        }
                        .font(.caption2)
                        .disabled(isRestartingVpn)
                        Button(action: { showRestartTip = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .accessibilityLabel("不再提示")
                    }
                }
                Toggle("启用 MITM", isOn: $settingsStore.mitmEnabled)
                    // Save on change, like the settings page's copy
                    // of this pair (audit B37): without this the
                    // switch silently reverted on leaving the page
                    // unless "保存并应用" was tapped.
                    .onChange(of: settingsStore.mitmEnabled) { _, _ in
                        settingsStore.save()
                        showRestartTipIfNeeded()
                    }
                Toggle("解密 TLS", isOn: $settingsStore.mitmDecryptTls)
                    .onChange(of: settingsStore.mitmDecryptTls) { _, _ in settingsStore.save() }
                // v0.2.68 (MuYu): the trusted-server-certificate
                // fingerprint input moved here from the 常规 MITM
                // 选项 section — the 选项 page (MitmOptionsView)
                // has no such row in the video.
                TextField("受信任的服务器证书指纹（可选）", text: $settingsStore.mitmTrustedFingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settingsStore.mitmTrustedFingerprint) { _, _ in settingsStore.save() }
                Text("填入某个服务器证书的 SHA-256 指纹后，只信任该指纹的证书（解密 TLS 随之开启）；留空则用本应用 CA 的指纹。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    MitmHostnameEditorView().concordNavBarBackground()
                } label: {
                    HStack {
                        Text("主机名")
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
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("MITM 证书设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settingsStore.refreshMitmStatus()
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

    private var mitmHostnameSummary: String {
        let count = settingsStore.mitmHostnames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.count
        return "\(count) 项"
    }

    /// MuYu showMitmRestartTip's gate, on iOS: only when the VPN
    /// is running and MITM is on (the tip's tap restarts it).
    private func showRestartTipIfNeeded() {
        if TunnelManager.shared.isRunning && settingsStore.mitmEnabled {
            showRestartTip = true
        }
    }

    /// Restarts the tunnel (stop, then start) and clears the tip.
    private func restartVpn() async {
        isRestartingVpn = true
        defer { isRestartingVpn = false }
        await TunnelManager.shared.stop()
        do {
            try await TunnelManager.shared.start()
            showRestartTip = false
        } catch {
            settingsStore.mitmStatusMessage = "重启 VPN 失败：\(error.localizedDescription)"
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
                installMessage = "已交给系统打开安装页面：按提示装好描述文件，然后去「设置 → 通用 → 关于本机 → 证书信任设置」里打开 Concord CA 的完全信任，再回来点「检测信任状态」确认。"
            case .failure(let error):
                installFailed = true
                installMessage = "打不开安装页面：\(error.localizedDescription)。可以改用下面的「分享 CA 证书（PEM）」把证书发到电脑上安装。"
            }
        }
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
        var deletion: AppCore.OldCADeletion?
        do {
            try await AppCore.shared.ensureStarted()
            // Fork ac90aebb: delete the old CA from BOTH homes
            // before regenerating. AFTER ensureStarted on purpose:
            // its healCAFiles would copy a surviving old CA from
            // one home back into a just-cleaned other home. The
            // core overwrites this home on its own; the deletion is
            // what lets the sync below fill the tunnel home with
            // the fresh CA instead of leaving the old one there.
            let result = AppCore.deleteOldCAFiles()
            deletion = result
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
                if let deletion, deletion.hasFailures {
                    message += "。注意：旧 CA 文件未能完全删除（\(deletion.failures.joined(separator: "；"))），隧道或应用内可能仍留有旧 CA，请重试或检查后重新生成"
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
            var message = "生成 CA 失败：\(error.localizedDescription)"
            if let deletion, !deletion.deleted.isEmpty {
                message += "（旧 CA 文件已先删除，重新生成一次即可恢复）"
            }
            settingsStore.mitmStatusMessage = message
            return false
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

/// Shared trust evaluation (FlClash IOSMitmTrustStore.check),
/// used by both MitmCertificateView and MitmOptionsView: issue a
/// leaf for the check host and evaluate it against the system
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
// per-line validation, plus a bulk quick-edit (one per line).
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
                    HostnameRowView(hostnames: $hostnames, index: index)
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
                    guard searchText.isEmpty else { return }
                    hostnames.move(fromOffsets: from, toOffset: to)
                    save()
                }
                if !invalidHostnames.isEmpty {
                    Text("格式不对的域名（不会生效）：\(invalidHostnames.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                // Ours-only extra (no equivalent in the video):
                // bulk edit stays reachable here.
                Section {
                    Button("批量编辑（每行一个）") {
                        bulkText = hostnames.joined(separator: "\n")
                        showBulkEdit = true
                    }
                }
            }
            // v0.2.68 (MuYu): the search is a BOTTOM floating pill,
            // not a top .searchable.
            bottomSearchPill
                .padding(.horizontal, 16)
                .padding(.bottom, ConcordTheme.tabBarClearance + 8)
        }
        // v0.2.66: bottom clearance for the floating tab bar on pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance + 56)
        .font(.footnote.weight(.semibold))
        .navigationTitle("主机名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newHostname = ""
                    addError = nil
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("添加主机名")
            }
        }
        .onAppear {
            hostnames = settingsStore.mitmHostnames
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        .onChange(of: hostnames) { _, _ in save() }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                List {
                    Section {
                        TextField("域名，如 *.example.com", text: $newHostname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let addError {
                            Text(addError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Text("以 - 开头表示排除该域名（不解密）。支持 *.example.com 这样的通配符。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("添加") {
                            addHostname()
                            if newHostname.isEmpty { showAddSheet = false }
                        }
                        .disabled(newHostname.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .font(.footnote.weight(.semibold))
                .navigationTitle("添加主机名")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消") { showAddSheet = false }
                    }
                }
            }
        }
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
                .font(.footnote.weight(.semibold))
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

    private var isExcluded: Bool { hostnames[index].hasPrefix("-") }

    private var displayName: String {
        isExcluded ? String(hostnames[index].dropFirst()) : hostnames[index]
    }

    var body: some View {
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

// MARK: - MITM options (MuYu 选项 page, v0.2.68)
// An independent page reached from 进阶配置 → MITM → 选项:
//   card 1: 抓包 status row (tap toggles) + 重启隧道 row
//   card 2: CA card (Concord CA, trust status, regenerate)
//   card 3: the four toggles in the video's order
// The video has no "解密 TLS" toggle and no trusted-fingerprint
// input here — 解密 TLS stays on the certificate page, and the
// fingerprint input moved to the certificate page too.
// Labels renamed to the video's wording: 跳过服务器证书验证
// (was 跳过服务端证书验证）, HTTP/2 (was 启用 HTTP/2（h2)),
// 本机未信任时也解密 (was 解密不受信任的证书）.
struct MitmOptionsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
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
    @State private var regenerateNote: String?

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
                        Text("Concord CA")
                            .font(.footnote.weight(.semibold))
                        Text(trustStatusText)
                            .font(.caption)
                            .foregroundStyle(trustResult?.isReady == true ? .green : .secondary)
                    }
                    Spacer()
                    if isCheckingTrust {
                        ProgressView()
                    } else {
                        Button("检测") {
                            Task { await checkTrust() }
                        }
                        .font(.caption)
                        .disabled(settingsStore.mitmCertificate == nil)
                    }
                }
                if let trustResult, !trustResult.isReady {
                    Text(trustResult.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("重新生成证书", role: .destructive) {
                    showRegenerateConfirm = true
                }
                .disabled(!settingsStore.mitmAvailable || settingsStore.mitmCertificate == nil)
                .alert("重新生成 CA 证书吗？", isPresented: $showRegenerateConfirm) {
                    Button("重新生成", role: .destructive) {
                        Task {
                            await settingsStore.generateMitmCertificate()
                            regenerateNote = "已重新生成 CA 证书。旧 CA 还留在 iPhone「设置 → 通用 → VPN 与设备管理」里，请先删掉旧的，再安装并完全信任新的 CA，否则 HTTPS 解密会失败。"
                            await checkTrust()
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
    }

    private func checkTrust() async {
        guard settingsStore.client.mode == .live,
              settingsStore.mitmCertificate != nil else { return }
        isCheckingTrust = true
        defer { isCheckingTrust = false }
        if let checked = await mitmTrustCheckResult(settingsStore: settingsStore) {
            trustResult = checked
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
