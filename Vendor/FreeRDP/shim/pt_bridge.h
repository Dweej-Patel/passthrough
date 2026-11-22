/*
 * The transport bridge: two byte rings between the app's stream and
 * FreeRDP's transport layer, guarded by one mutex, with a WinPR event that is
 * set exactly while the inbox has bytes to read (or is closed), which is the
 * handle FreeRDP waits on. Internal to the shim.
 */
#ifndef PT_BRIDGE_H
#define PT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#include <winpr/wtypes.h>

typedef struct pt_bridge pt_bridge;

typedef struct {
    void *user;
    /** The outbox went from empty to not empty. Called without the lock held. */
    void (*outbox_ready)(void *user);
    /** The inbox was full and has room again. Called without the lock held. */
    void (*inbox_space)(void *user);
} pt_bridge_callbacks;

pt_bridge *pt_bridge_new(size_t inbox, size_t outbox, const pt_bridge_callbacks *callbacks);
void pt_bridge_free(pt_bridge *bridge);

/* The app's side, any thread. */
size_t pt_bridge_feed(pt_bridge *bridge, const uint8_t *bytes, size_t length);
size_t pt_bridge_inbox_free(pt_bridge *bridge);
void pt_bridge_feed_closed(pt_bridge *bridge);
size_t pt_bridge_take(pt_bridge *bridge, uint8_t *buffer, size_t capacity);
/** Both directions end: reads return closed once the inbox is empty, writes fail, waits return. */
void pt_bridge_close(pt_bridge *bridge);
/** Waits return at once from now on, whatever they wait for. */
void pt_bridge_abort(pt_bridge *bridge);

/* FreeRDP's side (rdpTransportLayer), the engine thread. */
int pt_bridge_read(pt_bridge *bridge, void *data, int bytes);
int pt_bridge_write(pt_bridge *bridge, const void *data, int bytes);
BOOL pt_bridge_wait(pt_bridge *bridge, BOOL write, DWORD timeout_ms);
HANDLE pt_bridge_event(pt_bridge *bridge);

#endif
