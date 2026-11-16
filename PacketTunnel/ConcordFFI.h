/* ConcordFFI.h — bridging header for the PacketTunnel target.
 *
 * Declares the Swift-friendly `concord_ios_*` wrappers from
 * rust/concord-ios-ffi (src/lib.rs), which forward to the real Concord C
 * ABI in libconcord_ios.a (upstream bins/ios + crates/ffi, patched tree;
 * see patches/README.md). The PacketTunnel target links BOTH
 * libconcord_ios.a and libconcord_ios_ffi.a (see project.pbxproj:
 * LIBRARY_SEARCH_PATHS / OTHER_LDFLAGS on the PacketTunnel target).
 * The app target does NOT link either library and never includes this
 * header — it talks to the extension via NEProviderManager /
 * sendProviderMessage, never to the core directly.
 *
 * Naming note: the wrappers are `concord_ios_packet_channel_open`,
 * `concord_ios_packet_write`, `concord_ios_packet_read` and
 * `concord_ios_packet_channel_close` — write/read have NO "channel"
 * infix (see rust/concord-ios-ffi/src/lib.rs). Do not "fix" the names
 * here; this header must match the Rust symbols exactly.
 *
 * The packet channel is Option B (patches/02-packet-channel.patch):
 * `concord_ios_packet_channel_open` returns the handle that `tun.start`
 * names as {"kind": "channel", "handle": ...}. Packets are bare IP
 * packets, no utun header. write returns 1 queued / 0 ring full /
 * -1 unknown handle; read is a non-blocking poll returning the byte
 * count, 0 when no packet is waiting, -1 on error.
 *
 * Header path (registered in project.pbxproj as the PacketTunnel
 * target's SWIFT_OBJC_BRIDGING_HEADER):
 *   PacketTunnel/ConcordFFI.h
 */

#ifndef CONCORD_FFI_H
#define CONCORD_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A JSON-RPC message delivered to Swift: `data`/`len` are one complete
 * message, valid only during the call. Return false once the host is
 * gone; that ends the session. Runs on a core thread. */
typedef bool (*ConcordIOSDeliver)(void *context, const uint8_t *data, size_t len);
/* Runs once when the core no longer holds the session (or right away when
 * the open fails because the core is not up). May be NULL. */
typedef void (*ConcordIOSRelease)(void *context);

/* Starts the Concord core, once per process. Returns 0 when it runs, -1
 * on failure. Later calls only report whether it runs. */
int32_t concord_ios_start(void);

/* Opens a JSON-RPC session whose messages are handed to `deliver` with
 * `context`. Returns the session id (never 0), or 0 when the core is not
 * up. */
uint64_t concord_ios_open_session(ConcordIOSDeliver deliver, void *context,
                                  ConcordIOSRelease release);

/* Copies one complete JSON-RPC message onto a session. Returns 1 when the
 * session exists, 0 when it does not. */
int32_t concord_ios_send(uint64_t session, const uint8_t *data, size_t len);

/* Ends a session. Closing twice is harmless. */
void concord_ios_close_session(uint64_t session);

/* Option A (socketpair bridge): hands a descriptor to the core, which
 * closes it. Returns the handle `tun.start` names as
 * {"kind": "inherited", "handle": ...}, or 0 when the core is not up.
 * Declared for completeness; the provider uses the Option B packet
 * channel instead (see below). */
uint64_t concord_ios_adopt_fd(int32_t fd);

/* Creates a packet channel (Option B, patched tree only) and returns its
 * handle (never 0), or 0 when the core is not up. */
uint64_t concord_ios_packet_channel_open(void);

/* Writes one IP packet (bare, no utun header) into the channel for the
 * stack to read. Returns 1 when queued, 0 when the ring is full (retry
 * the packet), -1 when the handle is unknown or the core is not up. */
int32_t concord_ios_packet_write(uint64_t handle, const uint8_t *data, size_t len);

/* Reads one packet the stack wrote, non-blocking, into `buf` (capacity
 * `cap`). Returns the byte count, 0 when no packet is waiting, -1 when
 * the handle is unknown, the core is not up, or `buf` is null. */
int32_t concord_ios_packet_read(uint64_t handle, uint8_t *buf, size_t cap);

/* Drops a packet channel. A runner that already took the device is
 * unaffected. */
void concord_ios_packet_channel_close(uint64_t handle);

#ifdef __cplusplus
}
#endif

#endif /* CONCORD_FFI_H */
