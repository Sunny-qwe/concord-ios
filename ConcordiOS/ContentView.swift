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
    /// Drives the sliding grey pill behind the selected tab in the
    /// floating bar (matchedGeometryEffect): the pill glides to the
    /// tapped tab inside the same 0.3 s ease-out transaction that
    /// slides the page, like FlClash's PageView + dock indicator.
    @Namespace private var tabPillNamespace
    // T1: the TrafficStore 1 s timer had no stop() caller and ran
    // forever, even in the background — waking the app every
    // second to RPC a (usually dead) core.
    @Environment(\.scenePhase) private var scenePhase
    /// The 20-minute subscription auto-update timer (S8): a
    /// Combine cancellable held in @State so it lives as long as
    /// the root view and is cancelled with it.
    @State private var profileUpdateTimer: AnyCancellable?
    @AppStorage("ConcordiOS.geoAutoUpdate") private var geoAutoUpdate = true
    @AppStorage("ConcordiOS.geoAutoUpdateHours") private var geoAutoUpdateHours = 24.0
    /// Tab animation (upstream home.dart tabAnimation: slide/fade).
    /// Slide is the default 0.3 s ease-out PageView; fade cross-fades
    /// the pages instead. The picker lives in ThemePickerView and
    /// writes themeStore.tabAnimation — read it directly here. (An
    /// earlier @AppStorage bool in this spot was never written by
    /// anything, so the fade setting did nothing; v0.2.54 wires it
    /// to the theme store.) The fade duration/curve are upstream
    /// prism_ui values and unverifiable from these checkouts, so
    /// fade reuses the 0.3 s slide duration.
    private var tabAnimationFade: Bool { themeStore.tabAnimation == .fade }

    /// App version from the bundle (Info.plist
    /// CFBundleShortVersionString) for the environment watermark —
    /// never hardcoded, so it tracks the bumped version.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Group {
            if themeStore.navBarStyle == .docked {
                // Docked: the same sliding/fading page container as
                // floating (upstream home.dart always slides via the
                // same PageView regardless of bar style — a TabView
                // here was an instant jump with no transition). The
                // bar below is a plain system-style bar instead of
                // the floating capsule.
                slidingTabView
                    .tint(themeStore.accentColor)
                    .safeAreaInset(edge: .bottom) {
                        dockedTabBar
                    }
            } else {
                // Floating capsule bar (default, reference bottom bar).
                // FlClash home.dart: a PageView (300 ms ease-out slide,
                // pages kept alive) — NOT a TabView, whose switch is an
                // instant jump with no transition and no shared pill.
                slidingTabView
                    .toolbar(.hidden, for: .tabBar)
                    .tint(themeStore.accentColor)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 6) {
                            // Environment watermark (FlClash 显示环境水印）:
                            // a faint version label just above the
                            // floating bar. The toggle itself lives in
                            // SettingsStore.showEnvironmentWatermark
                            // (default true); non-interactive so it
                            // never blocks taps on the pages below.
                            if settingsStore.showEnvironmentWatermark {
                                Text("Concord iOS v\(appVersion)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(.label))
                                    .opacity(0.35)
                                    .allowsHitTesting(false)
                            }
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
                    // Audit B9: stamp the update time only when all
                    // three kinds actually succeeded. geoUpdate
                    // reports through lastError (nil on success, set
                    // on failure — e.g. VPN off -> notRunning), so a
                    // failed kind must not stamp the time, or the
                    // 24 h interval would suppress the retry.
                    var geoAllSucceeded = true
                    for kind in ["MMDB", "ASN", "GEOSITE"] {
                        await ruleStore.geoUpdate(kind: kind)
                        if ruleStore.lastError != nil { geoAllSucceeded = false }
                    }
                    if geoAllSucceeded {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ConcordiOS.geoLastUpdate")
                    }
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
        // T1: stop the TrafficStore 1 s timer when the app goes to
        // the background, restart it on foreground. start() is
        // idempotent (it stops first) and re-fires one immediate
        // refresh / probe / memory read.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: trafficStore.start()
            case .background: trafficStore.stop()
            default: break
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
    @ViewBuilder
    private func pageView(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard:
            DashboardView(onSelectTab: { selectTab($0) })
        case .proxies:
            ProxiesView()
        case .profiles:
            ProfilesView()
        case .tools:
            ToolsView()
        }
    }

    /// Floating-style page container: FlClash's PageView in SwiftUI.
    /// All four pages are mounted once and kept alive (FlClash
    /// KeepScope), so switching never rebuilds a page; the selected
    /// page slides in with a 0.3 s ease-out (FlClash kTabScrollDuration
    /// = 300 ms, Curves.easeOut), and off-screen pages are disabled
    /// (FlClash TickerMode / ExcludeFocus on inactive pages). With
    /// the fade animation on, the pages stack and cross-fade instead
    /// (upstream tabAnimation == fade).
    private var slidingTabView: some View {
        GeometryReader { geo in
            if tabAnimationFade {
                ZStack {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        pageView(for: tab)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(selectedTab == tab ? 1 : 0)
                            .disabled(selectedTab != tab)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        pageView(for: tab)
                            .frame(width: geo.size.width)
                            .disabled(selectedTab != tab)
                    }
                }
                .offset(x: -CGFloat(selectedTab.rawValue) * geo.size.width)
            }
        }
        .clipped()
        // Root backdrop (v0.2.56): every tab page is a NavigationStack
        // that paints ConcordTheme.pageBackground only on its inner
        // content (inside the safe area), so nothing painted the
        // status-bar strip — the UIWindow default (white in light
        // mode) showed through as a white band on every page
        // (IMG_1178). Painting the same theme-aware page colour
        // edge-to-edge behind the whole tab container removes the
        // strip on all four tabs and on every pushed page (they all
        // sit inside this container), and it always matches the
        // pages exactly — systemGroupedBackground in light/dark,
        // black in pure-black dark mode — so there is no seam.
        .background(ConcordTheme.pageBackground.ignoresSafeArea())
    }

    /// FlClash _HomePageView._toPage: animateToPage with a 300 ms
    /// ease-out. A jump of more than one page first parks (no
    /// animation) on the adjacent page so no intermediate page
    /// flashes past, then slides to the target — the async hop lets
    /// the parked frame paint before the slide starts. A fade needs
    /// no parking: pages cross-fade in place.
    private func selectTab(_ tab: AppTab) {
        guard tab != selectedTab else { return }
        if tabAnimationFade {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedTab = tab
            }
            return
        }
        let distance = abs(tab.rawValue - selectedTab.rawValue)
        if distance > 1 {
            let adjacentRaw = tab.rawValue > selectedTab.rawValue
                ? selectedTab.rawValue + 1
                : selectedTab.rawValue - 1
            let adjacent = AppTab(rawValue: adjacentRaw) ?? tab
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { selectedTab = adjacent }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.selectedTab = tab
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                selectedTab = tab
            }
        }
    }

    /// A tap on a bar item: switch tabs, or — when the tab is already
    /// selected — scroll it to the top. Upstream ToolsView listens
    /// for the Tools page being re-selected and jumps its scroll
    /// controller to 0 (tools.dart:41-48); only the Tools listener
    /// was verified upstream, so only Tools re-taps scroll.
    private func tapTab(_ tab: AppTab) {
        if tab == selectedTab {
            if tab == .tools {
                NotificationCenter.default.post(name: .toolsScrollToTop, object: nil)
            }
            return
        }
        selectTab(tab)
    }

    /// Docked system-style bar (FlClash 导航栏样式 -> 停靠）: plain
    /// icons + labels on the system background with a top hairline,
    /// driving the same sliding container as the floating bar.
    private var dockedTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { tapTab(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selectedTab == tab ? ConcordTheme.accent : ConcordTheme.tabUnselected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    /// Floating white capsule bar (reference bottom bar): the selected
    /// tab gets a solid accent capsule with a white icon + label
    /// (v0.2.68 — was a grey capsule with a blue icon; the video's
    /// selected tab is a solid magenta capsule, white on it).
    private var floatingTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { tapTab(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(ConcordTheme.tabSelectedFill)
                                .matchedGeometryEffect(id: "tabPill", in: tabPillNamespace)
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? .white : ConcordTheme.tabUnselected)
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
