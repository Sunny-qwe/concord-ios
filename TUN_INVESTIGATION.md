# Concord TUN / packet-flow investigation — can NEPacketTunnelProvider packets be fed into Concord?

Date: 2026-11-16
Upstream checked: https://github.com/chen08209/concord, main branch,
commit `187ac9d1e9282f07c05c49eb2ea9d4bc0ef243b6` (2026-11-16 01:25 +0800),
cloned shallow to `/tmp/concord-upstream`.

## Short answer

**No — not as-is.** Concord's `tun.start` has only two packet sources, and neither
is an iOS `NEPacketTunnelFlow`:

1. `{"kind": "device"}` — the core creates its own TUN device (impossible inside a
   NetworkExtension; the system owns the tunnel interface).
2. `{"kind": "inherited", "handle": <u64>}` — the host hands the core a **real OS
   file descriptor** of a TUN device it opened beforehand. iOS
   `NEPacketTunnelProvider` never gives you such an fd; it only gives you
   `packetFlow.readPackets()` / `writePackets()`.

There is **no** packet-channel, callback, socket, or "write this IP packet into the
core" API in the public JSON-RPC schema or the C FFI.

**But the gap is narrow and concrete.** The core already runs fully in-process
(there is a real C ABI + JSON-RPC, proven by the Android `libconcord.so`), the
userspace IP stack is driven by a generic `Device` trait (`poll_recv` /
`poll_send`), and a channel-backed test device with exactly the needed
`inject()` / `take()` shape already exists in the tree — it is just test-only
and not wired to any public API. Two realistic bridges exist (see §5); the
cheapest to try first is a **datagram socketpair handed to `concord_adopt_fd`**
(no upstream change needed, but unverified and with framing caveats). If that
fails, the correct fix is a **new production packet-channel `DeviceSource` in
upstream Concord** (a fork/patch, not a scaffold-only change).

## 1. What `tun.start` actually accepts

`schema/api.json` lines 4074–4160 (`TunStartParams`) and
`crates/proto/src/types/live.rs:245-261, 304-316`:

```json
"TunStartParams": {
  "properties": {
    "source": { "$ref": "#/$defs/TunSource" },
    "stack":  { "type": ["string", "null"] },
    "mtu":    { "type": ["integer", "null"], "format": "uint32" },
    "address": { "type": "array", "items": { "type": "string" }, "default": [] },
    "dns":     { "type": "array", "items": { "type": "string" }, "default": [] },
    "congestionController": { "type": ["string", "null"] }
  },
  "required": ["source"]
}
```

```rust
/// A device the core creates itself, or a descriptor the host opened and
/// registered beforehand.
pub enum TunSource {
    Device { name: Option<String> },
    Inherited { handle: u64 },
}
```

`schema/api.json:671-682` — `tun.start` is a unary, serial RPC method; there is
no streaming / packet parameter anywhere in the schema. `core.init`
(`CoreInitParams { home: String, sdk_int: Option<i32> }`,
`crates/proto/src/types/config.rs:59-63`) takes only a home directory and an
Android SDK level. `config.apply` takes a profile; `engine.start` takes
`Empty` and only starts the listeners (`crates/api/src/control.rs:1126-1136`).

### Implementation — `crates/api/src/control.rs:1138-1200`

```rust
async fn tun_start(&self, params: TunStartParams) -> Result<Empty, ApiError> {
    match params.source {
        TunSource::Device { name } => {
            if self.engine.is_android() {
                return Err(ApiError::unsupported_capability(
                    "tun.device",
                    "this platform hands the core a descriptor instead",
                ));
            }
            // … engine.update() with a TunPatch (core creates the device)
        }
        TunSource::Inherited { handle } => {
            #[cfg(unix)]
            {
                let fd = self.fds.take(handle)
                    .ok_or_else(|| ApiError::not_found("handle", handle.to_string()))?;
                // …
                let started = self.engine.start_vpn_tun(fd, VpnTunRequest {
                    stack: params.stack.unwrap_or_default(),
                    address: params.address.join(","),
                    dns: params.dns.join(","),
                    options: options.to_string(),
                }).await;
            }
            #[cfg(not(unix))]
            { return Err(ApiError::unsupported_capability(
                "tun.inherited", "this platform has no descriptors to inherit")); }
        }
    }
}
```

The `handle` is looked up in `AdoptedFds` (`crates/api/src/fds.rs:11-40`):
"Descriptors a host opened for the core and registered before `tun.start`
names them. Registering hands over ownership." Registration happens through the
FFI (see §3), not through JSON-RPC.

## 2. What the core does with an inherited fd

`crates/engine/src/engine.rs:619-660` — `start_vpn_tun(fd: OwnedFd, request:
VpnTunRequest) -> bool` calls `vpn_options()` (`crates/engine/src/tun.rs:196-246`,
which parses `address`/`dns`/MTU and forces `auto_route: false`) and then
`start_runner(..., DeviceSource::Adopt(fd), ...)` (`crates/engine/src/tun.rs:263-279`).

`crates/tun/src/runner.rs:43-47, 134-143`:

```rust
pub enum DeviceSource {
    Create,
    /// The descriptor of an Android `VpnService` interface.
    #[cfg(unix)]
    Adopt(std::os::fd::OwnedFd),
}
// in TunRunner::start():
DeviceSource::Create => TunDevice::create(options),
DeviceSource::Adopt(fd) => TunDevice::adopt(fd),
```

`crates/tun/src/device/mod.rs:319-330`:

```rust
/// Adopts the descriptor of a `VpnService` interface. The descriptor is closed on every
/// failure path, including the ones before tun-rs takes it over.
#[cfg(unix)]
pub fn adopt(fd: std::os::fd::OwnedFd) -> io::Result<Self> {
    let inner = unsafe { tun_rs::AsyncDevice::from_fd(fd.into_raw_fd()) }?;
    Ok(Self::wrap(inner))
}
```

So the inherited path is a **byte-stream fd wrapped by tun-rs** (`tun-rs = 2.8.16`,
vendored at `vendor/tun-rs`, patched in the workspace `Cargo.toml:278-286`).
The core then reads raw IP packets from that fd and writes reply packets back
to it, through the userspace stack (`NetStack`, `crates/tun/src/stack/`).

Two iOS-relevant details of this path:

- **Routes are a no-op on iOS.** `Os::current()` (`crates/tun/src/route/mod.rs:142-169`)
  returns `Os::Other` on any target that is not Linux/macOS/Windows, and
  `platform_backend()` (`crates/tun/src/runner.rs:108-118`) then uses a
  `NullBackend` and `plan()` returns `Plan::default()` (empty). That is actually
  convenient: on iOS the system (NetworkExtension) owns routing, and the core
  must not install routes. `vpn_options()` also sets `auto_route: false`.
- **Device creation is the wrong path on iOS.** `TunDevice::create`
  (`crates/tun/src/device/mod.rs`, `#[cfg(not(target_os = "android"))]`) calls
  `tun_rs::DeviceBuilder`, which on iOS would try to create a utun interface
  itself. Inside a PacketTunnel extension the system already owns the tunnel
  interface; creating one is not the sanctioned path and was not verified.

The vendored tun-rs does know about iOS: `vendor/tun-rs/src/platform/unix/tun.rs`
has `macos/ios/tvos` branches that prepend/strip the 4-byte utun packet-information
header (`AF_INET`/`AF_INET6`, `generate_packet_information()`), and
`vendor/tun-rs/src/async_device/mod.rs:205-213` documents `BorrowedAsyncDevice`
as "designed for scenarios where the file descriptor is managed externally, such
as: **iOS PacketTunnelProvider (NetworkExtension framework)**, Android
VpnService". But Concord does **not** use `BorrowedAsyncDevice`, and — decisively
— `NEPacketTunnelProvider` exposes **no fd at all**, so even tun-rs's iOS
anticipation does not match the NE API. (tun-rs also ships
`vendor/tun-rs/src/platform/apple/mod.rs:utun_fd()`, which scans fds 0–1024 for
a `com.apple.net.utun_control` socket — a fragile hack, not a documented NE API,
and not used by Concord.)

## 3. The core IS reusable in-process — the Android model

This is the good news. Concord is not desktop-child-process-only.

- `docs/usage.md:59-62`: "An application can run Concord as a child process on
  desktop or **load `libconcord.so` on Android**, and drive it through the
  JSON-RPC 2.0 API."
- `crates/ffi/` is a real C ABI (`crates/ffi/src/lib.rs`): `concord_open`,
  `concord_open_callback`, `concord_send`, `concord_close`,
  `concord_init_dart_api`, and on Unix `concord_adopt_fd(fd: i32) -> u64`
  (`crates/ffi/src/abi.rs:75-87`):

  ```rust
  /// Hands a descriptor to the core, which closes it. The returned handle is what
  /// `tun.start` names as `{"kind":"inherited","handle":…}`; 0 means the core is not up,
  /// and the descriptor is closed.
  #[cfg(unix)]
  #[unsafe(no_mangle)]
  pub extern "C" fn concord_adopt_fd(fd: i32) -> u64
  ```

  Sessions are JSON-RPC over `concord_send` / a `Deliver` callback
  (`crates/ffi/src/hub.rs:129` — `adopt_fd` forwards to
  `control.adopted_fds().adopt(fd)`).
- `bins/android/` is the working template: `bins/android/Cargo.toml:13`
  `crate-type = ["cdylib", "rlib"]` producing `libconcord.so`, with
  `concord_start` (builds the core once per process) and
  `concord_set_platform_host` (callbacks for `VpnService.protect`,
  `resolve_uid`, `resolve_package`) in `bins/android/src/abi.rs`, and
  `Core::new` with `EngineConfig { android: true, ... }` plus capabilities
  `["tun.inherited", "host.protect", "host.resolveUid"]` in
  `bins/android/src/core.rs:11, 150`.

What does **not** exist for iOS (searched the whole tree):

- No `bins/ios`, no iOS target in CI (`.github/workflows/ci.yaml` runs
  `check`, `macos`, `android` only), no `aarch64-apple-ios` target anywhere
  outside vendored tun-rs's Cargo metadata.
- No `crate-type = ["staticlib"]` anywhere in the workspace (only the Android
  `cdylib`); no cbindgen, no Swift/ObjC bridging header, no iOS entry point.
- No iOS-specific platform host. The only platform host is Android's
  (`bins/android/src/platform.rs`: `PlatformHost` trait with `protect` /
  `resolve_uid` / `resolve_package`). `protect` matters on Android because
  `VpnService` routes the app's own sockets into the VPN
  (`crates/net/src/held.rs:7-9`); whether the iOS extension's own outbound
  sockets need equivalent treatment is **not** addressed anywhere in the code
  and is unverified (in practice NE provider sockets are generally not
  looped back into the tunnel, but do not assume this).
- The `Device` implementation selected for iOS in
  `crates/tun/src/device/mod.rs:6-16` is the generic `other.rs` (not
  `apple.rs`, which is `#[cfg(target_os = "macos")]` only), and
  `crates/platform` has `#[cfg(target_os = "ios")]` handling only in
  `sockopt.rs:72,118` and `netinfo/ifaces.rs:102`. So iOS mostly falls through
  to the generic-Unix paths — plausible, but nothing iOS-specific was ever
  compiled or tested upstream.

## 4. Is there any packet-injection API already?

No, in production code. The closest thing is test-only:

`crates/tun/src/testing.rs:1` — "A channel-backed device for driving the stack
without a TUN interface." `fake_device(slots, slot_size) -> (FakeDevice,
FakeNet)` with `FakeNet::inject(&self, packet: &[u8]) -> bool` (line 294) and
`FakeNet::take(&self, out: &mut [u8]) -> usize` (line 312). The stack itself is
generic over the device: `NetStack::prepare<D: Device>(dev, sink, stop)`
(`crates/tun/src/stack/mod.rs:170-179`) and `TunRunner::start_with<D: Device>`
is generic too — but it is `pub(crate)` (`crates/tun/src/runner.rs:177`), and
`TunRunner::start` only accepts the `DeviceSource` enum. The `testing` module
is gated `#[cfg(any(test, feature = "testing"))]` (`crates/tun/src/lib.rs`),
and `crates/tun/Cargo.toml` defines `testing = []` as an empty feature. So the
abstraction and even a reference implementation exist, but there is no public
path to use them, and no RPC/FFI method to inject packets.

## 5. What would be required — two options

### Option A (try first, no upstream change): a datagram socketpair as a fake TUN fd

1. In the PacketTunnel extension (Swift or Rust), create a Unix **datagram**
   socketpair (`socketpair(AF_UNIX, SOCK_DGRAM, 0, ...)`).
2. Hand one end to the core with `concord_adopt_fd(fd)`, then call
   `tun.start` with `{"source": {"kind": "inherited", "handle": <returned>}}`,
   `stack`/`address`/`dns` as on Android.
3. Pump packets: `packetFlow.readPackets()` → write each packet into the
   socketpair end; read packets the core writes back → `packetFlow.writePackets()`.

Caveats, all unverified — this is a hypothesis to test, not a known-working
bridge:

- **Packet framing.** A `SOCK_STREAM` socketpair does not preserve packet
  boundaries; a tun-rs `recv` could return a partial or coalesced packet and
  corrupt the IP stream. A `SOCK_DGRAM` socketpair preserves datagram
  boundaries, which is why it must be datagram, not stream. (No `socketpair`
  usage exists anywhere in Concord to copy from.)
- **The 4-byte utun header.** On Apple targets the vendored tun-rs
  prepends/strips a 4-byte `AF_INET`/`AF_INET6` packet-information header on
  write/read (`vendor/tun-rs/src/platform/unix/tun.rs`,
  `generate_packet_information()`). The Swift side would most likely have to
  add that header when writing packets in and strip it when reading them out.
  Which side of the boundary this lands on depends on whether the iOS build
  takes the `other.rs` device path (it does, per §3) and tun-rs's
  `ignore_packet_information` default (`true` in `Tun::new`).
- **fd ownership / name lookup.** `TunDevice::adopt` takes ownership of the fd
  (`from_raw_fd`), and `wrap()` calls `inner.name().unwrap_or_default()` and
  `inner.if_index().ok()` (`crates/tun/src/device/mod.rs:332-334`). On a
  socket fd the name lookup (ioctl `SIOCGIFNAME` via tun-rs
  `platform/unix/device.rs:196-199`) will fail, but the code tolerates it
  (empty name, `None` index). Routes are empty on iOS anyway (§2).
- **tokio registration.** `tun_rs::AsyncDevice::from_fd` registers the fd with
  the tokio reactor; a socketpair fd should be pollable, but this was never
  exercised with a non-TUN fd.
- **Extension lifetime / memory.** The core would run inside the
  PacketTunnelProvider process, under the NetworkExtension memory limit
  (historically ~15 MB, more recently reported ~50 MB). Concord's desktop
  binary budget is 30 MB (`CORE_MAX_BYTES`, `.github/workflows/ci.yaml:14-15`);
  whether the core + its rule/geo data fit in an NE extension is unverified.

### Option B (correct fix, needs an upstream fork/patch): a production packet-channel device

Promote the `FakeDevice` pattern to a real `DeviceSource`:

1. Add a new `DeviceSource` variant (e.g. `Channel`) backed by an
   in-memory ring/channel implementing the `Device` trait
   (`crates/tun/src/device/mod.rs:22`, `poll_recv`/`poll_send`), reusing
   `crates/tun/src/testing.rs` as the template but as production code.
2. Expose it: either a new `TunSource` kind in the JSON-RPC schema
   (`crates/proto/src/types/live.rs:304`, `schema/api.json:4119`) plus a new
   FFI pair (`concord_packet_write` / a callback or poll for outbound packets),
   or a new `DeviceSource` wired through `start_vpn_tun`-style plumbing.
3. Add an iOS bin (`bins/ios`, `crate-type = ["staticlib"]`) mirroring
   `bins/android`, with an iOS platform host (no `protect`/`resolve_uid`/
   `resolve_package`, or no-op equivalents) and `EngineConfig { android: false }`
   — plus deciding what `core.init`'s `sdk_int` and the `is_android()` branches
   mean on iOS.
4. This is the architecturally clean route, and it is also the most work: it
   touches upstream Concord's public API/schema and needs a maintained fork
   (or an upstream contribution) until/unless the project accepts it.

### What does NOT work

- Feeding `packetFlow` packets into `tun.start` as-is: no such parameter exists.
- `TunSource::Device` on iOS: the core would try to create its own utun device
  inside the extension, which is not the sanctioned NE path.
- Using the desktop child-process model on iOS: iOS forbids `fork`/`exec`/
  `posix_spawn` of a bundled helper; the core must be linked in-process
  (staticlib) into the extension.
- Running only the SOCKS/mixed listeners (`engine.start`) and hoping the
  system routes packets to them: without a TUN/packet path the core never sees
  device traffic. Those listeners are useful for testing the core in-process,
  not as a VPN data plane.

## 6. BoringSSL / iOS build compatibility

- `boring = 5.4`, `tokio-boring = 5.3` (workspace `Cargo.toml:107-108`);
  `crates/tls` uses it for ECH/REALITY etc. (`crates/tls/Cargo.toml:28-29`,
  `crates/tls/src/boring_backend.rs`). The `boring` crate itself is patched
  to the vendored copy (`[patch.crates-io] boring = { path = "vendor/boring" }`),
  but `boring-sys 5.4.0` comes from crates.io (`Cargo.lock`) and compiles
  BoringSSL C code via `cmake` + `bindgen`.
- BoringSSL upstream does support iOS targets in principle (it is used in iOS
  apps), and `aws-lc-rs` (used by rustls/quinn, `aws-lc-sys` with
  `prebuilt-nasm`) is in the same boat. **But: no iOS build has ever been run
  for this workspace** — CI has no `aarch64-apple-ios` job, no iOS SDK/sysroot
  handling, and no target in any `Cargo.toml`. Whether `boring-sys` /
  `aws-lc-sys` / `quinn` / `tun-rs` compile and link for
  `aarch64-apple-ios` (Xcode SDK, `cmake`, `bindgen` with the iOS sysroot,
  no bitcode) is **unverified**. This is the first gate to test, before any
  packet-flow work: `cargo build --target aarch64-apple-ios -p concord-ffi`
  (or the new iOS bin) on a macOS runner.

## 7. Realistic next step for `Sunny-qwe/concord-ios`

The scaffold's current state (SwiftUI app + `PacketTunnelProvider` skeleton +
Rust `concord-ios-ffi` stubs `concord_ios_init/start/stop`) does not match the
real upstream API at all: the real entry points are `concord_start`,
`concord_open`/`concord_send`/`concord_adopt_fd` plus JSON-RPC
(`core.init` → `config.apply` → `engine.start` → `tun.start`), and the
scaffold's stubs would have to be replaced by a thin wrapper around
`concord-ffi` (or a new `bins/ios` staticlib crate).

Suggested order, cheapest gate first:

1. **Prove the core compiles for `aarch64-apple-ios`.** Add a minimal iOS
   bin crate (`crate-type = ["staticlib"]`) mirroring `bins/android`
   (minus the Android platform host), and build it on a GitHub Actions
   macOS runner. If `boring-sys`/`aws-lc-sys` fail here, stop and reassess —
   nothing else matters until this passes.
2. **Prove the packet bridge on macOS first.** Build the same core for macOS,
   adopt one end of a `SOCK_DGRAM` socketpair, pump a synthetic IP packet
   through `tun.start` (inherited), and confirm the packet is parsed/proxied
   and a reply comes back. This tests the framing/header questions of
   Option A without an iPhone or an NE extension.
3. **Only then wire the NE extension.** Link the staticlib into the
   PacketTunnel target, run the core in the extension process, and shuttle
   `packetFlow` packets through the socketpair. Keep the SwiftUI app talking
   to the extension via App Group / `sendProviderMessage`, not by loading the
   core in the app process.
4. **If Option A fails, do Option B** (new packet-channel `DeviceSource` in a
   Concord fork) — do not try to fake it with a Swift-side TCP/UDP proxy
   around the SOCKS listener; that re-implements the userspace stack and loses
   Concord's rules/DNS/fake-IP handling per flow.
5. **Do not promise a working proxy yet.** Until step 2 passes, the scaffold
   remains a UI skeleton: it can open, but it cannot proxy traffic. The
   unsigned-IPA build failure seen in Actions run #2 ("Signing for Concord
   requires a development team", exit 65) is a separate scaffold/signing
   problem and is unrelated to the TUN question.

## Evidence index

| Claim | Source |
|---|---|
| `tun.start` params: only `source`, `stack`, `mtu`, `address`, `dns`, `congestionController` | `schema/api.json:4074-4117`; `crates/proto/src/types/live.rs:245-261` |
| `TunSource` = `Device{name?}` or `Inherited{handle: u64}` | `schema/api.json:4119-4160`; `crates/proto/src/types/live.rs:304-316` |
| Inherited fd is taken from a host-registered fd table and passed to `start_vpn_tun` | `crates/api/src/control.rs:1162-1195`; `crates/api/src/fds.rs:11-40` |
| Inherited path wraps fd in tun-rs `AsyncDevice::from_fd` | `crates/engine/src/engine.rs:619-660`; `crates/tun/src/runner.rs:43-47, 134-143`; `crates/tun/src/device/mod.rs:319-330` |
| Routes are a no-op on iOS (`Os::Other`, `NullBackend`) | `crates/tun/src/route/mod.rs:142-169`; `crates/tun/src/runner.rs:100-118` |
| C ABI: `concord_open/send/close`, `concord_adopt_fd` | `crates/ffi/src/abi.rs:25-87`; `crates/ffi/src/hub.rs:129` |
| Android model: `libconcord.so` cdylib, `concord_start`, capabilities `tun.inherited` | `bins/android/Cargo.toml:13`; `bins/android/src/abi.rs`; `bins/android/src/core.rs:11, 150` |
| No iOS bin / staticlib / cbindgen / iOS CI job | `Cargo.toml` workspace members; `.github/workflows/ci.yaml`; grep over `crates/ bins/` |
| Channel-backed test device `FakeDevice`/`FakeNet::inject`/`take`, test-gated | `crates/tun/src/testing.rs:1, 294-330`; `crates/tun/src/lib.rs` (`#[cfg(any(test, feature = "testing"))]`); `crates/tun/Cargo.toml` (`testing = []`) |
| `Device` trait is generic; `TunRunner::start_with` is `pub(crate)` only | `crates/tun/src/device/mod.rs:22-...`; `crates/tun/src/runner.rs:177` |
| tun-rs anticipates iOS PacketTunnelProvider (borrowed fd) but Concord doesn't use it | `vendor/tun-rs/src/async_device/mod.rs:205-213`; `vendor/tun-rs/src/platform/apple/mod.rs:23` |
| utun 4-byte AF header handling on Apple targets in vendored tun-rs | `vendor/tun-rs/src/platform/unix/tun.rs` (`generate_packet_information`) |
| BoringSSL 5.4 via crates.io `boring-sys`, cmake build, no iOS verification | workspace `Cargo.toml:107-108, 278-286`; `Cargo.lock` (`boring-sys 5.4.0`); `crates/tls/Cargo.toml:28-29` |
| Embedding model: child process on desktop, `libconcord.so` on Android | `docs/usage.md:59-62` |

## What was NOT verified

- Whether `boring-sys` / `aws-lc-sys` / `quinn` / `tun-rs` compile for
  `aarch64-apple-ios` (no Mac, no Xcode SDK in this environment; no iOS build
  was attempted).
- Whether a `SOCK_DGRAM` socketpair fd survives `tun_rs::AsyncDevice::from_fd`
  + tokio registration and carries IP packets correctly (framing and the
  4-byte utun header are inferred from the vendored tun-rs code, not tested).
- Whether an NE extension's own outbound sockets are routed outside the
  tunnel (no `protect` equivalent exists for iOS in the code).
- Whether the core + geo/rule data fit in a NetworkExtension process memory
  limit.
- Anything about the scaffold's Xcode project itself (that is a separate
  build/signing problem, not covered here).
