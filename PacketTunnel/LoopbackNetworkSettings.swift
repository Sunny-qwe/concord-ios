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
    /// NEIPv4Settings (the fork's `options.loopbackDevice` branch).
    /// `NEIPv4Settings.addresses` / `subnetMasks` are get-only, so
    /// the address can only be added by rebuilding the settings
    /// object — this returns a new one (carrying over
    /// includedRoutes / excludedRoutes) when the address is missing,
    /// and the same object otherwise. Call AFTER `includedRoutes`
    /// is set (the peer route is appended to it). Idempotent:
    /// calling twice adds nothing twice. No-op when `enabled` is
    /// false. Callers must use the return value.
    static func apply(to ipv4Settings: NEIPv4Settings, enabled: Bool) -> NEIPv4Settings {
        guard enabled else { return ipv4Settings }
        var result = ipv4Settings
        if !ipv4Settings.addresses.contains(tunnelAddress) {
            result = NEIPv4Settings(
                addresses: ipv4Settings.addresses + [tunnelAddress],
                subnetMasks: ipv4Settings.subnetMasks + [tunnelSubnetMask])
            result.includedRoutes = ipv4Settings.includedRoutes
            result.excludedRoutes = ipv4Settings.excludedRoutes
        }
        var routes = result.includedRoutes ?? []
        if !routes.contains(where: { $0.destinationAddress == peerAddress }) {
            routes.append(NEIPv4Route(
                destinationAddress: peerAddress,
                subnetMask: peerRouteSubnetMask
            ))
            result.includedRoutes = routes
        }
        return result
    }
}

// MARK: - Provider hook (already applied in PacketTunnelProvider.swift)
//
//   1. `TunnelSettings` has the `loopbackDevice: Bool` field.
//   2. `readTunnelSettings(container:)` reads it in both return
//      paths (`LoopbackNetworkSettings.isEnabled(in: json)` when the
//      file is present, `false` in the fallback).
//   3. `bootCore()` calls it right after the IPv4 settings are
//      built: `ipv4 = LoopbackNetworkSettings.apply(to: ipv4,
//      enabled: tun.loopbackDevice)` — the return value must be
//      used because apply() may rebuild the settings.
//
// Do NOT add the flag to `tunTripleFingerprint`'s doc["tunnel"]:
// the NE interface settings are built once at startup, so a live
// toggle cannot take effect until the VPN restarts — fingerprinting
// it would only trigger a pointless channel TUN re-start. The
// switch takes effect at the next VPN start, and the UI says so.
