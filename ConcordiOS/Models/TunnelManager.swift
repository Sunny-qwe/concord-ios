import Foundation
import Combine
import NetworkExtension

// MARK: - TunnelManager: the app side of the extension IPC
//
// The app NEVER loads the Concord core (it runs in the PacketTunnel
// extension process; see PacketTunnel/PacketTunnelProvider.swift).
// This manager is the app's only handle on the tunnel:
//
//   * start/stop the system VPN (NETunnelProviderManager), which in
//     turn boots / tears down the core inside the extension;
//   * sendProviderMessage: carry ONE JSON-RPC 2.0 request per message
//     to the extension and await its reply bytes (used by
//     ExtensionConcordTransport for every unary core method).
//
// Live snapshots (traffic / connections / logs / dns) do NOT go through
// here: the extension writes them to the App Group container and the
// live transport reads the files (see ConfigStore.snapshotURL).
//
// First launch: loadAllFromPreferences finds no saved manager, so one
// is created (providerBundleIdentifier below, serverAddress "Concord")
// and saved. Starting the VPN the first time prompts the user for VPN
// permission; that prompt, and the `packet-tunnel-provider`
// entitlement, require a paid Apple Developer Program provisioning
// profile (see SIGNING.md).

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    static let providerBundleID = "com.concord.ios.PacketTunnel"
    static let serverAddress = "Concord"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    var isRunning: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? NEVPNConnection else { return }
            self.status = connection.status
        }
        Task { try? await self.prepare() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// Load the saved manager, or create + save one on first launch.
    @MainActor
    func prepare() async throws {
        if manager != nil { return }
        let managers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
        if let existing = managers.first {
            manager = existing
        } else {
            let created = NETunnelProviderManager()
            created.localizedDescription = "Concord"
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleID
            proto.serverAddress = Self.serverAddress
            created.protocolConfiguration = proto
            created.isEnabled = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                created.saveToPreferences { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            manager = created
        }
        if let connection = manager?.connection {
            status = connection.status
        }
    }

    /// Start the system VPN. The extension's startTunnel boots the
    /// core; a failure there surfaces as a status change to
    /// .disconnected (the error itself is logged by the extension).
    @MainActor
    func start() async throws {
        try await prepare()
        guard let manager else {
            throw TunnelError.noManager
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Stop the system VPN. The extension's stopTunnel tears down the
    /// core (tun.stop -> engine.stop -> close session).
    @MainActor
    func stop() async {
        try? await prepare()
        manager?.connection.stopVPNTunnel()
    }

    /// Send one JSON-RPC request to the extension and await its reply.
    /// Throws TunnelError.notRunning unless the tunnel is connected,
    /// and TunnelError.noReply when the extension answers nothing.
    func sendProviderMessage(_ data: Data) async throws -> Data {
        guard isRunning, let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelError.notRunning
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    if let reply {
                        continuation.resume(returning: reply)
                    } else {
                        continuation.resume(throwing: TunnelError.noReply)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum TunnelError: LocalizedError {
    case noManager
    case notRunning
    case noReply

    var errorDescription: String? {
        switch self {
        case .noManager:
            return "VPN 配置尚未创建（请先允许 VPN 权限）"
        case .notRunning:
            return "VPN 隧道未运行：请先在仪表盘启动 VPN，再查看实时数据"
        case .noReply:
            return "扩展未回复（隧道可能正在启动或已断开）"
        }
    }
}
