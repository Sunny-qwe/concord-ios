import Foundation
import Combine

// MARK: - NTP store (FlClash: lib/views/config/ntp.dart)
// The core's NTP section (upstream crates/config/src/keys.rs
// NTP_KEYS): enable, server, port, interval, dialer-proxy,
// write-to-system. Written to the shared ntp.json, which the
// extension merges into config.apply's overlay as "ntp" — the
// profile's own NTP is replaced wholesale whenever the file
// exists, same as dns.json / mitm.json.
//
// write-to-system asks the core to set the device clock: iOS gives
// an app no such API, so the value is passed through and the core
// (running in the extension) is left to honour or refuse it.

final class NtpStore: ObservableObject {
    static let shared = NtpStore()

    @Published var enable: Bool = false
    @Published var server: String = "time.apple.com"
    @Published var port: Int = 123
    @Published var interval: Int = 30
    @Published var dialerProxy: String = ""
    @Published var writeToSystem: Bool = false
    @Published var applyMessage: String?

    let client: ConcordClient
    private let storageKey = "ConcordiOS.ntp.v1"
    private var autosaveCancellable: AnyCancellable?

    private struct Saved: Codable {
        var enable: Bool = false
        var server: String = "time.apple.com"
        var port: Int = 123
        var interval: Int = 30
        var dialerProxy: String = ""
        var writeToSystem: Bool = false
    }

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
        load()
        autosaveCancellable = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.save() }
        }
    }

    /// The overlay dict for ntp.json (RawConfig keys, kebab-case).
    var overlayDict: [String: Any] {
        [
            "enable": enable,
            "server": server.trimmingCharacters(in: .whitespaces),
            "port": port,
            "interval": interval,
            "dialer-proxy": dialerProxy.trimmingCharacters(in: .whitespaces),
            "write-to-system": writeToSystem,
        ]
    }

    func save() {
        let saved = Saved(enable: enable, server: server, port: port,
                          interval: interval, dialerProxy: dialerProxy,
                          writeToSystem: writeToSystem)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        if let url = ConfigStore.sharedFileURL(name: ConfigStore.ntpFileName),
           let json = try? JSONSerialization.data(withJSONObject: overlayDict) {
            try? json.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        enable = saved.enable
        server = saved.server
        port = saved.port
        interval = saved.interval
        dialerProxy = saved.dialerProxy
        writeToSystem = saved.writeToSystem
    }

    /// Saves and re-applies the active config so the new NTP takes
    /// effect. When the tunnel is stopped the settings are still
    /// saved and take effect at the next VPN start.
    @MainActor
    func applyNtpSettings() async {
        save()
        guard client.mode == .live else {
            applyMessage = "示例模式：NTP 设置已保存在本地，切换到实时核心并重启 VPN 后生效"
            return
        }
        guard TunnelManager.shared.isRunning else {
            applyMessage = "NTP 设置已保存，下次启动 VPN 时生效"
            return
        }
        do {
            _ = try await client.configApply(profilePath: nil)
            applyMessage = "NTP 设置已应用（立即生效）"
        } catch {
            applyMessage = "应用失败：\(error.localizedDescription)"
        }
    }
}
