# patches/ — upstream Concord changes for the iOS port

These patches are the ONLY upstream changes. The upstream tree itself is
never copied into this repo: the GitHub workflow checks out
`chen08209/concord` at the pinned commit below and applies these patches at
build time. A local inspection copy lives at `../upstream/` (gitignored,
never uploaded).

- **Pinned upstream commit:** `187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6`
  (`ci: raise the desktop binary budget to 30 MB`, 2026-11-16)
- **Produced from:** `../upstream/` on branch `ios-port`
  (`git format-patch 187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6`)
- **Apply order:** `01`, then `02`, then `03`, then `04` (filenames sort in order).

## The patches

| # | File | What it does |
|---|---|---|
| `01-bins-ios.patch` | `bins/ios/*` (new), `Cargo.toml` | New iOS staticlib crate mirroring `bins/android`: `crate-type = ["staticlib", "rlib"]`, lib name `concord_ios`, `concord_start()` with no thread hook, `Core` with `EngineConfig { android: false }` and capabilities `["tun.inherited", "tun.channel"]`, an `IosPlatform` with no host callbacks (`protect` is a no-op `true`, `find_owner` is `None`), the Option A `SOCK_DGRAM` socketpair bridge (`concord_ios_bridge_open/close`), and the hand-written C header `concord_ios.h`. Also adds `"bins/ios"` to the workspace members. Builds the FULL upstream workspace — no feature trimming (see below). |
| `02-packet-channel.patch` | `crates/tun/src/channel.rs` (new), `crates/tun/src/{lib,runner}.rs`, `crates/proto/src/types/live.rs`, `schema/api.json`, `crates/api/src/{channels.rs (new),lib.rs,control.rs}`, `crates/api/Cargo.toml`, `crates/engine/src/engine.rs`, `crates/ffi/src/{abi,hub,lib}.rs` | Option B (correct fix): promotes the `FakeDevice` pattern of `crates/tun/src/testing.rs` to a production channel device; adds `DeviceSource::Channel` and `TunSource::channel` (`{"kind": "channel", "handle": …}`); a `PacketChannels` registry in `crates/api`; `Engine::start_channel_tun`; and the `concord_packet_channel_open/write/read/close` FFI. The iOS host pumps `packetFlow` packets through the channel — no file descriptor involved. |
| `03-tun-wrap-ios-fix.patch` | `crates/tun/src/device/mod.rs` | Prerequisite for ANY iOS build: `TunDevice::wrap` calls `inner.name()` / `inner.if_index()`, which do not exist on the generic unix `DeviceImpl` used on iOS (`vendor/tun-rs`), so `concord-tun` does not compile for `aarch64-apple-ios` as-is. Cfg-gates the lookup to the targets that have it; iOS/illumos get the empty name / `None` index the Android path already uses. Needed by Option A too, not just Option B. |
| `04-nix-ios-fix.patch` | `vendor/nix-0.31.3-ios/*` (new, 127 files), `Cargo.toml`, `vendor/PATCHES.md`, `vendor/UPSTREAM.sha256` | Vendors nix 0.31.3 and gates its macOS-only utun/kern-control items to macOS. nix gates `KextControl` / `UtunIfname` on `apple_targets` (any of iOS/macOS/watchOS/tvOS/visionOS), but libc defines `SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` only on macOS, so nix fails for `aarch64-apple-ios` with E0425 (run #2 of `ios-core-check`, log lines 819-843). The chain: `concord-proxy` (WireGuard stack) → `gotatun` 0.10.2 → its unix `nix` dependency with `net`/`socket` features. `GetCString` (only used by `UtunIfname`) is gated the same way, or nix's `#![deny(unused)]` fails the build. Follows upstream's own vendoring discipline: `[patch.crates-io]` entry, `vendor/PATCHES.md` section + table row, `UPSTREAM.sha256` manifest (validated by `cargo test -p xtask vendor_patches`). No workflow change needed: the patch carries the whole vendored copy, so the runner just applies patches and builds. |

## How to apply (manual)

```bash
git clone https://github.com/chen08209/concord upstream-checkout
cd upstream-checkout
git checkout 187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6
git apply /path/to/concord-ios/patches/01-bins-ios.patch
git apply /path/to/concord-ios/patches/02-packet-channel.patch
git apply /path/to/concord-ios/patches/03-tun-wrap-ios-fix.patch
git apply /path/to/concord-ios/patches/04-nix-ios-fix.patch
cargo build --release --target aarch64-apple-ios -p concord-ios
# -> target/aarch64-apple-ios/release/libconcord_ios.a
```

`git apply --check` first if you only want to test. The patches were
verified against a fresh clone at the pinned commit with zero rejects
(see the build report).

## No feature trimming

`bins/ios` depends on the same workspace crates as `bins/android`, with
default features on: `concord-engine` default `mitm`, `concord-mitm`
default `script` (rquickjs). All protocols, transports, DNS, rules, TUN
and MITM come along. Deliberately NOT included, with reasons:

- `tun.device` capability — not a Cargo feature; excluded because the core
  must not create its own TUN device inside a NetworkExtension (the system
  owns the tunnel interface). `tun.inherited` + `tun.channel` are the iOS
  paths.
- `concord-ipc` (desktop child-process IPC) — the desktop out-of-process
  model; iOS forbids spawning a helper process, so the core runs
  in-process and the app talks to the extension via App Groups /
  `NEProviderManager`, not via this crate.
- Android host callbacks (`protect` / `resolve_uid` / `resolve_package`)
  — there is no `VpnService` on iOS; replaced by no-ops in `IosPlatform`
  (see `bins/ios/src/platform.rs`).
- Linux/macOS/Windows-only code (rtnetlink, vnet, wintun, route_manager,
  core-foundation) — target-gated upstream, simply not compiled for iOS.

Unverified iOS build risks (nothing trimmed to dodge them — they must be
proven on a macOS runner): `boring-sys` 5.4, `aws-lc-sys` and `rquickjs`
0.14 all compiled for `aarch64-apple-ios` in `ios-core-check` run #2, so
BoringSSL is no longer the risk — the run then failed on nix 0.31.3
(`SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` missing on iOS), fixed by patch
`04` (vendored nix with macOS-only gating; verified locally with
`cargo check --target aarch64-apple-ios` on nix itself and on
`concord-proxy`, which stops afterwards only at `aws-lc-sys` needing the
Apple SDK's `xcrun` — absent on Linux, present on the runner). Still
unverified: the rest of the staticlib build after nix, the Xcode archive
with the staticlib linked, the Swift side compiling, and the
packet-channel bridge forwarding real traffic on a device.
