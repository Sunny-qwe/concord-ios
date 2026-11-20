import SwiftUI
import Combine

// MARK: - Icon sets (FlClash: IconSetsView, lib/views/config/icon_sets.dart)
// FlClash icon sets are downloadable packs (remote URL or local
// file) that map proxy types to custom images, synced and managed
// in-app. The Concord core has NO icon-set interface (see
// AdvancedConfigView.swift), so this port is CLIENT-SIDE ONLY:
// three built-in packs that map each proxy / group type to an SF
// Symbol (+ a colour), persisted in UserDefaults and applied to
// the node cards in ProxiesView. No import-from-URL/file, no sync,
// no remote packs — there is no core or server side to sync with.

// MARK: - Store

final class IconSetStore: ObservableObject {
    static let shared = IconSetStore()
    static let storageKey = "ConcordiOS.iconSet.pack.v1"

    struct Pack: Identifiable {
        let id: String
        let name: String
        let description: String
        /// Per-type SF Symbol; missing types fall back to "circle.fill".
        let symbols: [String: String]
        /// Per-type tint; nil means the theme accent for every type.
        let colors: [String: Color]?

        var isColorful: Bool { colors != nil }
    }

    /// Proxy / group type -> SF Symbol, shared by every pack.
    static let typeSymbols: [String: String] = [
        "shadowsocks": "bolt.fill",
        "vmess": "waveform",
        "vless": "waveform.circle.fill",
        "trojan": "shield.fill",
        "hysteria2": "wind",
        "hysteria": "wind",
        "tuic": "paperplane.fill",
        "socks5": "arrow.left.arrow.right",
        "socks": "arrow.left.arrow.right",
        "http": "globe",
        "snell": "bolt.circle",
        "wireguard": "lock.shield.fill",
        "anytls": "key.fill",
        "select": "list.bullet",
        "url-test": "speedometer",
        "fallback": "arrow.triangle.2.circlepath",
        "load-balance": "square.stack.3d.up.fill",
        "relay": "link",
        "direct": "arrow.up.right",
        "reject": "nosign",
        "dns": "server.rack",
    ]

    /// Per-type colours for the 彩色 pack.
    static let typeColors: [String: Color] = [
        "shadowsocks": .blue,
        "vmess": .purple,
        "vless": .indigo,
        "trojan": .orange,
        "hysteria2": .green,
        "hysteria": .green,
        "tuic": .teal,
        "socks5": .gray,
        "socks": .gray,
        "http": .brown,
        "snell": .pink,
        "wireguard": .cyan,
        "anytls": .yellow,
        "select": .blue,
        "url-test": .green,
        "fallback": .yellow,
        "load-balance": .purple,
        "relay": .gray,
        "direct": .green,
        "reject": .red,
        "dns": .blue,
    ]

    /// The proxy types shown in the preview grid.
    static let previewTypes = ["shadowsocks", "vmess", "vless", "trojan", "hysteria2", "tuic", "socks5", "http", "snell", "wireguard", "select", "url-test", "fallback", "load-balance", "relay", "direct", "reject", "dns"]

    static let packs: [Pack] = [
        Pack(id: "default", name: "默认", description: "系统图标，按主题色显示", symbols: typeSymbols, colors: nil),
        Pack(id: "color", name: "彩色", description: "每种代理类型一个颜色", symbols: typeSymbols, colors: typeColors),
        Pack(id: "outline", name: "线条", description: "描边风格，全部用主题色", symbols: typeSymbols.mapValues { $0.replacingOccurrences(of: ".fill", with: "") }, colors: nil),
    ]

    @Published var selectedPackID: String {
        didSet { save() }
    }

    var selectedPack: Pack {
        Self.packs.first { $0.id == selectedPackID } ?? Self.packs[0]
    }

    private init() {
        selectedPackID = UserDefaults.standard.string(forKey: Self.storageKey) ?? "default"
        if Self.packs.first(where: { $0.id == selectedPackID }) == nil {
            selectedPackID = "default"
        }
    }

    private func save() {
        UserDefaults.standard.set(selectedPackID, forKey: Self.storageKey)
    }

    /// The SF Symbol for a proxy / group type in the selected pack.
    func symbol(for type: String) -> String {
        selectedPack.symbols[type.lowercased()] ?? "circle.fill"
    }

    /// The tint for a proxy / group type in the selected pack.
    func color(for type: String) -> Color {
        selectedPack.colors?[type.lowercased()] ?? ConcordTheme.accent
    }

    /// The icon view used by the proxies list.
    func icon(for type: String, size: CGFloat = 10) -> some View {
        Image(systemName: symbol(for: type))
            .font(.system(size: size))
            .foregroundStyle(color(for: type))
    }
}

// MARK: - View

struct IconSetsView: View {
    @ObservedObject private var iconSetStore = IconSetStore.shared

    var body: some View {
        List {
            Section {
                ForEach(IconSetStore.packs) { pack in
                    Button {
                        iconSetStore.selectedPackID = pack.id
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                ForEach(["shadowsocks", "vmess", "trojan", "direct"], id: \.self) { type in
                                    Image(systemName: pack.symbols[type] ?? "circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(pack.colors?[type] ?? ConcordTheme.accent)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(.label))
                                Text(pack.description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if iconSetStore.selectedPackID == pack.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("图标集只影响本 App 内代理列表里节点类型旁的小图标。核心没有图标集接口，所以这里是纯客户端设置，不支持 FlClash 的从链接或文件导入图标包、也不做同步。")
                    .font(.system(size: 13))
            }

            Section("预览：\(iconSetStore.selectedPack.name)") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                    ForEach(IconSetStore.previewTypes, id: \.self) { type in
                        VStack(spacing: 4) {
                            iconSetStore.icon(for: type, size: 18)
                                .frame(width: 28, height: 28)
                            Text(type)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("图标集")
        .navigationBarTitleDisplayMode(.inline)
    }
}
