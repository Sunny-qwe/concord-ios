import Foundation
import Combine

// MARK: - Settings store (FlClash: Tools -> General / TUN / DNS / MITM / Network)
// FlClash's config pages map to Concord config.general (read) and
// config.patch (write). The fields below mirror the Clash/Concord
// general config: mode, log level, ports, allow LAN, IPv6, sniffing,
// TUN, DNS and MITM.
//
// On iOS, TUN and MITM are special:
//   - TUN is provided by the PacketTunnel extension, not by the core's
//     own TUN device (see TUN_INVESTIGATION.md). The TUN settings here
//     are the extension's parameters (stack, MTU, DNS): save() writes
//     them to the shared tunnel.json, which the extension reads for
//     tun.start and the tunnel interface settings.
//   - MITM needs the `mitm` capability (core.capabilities
//     features.mitm). The enable/hostname/decrypt-TLS choices are
//     written to the shared mitm.json; the extension merges them into
//     config.apply's overlay (config.patch has no mitm field, and the
//     app does not rewrite the user's profile YAML). The local CA must
//     be installed in the iOS trust store by the user in Settings —
//     there is no API for an app to install a trusted CA.

enum OutboundMode: String, CaseIterable, Identifiable {
    case rule = "rule"
    case global = "global"
    case direct = "direct"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rule: return "规则模式"
        case .global: return "全局模式"
        case .direct: return "直连模式"
        }
    }
}

enum LogLevel: String, CaseIterable, Identifiable {
    case debug, info, warning, error, silent
    var id: String { rawValue }
}

final class SettingsStore: ObservableObject {
    // General (config.general)
    @Published var mode: OutboundMode = .rule
    @Published var logLevel: LogLevel = .info
    @Published var mixedPort: Int = 7890
    @Published var socksPort: Int = 7891
    @Published var allowLan: Bool = false
    @Published var ipv6: Bool = true
    @Published var tcpConcurrent: Bool = true
    @Published var unifiedDelay: Bool = false
    @Published var sniffing: Bool = true
    @Published var globalUa: String = ""
    @Published var delayTestTimeout: Int = 5000

    // TUN (extension parameters, passed to tun.start)
    @Published var tunEnabled: Bool = true
    @Published var tunStack: String = "gvisor"
    @Published var tunMtu: Int = 1500
    @Published var tunDns: String = "223.5.5.5, 8.8.8.8"

    // DNS
    @Published var dnsEnabled: Bool = true
    @Published var dnsNameserver: String = "https://dns.alidns.com/dns-query"
    @Published var dnsFakeIpEnabled: Bool = true
    @Published var dnsFakeIpRange: String = "198.18.0.1/16"

    // MITM — live when the core reports features.mitm (see
    // refreshMitmStatus). Enable/hostnames/decrypt-TLS are written to
    // the shared mitm.json on save(); the extension merges them into
    // config.apply's overlay. The CA itself lives in the core; the app
    // only sees its info / PEM over RPC.
    @Published var mitmEnabled: Bool = false
    @Published var mitmAvailable: Bool = false
    @Published var mitmHostnames: String = ""
    @Published var mitmDecryptTls: Bool = true
    @Published var mitmCaFingerprint: String = ""
    @Published var mitmCertificate: ConcordCertificateInfo?
    @Published var mitmStatusMessage: String?
    @Published var mitmIssues: [String] = []
    @Published var mitmIssuedPem: String?
    @Published var generalApplyMessage: String?
    @Published var dnsApplyMessage: String?
    @Published var capabilities: ConcordCapabilities?
    @Published var developerInfoMessage: String?

    /// The MITM config as the core expects it (RawConfig keys, kebab-case).
    var mitmConfig: MitmConfig {
        MitmConfig(
            enable: mitmEnabled,
            hostname: mitmHostnames.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            skipServerCertVerify: false,
            decryptTls: mitmDecryptTls,
            caFingerprint: mitmCaFingerprint,
            h2: false
        )
    }

    // App
    @Published var autoUpdateProfiles: Bool = true
    @Published var developerMode: Bool = false

    let client: ConcordClient
    private let storageKey = "ConcordiOS.settings.v1"
    private var autosaveCancellable: AnyCancellable?

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
        // Autosave: every toggle / field change persists to UserDefaults
        // and rewrites the shared files the extension reads. Before this
        // only a handful of controls saved on change — most settings
        // (ports, sniffing, DNS, TUN stack/MTU, auto-update, developer
        // mode, …) were silently lost on restart. objectWillChange fires
        // before the change lands, so the save is deferred to the next
        // main-actor turn, when the new values are in place. save()
        // itself mutates no @Published property, so this cannot loop.
        autosaveCancellable = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.save() }
        }
    }

    // MARK: Persistence (UserDefaults; the core reads these via config.patch
    // once the live transport is connected)

    private struct Saved: Codable {
        var mode: String
        var logLevel: String
        var mixedPort: Int
        var socksPort: Int
        var allowLan: Bool
        var ipv6: Bool
        var tcpConcurrent: Bool
        var unifiedDelay: Bool
        var sniffing: Bool
        var globalUa: String
        var delayTestTimeout: Int
        var tunEnabled: Bool
        var tunStack: String
        var tunMtu: Int
        var tunDns: String
        var dnsEnabled: Bool
        var dnsNameserver: String
        var dnsFakeIpEnabled: Bool
        var dnsFakeIpRange: String
        var autoUpdateProfiles: Bool
        var developerMode: Bool
        var mitmEnabled: Bool
        var mitmHostnames: String
        var mitmDecryptTls: Bool
        var mitmCaFingerprint: String

        // The MITM fields are new: decode them leniently so settings
        // saved before they existed still load.
        init(mode: String, logLevel: String, mixedPort: Int, socksPort: Int, allowLan: Bool, ipv6: Bool, tcpConcurrent: Bool, unifiedDelay: Bool, sniffing: Bool, globalUa: String, delayTestTimeout: Int, tunEnabled: Bool, tunStack: String, tunMtu: Int, tunDns: String, dnsEnabled: Bool, dnsNameserver: String, dnsFakeIpEnabled: Bool, dnsFakeIpRange: String, autoUpdateProfiles: Bool, developerMode: Bool, mitmEnabled: Bool, mitmHostnames: String, mitmDecryptTls: Bool, mitmCaFingerprint: String) {
            self.mode = mode
            self.logLevel = logLevel
            self.mixedPort = mixedPort
            self.socksPort = socksPort
            self.allowLan = allowLan
            self.ipv6 = ipv6
            self.tcpConcurrent = tcpConcurrent
            self.unifiedDelay = unifiedDelay
            self.sniffing = sniffing
            self.globalUa = globalUa
            self.delayTestTimeout = delayTestTimeout
            self.tunEnabled = tunEnabled
            self.tunStack = tunStack
            self.tunMtu = tunMtu
            self.tunDns = tunDns
            self.dnsEnabled = dnsEnabled
            self.dnsNameserver = dnsNameserver
            self.dnsFakeIpEnabled = dnsFakeIpEnabled
            self.dnsFakeIpRange = dnsFakeIpRange
            self.autoUpdateProfiles = autoUpdateProfiles
            self.developerMode = developerMode
            self.mitmEnabled = mitmEnabled
            self.mitmHostnames = mitmHostnames
            self.mitmDecryptTls = mitmDecryptTls
            self.mitmCaFingerprint = mitmCaFingerprint
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decode(String.self, forKey: .mode)
            logLevel = try c.decode(String.self, forKey: .logLevel)
            mixedPort = try c.decode(Int.self, forKey: .mixedPort)
            socksPort = try c.decode(Int.self, forKey: .socksPort)
            allowLan = try c.decode(Bool.self, forKey: .allowLan)
            ipv6 = try c.decode(Bool.self, forKey: .ipv6)
            tcpConcurrent = try c.decode(Bool.self, forKey: .tcpConcurrent)
            unifiedDelay = try c.decode(Bool.self, forKey: .unifiedDelay)
            sniffing = try c.decode(Bool.self, forKey: .sniffing)
            globalUa = try c.decode(String.self, forKey: .globalUa)
            delayTestTimeout = try c.decode(Int.self, forKey: .delayTestTimeout)
            tunEnabled = try c.decode(Bool.self, forKey: .tunEnabled)
            tunStack = try c.decode(String.self, forKey: .tunStack)
            tunMtu = try c.decode(Int.self, forKey: .tunMtu)
            tunDns = try c.decode(String.self, forKey: .tunDns)
            dnsEnabled = try c.decode(Bool.self, forKey: .dnsEnabled)
            dnsNameserver = try c.decode(String.self, forKey: .dnsNameserver)
            dnsFakeIpEnabled = try c.decode(Bool.self, forKey: .dnsFakeIpEnabled)
            dnsFakeIpRange = try c.decode(String.self, forKey: .dnsFakeIpRange)
            autoUpdateProfiles = try c.decode(Bool.self, forKey: .autoUpdateProfiles)
            developerMode = try c.decode(Bool.self, forKey: .developerMode)
            mitmEnabled = try c.decodeIfPresent(Bool.self, forKey: .mitmEnabled) ?? false
            mitmHostnames = try c.decodeIfPresent(String.self, forKey: .mitmHostnames) ?? ""
            mitmDecryptTls = try c.decodeIfPresent(Bool.self, forKey: .mitmDecryptTls) ?? true
            mitmCaFingerprint = try c.decodeIfPresent(String.self, forKey: .mitmCaFingerprint) ?? ""
        }
    }

    func save() {
        let saved = Saved(mode: mode.rawValue, logLevel: logLevel.rawValue, mixedPort: mixedPort, socksPort: socksPort, allowLan: allowLan, ipv6: ipv6, tcpConcurrent: tcpConcurrent, unifiedDelay: unifiedDelay, sniffing: sniffing, globalUa: globalUa, delayTestTimeout: delayTestTimeout, tunEnabled: tunEnabled, tunStack: tunStack, tunMtu: tunMtu, tunDns: tunDns, dnsEnabled: dnsEnabled, dnsNameserver: dnsNameserver, dnsFakeIpEnabled: dnsFakeIpEnabled, dnsFakeIpRange: dnsFakeIpRange, autoUpdateProfiles: autoUpdateProfiles, developerMode: developerMode, mitmEnabled: mitmEnabled, mitmHostnames: mitmHostnames, mitmDecryptTls: mitmDecryptTls, mitmCaFingerprint: mitmCaFingerprint)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        saveSharedFiles()
    }

    /// Writes the files the PacketTunnel extension reads:
    /// tunnel.json (tun.start + interface settings), mitm.json
    /// (merged into config.apply's overlay), dns.json (ditto) and
    /// general.json (patched into the core at tunnel start via
    /// config.patch, so saved general settings take effect on the next
    /// VPN start even without tapping "apply"). Silently skipped when
    /// the App Group container is unavailable.
    private func saveSharedFiles() {
        let dnsServers = tunDns.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tunnel: [String: Any] = [
            "enabled": tunEnabled,
            "stack": tunStack,
            "mtu": tunMtu,
            "dns": dnsServers.isEmpty ? ["223.5.5.5", "8.8.8.8"] : dnsServers,
            "ipv6": ipv6,
        ]
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.tunnelSettingsFileName),
           let data = try? JSONSerialization.data(withJSONObject: tunnel) {
            try? data.write(to: url, options: .atomic)
        }
        // mitm.json uses the core's RawConfig keys verbatim, so the
        // extension can pass it as the "mitm" overlay value unchanged.
        let mitm: [String: Any] = [
            "enable": mitmEnabled,
            "hostname": mitmConfig.hostname,
            "decrypt-tls": mitmDecryptTls,
            "ca-fingerprint": mitmCaFingerprint,
        ]
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.mitmFileName),
           let data = try? JSONSerialization.data(withJSONObject: mitm) {
            try? data.write(to: url, options: .atomic)
        }
        // dns.json likewise: the core's DnsConfig keys are kebab-case
        // ("enhanced-mode", "fake-ip-range" — upstream
        // crates/config/src/dns.rs), so the extension passes it as the
        // "dns" overlay value unchanged. Keys are only written when
        // they carry a usable value, so an empty nameserver field or
        // an invalid fake-ip-range never overrides the profile's DNS
        // with something broken.
        var dns: [String: Any] = [
            "enable": dnsEnabled,
            "enhanced-mode": dnsFakeIpEnabled ? "fake-ip" : "normal",
            "ipv6": ipv6,
        ]
        let nameserver = dnsNameserver.trimmingCharacters(in: .whitespaces)
        if !nameserver.isEmpty {
            dns["nameserver"] = [nameserver]
        }
        let fakeIpRange = dnsFakeIpRange.trimmingCharacters(in: .whitespaces)
        if Self.isValidIPv4CIDR(fakeIpRange) {
            dns["fake-ip-range"] = fakeIpRange
        }
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.dnsFileName),
           let data = try? JSONSerialization.data(withJSONObject: dns) {
            try? data.write(to: url, options: .atomic)
        }
        // general.json: the general settings in ConfigPatchParams wire
        // keys (snake_case), patched by the extension at tunnel start.
        let general: [String: Any] = [
            "mode": mode.rawValue,
            "log_level": logLevel.rawValue,
            "mixed_port": mixedPort,
            "allow_lan": allowLan,
            "ipv6": ipv6,
            "tcp_concurrent": tcpConcurrent,
            "unified_delay": unifiedDelay,
        ]
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.generalSettingsFileName),
           let data = try? JSONSerialization.data(withJSONObject: general) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Strict-enough check for "a.b.c.d/n" (Clash fake-ip-range form).
    static func isValidIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3
                && octet.allSatisfy(\.isNumber)
                && (Int(octet).map { (0...255).contains($0) } ?? false)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        mode = OutboundMode(rawValue: saved.mode) ?? .rule
        logLevel = LogLevel(rawValue: saved.logLevel) ?? .info
        mixedPort = saved.mixedPort
        socksPort = saved.socksPort
        allowLan = saved.allowLan
        ipv6 = saved.ipv6
        tcpConcurrent = saved.tcpConcurrent
        unifiedDelay = saved.unifiedDelay
        sniffing = saved.sniffing
        globalUa = saved.globalUa
        delayTestTimeout = saved.delayTestTimeout
        tunEnabled = saved.tunEnabled
        tunStack = saved.tunStack
        tunMtu = saved.tunMtu
        tunDns = saved.tunDns
        dnsEnabled = saved.dnsEnabled
        dnsNameserver = saved.dnsNameserver
        dnsFakeIpEnabled = saved.dnsFakeIpEnabled
        dnsFakeIpRange = saved.dnsFakeIpRange
        autoUpdateProfiles = saved.autoUpdateProfiles
        developerMode = saved.developerMode
        mitmEnabled = saved.mitmEnabled
        mitmHostnames = saved.mitmHostnames
        mitmDecryptTls = saved.mitmDecryptTls
        mitmCaFingerprint = saved.mitmCaFingerprint
    }

    /// Pull the general config from the core (config.general) into the UI.
    @MainActor
    func refreshFromCore() async {
        do {
            let general = try await client.configGeneral()
            if let value = general.mode, let m = OutboundMode(rawValue: value) { mode = m }
            if let value = general.logLevel, let level = LogLevel(rawValue: value) { logLevel = level }
            if let value = general.mixedPort { mixedPort = value }
            if let value = general.socksPort { socksPort = value }
            if let value = general.allowLan { allowLan = value }
            if let value = general.ipv6 { ipv6 = value }
            if let value = general.tcpConcurrent { tcpConcurrent = value }
            if let value = general.unifiedDelay { unifiedDelay = value }
            if let value = general.sniffing { sniffing = value }
            if let value = general.globalUa { globalUa = value }
            save()
        } catch {
            // Keep the locally saved settings; the core is not linked yet.
        }
    }

    /// Push the general settings to the core (config.patch). Only the
    /// fields ConfigPatchParams accepts are sent (see ConcordClient);
    /// SOCKS port and sniffing, for example, are not patchable.
    /// When the tunnel is stopped the core is unreachable: the settings
    /// stay saved (locally + in the shared general.json, which the
    /// extension patches in at the next VPN start) and the message says
    /// so instead of reporting a failure.
    @MainActor
    func applyGeneralToCore() async {
        guard client.mode == .live else {
            generalApplyMessage = "示例模式：设置仅保存在本地，切换到实时核心后可应用到核心"
            return
        }
        guard TunnelManager.shared.isRunning else {
            generalApplyMessage = "已保存在本地：启动 VPN 后会自动应用到核心（也可现在点「从核心读取当前配置」确认）"
            return
        }
        do {
            try await client.configPatch(ConcordConfigPatchParams(
                mode: mode.rawValue, logLevel: logLevel.rawValue,
                mixedPort: mixedPort, allowLan: allowLan, ipv6: ipv6,
                tcpConcurrent: tcpConcurrent, unifiedDelay: unifiedDelay))
            generalApplyMessage = "通用设置已应用到核心"
        } catch {
            generalApplyMessage = "应用失败：\(error.localizedDescription)"
        }
    }

    /// Validates the DNS fields, saves them (dns.json, merged into
    /// config.apply's overlay by the extension) and re-applies the
    /// active config so the new DNS takes effect. When the tunnel is
    /// stopped the settings are still saved and take effect at the
    /// next VPN start.
    @MainActor
    func applyDnsSettings() async {
        let nameserver = dnsNameserver.trimmingCharacters(in: .whitespaces)
        let fakeIpRange = dnsFakeIpRange.trimmingCharacters(in: .whitespaces)
        if !fakeIpRange.isEmpty, !Self.isValidIPv4CIDR(fakeIpRange) {
            dnsApplyMessage = "Fake-IP 段格式不对，应为 a.b.c.d/n，例如 198.18.0.1/16"
            return
        }
        save()
        guard client.mode == .live else {
            dnsApplyMessage = "示例模式：DNS 设置已保存在本地，切换到实时核心并重启 VPN 后生效"
            return
        }
        guard TunnelManager.shared.isRunning else {
            dnsApplyMessage = "DNS 设置已保存，下次启动 VPN 时生效"
            return
        }
        do {
            _ = try await client.configApply(profilePath: nil)
            dnsApplyMessage = "DNS 设置已应用（立即生效）"
        } catch {
            dnsApplyMessage = "应用失败：\(error.localizedDescription)"
        }
    }

    /// Reads core.capabilities for the developer section (and refreshes
    /// the MITM availability flag as a side effect).
    @MainActor
    func refreshDeveloperInfo() async {
        do {
            capabilities = try await client.coreCapabilities()
            mitmAvailable = capabilities?.features.mitm ?? false
            developerInfoMessage = nil
        } catch {
            developerInfoMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    // MARK: MITM (mitm.* RPC; see ConcordClient.swift)

    /// Reads core.capabilities (features.mitm) and mitm.certificate
    /// into the UI. Call when the Settings page appears in live mode.
    @MainActor
    func refreshMitmStatus() async {
        do {
            let capabilities = try await client.coreCapabilities()
            mitmAvailable = capabilities.features.mitm
            guard mitmAvailable else {
                mitmStatusMessage = "核心未提供 MITM 能力（features.mitm 为 false）"
                return
            }
            let cert = try await client.mitmCertificate()
            mitmCertificate = cert.certificate
            if let info = cert.certificate {
                mitmCaFingerprint = info.fingerprint
                mitmStatusMessage = "CA 已就绪：\(info.subject)"
                save()
            } else {
                mitmStatusMessage = "核心尚未生成 CA 证书，请点「生成 CA 证书」"
            }
        } catch {
            mitmStatusMessage = "读取 MITM 状态失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func generateMitmCertificate() async {
        do {
            let cert = try await client.mitmGenerateCertificate()
            mitmCertificate = cert.certificate
            if let info = cert.certificate {
                mitmCaFingerprint = info.fingerprint
                mitmStatusMessage = "CA 已生成：\(info.subject)，指纹 \(info.fingerprint)"
                save()
            } else {
                mitmStatusMessage = "生成后仍无 CA 证书返回"
            }
        } catch {
            mitmStatusMessage = "生成 CA 失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func validateMitmConfig() async {
        do {
            let result = try await client.mitmValidate(config: mitmConfig)
            if result.issues.isEmpty {
                mitmIssues = []
                mitmStatusMessage = "MITM 配置校验通过"
            } else {
                mitmIssues = result.issues.flatMap { key, issues in
                    issues.map { "\(key)：\($0.message)" }
                }.sorted()
                mitmStatusMessage = "MITM 配置有 \(mitmIssues.count) 个问题"
            }
        } catch {
            mitmStatusMessage = "校验失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func issueMitmCertificate(host: String) async {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            mitmStatusMessage = "请先输入要签发证书的主机名"
            return
        }
        do {
            let pem = try await client.mitmIssueCertificate(host: host)
            mitmIssuedPem = pem.pem
            mitmStatusMessage = "已为 \(host) 签发叶证书（可用于验证信任链）"
        } catch {
            mitmStatusMessage = "签发失败：\(error.localizedDescription)"
        }
    }

    /// Persists the MITM choices (mitm.json, merged by the extension
    /// into config.apply's overlay) and re-applies the active profile
    /// so the new overlay takes effect. When the tunnel is stopped the
    /// settings are still saved and take effect at the next VPN start.
    @MainActor
    func applyMitmSettings() async {
        save()
        guard client.mode == .live else {
            mitmStatusMessage = "示例模式：MITM 设置已保存在本地，切换到实时核心并重启 VPN 后生效"
            return
        }
        guard TunnelManager.shared.isRunning else {
            mitmStatusMessage = "MITM 设置已保存，下次启动 VPN 时生效"
            return
        }
        do {
            _ = try await client.configApply(profilePath: nil)
            mitmStatusMessage = "MITM 设置已应用（立即生效）"
        } catch {
            mitmStatusMessage = "应用失败：\(error.localizedDescription)"
        }
    }
}
