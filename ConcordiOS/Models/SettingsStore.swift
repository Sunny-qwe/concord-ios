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
    // TCP keep-alive (core GeneralConfig `keep-alive-idle` /
    // `keep-alive-interval` / `disable-keep-alive`, defaults 0/0/
    // false = the core's built-in 15 s idle). Written to
    // general-overlay.json by saveSharedFiles (ConfigPatchParams
    // has no keep-alive field, so general.json cannot carry them).
    @Published var keepAliveIdle: Int = 0
    @Published var keepAliveInterval: Int = 0
    @Published var disableKeepAlive: Bool = false
    @Published var globalUa: String = ""
    @Published var delayTestTimeout: Int = 8000

    // Local network (FlClash: Tools -> 常规 -> 本地网络设置,
    // iOS): CIDRs excluded from the tunnel routes, private-range
    // bypass and DNS hijacking. Written to tunnel.json by save();
    // the extension applies them when it sets up the interface.
    @Published var routeExcludeAddress: [String] = []
    @Published var bypassPrivateRoute: Bool = false
    @Published var dnsHijack: Bool = true
    /// FlClash network.dart VpnSystemProxyItem: the system-proxy
    /// switch (a NetworkSetting in FlClash). Stored here and written
    /// to tunnel.json ("system-proxy") for the extension's VPN
    /// setup; whether iOS honours it is unverified (the packet
    /// tunnel works through interface routes), so the toggle's
    /// footnote says so instead of promising an effect.
    @Published var systemProxy: Bool = false
    /// FlClash network.dart BypassDomainItem: domains that bypass
    /// the proxy. Written to tunnel.json ("bypass-domain") only
    /// while systemProxy is on (FlClash core.dart:247 passes
    /// `systemProxy ? bypassDomain : []` to the VPN setup); the
    /// list itself is kept here regardless, so turning the switch
    /// off does not lose it.
    @Published var bypassDomain: [String] = []
    // System VPN switches (NETunnelProviderProtocol, iOS-only):
    // include-all-networks routes ALL traffic through the tunnel;
    // the excludes keep local networks / APNs / cellular services /
    // device-to-device traffic out of it; enforce-routes forces the
    // tunnel routes even when the system would prefer another
    // interface. Defaults are the system defaults, so existing
    // behaviour does not change. Written to tunnel.json by save();
    // applied to the protocol in TunnelManager.prepare() and
    // armManagerForStart() (NE API, core-independent).
    @Published var includeAllNetworks: Bool = false
    @Published var excludeLocalNetworks: Bool = true
    @Published var excludeAPNs: Bool = true
    @Published var excludeCellularServices: Bool = true
    @Published var enforceRoutes: Bool = false
    @Published var excludeDeviceCommunication: Bool = true

    // Startup / requests (FlClash: Tools -> 常规): auto-run on
    // launch, close all connections on profile switch, verify
    // subscription certificates, auto-check for updates, and
    // whether the log page appears on the Tools page.
    @Published var autoRun: Bool = false
    @Published var autoCloseConnections: Bool = false
    /// FlClash general.dart:337 _connectionItems: only count proxy
    /// traffic in the traffic stats (FlClash passes it to
    /// getTraffic / getTotalTraffic). Stored here; the traffic feed
    /// itself (traffic.watch, ConcordClient/TrafficStore) takes no
    /// such parameter yet, so the switch only records the preference
    /// until that call is wired — the Settings footnote says so.
    @Published var onlyStatisticsProxy: Bool = false
    @Published var checkCertificate: Bool = true
    @Published var autoCheckUpdate: Bool = false
    @Published var openLogs: Bool = false
    /// The core's find-process mode (config.general, display-only:
    /// what the core currently reports, via refreshFromCore). The
    /// value the user picks lives in findProcessModeSetting below.
    /// NOTE: api.json's ConfigPatchParams HAS findProcessMode, so
    /// it IS patchable in principle — but our ConcordConfigPatchParams
    /// (ConcordClient.swift) has no such field yet, so the picked
    /// value travels via general-overlay.json instead.
    @Published var findProcessMode: String?
    /// The process-matching mode the user picked (SettingsView
    /// picker): "strict" (the core default — crates/config/src/
    /// general.rs), "always" or "off". Persisted in Saved and
    /// written to general-overlay.json as `find-process-mode`
    /// (see saveSharedFiles). The old always/off bool toggle
    /// forced "off" for everyone who never touched it, which
    /// disabled PROCESS-NAME / PROCESS-PATH rules (config B4).
    @Published var findProcessModeSetting: String = "strict"


    // TUN (extension parameters, passed to tun.start)
    @Published var tunEnabled: Bool = true
    @Published var tunStack: String = "gvisor"
    @Published var tunMtu: Int = 1500
    @Published var tunDns: String = "223.5.5.5, 8.8.8.8"

    // DNS
    @Published var dnsEnabled: Bool = true
    /// FlClash general.dart:360 _coreItems: append the system DNS
    /// servers to dns.nameserver at config build (FlClash
    /// task.dart:314). Implemented in saveSharedFiles: the system
    /// servers are read from /etc/resolv.conf (the same source
    /// ConnectionStore.systemDnsServers() uses for network.update)
    /// and appended to the nameserver list when this is on.
    @Published var appendSystemDns: Bool = false
    @Published var dnsNameserver: String = "https://dns.alidns.com/dns-query"
    @Published var dnsFakeIpEnabled: Bool = true
    @Published var dnsFakeIpRange: String = "198.18.0.1/16"
    /// DNS 用 IPv6 (core `dns.ipv6`, default false — FlClash
    /// Dns.ipv6, independent of the general `ipv6` switch which
    /// defaults true and also drives the tunnel IPv6 address +
    /// default route). Written to dns.json; the global switch is
    /// left alone (config B9).
    @Published var dnsIpv6: Bool = false
    // DNS completion (FlClash Dns model; upstream
    // crates/config/src/keys.rs dns_defaults). Lists are edited in
    // DnsSettingsView; the fake-IP toggle and the enhanced-mode
    // picker are kept in sync (fake-ip <=> enhanced-mode fake-ip).
    @Published var dnsListen: String = ""
    @Published var dnsPreferH3: Bool = false
    @Published var dnsUseHosts: Bool = true
    @Published var dnsUseSystemHosts: Bool = true
    @Published var dnsRespectRules: Bool = false
    @Published var dnsIpv6Timeout: Int = 100
    @Published var dnsCacheAlgorithm: String = "lru"
    @Published var dnsCacheMaxSize: Int = 4096
    @Published var dnsEnhancedMode: String = "fake-ip"
    @Published var dnsFakeIpRange6: String = ""
    @Published var dnsFakeIpFilter: [String] = ["dns.msftnsci.com", "www.msftnsci.com", "www.msftconnecttest.com"]
    @Published var dnsFakeIpFilterMode: String = "blacklist"
    @Published var dnsFakeIpTtl: Int = 1
    @Published var dnsDefaultNameserver: [String] = ["114.114.114.114", "223.5.5.5", "8.8.8.8", "1.0.0.1"]
    @Published var dnsNameserverPolicy: [String: String] = [:]
    @Published var dnsExtraNameservers: [String] = []
    @Published var dnsFallback: [String] = []
    @Published var dnsFallbackLazyQuery: Bool = false
    @Published var dnsProxyServerNameserver: [String] = []
    @Published var dnsProxyServerNameserverPolicy: [String: String] = [:]
    @Published var dnsDirectNameserver: [String] = []
    @Published var dnsDirectNameserverFollowPolicy: Bool = false
    @Published var dnsFallbackFilterGeoip: Bool = true
    @Published var dnsFallbackFilterGeoipCode: String = ""
    @Published var dnsFallbackFilterGeosite: [String] = []
    @Published var dnsFallbackFilterIpcidr: [String] = []
    @Published var dnsFallbackFilterDomain: [String] = []

    // Interface name (FlClash general.dart InterfaceNameMode):
    // follow = leave the profile's value alone, clear = force "",
    // custom = use interfaceName. Written to general-overlay.json
    // (config.patch cannot carry it).
    @Published var interfaceName: String = ""
    @Published var interfaceNameMode: String = "follow"

    // User-Agent list (FlClash user_agents.dart): the saved list;
    // globalUa stays the selected value ("" = default).
    @Published var userAgents: [String] = []

    // Local inbound authentication + external-controller secret
    // (FlClash general.dart AuthenticationItem /
    // ExternalControllerSecretItem). Stored in UserDefaults with the
    // rest of the settings — there is no Keychain helper in the app,
    // so the password is not hardware-protected; see GeneralAuthView.
    // Sent via config.patch (core ConfigPatchParams accepts secret,
    // authentication and externalController) and written to
    // general.json for the startup patch.
    @Published var authEnabled: Bool = false
    @Published var authUsername: String = ""
    @Published var authPassword: String = ""
    @Published var externalControllerSecret: String = ""
    @Published var externalControllerEnabled: Bool = false

    // MITM — live when the core reports features.mitm (see
    // refreshMitmStatus). Enable/hostnames/decrypt-TLS are written to
    // the shared mitm.json on save(); the extension merges them into
    // config.apply's overlay. The CA itself lives in the core; the app
    // only sees its info / PEM over RPC.
    @Published var mitmEnabled: Bool = false
    @Published var mitmAvailable: Bool = false
    @Published var mitmHostnames: String = ""
    @Published var mitmDecryptTls: Bool = true
    /// Skip verifying upstream servers' certificates (core
    /// `skip-server-cert-verify`). Off by default: with it on, a
    /// middlebox can forge a server certificate.
    @Published var mitmSkipServerCertVerify: Bool = false
    /// Block QUIC so clients fall back to decryptable TCP+TLS
    /// (core `auto-quic-block`, default true).
    @Published var mitmAutoQuicBlock: Bool = true
    /// A server certificate's SHA-256 fingerprint to trust instead
    /// of this app's CA (FlClash `trusted-fingerprint`). Empty
    /// means the app's own CA fingerprint. Setting one also turns
    /// TLS decryption on, as FlClash's coreJson does.
    @Published var mitmTrustedFingerprint: String = ""
    /// Save captured exchanges (mitm.exchanges). The core only
    /// captures while config.apply's `options.mitm_capture` is on;
    /// the switch is written to mitm.json's `capture` key for the
    /// extension to pass through (see the coordinator note).
    @Published var mitmCapture: Bool = false
    /// How many exchanges to keep (FlClash iOS options 16/32/64;
    /// the iOS core limit is 64 entries / 1 MB).
    @Published var mitmCaptureEntries: Int = 64
    @Published var mitmCaFingerprint: String = ""
    @Published var mitmCertificate: ConcordCertificateInfo?
    @Published var mitmStatusMessage: String?
    @Published var mitmIssues: [String] = []
    @Published var mitmIssuedPem: String?
    @Published var generalApplyMessage: String?
    @Published var dnsApplyMessage: String?
    @Published var capabilities: ConcordCapabilities?
    @Published var developerInfoMessage: String?
    /// MITM memory-pressure level (core.setPressure): 0 none, 1 stop
    /// scripts, 2 stop bodies, 3 relay-only. A transient diagnostic
    /// control, not persisted: the core only ever raises the level
    /// and lifts it itself after a hold.
    @Published var pressureLevel: Int = 0
    @Published var pressureMessage: String?
    @Published var crashMessage: String?
    /// The core's TUN state (config.general `tun`). Display-only: TUN
    /// is owned by the PacketTunnel extension, so the app never sends
    /// config.patch `tun`.
    @Published var tunState: ConcordTunState?
    @Published var tunStateMessage: String?

    /// The MITM config as the core expects it (RawConfig keys, kebab-case).
    /// A trusted fingerprint overrides the app CA's fingerprint and
    /// turns decryption on (FlClash MitmExt.coreJson); otherwise the
    /// app CA's fingerprint is used.
    /// `h2` and `decrypt-untrusted` live in UserDefaults (@AppStorage
    /// in SettingsView) — the SettingsView toggles write them there,
    /// and this computed property is the single reader, so the
    /// formula below and the shared mitm.json always agree.
    /// FlClash: 'decrypt-tls' = decryptUntrusted || trustedFingerprint
    /// != null (clash_config.dart:2322-2323); ours adds the local
    /// decrypt-TLS switch to the same OR.
    private var mitmH2: Bool { UserDefaults.standard.bool(forKey: "ConcordiOS.mitmH2") }
    private var mitmDecryptUntrusted: Bool { UserDefaults.standard.bool(forKey: "ConcordiOS.mitmDecryptUntrusted") }
    var mitmConfig: MitmConfig {
        let trusted = mitmTrustedFingerprint.trimmingCharacters(in: .whitespaces)
        return MitmConfig(
            enable: mitmEnabled,
            hostname: mitmHostnames.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            skipServerCertVerify: mitmSkipServerCertVerify,
            decryptTls: mitmDecryptTls || mitmDecryptUntrusted || !trusted.isEmpty,
            caFingerprint: trusted.isEmpty ? mitmCaFingerprint : trusted,
            h2: mitmH2,
            autoQuicBlock: mitmAutoQuicBlock,
            limits: mitmCapture ? MitmLimitsConfig(captureEntries: mitmCaptureEntries) : nil
        )
    }

    // App
    @Published var autoUpdateProfiles: Bool = true
    @Published var developerMode: Bool = false
    /// Mask the egress IP on the dashboard as "*****" (FlClash
    /// appSetting hideIp, models/config.dart:273, default false).
    @Published var hideIp: Bool = false

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
        var dnsIpv6: Bool
        var dnsListen: String
        var dnsPreferH3: Bool
        var dnsUseHosts: Bool
        var dnsUseSystemHosts: Bool
        var dnsRespectRules: Bool
        var dnsIpv6Timeout: Int
        var dnsCacheAlgorithm: String
        var dnsCacheMaxSize: Int
        var dnsEnhancedMode: String
        var dnsFakeIpRange6: String
        var dnsFakeIpFilter: [String]
        var dnsFakeIpFilterMode: String
        var dnsFakeIpTtl: Int
        var dnsDefaultNameserver: [String]
        var dnsNameserverPolicy: [String: String]
        var dnsExtraNameservers: [String]
        var dnsFallback: [String]
        var dnsFallbackLazyQuery: Bool
        var dnsProxyServerNameserver: [String]
        var dnsProxyServerNameserverPolicy: [String: String]
        var dnsDirectNameserver: [String]
        var dnsDirectNameserverFollowPolicy: Bool
        var dnsFallbackFilterGeoip: Bool
        var dnsFallbackFilterGeoipCode: String
        var dnsFallbackFilterGeosite: [String]
        var dnsFallbackFilterIpcidr: [String]
        var dnsFallbackFilterDomain: [String]
        var interfaceName: String
        var interfaceNameMode: String
        var userAgents: [String]
        var authEnabled: Bool
        var authUsername: String
        var authPassword: String
        var externalControllerSecret: String
        var externalControllerEnabled: Bool
        var autoUpdateProfiles: Bool
        var developerMode: Bool
        var mitmEnabled: Bool
        var mitmHostnames: String
        var mitmDecryptTls: Bool
        var mitmCaFingerprint: String
        var mitmSkipServerCertVerify: Bool
        var mitmAutoQuicBlock: Bool
        var mitmTrustedFingerprint: String
        var mitmCapture: Bool
        var mitmCaptureEntries: Int
        var autoRun: Bool
        var autoCloseConnections: Bool
        var checkCertificate: Bool
        var autoCheckUpdate: Bool
        var openLogs: Bool
        var routeExcludeAddress: [String]
        var bypassPrivateRoute: Bool
        var dnsHijack: Bool
        var hideIp: Bool
        var findProcessModeSetting: String
        var keepAliveIdle: Int
        var keepAliveInterval: Int
        var disableKeepAlive: Bool
        var includeAllNetworks: Bool
        var excludeLocalNetworks: Bool
        var excludeAPNs: Bool
        var excludeCellularServices: Bool
        var enforceRoutes: Bool
        var excludeDeviceCommunication: Bool
        var onlyStatisticsProxy: Bool
        var appendSystemDns: Bool
        var systemProxy: Bool
        var bypassDomain: [String]

        // The MITM fields are new: decode them leniently so settings
        // saved before they existed still load.
        init(mode: String, logLevel: String, mixedPort: Int, socksPort: Int, allowLan: Bool, ipv6: Bool, tcpConcurrent: Bool, unifiedDelay: Bool, sniffing: Bool, globalUa: String, delayTestTimeout: Int, tunEnabled: Bool, tunStack: String, tunMtu: Int, tunDns: String, dnsEnabled: Bool, dnsNameserver: String, dnsFakeIpEnabled: Bool, dnsFakeIpRange: String, autoUpdateProfiles: Bool, developerMode: Bool, mitmEnabled: Bool, mitmHostnames: String, mitmDecryptTls: Bool, mitmCaFingerprint: String, autoRun: Bool = false, autoCloseConnections: Bool = false, checkCertificate: Bool = true, autoCheckUpdate: Bool = false, openLogs: Bool = false, routeExcludeAddress: [String] = [], bypassPrivateRoute: Bool = false, dnsHijack: Bool = true, dnsListen: String = "", dnsPreferH3: Bool = false, dnsUseHosts: Bool = true, dnsUseSystemHosts: Bool = true, dnsRespectRules: Bool = false, dnsIpv6Timeout: Int = 100, dnsCacheAlgorithm: String = "lru", dnsCacheMaxSize: Int = 4096, dnsEnhancedMode: String = "fake-ip", dnsFakeIpRange6: String = "", dnsFakeIpFilter: [String] = ["dns.msftnsci.com", "www.msftnsci.com", "www.msftconnecttest.com"], dnsFakeIpFilterMode: String = "blacklist", dnsFakeIpTtl: Int = 1, dnsDefaultNameserver: [String] = ["114.114.114.114", "223.5.5.5", "8.8.8.8", "1.0.0.1"], dnsNameserverPolicy: [String: String] = [:], dnsExtraNameservers: [String] = [], dnsFallback: [String] = [], dnsFallbackLazyQuery: Bool = false, dnsProxyServerNameserver: [String] = [], dnsProxyServerNameserverPolicy: [String: String] = [:], dnsDirectNameserver: [String] = [], dnsDirectNameserverFollowPolicy: Bool = false, dnsFallbackFilterGeoip: Bool = true, dnsFallbackFilterGeoipCode: String = "", dnsFallbackFilterGeosite: [String] = [], dnsFallbackFilterIpcidr: [String] = [], dnsFallbackFilterDomain: [String] = [], interfaceName: String = "", interfaceNameMode: String = "follow", userAgents: [String] = [], authEnabled: Bool = false, authUsername: String = "", authPassword: String = "", externalControllerSecret: String = "", externalControllerEnabled: Bool = false, mitmSkipServerCertVerify: Bool = false, mitmAutoQuicBlock: Bool = true, mitmTrustedFingerprint: String = "", mitmCapture: Bool = false, mitmCaptureEntries: Int = 64, hideIp: Bool = false, dnsIpv6: Bool = false, findProcessModeSetting: String = "strict", keepAliveIdle: Int = 0, keepAliveInterval: Int = 0, disableKeepAlive: Bool = false, includeAllNetworks: Bool = false, excludeLocalNetworks: Bool = true, excludeAPNs: Bool = true, excludeCellularServices: Bool = true, enforceRoutes: Bool = false, excludeDeviceCommunication: Bool = true, onlyStatisticsProxy: Bool = false, appendSystemDns: Bool = false, systemProxy: Bool = false, bypassDomain: [String] = []) {
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
            self.mitmSkipServerCertVerify = mitmSkipServerCertVerify
            self.mitmAutoQuicBlock = mitmAutoQuicBlock
            self.mitmTrustedFingerprint = mitmTrustedFingerprint
            self.mitmCapture = mitmCapture
            self.mitmCaptureEntries = mitmCaptureEntries
            self.autoRun = autoRun
            self.autoCloseConnections = autoCloseConnections
            self.checkCertificate = checkCertificate
            self.autoCheckUpdate = autoCheckUpdate
            self.openLogs = openLogs
            self.routeExcludeAddress = routeExcludeAddress
            self.bypassPrivateRoute = bypassPrivateRoute
            self.dnsHijack = dnsHijack
            self.hideIp = hideIp
            self.dnsIpv6 = dnsIpv6
            self.findProcessModeSetting = findProcessModeSetting
            self.keepAliveIdle = keepAliveIdle
            self.keepAliveInterval = keepAliveInterval
            self.disableKeepAlive = disableKeepAlive
            self.includeAllNetworks = includeAllNetworks
            self.excludeLocalNetworks = excludeLocalNetworks
            self.excludeAPNs = excludeAPNs
            self.excludeCellularServices = excludeCellularServices
            self.enforceRoutes = enforceRoutes
            self.excludeDeviceCommunication = excludeDeviceCommunication
            self.onlyStatisticsProxy = onlyStatisticsProxy
            self.appendSystemDns = appendSystemDns
            self.systemProxy = systemProxy
            self.bypassDomain = bypassDomain
            self.dnsListen = dnsListen
            self.dnsPreferH3 = dnsPreferH3
            self.dnsUseHosts = dnsUseHosts
            self.dnsUseSystemHosts = dnsUseSystemHosts
            self.dnsRespectRules = dnsRespectRules
            self.dnsIpv6Timeout = dnsIpv6Timeout
            self.dnsCacheAlgorithm = dnsCacheAlgorithm
            self.dnsCacheMaxSize = dnsCacheMaxSize
            self.dnsEnhancedMode = dnsEnhancedMode
            self.dnsFakeIpRange6 = dnsFakeIpRange6
            self.dnsFakeIpFilter = dnsFakeIpFilter
            self.dnsFakeIpFilterMode = dnsFakeIpFilterMode
            self.dnsFakeIpTtl = dnsFakeIpTtl
            self.dnsDefaultNameserver = dnsDefaultNameserver
            self.dnsNameserverPolicy = dnsNameserverPolicy
            self.dnsExtraNameservers = dnsExtraNameservers
            self.dnsFallback = dnsFallback
            self.dnsFallbackLazyQuery = dnsFallbackLazyQuery
            self.dnsProxyServerNameserver = dnsProxyServerNameserver
            self.dnsProxyServerNameserverPolicy = dnsProxyServerNameserverPolicy
            self.dnsDirectNameserver = dnsDirectNameserver
            self.dnsDirectNameserverFollowPolicy = dnsDirectNameserverFollowPolicy
            self.dnsFallbackFilterGeoip = dnsFallbackFilterGeoip
            self.dnsFallbackFilterGeoipCode = dnsFallbackFilterGeoipCode
            self.dnsFallbackFilterGeosite = dnsFallbackFilterGeosite
            self.dnsFallbackFilterIpcidr = dnsFallbackFilterIpcidr
            self.dnsFallbackFilterDomain = dnsFallbackFilterDomain
            self.interfaceName = interfaceName
            self.interfaceNameMode = interfaceNameMode
            self.userAgents = userAgents
            self.authEnabled = authEnabled
            self.authUsername = authUsername
            self.authPassword = authPassword
            self.externalControllerSecret = externalControllerSecret
            self.externalControllerEnabled = externalControllerEnabled
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
            mitmSkipServerCertVerify = try c.decodeIfPresent(Bool.self, forKey: .mitmSkipServerCertVerify) ?? false
            mitmAutoQuicBlock = try c.decodeIfPresent(Bool.self, forKey: .mitmAutoQuicBlock) ?? true
            mitmTrustedFingerprint = try c.decodeIfPresent(String.self, forKey: .mitmTrustedFingerprint) ?? ""
            mitmCapture = try c.decodeIfPresent(Bool.self, forKey: .mitmCapture) ?? false
            mitmCaptureEntries = try c.decodeIfPresent(Int.self, forKey: .mitmCaptureEntries) ?? 64
            autoRun = try c.decodeIfPresent(Bool.self, forKey: .autoRun) ?? false
            autoCloseConnections = try c.decodeIfPresent(Bool.self, forKey: .autoCloseConnections) ?? false
            checkCertificate = try c.decodeIfPresent(Bool.self, forKey: .checkCertificate) ?? true
            autoCheckUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdate) ?? false
            openLogs = try c.decodeIfPresent(Bool.self, forKey: .openLogs) ?? false
            routeExcludeAddress = try c.decodeIfPresent([String].self, forKey: .routeExcludeAddress) ?? []
            bypassPrivateRoute = try c.decodeIfPresent(Bool.self, forKey: .bypassPrivateRoute) ?? false
            dnsHijack = try c.decodeIfPresent(Bool.self, forKey: .dnsHijack) ?? true
            dnsListen = try c.decodeIfPresent(String.self, forKey: .dnsListen) ?? ""
            dnsPreferH3 = try c.decodeIfPresent(Bool.self, forKey: .dnsPreferH3) ?? false
            dnsUseHosts = try c.decodeIfPresent(Bool.self, forKey: .dnsUseHosts) ?? true
            dnsUseSystemHosts = try c.decodeIfPresent(Bool.self, forKey: .dnsUseSystemHosts) ?? true
            dnsRespectRules = try c.decodeIfPresent(Bool.self, forKey: .dnsRespectRules) ?? false
            dnsIpv6Timeout = try c.decodeIfPresent(Int.self, forKey: .dnsIpv6Timeout) ?? 100
            dnsCacheAlgorithm = try c.decodeIfPresent(String.self, forKey: .dnsCacheAlgorithm) ?? "lru"
            dnsCacheMaxSize = try c.decodeIfPresent(Int.self, forKey: .dnsCacheMaxSize) ?? 4096
            dnsEnhancedMode = try c.decodeIfPresent(String.self, forKey: .dnsEnhancedMode) ?? (dnsFakeIpEnabled ? "fake-ip" : "normal")
            dnsFakeIpRange6 = try c.decodeIfPresent(String.self, forKey: .dnsFakeIpRange6) ?? ""
            dnsFakeIpFilter = try c.decodeIfPresent([String].self, forKey: .dnsFakeIpFilter) ?? ["dns.msftnsci.com", "www.msftnsci.com", "www.msftconnecttest.com"]
            dnsFakeIpFilterMode = try c.decodeIfPresent(String.self, forKey: .dnsFakeIpFilterMode) ?? "blacklist"
            dnsFakeIpTtl = try c.decodeIfPresent(Int.self, forKey: .dnsFakeIpTtl) ?? 1
            dnsDefaultNameserver = try c.decodeIfPresent([String].self, forKey: .dnsDefaultNameserver) ?? ["114.114.114.114", "223.5.5.5", "8.8.8.8", "1.0.0.1"]
            dnsNameserverPolicy = try c.decodeIfPresent([String: String].self, forKey: .dnsNameserverPolicy) ?? [:]
            dnsExtraNameservers = try c.decodeIfPresent([String].self, forKey: .dnsExtraNameservers) ?? []
            dnsFallback = try c.decodeIfPresent([String].self, forKey: .dnsFallback) ?? []
            dnsFallbackLazyQuery = try c.decodeIfPresent(Bool.self, forKey: .dnsFallbackLazyQuery) ?? false
            dnsProxyServerNameserver = try c.decodeIfPresent([String].self, forKey: .dnsProxyServerNameserver) ?? []
            dnsProxyServerNameserverPolicy = try c.decodeIfPresent([String: String].self, forKey: .dnsProxyServerNameserverPolicy) ?? [:]
            dnsDirectNameserver = try c.decodeIfPresent([String].self, forKey: .dnsDirectNameserver) ?? []
            dnsDirectNameserverFollowPolicy = try c.decodeIfPresent(Bool.self, forKey: .dnsDirectNameserverFollowPolicy) ?? false
            dnsFallbackFilterGeoip = try c.decodeIfPresent(Bool.self, forKey: .dnsFallbackFilterGeoip) ?? true
            dnsFallbackFilterGeoipCode = try c.decodeIfPresent(String.self, forKey: .dnsFallbackFilterGeoipCode) ?? ""
            dnsFallbackFilterGeosite = try c.decodeIfPresent([String].self, forKey: .dnsFallbackFilterGeosite) ?? []
            dnsFallbackFilterIpcidr = try c.decodeIfPresent([String].self, forKey: .dnsFallbackFilterIpcidr) ?? []
            dnsFallbackFilterDomain = try c.decodeIfPresent([String].self, forKey: .dnsFallbackFilterDomain) ?? []
            interfaceName = try c.decodeIfPresent(String.self, forKey: .interfaceName) ?? ""
            interfaceNameMode = try c.decodeIfPresent(String.self, forKey: .interfaceNameMode) ?? "follow"
            userAgents = try c.decodeIfPresent([String].self, forKey: .userAgents) ?? []
            authEnabled = try c.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? false
            authUsername = try c.decodeIfPresent(String.self, forKey: .authUsername) ?? ""
            authPassword = try c.decodeIfPresent(String.self, forKey: .authPassword) ?? ""
            externalControllerSecret = try c.decodeIfPresent(String.self, forKey: .externalControllerSecret) ?? ""
            externalControllerEnabled = try c.decodeIfPresent(Bool.self, forKey: .externalControllerEnabled) ?? false
            hideIp = try c.decodeIfPresent(Bool.self, forKey: .hideIp) ?? false
            dnsIpv6 = try c.decodeIfPresent(Bool.self, forKey: .dnsIpv6) ?? false
            keepAliveIdle = try c.decodeIfPresent(Int.self, forKey: .keepAliveIdle) ?? 0
            keepAliveInterval = try c.decodeIfPresent(Int.self, forKey: .keepAliveInterval) ?? 0
            disableKeepAlive = try c.decodeIfPresent(Bool.self, forKey: .disableKeepAlive) ?? false
            includeAllNetworks = try c.decodeIfPresent(Bool.self, forKey: .includeAllNetworks) ?? false
            excludeLocalNetworks = try c.decodeIfPresent(Bool.self, forKey: .excludeLocalNetworks) ?? true
            excludeAPNs = try c.decodeIfPresent(Bool.self, forKey: .excludeAPNs) ?? true
            excludeCellularServices = try c.decodeIfPresent(Bool.self, forKey: .excludeCellularServices) ?? true
            enforceRoutes = try c.decodeIfPresent(Bool.self, forKey: .enforceRoutes) ?? false
            excludeDeviceCommunication = try c.decodeIfPresent(Bool.self, forKey: .excludeDeviceCommunication) ?? true
            onlyStatisticsProxy = try c.decodeIfPresent(Bool.self, forKey: .onlyStatisticsProxy) ?? false
            appendSystemDns = try c.decodeIfPresent(Bool.self, forKey: .appendSystemDns) ?? false
            systemProxy = try c.decodeIfPresent(Bool.self, forKey: .systemProxy) ?? false
            bypassDomain = try c.decodeIfPresent([String].self, forKey: .bypassDomain) ?? []
            // Pre-tri-state installs only had the always/off bool:
            // on = "always", anything else = the core default
            // "strict" (the old "off" was the B4 bug — it forced
            // process matching off for everyone who never touched
            // the toggle).
            let legacyAlways = UserDefaults.standard.object(forKey: "ConcordiOS.findProcessModeAlways") as? Bool ?? false
            let rawMode = try c.decodeIfPresent(String.self, forKey: .findProcessModeSetting)
            findProcessModeSetting = ["strict", "always", "off"].contains(rawMode ?? "") ? rawMode! : (legacyAlways ? "always" : "strict")
        }
    }

    func save() {
        let saved = Saved(mode: mode.rawValue, logLevel: logLevel.rawValue, mixedPort: mixedPort, socksPort: socksPort, allowLan: allowLan, ipv6: ipv6, tcpConcurrent: tcpConcurrent, unifiedDelay: unifiedDelay, sniffing: sniffing, globalUa: globalUa, delayTestTimeout: delayTestTimeout, tunEnabled: tunEnabled, tunStack: tunStack, tunMtu: tunMtu, tunDns: tunDns, dnsEnabled: dnsEnabled, dnsNameserver: dnsNameserver, dnsFakeIpEnabled: dnsFakeIpEnabled, dnsFakeIpRange: dnsFakeIpRange, autoUpdateProfiles: autoUpdateProfiles, developerMode: developerMode, mitmEnabled: mitmEnabled, mitmHostnames: mitmHostnames, mitmDecryptTls: mitmDecryptTls, mitmCaFingerprint: mitmCaFingerprint, autoRun: autoRun, autoCloseConnections: autoCloseConnections, checkCertificate: checkCertificate, autoCheckUpdate: autoCheckUpdate, openLogs: openLogs, routeExcludeAddress: routeExcludeAddress, bypassPrivateRoute: bypassPrivateRoute, dnsHijack: dnsHijack, dnsListen: dnsListen, dnsPreferH3: dnsPreferH3, dnsUseHosts: dnsUseHosts, dnsUseSystemHosts: dnsUseSystemHosts, dnsRespectRules: dnsRespectRules, dnsIpv6Timeout: dnsIpv6Timeout, dnsCacheAlgorithm: dnsCacheAlgorithm, dnsCacheMaxSize: dnsCacheMaxSize, dnsEnhancedMode: dnsEnhancedMode, dnsFakeIpRange6: dnsFakeIpRange6, dnsFakeIpFilter: dnsFakeIpFilter, dnsFakeIpFilterMode: dnsFakeIpFilterMode, dnsFakeIpTtl: dnsFakeIpTtl, dnsDefaultNameserver: dnsDefaultNameserver, dnsNameserverPolicy: dnsNameserverPolicy, dnsExtraNameservers: dnsExtraNameservers, dnsFallback: dnsFallback, dnsFallbackLazyQuery: dnsFallbackLazyQuery, dnsProxyServerNameserver: dnsProxyServerNameserver, dnsProxyServerNameserverPolicy: dnsProxyServerNameserverPolicy, dnsDirectNameserver: dnsDirectNameserver, dnsDirectNameserverFollowPolicy: dnsDirectNameserverFollowPolicy, dnsFallbackFilterGeoip: dnsFallbackFilterGeoip, dnsFallbackFilterGeoipCode: dnsFallbackFilterGeoipCode, dnsFallbackFilterGeosite: dnsFallbackFilterGeosite, dnsFallbackFilterIpcidr: dnsFallbackFilterIpcidr, dnsFallbackFilterDomain: dnsFallbackFilterDomain, interfaceName: interfaceName, interfaceNameMode: interfaceNameMode, userAgents: userAgents, authEnabled: authEnabled, authUsername: authUsername, authPassword: authPassword, externalControllerSecret: externalControllerSecret, externalControllerEnabled: externalControllerEnabled, mitmSkipServerCertVerify: mitmSkipServerCertVerify, mitmAutoQuicBlock: mitmAutoQuicBlock, mitmTrustedFingerprint: mitmTrustedFingerprint, mitmCapture: mitmCapture, mitmCaptureEntries: mitmCaptureEntries, hideIp: hideIp, dnsIpv6: dnsIpv6, findProcessModeSetting: findProcessModeSetting, keepAliveIdle: keepAliveIdle, keepAliveInterval: keepAliveInterval, disableKeepAlive: disableKeepAlive, includeAllNetworks: includeAllNetworks, excludeLocalNetworks: excludeLocalNetworks, excludeAPNs: excludeAPNs, excludeCellularServices: excludeCellularServices, enforceRoutes: enforceRoutes, excludeDeviceCommunication: excludeDeviceCommunication, onlyStatisticsProxy: onlyStatisticsProxy, appendSystemDns: appendSystemDns, systemProxy: systemProxy, bypassDomain: bypassDomain)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        saveSharedFiles()
        // B6: the master sniffing switch lives here, but the
        // effective enable (master && SnifferStore.enable) is
        // written by SnifferStore.save() into sniffer.json — so a
        // master-switch change only propagates if sniffer.json is
        // re-saved. Do it on every settings save (the blob above
        // is already persisted, so savedSniffing() reads the new
        // value). No loop: SnifferStore.save() never touches this
        // store. Cheap (one small JSON write) and covers every
        // path that flips the switch (view, refreshFromCore,
        // backup restore).
        SnifferStore.shared.save()
    }

    /// Re-read the settings from UserDefaults and rewrite the shared
    /// files (used after a backup restore so the pages and the
    /// extension see the restored settings without restarting).
    func reload() {
        load()
        saveSharedFiles()
    }

    /// The saved master sniffing toggle, for stores that cannot reach
    /// this store's instance: SnifferStore reads it when writing
    /// sniffer.json, so the effective enable stays master && own.
    /// True when nothing was ever saved (the default is on).
    static func savedSniffing() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "ConcordiOS.settings.v1"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return true }
        return saved.sniffing
    }

    /// Persist a mode change made outside this store's instance (the
    /// Shortcuts mode intent runs without the app's stores): update
    /// the saved settings blob AND the shared general.json, so the
    /// mode is consistent wherever it is read next.
    static func persistMode(_ mode: OutboundMode) {
        if let data = UserDefaults.standard.data(forKey: "ConcordiOS.settings.v1"),
           var saved = try? JSONDecoder().decode(Saved.self, from: data) {
            saved.mode = mode.rawValue
            if let encoded = try? JSONEncoder().encode(saved) {
                UserDefaults.standard.set(encoded, forKey: "ConcordiOS.settings.v1")
            }
        }
        writeGeneralJSONMode(mode)
    }

    /// Merge just the mode into the shared general.json (read what is
    /// there, change one key, write it back) so an intent-side mode
    /// change never wipes the other general settings.
    private static func writeGeneralJSONMode(_ mode: OutboundMode) {
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.generalSettingsFileName) else { return }
        var general: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            general = object
        }
        general["mode"] = mode.rawValue
        if let data = try? JSONSerialization.data(withJSONObject: general) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Write the shared settings files the PacketTunnel extension
    /// reads at boot (tunnel.json, mitm.json, dns.json,
    /// general.json, general-overlay.json, sniffer.json, ntp.json)
    /// with the current UI defaults — but ONLY when the file is
    /// missing. Never overwrites an existing file, so saved user
    /// settings (or a backup restore) are never clobbered; calling
    /// it again is a no-op once every file exists. Idempotent.
    /// Call at app launch and at TunnelManager.start() (another
    /// worker wires those call sites). Fresh installs had no
    /// dns.json / sniffer.json / general.json at all, so the core
    /// ran its own defaults (DNS disabled, mixed-port 0,
    /// tcp-concurrent off) contradicting the UI (config B2).
    /// hosts.json is deliberately NOT created here: the extension
    /// only overlays hosts when the file exists, and an empty {}
    /// would wipe the active subscription's own hosts (config
    /// B16). overrides.json / added-rules.json / module-mitm.json
    /// are likewise left alone: missing means "no override",
    /// which is the correct default.
    func ensureSharedFilesExist() {
        saveSharedFiles(onlyIfMissing: true)
        // C3: backfill the geo keys into a general-overlay.json
        // written before v0.2.43 (without them). Only ADDS a key
        // when it is missing — never touches other keys, and an
        // explicitly saved false stays off. Runs on every launch
        // and every VPN start, so an upgraded install picks up the
        // new upstream default without waiting for an unrelated
        // settings save.
        backfillGeoOverlayKeys()
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.snifferFileName),
           !FileManager.default.fileExists(atPath: url.path) {
            SnifferStore.shared.save()
        }
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.ntpFileName),
           !FileManager.default.fileExists(atPath: url.path) {
            NtpStore.shared.save()
        }
    }

    /// Writes one shared JSON file, optionally only when it does
    /// not exist yet (see ensureSharedFilesExist). Silently
    /// skipped when the App Group container is unavailable.
    private func writeSharedJSON(_ dict: [String: Any], name: String, onlyIfMissing: Bool = false) {
        guard let url = ConfigStore.sharedFileURL(name: name) else { return }
        if onlyIfMissing, FileManager.default.fileExists(atPath: url.path) { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// C3: adds the geo auto-update keys to an existing
    /// general-overlay.json that lacks them (written before
    /// v0.2.43). Each key is filled independently; a present key —
    /// including an explicitly saved false — is never changed.
    /// Silently skipped when the container or file is unavailable
    /// or the file is not a JSON object.
    private func backfillGeoOverlayKeys() {
        guard let url = ConfigStore.sharedFileURL(name: ConfigStore.generalOverlayFileName),
              let data = try? Data(contentsOf: url),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        var changed = false
        if dict["geo-auto-update"] == nil {
            dict["geo-auto-update"] = defaults.object(forKey: "ConcordiOS.geoAutoUpdate") as? Bool ?? true
            changed = true
        }
        if dict["geo-update-interval"] == nil {
            dict["geo-update-interval"] = Int(defaults.object(forKey: "ConcordiOS.geoAutoUpdateHours") as? Double ?? 24.0)
            changed = true
        }
        guard changed, let out = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? out.write(to: url, options: .atomic)
    }

    /// Writes the files the PacketTunnel extension reads:
    /// tunnel.json (tun.start + interface settings), mitm.json
    /// (merged into config.apply's overlay), dns.json (ditto) and
    /// general.json (patched into the core at tunnel start via
    /// config.patch, so saved general settings take effect on the next
    /// VPN start even without tapping "apply"). Silently skipped when
    /// the App Group container is unavailable.
    private func saveSharedFiles(onlyIfMissing: Bool = false) {
        let dnsServers = tunDns.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var tunnel: [String: Any] = [
            "enabled": tunEnabled,
            "stack": tunStack,
            "mtu": tunMtu,
            "dns": dnsServers.isEmpty ? ["223.5.5.5", "8.8.8.8"] : dnsServers,
            "ipv6": ipv6,
            "route-exclude-address": routeExcludeAddress,
            "bypass-private-route": bypassPrivateRoute,
            "dns-hijack": dnsHijack,
            // C2: the six NETunnelProviderProtocol switches (system
            // defaults, so an untouched install writes the same
            // behaviour). The extension does not read these — the
            // app applies them to the protocol directly — but
            // tunnel.json is the record of the tunnel's settings.
            "include-all-networks": includeAllNetworks,
            "exclude-local-networks": excludeLocalNetworks,
            "exclude-apns": excludeAPNs,
            "exclude-cellular-services": excludeCellularServices,
            "enforce-routes": enforceRoutes,
            "exclude-device-communication": excludeDeviceCommunication,
            // C5/C16: FlClash's system-proxy switch + bypass-domain
            // list (network.dart VpnSystemProxyItem /
            // BypassDomainItem). The list is passed to the VPN setup
            // only while the switch is on (FlClash core.dart:247);
            // the extension reads both keys from here. Whether iOS
            // honours the switch is unverified — the toggle's
            // footnote says so.
            "system-proxy": systemProxy,
            "bypass-domain": systemProxy ? bypassDomain : [],
        ]
        // E6: preserve the Loopback 10.7.0.1 switch ("loopback-device",
        // written by LoopbackView's own read-modify-write). This dict
        // is built fresh from this store's fields and has no such
        // field, so without this a Settings save would drop the
        // switch. Missing file/key means OFF (the extension treats
        // a missing key as OFF).
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.tunnelSettingsFileName),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loopbackDevice = existing["loopback-device"] as? Bool {
            tunnel["loopback-device"] = loopbackDevice
        }
        writeSharedJSON(tunnel, name: ConfigStore.tunnelSettingsFileName, onlyIfMissing: onlyIfMissing)
        // mitm.json uses the core's RawConfig keys verbatim, so the
        // extension can pass it as the "mitm" overlay value unchanged.
        // decrypt-tls / ca-fingerprint come from mitmConfig, so a
        // trusted fingerprint folds in the same way as for
        // mitm.validate. "capture" is not a core MitmSection key
        // (serde ignores it); it is there for the extension to pass
        // as config.apply's options.mitm_capture.
        var mitm: [String: Any] = [
            "enable": mitmEnabled,
            "hostname": mitmConfig.hostname,
            "decrypt-tls": mitmConfig.decryptTls,
            "ca-fingerprint": mitmConfig.caFingerprint,
            "skip-server-cert-verify": mitmSkipServerCertVerify,
            "auto-quic-block": mitmAutoQuicBlock,
            "h2": mitmConfig.h2,
            "capture": mitmCapture,
        ]
        if mitmCapture {
            mitm["limits"] = ["capture-entries": mitmCaptureEntries]
        }
        writeSharedJSON(mitm, name: ConfigStore.mitmFileName, onlyIfMissing: onlyIfMissing)
        // dns.json likewise: the core's DnsConfig keys are kebab-case
        // ("enhanced-mode", "fake-ip-range" — upstream
        // crates/config/src/dns.rs), so the extension passes it as the
        // "dns" overlay value unchanged. Keys are only written when
        // they carry a usable value, so an empty nameserver field or
        // an invalid fake-ip-range never overrides the profile's DNS
        // with something broken. Lists / maps are written when
        // non-empty; scalars always (they are the section's own
        // values, and the profile's DNS is replaced wholesale by
        // this overlay whenever the file exists).
        var dns: [String: Any] = [
            "enable": dnsEnabled,
            "enhanced-mode": dnsEnhancedMode,
            "ipv6": dnsIpv6,
            "ipv6-timeout": dnsIpv6Timeout,
            "prefer-h3": dnsPreferH3,
            "use-hosts": dnsUseHosts,
            "use-system-hosts": dnsUseSystemHosts,
            "respect-rules": dnsRespectRules,
            "cache-algorithm": dnsCacheAlgorithm,
            "cache-max-size": dnsCacheMaxSize,
            "fake-ip-filter-mode": dnsFakeIpFilterMode,
            "fake-ip-ttl": dnsFakeIpTtl,
            "fallback-lazy-query": dnsFallbackLazyQuery,
            "direct-nameserver-follow-policy": dnsDirectNameserverFollowPolicy,
        ]
        let nameserver = dnsNameserver.trimmingCharacters(in: .whitespaces)
        var nameservers: [String] = []
        if !nameserver.isEmpty { nameservers.append(nameserver) }
        nameservers.append(contentsOf: dnsExtraNameservers)
        // C1: 追加系统 DNS (FlClash task.dart:314 — append the
        // system DNS to dns.nameserver at config build). The system
        // servers come from /etc/resolv.conf via
        // ConnectionStore.systemDnsServers() ("ip:53" socket
        // addresses, the same source network.update uses); they are
        // appended after the user's own servers, deduplicated, so
        // the profile's nameservers keep priority.
        if appendSystemDns, let systemServers = ConnectionStore.systemDnsServers() {
            for server in systemServers where !nameservers.contains(server) {
                nameservers.append(server)
            }
        }
        if !nameservers.isEmpty {
            dns["nameserver"] = nameservers
        }
        let fakeIpRange = dnsFakeIpRange.trimmingCharacters(in: .whitespaces)
        if Self.isValidIPv4CIDR(fakeIpRange) {
            dns["fake-ip-range"] = fakeIpRange
        }
        let fakeIpRange6 = dnsFakeIpRange6.trimmingCharacters(in: .whitespaces)
        if !fakeIpRange6.isEmpty {
            dns["fake-ip-range6"] = fakeIpRange6
        }
        if !dnsFakeIpFilter.isEmpty {
            dns["fake-ip-filter"] = dnsFakeIpFilter
        }
        if !dnsDefaultNameserver.isEmpty {
            dns["default-nameserver"] = dnsDefaultNameserver
        }
        if !dnsNameserverPolicy.isEmpty {
            dns["nameserver-policy"] = dnsNameserverPolicy
        }
        if !dnsFallback.isEmpty {
            dns["fallback"] = dnsFallback
        }
        if !dnsProxyServerNameserver.isEmpty {
            dns["proxy-server-nameserver"] = dnsProxyServerNameserver
        }
        if !dnsProxyServerNameserverPolicy.isEmpty {
            dns["proxy-server-nameserver-policy"] = dnsProxyServerNameserverPolicy
        }
        if !dnsDirectNameserver.isEmpty {
            dns["direct-nameserver"] = dnsDirectNameserver
        }
        let listen = dnsListen.trimmingCharacters(in: .whitespaces)
        if !listen.isEmpty {
            dns["listen"] = listen
        }
        // listen-routing-mark (FlClash dns.dart:191-193; core
        // DnsConfig key). 0 = the core default, so it is only
        // written when set — otherwise it would override the
        // profile's value with the default.
        let listenRoutingMark = UserDefaults.standard.integer(forKey: "ConcordiOS.dnsListenRoutingMark")
        if listenRoutingMark != 0 {
            dns["listen-routing-mark"] = listenRoutingMark
        }
        var fallbackFilter: [String: Any] = [
            "geoip": dnsFallbackFilterGeoip,
            "geoip-code": dnsFallbackFilterGeoipCode,
        ]
        if !dnsFallbackFilterGeosite.isEmpty {
            fallbackFilter["geosite"] = dnsFallbackFilterGeosite
        }
        if !dnsFallbackFilterIpcidr.isEmpty {
            fallbackFilter["ipcidr"] = dnsFallbackFilterIpcidr
        }
        if !dnsFallbackFilterDomain.isEmpty {
            fallbackFilter["domain"] = dnsFallbackFilterDomain
        }
        dns["fallback-filter"] = fallbackFilter
        writeSharedJSON(dns, name: ConfigStore.dnsFileName, onlyIfMissing: onlyIfMissing)
        // general.json: the general settings in ConfigPatchParams wire
        // keys (snake_case), patched by the extension at tunnel start.
        var general: [String: Any] = [
            "mode": mode.rawValue,
            "log_level": logLevel.rawValue,
            "mixed_port": mixedPort,
            "allow_lan": allowLan,
            "ipv6": ipv6,
            "tcp_concurrent": tcpConcurrent,
            "unified_delay": unifiedDelay,
        ]
        // Auth + external-controller secret (core ConfigPatchParams
        // accepts all three): an empty secret / disabled auth clears
        // the value in force, so they are always written.
        general["secret"] = externalControllerSecret
        general["authentication"] = authPatchLines
        general["external_controller"] = externalControllerAddress
        writeSharedJSON(general, name: ConfigStore.generalSettingsFileName, onlyIfMissing: onlyIfMissing)
        // general-overlay.json: top-level RawConfig keys config.patch
        // cannot carry (global-ua, interface-name). The extension
        // merges them into config.apply's overlay. interface-name
        // follows the mode: follow = omit (profile's value stands),
        // clear = "", custom = the name.
        // The extra inbound ports and find-process-mode are the same
        // kind of key: the core's ConfigPatchParams has NO port /
        // redir-port / tproxy-port / socks-port field — and although
        // api.json's ConfigPatchParams DOES have findProcessMode,
        // our ConcordConfigPatchParams (ConcordClient.swift) has no
        // such field yet — so they must NOT go into general.json:
        // the startup config.patch would drop them (or fail). They
        // travel here instead, as RawConfig
        // kebab-case keys, exactly as FlClash writes them into
        // rawConfig (task.dart:197-202). The values live in
        // UserDefaults (@AppStorage in SettingsView); the extension
        // merges this file into config.apply's overlay at tunnel
        // start AND on every live re-apply, so the ports apply on
        // the next start or the next "应用通用设置".
        var overlay: [String: Any] = [:]
        let defaults = UserDefaults.standard
        overlay["port"] = defaults.integer(forKey: "ConcordiOS.httpPort")
        overlay["redir-port"] = defaults.integer(forKey: "ConcordiOS.redirPort")
        overlay["tproxy-port"] = defaults.integer(forKey: "ConcordiOS.tproxyPort")
        // B3: socks-port is a real RawConfig T0 key (core
        // crates/config/src/keys.rs, default 0 = disabled) and the
        // only way to reach it — ConfigPatchParams has no socks
        // field. 0 disables the listener, matching the UI. The
        // extension merges this file into config.apply's overlay
        // at tunnel start AND on every live re-apply, so the UI
        // value and "restore default ports" now actually take
        // effect (previously the stepper wrote a dead value).
        overlay["socks-port"] = socksPort
        // B4: the picked mode (default "strict", the core default).
        // The old bool wrote "always"/"off" and forced "off" on
        // everyone who never touched the toggle.
        overlay["find-process-mode"] = findProcessModeSetting
        // C6: TCP keep-alive (core GeneralConfig `keep-alive-idle` /
        // `keep-alive-interval` / `disable-keep-alive`, defaults
        // 0/0/false = the core's built-in 15 s idle). ConfigPatchParams
        // has NO keep-alive field, so these cannot travel via
        // general.json — the startup config.patch would drop them —
        // they go here as RawConfig kebab-case keys, like socks-port
        // and find-process-mode above. 0/0/false are the core
        // defaults, so an untouched install behaves the same.
        overlay["keep-alive-idle"] = keepAliveIdle
        overlay["keep-alive-interval"] = keepAliveInterval
        overlay["disable-keep-alive"] = disableKeepAlive
        // C3: geo auto-update (upstream FlClash 1b2ea11 flipped the
        // client default false -> true, 24 h interval; an
        // explicitly saved false stays off). RawConfig kebab-case
        // keys (core crates/config/src/keys.rs), so they travel
        // here like socks-port / find-process-mode / keep-alive —
        // the extension merges this file into config.apply's
        // overlay at tunnel start AND on every live re-apply, and
        // the core's GeoUpdater runs the periodic refresh from
        // them (crates/engine/src/resources.rs sync_auto /
        // auto_loop). Absent key = true: bool(forKey:) returns
        // false for a missing key, so the default must be read
        // via object(forKey:).
        overlay["geo-auto-update"] = defaults.object(forKey: "ConcordiOS.geoAutoUpdate") as? Bool ?? true
        overlay["geo-update-interval"] = Int(defaults.object(forKey: "ConcordiOS.geoAutoUpdateHours") as? Double ?? 24.0)
        let ua = globalUa.trimmingCharacters(in: .whitespaces)
        if !ua.isEmpty {
            overlay["global-ua"] = ua
        }
        switch interfaceNameMode {
        case "clear":
            overlay["interface-name"] = ""
        case "custom":
            let name = interfaceName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                overlay["interface-name"] = name
            }
        default:
            break
        }
        writeSharedJSON(overlay, name: ConfigStore.generalOverlayFileName, onlyIfMissing: onlyIfMissing)
    }

    /// The `user:password` lines for config.patch: one line while
    /// auth is on (a colon in the username would break the split,
    /// so it is stripped, matching FlClash), empty when off.
    var authPatchLines: [String] {
        guard authEnabled else { return [] }
        let user = authUsername.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        let pass = authPassword.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return [] }
        return ["\(user):\(pass)"]
    }

    /// The external-controller listen address for config.patch:
    /// 127.0.0.1:9090 while enabled with a secret set, "" otherwise
    /// (FlClash only opens the controller when a secret exists).
    var externalControllerAddress: String {
        externalControllerEnabled && !externalControllerSecret.trimmingCharacters(in: .whitespaces).isEmpty
            ? "127.0.0.1:9090" : ""
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
        delayTestTimeout = min(max(saved.delayTestTimeout, 500), 8000)
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
        mitmSkipServerCertVerify = saved.mitmSkipServerCertVerify
        mitmAutoQuicBlock = saved.mitmAutoQuicBlock
        mitmTrustedFingerprint = saved.mitmTrustedFingerprint
        mitmCapture = saved.mitmCapture
        mitmCaptureEntries = saved.mitmCaptureEntries
        autoRun = saved.autoRun
        autoCloseConnections = saved.autoCloseConnections
        checkCertificate = saved.checkCertificate
        autoCheckUpdate = saved.autoCheckUpdate
        openLogs = saved.openLogs
        routeExcludeAddress = saved.routeExcludeAddress
        bypassPrivateRoute = saved.bypassPrivateRoute
        dnsHijack = saved.dnsHijack
        dnsListen = saved.dnsListen
        dnsPreferH3 = saved.dnsPreferH3
        dnsUseHosts = saved.dnsUseHosts
        dnsUseSystemHosts = saved.dnsUseSystemHosts
        dnsRespectRules = saved.dnsRespectRules
        dnsIpv6Timeout = saved.dnsIpv6Timeout
        dnsCacheAlgorithm = saved.dnsCacheAlgorithm
        dnsCacheMaxSize = saved.dnsCacheMaxSize
        dnsEnhancedMode = saved.dnsEnhancedMode
        dnsFakeIpRange6 = saved.dnsFakeIpRange6
        dnsFakeIpFilter = saved.dnsFakeIpFilter
        dnsFakeIpFilterMode = saved.dnsFakeIpFilterMode
        dnsFakeIpTtl = saved.dnsFakeIpTtl
        dnsDefaultNameserver = saved.dnsDefaultNameserver
        dnsNameserverPolicy = saved.dnsNameserverPolicy
        dnsExtraNameservers = saved.dnsExtraNameservers
        dnsFallback = saved.dnsFallback
        dnsFallbackLazyQuery = saved.dnsFallbackLazyQuery
        dnsProxyServerNameserver = saved.dnsProxyServerNameserver
        dnsProxyServerNameserverPolicy = saved.dnsProxyServerNameserverPolicy
        dnsDirectNameserver = saved.dnsDirectNameserver
        dnsDirectNameserverFollowPolicy = saved.dnsDirectNameserverFollowPolicy
        dnsFallbackFilterGeoip = saved.dnsFallbackFilterGeoip
        dnsFallbackFilterGeoipCode = saved.dnsFallbackFilterGeoipCode
        dnsFallbackFilterGeosite = saved.dnsFallbackFilterGeosite
        dnsFallbackFilterIpcidr = saved.dnsFallbackFilterIpcidr
        dnsFallbackFilterDomain = saved.dnsFallbackFilterDomain
        interfaceName = saved.interfaceName
        interfaceNameMode = saved.interfaceNameMode
        userAgents = saved.userAgents
        authEnabled = saved.authEnabled
        authUsername = saved.authUsername
        authPassword = saved.authPassword
        externalControllerSecret = saved.externalControllerSecret
        externalControllerEnabled = saved.externalControllerEnabled
        hideIp = saved.hideIp
        dnsIpv6 = saved.dnsIpv6
        findProcessModeSetting = saved.findProcessModeSetting
        keepAliveIdle = saved.keepAliveIdle
        keepAliveInterval = saved.keepAliveInterval
        disableKeepAlive = saved.disableKeepAlive
        includeAllNetworks = saved.includeAllNetworks
        excludeLocalNetworks = saved.excludeLocalNetworks
        excludeAPNs = saved.excludeAPNs
        excludeCellularServices = saved.excludeCellularServices
        enforceRoutes = saved.enforceRoutes
        excludeDeviceCommunication = saved.excludeDeviceCommunication
        onlyStatisticsProxy = saved.onlyStatisticsProxy
        appendSystemDns = saved.appendSystemDns
        systemProxy = saved.systemProxy
        bypassDomain = saved.bypassDomain
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
            if let value = general.findProcessMode { findProcessMode = value }
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
                tcpConcurrent: tcpConcurrent, unifiedDelay: unifiedDelay,
                findProcessMode: findProcessModeSetting,
                secret: externalControllerSecret,
                authentication: authPatchLines,
                externalController: externalControllerAddress))
            // The patch cannot carry the RawConfig keys that live in
            // general-overlay.json / mitm.json / dns.json (extra
            // ports, h2, listen-routing-mark — ConfigPatchParams has
            // no such fields). find-process-mode DOES travel via this
            // patch (live) and via general-overlay.json (merged at
            // config.apply / boot) — same value, so they cannot
            // disagree. Re-apply the config so the extension
            // re-merges those shared files into the overlay (same
            // mechanism as applyDnsSettings). A re-apply failure
            // does not undo the patch above.
            do {
                _ = try await client.configApply(profilePath: nil)
                generalApplyMessage = "通用设置已应用到核心"
            } catch {
                generalApplyMessage = "通用设置已打补丁，但配置重载失败（端口等需重载的项下次启动 VPN 时生效）：\(error.localizedDescription)"
            }
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

    /// Reads the core's TUN state (config.general `tun`). Display-only:
    /// TUN is owned by the PacketTunnel extension (tun.start/tun.stop +
    /// tunnel.json); sending config.patch `tun` would fight it — the
    /// patch would disable or replace the device the extension is
    /// pumping packets through — so the app never sends tun patches.
    /// `device` is meaningless on iOS (the device is the packet
    /// channel, not a named interface) and `autoRoute` is owned by
    /// NetworkExtension, not the core.
    @MainActor
    func refreshTunState() async {
        do {
            tunState = try await client.configGeneral().tun
            tunStateMessage = tunState == nil ? "核心未报告 TUN 状态" : nil
        } catch {
            tunState = nil
            tunStateMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    /// Raises the MITM memory-pressure level (core.setPressure).
    /// Levels: 0 none, 1 stop scripts, 2 stop bodies, 3 relay-only.
    /// The core clamps to 0…3 and only ever raises; the level lifts
    /// itself after a hold. Only affects MITM capture shedding, so it
    /// is a no-op while MITM is off.
    @MainActor
    func setPressure(level: Int) async {
        guard client.mode == .live else {
            pressureMessage = "示例模式：不会发往核心"
            return
        }
        guard TunnelManager.shared.isRunning else {
            pressureMessage = "需先启动 VPN"
            return
        }
        do {
            try await client.coreSetPressure(level: Int32(level))
            pressureLevel = level
            pressureMessage = "已设置内存压力等级 \(level)（\(Self.pressureLabel(level))）"
        } catch {
            pressureMessage = "设置失败：\(error.localizedDescription)"
        }
    }

    static func pressureLabel(_ level: Int) -> String {
        switch level {
        case 1: return "停止脚本"
        case 2: return "停止保存请求体"
        case 3: return "仅中继"
        default: return "无压力"
        }
    }

    /// Intentionally aborts the core process (debug.crash). Only built
    /// into debug cores (concord-api `debug` feature, off in release
    /// packages); the iOS staticlib does not enable it, so the core
    /// answers "method not found" and nothing crashes. The UI asks
    /// for confirmation first and shows the core's answer here.
    @MainActor
    func crashCore() async {
        guard client.mode == .live else {
            crashMessage = "示例模式：不会真的崩溃"
            return
        }
        guard TunnelManager.shared.isRunning else {
            crashMessage = "需先启动 VPN"
            return
        }
        do {
            try await client.debugCrash()
            crashMessage = "核心已崩溃（debug.crash 已发送，隧道将断开）"
        } catch {
            crashMessage = "未崩溃：\(error.localizedDescription)"
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
        // Fork ac90aebb: delete the old CA from BOTH homes before
        // regenerating — the tunnel core overwrites its own home,
        // but the app home would otherwise keep the stale CA for
        // VPN-off trust checks (healCAFiles never overwrites an
        // existing CA), and the next ensureStarted would then keep
        // loading the old one. Live mode only: sample mode has no
        // real core homes, and must not touch the real CA files.
        // Deletion failures are reported in the status message,
        // never silently passed; if generation then fails after
        // files were already deleted, say so too.
        let deletion = client.mode == .live ? AppCore.deleteOldCAFiles() : nil
        do {
            let cert = try await client.mitmGenerateCertificate()
            mitmCertificate = cert.certificate
            if let info = cert.certificate {
                mitmCaFingerprint = info.fingerprint
                var message = "CA 已生成：\(info.subject)，指纹 \(info.fingerprint)"
                if let deletion, deletion.hasFailures {
                    message += "。注意：旧 CA 文件未能完全删除（\(deletion.failures.joined(separator: "；"))），请重试或检查后重新生成"
                }
                mitmStatusMessage = message
                save()
            } else {
                mitmStatusMessage = "生成后仍无 CA 证书返回"
            }
        } catch {
            var message = "生成 CA 失败：\(error.localizedDescription)"
            if let deletion, !deletion.deleted.isEmpty {
                message += "（旧 CA 文件已先删除，重新生成一次即可恢复）"
            }
            mitmStatusMessage = message
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
        // B38: the tunnel path below only works while the VPN is
        // running (client talks to the extension core). When it is
        // off in live mode, fall back to the in-app core — the same
        // pattern as MitmCertificateView's CA generation (v0.2.35
        // Item C): AppCore.ensureStarted() boots the core
        // in-process, then AppCore.mitmIssueCertificate issues the
        // leaf there. If the tunnel starts while the in-app core is
        // booting, AppCore refuses (tunnelRunning) and the call falls
        // through to the tunnel-core path below.
        if client.mode == .live, !TunnelManager.shared.isRunning {
            do {
                try await AppCore.shared.ensureStarted()
                let pem = try await AppCore.shared.mitmIssueCertificate(host: host)
                mitmIssuedPem = pem.pem
                mitmStatusMessage = "已为 \(host) 签发叶证书（应用内核心，可用于验证信任链）"
                return
            } catch {
                if case AppCoreError.tunnelRunning = error {
                    // Fall through to the tunnel-core path below.
                } else {
                    mitmStatusMessage = "应用内核心签发失败：\(error.localizedDescription)"
                    return
                }
            }
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
