import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Dashboard bottom sheets (v0.2.56, MuYu iOS build)
//
// Every dashboard card opens a bottom sheet in the MuYu build:
// a drawer sliding up from the bottom with a drag handle on top,
// an ✕ close button top-left, a centred title, and action buttons
// top-right (one action: its own circle; two actions: one pill).
// DashboardBottomSheet is that chrome;
// the sheets below are the card details. Every number in them
// comes from a real source (core APIs / existing stores) — see
// each sheet's notes. Nothing here invents data.
//
// Sheets that are full pages with search/toolbars (DNS queries,
// Connections) keep their NavigationStack — their content needs
// a navigation bar — and get the drag handle + leading ✕ instead
// (wired in DashboardView).

// MARK: - Shared formatting

/// MuYu `traffic.show`: one decimal, no space ("1.1GB",
/// "713.5MB"). ConcordBytes.split already trims a ".0", so
/// number + unit is exactly MuYu's form.
func dashboardBytesNoSpace(_ value: Int64) -> String {
    let split = ConcordBytes.split(value)
    return split.number + split.unit
}

/// Rule counts the way MuYu shows them ("7.09K 条规则",
/// "759 条规则"): below 1000 plain, at/above two decimals
/// trimmed ("7.09K", "1.5K", never "7.10K").
func dashboardCompactCount(_ value: UInt64) -> String {
    if value < 1000 { return "\(value)" }
    let thousands = Double(value) / 1000
    var text = String(format: "%.2f", thousands)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text + "K"
}

/// MuYu trafficStatisticsUptimeText: "18 小时 56 分钟",
/// "18 小时" when the minutes are zero, "56 分钟" below one
/// hour, "0 分钟" at zero.
func formatCumulativeUptime(seconds: Int64) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 && minutes > 0 { return "\(hours) 小时 \(minutes) 分钟" }
    if hours > 0 { return "\(hours) 小时" }
    return "\(minutes) 分钟"
}

/// Flag emoji for a 2-letter country code ("HK" -> 🇭🇰).
/// Returns nil for anything that is not exactly two ASCII
/// letters, so a region like "" or "EU" never renders a
/// misleading flag.
func flagEmoji(countryCode: String?) -> String? {
    guard let code = countryCode?.uppercased(), code.count == 2,
          code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
    let base: UInt32 = 0x1F1E6
    let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(base + $0.value - 65) }
    guard scalars.count == 2 else { return nil }
    return String(String.UnicodeScalarView(scalars))
}

/// Display name for a probe-service registry name
/// ("chatgpt" -> "ChatGPT", "disney-plus" -> "Disney+").
/// Only the fixed registry names are mapped; anything else
/// shows capitalised as-is, never invented.
func serviceDisplayName(_ name: String) -> String {
    switch name.lowercased() {
    case "google": return "Google"
    case "github": return "GitHub"
    case "youtube": return "YouTube"
    case "chatgpt": return "ChatGPT"
    case "claude": return "Claude"
    case "gemini": return "Gemini"
    case "netflix": return "Netflix"
    case "disney-plus": return "Disney+"
    case "prime-video": return "Prime Video"
    case "spotify": return "Spotify"
    case "tiktok": return "TikTok"
    case "discord": return "Discord"
    case "bilibili": return "Bilibili"
    default: return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Service probe status label (core contract, upstream
/// crates/engine/src/probe/services.rs) and colour. Mirrors
/// DashboardView's serviceStatusLabel/serviceStatusColor —
/// duplicated here because those are instance methods on
/// DashboardView and this file's sheets cannot call them.
func dashboardServiceStatusLabel(_ status: String) -> String {
    switch status {
    case "available": return "可用"
    case "unavailable": return "不可用"
    case "restricted": return "受限"
    case "disallowed-isp": return "运营商限制"
    case "blocked": return "被墙"
    case "unsupported-region": return "地区不支持"
    case "originals-only": return "仅自制剧"
    case "coming-soon": return "即将推出"
    case "timeout": return "超时"
    case "failed": return "失败"
    case "": return "未判断"
    default: return status
    }
}

func dashboardServiceStatusColor(_ status: String) -> Color {
    switch status {
    case "available": return .green
    case "blocked", "failed", "timeout", "unavailable": return .red
    default: return .orange
    }
}

// MARK: - Rings

/// Solid proxy-share ring (MuYu ProxyRatioRing, dashboard card):
/// 64pt, 6pt stroke, round caps, arc starts at the top and runs
/// clockwise; the track is the soft fill. Built from Circle trim
/// + rotation — iOS 17-safe, no iOS 26 glass.
struct ProxyRatioRing: View {
    let ratio: Double
    var size: CGFloat = 64
    var strokeWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(ConcordTheme.softFill, lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(ratio, 0), 1)))
                .stroke(ConcordTheme.accent, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((min(max(ratio, 0), 1) * 100).rounded()))%")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size, height: size)
    }
}

/// Dashed proxy gauge (MuYu TrafficGaugeTicks, traffic sheet):
/// 30 ticks around a 96pt circle, stroke 3.5, round caps; the
/// first (1 - ratio) * 30 ticks from the top, clockwise, are the
/// direct colour (accent 45% over the card), the rest proxy
/// (accent). The centre shows the proxy percent + "代理".
struct ProxyGaugeTicks: View {
    let ratio: Double
    var size: CGFloat = 96

    private var tickCount: Int { 30 }

    var body: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let directTicks = Int(((1 - min(max(ratio, 0), 1)) * Double(tickCount)).rounded())
                let isDirect = index < directTicks
                Capsule()
                    .fill(isDirect ? ConcordTheme.accent.opacity(0.45) : ConcordTheme.accent)
                    .frame(width: 3.5, height: 9)
                    .offset(y: -(size / 2 - 2 - 4.5))
                    .rotationEffect(.degrees(Double(index) * 360 / Double(tickCount)))
            }
            VStack(spacing: 0) {
                Text("\(Int((min(max(ratio, 0), 1) * 100).rounded()))%")
                    .font(.system(size: 20, weight: .bold))
                Text("代理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sheet chrome

/// One action pill for the sheet header (MuYu's top-right
/// capsule holding the refresh, bolt/sliders or
/// trash/refresh buttons).
struct SheetActionsPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(ConcordTheme.cardBackground, in: Capsule())
    }
}

private struct SheetActionButton: View {
    let systemImage: String
    let label: String
    let disabled: Bool
    /// v0.2.128 item 10a (upstream _CheckAllButton): while a probe
    /// runs the button shows a spinner instead of its glyph, but
    /// stays tappable — it is never disabled for loading. A spinner
    /// that cannot be tapped reads as broken; a disabled button
    /// that does nothing reads as broken too.
    let loading: Bool
    let action: () -> Void

    /// Explicit init: the synthesized memberwise init does NOT
    /// carry the defaulted `loading` (CI: "extra arguments at
    /// positions #4, #5"), so the signature is spelled out here
    /// with `loading` defaulting to false for the existing call
    /// sites that do not pass it.
    init(systemImage: String, label: String, disabled: Bool, loading: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.disabled = disabled
        self.loading = loading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if loading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}

/// The MuYu bottom-sheet chrome: drag handle, ✕ top-left,
/// centred title, actions top-right. Content fills the rest
/// of the sheet (scrollable content scrolls inside it).
/// Present with .presentationDragIndicator(.hidden) (the
/// handle here replaces the system one) and
/// .presentationBackground(Color(.systemGroupedBackground)).
struct DashboardBottomSheet<Content: View, Actions: View>: View {
    let title: String
    /// v0.2.68: one action renders as its own independent 36pt
    /// circle (same style as the ✕); two actions render in the
    /// shared SheetActionsPill capsule (call sites wrap them).
    let singleAction: Bool
    let actions: Actions
    let content: Content
    /// v0.2.124: explicit close for sheets rendered as a custom
    /// overlay (no system presentation, so @Environment(\.dismiss)
    /// is a no-op there). Nil keeps the old dismiss() path for
    /// every system-sheet call site.
    let onClose: (() -> Void)?
    /// v0.2.124: drag callbacks for the overlay sheets (drag the
    /// header to grow / dismiss, mirroring the overlay sheets in
    /// ContentView). Nil
    /// means no gesture is attached at all — system sheets are
    /// untouched. The gesture lives on the header only (never on
    /// the scrollable content — v0.2.114: a gesture on the
    /// container captures vertical drags and the list never
    /// scrolls). Velocity is 0: DragGesture.Value exposes no
    /// public velocity; the overlay relies on the translation
    /// branches, same as DnsQueriesView's header.
    let onDragChanged: ((CGFloat) -> Void)?
    let onDragEnded: ((CGFloat, CGFloat) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(title: String, singleAction: Bool = false, onClose: (() -> Void)? = nil, onDragChanged: ((CGFloat) -> Void)? = nil, onDragEnded: ((CGFloat, CGFloat) -> Void)? = nil, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.singleAction = singleAction
        self.actions = actions()
        self.content = content()
        self.onClose = onClose
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    init(title: String, onClose: (() -> Void)? = nil, onDragChanged: ((CGFloat) -> Void)? = nil, onDragEnded: ((CGFloat, CGFloat) -> Void)? = nil, @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.title = title
        self.singleAction = false
        self.actions = EmptyView()
        self.content = content()
        self.onClose = onClose
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Handle + title row. The drag gesture (overlay sheets only)
    /// attaches here; a tap (<10pt movement) still reaches the ✕
    /// / action buttons because the gesture's minimumDistance is
    /// 10pt.
    private var header: some View {
        Group {
            if onDragChanged != nil {
                headerContent
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { onDragChanged?($0.translation.height) }
                            .onEnded { onDragEnded?($0.translation.height, 0) }
                    )
            } else {
                headerContent
            }
        }
    }

    private var headerContent: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            ZStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                HStack {
                    Button { if let onClose { onClose() } else { dismiss() } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(.label))
                            .frame(width: 36, height: 36)
                            .background(ConcordTheme.cardBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                    Spacer()
                    if singleAction {
                        actions
                            .frame(width: 36, height: 36)
                            .background(ConcordTheme.cardBackground, in: Circle())
                    } else {
                        actions
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Outbound IP sheet (status card)
//
// MuYu key_3: "出站 IP" — note "依赖第三方api，仅供参考",
// then a "基础信息" card (IP 地址， 等级， …). The IP comes
// ONLY from the core's egress probe (displayIp, v0.2.115 —
// the direct HTTP IP chain is gone); the ip-api.com lookup
// (DashboardView.fetchIPInfo) only enriches that IP's geo/org
// for the level/type rows (hosting -> 机房， silence ->
// residential, inferred).
// The IP row opens the full IP-quality page (MuYu taps the
// IP line for the same page); v0.2.68 removed the in-sheet
// "查看完整 IP 质量" button (the video's sheet has none), and
// v0.2.85 removed the dashboard's dead IP-quality sheet
// presentation (its trigger was deleted in v0.2.68 and nothing
// ever set it) — the IP-quality page itself stays reachable
// from Settings. The refresh button re-runs the probe plus the
// enrichment lookup. hideIp masks the address like the card does.

// MARK: - Service status sheet (services card)
//
// MuYu key_7: "服务状态" — one row per service: brand tile
// with a status dot, name, flag + egress IP, latency right.
// Top-right: bolt (test all) + sliders (manage services).
// The egress IP is probed per exit node (probe.outboundIp
// through the service's first chain, MuYu's per-node
// outboundIpProbeProvider); while a probe is pending the row
// shows the node name, and when it fails the node name stays
// (never a made-up IP). The flag is the service's region
// code. Row tap re-checks that one service.

struct ServiceStatusSheet: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var client: ConcordClient

    /// v0.2.124: explicit close + header-drag callbacks for the
    /// custom-overlay presentation (ContentView root — the system
    /// .sheet path froze, see the overlay note). Nil = the old
    /// system-sheet presentation (dismiss() + no drag gesture).
    /// NOTE: no `= nil` defaults here — a `let` with a default is
    /// already initialized and cannot be assigned again in init
    /// (CI: "immutable value may only be initialized once"); the
    /// defaults live on the explicit init's parameters below.
    let onClose: (() -> Void)?
    let onDragChanged: ((CGFloat) -> Void)?
    let onDragEnded: ((CGFloat, CGFloat) -> Void)?

    @State private var nodeIPs: [String: String] = [:]
    @State private var nodeIPPending: Set<String> = []
    @State private var showManage = false
    /// IP-quality sheet target (v0.2.139, upstream
    /// service_status.dart:498): tapping a service row's
    /// address line opens the per-IP quality sheet — only when
    /// the line is a real IP.
    @State private var ipQualitySelection: IpQualitySheetTarget?

    /// v0.2.124 (services=0): the proxy a services probe runs
    /// through. Every probe call site used to gate on
    /// selectedOutbound != nil, and this user never picked a node
    /// (出站=无), so no probe ever ran and services stayed empty
    /// forever — the card's "?" pills and the empty sheet. DIRECT
    /// is the core's own default probe proxy (upstream
    /// probe/testing.rs: None => "DIRECT"), i.e. the route the
    /// user's traffic actually takes with nothing selected. Once
    /// the user picks a node, ServiceProbeStore.outboundChanged
    /// re-probes through it, replacing these results.
    private var probeProxy: String {
        proxyStore.selectedOutbound ?? "DIRECT"
    }

    /// v0.2.124 diagnostic: body-evaluation counter. If the
    /// overlay still freezes, the ring buffer settles whether the
    /// SwiftUI body is re-evaluating in a loop (count explodes to
    /// 1024 within a second) or the body is quiet (count stays
    /// ~1-3 while the main thread spins, so the spin is in UIKit
    /// layout, not the body). A static counter — NOT @State /
    /// @Published — so counting itself can never trigger a
    /// re-render; logged only at powers of two, capped at 1024.
    private static var bodyEvaluations = 0

    private static func noteBodyEvaluation() {
        bodyEvaluations += 1
        let n = bodyEvaluations
        if n <= 1024, n & (n - 1) == 0 {
            ServiceSheetDiagnostics.record("ServiceStatusSheet body 已评估 \(n) 次")
        }
    }

    /// v0.2.124: explicit initializer. The memberwise initializer
    /// is not usable here — the @EnvironmentObject / @State
    /// properties leave the struct with only a zero-argument
    /// init (CI: "argument passed to call that takes no
    /// arguments" at the overlay's ServiceStatusSheet(onClose:)
    /// call), so the overlay parameters get their own init.
    /// The environment objects and @State keep their defaults.
    init(onClose: (() -> Void)? = nil, onDragChanged: ((CGFloat) -> Void)? = nil, onDragEnded: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.onClose = onClose
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        Self.noteBodyEvaluation()
        return DashboardBottomSheet(
            title: "服务状态",
            onClose: onClose,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            actions: {
                SheetActionsPill {
                    // v0.2.128 item 10a (upstream _CheckAllButton):
                    // the bolt is NEVER disabled — it shows a spinner
                    // while a sweep runs and stays tappable, so the
                    // user can always re-run the probe. A tap during
                    // a sweep is a no-op inside probeServices (its
                    // isProbingServices guard), but the spinner shows
                    // a probe is already in flight; a tap when idle
                    // starts a fresh sweep at once.
                    SheetActionButton(systemImage: "bolt.fill", label: "全部检测", disabled: false, loading: trafficStore.isProbingServices) {
                        Task { await recheckAll() }
                    }
                    SheetActionButton(systemImage: "slider.horizontal.3", label: "管理服务", disabled: false) {
                        showManage = true
                    }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if trafficStore.services.isEmpty {
                        Text("通过当前出站检测 Google / GitHub / YouTube 等服务的可用性（probe.services）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        // v0.2.128 item 10c (upstream _ServiceRow /
                        // SliverPrismList): each row is its own
                        // rounded card (cardBackground, radius 16 —
                        // the DNS sheet's row radius), not a flat
                        // list row with a divider. The dividers are
                        // gone; the 8pt gaps between cards are the
                        // separation.
                        VStack(spacing: 8) {
                            ForEach(trafficStore.services) { service in
                                serviceRow(service)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if trafficStore.servicesHeld {
                        Text("检测结果已暂停：VPN 刚启动，等待下次检测刷新。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    if let error = trafficStore.servicesError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    Text("出口 IP 为通过各服务出口节点探测的地址；未探测到时显示节点名。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                .padding(.bottom, 20)
            }
        }
        // v0.2.123 diagnostic (服务状态 freeze 2026-11-26 08:08):
        // phase 3 — the sheet content actually appeared. On 124
        // the sheet is a custom overlay (no system .sheet), so
        // this line now means the overlay mounted and its body
        // evaluated; if a freeze still shows the tap + target
        // lines but not this one, the main thread died mounting
        // the overlay; if this line is present, the freeze is
        // inside the sheet (probeNodeIPs lines below say where,
        // and the body-evaluation counter says whether the body
        // itself is looping). Logging only.
        .onAppear { ServiceSheetDiagnostics.record("服务状态 sheet 已出现") }
        .task { await probeNodeIPs(source: "打开时") }
        .sheet(isPresented: $showManage) {
            ServiceManageSheet()
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
                .presentationBackground(ConcordTheme.pageBackground)
                .presentationCornerRadius(28)
        }
        .sheet(item: $ipQualitySelection) { target in
            IPQualityView(ip: target.ip)
                .presentationDetents([.fraction(0.5625), .fraction(0.9)])
                .presentationDragIndicator(.visible)
                .presentationBackground(ConcordTheme.pageBackground)
                .presentationCornerRadius(28)
        }
    }

    private func serviceRow(_ service: ConcordServiceItem) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                PackTileImage(
                    name: service.name,
                    fallback: serviceTileText(service.name),
                    fontSize: service.name.lowercased() == "github" ? 13 : 20
                )
                .foregroundStyle(Color(.label))
                .frame(width: 48, height: 48)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Circle()
                    .fill(dashboardServiceStatusColor(service.status))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceDisplayName(service.name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let flag = flagEmoji(countryCode: service.region) {
                        Text(flag)
                    }
                    // v0.2.139 (Q-D3/Q-M5, upstream
                    // service_status.dart:498): the address line
                    // is tappable only when it is a real IP —
                    // tapping it opens the per-IP quality sheet
                    // for that IP. The node-name fallback and
                    // the "—" are plain text (not tappable, like
                    // upstream). Per the v0.2.128 lesson, a
                    // Button inside the row's onTapGesture area
                    // does NOT trigger the row's gesture — only
                    // its own action.
                    if let ip = serviceIp(for: service) {
                        Button {
                            ipQualitySelection = IpQualitySheetTarget(ip: ip)
                        } label: {
                            Text(ip)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(nodeLine(for: service))
                            .lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(trailingText(for: service))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(trailingColor(for: service))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // v0.2.128 item 10c: the row itself is a rounded card
        // (cardBackground — pure white under default blue, ~5%
        // accent tint under a non-default theme; radius 16,
        // the DNS sheet's row radius).
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        // Row tap re-checks that one service — as a plain
        // gesture now (the row is no longer a Button), so a
        // tap during a sweep is a no-op instead of a disabled
        // row (upstream's row is never disabled either).
        .onTapGesture {
            guard !trafficStore.isProbingServices else { return }
            Task { await recheckOne(service) }
        }
    }

    private func serviceTileText(_ name: String) -> String {
        if name.lowercased() == "github" { return "GH" }
        return String(name.prefix(1)).uppercased()
    }

    /// The service row's real IP, if the second line shows one
    /// (upstream service_status.dart:498: the address line is
    /// tappable only when `address != null`): the service's own
    /// `ip`, else the probed egress IP through its exit node.
    /// Nil while pending or when the probe failed — the row then
    /// shows the node name (not tappable).
    private func serviceIp(for service: ConcordServiceItem) -> String? {
        if let ip = service.ip, !ip.isEmpty { return ip }
        guard let node = service.chains?.first, !node.isEmpty else { return nil }
        return nodeIPs[node]
    }

    /// Second line: the address the service itself saw the
    /// check come from (the core fills `ip` only for checks
    /// whose answer names it — Claude/ChatGPT, from their
    /// Cloudflare trace); else the probed egress IP through
    /// the service's exit node; the node name while pending
    /// or when the probe failed; "—" when there is no node
    /// at all.
    private func nodeLine(for service: ConcordServiceItem) -> String {
        guard let node = service.chains?.first, !node.isEmpty else { return "—" }
        if let ip = service.ip, !ip.isEmpty { return ip }
        if let ip = nodeIPs[node] { return ip }
        return node
    }

    private func trailingText(for service: ConcordServiceItem) -> String {
        // v0.2.86 item 16: a failed/timeout status reads as
        // checking until ServiceProbeStore confirms it (1 s
        // confirm re-probe); verdicts are shown as-is.
        if ServiceProbeStore.isFailure(service),
           !trafficStore.serviceProbeStore.confirmedFailures.contains(service.name) {
            return "检测中"
        }
        if service.status == "available", let delay = service.delay {
            return "\(delay) ms"
        }
        return dashboardServiceStatusLabel(service.status)
    }

    private func trailingColor(for service: ConcordServiceItem) -> Color {
        if ServiceProbeStore.isFailure(service),
           !trafficStore.serviceProbeStore.confirmedFailures.contains(service.name) {
            return .secondary
        }
        if service.status == "available", service.delay != nil {
            return Color(.label)
        }
        return dashboardServiceStatusColor(service.status)
    }

    private func recheckAll() async {
        await trafficStore.serviceProbeStore.probeAll(proxy: probeProxy, names: trafficStore.orderedServiceNames)
        await probeNodeIPs(source: "全部检测")
    }

    private func recheckOne(_ service: ConcordServiceItem) async {
        await trafficStore.probeService(proxy: probeProxy, name: service.name)
        // v0.2.86 item 16: feed the single-service result through
        // the confirm/backoff machine instead of showing a first
        // failure instantly.
        await trafficStore.serviceProbeStore.evaluate(trafficStore.services)
        await probeNodeIPs(source: "单项重测")
    }

    /// Probes the egress IP through each distinct exit node
    /// (sequential: usually one or two nodes; a failed probe
    /// leaves the node name in place).
    ///
    /// v0.2.123 diagnostic (服务状态 freeze 2026-11-26 08:08):
    /// phase 4 — enter/exit + one line per node, recorded
    /// BEFORE each probeOutboundIp await, so a freeze inside
    /// one node's probe leaves "正在探测节点 X" as the last
    /// line with no completion after it. `source` tells the
    /// appear-probe apart from a bolt/row re-probe. The probe
    /// itself is unchanged (same calls, same order, same
    /// fallbacks); only record lines were added.
    private func probeNodeIPs(source: String) async {
        let nodes = Set(
            trafficStore.services.compactMap { $0.chains?.first }.filter { !$0.isEmpty })
        let pending = nodes.filter { nodeIPs[$0] == nil && !nodeIPPending.contains($0) }
        guard !pending.isEmpty else {
            ServiceSheetDiagnostics.record("出口 IP 探测跳过 (\(source), services=\(trafficStore.services.count) 个, 无待探测节点)")
            return
        }
        ServiceSheetDiagnostics.record("开始探测出口 IP (\(source), 待探测节点=\(pending.count) 个: \(pending.sorted().joined(separator: "、")))")
        for node in pending { nodeIPPending.insert(node) }
        var succeeded = 0
        for node in pending.sorted() {
            ServiceSheetDiagnostics.record("正在探测节点 \(node) 的出口 IP")
            do {
                let result = try await client.probeOutboundIp(proxy: node)
                let ip = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty {
                    nodeIPs[node] = ip
                    succeeded += 1
                    ServiceSheetDiagnostics.record("节点 \(node) 出口 IP: \(ip)")
                } else {
                    ServiceSheetDiagnostics.record("节点 \(node) 探测返回空")
                }
            } catch {
                ServiceSheetDiagnostics.record("节点 \(node) 探测失败: \(error.localizedDescription)")
            }
            nodeIPPending.remove(node)
        }
        ServiceSheetDiagnostics.record("出口 IP 探测完成 (\(source), 成功 \(succeeded)/\(pending.count) 个)")
    }
}

// MARK: - Profile providers sheet (config card)
//
// v0.2.145 (providers placement): the active profile's name as
// the title, then one row per provider — ALL providers (proxy +
// rule), like upstream's ExternalProvidersSliver. Data is
// provider.list via RuleStore; count is the provider's item
// count and updatedAt is epoch seconds. Top-right: refresh
// re-reads the list; the providers section has an update-all
// button (upstream's sliver header sync) and each HTTP provider
// row has an update action in its context menu. There is no
// eye toggle — upstream's sliver has no filter.

/// The profile-detail sheet (upstream profile_detail.dart
/// ProfileDetailSheet, opened from the dashboard profile card):
/// stat cells, the subscription section, the 配置 section (last
/// updated) and the providers sliver — ALL providers, like
/// upstream's ExternalProvidersSliver, not rule-only.
struct ProfileDetailSheet: View {
    @EnvironmentObject private var ruleStore: RuleStore
    @EnvironmentObject private var proxyStore: ProxyStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    /// Extend settings + the MITM script library, for the 扩展脚本
    /// row (upstream profile_detail.dart reads profile.scriptId
    /// against the scripts library). Ours stores the picked
    /// library script's id in ExtendSettings.scriptId (v0.2.147)
    /// alongside the copied content, so the label is an exact
    /// id lookup (see scriptLabel), not a content match.
    @StateObject private var extendStore = ExtendConfigStore()
    @StateObject private var scriptStore = MitmScriptStore()

    let profileName: String
    /// The active profile's subscription info, passed from the
    /// dashboard (same source as the profile card's traffic
    /// text, so the sheet and the card always agree).
    let subscription: ConcordSubscriptionInfo?
    @State private var isRefreshing = false
    @State private var isSyncingProviders = false
    @State private var isSyncingProfile = false
    @State private var showPreview = false
    @State private var headerError: String?
    /// Update-all failures, one line per failed provider
    /// (upstream _updateProviders → dialogs.showFailures).
    @State private var providerFailures: String?
    /// Stat counts parsed from the applied config file on disk
    /// (upstream _countConfigFile / configCountsOf, 8 MB cap).
    /// Nil = not loaded yet or the file could not be read — the
    /// cells then fall back to the live stores, and to "—" when
    /// those are empty too. Only used in live mode; sample mode
    /// keeps the live-store counts (its mock data has no real
    /// file behind it).
    @State private var localCounts: ProfileStore.AppliedConfigCounts?
    /// Provider rows: edit (text files) and .mrs dump preview.
    @State private var editingProvider: ConcordProviderInfo?
    @State private var previewingProvider: ConcordProviderInfo?
    /// Subscription-info dialog (upstream _handleShowSubscriptionInfo).
    @State private var subscriptionInfoProvider: ConcordProviderInfo?
    /// Side-load upload target + the system file picker.
    @State private var uploadTarget: ConcordProviderInfo?
    @State private var showFileImporter = false

    private var providers: [ConcordProviderInfo] {
        ruleStore.providers
    }

    /// Header (v0.2.64, video sheet_2 bottom-right): four stat
    /// cells (策略组 / 代理 / 规则 / 外部资源）, a 订阅信息
    /// section (used/total + expiry date, only when the profile
    /// actually has subscription traffic — upstream shows the
    /// section only when total > 0), and a 配置 section
    /// (上次更新 + 扩展脚本）. Counts come from the applied
    /// config file when it could be parsed (works VPN-off,
    /// upstream profile_detail.dart), falling back to the live
    /// stores; with no loaded data they show "—" — never an
    /// invented number. A legitimately empty config shows 0,
    /// not "—" (upstream reserves "-" for a load failure).
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                profileStatCell(value: groupCountText, label: "策略组")
                profileStatCell(value: nodeCountText, label: "代理")
                profileStatCell(value: ruleCountText, label: "规则")
                profileStatCell(value: providerCountText, label: "外部资源")
            }
            if let info = subscription, info.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("订阅信息")
                        .font(.headline)
                    HStack {
                        Text(subscriptionText)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(expireText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // v0.2.68: wavy usage bar under the used/total line.
                    WavyProgressBar(
                        progress: Double(info.upload + info.download) / Double(info.total),
                        color: ConcordTheme.accent
                    )
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("配置")
                    .font(.headline)
                HStack {
                    Text("上次更新")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(updatedText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Upstream profile_detail.dart:229-237: the 扩展脚本
                // row, for non-custom profiles (every profile here
                // is url/file). The label is the library script
                // whose content matches the extend settings, or
                // "自定义脚本" when a script is set but came from
                // nowhere in the library.
                HStack {
                    Text("扩展脚本")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(scriptLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let headerError {
                Text(headerError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    private func profileStatCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v0.2.68: white rounded-card backgrounds, like the video.
        .padding(12)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private func refreshProviders() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await ruleStore.refresh()
        await loadLocalCounts()
    }

    /// Parses the applied config file off the main thread
    /// (ProfileStore.localAppliedConfigCounts, upstream
    /// _countConfigFile). Live mode only: sample mode has no real
    /// file behind its mock stores.
    private func loadLocalCounts() async {
        guard client.mode == .live else { return }
        let counts = await Task.detached(priority: .userInitiated) {
            ProfileStore.localAppliedConfigCounts()
        }.value
        // The detached parse resumes off the main thread; the
        // @State write must hop back explicitly.
        await MainActor.run { localCounts = counts }
    }

    /// The extend-script label for the 配置 section: the library
    /// script named by the active profile's stored script id
    /// (v0.2.147, upstream Profile.scriptId). No script set →
    /// "无"; an id whose library entry is gone, or text with no
    /// id at all (pasted in), → "自定义脚本". The old
    /// content-match mislabelled a pasted script that happened
    /// to equal a library entry.
    private var scriptLabel: String {
        guard let active = profileStore.activeProfile else { return "无" }
        let settings = extendStore.settings(for: active.id)
        guard settings.mode == .script, settings.scriptEnabled,
              !settings.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "无" }
        if let scriptId = settings.scriptId,
           let match = scriptStore.scripts.first(where: { $0.id == scriptId }) {
            return match.label
        }
        return "自定义脚本"
    }

    /// Upstream profile_detail.dart syncProfile: re-downloads the
    /// active URL profile (the sheet's sync icon action). Errors
    /// surface under the header; a success re-reads the counts
    /// and the provider list.
    private func syncProfile() async {
        guard let active = profileStore.activeProfile, active.kind == .url else { return }
        isSyncingProfile = true
        defer { isSyncingProfile = false }
        await profileStore.update(active)
        if let error = profileStore.lastError {
            headerError = error
        } else {
            headerError = nil
            await loadLocalCounts()
            await ruleStore.refresh()
        }
    }

    /// Upstream's sliver header sync (providers.dart
    /// _updateProviders): updates every provider in the sliver in
    /// parallel, reports EVERY failed provider (not just the
    /// last), then refreshes the proxy groups
    /// (updateGroupsDebounce) and the list.
    private func syncAllProviders() async {
        guard !isSyncingProviders else { return }
        isSyncingProviders = true
        defer { isSyncingProviders = false }
        providerFailures = nil
        let store = ruleStore
        let failures: [(String, String)] = await withTaskGroup(of: (String, String)?.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        try await store.updateProviderThrowing(provider)
                        return nil
                    } catch {
                        return (provider.name, error.localizedDescription)
                    }
                }
            }
            var collected: [(String, String)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }
        if !failures.isEmpty {
            providerFailures = "更新失败（\(failures.count) 个）：\n"
                + failures.sorted(by: { $0.0 < $1.0 }).map { "· \($0.0)：\($0.1)" }.joined(separator: "\n")
        }
        await ruleStore.refresh()
        await proxyStore.refresh(activeProfile: profileStore.activeProfile)
    }

    /// Upstream ProviderItem._handleUpdateProvider (via
    /// RuleStore.updateProvider, which handles the HTTP case, the
    /// app-rule-set remote sync, and the VPN-off in-app core),
    /// then the groups refresh (upstream updateGroupsDebounce).
    private func updateProvider(_ provider: ConcordProviderInfo) async {
        await ruleStore.updateProvider(provider)
        await proxyStore.refresh(activeProfile: profileStore.activeProfile)
    }

    /// Tap-to-preview (upstream ProviderItem._handlePreviewProvider):
    /// a text provider opens the editor; an .mrs rule set is dumped
    /// by the core to text first and shown read-only (a binary
    /// .mrs must never be opened as text). A binary provider has
    /// no preview — the row tap is disabled for it.
    private func previewProvider(_ provider: ConcordProviderInfo) async {
        let kind = await ruleStore.probeProviderFile(provider)
        if kind == .ruleSet {
            await ruleStore.dumpRuleSet(provider)
            if ruleStore.dumpedRuleSetName == provider.name, ruleStore.dumpedRuleSetText != nil {
                previewingProvider = provider
            }
        } else if kind == .text {
            editingProvider = provider
        }
    }

    /// Upstream _sideLoadProvider: uploads a picked file's text
    /// into the core under the provider's name. Non-UTF-8 files
    /// are refused (the core's string side-load cannot take them,
    /// same as upstream's _decodeProviderFile).
    private func handleUploadResult(_ result: Result<URL, Error>) async {
        guard let provider = uploadTarget else { return }
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                // The file-picker completion runs off the main
                // thread; the @Published write hops explicitly.
                await MainActor.run { ruleStore.lastError = "上传失败：文件为空或不是 UTF-8 文本" }
                return
            }
            await ruleStore.sideLoadProvider(name: provider.name, data: text)
            await proxyStore.refresh(activeProfile: profileStore.activeProfile)
        case .failure(let error):
            await MainActor.run { ruleStore.lastError = "选择文件失败：\(error.localizedDescription)" }
        }
    }

    private var groupCountText: String {
        if let local = localCounts { return "\(local.groups)" }
        return proxyStore.groups.isEmpty ? "—" : "\(proxyStore.groups.count)"
    }

    private var nodeCountText: String {
        // Upstream profileStatsOf: the applied config's own proxies
        // PLUS the proxies provided by proxy providers.
        if let local = localCounts { return "\(local.proxies + providedProxyCount)" }
        // allNodes repeats a node once per group that lists it;
        // dedup by name (unique within a profile) for the true
        // proxy count.
        return proxyStore.groups.isEmpty ? "—" : "\(Set(proxyStore.allNodes.map { $0.name }).count)"
    }

    private var ruleCountText: String {
        if let local = localCounts { return "\(local.rules)" }
        return ruleStore.rules.isEmpty ? "—" : "\(ruleStore.rules.count)"
    }

    private var providerCountText: String {
        ruleStore.providers.isEmpty ? "—" : "\(ruleStore.providers.count)"
    }

    /// Proxies contributed by proxy providers (upstream
    /// profileStatsOf's providedProxies fold). Core provider
    /// types arrive lowercase ("proxy" / "rule", see the sample
    /// transport); the comparison is case-insensitive so a core
    /// that reports "Proxy" counts the same.
    private var providedProxyCount: Int {
        providers.filter { $0.type.lowercased() == "proxy" }.reduce(0) { $0 + Int($1.count) }
    }

    private var subscriptionText: String {
        guard let info = subscription, info.total > 0 else { return "—" }
        return "\(dashboardBytesNoSpace(info.upload + info.download)) / \(dashboardBytesNoSpace(info.total))"
    }

    private var expireText: String {
        guard let info = subscription, info.expire > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var updatedText: String {
        guard let date = profileStore.activeProfile?.updatedAt else { return "—" }
        return ConcordRelativeTime.string(since: date)
    }

    var body: some View {
        DashboardBottomSheet(
            title: profileName,
            actions: {
                // Upstream profile_detail.dart:178-192 icon actions:
                // sync (URL profiles only, with the updating
                // spinner) + runtime-config preview (eye). The
                // 刷新 pill stays as the third action: it only
                // re-reads the provider/rule lists.
                SheetActionsPill {
                    if profileStore.activeProfile?.kind == .url {
                        SheetActionButton(systemImage: "arrow.clockwise", label: "同步", disabled: isSyncingProfile, loading: isSyncingProfile) {
                            Task { await syncProfile() }
                        }
                    }
                    SheetActionButton(systemImage: "eye", label: "运行时配置", disabled: profileStore.activeProfile == nil) {
                        showPreview = true
                    }
                    SheetActionButton(systemImage: "arrow.triangle.2.circlepath", label: "刷新", disabled: isRefreshing) {
                        Task { await refreshProviders() }
                    }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    Divider().padding(.horizontal, 16)
                    // Upstream's sliver header sync (providers.dart
                    // _updateProviders): parallel, every failure
                    // reported, groups refreshed afterwards. The
                    // header pill above only reloads the list.
                    HStack {
                        Text("外部资源")
                            .font(.headline)
                        Spacer()
                        Button { Task { await syncAllProviders() } } label: {
                            if isSyncingProviders {
                                ProgressView()
                                    .frame(width: 36, height: 36)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 36, height: 36)
                                    .background(ConcordTheme.cardBackground, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing || isSyncingProviders)
                        .opacity(isRefreshing || isSyncingProviders ? 0.4 : 1)
                        .accessibilityLabel("更新全部提供方")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    if providers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("暂无提供方")
                                .font(.subheadline.weight(.semibold))
                            Text("核心未返回提供方列表：请点右上角刷新重试；若一直为空，请检查配置是否引用了提供方。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    } else {
                        ForEach(providers) { provider in
                            providerRow(provider)
                            if provider.id != providers.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    if let failures = providerFailures {
                        Text(failures)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(16)
                    }
                    if let error = ruleStore.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(16)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .task {
            await loadLocalCounts()
            await ruleStore.refreshAppRuleSetNames()
            if ruleStore.providers.isEmpty {
                await ruleStore.refresh()
            }
        }
        .sheet(isPresented: $showPreview) {
            if let active = profileStore.activeProfile {
                ProfilePreviewView(profile: active)
            }
        }
        .sheet(item: $editingProvider) { provider in
            EditProviderView(provider: provider)
        }
        .sheet(item: $previewingProvider) { provider in
            ProviderDumpPreviewSheet(name: provider.name, text: ruleStore.dumpedRuleSetText ?? "")
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.yaml, .plainText]) { result in
            Task { await handleUploadResult(result) }
        }
        .alert(
            "订阅信息",
            isPresented: Binding(
                get: { subscriptionInfoProvider != nil },
                set: { if !$0 { subscriptionInfoProvider = nil } }
            ),
            presenting: subscriptionInfoProvider
        ) { _ in
            Button("确定", role: .cancel) {}
        } message: { provider in
            Text(subscriptionInfoMessage(ruleStore.providerDetails[provider.name]?.subscriptionInfo ?? provider.subscriptionInfo))
        }
    }

    /// Upstream ProviderItem (providers.dart:160-371): tap
    /// previews (editor, or the core's dumpRules for .mrs),
    /// the menu offers edit (text files), preview (.mrs),
    /// side-load upload, sync (HTTP or app rule set), and the
    /// subscription-info dialog when the provider has
    /// subscription traffic. The subtitle is the traffic meter
    /// (used/total + progress bar) when subscription info is
    /// known, else the rule/proxy count; the title carries the
    /// expiry chip; the trailing shows a spinner while this
    /// provider updates, else the last-update time. The detail
    /// (provider.get) and the file kind are fetched when the row
    /// appears; until the kind lands the row is not tappable and
    /// the menu shows only the always-available items.
    private func providerRow(_ provider: ConcordProviderInfo) -> some View {
        let detail = ruleStore.providerDetails[provider.name]
        let info = detail?.subscriptionInfo ?? provider.subscriptionInfo
        let kind = ruleStore.providerFileKinds[provider.name]
        let isUpdating = ruleStore.updatingProviderNames.contains(provider.name)
        let previewable = kind != nil && kind != .binary
        let syncable = provider.vehicleType == "HTTP" || ruleStore.isAppRuleSetProvider(provider)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let expire = providerExpireText(info) {
                        Text(expire)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ConcordTheme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(ConcordTheme.accent)
                            .lineLimit(1)
                    }
                }
                if let info, info.total > 0 {
                    providerTrafficMeter(info: info)
                } else {
                    Text(countText(for: provider))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isUpdating {
                ProgressView()
                    .frame(width: 24, height: 24)
            } else {
                Text(updatedText(for: provider))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isUpdating, previewable else { return }
            Task { await previewProvider(provider) }
        }
        .task {
            _ = await ruleStore.probeProviderFile(provider)
            await ruleStore.loadProviderDetailIfNeeded(provider)
        }
        .contextMenu {
            if kind == .text {
                Button("编辑提供方") {
                    editingProvider = provider
                }
            }
            if kind == .ruleSet {
                Button("预览规则") {
                    Task { await previewProvider(provider) }
                }
            }
            Button("上传文件") {
                uploadTarget = provider
                showFileImporter = true
            }
            if syncable {
                Button("更新提供方") {
                    Task { await updateProvider(provider) }
                }
            }
            if let info, info.total > 0 {
                Button("订阅信息") {
                    subscriptionInfoProvider = provider
                }
            }
        }
    }

    /// Upstream ProviderItem._TrafficMeter: used/total + a thin
    /// progress bar. The header's wavy bar is the profile-level
    /// one; rows use the plain bar, like upstream's
    /// LinearProgressIndicator.
    private func providerTrafficMeter(info: ConcordSubscriptionInfo) -> some View {
        let used = info.upload + info.download
        let usage = info.total > 0 ? min(Double(used) / Double(info.total), 1.0) : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(dashboardBytesNoSpace(used)) / \(dashboardBytesNoSpace(info.total))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: usage)
                .tint(ConcordTheme.accent)
        }
    }

    /// Expiry date chip (upstream ChipTitle expire): "yyyy-MM-dd",
    /// nil when the provider has no subscription expiry.
    private func providerExpireText(_ info: ConcordSubscriptionInfo?) -> String? {
        guard let info, info.expire > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Subscription-info dialog body (upstream
    /// SubscriptionInfoDetailView): used / total / expiry, one
    /// line each. No traffic info at all → the fallback line.
    private func subscriptionInfoMessage(_ info: ConcordSubscriptionInfo?) -> String {
        guard let info else { return "无订阅信息" }
        var lines = [
            "已用：\(dashboardBytesNoSpace(info.upload + info.download))",
            "总量：\(info.total > 0 ? dashboardBytesNoSpace(info.total) : "不限")",
        ]
        if let expire = providerExpireText(info) {
            lines.append("到期：\(expire)")
        }
        return lines.joined(separator: "\n")
    }

    private func countText(for provider: ConcordProviderInfo) -> String {
        if provider.type == "rule" {
            return "\(dashboardCompactCount(provider.count)) 条规则"
        }
        return "\(dashboardCompactCount(provider.count)) 项"
    }

    private func updatedText(for provider: ConcordProviderInfo) -> String {
        guard let updatedAt = provider.updatedAt else { return "—" }
        return ConcordRelativeTime.string(since: Date(timeIntervalSince1970: TimeInterval(updatedAt)))
    }
}

/// Read-only dump preview for an .mrs rule-set provider
/// (upstream ProviderItem._handlePreviewProvider with
/// core.dumpRules): the dumped text in a monospaced, selectable
/// scroll view with copy. Kept separate from EditProviderView
/// on purpose — saving dumped text back through side-load would
/// corrupt the compiled set.
private struct ProviderDumpPreviewSheet: View {
    let name: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(ConcordTheme.pageBackground)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Traffic statistics sheet (traffic card)
//
// MuYu key_28 + views/traffic_statistics.dart: 日/周/月
// segmented control, date navigator, a 流量概括 card (total,
// down/up pills, dashed 45% 代理 gauge, 累计运行 + 代理/直连
// mini-cells), then a 流量趋势 chart, a 规则命中 list, then
// a ranking list (策略/节点/域名 tabs). All figures come from
// TrafficStore's daily history (recorded since v0.2.55; ranges
// with no recorded day show "暂无记录", never invented
// numbers). The trash button clears the recorded history
// after confirmation; refresh re-reads the live snapshot.
//
// v0.2.57 adds, in MuYu's order (key_28 / f_029): the hourly
// trend chart (hourly buckets collected from v0.2.57 on, no
// backfill — a pre-upgrade day has a daily total but no bars),
// the rule-hit list (per-day counts from the connection
// feed's `rule` field, same 1 s sampling as the split), and
// per-day uptime (past ranges show recorded values; days with
// no observation show "—"). v0.2.64 adds the 4th ranking tab
// 配置 (video sheet_3): a single row, the active profile with
// the range totals — only one profile is ever active.

private enum TrafficRankingTab: String, CaseIterable {
    case policy, node, domain, config

    var title: String {
        switch self {
        case .policy: return "策略"
        case .node: return "节点"
        case .domain: return "域名"
        case .config: return "配置"
        }
    }
}

private struct TrafficRankingRow: Identifiable {
    let id: String
    let up: Int64
    let down: Int64

    var total: Int64 { up + down }
}

// MARK: - Traffic trend chart (v0.2.57, MuYu 流量趋势)
//
// MuYu key_28 / f_029: a 流量趋势 card — legend 下载 (dark) /
// 上传 (light) top-right, grouped vertical bars per hour,
// x-axis 0/6/12/18, y-axis max / max/2 / 0 on the right,
// dashed gridlines. Day range shows 24 hourly buckets;
// week/month show one grouped bar per day (daily totals,
// recorded since v0.2.55). A bucket with no recorded data
// draws no bar — never an invented value. Pure SwiftUI,
// iOS 17-safe (no Charts framework, no iOS 18 APIs).

private struct TrafficTrendChart: View {
    /// One bar group: down + up bytes. `label` is the x-axis
    /// label (nil for most groups — only a few hours/days are
    /// labelled, like MuYu's 0/6/12/18).
    struct Bucket: Identifiable {
        let id: Int
        let down: Int64
        let up: Int64
        let label: String?
    }

    let buckets: [Bucket]

    private var maxValue: Int64 {
        max(buckets.map { $0.down + $0.up }.max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ConcordTheme.accent.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConcordTheme.accent)
                }
                Text("流量趋势")
                    .font(.headline)
                Spacer()
                legendDot(color: ConcordTheme.accent)
                Text("下载")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                legendDot(color: ConcordTheme.accent.opacity(0.45))
                Text("上传")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    GeometryReader { geo in
                        chartBody(width: geo.size.width, height: geo.size.height)
                    }
                    .frame(height: 160)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(dashboardBytesNoSpace(maxValue))
                        Spacer()
                        Text(dashboardBytesNoSpace(maxValue / 2))
                        Spacer()
                        Text("0")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 160, alignment: .top)
                }
                HStack(spacing: 0) {
                    ForEach(buckets) { bucket in
                        Text(bucket.label ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                // Same width as the y-axis column + spacing, so
                // the labels sit under the bars, not under the
                // axis.
                .padding(.trailing, 60)
            }
        }
        .padding(16)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private func legendDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    /// Dashed horizontal grid line for the trend chart (restored v0.2.69:
    /// the v0.2.68 stacked-bar rewrite deleted this helper but left its
    /// two call sites in chartBody).
    private func dashedLine(width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: width, y: 0.5))
        }
        .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .frame(height: 1)
    }

    private func chartBody(width: CGFloat, height: CGFloat) -> some View {
        let groupWidth = width / CGFloat(max(buckets.count, 1))
        let barWidth = max(4, groupWidth - 6)
        return ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                dashedLine(width: width)
                Spacer()
                dashedLine(width: width)
                Spacer()
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
            }
            // v0.2.68: vertical dashed gridlines at 0/6/12/18.
            HStack(spacing: 0) {
                ForEach(buckets) { bucket in
                    ZStack {
                        if ["0", "6", "12", "18"].contains(bucket.label ?? "") {
                            Path { path in
                                path.move(to: CGPoint(x: groupWidth / 2, y: 0))
                                path.addLine(to: CGPoint(x: groupWidth / 2, y: height))
                            }
                            .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .frame(width: groupWidth, height: height)
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(buckets) { bucket in
                    stackedColumn(bucket: bucket, height: height, width: barWidth)
                        .frame(width: groupWidth, alignment: .center)
                }
            }
        }
    }

    /// One stacked column (v0.2.68): download below, upload
    /// stacked on top in the same column; the bar top is down+up.
    /// Wide, with a fully rounded top (the top segment carries
    /// the rounding; a lone download segment is rounded itself).
    private func stackedColumn(bucket: Bucket, height: CGFloat, width: CGFloat) -> some View {
        let downHeight: CGFloat = bucket.down <= 0 ? 0 : max(2, CGFloat(bucket.down) / CGFloat(maxValue) * height)
        let upHeight: CGFloat = bucket.up <= 0 ? 0 : max(2, CGFloat(bucket.up) / CGFloat(maxValue) * height)
        let radius = min(6, width / 2)
        return VStack(spacing: 0) {
            if bucket.up > 0 {
                UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                    .fill(ConcordTheme.accent.opacity(0.45))
                    .frame(width: width, height: upHeight)
            }
            if bucket.down > 0 {
                Group {
                    if bucket.up > 0 {
                        Rectangle().fill(ConcordTheme.accent)
                    } else {
                        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                            .fill(ConcordTheme.accent)
                    }
                }
                .frame(width: width, height: downHeight)
            }
        }
        .frame(width: width, height: downHeight + upHeight, alignment: .bottom)
    }
}

/// Custom pill segmented control (v0.2.68, video): white
/// rounded track, selected item = accent-filled pill with white
/// text. Replaces the native segmented Pickers in the traffic
/// sheet (range + ranking tabs).
private struct PillSegmentedControl: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { selection = index } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == index ? .white : Color(.label))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selection == index ? ConcordTheme.accent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }
}

struct TrafficStatsSheet: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var range: TrafficRange = .day
    @State private var offset = 0
    @State private var rankingTab: TrafficRankingTab = .policy
    @State private var showClearConfirm = false

    private var rangeSelection: Binding<Int> {
        Binding(
            get: { TrafficRange.allCases.firstIndex(of: range) ?? 0 },
            set: { range = TrafficRange.allCases[$0]; offset = 0 }
        )
    }

    private var rankingSelection: Binding<Int> {
        Binding(
            get: { TrafficRankingTab.allCases.firstIndex(of: rankingTab) ?? 0 },
            set: { rankingTab = TrafficRankingTab.allCases[$0] }
        )
    }

    private var dates: [String] { trafficStore.rangeDates(range: range, offset: offset) }
    private var totals: DayTotals { trafficStore.totalsForDates(dates) }

    private var rankedRows: [TrafficRankingRow] {
        switch rankingTab {
        case .policy:
            return totals.groups.map { TrafficRankingRow(id: $0.key, up: $0.value.up, down: $0.value.down) }
                .sorted { $0.total > $1.total }
        case .node:
            return totals.nodes.map { TrafficRankingRow(id: $0.key, up: $0.value.up, down: $0.value.down) }
                .sorted { $0.total > $1.total }
        case .domain:
            return totals.domains.map { TrafficRankingRow(id: $0.key, up: $0.value.up, down: $0.value.down) }
                .sorted { $0.total > $1.total }
        case .config:
            // v0.2.64 (video sheet_3): the 4th tab 配置. Only one
            // profile is ever active, so it is a single row — the
            // active profile's name with the range totals.
            let name = profileStore.activeProfile?.name ?? "配置"
            return [TrafficRankingRow(id: name, up: totals.up, down: totals.down)]
        }
    }

    private var shownRows: [TrafficRankingRow] { Array(rankedRows.prefix(30)) }

    var body: some View {
        DashboardBottomSheet(
            title: "流量统计",
            actions: {
                SheetActionsPill {
                    SheetActionButton(systemImage: "trash", label: "清空统计", disabled: false) {
                        showClearConfirm = true
                    }
                    SheetActionButton(systemImage: "arrow.clockwise", label: "刷新", disabled: false) {
                        Task { await trafficStore.refresh() }
                    }
                }
            }
        ) {
            // v0.2.68: the range picker + date navigator are PINNED
            // below the sheet title; only the content below scrolls.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    PillSegmentedControl(titles: TrafficRange.allCases.map(\.title), selection: rangeSelection)
                    dateNavigator
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if totals.recordedDays == 0 {
                            Text("暂无记录：该范围没有已记录的流量。自 v0.2.55 起记录每日流量，升级前的数据没有记录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
                        } else {
                            summaryCard
                            trendSection
                            ruleHitsSection
                            rankingSection
                            Text("代理/直连、排行与规则命中按连接采样统计，仅含应用运行时观测到的流量；在两次采样之间开闭的短连接不会计入，拆分之和可能小于总流量。分时流量自 v0.2.57 起记录，升级前日期无分时数据。累计运行只统计应用观测到的隧道时段：在应用未运行时结束的会话无法计入，未观测到的日期显示 —。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
            }
        }
        .alert("清空流量统计", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                Task {
                    await trafficStore.clearDailyHistory()
                    offset = 0
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除自 v0.2.55 起记录的每日流量、代理/直连拆分与排行，以及自 v0.2.57 起记录的分时流量与规则命中，今日从零开始重新记录。累计运行时间与核心累计流量不受影响。")
        }
    }

    private var dateNavigator: some View {
        HStack {
            Button { offset += 1 } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(offset >= range.maxOffset ? Color.gray : ConcordTheme.accent)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(offset >= range.maxOffset)
            .opacity(offset >= range.maxOffset ? 0.3 : 1)
            .accessibilityLabel("上一范围")
            Spacer()
            Text(trafficStore.rangeLabel(range: range, offset: offset))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { offset -= 1 } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.gray)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(offset == 0)
            .opacity(offset == 0 ? 0.3 : 1)
            .accessibilityLabel("下一范围")
        }
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ConcordTheme.accent.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "chart.pie")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConcordTheme.accent)
                }
                Text("流量概括")
                    .font(.headline)
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("总流量")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ConcordBytes.split(totals.total).number)
                            .font(.system(size: 30, weight: .bold))
                        Text(ConcordBytes.split(totals.total).unit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        trafficPill(label: "↓ \(dashboardBytesNoSpace(totals.down))")
                        trafficPill(label: "↑ \(dashboardBytesNoSpace(totals.up))")
                    }
                }
                Spacer()
                ProxyGaugeTicks(ratio: totals.proxyRatio)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("累计运行")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // v0.2.68: numbers big/bold, units small.
                    if let uptime = totals.uptimeText {
                        uptimeBigSmall(uptime)
                    } else {
                        Text("—")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(ConcordTheme.accent).frame(width: 8, height: 8)
                        Text("代理")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ConcordFormat.bytes(totals.proxyBytes))
                            .font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        Circle().fill(ConcordTheme.accent.opacity(0.45)).frame(width: 8, height: 8)
                        Text("直连")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ConcordFormat.bytes(totals.directBytes))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConcordTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    /// Renders "18 小时 56 分钟" with the numbers big/bold and
    /// the units small, like the video.
    private func uptimeBigSmall(_ text: String) -> some View {
        let segments = uptimeSegments(text)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.value)
                    .font(segment.isNumber
                          ? .system(size: 20, weight: .bold)
                          : .footnote)
                    .foregroundStyle(segment.isNumber ? Color(.label) : .secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func uptimeSegments(_ text: String) -> [(value: String, isNumber: Bool)] {
        var segments: [(value: String, isNumber: Bool)] = []
        var current = ""
        var currentIsNumber: Bool? = nil
        for ch in text {
            let isNumber = ch.isNumber
            if let flag = currentIsNumber, flag != isNumber {
                segments.append((value: current, isNumber: flag))
                current = ""
            }
            currentIsNumber = isNumber
            current.append(ch)
        }
        if !current.isEmpty, let flag = currentIsNumber {
            segments.append((value: current, isNumber: flag))
        }
        return segments
    }

    private func trafficPill(label: String) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ConcordTheme.softFill, in: Capsule())
    }

    /// Chart buckets, oldest first. Day range: 24 hourly
    /// buckets (x labels 0/6/12/18, like MuYu). Week/month:
    /// one grouped bar per day from the daily totals (week
    /// dates come back newest-first, so they are reversed;
    /// month dates are already oldest-first).
    private var trendBuckets: [TrafficTrendChart.Bucket] {
        if range == .day {
            let date = dates.first ?? ""
            return (0..<24).map { hour in
                let key = "\(date) \(String(format: "%02d", hour))"
                let split = trafficStore.hourlyBucket(for: key)
                return TrafficTrendChart.Bucket(
                    id: hour, down: split?.down ?? 0, up: split?.up ?? 0,
                    label: [0, 6, 12, 18].contains(hour) ? "\(hour)" : nil)
            }
        }
        let ordered = range == .week ? Array(dates.reversed()) : dates
        return ordered.enumerated().map { (index, date) in
            let day = trafficStore.totalsForDates([date])
            let label: String?
            if range == .week {
                label = TrafficStore.shortDayLabel(date)
            } else if let dayNumber = Int(date.suffix(2)), dayNumber == 1 || (dayNumber - 1) % 5 == 0 {
                label = "\(dayNumber)"
            } else {
                label = nil
            }
            return TrafficTrendChart.Bucket(id: index, down: day.down, up: day.up, label: label)
        }
    }

    /// Whether the selected day has any recorded hourly bucket
    /// (false for a pre-v0.2.57 day, which has only a daily
    /// total, and for a day with no traffic at all).
    private var dayHasHourlyData: Bool {
        trendBuckets.contains { $0.down > 0 || $0.up > 0 }
    }

    private struct TopRuleHit: Identifiable {
        let name: String
        let count: Int

        var id: String { name }
    }

    private var topRuleHits: [TopRuleHit] {
        totals.ruleHits
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { TopRuleHit(name: $0.key, count: $0.value) }
    }

    /// The 流量趋势 card (MuYu f_029: below the summary, above
    /// 规则命中). A pre-v0.2.57 day shows an honest note instead
    /// of an empty chart — its hourly buckets were never
    /// recorded.
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if range == .day && !dayHasHourlyData {
                Text("该日无分时记录：分时流量自 v0.2.57 起记录，升级前日期只有每日总流量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
            } else {
                TrafficTrendChart(buckets: trendBuckets)
                if range == .day {
                    Text("分时流量自 v0.2.57 起记录，仅含应用运行时观测到的流量；空白时段无观测记录。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The 规则命中 list (MuYu f_029: below 流量趋势, above the
    /// ranking tabs — the frames show the header but no rows, so
    /// the rows use the same card/row style as the ranking list:
    /// rule name, hit count, share of the range's hits).
    private var ruleHitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("规则命中")
                .font(.headline)
            if topRuleHits.isEmpty {
                Text("该范围没有规则命中记录。规则命中自 v0.2.57 起按连接采样统计（一次连接计一次）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
            } else {
                VStack(spacing: 0) {
                    ForEach(topRuleHits) { hit in
                        ruleHitRow(hit)
                        if hit.name != topRuleHits.last?.name {
                            Divider().padding(.leading, 56)
                        }
                    }
                    if totals.ruleHits.count > topRuleHits.count {
                        Text("仅显示前 \(topRuleHits.count) 条，共 \(totals.ruleHits.count) 条规则。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
            }
        }
    }

    private func ruleHitRow(_ hit: TopRuleHit) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ConcordTheme.softFill)
                    .frame(width: 40, height: 40)
                Image(systemName: "tag")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(hit.count) 次命中")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(totals.totalRuleHits > 0
                 ? String(format: "%.1f%%", Double(hit.count) / Double(totals.totalRuleHits) * 100)
                 : "—")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("流量排行")
                .font(.headline)
            PillSegmentedControl(titles: TrafficRankingTab.allCases.map(\.title), selection: rankingSelection)
            if rankedRows.isEmpty {
                Text("该范围没有排行数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
            } else {
                VStack(spacing: 0) {
                    ForEach(shownRows) { row in
                        rankingRow(row)
                        if row.id != shownRows.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                    if rankedRows.count > shownRows.count {
                        Text("仅显示前 \(shownRows.count) 条，共 \(rankedRows.count) 条。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
            }
        }
    }

    private func rankingRow(_ row: TrafficRankingRow) -> some View {
        let share = totals.total > 0 ? Double(row.total) / Double(totals.total) : 0
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ConcordTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "globe")
                    .font(.system(size: 17))
                    .foregroundStyle(ConcordTheme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.id)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("↓ \(dashboardBytesNoSpace(row.down))  ↑ \(dashboardBytesNoSpace(row.up))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // v0.2.68: thin progress bar under the name (accent
                // fill by share %, gray track).
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemGray5))
                        Capsule()
                            .fill(ConcordTheme.accent)
                            .frame(width: max(0, geo.size.width * CGFloat(min(max(share, 0), 1))))
                    }
                }
                .frame(height: 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(dashboardBytesNoSpace(row.total))
                    .font(.subheadline.weight(.semibold))
                Text(totals.total > 0 ? String(format: "%.1f%%", Double(row.total) / Double(totals.total) * 100) : "—")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Memory detail sheet (memory card)
//
// Moved from DashboardView.swift unchanged in content, only
// the chrome changed to the dashboard bottom-sheet style
// (was a NavigationStack with a "完成" button). App RSS +
// core RSS are separate processes; the release action calls
// core.releaseMemory.

struct MemoryDetailSheet: View {
    let appBytes: UInt64
    let coreBytes: UInt64?
    /// Extension (NetworkExtension process) RSS — the same GET /memory
    /// number the card shows as its extension leg (v0.2.146 D-42).
    /// Non-nil only while the tunnel runs; nil VPN-off / sample mode.
    let extensionBytes: UInt64?
    @Binding var isReleasing: Bool
    @Binding var releaseMessage: String?
    let onRelease: () async -> Void
    /// v0.2.146 (D-43): release is enabled exactly where a route
    /// exists — VPN-on the tunnel core answers core.releaseMemory
    /// over the existing JSON-RPC route, sample mode keeps its mock
    /// answer. VPN-off live stays disabled (no AppCore release RPC).
    let canRelease: Bool

    /// While the tunnel runs the /memory number belongs to the
    /// extension leg, so the core leg is 0 (same split as the card);
    /// otherwise the core leg is coreBytes (nil = core not running).
    private var hasExtension: Bool { (extensionBytes ?? 0) > 0 }
    private var coreLeg: UInt64 { hasExtension ? 0 : (coreBytes ?? 0) }
    private var totalBytes: UInt64 { appBytes + coreLeg + (extensionBytes ?? 0) }

    var body: some View {
        DashboardBottomSheet(
            title: "内存信息",
            // v0.2.68: ONE action — the broom — as its own
            // independent circle, like the video (was: no button
            // at all; the release lived as a text button in-body).
            singleAction: true,
            actions: {
                Button { Task { await onRelease() } } label: {
                    BroomIcon(size: 18, color: Color(.label))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isReleasing || coreBytes == nil || !canRelease)
                .opacity(isReleasing || coreBytes == nil || !canRelease ? 0.4 : 1)
                .accessibilityLabel("释放核心内存")
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // v0.2.68: big total number (number big, unit small).
                    let split = ConcordBytes.split(Int64(totalBytes))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(split.number)
                            .font(.system(size: 34, weight: .bold))
                        Text(split.unit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // Segmented bar: app + core + extension (v0.2.146
                    // D-42 — the extension leg is the tunnel core's
                    // /memory number; 0 while the tunnel is down).
                    MemoryDetailBar(appBytes: appBytes, coreBytes: coreLeg, extensionBytes: extensionBytes ?? 0)
                    VStack(spacing: 0) {
                        memoryRow("总计", value: ConcordFormat.bytes(Int64(totalBytes)))
                        Divider()
                        memoryRow("应用及共享", value: ConcordFormat.bytes(Int64(appBytes)))
                        Divider()
                        if hasExtension {
                            memoryRow("内核", value: ConcordFormat.bytes(0))
                            Divider()
                            memoryRow("扩展", value: ConcordFormat.bytes(Int64(extensionBytes ?? 0)))
                        } else if let core = coreBytes {
                            memoryRow("内核", value: ConcordFormat.bytes(Int64(core)))
                        } else {
                            memoryRow("内核", value: "核心未运行")
                        }
                    }
                    .padding(16)
                    .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
                    // v0.2.68: short honest two-process note. The
                    // Jetsam warning paragraph is gone (the video has
                    // none), and the percent rows (常驻内存 100%, heap
                    // use/free) are omitted — no data source for them.
                    Text("应用与核心是两个进程（应用进程与 NetworkExtension 进程），分别占用内存，相加为总和。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let message = releaseMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }

    private func memoryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.semibold))
        .padding(.vertical, 10)
    }
}

/// Three-segment memory bar for the detail sheet (app in accent,
/// core in the series2 tone, extension in series3, on a soft track;
/// the extension segment is 0 while the tunnel is down).
private struct MemoryDetailBar: View {
    let appBytes: UInt64
    let coreBytes: UInt64
    let extensionBytes: UInt64

    var body: some View {
        GeometryReader { geo in
            let total = max(1, appBytes + coreBytes + extensionBytes)
            let appWidth = geo.size.width * CGFloat(appBytes) / CGFloat(total)
            let coreWidth = geo.size.width * CGFloat(coreBytes) / CGFloat(total)
            ZStack(alignment: .leading) {
                Capsule().fill(ConcordTheme.softFill)
                HStack(spacing: 2) {
                    Capsule().fill(ConcordTheme.accent).frame(width: max(0, appWidth - 1))
                    Capsule().fill(ConcordTheme.accent.opacity(0.45)).frame(width: max(0, coreWidth - 1))
                    Capsule().fill(ConcordTheme.series3).frame(width: max(0, geo.size.width - appWidth - coreWidth - 1))
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Service management sheet
//
// Moved verbatim from DashboardView.swift (only `private`
// dropped): the services sheet opens it nested, and the
// dashboard's expanded services section opens it too. Kept
// in its NavigationStack style — it is a management list,
// not a card detail sheet.

struct ServiceManageSheet: View {
    @EnvironmentObject private var trafficStore: TrafficStore
    @Environment(\.dismiss) private var dismiss

    @State private var order: [String] = []

    private var enabledCount: Int {
        order.filter { !trafficStore.disabledServices.contains($0) }.count
    }

    private func isEnabled(_ name: String) -> Bool {
        !trafficStore.disabledServices.contains(name)
    }

    private func toggleBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { isEnabled(name) },
            set: { enabled in
                // Refuse to disable the last enabled service.
                if !enabled, enabledCount <= 1 { return }
                trafficStore.setServiceDisabled(name, disabled: !enabled)
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("服务顺序") {
                    ForEach(order, id: \.self) { name in
                        HStack(spacing: 8) {
                            Text(name)
                            Spacer()
                            if let service = trafficStore.services.first(where: { $0.name.lowercased() == name.lowercased() }) {
                                Text(serviceStatusText(service.status))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            // The last enabled service's toggle is
                            // locked (see toggleBinding's guard).
                            Toggle("", isOn: toggleBinding(for: name))
                                .labelsHidden()
                                .disabled(isEnabled(name) && enabledCount <= 1)
                        }
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        trafficStore.setServiceOrder(order)
                    }
                }
                Section {
                    Text("拖动右侧手柄调整检测顺序；关闭的服务不参与「检测」，「全部检测」仍会检测全部服务。至少保留 1 个启用服务。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .font(.footnote.weight(.semibold))
            .background(ConcordTheme.pageBackground)
            .navigationTitle("管理服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { order = trafficStore.orderedServiceNames }
        }
    }

    private func serviceStatusText(_ status: String) -> String {
        switch status {
        case "available": return "可用"
        case "unavailable": return "不可用"
        case "blocked": return "被墙"
        case "timeout": return "超时"
        case "failed": return "失败"
        case "": return "未判断"
        default: return status
        }
    }
}
