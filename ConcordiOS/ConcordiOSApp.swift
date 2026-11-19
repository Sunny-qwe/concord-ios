import SwiftUI

// Concord iOS — main app entry point.
// One shared ConcordClient feeds every store; the stores are the single
// source of truth for their page. The client runs in `.live` mode by
// default: the real core lives in the PacketTunnel extension process
// and the app reaches it through TunnelManager (sendProviderMessage)
// plus the App Group snapshot files — the app never loads the core
// itself (see ConcordClient.swift and PacketTunnelProvider.swift).
// `.sample` is an explicit, labelled fallback only.

@main
struct ConcordiOSApp: App {
    @StateObject private var client = ConcordClient()
    @StateObject private var proxyStore: ProxyStore
    @StateObject private var configStore = ConfigStore()
    @StateObject private var trafficStore: TrafficStore
    @StateObject private var connectionStore: ConnectionStore
    @StateObject private var logStore: LogStore
    @StateObject private var profileStore: ProfileStore
    @StateObject private var ruleStore: RuleStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var dnsStore: DnsStore
    @StateObject private var mitmStore: MitmStore
    @StateObject private var eventStore: EventStore
    @StateObject private var mitmModuleStore: MitmModuleStore
    @StateObject private var themeStore: ThemeStore
    @StateObject private var fontStore: FontStore

    init() {
        let client = ConcordClient()
        _client = StateObject(wrappedValue: client)
        _proxyStore = StateObject(wrappedValue: ProxyStore(client: client))
        _trafficStore = StateObject(wrappedValue: TrafficStore(client: client))
        _connectionStore = StateObject(wrappedValue: ConnectionStore(client: client))
        _logStore = StateObject(wrappedValue: LogStore(client: client))
        let profileStore = ProfileStore(client: client)
        _profileStore = StateObject(wrappedValue: profileStore)
        _ruleStore = StateObject(wrappedValue: RuleStore(client: client))
        _settingsStore = StateObject(wrappedValue: SettingsStore(client: client))
        _dnsStore = StateObject(wrappedValue: DnsStore(client: client))
        _mitmStore = StateObject(wrappedValue: MitmStore(client: client))
        _eventStore = StateObject(wrappedValue: EventStore(client: client))
        // A module change rewrites the merged files; re-apply the
        // active profile live when the tunnel is running, so the
        // change takes effect without a VPN restart.
        let mitmModuleStore = MitmModuleStore()
        mitmModuleStore.client = client
        mitmModuleStore.onModulesChanged = { await profileStore.reapplyActive() }
        _mitmModuleStore = StateObject(wrappedValue: mitmModuleStore)
        // The theme store is a singleton (DesignSystem reads the
        // accent from it); the app owns the same instance so a theme
        // change re-renders the root.
        _themeStore = StateObject(wrappedValue: ThemeStore.shared)
        // Same pattern for the font store: the root applies its
        // default font to the whole app (see .font below).
        _fontStore = StateObject(wrappedValue: FontStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(proxyStore)
                .environmentObject(configStore)
                .environmentObject(trafficStore)
                .environmentObject(connectionStore)
                .environmentObject(logStore)
                .environmentObject(profileStore)
                .environmentObject(ruleStore)
                .environmentObject(settingsStore)
                .environmentObject(dnsStore)
                .environmentObject(mitmStore)
                .environmentObject(eventStore)
                .environmentObject(mitmModuleStore)
                .environmentObject(themeStore)
                .environmentObject(fontStore)
                .environmentObject(TunnelManager.shared)
                .environment(\.font, fontStore.rootFont)
                .onOpenURL { url in
                    Task { await handleOpenURL(url) }
                }
        }
    }

    /// Handles the `concord://` URL scheme (see ShortcutsView): the
    /// fallback the Shortcuts intents name when they cannot act
    /// without the app. concord://vpn/on|off|toggle and
    /// concord://mode/rule|global|direct.
    @MainActor
    private func handleOpenURL(_ url: URL) async {
        guard url.scheme == "concord", let host = url.host else { return }
        let action = url.pathComponents.dropFirst().first
        if host == "vpn" {
            switch action {
            case "on":
                try? await TunnelManager.shared.start()
            case "off":
                await TunnelManager.shared.stop()
            case "toggle":
                if TunnelManager.shared.isRunning {
                    await TunnelManager.shared.stop()
                } else {
                    try? await TunnelManager.shared.start()
                }
            default:
                break
            }
        } else if host == "mode", let raw = action,
                  let mode = OutboundMode(rawValue: raw) {
            settingsStore.mode = mode
            settingsStore.save()
            await settingsStore.applyGeneralToCore()
        }
    }
}
