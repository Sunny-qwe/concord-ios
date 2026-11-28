import SwiftUI
import Combine

// MARK: - Main navigation (reference screenshots IMG_1082 / IMG_1083)
// Four tabs — 仪表盘 / 代理 / 配置 / 工具 — in a floating
// transparent bar (v0.2.103: no container background or shadow —
// MuYu IMG_1281). The native tab bar is hidden; the bar below is the
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
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var dnsStore: DnsStore
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var clashProviderStore: ClashProviderStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var themeStore: ThemeStore
    // T-D1 (v0.2.138): the picked app language. The root Group
    // below is re-identified on every language change, so the
    // whole tab container (pages + floating tab bar) remounts
    // and re-renders in the new language — the SwiftUI
    // equivalent of upstream's whole-app rebuild on a locale
    // change (tools.dart: the locale provider rebuilds the app).
    // ContentView's own @State (selectedTab, fade state, stats
    // destination) survives: it lives in this struct, above the
    // re-identified Group. The pages' own @State resets, as it
    // does upstream.
    @EnvironmentObject private var localization: LocalizationManager

    @State private var selectedTab: AppTab = .dashboard
    /// v0.2.167 (B): the shared push depth (NavDepthStore) — the
    /// tab bar hides while the selected tab has a pushed page.
    @ObservedObject private var navDepthStore = NavDepthStore.shared
    /// Sequential fade state (v0.2.136, re-do of v0.2.128): the
    /// fade is two 0.15 s steps — current page out, switch with no
    /// animation, new page in — so the two pages are never visible
    /// at once (a cross-fade shows both mid-transition: the double
    /// exposure). fadeToken supersedes a stale fade when the user
    /// taps a second tab mid-transition.
    @State private var fadeOpacity = 1.0
    @State private var fadeToken = 0
    /// The Dashboard stat-cell destination (v0.2.111): owned here,
    /// not in DashboardView — the .dns destination renders as a
    /// custom overlay at this root (above the floating tab bar),
    /// so the state has to live above the tab bar. Passed down to
    /// DashboardView as a binding; .live / .recent still use
    /// DashboardView's system .sheet, .dns uses the overlay below.
    @State private var statsDestination: StatsDestination?
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
    /// Slide is the default 0.3 s ease-out PageView; fade is a
    /// SEQUENTIAL fade (0.15 s out, switch, 0.15 s in — v0.2.136,
    /// re-do of v0.2.128), never a cross-fade: fading both pages
    /// at once shows both mid-transition (the double exposure).
    /// The picker lives in ThemePickerView and writes
    /// themeStore.tabAnimation — read it directly here. (An
    /// earlier @AppStorage bool in this spot was never written by
    /// anything, so the fade setting did nothing; v0.2.54 wires it
    /// to the theme store.) The fade duration/curve are upstream
    /// prism_ui values and unverifiable from these checkouts, so
    /// fade reuses the 0.3 s slide duration.
    private var tabAnimationFade: Bool { themeStore.tabAnimation == .fade }
    /// v0.2.167 (B): true while the selected tab has a pushed
    /// page (upstream pushed pages cover the dock entirely).
    private var isTabBarHidden: Bool { navDepthStore.isPushed(tab: selectedTab.rawValue) }

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
                        // v0.2.167 (B): no docked bar over a pushed
                        // page — same rule as the floating bar below.
                        if !isTabBarHidden {
                            dockedTabBar
                        }
                    }
            } else {
                // Floating capsule bar (default, reference bottom bar).
                // FlClash home.dart: a PageView (300 ms ease-out slide,
                // pages kept alive) — NOT a TabView, whose switch is an
                // instant jump with no transition and no shared pill.
                // v0.2.108: the bar FLOATS over the page (overlay),
                // it does not reserve a safeAreaInset strip. The
                // inset made the bottom a dead zone page content
                // could never enter, so the bar completely covered
                // whatever was below it (v0.2.107: the Dashboard's
                // bottom card hid behind the bar, while MuYu IMG_1281
                // shows it peeking out below the bar). As an overlay
                // the pages run full-height underneath and the content
                // scrolls under the bar and peeks out below it, like
                // MuYu.
                // v0.2.109: geometry follows upstream FlClash
                // v0.9.5-rs.1 NavigationDock (prism_ui, pinned
                // 8f5fc22 — MuYu pins 6c47901 with identical
                // numbers): pill 62pt (_barHeight), side margins
                // 21pt (_edgeMargin), bottom margin max(21, system
                // bottom padding) (_bottomMarginOf). The v0.2.108
                // overlay double-counted the bottom safe area: the
                // root GeometryReader is already safe-area-bounded
                // (its bottom sits at the safe area) and the overlay
                // added safeAreaInsets.bottom + 4 on top, so the bar
                // floated 72pt above the screen bottom instead of 34
                // (IMG_1294 measured: bar 711–772pt on an 844pt
                // screen) — and the bar top at 711 left the Tools
                // last card 4pt behind the bar. v0.2.109 "fixed"
                // it by putting .ignoresSafeArea(edges: .bottom)
                // on the GeometryReader — but that zeroes the
                // safe-area insets the reader reports, so
                // geo.safeAreaInsets.bottom became 0 and the
                // padding came out max(21, 0) = 21, leaving the
                // bar 13pt too low (v0.2.111 audit: bar bottom
                // 823, top 761 on an 844pt screen). v0.2.111
                // tried to fix it by keeping the reader
                // safe-area-aware (real 34) and ignoring the
                // bottom safe area on slidingTabView instead —
                // but that assumed the overlay aligns to the
                // SCREEN bottom. It does not: the overlay
                // aligns to the GeometryReader's bottom, the
                // safe-area boundary (810 on an 844pt notched
                // phone), so the padding max(21, 34) = 34
                // counted the safe area a second time and the
                // bar floated 34pt too high (IMG_1298 measured
                // v0.2.111: bar 714–775pt, bottom margin 68).
                // v0.2.112: the overlay bottom is already
                // safeArea above the screen bottom, so the
                // padding only needs the remainder of
                // upstream's max(21, safeArea) margin:
                // max(0, 21 - safeArea). Notched (34): padding
                // 0, bar bottom 810, margin 34, bar top 748 —
                // matches the reference (IMG_1299, icons centre
                // 772). Non-notched (0): padding 21, bar bottom
                // 823, margin 21. The version watermark
                // above the bar is gone (v0.2.109, user request):
                // the version shows only in Tools → About. Pages
                // carry tabBarClearance (95pt) bottom padding, so
                // the last card clears the bar at max scroll with
                // a 33pt gap.
                GeometryReader { geo in
                    slidingTabView
                        // v0.2.111: the bottom safe area is ignored
                        // HERE, on the page container — NOT on this
                        // GeometryReader (see the comment above),
                        // so the page content runs under the bar.
                        // NOTE: that does NOT move the overlay —
                        // it still aligns to this GeometryReader's
                        // bottom (the safe-area boundary, 810 on a
                        // notched 844pt screen), so the padding
                        // below is only the remainder of the
                        // upstream margin (see below).
                        .ignoresSafeArea(edges: .bottom)
                        .toolbar(.hidden, for: .tabBar)
                        .tint(themeStore.accentColor)
                        .overlay(alignment: .bottom) {
                            // v0.2.167 (B): the bar hides on pushed
                            // pages — it is a root overlay, so it
                            // would otherwise float over every
                            // pushed page, under the docked search
                            // pill (user: 底栏的位置不是搜索框的位置吗).
                            if !isTabBarHidden {
                                floatingTabBar
                                    .padding(.horizontal, 21)
                                    // Upstream NavigationDock._bottomMarginOf:
                                // max(_edgeMargin = 21, system bottom
                                // padding), measured from the SCREEN
                                // bottom. The overlay already sits
                                // safeAreaInsets.bottom above the
                                // screen bottom (the reader is
                                // safe-area-bounded), so this padding
                                // is only the remainder:
                                // max(21, safeArea) - safeArea =
                                // max(0, 21 - safeArea). Notched
                                // (34): 0, bar bottom 810, margin 34.
                                .padding(.bottom, max(0, 21 - geo.safeAreaInsets.bottom))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                }
            }
        }
        // v0.2.167 (B): animate the tab bar sliding away / back
        // on push / pop (both the floating overlay above and the
        // docked safeAreaInset below).
        .animation(.easeOut(duration: 0.25), value: isTabBarHidden)
        // T-D1 (v0.2.138): remount the tab container on a language
        // change — see the localization property above.
        .id(localization.language)
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
                    Task {
                        await profileStore.updateDueProfiles()
                        // v0.2.157: same timer drives the provider
                        // auto-update; updateDueProviders self-gates
                        // on the geo switch, like updateDueProfiles
                        // self-gates on the profile switch.
                        let changed = await clashProviderStore.updateDueProviders()
                        for id in changed { await profileStore.reapplyActiveForClashProvider(id: id) }
                    }
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
            // v0.2.157: scheduled ClashProvider auto-update
            // (upstream resources.dart autoUpdate — same launch +
            // 20-minute timer as profiles, gated on the geo
            // auto-update switch + interval inside
            // updateDueProviders). Changed records re-apply the
            // active profile when it bakes them (a no-op
            // otherwise); failures surface in
            // clashProviderStore.lastAutoUpdateError, shown on the
            // Providers page. It runs AFTER the auto-run toggle
            // (behaviour-audit B2): upstream fires autoUpdate
            // unawaited after startCore, so it can never delay
            // startup — awaiting serial provider downloads (up to
            // 30 s each) before the toggle delayed VPN auto-start
            // by up to 30 s × N due providers. (The profile
            // update above is still awaited before the toggle —
            // pre-existing S8 behaviour, not changed here.)
            if geoAutoUpdate {
                let changed = await clashProviderStore.updateDueProviders()
                for id in changed { await profileStore.reapplyActiveForClashProvider(id: id) }
            }
            // Auto-check for updates on launch (v0.2.85):
            // upstream update_status.dart installs directly
            // from the update row with NO dialog, so the old
            // "发现更新" alert is gone. The result is recorded
            // silently in the same AppStorage keys the
            // Dashboard update card reads (see DashboardView
            // checkForUpdate), so the card shows the
            // "发现新提交" pill — tapping the card opens the
            // Releases page straight away.
            if settingsStore.autoCheckUpdate {
                if let result = await UpdateChecker.check() {
                    UserDefaults.standard.set(result.sha, forKey: "ConcordiOS.update.lastSha")
                    UserDefaults.standard.set(result.message, forKey: "ConcordiOS.update.lastMessage")
                    UserDefaults.standard.set(result.date, forKey: "ConcordiOS.update.lastDate")
                    UserDefaults.standard.set(result.isNew, forKey: "ConcordiOS.update.lastIsNew")
                    UserDefaults.standard.set(true, forKey: "ConcordiOS.update.lastChecked")
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
            case .active:
                trafficStore.start()
                // v0.2.102 (MuYu parity): the app runs its own core
                // from launch while the tunnel is off, so the
                // Dashboard DNS count and the DNS sheet have live
                // records with the VPN off (MuYu's startCore at
                // bootstrap). Best-effort and never blocking: the
                // call is a no-op when the core is already running
                // the same config, and it throws (swallowed) when
                // the tunnel is up, when there is no config, or
                // when the boot fails — every caller reboots on
                // demand through ensureStarted anyway. Also fires
                // on every foreground return, which restarts the
                // core after a backgrounded idle shutdown.
                TunnelManager.shared.isAppForeground = true
                Task { try? await AppCore.shared.ensureStarted() }
            case .background:
                trafficStore.stop()
                // v0.2.102: the app is backgrounded — the in-app
                // core's 5-minute idle shutdown (TunnelManager
                // poller) applies again from here.
                TunnelManager.shared.isAppForeground = false
                // v0.2.86 item 4: upstream only shows a script
                // notification while resumed — a banner showing
                // when the app backgrounds is discarded, not kept
                // for the return.
                eventStore.dismissScriptNotification()
            default: break
            }
        }
        // v0.2.82 (stats freeze / Tools lag): pause the
        // TrafficStore 1 s Dashboard tick while the Dashboard tab
        // is not selected — all four tabs stay mounted, so the
        // tick re-rendered the Dashboard every second even on
        // Tools / Profiles. Per-node speeds keep ticking (the
        // pause only skips the traffic + engine work), and the
        // next tick after returning refreshes within 1 s.
        .onChange(of: selectedTab) { _, tab in
            trafficStore.liveTickPaused = tab != .dashboard
            // v0.2.86 item 4: pick up a script notification
            // immediately on a tab switch (the 1 s poll below only
            // fires while the Dashboard tick runs).
            Task { await eventStore.refresh() }
        }
        // v0.2.111 (DNS freeze, TOCTOU): while the DNS sheet is
        // open, DnsStore defers background publishes — a publish
        // landing mid-presentation is a freeze suspect. The flag
        // is checked at publish time inside refresh(), so even a
        // refresh already in flight when the user taps defers.
        // Closing the sheet applies the newest deferred result.
        .onChange(of: statsDestination) { _, destination in
            dnsStore.setPublishSuspended(destination == .dns)
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
        // v0.2.86 item 4 (MITM `$notification.post` banner):
        // poll the events snapshot on TrafficStore's 1 s tick — NO
        // new permanent Timer (the snapshot file is the buffer, so
        // a new script notification is only visible on a refresh).
        // `$current` fires on every tick while the Dashboard tab is
        // selected; on other tabs the tick skips the traffic
        // refresh (liveTickPaused) but the per-node sampler still
        // runs, so `$nodeSpeeds` covers those tabs while traffic
        // is flowing (a script can only post while requests flow).
        // EventStore.refresh() itself detects new
        // `scriptNotification` entries and raises the banner; the
        // banner host lives in ScriptNotificationBanner.swift.
        .onReceive(trafficStore.$current) { _ in
            Task { await eventStore.refresh() }
        }
        .onReceive(trafficStore.$nodeSpeeds) { _ in
            Task { await eventStore.refresh() }
        }
        // v0.2.86 item 4: the banner mount point — exactly one
        // overlay at the ContentView root, above the sliding tab
        // container; the banner UI itself lives in
        // ScriptNotificationBanner.swift, NOT here.
        .overlay(alignment: .top) {
            ScriptNotificationBannerHost()
        }
        // v0.2.111 (DNS freeze) / v0.2.113 (Connections freeze):
        // the stats destinations as custom overlay bottom sheets
        // at the root — attached after the tab bar in Z-order, so
        // they render ABOVE the floating tab bar exactly like the
        // system sheets did. Same content (DnsQueriesView mode
        // .sheet / ConnectionsView sheetChrome), same 28pt corners,
        // same detents (0.5625 / 0.9), same dim, drag-down-to-
        // dismiss, tap-dim-to-dismiss, ✕ dismiss. UNTESTED
        // HYPOTHESIS: the system .sheet presentation path is a
        // freeze suspect on iOS 17.6.1 — this bypasses it. DNS is
        // CONFIRMED fixed on-device (user 2026-11-25: "DNS查询现在
        // 不卡死了"); .live / .recent are not proven until they
        // hold on-device.
        // v0.2.124 (服务状态 freeze): the services card joins
        // them. The 123 diagnostic proved the sheet appeared and
        // the probe was skipped, and a static trace proves the
        // SwiftUI body cannot loop (it writes no state), so the
        // spin is in the UIKit sheet layout layer — the same fix
        // that already cured the identical DNS / .live / .recent
        // freezes. ServiceStatusSheet is unchanged inside.
        .overlay {
            if statsDestination == .services {
                ServiceStatusSheetOverlay(onDismiss: { statsDestination = nil })
            } else if let destination = statsDestination,
                      destination == .live || destination == .recent || destination == .dns {
                // The DNS stat opens the Requests page on its DNS segment
                // (upstream has no standalone DNS page — v0.2.146).
                ConnectionsSheetOverlay(
                    feed: destination == .live ? .live : .recent,
                    segment: destination == .dns ? .dns : nil,
                    onDismiss: { statsDestination = nil }
                )
                .id(destination)
            }
        }
        .animation(.easeOut(duration: 0.3), value: statsDestination != nil)
    }

    /// The four tabs (shared by the floating and docked bar styles).
    @ViewBuilder
    private func pageView(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard:
            DashboardView(onSelectTab: { selectTab($0) }, statsDestination: $statsDestination)
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
    /// the fade animation on, the pages stack and fade SEQUENTIALLY
    /// (out, switch, in — see selectTab), never cross-fading
    /// (upstream tabAnimation == fade).
    private var slidingTabView: some View {
        GeometryReader { geo in
            if tabAnimationFade {
                // v0.2.136 (re-do of v0.2.128): NO per-page
                // .background here. The container's own background
                // (below, after .clipped()) already paints the
                // status-bar strip edge-to-edge, and a background
                // placed AFTER .opacity escapes the fade — the
                // hidden pages would keep a fully opaque background
                // and the topmost one (Tools, last in ForEach
                // order) would cover the incoming page. The opacity
                // applies to the whole page subtree, so the fade
                // below is the only per-page modifier needed.
                ZStack {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        pageView(for: tab)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(selectedTab == tab ? fadeOpacity : 0)
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
    /// no parking: the pages fade sequentially in place (out 0.15 s,
    /// switch with no animation, in 0.15 s). v0.2.107: the async
    /// hop is guarded — it only completes the slide while the
    /// selection is still the parked page, so a second tap before
    /// it fires cannot be overwritten by the stale block (that
    /// landed the user on the wrong page).
    private func selectTab(_ tab: AppTab) {
        guard tab != selectedTab else { return }
        if tabAnimationFade {
            // v0.2.136 (re-do of v0.2.128): sequential fade. The
            // old cross-fade animated both pages at once, so
            // mid-transition both were half-visible — the double
            // exposure. Here the current page fades out first
            // (fadeOpacity is shared: it is 1 for the selected
            // page, 0 for the rest), the switch happens with no
            // animation while everything is invisible, then the
            // new page fades in. The token guard supersedes a
            // stale fade when the user taps a second tab before
            // the first fade's switch fires; the fade-mode guard
            // drops the pending switch if the user changed the
            // animation to slide mid-fade (a no-animation switch
            // would jump the slide offset instead).
            fadeToken += 1
            let token = fadeToken
            withAnimation(.easeInOut(duration: 0.15)) {
                fadeOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard token == self.fadeToken else { return }
                guard self.tabAnimationFade else {
                    // The user switched to slide mid-fade: the
                    // slide branch ignores fadeOpacity, but restore
                    // it so a later switch back to fade does not
                    // start with an invisible page. (A superseded
                    // fade — token mismatch above — must NOT restore:
                    // the newer fade owns fadeOpacity.)
                    self.fadeOpacity = 1
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.selectedTab = tab }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.fadeOpacity = 1
                }
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
                // v0.2.107: only complete the parked slide while
                // the selection is still the parked page. If the
                // user tapped another tab before this block fired,
                // that tap already moved selectedTab elsewhere and
                // this stale block must do nothing — unguarded it
                // overwrote the newer selection and landed the user
                // on the wrong page.
                guard self.selectedTab == adjacent else { return }
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

    /// Floating bar (reference bottom bar): intentionally
    /// transparent — no container background, no shadow — so the
    /// page background shows through and the bar blends with the
    /// page like the MuYu reference (IMG_1281: bar #FCF8F9 vs
    /// page #F9F5F6, ~3/255 apart, looks transparent to the eye).
    /// A pure-white container was tried in v0.2.105 and rejected
    /// by the user (IMG_1288: pure-white bar #FFFFFF vs page
    /// #EBEAF0, ~20/255 apart, a clearly visible white box).
    /// The selected tab gets a LIGHT tint of the accent with a
    /// solid-accent icon + label in EVERY theme, including the
    /// default blue (MuYu IMG_1281 is a blue-theme screenshot
    /// whose selected tab pill is still light with a blue icon —
    /// the v0.2.82 inference that default blue kept a solid
    /// capsule + white icon was wrong; see
    /// ConcordTheme.tabSelectedFill / tabSelectedForeground).
    /// The sliding matchedGeometryEffect pill and the page
    /// slide/fade switching are untouched.
    private var floatingTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { tapTab(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(ConcordTheme.tabSelectedFill)
                                .matchedGeometryEffect(id: "tabPill", in: tabPillNamespace)
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? ConcordTheme.tabSelectedForeground : ConcordTheme.tabUnselected)
                }
                .buttonStyle(.plain)
            }
        }
        // Upstream NavigationDock: pill 62pt (_barHeight), inner
        // padding 4 (_barPadding); label 10, gap 2. The icon font
        // is 22, NOT upstream's _iconSize 28: Flutter's GlyphIcon
        // at size 28 renders the visible glyph at only ~22pt (the
        // glyph path has internal padding inside its 28pt box),
        // while an SF Symbol at font size 28 renders at ~28.6pt
        // visual — so matching the number made ours ~7pt bigger
        // than MuYu's (~21.8pt measured). 22pt font renders at
        // ~22.4pt visual (20pt font measured ~20.4pt), matching
        // MuYu's visual size. The frame pins the pill to exactly
        // 62 regardless of font metrics; the content centers
        // inside it.
        .padding(4)
        .frame(height: 62)
        // White floating container, no shadow (v0.2.107): the bar
        // background is white like the MuYu reference; the
        // light-gray layer behind it is removed — no shadow, no
        // blur, no extra background. The page shows around the
        // container. (A fully transparent bar was tried in
        // v0.2.106 and rejected by the user.)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 30))
    }
}

/// v0.2.113 (Connections freeze): overlay for
/// the .live / .recent / .dns stats destinations — same mechanics, same
/// look (28pt corners, detents 0.5625 / 0.9, dim, drag-down-to-
/// dismiss, tap-dim-to-dismiss, ✕ dismiss, keyboard handling for
/// the floating search bar's TextField). The nested
/// .sheet(item: $detail) inside ConnectionsView (connection
/// detail) stays a system sheet, like the DNS entry detail.
///
/// Drag behaviour (v0.2.114): the gesture
/// lives on the content view's header ONLY — never on the sheet
/// container, which captured every vertical drag and left the list
/// unscrollable on v0.2.113. Drag up on the header grows toward
/// 0.9, drag down follows the finger; on release a far drag
/// (>140pt) dismisses, a short drag down from the tall detent
/// steps back to 0.5625, a clear upward drag (or an upward fling)
/// settles at 0.9 (v0.2.119), otherwise it snaps to the nearest
/// detent. v0.2.119: dragging the LIST up at the top grows the
/// sheet too, via the UIKit pan bridge (SheetListDragPan) — the
/// v0.2.118 simultaneous-gesture mechanism never delivered and
/// is gone.
///
/// Keyboard: the sheet's floating search bar opens the keyboard,
/// which would cover it (the system sheet moved out of the way
/// for free). The bottom strip under the content grows to the
/// keyboard height while it is up, and the sheet auto-expands to
/// the 0.9 detent (restored when the keyboard hides), so the
/// search bar stays visible above the keyboard.
private struct ConnectionsSheetOverlay: View {
    let feed: ConnectionsView.ConnectionFeed
    /// Requests segment to open on (nil = connections); the Dashboard DNS
    /// stat opens the overlay on .dns (upstream has no standalone DNS page).
    let segment: ConnectionsView.RequestsSegment?
    let onDismiss: () -> Void

    /// Current detent, as a fraction of screen height.
    @State private var heightFraction: CGFloat = 0.5625
    /// Live drag offset (downward drags slide the sheet down).
    @State private var dragOffset: CGFloat = 0
    /// Detent the drag started from; captured on the first
    /// onChanged so upward drags grow from the right base.
    @State private var dragStartFraction: CGFloat = 0.5625
    @State private var dragging = false
    /// Keyboard height while the search field is focused, 0 else.
    @State private var keyboardHeight: CGFloat = 0
    /// Whether the keyboard auto-expanded the sheet (restored on
    /// hide); false when the user expanded it themselves.
    @State private var keyboardExpandedSheet = false

    private let minFraction: CGFloat = 0.5625
    private let maxFraction: CGFloat = 0.9

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .transition(.opacity)
                VStack(spacing: 0) {
                    // v0.2.114: the sheet-drag gesture lives on
                    // ConnectionsView's header (via these
                    // callbacks), NOT on this container — a
                    // .gesture here captured every vertical drag
                    // and the list never scrolled.
                    ConnectionsView(initialFeed: feed, initialSegment: segment, sheetChrome: true, onClose: onDismiss,
                                    onSheetDragChanged: { sheetDragChanged($0, screenHeight: geo.size.height) },
                                    onSheetDragEnded: { sheetDragEnded($0, velocity: $1) })
                    // Bottom strip: the home-indicator safe area
                    // normally, the keyboard height while the
                    // search field is focused — the sheet's
                    // background extends to the screen bottom in
                    // both cases, like the system sheet.
                    Color.clear
                        .frame(height: keyboardHeight > 0 ? keyboardHeight : geo.safeAreaInsets.bottom)
                }
                .frame(width: geo.size.width, height: geo.size.height * heightFraction)
                .background(ConcordTheme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .offset(y: dragOffset)
                .transition(.move(edge: .bottom))
            }
            .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let height = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            guard height > 0 else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = height
                if heightFraction < maxFraction {
                    keyboardExpandedSheet = true
                    heightFraction = maxFraction
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
                if keyboardExpandedSheet {
                    keyboardExpandedSheet = false
                    heightFraction = minFraction
                }
            }
        }
    }

    /// Sheet-drag handlers (v0.2.114): driven by the drag gesture
    /// on ConnectionsView's header (see the callbacks passed
    /// above) and, since v0.2.119, by the UIKit pan bridge on the
    /// list (SheetListDragPan) — NOT by a gesture on this
    /// container. Same rules as before: drag up grows toward 0.9,
    /// drag down follows the finger; on release a far drag
    /// (>140pt) dismisses, a short drag down from the tall detent
    /// steps back to 0.5625, a clear upward drag (net translation
    /// <= -20pt) or an upward fling (release velocity <= -200
    /// pt/s) settles at 0.9 — the old nearest-detent snap sent any
    /// upward drag under ~180pt back to the short detent, so
    /// dragging the list up never expanded the sheet — otherwise
    /// it snaps to the nearest detent.
    private func sheetDragChanged(_ translation: CGFloat, screenHeight: CGFloat) {
        if !dragging {
            dragging = true
            dragStartFraction = heightFraction
        }
        if translation < 0 {
            // Drag up: grow toward the 0.9 detent.
            dragOffset = 0
            heightFraction = min(maxFraction, max(minFraction, dragStartFraction - translation / screenHeight))
        } else {
            // Drag down: follow the finger; the detent
            // only changes on release.
            dragOffset = translation
        }
    }

    private func sheetDragEnded(_ translation: CGFloat, velocity: CGFloat = 0) {
        dragging = false
        if translation > 140 {
            // Dragged far down: dismiss (the overlay
            // removal transition continues the slide).
            onDismiss()
        } else if heightFraction >= maxFraction - 0.01, translation > 40 {
            // At the tall detent, a short drag down steps
            // back to the short detent, not a dismiss.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = minFraction
                dragOffset = 0
            }
        } else if translation <= -20 || velocity <= -200 {
            // v0.2.119: a clear upward drag — or an upward fling,
            // even a short one — settles at the tall detent.
            // velocity is pt/s, upward negative; the header
            // passes 0 (DragGesture.Value exposes no public
            // velocity) and relies on the translation branch,
            // the UIKit list bridge passes the real release
            // velocity.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = maxFraction
                dragOffset = 0
            }
        } else {
            // Snap to the nearest detent.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = heightFraction > (minFraction + maxFraction) / 2 ? maxFraction : minFraction
                dragOffset = 0
            }
        }
    }
}

/// v0.2.124 (服务状态 freeze): sibling of
/// ConnectionsSheetOverlay for the services card. The system
/// .sheet presentation froze on 123 — the 123 diagnostic proved
/// the sheet appeared and the probe was skipped, and a static
/// trace proves the SwiftUI body cannot loop (it writes no
/// state; .onAppear writes only UserDefaults; .task returns
/// before any @State write when services is empty), so the spin
/// is in the UIKit sheet layout layer (UISheetPresentationController
/// + fractional detents), which this bypasses — the same fix that
/// already cured the identical DNS / .live / .recent freezes
/// (v0.2.111 / v0.2.113, DNS confirmed on-device, .live / .recent
/// holding). Same content (ServiceStatusSheet), same 28pt corners,
/// same detents (0.5625 / 0.9), same dim, drag-down-to-dismiss,
/// tap-dim-to-dismiss, ✕ dismiss. No keyboard handling: the sheet
/// has no TextField (the nested manage sheet is a separate system
/// sheet, like the DNS entry detail).
private struct ServiceStatusSheetOverlay: View {
    let onDismiss: () -> Void

    /// Current detent, as a fraction of screen height.
    @State private var heightFraction: CGFloat = 0.5625
    /// Live drag offset (downward drags slide the sheet down).
    @State private var dragOffset: CGFloat = 0
    /// Detent the drag started from; captured on the first
    /// onChanged so upward drags grow from the right base.
    @State private var dragStartFraction: CGFloat = 0.5625
    @State private var dragging = false

    private let minFraction: CGFloat = 0.5625
    private let maxFraction: CGFloat = 0.9

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .transition(.opacity)
                VStack(spacing: 0) {
                    ServiceStatusSheet(
                        onClose: onDismiss,
                        onDragChanged: { sheetDragChanged($0, screenHeight: geo.size.height) },
                        onDragEnded: { sheetDragEnded($0, velocity: $1) }
                    )
                    // Bottom strip: the home-indicator safe area —
                    // the sheet's background extends to the screen
                    // bottom, like the system sheet.
                    Color.clear
                        .frame(height: geo.safeAreaInsets.bottom)
                }
                .frame(width: geo.size.width, height: geo.size.height * heightFraction)
                .background(ConcordTheme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .offset(y: dragOffset)
                .transition(.move(edge: .bottom))
            }
            .ignoresSafeArea()
        }
    }

    /// Sheet-drag handlers (same rules as
    /// ConnectionsSheetOverlay): driven by the drag gesture on
    /// the sheet's header (via DashboardBottomSheet's callbacks)
    /// — NOT by a gesture on this container. Drag up grows toward
    /// 0.9, drag down follows the finger; on release a far drag
    /// (>140pt) dismisses, a short drag down from the tall detent
    /// steps back to 0.5625, a clear upward drag (net translation
    /// <= -20pt) or an upward fling (release velocity <= -200
    /// pt/s) settles at 0.9, otherwise it snaps to the nearest
    /// detent. The header passes velocity 0 (DragGesture.Value
    /// exposes no public velocity) and relies on the translation
    /// branches.
    private func sheetDragChanged(_ translation: CGFloat, screenHeight: CGFloat) {
        if !dragging {
            dragging = true
            dragStartFraction = heightFraction
        }
        if translation < 0 {
            // Drag up: grow toward the 0.9 detent.
            dragOffset = 0
            heightFraction = min(maxFraction, max(minFraction, dragStartFraction - translation / screenHeight))
        } else {
            // Drag down: follow the finger; the detent
            // only changes on release.
            dragOffset = translation
        }
    }

    private func sheetDragEnded(_ translation: CGFloat, velocity: CGFloat = 0) {
        dragging = false
        if translation > 140 {
            // Dragged far down: dismiss (the overlay
            // removal transition continues the slide).
            onDismiss()
        } else if heightFraction >= maxFraction - 0.01, translation > 40 {
            // At the tall detent, a short drag down steps
            // back to the short detent, not a dismiss.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = minFraction
                dragOffset = 0
            }
        } else if translation <= -20 || velocity <= -200 {
            // A clear upward drag — or an upward fling,
            // even a short one — settles at 0.9.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = maxFraction
                dragOffset = 0
            }
        } else {
            // Snap to the nearest detent.
            withAnimation(.easeOut(duration: 0.25)) {
                heightFraction = heightFraction > (minFraction + maxFraction) / 2 ? maxFraction : minFraction
                dragOffset = 0
            }
        }
    }
}
