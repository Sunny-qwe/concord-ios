import NetworkExtension

// PacketTunnelProvider — Network Extension entry point.
// TODO: THIS IS NOT A WORKING DATA PLANE. It only shows the lifecycle and
// where Concord must be fed packets. Do not ship this as a working proxy.
//
// Architecture that must be built here:
//   1. Read config.yaml from the App Group shared container.
//   2. Start the Concord staticlib in-process (concord_ios_init/start in
//      rust/concord-ios-ffi) — do NOT spawn a child process; iOS forbids it.
//   3. Feed IP packets from packetFlow.readPackets() into Concord, and
//      write Concord's output packets back via packetFlow.writePackets().
//   4. Confirm how Concord's `tun.start` accepts an external packet flow —
//      that interface is currently UNKNOWN and must be read from source.
//   5. Keep memory low: Packet Tunnel has a tight memory limit
//      (historically ~15 MB, reported ~50 MB more recently). Large rule
//      sets / MITM / GeoIP can trigger Jetsam.

final class PacketTunnelProvider: NEPacketTunnelProvider {

    // TODO: replace with your real App Group.
    private let appGroupID = "group.com.sunny-qwe.concord-ios"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // TODO: read the shared config.yaml from the App Group container.
        // TODO: call concord_ios_init() / concord_ios_start(configPath).
        // TODO: configure tunnel network settings (addresses, routes, DNS)
        //       from the active config, then start the packet pump loop.
        //
        // Placeholder: report success without forwarding any traffic.
        // This will NOT proxy anything. Real implementation required.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { error in
            // TODO: on success, start reading packets in a loop and feeding
            // them to Concord; on failure, call completionHandler(error).
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // TODO: stop the packet pump, then call concord_ios_stop().
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // App <-> tunnel messaging (e.g. switch proxy group, reload config).
        // TODO: implement via sendProviderMessage / handleAppMessage.
        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }
}
