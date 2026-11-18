import SwiftUI

// MARK: - Main navigation (reference screenshots IMG_1082 / IMG_1083)
// Four tabs — 仪表盘 / 代理 / 配置 / 工具 — in a floating white
// capsule bar. The native tab bar is hidden; the bar below is the
// only tab UI. Rules / Connections / Logs / MITM / Settings are not
// gone: they live under the 工具 tab (see ToolsView.swift).

/// The four main tabs.
enum AppTab: Int, CaseIterable {
    case dashboard = 0
    case proxies = 1
    case profiles = 2
    case tools = 3

    var title: String {
        switch self {
        case .dashboard: return "仪表盘"
        case .proxies: return "代理"
        case .profiles: return "配置"
        case .tools: return "工具"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .proxies: return "globe"
        case .profiles: return "doc.text.fill"
        case .tools: return "briefcase.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var selectedTab: AppTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(onSelectTab: { selectedTab = $0 })
                .tag(AppTab.dashboard)
                .tabItem { Label("仪表盘", systemImage: "square.grid.2x2.fill") }
            ProxiesView()
                .tag(AppTab.proxies)
                .tabItem { Label("代理", systemImage: "globe") }
            ProfilesView()
                .tag(AppTab.profiles)
                .tabItem { Label("配置", systemImage: "doc.text.fill") }
            ToolsView()
                .tag(AppTab.tools)
                .tabItem { Label("工具", systemImage: "briefcase.fill") }
        }
        .toolbar(.hidden, for: .tabBar)
        .tint(themeStore.accentColor)
        .preferredColorScheme(themeStore.colorScheme)
        .safeAreaInset(edge: .bottom) {
            floatingTabBar
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
        .task {
            // Load the first snapshot for every page once, like FlClash
            // does when the home page mounts.
            await proxyStore.refresh()
            await ruleStore.refresh()
            await connectionStore.refresh()
            await logStore.refresh()
            trafficStore.start()
            // "自动更新订阅" is a real switch now: refresh remote
            // profiles on launch (updateAll re-applies the active one).
            if settingsStore.autoUpdateProfiles {
                await profileStore.updateAll()
            }
        }
        .onChange(of: client.mode) { _, _ in
            Task {
                await proxyStore.refresh()
                await ruleStore.refresh()
                await connectionStore.refresh()
                await logStore.refresh()
            }
        }
    }

    /// Floating white capsule bar (reference bottom bar): the selected
    /// tab gets a pale capsule behind a blue icon + label.
    private var floatingTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab
                            ? ConcordTheme.tabSelectedFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 22)
                    )
                    .foregroundStyle(selectedTab == tab ? ConcordTheme.accent : ConcordTheme.tabUnselected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 32))
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}
