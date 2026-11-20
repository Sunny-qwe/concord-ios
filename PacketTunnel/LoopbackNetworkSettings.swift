import Foundation
import NetworkExtension

/// Loopback 10.7.0.1 — the NE-side half only (FlClash fork commit
/// 89aa066, "reflect 10.7.0.1 to the device behind a switch").
///
/// What the fork does, split in two:
///   * NE side (this file): when the switch is on, the tunnel
///     interface gets a second IPv4 address, 10.7.0.2, and a
///     10.7.0.1/32 route into the tunnel, so SideStore /
///     SideInstaller can still reach the device while the VPN is
///     on (otherwise the installer sees a full-tunnel VPN and
///     cannot connect back).
///   * sing-tun side (NOT done here, and NOT possible with the
///     pinned core): the fork also passes `loopback-address:
///     "10.7.0.1"` to the core's tun.start so sing-tun reflects
///     packets for 10.7.0.1 back to the device. Concord 165154c
///     has no such path — `TunConfig::from_map`
///     (crates/config/src/tun.rs) never reads "loopback-address"
///     (only crates/config/src/keys.rs registers the key), and the
///     engine's LoopbackGuard (crates/net/src/loopback.rs) only
///     remembers the core's own DIRECT sockets to refuse its own
///     traffic coming back; it takes no configurable addresses.
///     So the NE half alone routes 10.7.0.1 packets INTO the
///     tunnel, but nothing in the core sends them back out to the
///     device — the switch may not work. The UI says so plainly;
///     never claim otherwise.
///
/// This is a DIFFERENT mechanism from the tun.loopback-address
/// address list on the same page (LoopbackView): that list is a
/// config override sent to the core with config.apply, and the
/// core ignores it too (see the header comment there). This
/// switch is an NE interface setting, persisted in tunnel.json
/// under the key `loopback-device` (kebab-case, like the other
/// tunnel.json keys) and read by the extension at VPN start.
///
/// Pure helper: no I/O, no provider state. The coordinator hooks
/// it into PacketTunnelProvider.bootCore after the IPv4 settings
/// are built (see the hook note at the bottom) — this file alone
/// changes nothing until then.
///
/// Known interaction (not handled, same as the fork): when
/// bypass-private-route is on, the excluded 10.0.0.0/8 route
/// shadows this 10.7.0.1/32 included route (excluded wins in
/// NetworkExtension), so the switch is dead until that bypass
/// is off. The UI note does not promise otherwise.

enum LoopbackNetworkSettings {

    /// The address the installer listens on / connects to.
    static let peerAddress = "10.7.0.1"
    /// The tunnel interface's second IPv4 address (fork:
    /// loopbackTunnelAddress).
    static let tunnelAddress = "10.7.0.2"
    /// Subnet mask for the tunnel address (fork:
    /// loopbackTunnelSubnetMask, a /24).
    static let tunnelSubnetMask = "255.255.255.0"
    /// The peer route is a host route (/32).
    static let peerRouteSubnetMask = "255.255.255.255"

    /// tunnel.json key for the switch. Default OFF (missing key
    /// reads as false); the UI writes it, the extension reads it.
    static let tunnelSettingsKey = "loopback-device"

    /// Reads the switch from an already-parsed tunnel.json dict.
    /// Missing key or a non-Bool value means OFF.
    static func isEnabled(in tunnelJSON: [String: Any]) -> Bool {
        tunnelJSON[tunnelSettingsKey] as? Bool ?? false
    }

    /// Adds the loopback address + peer route to an already-built
    /// NEIPv4Settings (the fork's `options.loopbackDevice` branch,
    /// as a mutation instead of a rebuild so the provider's
    /// existing address / mask / route code stays untouched).
    /// Call AFTER `includedRoutes` is set (the peer route is
    /// appended to it). Idempotent: calling twice adds nothing
    /// twice. No-op when `enabled` is false.
    static func apply(to ipv4Settings: NEIPv4Settings, enabled: Bool) {
        guard enabled else { return }
        if !ipv4Settings.addresses.contains(tunnelAddress) {
            ipv4Settings.addresses = ipv4Settings.addresses + [tunnelAddress]
            ipv4Settings.subnetMasks = ipv4Settings.subnetMasks + [tunnelSubnetMask]
        }
        var routes = ipv4Settings.includedRoutes ?? []
        if !routes.contains(where: { $0.destinationAddress == peerAddress }) {
            routes.append(NEIPv4Route(
                destinationAddress: peerAddress,
                subnetMask: peerRouteSubnetMask
            ))
            ipv4Settings.includedRoutes = routes
        }
    }
}

// MARK: - Coordinator hook (do NOT apply from this file)
//
// PacketTunnelProvider.swift is owned by another worker for the
// SSID item; apply these three edits after that work lands:
//
//   1. `TunnelSettings` struct — add one field:
//        let loopbackDevice: Bool
//
//   2. `readTunnelSettings(container:)` — read the key in both
//      return paths (file present + fallback default):
//        let loopbackDevice = LoopbackNetworkSettings.isEnabled(in: json)
//      (file-present path) and `loopbackDevice: false` in the
//      fallback TunnelSettings initializer.
//
//   3. `bootCore()`, right after the IPv4 settings are built
//      (after `ipv4.includedRoutes = [NEIPv4Route.default()]`,
//      before `settings.ipv4Settings = ipv4`), add one line:
//        LoopbackNetworkSettings.apply(to: ipv4, enabled: tun.loopbackDevice)
//
// Do NOT add the flag to `tunTripleFingerprint`'s doc["tunnel"]:
// the NE interface settings are built once at startup, so a live
// toggle cannot take effect until the VPN restarts — fingerprinting
// it would only trigger a pointless channel TUN re-start. The
// switch takes effect at the next VPN start, and the UI says so.
