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

    init() {
        let client = ConcordClient()
        _client = StateObject(wrappedValue: client)
        _proxyStore = StateObject(wrappedValue: ProxyStore(client: client))
        _trafficStore = StateObject(wrappedValue: TrafficStore(client: client))
        _connectionStore = StateObject(wrappedValue: ConnectionStore(client: client))
        _logStore = StateObject(wrappedValue: LogStore(client: client))
        _profileStore = StateObject(wrappedValue: ProfileStore(client: client))
        _ruleStore = StateObject(wrappedValue: RuleStore(client: client))
        _settingsStore = StateObject(wrappedValue: SettingsStore(client: client))
        _dnsStore = StateObject(wrappedValue: DnsStore(client: client))
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
                .environmentObject(TunnelManager.shared)
        }
    }
}
