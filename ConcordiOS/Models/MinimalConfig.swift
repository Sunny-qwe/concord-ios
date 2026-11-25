import Foundation

// MARK: - Minimal config (FlClash no-profile mode)
/// The general-only config the app falls back to when no profile
/// remains (FlClash v0.9.5-rs.1 no-profile mode, _makeRealProfileTask
/// in lib/common/task.dart + the PatchClashConfig defaults in
/// lib/models/clash_config.dart). No proxies, no proxy-groups, no
/// rules — with mode 'rule' and an empty rule list everything falls
/// to DIRECT (core route.rs decide), so the VPN keeps running with
/// all traffic direct instead of stopping when the last profile is
/// deleted. The 646f8c9 core accepts it: config.apply succeeds and
/// engine.start runs (item 8 gate, GO).
///
/// Field notes (do NOT invent keys or values — every line below is
/// copied from the FlClash defaults):
///   - mode is 'rule', NOT 'direct': FlClash's default is rule.
///   - dns.nameserver MUST be non-empty when dns.enable is true
///     (core dns.rs hard requirement); the two DoH upstreams are
///     FlClash's baselineDns (clash_config.dart:27-29).
///   - geox-url is FlClash's defaultGeoXUrl (clash_config.dart:32-39).
///   - tun is Tun.coreJson + task.dart's dns-hijack ['any:53'] and
///     auto-detect-interface true; enable stays false (the iOS
///     tunnel is driven by the NetworkExtension, not the core TUN).
///   - mitm is Mitm.coreJson with empty rule lists and mitm disabled:
///     no 'modules' key (modules only exist when enabled). The
///     limits are FlClash's desktop set (_desktopMitmLimits) — iOS
///     is not Android, so FlClash applies the desktop set there too;
///     they are inert while enable is false.
///   - proxies / proxy-groups / proxy-providers / rule-providers are
///     OMITTED entirely (not empty arrays); ntp / sniffer are omitted
///     so the core defaults apply.
enum MinimalConfig {

    /// FlClash's defaultGeoXUrl (clash_config.dart:32-39) — the
    /// three MetaCubeX download URLs. Single source of truth: the
    /// YAML below interpolates them, and SettingsStore's geo-URL
    /// resolver falls back to them, so the strings exist once.
    static let defaultGeoURLMMDB = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
    static let defaultGeoURLASN = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
    static let defaultGeoURLGeosite = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

    /// The minimal config as YAML text, one key per line.
    static var yaml: String {
        """
        mode: rule
        log-level: error
        mixed-port: 7890
        port: 0
        socks-port: 0
        redir-port: 0
        tproxy-port: 0
        allow-lan: false
        authentication: []
        skip-auth-prefixes: []
        find-process-mode: strict
        keep-alive-interval: 30
        keep-alive-idle: 15
        disable-keep-alive: false
        routing-mark: 0
        unified-delay: true
        tcp-concurrent: true
        ipv6: false
        tun:
          enable: false
          device: FlClash
          auto-route: true
          dns-hijack:
            - any:53
          auto-detect-interface: true
        geo-auto-update: true
        geo-update-interval: 24
        geox-url:
          mmdb: \(defaultGeoURLMMDB)
          asn: \(defaultGeoURLASN)
          geosite: \(defaultGeoURLGeosite)
        profile:
          store-selected: false
        hosts: {}
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver:
            - https://doh.pub/dns-query
            - https://dns.alidns.com/dns-query
        mitm:
          enable: false
          skip-server-cert-verify: false
          auto-quic-block: true
          h2: false
          hostname: []
          url-rewrite: []
          header-rewrite: []
          body-rewrite: []
          map-local: []
          request-body-mock: []
          client-source-address: []
          skip-server-cert-verify-hostname: []
          script: []
          decrypt-tls: false
          ca-fingerprint: ''
          limits:
            max-body-size: 4194304
            body-buffer: 33554432
            certificate-cache: 1024
            script-concurrency: 4
            script-memory: 268435456
            capture-entries: 2000
            capture-bytes: 67108864
        rules: []
        external-controller: ''
        secret: ''
        external-controller-tls: ''
        external-controller-unix: ''
        external-controller-pipe: ''
        external-ui: ''
        external-ui-url: ''
        interface-name: ''
        """
    }

    /// Writes the minimal config to the App Group shared config.yaml
    /// — the same URL ProfileStore.applyProfile writes to, so the
    /// extension reads it at the next VPN start — and returns its URL.
    /// Throws when the App Group container is unavailable or the
    /// write fails; the caller decides what that means for the tunnel.
    @discardableResult
    static func writeToSharedConfig() throws -> URL {
        guard let shared = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ConfigStore.appGroupID)?
            .appendingPathComponent(ConfigStore.configFileName) else {
            throw MinimalConfigError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(to: shared, atomically: true, encoding: .utf8)
        return shared
    }
}

/// Failures from MinimalConfig.writeToSharedConfig.
enum MinimalConfigError: LocalizedError {
    /// The App Group container URL could not be resolved (missing
    /// entitlements / App Group configuration).
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group 容器不可用，请检查 entitlements 与 App Group 配置"
        }
    }
}
