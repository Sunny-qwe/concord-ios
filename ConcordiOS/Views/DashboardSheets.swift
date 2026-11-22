import SwiftUI

// MARK: - Dashboard bottom sheets (v0.2.56, MuYu iOS build)
//
// Every dashboard card opens a bottom sheet in the MuYu build:
// a drawer sliding up from the bottom with a drag handle on top,
// an ✕ close button top-left, a centred title, and action buttons
// top-right (in one pill). DashboardBottomSheet is that chrome;
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
/// capsule holding the refresh/eye, bolt/sliders or
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
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
    let actions: Actions
    let content: Content

    @Environment(\.dismiss) private var dismiss

    init(title: String, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    init(title: String, @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.title = title
        self.actions = EmptyView()
        self.content = content()
    }

    var body: some View {
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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(.label))
                            .frame(width: 36, height: 36)
                            .background(ConcordTheme.cardBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                    Spacer()
                    actions
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A label/value row inside a sheet info card.
struct SheetInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - Outbound IP sheet (status card)
//
// MuYu key_3: "出站 IP" — note "依赖第三方api，仅供参考",
// then a "基础信息" card (IP 地址， 等级， …). The rows come
// from the same ip-api.com lookup the status card already
// runs (DashboardView.fetchIPInfo) plus the core's egress
// probe (displayIp); the level/type are the assessed ones
// (hosting -> 机房， silence -> residential, inferred).
// The IP row opens the full IP-quality page (MuYu taps the
// IP line for the same page); the refresh button re-runs
// both lookups. hideIp masks the address like the card does.

struct OutboundIPSheet: View {
    let displayIp: String?
    let hideIp: Bool
    /// The assessed lookup (nil while no lookup has answered).
    let assessed: IPQualityInfo?
    /// The bare "AS<n>" token (parsed from the lookup's `as`
    /// field) when no org/ISP answered.
    let ipAsn: String?
    let isChecking: Bool
    let fetchFailed: Bool
    let onRefresh: () -> Void

    @State private var showFullQuality = false

    private var maskedIp: String? {
        guard let ip = displayIp else { return nil }
        return hideIp ? "*****" : ip
    }

    var body: some View {
        DashboardBottomSheet(
            title: "出站 IP",
            actions: {
                SheetActionsPill {
                    SheetActionButton(systemImage: "arrow.clockwise", label: "刷新", disabled: isChecking, action: onRefresh)
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("依赖第三方api，仅供参考")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let assessed {
                        Text("基础信息")
                            .font(.headline)
                        VStack(spacing: 0) {
                            infoRow(label: "IP 地址", value: maskedIp ?? "—")
                            Divider().padding(.leading, 0)
                            infoRow(
                                label: "等级",
                                value: (assessed.qualityLevel?.label ?? "—")
                                    + (assessed.typeInferred ? "（推断）" : ""))
                            Divider()
                            infoRow(label: "IP 类型", value: assessed.qualityType?.label ?? "—")
                            Divider()
                            infoRow(
                                label: "国家",
                                value: [flagEmoji(countryCode: assessed.countryCode), assessed.country]
                                    .compactMap { $0 }.joined(separator: " "))
                            Divider()
                            infoRow(
                                label: "城市",
                                value: [assessed.regionName, assessed.city]
                                    .compactMap { $0 }.joined(separator: " · "))
                            Divider()
                            infoRow(label: "组织", value: assessed.org ?? "—")
                            Divider()
                            infoRow(label: "运营商", value: assessed.isp ?? "—")
                            Divider()
                            infoRow(label: "ASN", value: assessed.asn ?? ipAsn ?? "—")
                            Divider()
                            infoRow(label: "时区", value: assessed.timezone ?? "—")
                        }
                        .padding(16)
                        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
                        Button("查看完整 IP 质量") { showFullQuality = true }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isChecking {
                        ProgressView("正在查询…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    } else if fetchFailed {
                        VStack(spacing: 8) {
                            Text("查询失败")
                                .font(.subheadline.weight(.semibold))
                            Text("第三方查询未返回结果，请检查网络后重试。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("重试", action: onRefresh)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                    } else {
                        Text("暂无出站 IP：启动 VPN 后查看出口 IP，也可点右上角刷新直接查询本机 IP。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showFullQuality) {
            NavigationStack {
                if let ip = displayIp {
                    IPQualityView(ip: ip)
                } else {
                    IPQualityView()
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        SheetInfoRow(label: label, value: value.isEmpty ? "—" : value)
            .padding(.vertical, 10)
    }
}

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

    @State private var nodeIPs: [String: String] = [:]
    @State private var nodeIPPending: Set<String> = []
    @State private var showManage = false

    private var canProbe: Bool {
        proxyStore.selectedOutbound != nil && !trafficStore.isProbingServices
    }

    var body: some View {
        DashboardBottomSheet(
            title: "服务状态",
            actions: {
                SheetActionsPill {
                    SheetActionButton(systemImage: "bolt.fill", label: "全部检测", disabled: !canProbe) {
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
                        ForEach(trafficStore.services) { service in
                            serviceRow(service)
                            if service.id != trafficStore.services.last?.id {
                                Divider().padding(.leading, 76)
                            }
                        }
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
        .task { await probeNodeIPs() }
        .sheet(isPresented: $showManage) {
            ServiceManageSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func serviceRow(_ service: ConcordServiceItem) -> some View {
        Button {
            Task { await recheckOne(service) }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Text(serviceTileText(service.name))
                        .font(.system(size: service.name.lowercased() == "github" ? 13 : 20, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .frame(width: 48, height: 48)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
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
                        Text(nodeLine(for: service))
                            .lineLimit(1)
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
        }
        .buttonStyle(.plain)
        .disabled(trafficStore.isProbingServices)
    }

    private func serviceTileText(_ name: String) -> String {
        if name.lowercased() == "github" { return "GH" }
        return String(name.prefix(1)).uppercased()
    }

    /// Second line: the probed egress IP through the service's
    /// exit node; the node name while pending or when the probe
    /// failed; "—" when there is no node at all.
    private func nodeLine(for service: ConcordServiceItem) -> String {
        guard let node = service.chains?.first, !node.isEmpty else { return "—" }
        if let ip = nodeIPs[node] { return ip }
        return node
    }

    private func trailingText(for service: ConcordServiceItem) -> String {
        if service.status == "available", let delay = service.delay {
            return "\(delay) ms"
        }
        return dashboardServiceStatusLabel(service.status)
    }

    private func trailingColor(for service: ConcordServiceItem) -> Color {
        if service.status == "available", service.delay != nil {
            return Color(.label)
        }
        return dashboardServiceStatusColor(service.status)
    }

    private func recheckAll() async {
        guard let proxy = proxyStore.selectedOutbound else { return }
        await trafficStore.probeServices(proxy: proxy, names: trafficStore.orderedServiceNames)
        await probeNodeIPs()
    }

    private func recheckOne(_ service: ConcordServiceItem) async {
        guard let proxy = proxyStore.selectedOutbound else { return }
        await trafficStore.probeService(proxy: proxy, name: service.name)
        await probeNodeIPs()
    }

    /// Probes the egress IP through each distinct exit node
    /// (sequential: usually one or two nodes; a failed probe
    /// leaves the node name in place).
    private func probeNodeIPs() async {
        let nodes = Set(
            trafficStore.services.compactMap { $0.chains?.first }.filter { !$0.isEmpty })
        let pending = nodes.filter { nodeIPs[$0] == nil && !nodeIPPending.contains($0) }
        guard !pending.isEmpty else { return }
        for node in pending { nodeIPPending.insert(node) }
        for node in pending.sorted() {
            do {
                let result = try await client.probeOutboundIp(proxy: node)
                let ip = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty { nodeIPs[node] = ip }
            } catch {
                // Keep the node name as the fallback.
            }
            nodeIPPending.remove(node)
        }
    }
}

// MARK: - Profile providers sheet (config card)
//
// MuYu key_25: the active profile's name as the title, then
// one row per rule provider: name, "N 条规则", updated time
// right ("15 小时前"). Data is provider.list via RuleStore
// (ruleProviders = type == "rule"); count is the provider's
// rule count and updatedAt is epoch seconds. Top-right:
// refresh re-reads the list; the eye toggles between
// rule providers only and all providers (MuYu's eye action
// could not be verified from the frames, so it is this
// honest scope toggle, not a dead button).

struct ProvidersSheet: View {
    @EnvironmentObject private var ruleStore: RuleStore

    let profileName: String
    @State private var showAll = false
    @State private var isRefreshing = false

    private var providers: [ConcordProviderInfo] {
        let all = ruleStore.providers
        if showAll { return all }
        return all.filter { $0.type == "rule" }
    }

    var body: some View {
        DashboardBottomSheet(
            title: profileName,
            actions: {
                SheetActionsPill {
                    SheetActionButton(systemImage: "arrow.clockwise", label: "刷新", disabled: isRefreshing) {
                        Task {
                            isRefreshing = true
                            defer { isRefreshing = false }
                            await ruleStore.refresh()
                        }
                    }
                    SheetActionButton(
                        systemImage: showAll ? "eye.slash" : "eye",
                        label: showAll ? "仅显示规则提供方" : "显示全部提供方",
                        disabled: false
                    ) {
                        showAll.toggle()
                    }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if providers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ruleStore.providers.isEmpty ? "暂无提供方" : "暂无规则提供方")
                                .font(.subheadline.weight(.semibold))
                            Text("核心未返回提供方列表：请先启动 VPN，或点右上角刷新。")
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
            if ruleStore.providers.isEmpty {
                await ruleStore.refresh()
            }
        }
    }

    private func providerRow(_ provider: ConcordProviderInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(countText(for: provider))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(updatedText(for: provider))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

// MARK: - Traffic statistics sheet (traffic card)
//
// MuYu key_28 + views/traffic_statistics.dart: 日/周/月
// segmented control, date navigator, a 流量概括 card (total,
// down/up pills, dashed 45% 代理 gauge, 累计运行 + 代理/直连
// mini-cells), then a ranking list (策略/节点/域名 tabs).
// All figures come from TrafficStore's daily history
// (recorded since v0.2.55; ranges with no recorded day show
// "暂无记录", never invented numbers). The trash button clears
// the recorded history after confirmation; refresh re-reads
// the live snapshot.
//
// NOT in this sheet (no truthful source): the hourly trend
// chart (we keep no hourly buckets) and the rule-hit cards
// (no per-day rule-hit counts). The 配置 ranking tab is
// omitted — only one profile is ever active, so the row
// would just repeat the total.

private enum TrafficRankingTab: String, CaseIterable {
    case policy, node, domain

    var title: String {
        switch self {
        case .policy: return "策略"
        case .node: return "节点"
        case .domain: return "域名"
        }
    }
}

private struct TrafficRankingRow: Identifiable {
    let id: String
    let up: Int64
    let down: Int64

    var total: Int64 { up + down }
}

struct TrafficStatsSheet: View {
    @EnvironmentObject private var trafficStore: TrafficStore

    @State private var range: TrafficRange = .day
    @State private var offset = 0
    @State private var rankingTab: TrafficRankingTab = .policy
    @State private var showClearConfirm = false

    private var dates: [String] { trafficStore.rangeDates(range: range, offset: offset) }
    private var totals: DayTotals { trafficStore.totalsForDates(dates) }
    private var isToday: Bool { range == .day && offset == 0 }

    private var rankedRows: [TrafficRankingRow] {
        let buckets: [String: TrafficStore.DaySplit]
        switch rankingTab {
        case .policy: buckets = totals.groups
        case .node: buckets = totals.nodes
        case .domain: buckets = totals.domains
        }
        return buckets
            .map { TrafficRankingRow(id: $0.key, up: $0.value.up, down: $0.value.down) }
            .sorted { $0.total > $1.total }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("范围", selection: $range) {
                        ForEach(TrafficRange.allCases, id: \.self) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: range) { _, _ in offset = 0 }
                    dateNavigator
                    if totals.recordedDays == 0 {
                        Text("暂无记录：该范围没有已记录的流量。自 v0.2.55 起记录每日流量，升级前的数据没有记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
                    } else {
                        summaryCard
                        rankingSection
                        Text("代理/直连与排行按连接采样统计，仅含应用运行时观测到的流量；短连接与后台流量可能未计入，拆分之和可能小于总流量。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
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
            Text("将删除自 v0.2.55 起记录的每日流量、代理/直连拆分与排行，今日从零开始重新记录。核心累计流量不受影响。")
        }
    }

    private var dateNavigator: some View {
        HStack {
            Button { offset += 1 } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.label))
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
                    .foregroundStyle(Color(.label))
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
                    Text(isToday ? trafficStore.todayUptimeText : "—")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
            if !isToday {
                Text("累计运行仅统计今日，历史范围的运行时间暂未保存。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: ConcordTheme.panelRadius))
    }

    private func trafficPill(label: String) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ConcordTheme.softFill, in: Capsule())
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("流量排行")
                .font(.headline)
            Picker("排行", selection: $rankingTab) {
                ForEach(TrafficRankingTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ConcordTheme.softFill)
                    .frame(width: 40, height: 40)
                Image(systemName: "globe")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("↓ \(dashboardBytesNoSpace(row.down))  ↑ \(dashboardBytesNoSpace(row.up))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    @Binding var isReleasing: Bool
    @Binding var releaseMessage: String?
    let onRelease: () async -> Void

    var body: some View {
        DashboardBottomSheet(title: "内存") {
            List {
                Section("总计") {
                    memoryRow("应用 + 核心", value: ConcordFormat.bytes(Int64(appBytes + (coreBytes ?? 0))))
                    Text("应用与核心是两个进程（应用进程与 NetworkExtension 进程），两项相加是占用总和。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("应用") {
                    memoryRow("常驻内存", value: ConcordFormat.bytes(Int64(appBytes)))
                }
                Section("核心") {
                    if let core = coreBytes {
                        memoryRow("RSS", value: ConcordFormat.bytes(Int64(core)))
                    } else {
                        Text("核心未运行，无内存数据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("core.stats 只暴露 rss。NetworkExtension 进程内存上限很紧（历史约 15–50 MB），大规则集与 GeoIP 可能触发 Jetsam。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button(isReleasing ? "释放中…" : "释放核心内存（core.releaseMemory）") {
                        Task { await onRelease() }
                    }
                    .disabled(isReleasing || coreBytes == nil)
                    if let message = releaseMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .scrollContentBackground(.hidden)
        }
    }

    private func memoryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
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
