// concord-ios-ffi — thin Swift-friendly wrapper over the REAL Concord C ABI.
//
// This crate is exactly ONE FFI layer: it declares the real symbols
// (`concord_start`, `concord_open_callback`, `concord_send`, `concord_close`,
// `concord_adopt_fd`, `concord_packet_channel_*`) as `extern "C"` and exposes
// them under `concord_ios_*` names that Swift can call without juggling
// `u64` session ids and raw callback types. It contains NO core logic and
// NO stubs: the symbols are defined elsewhere and resolved at final link.
//
// The real symbols live in `libconcord_ios.a`, built from upstream
// `chen08209/concord` at the pinned commit with `patches/01-bins-ios.patch`
// applied (the `bins/ios` crate — local inspection copy at `upstream/`,
// see `patches/README.md`) plus the Option B patch set (see `patches/`).
// The Xcode PacketTunnel target must link BOTH
// `libconcord_ios_ffi.a` (this crate) AND `libconcord_ios.a`; the
// `concord_*` symbols below are undefined in this crate and resolve from
// the latter. Linking only this crate produces undefined-symbol errors for
// `concord_start`, `concord_open_callback`, etc. — that is expected, not a
// bug in this crate.
//
// BREAKING CHANGE vs the old stubs: `concord_ios_init/start/stop` are GONE.
// There is no "start with a config file path" entry point in the real API.
// The flow is JSON-RPC over a session (see `concord_ios.h` —
// `patches/01-bins-ios.patch` — and `schema/api.json` upstream):
//   concord_ios_start()                          // concord_start, once per process
//   session = concord_ios_open_session(...)      // concord_open_callback
//   concord_ios_send(session, core.hello …)      // one JSON-RPC message per call
//   concord_ios_send(session, core.init {"home": "<app-group dir>"})
//   concord_ios_send(session, config.apply …)
//   concord_ios_send(session, engine.start …)
//   handle = concord_ios_packet_channel_open()   // Option B (patched tree)
//   concord_ios_send(session, tun.start {"source": {"kind": "channel", "handle": handle}})
//   pump: packetFlow.readPackets → concord_ios_packet_write(handle, …);
//         concord_ios_packet_read(handle, …) → packetFlow.writePackets
//   // Option A instead: fd,handle = concord_ios_bridge_open() (bins/ios,
//   // declared in concord_ios.h — see patches/01-bins-ios.patch)
//   // and tun.start {"source": {"kind": "inherited", "handle": handle}}.
//   concord_ios_close_session(session)
//
// `concord_ios_packet_channel_*` only exist in a patched tree (Option B);
// until the patch is applied they are unresolved symbols — use the Option A
// bridge (`concord_ios_bridge_open`, also in `libconcord_ios.a`) instead.
//
// This crate builds on Linux for syntax checking, but its symbols only
// resolve when linked with the real staticlib on macOS/iOS.

use std::ffi::{c_int, c_void};

/// A JSON-RPC message delivered to Swift: `data`/`len` are one complete
/// message, valid only during the call. Return `false` once the host is
/// gone; that ends the session. Runs on a core thread.
pub type ConcordDeliver =
    unsafe extern "C" fn(context: *mut c_void, data: *const u8, len: usize) -> bool;
/// Runs once when the core no longer holds the session (or right away when
/// the open fails because the core is not up). May be null.
pub type ConcordRelease = unsafe extern "C" fn(context: *mut c_void);

// The real Concord C ABI, defined in `libconcord_ios.a` (bins/ios in the
// patched upstream tree + crates/ffi). Declared here so Swift calls one
// wrapper layer; see the module docs for where each symbol comes from.
extern "C" {
    fn concord_start() -> c_int;
    fn concord_open_callback(
        deliver: ConcordDeliver,
        context: *mut c_void,
        release: Option<ConcordRelease>,
    ) -> u64;
    fn concord_send(session: u64, data: *const u8, len: usize) -> c_int;
    fn concord_close(session: u64);
    fn concord_adopt_fd(fd: c_int) -> u64;
    fn concord_packet_channel_open() -> u64;
    fn concord_packet_write(handle: u64, data: *const u8, len: usize) -> c_int;
    fn concord_packet_read(handle: u64, buf: *mut u8, cap: usize) -> c_int;
    fn concord_packet_channel_close(handle: u64);
}

/// Starts the Concord core, once per process. Returns 0 when it runs, -1 on
/// failure. Later calls only report whether it runs.
#[no_mangle]
pub extern "C" fn concord_ios_start() -> c_int {
    // SAFETY: `concord_start` takes no arguments and is safe to call.
    unsafe { concord_start() }
}

/// Opens a JSON-RPC session whose messages are handed to `deliver` with
/// `context`. Returns the session id (never 0), or 0 when the core is not up.
///
/// # Safety
/// `deliver` must be safe to call from any thread with `context` until
/// `release` has run; `release` may be null.
#[no_mangle]
pub unsafe extern "C" fn concord_ios_open_session(
    deliver: ConcordDeliver,
    context: *mut c_void,
    release: Option<ConcordRelease>,
) -> u64 {
    // SAFETY: forwarded from this function's contract.
    unsafe { concord_open_callback(deliver, context, release) }
}

/// Copies one complete JSON-RPC message onto a session. Returns 1 when the
/// session exists, 0 when it does not.
///
/// # Safety
/// `data` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn concord_ios_send(session: u64, data: *const u8, len: usize) -> c_int {
    // SAFETY: forwarded from this function's contract.
    unsafe { concord_send(session, data, len) }
}

/// Ends a session. Closing twice is harmless.
#[no_mangle]
pub extern "C" fn concord_ios_close_session(session: u64) {
    // SAFETY: `concord_close` takes only the session id.
    unsafe { concord_close(session) }
}

/// Adopts a host file descriptor (the real utun fd, recovered by scanning
/// the extension's fds for the utun control socket) into the core and
/// returns its handle (never 0), or 0 when the core is not up or the fd is
/// invalid. The handle is what `tun.start` names as
/// `{"kind": "inherited", "handle": …}` — MuYu's path: the core then does
/// native TUN I/O on the fd, no Swift packet pump.
///
/// # Safety
/// `fd` must be a valid open file descriptor owned by this process.
#[no_mangle]
pub unsafe extern "C" fn concord_ios_adopt_fd(fd: c_int) -> u64 {
    // SAFETY: forwarded from this function's contract.
    unsafe { concord_adopt_fd(fd) }
}

/// Creates a packet channel (Option B, patched tree only) and returns its
/// handle (never 0), or 0 when the core is not up. The handle is what
/// `tun.start` names as `{"kind": "channel", "handle": …}`.
#[no_mangle]
pub extern "C" fn concord_ios_packet_channel_open() -> u64 {
    // SAFETY: `concord_packet_channel_open` takes no arguments.
    unsafe { concord_packet_channel_open() }
}

/// Writes one IP packet (bare, no utun header) into the channel for the
/// stack to read. Returns 1 when queued, 0 when the ring is full (retry the
/// packet), -1 when the handle is unknown or the core is not up.
///
/// # Safety
/// `data` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn concord_ios_packet_write(
    handle: u64,
    data: *const u8,
    len: usize,
) -> c_int {
    // SAFETY: forwarded from this function's contract.
    unsafe { concord_packet_write(handle, data, len) }
}

/// Reads one packet the stack wrote, non-blocking, into `buf` (capacity
/// `cap`). Returns the byte count, 0 when no packet is waiting, -1 when the
/// handle is unknown, the core is not up, or `buf` is null. Poll from the
/// packetFlow pump loop.
///
/// # Safety
/// `buf` must point to `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn concord_ios_packet_read(handle: u64, buf: *mut u8, cap: usize) -> c_int {
    // SAFETY: forwarded from this function's contract.
    unsafe { concord_packet_read(handle, buf, cap) }
}

/// Drops a packet channel. A runner that already took the device is unaffected.
#[no_mangle]
pub extern "C" fn concord_ios_packet_channel_close(handle: u64) {
    // SAFETY: `concord_packet_channel_close` takes only the handle.
    unsafe { concord_packet_channel_close(handle) }
}
