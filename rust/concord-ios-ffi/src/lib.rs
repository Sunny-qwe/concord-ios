// concord-ios-ffi — C FFI stubs ONLY.
// TODO: wire the real Concord API here once its iOS entry point is defined.
// Concord today exposes JSON-RPC 2.0 (schema/api.json) over a child process
// (desktop) or libconcord.so (Android). iOS extensions cannot spawn child
// processes, so the core must run in-process as a staticlib. There is
// currently no verified iOS FFI / staticlib entry point in Concord, and
// whether `tun.start` can accept an externally-provided packet flow
// (from NEPacketTunnelProvider) is unknown — read the Concord source first.
//
// These stubs exist only so the Xcode project / GitHub Actions can link
// something and the build pipeline can be smoke-tested. They do NOT proxy
// any traffic. Do not ship them as a working proxy.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

/// Initialise the Concord core in-process.
/// Returns 0 on success, non-zero on failure.
/// TODO: replace with the real Concord init (config home, log level, etc.).
#[no_mangle]
pub extern "C" fn concord_ios_init() -> c_int {
    // TODO: call real Concord core init.
    0
}

/// Start the engine with a Clash/mihomo YAML config file.
/// `config_path` is a null-terminated UTF-8 path, e.g. inside the App Group
/// shared container.
/// Returns 0 on success, non-zero on failure.
/// TODO: replace with real `config.apply` + `engine.start` wiring, and
/// confirm how `tun.start` should be driven from a Packet Tunnel.
#[no_mangle]
pub extern "C" fn concord_ios_start(config_path: *const c_char) -> c_int {
    if config_path.is_null() {
        return -1;
    }
    let _path = unsafe { CStr::from_ptr(config_path) };
    // TODO: load the YAML, apply it, start the engine.
    // TODO: do NOT create a TUN device here — iOS forbids it. Packets must
    // come from NEPacketTunnelProvider via the App Group / FFI callbacks.
    0
}

/// Stop the engine.
/// Returns 0 on success, non-zero on failure.
/// TODO: replace with real `engine.stop`.
#[no_mangle]
pub extern "C" fn concord_ios_stop() -> c_int {
    // TODO: stop the engine and release resources.
    0
}
