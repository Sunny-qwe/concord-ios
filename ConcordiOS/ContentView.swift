import SwiftUI

// MARK: - FlClash-like navigation (mobile)
// FlClash (lib/views/navigation.dart) navigates between:
//   Dashboard, Proxies, Profiles, Requests, DNS, Resources, Logs, Tools.
// On iOS the tab bar carries the main pages; Requests is the Connections
// tab, DNS / Resources / Tools live under Settings, matching FlClash's
// "More" menu on mobile.

struct ContentView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var client: ConcordClient

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("仪表盘", systemImage: "gauge.with.dots.needle.33percent") }
            ProxiesView()
                .tabItem { Label("代理", systemImage: "globe") }
            ProfilesView()
                .tabItem { Label("订阅", systemImage: "list.clipboard") }
            RulesView()
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
            ConnectionsView()
                .tabItem { Label("连接", systemImage: "arrow.left.arrow.right") }
            LogsView()
                .tabItem { Label("日志", systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gear") }
        }
        .task {
            // Load the first snapshot for every page once, like FlClash
            // does when the home page mounts.
            await proxyStore.refresh()
            await ruleStore.refresh()
            await connectionStore.refresh()
            await logStore.refresh()
            trafficStore.start()
        }
        .onChange(of: client.mode) { _ in
            Task {
                await proxyStore.refresh()
                await ruleStore.refresh()
                await connectionStore.refresh()
                await logStore.refresh()
            }
        }
    }
}
