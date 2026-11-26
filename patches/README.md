# patches/ — upstream Concord changes for the iOS port

These patches are the ONLY upstream changes. The upstream tree itself is
never copied into this repo: the GitHub workflow checks out
`chen08209/concord` at the pinned commit below and applies these patches at
build time. A local inspection copy lives at `../upstream/` (gitignored,
never uploaded).

- **Pinned upstream commit:** `33904fff812041498a5a647930138f5ad4f26013`
  (`fix(group): speak HTTP/1.1 without ALPN on downloads and URL tests, as mihomo`, 2026-11-25)
- **Produced from:** the rebase tree at `/home/hatch/workspace/scratch/v0.2.109/rebase` (fresh clone at
  `33904fff`, the 8 patches below applied in order), rebased
  2026-11-25 from the previous pin `fdea08a92b5da4c93171161715e48e7f72fcb9a5`.
  Verified: the 8 patches apply to a fresh clone at `33904fff`
  with zero rejects (see the "Rebase to 33904fff" section). The local inspection copy at `../upstream/` (branch `ios-port`)
  still points at the old pin until it is refreshed; the patches in this
  directory are the authority for the new pin.
- **Apply order:** `01`, then `02`, then `03`, then `04`, then `05`, then `06`, then `07`, then `08`, then `09` (filenames sort in order). The OLD patch `09` (driver-coop-budget) was removed in this rebase: its content (`2e2cc02`) is now in the core. A NEW patch `09` (ios-resident-memory) was added in v0.2.134; the number was reused because the slot was free.

## The patches

| # | File | What it does |
|---|---|---|
| `01-bins-ios.patch` | `bins/ios/*` (new), `Cargo.toml` | New iOS staticlib crate mirroring `bins/android`: `crate-type = ["staticlib", "rlib"]`, lib name `concord_ios`, `concord_start()` with no thread hook, `Core` with `EngineConfig { android: false }` and capabilities `["tun.inherited", "tun.channel"]`, an `IosPlatform` with no host callbacks (`protect` is a no-op `true`, `find_owner` is `None`), the Option A `SOCK_DGRAM` socketpair bridge (`concord_ios_bridge_open/close`), and the hand-written C header `concord_ios.h`. Also adds `"bins/ios"` to the workspace members. Builds the FULL upstream workspace — no feature trimming (see below). **Rebase note (5f1d090):** upstream refactored `Hub` to hold the `Server<Control>` instead of a separate `Control`, so `Hub::new` now takes 2 arguments `(handle, server)`; `core.rs` drops the third argument. **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** no changes — patch content identical to the 01d7a13 version. **Rebase note (4e3f9db):** no content changes — only the workspace-members hunk shifted by one line (upstream added `crates/quic` above `bins/ios`). **Rebase note (165154c):** no content changes — only the index hash shifted (upstream added `boring-sys` to the workspace deps and a `[profile.dev.package.boring-sys]` section in a region away from this patch's hunks). |
| `02-packet-channel.patch` | `crates/tun/src/channel.rs` (new), `crates/tun/src/{lib,runner}.rs`, `crates/proto/src/types/live.rs`, `schema/api.json`, `crates/api/src/{channels.rs (new),lib.rs,control.rs,control/tun.rs}`, `crates/api/Cargo.toml`, `crates/engine/src/engine/tun.rs`, `crates/ffi/src/{abi,hub,lib}.rs` | Option B (correct fix): promotes the `FakeDevice` pattern of `crates/tun/src/testing.rs` to a production channel device; adds `DeviceSource::Channel` and `TunSource::channel` (`{"kind": "channel", "handle": …}`); a `PacketChannels` registry in `crates/api`; `Engine::start_channel_tun`; and the `concord_packet_channel_open/write/read/close` FFI. The iOS host pumps `packetFlow` packets through the channel — no file descriptor involved. **Rebase note (5f1d090):** upstream REMOVED the `TunSource::channel` variant (`crates/proto/src/types/live.rs`), so this patch now re-adds it (with a doc comment marking it as the iOS packet-channel variant) and re-adds the `TunSource::Channel { handle }` arm in `tun.start` (`crates/api/src/control.rs`). `Hub` no longer holds a `Control`, so the four `packet_channel_*` methods go through `self.server.service().packet_channels()` instead of `self.control.packet_channels()`, and the `pub use channels::PacketChannels;` export in `crates/api/src/lib.rs` sits after the new `pub use concord_engine::ControllerCors;`. The tun-side `channel.rs` / `runner.rs` / `lib.rs` hunks applied cleanly. **Rebase note (01d7a13):** no content changes — the patch applied cleanly despite the watch report flagging it: upstream `b3744f7` only added a Linux/Android-gated `pub mod provision;` to `crates/tun/src/lib.rs` and moved `rtnetlink` under the combined linux/android target section of `crates/tun/Cargo.toml` (no iOS effect); `702bac2` / `5e353de` touched `crates/api/src/control.rs` and `schema/api.json` in regions away from the patch hunks, so only the hunk line numbers shifted. The `TunSource::Channel` variant, the `tun.start` arm, and the `concord_packet_channel_open` / `concord_packet_write` / `concord_packet_read` / `concord_packet_channel_close` FFI are unchanged. **Rebase note (73d6530): REWORKED** — upstream split the control surface by domain (`9fd36ab`: `crates/api/src/control.rs` became a thin `Control` struct plus `control/{config,lifecycle,mitm,network,profile,provider,proxy,tun}.rs`) and split `crates/engine/src/engine.rs` into child modules (`232e3a8`), and dropped `VpnTunRequest`. The `TunSource::Channel { handle }` arm in `tun.start` therefore moved from `control.rs` to the new `crates/api/src/control/tun.rs`, next to the `Inherited` arm it mirrors: it takes the device with `self.packet_channels().take_device(handle)` and calls `engine.start_channel_tun(device, InheritedTun { mtu, address, dns, congestion_controller })`, mapping errors with `tun_error` (the old arm built a JSON options string into the now-removed `VpnTunRequest` and checked a `bool`). `Engine::start_channel_tun` moved from `engine.rs` to the new `crates/engine/src/engine/tun.rs`, next to `start_inherited_tun`: it now takes `(ChannelDevice, InheritedTun)` and returns `Result<(), TunStartError>` (was `(ChannelDevice, VpnTunRequest) -> bool`), using `vpn_options(&tun)?` + `start_runner(..., DeviceSource::Channel(device), ...).await?` exactly like `start_inherited_tun` uses `DeviceSource::Adopt(fd)`; the `stack` field is no longer passed (`InheritedTun` has none — the `Inherited` arm ignores `params.stack` too). The `channels` field / init / `packet_channels()` accessor are still added to `Control` in `control.rs`; the import is now ungated (the old patch had it under `#[cfg(unix)]`, a latent inconsistency — the field is ungated and the FFI calls it on all platforms, and `channel.rs` itself has no cfg gates). Everything else in the patch is unchanged (`channels.rs`, `lib.rs`, `Cargo.toml`, `ffi` `abi`/`hub`/`lib`, `proto` `live.rs`, tun `channel.rs`/`runner.rs`/`lib.rs`, `api.json`). **Rebase note (4e3f9db): REWORKED** — upstream split `TunRunner::start`'s tail into `start_with` taking `TunDeps` (`0192321`, `6c459a2`): `platform_backend` now takes `&deps.tasks`, and `start_runner` gained a `tasks` parameter, so `start_with_device` calls `platform_backend(&deps.tasks)` and `start_with(options, device, platform, deps, dns)`, and `start_channel_tun` passes `self.shared.proxy_tasks.tasks()` to `start_runner` like `start_inherited_tun` does. The per-arm `start` shape (needed because `ChannelDevice` is not a `TunDevice`) and everything else in the patch are unchanged. **Rebase note (165154c):** no content changes — only the index hash and one hunk line number shifted (upstream's `api.json` grew by the `mitm.readModule` method in a region away from this patch's hunks). The watch report's expected failure at `crates/tun/src/runner.rs:135` did NOT materialize: the patch applies cleanly at `165154c`, as it does at `145c9e7`. **Rebase note (0c9788f):** no content changes — only hunk line numbers shifted (`live.rs` 299 → 410 and 311 → 422, `api.json` 4370 → 4624; upstream added ~111 lines above the `TunSource` hunk and 254 lines above the `api.json` hunk). The watch report's expected manual merge at `api.json` / `live.rs` did NOT materialize: the 721-line `api.json` growth (`mitm.query` + new connection fields) and the 131-line `live.rs` growth are all in regions away from the patch hunks, so the patch applies cleanly at `0c9788f`, as it does at `4db36a4`. |
| `03-tun-wrap-ios-fix.patch` | `crates/tun/src/device/mod.rs` | Prerequisite for ANY iOS build: `TunDevice::wrap` calls `inner.name()` / `inner.if_index()`, which do not exist on the generic unix `DeviceImpl` used on iOS (`vendor/tun-rs`), so `concord-tun` does not compile for `aarch64-apple-ios` as-is. Cfg-gates the lookup to the targets that have it; iOS/illumos get the empty name / `None` index the Android path already uses. Needed by Option A too, not just Option B. **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** no changes — patch content identical to the 01d7a13 version. **Rebase note (4e3f9db):** no changes — only the hunk line number shifted (332 → 331). |
| `04-nix-ios-fix.patch` | `vendor/nix-0.31.3-ios/*` (new, 127 files), `Cargo.toml`, `vendor/PATCHES.md`, `vendor/UPSTREAM.sha256` | Vendors nix 0.31.3 and gates its macOS-only utun/kern-control items to macOS. nix gates `KextControl` / `UtunIfname` on `apple_targets` (any of iOS/macOS/watchOS/tvOS/visionOS), but libc defines `SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` only on macOS, so nix fails for `aarch64-apple-ios` with E0425 (run #2 of `ios-core-check`, log lines 819-843). The chain: `concord-proxy` (WireGuard stack) → `gotatun` 0.10.2 → its unix `nix` dependency with `net`/`socket` features. `GetCString` (only used by `UtunIfname`) is gated the same way, or nix's `#![deny(unused)]` fails the build. Follows upstream's own vendoring discipline: `[patch.crates-io]` entry, `vendor/PATCHES.md` section + table row, `UPSTREAM.sha256` manifest (validated by `cargo test -p xtask vendor_patches`). No workflow change needed: the patch carries the whole vendored copy, so the runner just applies patches and builds. **Rebase note (5f1d090):** upstream added `vendor/h3` (new vendored crate), so the workspace `exclude` list, the `[patch.crates-io]` section, `vendor/PATCHES.md` table and `vendor/UPSTREAM.sha256` all shifted; the patch hunks were re-based onto the new line numbers. The vendored nix copy itself is unchanged (124/126 `UPSTREAM.sha256` hashes verify against the vendored files; the 2 mismatches are exactly the two intentionally modified files `src/sys/socket/mod.rs` and `src/sys/socket/sockopt.rs`, whose hashes record the pristine archive). **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** no changes — patch content identical to the 01d7a13 version. **Rebase note (4e3f9db):** no content changes — the vendored nix copy is unchanged; only hunk line numbers shifted (upstream added `crates/quic` and edited `vendor/PATCHES.md` in a region away from this patch's hunks). **Rebase note (165154c):** no content changes — only the index hash and one hunk line number shifted (upstream added lines above the `Cargo.toml` hunk). **Rebase note (0c9788f):** no content changes — only one hunk line number shifted (`Cargo.toml` 304 → 302, because upstream dropped the `aes-cfb` / `cfb-mode` workspace deps in a region away from this patch's hunks); the vendored nix copy is unchanged. |
| `05-rquickjs-ios-fix.patch` | `crates/mitm/Cargo.toml` | Enables the `bindgen` feature of `rquickjs` for `target_os = "ios"`, mirroring the Android block in the same file. `rquickjs-sys` 0.14.0 ships pre-generated bindings for darwin/linux/windows/wasm only — there is no `bindings/aarch64-apple-ios.rs`, so the build fails in `src/lib.rs:19` (`include!(concat!("bindings/", bindings_env!("TARGET"), ".rs"))`) with "couldn't find file .../aarch64-apple-ios.rs" (run #4 of `ios-core-check`, log lines 920-930). With `bindgen` on, `rquickjs-sys/build.rs` generates the bindings at build time from `quickjs.bind.h`. The chain: `concord-ios` → `concord-engine` (default `mitm`) → `concord-mitm` (default `script`) → `rquickjs` 0.14, used by the MITM script engine (`crates/mitm/src/quickjs/`, `mitm.runScript`). No vendoring: bindgen finds Xcode's libclang itself — `clang-sys` 1.9.1 (the locked version) searches `xcode-select --print-path`/Toolchains/`XcodeDefault.xctoolchain/usr/lib` and the hardcoded `/Applications/Xcode.app/...` path, and the workflow already selects that Xcode — so no `LIBCLANG_PATH` is needed. **Workflow change still needed (one line, in the "Build Concord staticlib" step of both `ios-core-check.yml` and `ios.yml`):** `export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path) --target=arm64-apple-ios"` so bindgen parses against the iOS SDK headers instead of the macOS SDK (same mechanism upstream CI uses for Android: `BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android` in `ci.yaml`). Verified locally: `cargo tree --target aarch64-apple-ios -p concord-mitm -e features -i rquickjs-sys` shows `bindgen` enabled, and with a local libclang the build script ran bindgen and wrote a 2,334-line `bindings.rs` for `arm64-apple-ios` that is identical to the bundled `aarch64-apple-darwin.rs` except for one typedef alias (`size_t` vs `__darwin_size_t` — a header-stub artifact, not a real difference); the build then stops only at `cc-rs` needing `xcrun` for the iOS SDK, which exists only on the runner. **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** no changes — patch content identical to the 01d7a13 version. **Rebase note (4e3f9db):** no changes — only the hunk line number shifted (58 → 60). |
| `06-tun-devicebuilder-ios-fix.patch` | `crates/tun/src/device/mod.rs` | Gates `TunDevice::create` / `build` off iOS and adds an iOS `create` stub returning `Unsupported`, mirroring the Android stub. Root cause: tun-rs 2.8.16 compiles its `builder` module only for windows/linux/macos/freebsd/openbsd/netbsd/illumos (`vendor/tun-rs/src/lib.rs`), so `tun_rs::DeviceBuilder::new()` in `build` fails for `aarch64-apple-ios` with E0433 (run #8 of `ios-core-check`, 2026-11-16 15:01). iOS never creates a device anyway: the NetworkExtension owns the interface and the core gets packets through the packet channel (patch 02) or an adopted descriptor (`AsyncDevice::from_fd`, which tun-rs DOES export on iOS via its generic unix `DeviceImpl`). No vendoring: this touches Concord's own code, not tun-rs. Verified locally: `cargo check -p concord-tun --target aarch64-apple-ios` passes, `cargo check -p concord-tun --target x86_64-apple-darwin` passes (no macOS regression), and patches 01–06 applied to a fresh clone at 5f1d090 produce a tree byte-identical to the rebase tree (see below). **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** upstream added a `TunDevice::OFFLOADS` const (3 lines) at the top of `impl TunDevice` in `crates/tun/src/device/mod.rs`, so only hunk line numbers/context shifted; the added/removed lines are identical to the 01d7a13 version. **Rebase note (4e3f9db):** no changes — only the hunk line number shifted (319 → 318). |
| `07-sock-cloexec-ios-fix.patch` | `bins/ios/src/bridge.rs` | Drops `SOCK_CLOEXEC` from the `socketpair` call in `concord_ios_bridge_open` on Apple targets (`#[cfg(target_vendor = "apple")]` → plain `SOCK_DGRAM`). Root cause: `libc::SOCK_CLOEXEC` exists on Linux but is not defined in libc for Apple targets, so the `concord-ios` lib fails for `aarch64-apple-ios` with E0425 (`cannot find value 'SOCK_CLOEXEC' in crate 'libc'`, `bins/ios/src/bridge.rs:101`, run #9 of `ios-core-check` attempt 2, 2026-11-17 09:33). This is a bug in our own patch-01 bridge code, not upstream code. The fds stay in-process (one end is adopted by the core, the other is held by the extension), so nothing can leak them into a spawned process anyway. Verified locally: `rustfmt --check` passes; `cargo check -p concord-ios --target aarch64-apple-ios` still stops at `cc-rs` needing `xcrun`/iOS SDK (absent on Linux, present on the runner), so the runner build is the verification for this one. Patches 01–07 applied to a fresh clone at 5f1d090 produce a tree byte-identical to the rebase tree (see below). **Rebase note (01d7a13):** no changes — patch content identical to the 5f1d090 version. **Rebase note (73d6530):** no changes — patch content identical to the 01d7a13 version. **Rebase note (4e3f9db):** no changes — patch content identical to the 73d6530 version. |
| `08-quic-ipv4-fallback.patch` | `crates/dns/src/{dialer,doq,doh3}.rs` | QUIC DNS upstreams (`quic://` DoQ, `h3://` DoH3) try every resolved address: `quic_socket` took only the first IP while `tcp()` iterates all, so a nameserver hostname resolving to IPv6 first never fell back to IPv4 on a network with no IPv6 route. A loop inside `quic_socket` alone would NOT fix it — binding a UDP socket never tests the route (`Sockets::bind_udp` only creates the socket in the peer's family and binds the wildcard), so the bind succeeds for every address and the first one would still be picked. The retry therefore spans the handshake, where the unreachable address actually fails: `quic_socket` becomes the per-address `quic_socket_for`, and `DoqClient::dial` / `Doh3Client::dial` try each resolved address with a full socket + handshake, keeping the last error, exactly like `Connector::tcp`. Verified: applies cleanly to the pristine pinned tree and on top of 01–07 (fresh clone at `4db36a4`, sequential `git apply --check` + apply for 01–08, `git diff --check` clean). **Scope note (v0.2.58):** `quic_socket` serves only the DNS upstreams — proxy QUIC nodes (hysteria2/tuic/shadowquic/xhttp) already fall back over all addresses via `dial_each` (`QuicLink::connect_any`, `crates/net/src/dial.rs`, happy-eyeballs with a 300 ms family head start, and EHOSTUNREACH is not in `no_retry` so it does not abort the dial); only hysteria v1 (`QuicLink::connect`) and MASQUE (`connect_endpoint`) still dial the first address only — deliberate mihomo alignment, not changed here. If the user's failing nodes are hysteria v1, that is a separate follow-up. **Item 7 (anchor-count log) DROPPED:** the only honest call site is `TrustCache::store` (`crates/engine/src/apply.rs:393`), but `TrustStore::len()` forces the `LazyLock` anchors, which synchronously reads the OS trust store on the config-apply path — upstream deliberately made that lazy (`with_system_roots`: "Never waits for the OS store", ~90 ms on macOS) — so a startup log line would change startup behaviour on every platform for a diagnostic aid; dropped, not shipped. **Rebase note (0c9788f): STILL NEEDED, carried forward unchanged** — upstream did NOT fix the `quic_socket` first-IP-only issue: at `0c9788f` it still takes only `first_ip(&ips)` (`crates/dns/src/dialer.rs:262`), and the DNS commits since the old pin (`92ac3c2` lists a client-handed query as the app's; `a20883f` documents the tunnel's single dial and its per-address attempts) do not touch `quic_socket`'s address selection. The patch applies cleanly at `0c9788f`, byte-identical to its `4db36a4` version. |
| ~~09-driver-coop-budget.patch~~ (REMOVED in the 33904fff rebase) | `crates/tun/src/{stack/driver.rs, device/apple.rs}`, `xtask/{tunables.txt, src/tunables/mod.rs}` | Backported upstream `2e2cc02` ("refactor(tun): end a busy driver pass on the cooperative budget instead of a round count", 2026-11-24) onto the pinned `fdea08a` (v0.2.101, phone-heating fix). REMOVED 2026-11-25: `2e2cc02` is now in the core at `33904fff` (driver ends a pass on `has_budget_remaining()`, Apple I/O draws budget in `poll_recv_batch`, `MAX_ROUNDS` gone, tunables ratchet 76) — leaving the patch would fail to apply. Verified in the rebase tree: `MAX_ROUNDS` count 0, `has_budget_remaining()` in `driver.rs`, `poll_proceed` + `made_progress()` in `apple.rs`, 76 tunables entries against the 76 ceiling. |
| `09-ios-resident-memory.patch` | `crates/platform/src/mem.rs` | iOS `resident_memory()` returned 0 always: the `proc_pidinfo` branch was cfg-gated to `target_os = "macos"` only, and iOS (`target_os = "ios"`) matched only the fallback stub returning 0 — so `engine.memory_stats().rss`, the `core.stats` RPC, and the controller's `/memory` stream all reported 0 on iOS, and the app's core-memory display (Dashboard card + memory sheet) could never show a number with the VPN on or off. v3 (current): keeps the macOS branch macOS-only and adds a separate `#[cfg(target_os = "ios")]` branch using Mach `task_info` (`mach_task_basic_info.resident_size`, via `libc::mach_task_self()`), because v2 FAILED CI: `libc::proc_pidinfo` sits inside a `cfg_if target_os = "macos"` block in libc 0.2.191 (pinned in `Cargo.lock`; `src/unix/bsd/apple/mod.rs` ~5458, "Prohibited on iOS/tvOS/watchOS/visionOS"), so the iOS build failed with E0425. Every Mach item used was verified ungated for iOS in the pinned libc 0.2.191 source: `mach_task_basic_info` struct with `resident_size` (mod.rs:1774), `MACH_TASK_BASIC_INFO` = 20 (4245), `MACH_TASK_BASIC_INFO_COUNT` (4547), `task_info()` extern (5333), `task_info_t`/`task_flavor_t` (38/40), `KERN_SUCCESS` (3711), `mach_task_self()` (5452) — the `mod apple` itself is included for all `target_vendor = "apple"` targets (bsd/mod.rs:923). `mach_task_self()` is deprecated in libc (use the `mach2` crate instead) — the branch carries `#[allow(deprecated)]`; concord-platform sets no deny-warnings, so it is warning-only. Also adds `target_os = "ios"` to the fallback stub's exclusion list — without it the ios branch and the stub would BOTH compile on iOS (E0428 duplicate definitions). Verified: applies cleanly to a fresh clone at `33904fff` on top of 01–08 (sequential `git apply --check` + apply), `git diff --check` clean, and exactly one `resident_memory` definition compiles on every target (iOS: Mach task_info; macOS: proc_pidinfo; linux/android: /proc; windows: K32GetProcessMemoryInfo; anything else: 0 stub). Added in v0.2.134 (v2 failed CI, replaced by v3 same version). |

## How to apply (manual)

```bash
git clone https://github.com/chen08209/concord upstream-checkout
cd upstream-checkout
git checkout 0c9788fc2476b69dcc00c7a578978857d755cfad
git apply /path/to/concord-ios/patches/01-bins-ios.patch
git apply /path/to/concord-ios/patches/02-packet-channel.patch
git apply /path/to/concord-ios/patches/03-tun-wrap-ios-fix.patch
git apply /path/to/concord-ios/patches/04-nix-ios-fix.patch
git apply /path/to/concord-ios/patches/05-rquickjs-ios-fix.patch
git apply /path/to/concord-ios/patches/06-tun-devicebuilder-ios-fix.patch
git apply /path/to/concord-ios/patches/07-sock-cloexec-ios-fix.patch
git apply /path/to/concord-ios/patches/08-quic-ipv4-fallback.patch
git apply /path/to/concord-ios/patches/09-ios-resident-memory.patch
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
above). Run #9 attempt 2 (2026-11-17 09:33, after the repo went public so
the job could start again) then failed on `concord-ios` itself:
`libc::SOCK_CLOEXEC` does not exist on Apple targets
(`bins/ios/src/bridge.rs:101`, E0425) — a bug in our own patch-01 bridge
code, fixed by patch `07` (plain `SOCK_DGRAM` on Apple targets; the fds
stay in-process so CLOEXEC is moot there — see the `07` row above). Still unverified: the rest of the staticlib build after
concord-ios, the Xcode archive with the staticlib linked, the Swift side
compiling, and the packet-channel bridge forwarding real traffic on a
device.

## Rebase to 5f1d090 (2026-11-17)

Patches `01`, `02` and `04` were reworked for the new pin; `03`, `05`, `06`,
`07` applied cleanly. `schema/api.json` at the new HEAD still has **68
methods with the same names** — no added/removed/renamed methods. Param-level
additions only: `ConfigPatchParams` gains `externalControllerCors`
(nullable `ControllerCorsPatch` with `allowOrigins` / `allowPrivateNetwork`),
`ConnectionInfo` gains `rematchName` (`string | null`), and the
`DelayRunParams.concurrency` description was reworded ("mihomo" → "the Clash
API"). The Swift side does not need changes for these (both new fields are
optional), but `config.patch` could now send `externalControllerCors` and
connections can carry `rematchName`.

Local verification at the new pin (Linux, Rust 1.100.0; the iOS `std` target
had to be added for the 1.100.0 toolchain with
`rustup target add aarch64-apple-ios --toolchain 1.100.0`):

- `cargo check -p concord-proto --target aarch64-apple-ios` — passes.
- `cargo check -p concord-tun --target aarch64-apple-ios` — passes (covers
  the patch-02 channel code, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine`
  (host) — passes; this type-checks the patch-02 `channels.rs` /
  `control.rs` / `hub.rs` / `abi.rs` rework and the patch-01 `core.rs`
  `Hub::new` fix. (Host check needed `libclang-dev` installed for the
  `boring-sys` bindgen step, and the work area moved from `/tmp` to
  `/home/hatch/concord-rebase` because `/tmp` is a 512 MB tmpfs that the
  `target/` directory filled.)
- `cargo check -p concord-ios` (host) — passes after the `Hub::new`
  two-argument fix (it initially failed with E0061, 3 arguments supplied).
- `cargo check -p concord-api / -p concord-ffi / -p concord-ios
  --target aarch64-apple-ios` — all three stop at the known SDK wall:
  `aws-lc-sys v0.47.0`'s build script fails with `cc-rs: failed to find
  tool "xcrun"`. No Rust code is reached past that point on Linux; the
  macOS runner (which has `xcrun` and the iOS SDK) is the verification for
  the full staticlib build, as before.

Patches 01–07 applied to a fresh clone at `5f1d090` produce a tree
byte-identical to the rebase tree (`/home/hatch/concord-rebase`).

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 01d7a13 (2026-11-18)

All 7 patches applied cleanly with **zero conflicts and zero content
changes** — every patch's diff is byte-identical to its 5f1d090 version
(only the hunk line numbers in patch `02` shifted, because upstream added
lines above the patched hunks). The watch report's expected patch-02
conflict did not materialize: `b3744f7` only added a Linux/Android-gated
`pub mod provision;` to `crates/tun/src/lib.rs` and moved `rtnetlink`
under the combined linux/android target section of
`crates/tun/Cargo.toml` (no iOS effect), and `702bac2` / `5e353de`
touched `crates/api/src/control.rs` and `schema/api.json` in regions away
from the patch hunks. New patch commits `0f282a9`–`494057f` on top of
`01d7a13` (`git rebase origin/main`, `git fetch` worked this time — the
egress-proxy stall seen by the watch job on 2026-11-17 ~23:51 CST did not
recur).

`schema/api.json` at the new HEAD still has **68 methods with the same
names** — no added/removed/renamed methods. Param-level additions only:
`Inbound` / `InboundPatch` gain `bindAddress` (`string | null`),
`lanAllowedIps` / `lanDisallowedIps` (arrays of CIDR strings, nullable in
the config form) from `702bac2` — all optional, the Swift side does not
need changes for them (it does not send them yet). The one change the
Swift side SHOULD track: `5e353de` retyped `mitm.validate`'s result.
`MitmValidateResult` was `{issues: <untyped JSON>}` and is now
`{issues: {<list>: MitmIssue[]}, views: {<list>: MitmLineEntry[]}}`,
where `MitmIssue = {index: u32, kind: MitmIssueKind, message: string}`
with `kind` in `syntax | missing | unknown | unsupported | invalid |
pattern | jq | resource | script`, and `MitmLineEntry = {index: u32,
view: MitmLineView}` where `MitmLineView` is an internally-tagged
(`type`) union of the parsed rule structs (`urlRewrite`,
`headerRewrite`, `bodyRewrite`, `mapLocal`, `script`, `hosts`,
`sources`). The old engine returned the issues map directly with
`Issue {index, message}`; the new engine returns
`Validation {issues, views}` and the handler converts it with
`serde_json::from_value`. **The current Swift code does NOT break
against the new core**: `ConcordMitmIssue {index, message}` and
`ConcordMitmValidateResult {issues}` decode fine because Swift's
synthesized `Codable` ignores the unknown `kind` and `views` keys — the
new data is just dropped. To surface it, add an optional `kind` to
`ConcordMitmIssue` and an optional-with-default `views` to
`ConcordMitmValidateResult` (plus `ConcordMitmLineEntry` /
`ConcordMitmLineView` types, decoding `view` by its `type` tag, or as
`JSONValue` for a minimal change); `ConcordSampleData.swift` builds
`ConcordMitmValidateResult(issues: [:])`, so give `views` a default of
`[:]` to avoid touching that call site. Call sites:
`ConcordClient.swift:626-634` (types), `SettingsStore.swift:606-621`
(`validateMitmConfig`, flattens issues to `"key：message"` strings),
`MitmModulesView.swift:232,305,352-357` (`validateIssues`, same flattening).

Local verification at the new pin (Linux, Rust 1.100.0):

- `cargo check -p concord-proto --target aarch64-apple-ios` — passes.
- `cargo check -p concord-tun --target aarch64-apple-ios` — passes (covers
  the patch-02 channel code, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine`
  (host) — passes; this type-checks the patch-02 `channels.rs` /
  `control.rs` / `hub.rs` / `abi.rs`.
- `cargo check -p concord-ios` (host) — passes.
- `cargo check -p concord-api / -p concord-ffi / -p concord-ios
  --target aarch64-apple-ios` — all three were run and all three stop at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"` (exit 101).
  No Rust code is reached past that point on Linux; the macOS runner
  (which has `xcrun` and the iOS SDK) is the verification for the full
  staticlib build, as before.

Environment note for the host checks: this VM no longer has `libclang-dev`
installed (the 5f1d090 rebase relied on it), so the host checks initially
failed in `boring-sys`'s bindgen step for all four crates — first
"Unable to find libclang", then (with a libclang path set) "'stddef.h'
file not found". They pass with the Python `clang` package's bundled
libclang plus the gcc headers:
`LIBCLANG_PATH=$HOME/.local/lib/python3.12/site-packages/clang/native`
and
`BINDGEN_EXTRA_CLANG_ARGS="-I/usr/lib/gcc/x86_64-linux-gnu/13/include -I/usr/include/x86_64-linux-gnu -I/usr/include"`.
(Only warnings: `proc-macro-error2 v2.0.1` future-incompat notice and 9
`h3` lib warnings — both pre-existing upstream, unrelated to the patches.)

Patches 01–07 applied to a fresh clone at `01d7a13` produce a tree
byte-identical to the rebase tree (`/home/hatch/concord-rebase`) once the
regenerated `Cargo.lock` is reverted (see the note below).

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 73d6530 (2026-11-19)

Patch `02` was reworked for the new pin; patch `06` only shifted hunk
positions; `01`, `03`, `04`, `05`, `07` are byte-identical to their
01d7a13 versions. 24 commits since `01d7a13`, dominated by a refactor
wave: the control surface split by domain (`9fd36ab`), `engine.rs`
split into child modules (`232e3a8`), the platform branches moved into
`platform`/`tun` (`34150d5`), and shared DNS-dial / MITM / resource
types moved into `concord-config` (`d7e7837`, `ef9a065`) — plus
shutdown-ownership fixes for the engine's background tasks (`73d6530`,
`515261c`, `cc4ceee`), DNS dial fixes (`43d7ff3`, `9601799`,
`1d94227`, `96eeb2d`) and proxy-layer fixes (`d6172d9`, `4f51ff5`,
`32f8e75`, `022c838`).

`schema/api.json` at the new HEAD still has **68 methods with the same
names** — and the file is byte-identical to the one at `01d7a13`, so
there are no added/removed/renamed methods and no param changes at
all. **The Swift side needs no changes for this rebase.** The only
schema change is in `schema/config-schema.json`: a new `"proxy-groups"`
tier entry (`t0` lists the main proxy-group keys, `t2` lists
`routing-mark` / `interface-name` / `dialer-proxy`, `t1` and `inert`
are empty) — documentation of which proxy-group keys take effect under
`concord -t`, not an API change; the Swift client does not read it.
(The `mitm.validate` result retyping from the 01d7a13 rebase still
stands and still needs no Swift change — see above.)

Local verification at the new pin (Linux, Rust 1.100.0; same libclang
workaround as the 01d7a13 rebase — Python `clang` package's bundled
libclang + gcc headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (covers the patch-02 channel code and
  `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — all pass; this type-checks the patch-02
  rework (`channels.rs` / `control.rs` / `control/tun.rs` /
  `engine/tun.rs` / `hub.rs` / `abi.rs`). (Only warnings:
  `proc-macro-error2 v2.0.1` future-incompat notice and 9 `h3` lib
  warnings — both pre-existing upstream, unrelated to the patches.)
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"`. No Rust
  code is reached past that point on Linux; the macOS runner (which has
  `xcrun` and the iOS SDK) is the verification for the full staticlib
  build, as before. (The `concord-ffi` / `concord-ios` iOS-target checks
  were not re-run this time — they stop at the same wall; the host
  checks above cover the reworked code.)

Patches 01–07 applied to a fresh clone at `73d6530` produce a tree
byte-identical to the rebase tree (`/home/hatch/concord-rebase`) once
the regenerated `Cargo.lock` is reverted. Note: the fresh clone must be
pinned to `73d6530` explicitly (`git fetch --depth 1 origin
73d6530...` + checkout) — a plain `--branch main` clone already pulls
a newer HEAD (upstream has since added a `crates/quic` crate), and the
patches do not apply to that newer tree.

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 4e3f9db (2026-11-19)

Patch `02` was reworked for the new pin; `01`, `03`, `04`, `05`, `06`,
`07` are content-identical to their 73d6530 versions (only hunk line
numbers shifted). 18 commits since `73d6530`, dominated by a QUIC
refactor into a new `crates/quic` crate (`ea02b34`, `50cb078`), the
`TunRunner::start` / `start_runner` signature changes (`0192321`,
`6c459a2`), the Android privileged-TUN removal (`9fd449d`), a UDP
relay codec fold into `dgram` (`79acbc2`), host settings via
`config.apply` (`493fe6f`), MITM changes (`6daf337`, `099c97c`,
`cc9db4d`) and a public-suffix-table refactor (`0623847`).

`schema/api.json` at the new HEAD still has **68 methods with the same
names** — no added/removed/renamed methods. Param-level additions only,
all optional: `ConfigApplyParams` gains `host` (nullable new
`HostSettings` with `externalController` / `externalControllerCors` /
`hostCredential` / `secret` — the settings only a host gives a core it
drives, applied with the profile); `ConfigPatchParams` gains
`hostCredential` (`string | null`); `Options` gains `mitmTrustedCa`
(`string | null` — the fingerprint of the CA the host has just found
the device trusting; TLS is decrypted under a pinned `ca-fingerprint`
only while this agrees with it). **The Swift side needs no changes for
this rebase**: every new field is optional, and the Swift client does
not send any of them yet. (To use them later: `config.apply` could
send `host` so the core holds host settings from its first connection,
and `config.patch` could send `hostCredential`; the MITM CA-trust
handshake would need the app to report the device's trusted CA
fingerprint as `mitmTrustedCa`.)

Local verification at the new pin (Linux, Rust 1.100.0; same libclang
workaround as the 01d7a13 rebase — Python `clang` package's bundled
libclang + gcc headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (covers the patch-02 channel code and
  `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — all pass; this type-checks the patch-02
  rework (`channels.rs` / `control.rs` / `control/tun.rs` /
  `engine/tun.rs` / `hub.rs` / `abi.rs`) and the new `crates/quic`
  crate. (Only warning: `proc-macro-error2 v2.0.1` future-incompat
  notice — pre-existing upstream, unrelated to the patches.)
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"`. No Rust
  code is reached past that point on Linux; the macOS runner (which has
  `xcrun` and the iOS SDK) is the verification for the full staticlib
  build, as before. (The `concord-ffi` / `concord-ios` iOS-target checks
  were not re-run this time — they stop at the same wall; the host
  checks above cover the reworked code.)

Patches 01–07 applied to a fresh clone at `4e3f9db` produce a tree
byte-identical to the rebase tree (`/home/hatch/concord-rebase`) once
the regenerated `Cargo.lock` is reverted.

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 165154c (2026-11-19)

All 7 patches applied cleanly with **zero conflicts and zero content
changes** — the diff bodies of `03`, `05`, `06`, `07` are byte-identical
to their `145c9e7` versions, and `01`, `02`, `04` differ only in the
`index` hashes and hunk line numbers (upstream added lines above the
patched hunks). The watch report's expected patch-02 failure at
`crates/tun/src/runner.rs:135` did NOT materialize: the patch applies
cleanly at `165154c`, as it does at `145c9e7`. New patch commits on top
of `165154c` in `/home/hatch/concord-rebase-165154c`, regenerated with
`git format-patch 165154c`; the regenerated patches applied to a fresh
clone at `165154c` produce a tree byte-identical to the rebase tree
(`diff -r --exclude=.git`, no `Cargo.lock` regeneration involved —
no cargo invocation ran in either tree before the comparison).

9 commits since `145c9e7`, all 2026-11-19: the core reads MITM modules
itself — Surge (`038f1ab`), Loon (`d839bbb`), Quantumult X snippets
and Stash overrides (`f1de7da`) — plus `mitm.readModule`; URL-REGEX /
USER-AGENT rules and per-request routing inside decrypted sessions
(`f3e49e2`); a MITM jq fix (`1ff8283`: module lines using jq 1.7
builtins or a `\cX` escape now load); two TLS fixes (`d9b1847`: ECH
retry configs read only after BoringSSL rejected ECH; `7e9d333`:
BoringSSL ex_data slots initialized once per process); NDEBUG for the
C dependencies of release builds (`3096509`); docs only (`165154c`).

`schema/api.json` at the new HEAD has **69 methods** — the only
addition is `mitm.readModule` (unary, concurrent, capability `mitm`;
params `MitmModuleReadParams {text, arguments, attachments,
language}`; result `MitmModuleView {format, meta, off, arguments,
resources, declaredScripts, asksConsent, issues, views, rules,
ruleSets, network, ignored}`). No method removed or changed; 19 new
`MitmModule*` types, no type removed or changed. Upstream also added
`boring-sys = "5.4"` to the workspace deps, a
`[profile.dev.package.boring-sys] opt-level = 0` section, and
`fancy-regex` to `crates/rules` (for URL-REGEX) — all in regions away
from the patch hunks, so no patch needed changes.

**The Swift side changes for this rebase:**
- `mitm.readModule` is wired as the 69th method (`ConcordClient.
  mitmReadModule` + `ConcordMitmModuleView` et al.; sample data returns
  an empty view). When the VPN is running, `MitmModuleStore.
  coreParsedContent` calls it on the imported module text with the
  user-set arguments and builds the module content from the view
  (`MitmModuleParser.parseWithCore`): the core's meta, arguments,
  Clash rules, declared scripts and resources are authoritative, and
  the core's ignored lines / off-reason / issue count are shown in the
  module detail view. The MITM line lists still come from the Swift
  parser — the core's views are the parsed forms of those lines and
  have no line form to send back. When the VPN is off (or the call
  fails) the Swift parser reads the module alone, as before; the
  merged files (`refreshModuleFiles` → `mergedListsLive`) and the
  validate flow (`mergedConfigLive`) use the core where live. The
  Swift parser is NOT removed.
- URL-REGEX / USER-AGENT are recognized everywhere the app handles
  rule types: `AddedRulesStore.knownTypes` (validation accepts them;
  URL-REGEX must compile as a regex; payloads may be quoted since a
  regex or glob may contain commas — the core's `QUOTED_PAYLOAD`),
  `CustomSubscriptionStore.types` (rule editor picker; a content
  with a comma is quoted when emitted), and `MitmModuleParser`
  (`ruleTypes` + `qxFilterTypes` gains QX `user-agent`). The module
  parser no longer maps URL-REGEX + REJECT to a url-rewrite line
  (FlClash-era, from before the core had URL-REGEX rules) — the core
  keeps it as a profile rule, so the Swift parser does the same and
  the two parsers agree. Both types are undecided before the request
  is read; inside a decrypted session each request is routed on URL +
  UA after rewrites (noted in code at each site).
- Top bar (v0.2.28 user report, folded into this version): the ⋯
  menu card is now content-sized (`.frame(minWidth: 160,
  maxWidth: 280)`, 12pt row padding, `.subheadline` labels) instead
  of forced 280pt — FlClash's `_menuMinWidth = 160`; and the pill
  and the ⋯ are two separate toolbar items so the popover arrow
  points at the ⋯ circle instead of the whole bar.

Local verification at the new pin (Linux, Rust 1.100.0; same libclang
workaround as the 01d7a13 rebase — Python `clang` package's bundled
libclang + gcc headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (covers the patch-02 channel code and
  `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — all pass (11m56s; only warning:
  `proc-macro-error2 v2.0.1` future-incompat notice — pre-existing
  upstream, unrelated to the patches).
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"` in
  `aws-lc-sys`'s build script. No Rust code is reached past that point
  on Linux; the macOS runner (which has `xcrun` and the iOS SDK) is
  the verification for the full staticlib build, as before. (The
  `concord-ffi` / `concord-ios` iOS-target checks were not re-run this
  time — they stop at the same wall; the host checks above cover the
  reworked code.)

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to b0806a8 (2026-11-20)

All 7 patches applied cleanly with **zero conflicts and zero content
changes** — `01`, `03`, `04`, `05`, `06`, `07` are byte-identical to
their `165154c` versions, and `02` differs only in the `index` blob
hashes and one hunk line number (`schema/api.json` 4306 → 4370, because
the 2 new methods below added 64 lines above it); the added/removed
lines are identical. 15 commits since `165154c`, dominated by the
netstack work in the pin subject (BBR on the TUN and WireGuard/MASQUE
IP stacks) plus the MITM module work the Swift side must catch up on
(see below). New patch commits on top of `b0806a8` in
`/home/hatch/concord-rebase-b0806a8`, regenerated with
`git format-patch b0806a8`; the regenerated patches applied to a fresh
clone at `b0806a8` produce a tree byte-identical to the rebase tree
(0 diff lines, after reverting the cargo-regenerated `Cargo.lock`).

`schema/api.json` at the new HEAD has **71 methods** — the only
additions are `mitm.moduleStatus` (params `{}`, result
`MitmModuleStatusList`: per-module `enabled` / `inForce` / `problem` /
`off` / per-resource fetch state / `refusedRules` / `hostNetwork`) and
`mitm.fetchModule` (params `{name?: string | null}` — absent/null
re-fetches every module's remote files; result `{}`). No method
removed or changed. Also new: `CoreEvent` gains a `scriptNotification`
variant (`$notification.post` from MITM scripts); `MitmModuleRule`
gains optional `requiresResolve`; `MitmModuleRuleSet` gains optional
`provider` (`behavior`/`format`); `MitmScriptKind` gains `rule` and
`dns`; `ResourceKind` gains `mitmModule`.

**The Swift side changes for this rebase** (additive — nothing in the
new core breaks the existing Swift client at decode time; every new
field is optional or ignored by Swift's synthesized `Codable`):
- Wire the 2 new methods as the 70th/71st (`ConcordClient.
  mitmModuleStatus` + `mitmFetchModule`, following the `mitm.readModule`
  pattern), with `ConcordMitmModuleStatusList` et al. and sample-data
  cases; the natural UI home is a per-module status row in
  `MitmModulesView` (enabled / inForce / problem / per-resource state /
  refused rules) plus a re-fetch action.
- Module parser catch-up (offline fallback only — the core's
  `mitm.readModule` is the primary path when the tunnel runs): `SCRIPT`
  rules with a `requires-resolve` option; `dns` / `rule` scripts are
  now runnable by the core (the parser's "not supported" comment is
  now false); `[MITM] hostname-disabled`; Stash rule-provider
  `behavior`/`format` and payload-only scripts; ignore URL rewrites
  naming `{{{GATEWAY_ADDRESS}}}`.

Local verification at the new pin (Linux, Rust 1.100.0; same libclang
workaround as the 01d7a13 rebase — Python `clang` package's bundled
libclang + gcc headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (covers the patch-02 channel code and
  `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — all pass (12m59s; only warning:
  `proc-macro-error2 v2.0.1` future-incompat notice — pre-existing
  upstream, unrelated to the patches).
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"`. No Rust
  code is reached past that point on Linux; the macOS runner (which has
  `xcrun` and the iOS SDK) is the verification for the full staticlib
  build, as before. (The `concord-ffi` / `concord-ios` iOS-target checks
  were not re-run this time — they stop at the same wall; the host
  checks above cover the reworked code.)

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 4db36a4 (2026-11-21)

All 7 patches applied cleanly with **zero conflicts and zero content
changes** — `01`, `02`, `03`, `05`, `06`, `07` are byte-identical to
their `b0806a8` versions, and `04` differs only in one hunk line number
(`vendor/PATCHES.md` 96 → 97, because upstream added a quinn GRO-socket
row above it). 6 commits since `b0806a8`, all perf/docs/bench:
`4db36a4` GeoSite update hands memory back (by-value `GeoSiteEntry` in
`crates/rules/src/geo/dat.rs`); `140639c` one shared GRO socket for
QUIC (vendor/quinn `src/runtime/tokio.rs` + `vendor/PATCHES.md` row);
`06978e3` MITM serves large map-local files from disk and streams geo
updates (`crates/mitm/src/{body,exchange,forward,rules}.rs`,
`crates/engine/src/resources/{fetch,geo}.rs`, tokio gains the `fs`
feature and tokio-util the `io` feature in `crates/mitm/Cargo.toml` —
in a region away from patch 05's rquickjs hunk); `36424ef` Windows-only
bench `--keep-awake`; `73ebdda` + `fb5436f` bench docs only. New patch
commits on top of `4db36a4` in `/home/hatch/concord-rebase-4db36a4`,
regenerated with `git format-patch 4db36a4`; the regenerated patches
applied to a fresh clone at `4db36a4` produce a tree byte-identical to
the rebase tree (0 diff lines, verified before any `cargo` invocation;
the rebase tree's `Cargo.lock` was later rewritten by the local cargo
checks below and is NOT part of the patches — never commit it).

`schema/api.json` at the new HEAD is **byte-identical to the `b0806a8`
version: still 71 methods, none added, removed, or changed** (no `$defs`
changes either). **No Swift wiring is needed for this rebase.** The
only behaviour changes that could surface on-device: GeoSite updates
should use less memory, and large MITM map-local files are now served
from disk instead of memory.

Local verification at the new pin (Linux, same libclang workaround as
the 01d7a13 rebase — Python `clang` package's bundled libclang + gcc
headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (covers the patch-02 channel code and
  `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — passes.
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `cc-rs: failed to find tool "xcrun"`. No Rust
  code is reached past that point on Linux; the macOS runner (which has
  `xcrun` and the iOS SDK) is the verification for the full staticlib
  build, as before.

## Rebase to 0c9788f (2026-11-22)

All 8 patches applied cleanly with **zero conflicts and zero content
changes** — `01`, `03`, `05`, `06`, `07`, `08` are byte-identical to
their `4db36a4` versions, `02` differs only in hunk line numbers
(`live.rs` 299 → 410 and 311 → 422, `api.json` 4370 → 4624), and `04`
differs only in one hunk line number (`Cargo.toml` 304 → 302). The
watch report's expected patch-02 manual merge did NOT materialize:
the 721-line `api.json` growth and the 131-line `live.rs` growth are
all in regions away from the patch hunks. New patch commits on top of
`0c9788f` in `/home/hatch/workspace/scratch/v0.2.60/rebase`,
regenerated with `git format-patch 0c9788f`; the regenerated patches
applied to a fresh clone at `0c9788f` produce a tree byte-identical to
the rebase tree (0 diff lines, verified before any `cargo` invocation;
the rebase tree's `Cargo.lock` was later rewritten by the local cargo
checks below and is NOT part of the patches — never commit it).

Upstream REWROTE HISTORY since the last pin: the old pin object
`4db36a4` is no longer in the clone at all. The commit carrying the
same subject (`perf(engine): hand memory back after a GeoSite update`)
is now `02ef135`, and 34 genuinely new commits sit on top of it. The
new work is dominated by `connection.watch` enrichment — setup timing
(`0b88c44`), failed dials (`04ec6f2`), why and when each watched
connection ended (`4d8205f`), final totals on close (`90fa866`), the
deciding rule's position (`4a2b8fd`) and the DNS queries behind an
address (`1505211`) — plus `mitm.query` (`e9e9390`), script
notifications naming their connection and exchange (`c542475`), smart
groups that pick a member per site and redial the next one (`c4bc31d`),
a DNS fix listing a client-handed query as the app's (`92ac3c2`),
vmess legacy AES-128-CFB moved onto aws-lc (`e19a306`, which drops the
`aes-cfb` / `cfb-mode` workspace deps — no patch impact), AnyTLS
session-writer perf (`d459b99`, `5cad680`, `e6d11b9`), netstack/TLS
perf, and bench/docs/test-only commits.

`schema/api.json` at the new HEAD has **72 methods** — the only
addition is `mitm.query` (unary, concurrent, capability `mitm`;
params `MitmQueryParams {filter, before, limit, since, facets,
rateFrom}`; result `MitmQueryAnswer {capturing, since, version,
oldest, held, matched, exchanges, next, unmatched, facets, rate}`).
No method removed or changed. 14 new `$defs`, none removed:
`ConnectionEnd`, `ConnectionEndReason`, `ConnectionFailure`,
`ConnectionFailureKind`, `ConnectionTiming`, `MitmApp`,
`MitmExchangeSummary`, `MitmFacets`, `MitmFilter`, `MitmKind`,
`MitmQueryAnswer`, `MitmQueryParams`, `MitmRateBucket`, `MitmStatus`.
6 changed `$defs`, all additive or descriptive:
- `ConnectionInfo` gains `ruleIndex` (`u32 | null` — the deciding
  rule's position in the list `rule.list` gave), `failure`
  (`ConnectionFailure | null` — only on a connection whose dial
  failed; never in `connection.list`), `timing`
  (`ConnectionTiming | null` — `accepted` plus `dnsStart` /
  `dnsEnd` / `routed` / `dialStart` / `connected` / `tls` /
  `dialEnd` / `targetTls` / `decrypted`, in microseconds after
  `accepted`), and `dnsQueries` (`u64[]` — the `dns.watch` entry ids
  that gave out the destination's address).
- `ConnectionDelta` gains `ended` (`ConnectionEnd[]` — every id in
  `closed` has an entry with `reason` in `local | remote | finished |
  timeout | reset | core | error | failed`, `endedAt` and `message`);
  `counters` now always carries the final totals for closed ids,
  even when the watch asked for `counters` off.
- `ConnectionWatchParams`: `counters` description only (closes still
  carry their final totals).
- `CoreEvent` `scriptNotification` gains `at` (Unix ms when the
  script posted it), `connection` (the `connection.watch` id) and
  `exchange` (the `mitm.exchanges` id).
- `DnsEntry` gains `id` (`u64`, counting up from 1 — what a
  connection's `dnsQueries` names); `initiator` is now documented:
  `app` for a query a client sent the core (DNS `listen`,
  `dns-hijack`, a `dns` outbound).
- `ServiceItem` gains `ip` (the address the service saw the check
  come from — a node that sends the service out another way does not
  share it with its other traffic).

**The Swift side changes for this rebase** (additive — nothing in the
new core breaks the existing Swift client at decode time; every new
field is optional or ignored by Swift's synthesized `Codable`):
- Wire `mitm.query` as the 72nd method (`ConcordClient.mitmQuery` +
  `ConcordMitmQueryParams` / `ConcordMitmQueryAnswer` et al., with
  sample-data cases), following the `mitm.readModule` pattern. The
  natural UI home is a capture browser across connections: filter by
  status (`1xx`–`5xx` / `failed` / `pending`), method, kind (`json` /
  `html` / `script` / `css` / `image` / `font` / `media` / `text` /
  `other`), host, app and free text, with paging via `next` →
  `before`, live follow via `version` → `since`, and the facet counts
  + per-second rate for summary rows. `MitmExchangeSummary` carries
  `connection-id` and `app`, so rows link back to the Connections
  list.
- `ConnectionInfo`: add optional `ruleIndex`, `failure` (`kind` in
  `timeout | refused | unreachable | dns | handshake | other` +
  `message`), `timing` (the setup-step timestamps) and `dnsQueries`
  (ids into `dns.watch`); `ConnectionDelta`: add `ended` and treat a
  closed id's final `counters` entry as authoritative — the
  per-connection up/down differencing (v0.2.53) should use it rather
  than dropping the connection's last second. `DnsEntry`: add `id`;
  `initiator == "app"` marks a client-handed query. `ServiceItem`:
  add optional `ip` (the exit address the probe saw). `CoreEvent`
  `scriptNotification`: add optional `at` / `connection` /
  `exchange` to attribute a notification to its connection and its
  captured exchange.

Local verification at the new pin (Linux, Rust 1.100.0; same libclang
workaround as the 01d7a13 rebase — Python `clang` package's bundled
libclang + gcc headers):

- `cargo check -p concord-proto -p concord-tun --target
  aarch64-apple-ios` — passes (1m44s; covers the patch-02 channel code
  and `TunSource::Channel`, patch 03, patch 06 and the vendored nix).
- `cargo check -p concord-api -p concord-ffi -p concord-engine
  -p concord-ios` (host) — passes (13m10s; only warnings: the
  pre-existing `proc-macro-error2 v2.0.1` future-incompat notice and 2
  `concord-dns` unused-variable warnings, both upstream, unrelated to
  the patches).
- `cargo check -p concord-api --target aarch64-apple-ios` — stops at
  the known SDK wall: `aws-lc-sys v0.47.0`'s build script fails with
  `cc-rs: failed to find tool "xcrun"` (exit 101). No Rust code is
  reached past that point on Linux; the macOS runner (which has
  `xcrun` and the iOS SDK) is the verification for the full staticlib
  build, as before. (The `concord-ffi` / `concord-ios` iOS-target checks
  were not re-run this time — they stop at the same wall; the host
  checks above cover the reworked code.)

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## v0.2.11 signing experiment (FlClash-style placeholder entitlements)

`tools/adhoc-sign.sh` now embeds team `UNKNOWN000` (the FlClash
placeholder) instead of the real team `65ZBN43KNV`, and the unsigned
job in `.github/workflows/ios.yml` deletes `embedded.mobileprovision`
from each bundle and strips both binaries (`strip -S`) before the
ad-hoc sign — both copied from FlClash's `setup.dart`
`packageIOSNoSign`. Rationale: profile JUMJJ8's
`application-identifier` is exactly
`65ZBN43KNV.app.forest5669.sapodilla72` (no wildcard), so it does not
cover `.PacketTunnel`; baking the real team into the tunnel's
entitlements gives the re-signer a real-but-profile-mismatched
identifier to preserve. The placeholder forces the re-signer to
rewrite team + bundle identifiers consistently from the profile it
signs with. Unchanged: bundle IDs, App Group
`group.434fff4c253add77.1`, `packet-tunnel-provider`, the per-bundle
signing order (tunnel first, then app) and `--generate-entitlement-der`.
This is an EXPERIMENT, not a proven fix: v0.2.9 / v0.2.10 with the
tunnel do not install via SideKite, and this build has the same tunnel
structure.

## Dashboard size (v0.2.11 — no change)

The user reported the dashboard "还是太大，跟参考图不一样"
(2026-11-19). Verified against the reference screenshots (IMG_1082 /
IMG_1083) and the remote `DashboardView.swift`: the remote file is
already the v0.2.7-tightened version — play button 88pt (was 112pt),
title 30pt, edit button 44pt, card padding 16, gaps 12 — and the
first-viewport stack (title + status ~209pt + speed ~180pt + mode
~135pt + VPN 76pt ≈ 692pt) is 33pt SHORTER than the reference layout
(~725pt), which demonstrably fits a 390×844 screen with the VPN card
fully visible. The user has only ever installed the old no-tunnel
test build, whose 112pt button renders at 136pt under the 1.22x
compatibility scale (measured in their IMG_1095 screenshot) — that
is what looked too large, not the current code. No layout change was
made in v0.2.11; the fix is delivering an installable build so the
user finally sees the tightened UI. `LaunchScreen.storyboard` is still
referenced (`UILaunchStoryboardName` in `ConcordiOS/Info.plist`,
`PBXBuildFile` in `project.pbxproj`) — its absence was the cause of
the 1.22x scaling.

## Rebase to 9d1f485 (2026-11-23)

All 8 patches applied cleanly with **zero conflicts and zero content
changes** — `01`, `02`, `03`, `05`, `06`, `07`, `08` are byte-identical
to their `0c9788f` versions (only the `index` hashes and hunk line
numbers shifted), and `04` differs only in two hunk line numbers
(`vendor/PATCHES.md` 32 → 33 and 97 → 98, because upstream added an
h3 row above them). The watch report's expected clean rebase held:
no patch touches the files this batch changed. New patch commits on
top of `9d1f485` in `/home/hatch/workspace/scratch/v0.2.60/rebase`,
regenerated with `git format-patch 9d1f485`; the regenerated patches
applied to a fresh clone at `9d1f485` produce a tree byte-identical to
the rebase tree (0 diff lines, verified before any `cargo` invocation;
no `Cargo.lock` regeneration involved — never commit it).

15 commits since `0c9788f`, in two batches. `b678d79` (7 commits,
2026-11-22 20:43–22:10) is all MITM capture records: `152f632`
action kinds + local answer on each record, `21958e3` the response
reason phrase, `2de2c17` each header/body rewrite rule as its own
action, `aaa0f27` the capture wire types moved to their own module
(`crates/mitm/src/capture/wire.rs`), docs (`8b64e39`, `8c32b58`) and
a test (`b678d79`). `9d1f485` (8 commits, 2026-11-23 00:16) is the
`url` 2.5.9 security upgrade (`RUSTSEC-2026-0592`, `Cargo.lock`
only), test/docs/build-config fixes, and a TUN compile fix
(`3e9887f`: `tun-rs` `into_sync` only on Linux/Android — no iOS
effect).

`schema/api.json` at the new HEAD still has **72 methods** — none
added, removed, or changed. The only schema change is two fields on
`MitmExchangeSummary`: `action-kinds` (array of strings, each kind
once, in the order they first acted) and `answer` (`MitmAnswer` or
null: `reject` | `redirect` | `map-local` | `script` — what answered
in place of the server; absent when the request went to the server).
The full exchange (`mitm.exchange`, Rust `Exchange`) also gains
`reason` (the response reason phrase, e.g. "OK") — the schema does
not type the detail result, so it shows up only in the wire type.
The `Action` shape is unchanged (`kind`, `phase`, `detail`,
`module`); `2de2c17` is behavioural — each header/body rewrite rule
is now its own action instead of being merged per kind.

**The Swift side changes for this rebase (v0.2.71):**
- `MitmExchangeSummary` gains `actionKinds: [String]?` and
  `answer: ConcordMitmAnswer?` (new enum, kebab-case raw values
  with Chinese labels), both `var` with `nil` defaults so older
  cores and the sample data still decode.
- `MitmExchangeDetail` gains `reason: String?`; `MitmExchangeAction`
  gains `module: String?` (the module whose line acted) plus a
  static `kindLabel(for:)` so the summary's action kinds can reuse
  the same labels.
- The capture detail page (`MitmExchangeDetailView`) shows the
  reason phrase with the status ("200 OK"), the local answer
  ("本地拒绝" / "本地重定向" / "本地映射" / "脚本应答", or "服务器"
  when the request went to it), the action kinds ("处理动作"), and
  the module on each matched-rule row.

Local verification at the new pin (Linux): the rebase itself is the
verification for the Rust side (all 8 patches apply cleanly, fresh
clone + patches byte-identical to the rebase tree). The `cargo check`
host verification was not re-run this time — the patches are
content-identical to the `0c9788f` versions that passed it, and the
upstream changes in this batch do not touch any patched file. The
macOS runner (which has `xcrun` and the iOS SDK) is the verification
for the full staticlib build, as before.

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to 646f8c9 (2026-11-23)

Patch `02` needed one hand-resolved conflict; `01`, `03`, `04`, `05`,
`06`, `07`, `08` are content-identical to their `9d1f485` versions
(only the `From` hashes, `index` hashes and hunk line numbers
shifted). The `04` conflict the watch report expected (one context-line
offset) did NOT materialize — the `Cargo.toml` hunk only shifted
302 → 300. New patch commits on top of `646f8c9` in
`/home/hatch/workspace/scratch/v0.2.60/rebase`, regenerated with
`git format-patch 646f8c9`; the regenerated patches applied to a fresh
clone at `646f8c9` produce a tree byte-identical to the rebase tree
(0 diff lines, verified before any `cargo` invocation; no
`Cargo.lock` regeneration involved — never commit it).

Patch `02` conflict, `crates/engine/src/engine/tun.rs`: upstream
deleted the `/// StopTun.` doc comment above `stop_vpn_tun`
(9d1f485 line 108 → 646f8c9 line 108 is the bare `pub async fn`),
and our hunk carried that line as context after the inserted
`start_channel_tun`. Resolved by keeping our `start_channel_tun`
verbatim and NOT re-adding the comment. The `crates/api/Cargo.toml`
hunk auto-merged: upstream added a dependency (`base64`) and gave
`concord-engine` a `features = ["mitm"]` in the region the patch
touches, so only the hunk context lines changed. The patch intent
(`start_channel_tun`, `DeviceSource::Channel`, the packet-channel
FFI) is unchanged.

55 commits since `9d1f485` (2026-11-23 00:45–06:34), dominated by an
API-typing refactor wave (`50ef2b9`, `fd82eed`, `2cff326`: MITM
validate / module views / module status, capture / certificate /
script answers and the probe + profile answers are now typed on the
wire), the engine split into modules (`af2e894`, `171bb13`,
`148c93f`), a QUIC refactor (`462b2e8`, `e1e1b0c`, `4f5e32e`,
`ac0430f`), the TUN/netstack tidy (`f316190`, `2ea8e31`, `bc22dbf`,
`4553f21`), and YAML rulesets moving to `concord-config`
(`1ac6125`). User-visible: `646f8c9` Hysteria / Hysteria2 /
ShadowQUIC send to the peer's credit window (QUIC stability);
`335673c` Hysteria2's initial receive window now takes effect;
`f30896f` a DNS query error names the bad field; `b6e129c` a config
key that defines a YAML anchor is treated as a template (no more
`unknown_key` warning for `rule-anchor` style keys); `02730c7`
building a config no longer drags geo addresses, UA and trust
config into `force`; `f169d89` MITM capture builds the header list
only while capturing; `c00991f` the config schema now lists each
fixed option's legal values. TUN changes are Linux/Android only
(`bc22dbf`, `10e2dbf`, `f316190`, `2ea8e31`); iOS is unaffected.

`schema/api.json` at the new HEAD still has **72 methods** — none
added, removed, or renamed. The change that matters: the 4 MITM
capture methods' results are now strong types instead of the generic
`MitmResult` (`{result: <untyped JSON>}`) — `mitm.runScript` →
`MitmScriptResult` (`{result: MitmScriptOutput {logs: string[],
result?: string, error?: string}}`), `mitm.exchanges` →
`MitmExchangesResult` (`{result: MitmExchangeList}`),
`mitm.exchange` → `MitmExchangeResult` (`{result: MitmExchange |
null}` — null when the capture no longer holds the exchange),
`mitm.body` → `MitmBodyResult` (`{result: MitmBody | null}` —
null when the capture no longer holds the body). `MitmExchangeList`
gains `closed` (the connection had closed when its list was taken,
so the list is whole); `MitmExchange` gains `route`
(`MitmRouteNote`: the rule that decided the request and the chain
it left through, exit first). The v0.2.71 fields are all still on
the wire (`action-kinds`, `answer`, `reason`, per-rule `actions`
with `module`). Also new in the schema: `c00991f` puts each fixed
option's legal values in the config schema — the core side of a
future config-editor dropdown; the App does not build that UI in
this version.

**The Swift side changes for this rebase (v0.2.75):**
- The 4 capture methods now decode typed result wrappers
  (`MitmScriptResult` / `MitmExchangesResult` /
  `MitmExchangeResult` / `MitmBodyResult`, in ConcordClient.swift)
  instead of the generic `ConcordMitmResult` + open-JSON re-decode
  (`JSONValue.decoded(as:)`, removed as unused). `MitmScriptOutput`
  is new (`logs`, optional `result` / `error`).
- `MitmExchangeList` gains `closed: Bool?` (optional-with-default
  so sample data that omits it still decodes).
- `MitmExchangeDetail` (MitmStore.swift) now mirrors the full
  `MitmExchange` wire shape: it gains `actionKinds`, `answer`,
  `host`, `path`, `contentType`, `statusClass`, `kind`, `rewritten`,
  `connectionId`, `app`, and `route` (`ConcordMitmRouteNote`:
  `rule`, `rule-payload`, `chains`), all optional-with-default.
  The v0.2.71 detail fields keep working through it (`reason`,
  per-rule `actions` with `module`) and through the summary
  (`answer`, `actionKinds`).
- `MitmStore` handles the new nulls: `mitm.exchange` / `mitm.body`
  returning `null` now shows "该记录已不在抓包缓存中" /
  "该正文已不在抓包缓存中" instead of a generic decode failure.
  The raw-JSON sections still show the full detail (the typed
  detail round-trips back to JSONValue).
- Sample data returns the typed wrappers (`MitmScriptResult` /
  `MitmExchangesResult` / `MitmExchangeResult` / `MitmBodyResult`);
  `sampleExchangeDetail` (open JSON) is replaced by
  `sampleExchangeDetailTyped` (a `MitmExchangeDetail` with the same
  values). The script-run displays in MitmStore / MitmModulesView /
  MitmScriptsView convert the typed output back to JSONValue, so
  the displayed JSON is unchanged in shape.
- No other Swift changes: every other new schema field is optional
  or ignored by the existing decoders, and no App UI changed.

Local verification at the new pin (Linux): the rebase itself is the
verification for the Rust side (all 8 patches apply cleanly, fresh
clone + patches byte-identical to the rebase tree). The `cargo check`
host verification was not re-run this time — patches `01` / `03` /
`04` / `05` / `06` / `07` / `08` are content-identical to the
`9d1f485` versions that passed it, and patch `02`'s only change is
the deleted `StopTun` comment line (the `start_channel_tun` body
and the `Cargo.toml` additions are unchanged). The macOS runner
(which has `xcrun` and the iOS SDK) is the verification for the full
staticlib build, as before.

Note: `Cargo.lock` in the upstream tree is stale against the patched
manifests (patch `01` adds the `bins/ios` member, patch `04` re-sources
nix — neither commit regenerates the lock). Any `cargo` invocation in the
patched tree rewrites it. That is harmless here: the workflows run
`cargo build` without `--locked`, so the runner regenerates the lock
itself. Do not commit a locally regenerated lock into a patch unless the
build is switched to `--locked`.

## Rebase to b3fab9e (2026-11-23)

All 8 patches apply cleanly to a fresh clone at `b3fab9e`, in order,
with zero rejects and zero hand fixes — every patch is
content-identical to its `646f8c9` version (only the `From` / `index`
hashes and hunk line numbers shifted). Verified in
`/home/hatch/workspace/scratch/v0.2.87/rebase` (fresh clone,
`git checkout b3fab9e`, sequential `git apply --check` + `git apply`
for `01`–`08`, all exit 0; `git diff --check` clean;
`git status --porcelain` shows 24 changed files — 20 modified + 4
new — and no `Cargo.lock` change). The patches were NOT regenerated.

8 commits since `646f8c9` (all 2026-11-23):

- `808d641` perf(anytls): hand received data frames to the relay
  without a copy (zero-copy relay path for AnyTLS).
- `43413e1` style(anytls): order the stream module's imports as
  rustfmt does (import ordering only).
- `92dfece` docs(agents): note the round-position effect on
  Hysteria2 CRR (agent guidance only).
- `b6f59c7` fix(android): link libconcord.so without identical code
  folding (Android link fix; no iOS effect).
- `e32ef81` fix(mitm): say a resource path that is still a URL has
  not been downloaded.
- `2436ece` fix(mitm): read a module's stored files in its preview.
- `7b33294` test(config): keep a module's USER-AGENT and URL-REGEX
  rules (test-only).
- `b3fab9e` test(mitm): write the module samples of the stored-file
  tests neutrally (test-only).

`schema/api.json` is byte-identical between `646f8c9` and `b3fab9e`
(`git diff 646f8c9 b3fab9e -- schema/api.json` empty) — still **72
methods**, none added, removed, or renamed.

Worth adding (both ride along with this rebase, no separate work):

- `2436ece`: `Mitm::read_module` now shows stored local file names
  for downloaded module resources — before, the module preview
  named every fetched script / map-local / jq file by its URL, so
  the host's module page showed them all as missing even though the
  section in force reads the stored files. The preview now names
  them by the files the store keeps (through the same
  `name_stored_files` that `compose` uses); a file not stored yet
  still shows as not downloaded. Verified present in the rebase
  tree: `name_stored_files` in `crates/config/src/mitm/modules.rs`.
- `e32ef81`: an un-downloaded resource error now says "has not been
  downloaded" — before, a module/profile line naming a remote file
  by URL produced a confusing error when the file had not been
  fetched yet. Verified present in the rebase tree: the
  `"{param} {} has not been downloaded"` format string in
  `crates/mitm/src/rules.rs`.

Not necessary: `808d641` (AnyTLS zero-copy — a perf-only core change
that rides along with the rebase; no API or UI surface, no Swift
work), `43413e1` (style only), `92dfece` (docs only),
`b6f59c7` (Android-only), `7b33294` and `b3fab9e` (test-only).

**No Swift changes needed for this rebase.** `api.json` is unchanged
(72 methods, no signature changes), so no new methods to wire and no
decoder changes. The two worth-adding items are core-side behaviour
that the existing Swift MITM module views already display through
`mitm.readModule`.

Local verification approach (Linux): fresh clone + `git apply`, as
above. No `cargo check` re-run — the patches are content-identical
to the `646f8c9` versions that passed host cargo checks, and the
macOS runner (which has `xcrun` and the iOS SDK) is the verification
for the full staticlib build, as before.

## Rebase to fdea08a (2026-11-24)

All 8 patches apply cleanly to a fresh clone at `fdea08a`, in order,
with zero rejects and zero hand fixes — every patch is
content-identical to its `b3fab9e` version. The two known manual
merge points from the `646f8c9` batch did NOT materialize this time:
patch `02`'s `crates/engine/src/engine/tun.rs` doc line and patch
`04`'s `vendor/PATCHES.md` one-line context offset both applied
cleanly, because this batch touches neither file. Verified in
`/home/hatch/workspace/scratch/v0.2.90/rebase` (fresh clone,
`git checkout fdea08a92b5da4c93171161715e48e7f72fcb9a5`, sequential
`git apply` for `01`–`08`, all exit 0; `git diff --check` clean;
`git status --porcelain` shows 24 changed files — 20 modified + 4
new — and no `Cargo.lock` change). The patches were NOT regenerated.

11 commits since `b3fab9e` (2026-11-23 09:54 – 2026-11-24 06:04):

- `0866812` feat(bench): add a page-load workload of concurrent
  HTTPS fetches (bench only).
- `8011658` refactor(tun,netstack): separate queue I/O and TCP
  output scheduling — the 564-line `driver.rs` is split into
  `driver/{rx,tx,dispatch}.rs`; replies/fragments built once, two
  slot strategies shared.
- `cfd9666` perf(tun,netstack): reuse the local TCP lookup when
  delivering a segment; a forwarded packet needs no send resource;
  a TIME_WAIT local connection keeps its owner on a replacement SYN.
- `a0e419e` perf(anytls): let a draining stream read its frames
  with the session's read half — a single draining stream borrows
  the session's read half in its own relay task, saving one Tokio
  task wakeup handoff per frame; the read half is returned on other
  frames, writes, stream end, or session close.
- `8949183` refactor(anytls): box the session's lent read half
  (pure refactor, follows `a0e419e`).
- `c226ca1` feat(bench): report the share of tcp-rr transactions
  slower than `--rr-slow-ms` (bench only).
- `8574eb9` + `2b52539` docs(agents): TUIC send-window measurement
  vs Go; UDP round session hash std vs foldhash (docs only).
- `a9602b8` perf(tunnel): evict one UDP flow per insert into a full
  table, least recently active first — replaces a full-table scan
  evicting the oldest 1/16th; a recency queue tracks last-seen
  activity per flow.
- `edb2924` docs(tunnel): shorten the UDP eviction comments.
- `fdea08a` feat(bench): add udp-multi and udp-crr workloads
  (bench only).

`schema/api.json` is byte-identical between `b3fab9e` and `fdea08a`
(`git diff b3fab9e fdea08a -- schema/api.json` empty) — still **72
methods**, none added, removed, or renamed. No file changed by this
batch is touched by any patch (`git diff --name-only
b3fab9e..fdea08a` vs the patch file list: zero overlap).

Worth adding (all ride along with this rebase, no separate work):

- `a0e419e`: anytls single-stream direct read — download-type
  traffic on anytls nodes is faster with lower CPU on iOS.
  Verified present in the rebase tree: the lent reader in
  `crates/proxy/src/anytls/session.rs` (`poll_lent`).
- `cfd9666`: TCP ingress reuses the local lookup + TIME_WAIT
  replacement-SYN ownership — TUN/TCP hot-path optimisation and a
  correctness fix on the same path iOS uses. Verified present:
  `TIME_WAIT` handling in `crates/netstack/src/tcp/mod.rs`.
- `a9602b8`: UDP NAT per-insert LRU eviction — cheaper and fairer
  when the table is full; DNS, QUIC, game and voice traffic share
  the same UDP NAT on iOS. Verified present: the recency queue and
  `evict_oldest` in `crates/tunnel/src/udp/nat.rs`.
- `8011658`: driver split refactor — no visible function by itself,
  but it is the structural basis for `cfd9666`; rebase after it
  needs a TUN test. Verified present:
  `crates/tun/src/stack/driver/{rx,tx,dispatch}.rs`.

Not necessary: `0866812`, `c226ca1`, `fdea08a` (bench only);
`8574eb9`, `2b52539`, `edb2924` (docs/comments only); `8949183`
(pure refactor, rides along with `a0e419e`).

**No Swift changes needed for this rebase.** `api.json` is unchanged
(72 methods, no signature changes), so no new methods to wire and no
decoder changes. The worth-adding items are core-side behaviour
(performance on paths the existing Swift client already uses).

Local verification approach (Linux): fresh clone + `git apply`, as
above. No `cargo check` re-run — the patches are content-identical
to the `b3fab9e` versions that passed host cargo checks, and the
upstream changes in this batch touch no patched file; the macOS
runner (which has `xcrun` and the iOS SDK) is the verification for
the full staticlib build, as before.

## Rebase to 33904fff (2026-11-25)

All 8 patches apply cleanly to a fresh clone at `33904fff`, in order,
with zero rejects and zero hand fixes — every patch is
content-identical to its `fdea08a` version (only the `From` / `index`
hashes and hunk line numbers shifted: patch `02`'s `live.rs` hunks
410 → 415 and 422 → 427 and its `api.json` hunk 4608 → 4613, patch
`03`'s `device/mod.rs` hunk 315 → 327, patch `06`'s `device/mod.rs`
hunks +5/+5/+12 — all from upstream lines added above the patched
regions). The two known manual merge points from the `646f8c9` batch
did NOT materialize again: patch `02`'s `crates/engine/src/engine/tun.rs`
doc line and patch `04`'s `vendor/PATCHES.md` context offset both
applied cleanly, because this batch touches neither file. Patch `09`
was REMOVED: its content (`2e2cc02`) is now in the core, so leaving
it would fail to apply. Verified in
`/home/hatch/workspace/scratch/v0.2.109/rebase` (fresh clone,
`git checkout 33904fff812041498a5a647930138f5ad4f26013`, sequential
`git apply` for `01`–`08`, all exit 0; `git diff --check` clean;
`git status --porcelain` shows 24 changed files — 20 modified + 4
new — and no `Cargo.lock` change). The patches were regenerated with
`git format-patch 33904fff` from 8 commits on top of the pin; the
regenerated patches applied to a fresh clone at `33904fff` produce a
tree byte-identical to the rebase tree (0 diff lines).

19 commits since `fdea08a` (2026-11-24 – 2026-11-25 12:11), in two
batches. `a5e4e5c` (10 commits, 2026-11-24) is the TUN/driver batch:
`2e2cc02` ends a busy driver pass on the cooperative budget instead
of a round count (the v0.2.101 phone-heating fix, now upstream);
`823b6b6` draws the cooperative budget for each Windows TUN read and
write (Windows only); `9954810` / `01a92a6` / `5aa255b` / `564f71e`
let macOS name the utun when the device name is not a utun unit
(macOS only — iOS never names a device, the NetworkExtension owns
it); `a5e4e5c` lowers the tunables ratchet to 76 (build-only);
`708b55f` / `5aa255b` style, `ca48b70` / `9308b84` docs. `33904fff`
(9 commits, 2026-11-25) is the downloads/URL-test + API batch:
`33904ff` (see below), `ccdca6a` + `b5410bf` (downloads), `1392a8a`
(traffic watch), `78ee46f` / `40631b2` (MITM hostname view),
`09a46c1` / `be665be` (perf), `b55e9b7` (test-only).

`schema/api.json` at the new HEAD still has **72 methods** — none
added, removed, or renamed. Two additive changes, both optional:
`TrafficWatchParams` gains `changesOnly` (`boolean`, default
`false` — from `1392a8a`: send a sample only when it differs from
the last one sent; the default stays one sample per interval), and
`MitmHostItem` gains `reason` (`string | null` — from `78ee46f`:
why a hostname item could not be read) with a reworded description.

Worth adding (all ride along with this rebase, no separate work):

- `33904ff`: group downloads and URL tests now speak HTTP/1.1
  without ALPN, headers in canonical case, as mihomo does — before,
  Concord offered h2 on downloads and wrote lowercase names over
  HTTP/1.1, a request shape no client that passed the same firewall
  rule had. This is the most valuable commit in the range: it
  directly affects the delay test (URL test) and subscription /
  rule-set downloads, the paths most exposed to firewall
  fingerprinting. Verified present in the rebase tree: the
  HTTP/2 path is gone from `crates/group/src/http.rs`
  (`http1::Builder::new().title_case_headers(true)` only, no ALPN
  offered).
- `ccdca6a`: downloads add `Accept: */*` and `Accept-Encoding: gzip`
  and unpack gzip when asked for — a provider behind a web-firewall
  rule answered 403 to Concord alone (missing both headers flags a
  bot); headers a provider names win, and the size limit holds the
  unpacked body. Verified present: the `Accept` / `Accept-Encoding`
  defaults in `crates/engine/src/resources/fetch.rs`.
- `b5410bf`: a refused download (outside 2xx) now logs each hop's
  status + host and the first 4 KiB of the body — a 403 can now be
  told apart as a firewall refusal page vs the origin's, and a
  redirect chain is visible. The error itself keeps mihomo's status
  text, which the host reads.
- `2e2cc02`: the driver cooperative budget (the v0.2.101
  phone-heating fix) is now upstream — no longer a local patch.
  Verified present in the rebase tree: `MAX_ROUNDS` count 0,
  `has_budget_remaining()` in `crates/tun/src/stack/driver.rs`,
  `poll_proceed` + `made_progress()` in
  `crates/tun/src/device/apple.rs`, 76 tunables entries against the
  76 ceiling.
- `78ee46f` + `40631b2`: a MITM hostname line's view lists every
  item in the order written, and an item that could not be read
  carries its `reason` and takes no effect; whitespace in a host is
  named by code point (U+0020 / U+00A0 / U+3000) instead of an
  unreadable `' '`. Surfaces through `mitm.readModule` views the
  app already displays.
- `09a46c1` / `be665be`: perf-only (jq prelude parsed once; a
  regex's syntax tree checked without translating where that cannot
  fail).
- `1392a8a`: `changesOnly` is available (opt-in) — the app does not
  send it yet, so behaviour is unchanged; a future Dashboard
  optimisation (fewer wakeups when the link is idle).

Not necessary: `823b6b6` (Windows TUN only); `9954810` / `01a92a6` /
`564f71e` (macOS utun naming only); `708b55f` / `5aa255b` (style);
`ca48b70` / `9308b84` (docs); `b55e9b7` (test-only); `a5e4e5c`
(xtask ratchet, build-only).

**No Swift changes needed for this rebase.** `api.json` is unchanged
(72 methods, no signature changes), so no new methods to wire and no
decoder changes. `changesOnly` is opt-in with default `false` and
the app does not send it; `MitmHostItem.reason` is optional and
ignored by Swift's synthesized `Codable` (surfacing it in the MITM
hostname view is a future UI touch, not required). The worth-adding
items are core-side behaviour on paths the existing Swift client
already uses.

Local verification approach (Linux): fresh clone + `git apply`, as
above, plus the byte-identical check against the rebase tree. No
`cargo check` re-run — the patches are content-identical to the
`fdea08a` versions that passed host cargo checks, and the upstream
changes in this batch touch no patched file's logic (only line
numbers above the hunks); the macOS runner (which has `xcrun` and
the iOS SDK) is the verification for the full staticlib build, as
before.
