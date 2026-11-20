import SwiftUI

// MARK: - IP quality (Tools -> IP 质量)
// Shows the CURRENT egress IP's quality: address, country, city,
// ISP, ASN and timezone, from the free no-key ip-api.com endpoint
// (http://ip-api.com/json/, plain HTTP on the free tier — see the
// App Transport Security exception for ip-api.com in Info.plist).
// URLSession follows the system's default route, so when the VPN is
// on the answer IS the proxy egress IP, and when it is off it is the
// phone's direct IP. The page says which one it is, in the header
// and next to the result — the two must never be confused.
//
// No data is stored; each tap on 刷新 re-fetches. No network or an
// API error shows a clear message instead of stale numbers.

struct IPQualityInfo: Decodable {
    let status: String
    let message: String?
    let country: String?
    let countryCode: String?
    let city: String?
    let regionName: String?
    let isp: String?
    let org: String?
    let asn: String?
    let timezone: String?
    let query: String?
    let lat: Double?
    let lon: Double?
}

struct IPQualityView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var info: IPQualityInfo?
    @State private var latencyMs: Int?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var fetchedViaVPN: Bool?

    private var isViaVPN: Bool { tunnelManager.isRunning }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    BlobIcon(
                        systemName: isViaVPN ? "shield.lefthalf.filled" : "house.fill",
                        iconColor: .white,
                        blobColor: isViaVPN ? ConcordTheme.accent : .gray,
                        size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isViaVPN ? "代理出口 IP" : "本机直连 IP")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isViaVPN
                             ? "VPN 正在运行：下面是代理出口的 IP 质量。"
                             : "VPN 未运行：下面是你手机直连网络的 IP 质量，不是代理出口。开启 VPN 后再刷新，看到的才是代理出口。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button {
                    Task { await fetch() }
                } label: {
                    Label(isLoading ? "查询中…" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            if isLoading {
                Section { ProgressView("正在查询出口 IP…") }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }

            if let info, info.status == "success" {
                Section("IP 地址") {
                    LabeledContent("IP", value: info.query ?? "—")
                    if let latencyMs {
                        LabeledContent("查询延迟", value: "\(latencyMs) ms")
                    }
                    if let fetchedViaVPN {
                        LabeledContent("查询时 VPN", value: fetchedViaVPN ? "开启（代理出口）" : "关闭（本机直连）")
                    }
                    if let lat = info.lat, let lon = info.lon {
                        LabeledContent("经纬度", value: "\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))")
                    }
                }
                Section("地理位置") {
                    LabeledContent("国家", value: [info.country, info.countryCode.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                    LabeledContent("城市", value: [info.regionName, info.city].compactMap { $0 }.joined(separator: " · ").isEmpty ? "—" : [info.regionName, info.city].compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("时区", value: info.timezone ?? "—")
                }
                Section("网络归属") {
                    LabeledContent("运营商", value: info.isp ?? "—")
                    LabeledContent("组织", value: info.org ?? "—")
                    LabeledContent("ASN", value: info.asn ?? "—")
                }
            } else if info != nil {
                Section {
                    Text("查询服务返回失败：\(info?.message ?? "未知错误")")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("数据来自 ip-api.com（免费接口，无需 key）。它只告诉你出口 IP 是谁、在哪里、属于哪个运营商，不做测速、不判断节点能不能解锁流媒体。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("IP 质量")
        .task { await fetch() }
    }

    private func fetch() async {
        isLoading = true
        errorMessage = nil
        let started = Date()
        defer { isLoading = false }
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,message,country,countryCode,city,regionName,isp,org,as,timezone,query,lat,lon") else {
            errorMessage = "查询地址无效"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "查询服务不可用（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)），请检查网络后重试"
                return
            }
            let decoded = try JSONDecoder().decode(IPQualityInfo.self, from: data)
            latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            fetchedViaVPN = isViaVPN
            info = decoded
            if decoded.status != "success" {
                errorMessage = nil
            }
        } catch {
            errorMessage = "查询失败：\(error.localizedDescription)。请检查网络（VPN 开着时也要确认代理本身能联网）。"
        }
    }
}
