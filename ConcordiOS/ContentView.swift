import SwiftUI
import Combine

// MARK: - Main navigation (reference screenshots IMG_1082 / IMG_1083)
// Four tabs — 仪表盘 / 代理 / 配置 / 工具 — in a floating white
// capsule bar. The native tab bar is hidden; the bar below is the
// only tab UI. Rules / Logs / IP quality / Shortcuts live under
// the 工具 → 常规 page (see ToolsView.swift / SettingsView.swift).

/// The four main tabs.
enum AppTab: Int, CaseIterable {
    case dashboard = 0
    case proxies = 1
    case profiles = 2
    case tools = 3

    var title: String {
        switch self {
        case .dashboard: return "tab.dashboard".l10n
        case .proxies: return "tab.proxies".l10n
        case .profiles: return "tab.profiles".l10n
        case .tools: return "tab.tools".l10n
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
    @State private var updateAlertMessage: String?
    /// The 20-minute subscription auto-update timer (S8): a
    /// Combine cancellable held in @State so it lives as long as
    /// the root view and is cancelled with it.
    @State private var profileUpdateTimer: AnyCancellable?
    @AppStorage("ConcordiOS.geoAutoUpdate") private var geoAutoUpdate = false
    @AppStorage("ConcordiOS.geoAutoUpdateHours") private var geoAutoUpdateHours = 24.0

    var body: some View {
        Group {
            if themeStore.navBarStyle == .docked {
                // Docked: the system tab bar (FlClash: 导航栏样式 ->
                // 停靠）.
                tabView
                    .tint(themeStore.accentColor)
            } else {
                // Floating capsule bar (default, reference bottom bar).
                tabView
                    .toolbar(.hidden, for: .tabBar)
                    .tint(themeStore.accentColor)
                    .safeAreaInset(edge: .bottom) {
                        floatingTabBar
                            .padding(.horizontal, 16)
                            // Reference bar bottom sits 34pt above the screen
                            // bottom (810pt on an 844pt screen); the safe-area
                            // inset already supplies those 34pt on a home-
                            // indicator phone, so only 4pt extra padding is
                            // needed. (Fixed 4pt: there is no safe-area
                            // environment value in SwiftUI, so the previous
                            // property wrapper did not compile.)
                            .padding(.bottom, 4)
                    }
            }
        }
        .preferredColorScheme(themeStore.colorScheme)
        .environment(\.dynamicTypeSize, themeStore.dynamicTypeSize ?? .large)
        .task {
            // S2 (config B2): make sure the shared files the
            // extension reads (dns.json / sniffer.json /
            // general.json / tunnel.json / mitm.json) exist before
            // anything boots the core — a fresh install without
            // them makes the core run its own defaults (DNS
            // disabled) instead of the UI's. Only missing files
            // are written; existing ones are never overwritten.
            settingsStore.ensureSharedFilesExist()
            // Load the first snapshot for every page once, like FlClash
            // does when the home page mounts.
            await proxyStore.refresh()
            await ruleStore.refresh()
            await connectionStore.refresh()
            await logStore.refresh()
            trafficStore.start()
            // Sync the subscription-download flags into ProfileStore
            // (they live in SettingsStore's saved blob).
            profileStore.checkCertificate = settingsStore.checkCertificate
            profileStore.autoCloseConnections = settingsStore.autoCloseConnections
            // S8: the global auto-update switch for
            // updateDueProfiles(), synced the same way.
            profileStore.globalAutoUpdateEnabled = settingsStore.autoUpdateProfiles
            // "自动更新订阅" is a real switch now: update only the
            // URL profiles that are actually due (global switch +
            // per-profile switch + interval), not every profile on
            // every launch (S8: updateAll() updated all of them).
            if settingsStore.autoUpdateProfiles {
                await profileStore.updateDueProfiles()
            }
            // S8: 20-minute timer (FlClash auto-update scheduler):
            // re-check due profiles while the app stays open.
            // updateDueProfiles() itself refuses to do anything
            // while the global switch is off, so no extra gating
            // is needed here.
            profileUpdateTimer = Timer.publish(every: 1200, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    Task { await profileStore.updateDueProfiles() }
                }
            // Geo auto-update (ResourcesView setting): refresh the
            // three Geo databases when the interval has elapsed.
            if geoAutoUpdate {
                let last = UserDefaults.standard.double(forKey: "ConcordiOS.geoLastUpdate")
                if last == 0 || Date().timeIntervalSince1970 - last > geoAutoUpdateHours * 3600 {
                    for kind in ["MMDB", "ASN", "GEOSITE"] {
                        await ruleStore.geoUpdate(kind: kind)
                    }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ConcordiOS.geoLastUpdate")
                }
            }
            // Auto-run: start the VPN on launch when the user asked
            // for it and a profile is ready.
            if settingsStore.autoRun, profileStore.activeProfile != nil, !proxyStore.isRunning {
                await proxyStore.toggle()
            }
            // Auto-check for updates on launch.
            if settingsStore.autoCheckUpdate {
                if let result = await UpdateChecker.check(), result.isNew {
                    updateAlertMessage = "发现新提交：\(result.message)"
                }
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
        // NOTE (audit A1): a node picked while the VPN was off is
        // applied on the tunnel-connected edge by ProxyStore's own
        // tunnel-status subscription (applyPendingSelectionsOnConnect,
        // with a bounded retry) — there is deliberately NO second
        // trigger here. An earlier .onChange(of: isRunning) trigger
        // fired the same refresh on the .connecting edge too, racing
        // the subscription's own refresh.
        .onChange(of: settingsStore.autoUpdateProfiles) { _, enabled in
            // S8: keep the due-update gate in sync when the user
            // flips the switch in Settings while the app runs.
            profileStore.globalAutoUpdateEnabled = enabled
        }
        .alert("发现更新", isPresented: Binding(
            get: { updateAlertMessage != nil },
            set: { if !$0 { updateAlertMessage = nil } }
        )) {
            Button("common.ok".l10n, role: .cancel) {}
        } message: {
            if let updateAlertMessage {
                Text(updateAlertMessage)
            }
        }
    }

    /// The four tabs (shared by the floating and docked bar styles).
    private var tabView: some View {
        TabView(selection: $selectedTab) {
            DashboardView(onSelectTab: { selectedTab = $0 })
                .tag(AppTab.dashboard)
                .tabItem { Label("tab.dashboard".l10n, systemImage: "square.grid.2x2.fill") }
            ProxiesView()
                .tag(AppTab.proxies)
                .tabItem { Label("tab.proxies".l10n, systemImage: "globe") }
            ProfilesView()
                .tag(AppTab.profiles)
                .tabItem { Label("tab.profiles".l10n, systemImage: "doc.text.fill") }
            ToolsView()
                .tag(AppTab.tools)
                .tabItem { Label("tab.tools".l10n, systemImage: "briefcase.fill") }
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
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        selectedTab == tab
                            ? ConcordTheme.tabSelectedFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 24)
                    )
                    .foregroundStyle(selectedTab == tab ? ConcordTheme.accent : ConcordTheme.tabUnselected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        // White like the reference (secondarySystemBackground reads
        // grey against the grouped page background and makes the
        // bar look like it runs into the screen edge).
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 30))
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}
