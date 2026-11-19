import Foundation
import Combine

// MARK: - Sniffer store (FlClash: lib/views/config/sniffer.dart)
// The core's sniffer section (upstream crates/config/src/keys.rs
// sniffer_defaults): enable, override-destination,
// force-dns-mapping, parse-pure-ip, force-domain, skip-domain,
// skip-src-address, skip-dst-address, plus one sniff config per
// protocol (HTTP / TLS / QUIC) with its own ports list and
// override-destination (nil = inherit the sniffer's). Written to
// the shared sniffer.json, merged by the extension into
// config.apply's overlay as "sniffer".
//
// The master switch is the 通用 page's 流量嗅探 toggle
// (SettingsStore.sniffing): the effective enable written here is
// master && this page's own enable, so turning the master off
// disables sniffing without losing the per-protocol choices.

/// One protocol's sniff config: ports (empty = the protocol's
/// standard port) and override-destination (nil = inherit).
struct SniffProtocolConfig: Codable, Equatable {
    var ports: [String] = []
    var overrideDest: Bool? = nil
}

final class SnifferStore: ObservableObject {
    static let shared = SnifferStore()

    @Published var enable: Bool = true
    @Published var overrideDest: Bool = true
    @Published var forceDnsMapping: Bool = true
    @Published var parsePureIp: Bool = true
    @Published var forceDomain: [String] = []
    @Published var skipDomain: [String] = []
    @Published var skipSrcAddress: [String] = []
    @Published var skipDstAddress: [String] = []
    @Published var sniffHttp: SniffProtocolConfig = SniffProtocolConfig()
    @Published var sniffTls: SniffProtocolConfig = SniffProtocolConfig()
    @Published var sniffQuic: SniffProtocolConfig = SniffProtocolConfig()
    @Published var applyMessage: String?

    let client: ConcordClient
    private let storageKey = "ConcordiOS.sniffer.v1"
    private var autosaveCancellable: AnyCancellable?

    private struct Saved: Codable {
        var enable: Bool = true
        var overrideDest: Bool = true
        var forceDnsMapping: Bool = true
        var parsePureIp: Bool = true
        var forceDomain: [String] = []
        var skipDomain: [String] = []
        var skipSrcAddress: [String] = []
        var skipDstAddress: [String] = []
        var sniffHttp: SniffProtocolConfig = SniffProtocolConfig()
        var sniffTls: SniffProtocolConfig = SniffProtocolConfig()
        var sniffQuic: SniffProtocolConfig = SniffProtocolConfig()
    }

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
        autosaveCancellable = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.save() }
        }
    }

    /// Effective enable: the 通用 master switch AND this page's own.
    var effectiveEnable: Bool {
        SettingsStore.savedSniffing() && enable
    }

    private func sniffDict(_ config: SniffProtocolConfig) -> [String: Any] {
        var dict: [String: Any] = ["ports": config.ports]
        if let overrideDest = config.overrideDest {
            dict["override-destination"] = overrideDest
        }
        return dict
    }

    /// The overlay dict for sniffer.json (RawConfig keys,
    /// kebab-case). "sniffing" (the deprecated list form) is left
    /// out: the core only reads it while "sniff" is empty.
    var overlayDict: [String: Any] {
        [
            "enable": effectiveEnable,
            "override-destination": overrideDest,
            "force-dns-mapping": forceDnsMapping,
            "parse-pure-ip": parsePureIp,
            "force-domain": forceDomain,
            "skip-domain": skipDomain,
            "skip-src-address": skipSrcAddress,
            "skip-dst-address": skipDstAddress,
            "sniff": [
                "HTTP": sniffDict(sniffHttp),
                "TLS": sniffDict(sniffTls),
                "QUIC": sniffDict(sniffQuic),
            ],
        ]
    }

    func save() {
        let saved = Saved(enable: enable, overrideDest: overrideDest,
                          forceDnsMapping: forceDnsMapping, parsePureIp: parsePureIp,
                          forceDomain: forceDomain, skipDomain: skipDomain,
                          skipSrcAddress: skipSrcAddress, skipDstAddress: skipDstAddress,
                          sniffHttp: sniffHttp, sniffTls: sniffTls, sniffQuic: sniffQuic)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.snifferFileName),
           let json = try? JSONSerialization.data(withJSONObject: overlayDict) {
            try? json.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        enable = saved.enable
        overrideDest = saved.overrideDest
        forceDnsMapping = saved.forceDnsMapping
        parsePureIp = saved.parsePureIp
        forceDomain = saved.forceDomain
        skipDomain = saved.skipDomain
        skipSrcAddress = saved.skipSrcAddress
        skipDstAddress = saved.skipDstAddress
        sniffHttp = saved.sniffHttp
        sniffTls = saved.sniffTls
        sniffQuic = saved.sniffQuic
    }

    /// Saves and re-applies the active config so the new sniffer
    /// takes effect. When the tunnel is stopped the settings are
    /// still saved and take effect at the next VPN start.
    @MainActor
    func applySnifferSettings() async {
        save()
        guard client.mode == .live else {
            applyMessage = "示例模式：嗅探设置已保存在本地，切换到实时核心并重启 VPN 后生效"
            return
        }
        guard TunnelManager.shared.isRunning else {
            applyMessage = "嗅探设置已保存，下次启动 VPN 时生效"
            return
        }
        do {
            _ = try await client.configApply(profilePath: nil)
            applyMessage = "嗅探设置已应用（立即生效）"
        } catch {
            applyMessage = "应用失败：\(error.localizedDescription)"
        }
    }
}
