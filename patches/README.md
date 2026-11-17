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
- **Apply order:** `01`, then `02`, then `03`, then `04`, then `05`, then `06` (filenames sort in order).

## The patches

| # | File | What it does |
|---|---|---|
| `01-bins-ios.patch` | `bins/ios/*` (new), `Cargo.toml` | New iOS staticlib crate mirroring `bins/android`: `crate-type = ["staticlib", "rlib"]`, lib name `concord_ios`, `concord_start()` with no thread hook, `Core` with `EngineConfig { android: false }` and capabilities `["tun.inherited", "tun.channel"]`, an `IosPlatform` with no host callbacks (`protect` is a no-op `true`, `find_owner` is `None`), the Option A `SOCK_DGRAM` socketpair bridge (`concord_ios_bridge_open/close`), and the hand-written C header `concord_ios.h`. Also adds `"bins/ios"` to the workspace members. Builds the FULL upstream workspace — no feature trimming (see below). |
| `02-packet-channel.patch` | `crates/tun/src/channel.rs` (new), `crates/tun/src/{lib,runner}.rs`, `crates/proto/src/types/live.rs`, `schema/api.json`, `crates/api/src/{channels.rs (new),lib.rs,control.rs}`, `crates/api/Cargo.toml`, `crates/engine/src/engine.rs`, `crates/ffi/src/{abi,hub,lib}.rs` | Option B (correct fix): promotes the `FakeDevice` pattern of `crates/tun/src/testing.rs` to a production channel device; adds `DeviceSource::Channel` and `TunSource::channel` (`{"kind": "channel", "handle": …}`); a `PacketChannels` registry in `crates/api`; `Engine::start_channel_tun`; and the `concord_packet_channel_open/write/read/close` FFI. The iOS host pumps `packetFlow` packets through the channel — no file descriptor involved. |
| `03-tun-wrap-ios-fix.patch` | `crates/tun/src/device/mod.rs` | Prerequisite for ANY iOS build: `TunDevice::wrap` calls `inner.name()` / `inner.if_index()`, which do not exist on the generic unix `DeviceImpl` used on iOS (`vendor/tun-rs`), so `concord-tun` does not compile for `aarch64-apple-ios` as-is. Cfg-gates the lookup to the targets that have it; iOS/illumos get the empty name / `None` index the Android path already uses. Needed by Option A too, not just Option B. |
| `04-nix-ios-fix.patch` | `vendor/nix-0.31.3-ios/*` (new, 127 files), `Cargo.toml`, `vendor/PATCHES.md`, `vendor/UPSTREAM.sha256` | Vendors nix 0.31.3 and gates its macOS-only utun/kern-control items to macOS. nix gates `KextControl` / `UtunIfname` on `apple_targets` (any of iOS/macOS/watchOS/tvOS/visionOS), but libc defines `SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` only on macOS, so nix fails for `aarch64-apple-ios` with E0425 (run #2 of `ios-core-check`, log lines 819-843). The chain: `concord-proxy` (WireGuard stack) → `gotatun` 0.10.2 → its unix `nix` dependency with `net`/`socket` features. `GetCString` (only used by `UtunIfname`) is gated the same way, or nix's `#![deny(unused)]` fails the build. Follows upstream's own vendoring discipline: `[patch.crates-io]` entry, `vendor/PATCHES.md` section + table row, `UPSTREAM.sha256` manifest (validated by `cargo test -p xtask vendor_patches`). No workflow change needed: the patch carries the whole vendored copy, so the runner just applies patches and builds. |
| `05-rquickjs-ios-fix.patch` | `crates/mitm/Cargo.toml` | Enables the `bindgen` feature of `rquickjs` for `target_os = "ios"`, mirroring the Android block in the same file. `rquickjs-sys` 0.14.0 ships pre-generated bindings for darwin/linux/windows/wasm only — there is no `bindings/aarch64-apple-ios.rs`, so the build fails in `src/lib.rs:19` (`include!(concat!("bindings/", bindings_env!("TARGET"), ".rs"))`) with "couldn't find file .../aarch64-apple-ios.rs" (run #4 of `ios-core-check`, log lines 920-930). With `bindgen` on, `rquickjs-sys/build.rs` generates the bindings at build time from `quickjs.bind.h`. The chain: `concord-ios` → `concord-engine` (default `mitm`) → `concord-mitm` (default `script`) → `rquickjs` 0.14, used by the MITM script engine (`crates/mitm/src/quickjs/`, `mitm.runScript`). No vendoring: bindgen finds Xcode's libclang itself — `clang-sys` 1.9.1 (the locked version) searches `xcode-select --print-path`/Toolchains/`XcodeDefault.xctoolchain/usr/lib` and the hardcoded `/Applications/Xcode.app/...` path, and the workflow already selects that Xcode — so no `LIBCLANG_PATH` is needed. **Workflow change still needed (one line, in the "Build Concord staticlib" step of both `ios-core-check.yml` and `ios.yml`):** `export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path) --target=arm64-apple-ios"` so bindgen parses against the iOS SDK headers instead of the macOS SDK (same mechanism upstream CI uses for Android: `BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android` in `ci.yaml`). Verified locally: `cargo tree --target aarch64-apple-ios -p concord-mitm -e features -i rquickjs-sys` shows `bindgen` enabled, and with a local libclang the build script ran bindgen and wrote a 2,334-line `bindings.rs` for `arm64-apple-ios` that is identical to the bundled `aarch64-apple-darwin.rs` except for one typedef alias (`size_t` vs `__darwin_size_t` — a header-stub artifact, not a real difference); the build then stops only at `cc-rs` needing `xcrun` for the iOS SDK, which exists only on the runner. |
| `06-tun-devicebuilder-ios-fix.patch` | `crates/tun/src/device/mod.rs` | Gates `TunDevice::create` / `build` off iOS and adds an iOS `create` stub returning `Unsupported`, mirroring the Android stub. Root cause: tun-rs 2.8.16 compiles its `builder` module only for windows/linux/macos/freebsd/openbsd/netbsd/illumos (`vendor/tun-rs/src/lib.rs`), so `tun_rs::DeviceBuilder::new()` in `build` fails for `aarch64-apple-ios` with E0433 (run #8 of `ios-core-check`, 2026-11-16 15:01). iOS never creates a device anyway: the NetworkExtension owns the interface and the core gets packets through the packet channel (patch 02) or an adopted descriptor (`AsyncDevice::from_fd`, which tun-rs DOES export on iOS via its generic unix `DeviceImpl`). No vendoring: this touches Concord's own code, not tun-rs. Verified locally: `cargo check -p concord-tun --target aarch64-apple-ios` passes, `cargo check -p concord-tun --target x86_64-apple-darwin` passes (no macOS regression), and patches 01–06 applied to a fresh clone at 187ac9d produce a tree byte-identical to the `ios-port` branch. |

## How to apply (manual)

```bash
git clone https://github.com/chen08209/concord upstream-checkout
cd upstream-checkout
git checkout 187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6
git apply /path/to/concord-ios/patches/01-bins-ios.patch
git apply /path/to/concord-ios/patches/02-packet-channel.patch
git apply /path/to/concord-ios/patches/03-tun-wrap-ios-fix.patch
git apply /path/to/concord-ios/patches/04-nix-ios-fix.patch
git apply /path/to/concord-ios/patches/05-rquickjs-ios-fix.patch
git apply /path/to/concord-ios/patches/06-tun-devicebuilder-ios-fix.patch
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
proven on a macOS runner): `boring-sys` 5.4 and `aws-lc-sys` compiled for
`aarch64-apple-ios` in `ios-core-check` run #2, so BoringSSL is no longer
the risk. The run then failed on nix 0.31.3
(`SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` missing on iOS), fixed by patch
`04` (vendored nix with macOS-only gating; verified locally with
`cargo check --target aarch64-apple-ios` on nix itself and on
`concord-proxy`, which stops afterwards only at `aws-lc-sys` needing the
Apple SDK's `xcrun` — absent on Linux, present on the runner). Run #4
then failed on `rquickjs-sys` 0.14.0 (no pre-generated bindings for
`aarch64-apple-ios`), fixed by patch `05` (`bindgen` feature for iOS, as
Android already does; local bindgen run produces bindings identical to
the bundled darwin ones — see the `05` row above). Run #8 then failed on
`concord-tun` (`tun_rs::DeviceBuilder` does not exist on iOS — tun-rs
compiles its builder only for windows/linux/macos/BSD/illumos), fixed by
patch `06` (device creation cfg-gated off iOS in Concord's own code, with
an `Unsupported` stub like Android's; `cargo check -p concord-tun` passes
for both `aarch64-apple-ios` and `x86_64-apple-darwin` — see the `06` row
above). Still unverified: the rest of the staticlib build after
concord-tun, the Xcode archive with the staticlib linked, the Swift side
compiling, and the packet-channel bridge forwarding real traffic on a
device.

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.
