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
//     are the extension's parameters (stack, MTU, DNS) and are passed
//     to tun.start via the extension.
//   - MITM needs the `mitm` capability (mitm.certificate /
//     generateCertificate / runScript ...). It is unverified on iOS and
//     is shown as unavailable in the UI until the core exposes it.

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
    @Published var tunMtu: Int = 9000
    @Published var tunDns: String = "223.5.5.5, 8.8.8.8"

    // DNS
    @Published var dnsEnabled: Bool = true
    @Published var dnsNameserver: String = "https://dns.alidns.com/dns-query"
    @Published var dnsFakeIpEnabled: Bool = true
    @Published var dnsFakeIpRange: String = "198.18.0.1/16"

    // MITM — not available on iOS yet (see header comment).
    @Published var mitmEnabled: Bool = false
    @Published var mitmAvailable: Bool = false

    // App
    @Published var autoUpdateProfiles: Bool = true
    @Published var developerMode: Bool = false

    let client: ConcordClient
    private let storageKey = "ConcordiOS.settings.v1"

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
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
    }

    func save() {
        let saved = Saved(mode: mode.rawValue, logLevel: logLevel.rawValue, mixedPort: mixedPort, socksPort: socksPort, allowLan: allowLan, ipv6: ipv6, tcpConcurrent: tcpConcurrent, unifiedDelay: unifiedDelay, sniffing: sniffing, globalUa: globalUa, delayTestTimeout: delayTestTimeout, tunEnabled: tunEnabled, tunStack: tunStack, tunMtu: tunMtu, tunDns: tunDns, dnsEnabled: dnsEnabled, dnsNameserver: dnsNameserver, dnsFakeIpEnabled: dnsFakeIpEnabled, dnsFakeIpRange: dnsFakeIpRange, autoUpdateProfiles: autoUpdateProfiles, developerMode: developerMode)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
}
