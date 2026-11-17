import Foundation
import Combine

// MARK: - Config / subscription store
// The App Group container is the single place the app and the
// PacketTunnel extension share files:
//   config.yaml          the active profile YAML (written by ProfileStore)
//   profiles/<uuid>.yaml one file per imported profile (ProfileStore)
//   mitm.json            MITM choices, merged into config.apply's overlay
//   module-mitm.json     merged MITM lists + rules of the enabled
//                        MITM modules (written by MitmModuleStore),
//                        merged into the overlay next to mitm.json;
//                        module scripts / map-local files live in
//                        mitm/resources/ (the core's resources dir)
//   dns.json             DNS choices, merged into config.apply's overlay
//   tunnel.json          tunnel parameters (stack, MTU, DNS, IPv6)
//   general.json         general settings, patched at tunnel start
//   snapshots/*.json     live snapshots the extension writes for the app
//                        (traffic / connections / logs / dns / proxies /
//                        delay — see PacketTunnelProvider.swift)
//
// Profile download / import / switching lives in ProfileStore, which
// owns the ConcordClient: importing only writes a file, switching
// validates it and applies it via config.apply. This store only owns
// the shared paths, so nothing here pretends to talk to the core.

final class ConfigStore: ObservableObject {
    static let appGroupID = "group.com.sunny-qwe.concord-ios"
    static let configFileName = "config.yaml"
    static let mitmFileName = "mitm.json"
    static let moduleMitmFileName = "module-mitm.json"
    static let dnsFileName = "dns.json"
    static let tunnelSettingsFileName = "tunnel.json"
    static let generalSettingsFileName = "general.json"

    /// Snapshot files the PacketTunnel extension writes for the app's
    /// live transport (see PacketTunnelProvider.swift):
    ///   snapshots/traffic.json | connections.json | logs.json | dns.json
    ///   | proxies.json | delay.json
    /// Each file is {"updatedAt": <epoch ms>, "data": <payload>}.
    static func snapshotURL(name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("snapshots")
            .appendingPathComponent("\(name).json")
    }

    /// Shared files the extension reads (mitm.json, dns.json,
    /// tunnel.json, general.json). Plain JSON in the App Group
    /// container; the extension merges mitm.json / dns.json into
    /// config.apply's overlay and reads tunnel.json / general.json
    /// for tun.start / the tunnel interface settings.
    static func sharedFileURL(name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    /// Absolute path of a file inside the App Group container. The
    /// core reads profile files with a plain fs::read in the extension
    /// process (upstream crates/engine/src/ops.rs), where a relative
    /// path would resolve against an undocumented working directory —
    /// so every profile-ref call (config.validate, config.read,
    /// profile.inspect, convert.subscription, profile.build,
    /// ruleSet.dump) passes an absolute path built here.
    static func absolutePath(relative path: String) -> String? {
        sharedFileURL(name: path)?.path
    }

    static func absolutePath(url: URL) -> String {
        url.path
    }
}
