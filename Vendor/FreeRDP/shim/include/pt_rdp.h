/*
 * Passthrough's shim over FreeRDP: the only code that includes FreeRDP's
 * headers. Swift sees this header and nothing else (the xcframework's module
 * "FreeRDP" exports only it), so no FreeRDP type, macro or setting reaches
 * the app.
 *
 * One session per pt_rdp. Its bytes never touch a socket: FreeRDP's
 * transport layer is two byte queues in this process (pt_bridge.c), filled
 * and drained by the app from the stream its own connection handed over
 * after `rdpReady`.
 *
 * Threads: pt_rdp_run makes every FreeRDP call, on the thread that calls it
 * (the engine thread); every callback below runs there. Functions marked
 * "any thread" may be called from anywhere, at any time before pt_rdp_free.
 */
#ifndef PT_RDP_H
#define PT_RDP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pt_rdp pt_rdp;

typedef struct {
    int32_t x, y, w, h;
} pt_rect;

/** How far the connection has got (`phase` callback). */
enum {
    /** The first request is about to go out. */
    PT_PHASE_NEGOTIATING = 1,
    /** The certificate was the one the host announced. */
    PT_PHASE_IDENTITY_CHECKED = 2,
    /** Windows accepted the login and the connection sequence is done. */
    PT_PHASE_SIGNED_IN = 3,
};

/** Why a session ended, as Passthrough tells it (FreeRDP's codes are classified in the shim). */
typedef enum {
    PT_END_CLOSED_HERE = 0,
    PT_END_CONNECTION_LOST = 1,
    PT_END_IDENTITY_MISMATCH = 2,
    PT_END_WRONG_PASSWORD = 3,
    PT_END_PASSWORD_EXPIRED = 4,
    PT_END_ACCOUNT_LOCKED = 5,
    PT_END_ACCOUNT_DISABLED = 6,
    PT_END_NOT_ALLOWED_REMOTELY = 7,
    PT_END_NO_CREDENTIALS = 8,
    PT_END_UNSUPPORTED = 9,
    PT_END_TAKEN_OVER = 10,
    PT_END_SIGNED_OUT = 11,
    PT_END_HOST_ENDED = 12,
    PT_END_NO_LICENCE = 13,
    PT_END_PROTOCOL_ERROR = 14,
} pt_rdp_end_kind;

typedef struct {
    pt_rdp_end_kind kind;
    /** freerdp_get_last_error and freerdp_error_info, for the log. */
    uint32_t last_error;
    uint32_t error_info;
} pt_rdp_end;

typedef struct {
    /** Copied; the shim's copies are zeroed once Windows has the login, and in pt_rdp_free. */
    const char *username;
    /** NULL or empty: none. */
    const char *domain;
    const char *password;
    /** "iPhone", "iPad", "Mac": never the device's own name. */
    const char *client_name;
    /** The first desktop size, in pixels (even, 200 to 8192). */
    uint32_t width, height;
    /** Windows' scale factors: desktop 100 to 500, device 100, 140 or 180. */
    uint32_t desktop_scale, device_scale;
    /** 0: no H.264 (the fallback when it is slower than the progressive codec). */
    int allow_h264;
} pt_rdp_config;

typedef struct {
    void *user;
    /** The server's certificate chain, PEM, leaf first. Return 1 to accept, 0 to refuse (the session ends; nothing of the login has been sent). */
    int (*verify_certificate)(void *user, const uint8_t *pem, size_t length);
    void (*phase)(void *user, int phase);
    /** The desktop is now width x height (first, and after every resize). */
    void (*desktop)(void *user, uint32_t width, uint32_t height);
    /** `dirty` changed in the desktop's BGRA pixels (`stride` bytes a row); valid only during the call. */
    void (*painted)(void *user, const uint8_t *bgra, uint32_t stride, uint32_t width, uint32_t height, pt_rect dirty);
    /** The pointer's look: BGRA with straight (not premultiplied) alpha, width x height, its tip at (hot_x, hot_y). Valid only during the call. */
    void (*pointer_shape)(void *user, const uint8_t *bgra, uint32_t width, uint32_t height, uint32_t hot_x, uint32_t hot_y);
    /** 0: hidden; 1: the system's own arrow (no shape follows). */
    void (*pointer_system)(void *user, int visible);
    void (*pointer_moved)(void *user, uint32_t x, uint32_t y);
    /** The outbox has bytes again: take them (pt_rdp_take) from the app's own queue. */
    void (*outbox_ready)(void *user);
    /** The inbox has room again after it was full: feed more. */
    void (*inbox_space)(void *user);
} pt_rdp_callbacks;

/** The inbox's size: never more than this is held from the network. */
#define PT_RDP_INBOX_BYTES (4u << 20)
#define PT_RDP_OUTBOX_BYTES (1u << 20)

/** NULL if FreeRDP could not be set up. Callbacks are copied. */
pt_rdp *pt_rdp_new(const pt_rdp_config *config, const pt_rdp_callbacks *callbacks);
/** Connects, runs until the session ends, disconnects. Blocks; the engine thread. */
pt_rdp_end pt_rdp_run(pt_rdp *rdp);
/** After pt_rdp_run returned (or if it never ran). Zeroes the login. */
void pt_rdp_free(pt_rdp *rdp);

/* Any thread. */

/** Ends pt_rdp_run soon (within a wait slice, 250 ms at most). */
void pt_rdp_abort(pt_rdp *rdp);
/** Bytes from the network. Returns how many were taken: never more than pt_rdp_inbox_free said. */
size_t pt_rdp_feed(pt_rdp *rdp, const uint8_t *bytes, size_t length);
size_t pt_rdp_inbox_free(pt_rdp *rdp);
/** The network will send nothing more. */
void pt_rdp_feed_closed(pt_rdp *rdp);
/** Bytes for the network, at most `capacity`; 0 when there are none. */
size_t pt_rdp_take(pt_rdp *rdp, uint8_t *buffer, size_t capacity);

/* Input, any thread: queued and sent by the engine thread. Points are desktop pixels. */

/** A key by scan code (set 1), `extended` for the E0 keys. */
void pt_rdp_key(pt_rdp *rdp, uint8_t scancode, int extended, int down);
/** One UTF-16 unit as a Unicode key event. */
void pt_rdp_unicode(pt_rdp *rdp, uint16_t unit, int down);
/** The pointer at (x, y) with `buttons` held (1 left, 2 middle, 4 right). Moves in a row are coalesced. */
void pt_rdp_pointer(pt_rdp *rdp, uint16_t x, uint16_t y, uint8_t buttons);
/** Wheel rotation at (x, y): -255...255 a call, positive away from the user; `horizontal` for the tilt wheel. */
void pt_rdp_wheel(pt_rdp *rdp, uint16_t x, uint16_t y, int16_t rotation, int horizontal);
/** Stops (1) or restarts (0) the pictures, as when the app is in the background. */
void pt_rdp_suppress_output(pt_rdp *rdp, int suppress);

/** FreeRDP's and OpenSSL's versions, and whether VideoToolbox H.264 is compiled in. */
const char *pt_rdp_freerdp_version(void);
const char *pt_rdp_openssl_version(void);
int pt_rdp_has_videotoolbox(void);

#ifdef __cplusplus
}
#endif

#endif
