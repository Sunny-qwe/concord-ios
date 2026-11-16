import Foundation
import Combine

// MARK: - Config / subscription store
// Shares config with the PacketTunnel extension via the App Group container.
// TODO: the extension reads this file; the exact format Concord expects on
// iOS (YAML path vs. in-memory config) is still to be defined.

final class ConfigStore: ObservableObject {
    static let appGroupID = "group.com.sunny-qwe.concord-ios" // TODO: replace with your real App Group
    static let configFileName = "config.yaml"

    @Published var subscriptionURLString = ""
    @Published var statusMessage = "尚未导入配置"
    @Published var lastUpdated: Date?

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    var sharedConfigURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.configFileName)
    }

    /// Import a Clash/mihomo YAML subscription from a URL.
    /// TODO: validate the YAML, apply it via Concord config.apply, and
    /// surface Concord's config.warnings (unsupported nodes, etc.).
    func importSubscription(from urlString: String) async {
        guard let url = URL(string: urlString) else {
            statusMessage = "订阅链接无效"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try saveConfig(data)
            statusMessage = "已导入订阅（未验证，未接通 Concord）"
            lastUpdated = Date()
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Import a local Clash/mihomo YAML file.
    func importLocalFile(data: Data) {
        do {
            try saveConfig(data)
            statusMessage = "已导入本地配置（未验证，未接通 Concord）"
            lastUpdated = Date()
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func saveConfig(_ data: Data) throws {
        guard let url = sharedConfigURL else {
            throw NSError(domain: "ConcordiOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App Group 容器不可用，请检查 entitlements 与 App Group 配置"
            ])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
