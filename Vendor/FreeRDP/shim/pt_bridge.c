/*
 * The transport bridge (pt_bridge.h).
 *
 * Inbox: the app feeds what the network delivered; FreeRDP's Read copies it
 * out. The readable event is set by every feed and reset by a Read that
 * empties the ring, both under the lock, so a feed between the copy and the
 * reset cannot be lost. Read with nothing to read returns -1 with EAGAIN, or 0
 * (closed) once the network is done and the ring is empty.
 *
 * Outbox: FreeRDP's Write appends what fits and returns that count, or -1 with
 * EAGAIN when full; Wait(write) sleeps until there is room. The app takes the
 * bytes and sends them on.
 *
 * Every wait sleeps in slices of at most 100 ms and checks the abort flag
 * between them, so cancelling never waits on a network timeout.
 */
#include "pt_bridge.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include <winpr/handle.h>
#include <winpr/synch.h>

typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t head; /* first byte held */
    size_t length;
} pt_ring;

struct pt_bridge {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pt_ring in;
    pt_ring out;
    int in_closed; /* the network sends nothing more */
    int closed;    /* the bridge is over, both ways */
    int aborted;
    int in_was_full; /* the app was told the inbox had no room */
    HANDLE readable;
    pt_bridge_callbacks callbacks;
};

static int ring_init(pt_ring *ring, size_t capacity) {
    ring->bytes = calloc(1, capacity);
    ring->capacity = capacity;
    ring->head = 0;
    ring->length = 0;
    return ring->bytes != NULL;
}

static size_t ring_put(pt_ring *ring, const uint8_t *bytes, size_t length) {
    size_t room = ring->capacity - ring->length;
    size_t count = length < room ? length : room;
    size_t tail = (ring->head + ring->length) % ring->capacity;
    size_t first = ring->capacity - tail;
    if (first > count) first = count;
    memcpy(ring->bytes + tail, bytes, first);
    memcpy(ring->bytes, bytes + first, count - first);
    ring->length += count;
    return count;
}

static size_t ring_get(pt_ring *ring, uint8_t *buffer, size_t capacity) {
    size_t count = capacity < ring->length ? capacity : ring->length;
    size_t first = ring->capacity - ring->head;
    if (first > count) first = count;
    memcpy(buffer, ring->bytes + ring->head, first);
    memcpy(buffer + first, ring->bytes, count - first);
    ring->head = (ring->head + count) % ring->capacity;
    ring->length -= count;
    if (ring->length == 0) ring->head = 0;
    return count;
}

pt_bridge *pt_bridge_new(size_t inbox, size_t outbox, const pt_bridge_callbacks *callbacks) {
    pt_bridge *bridge = calloc(1, sizeof(pt_bridge));
    if (!bridge) return NULL;
    if (!ring_init(&bridge->in, inbox) || !ring_init(&bridge->out, outbox)) goto fail;
    bridge->readable = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!bridge->readable) goto fail;
    pthread_mutex_init(&bridge->lock, NULL);
    pthread_cond_init(&bridge->changed, NULL);
    if (callbacks) bridge->callbacks = *callbacks;
    return bridge;
fail:
    free(bridge->in.bytes);
    free(bridge->out.bytes);
    free(bridge);
    return NULL;
}

void pt_bridge_free(pt_bridge *bridge) {
    if (!bridge) return;
    CloseHandle(bridge->readable);
    pthread_cond_destroy(&bridge->changed);
    pthread_mutex_destroy(&bridge->lock);
    /* The rings held the session's bytes, the login's NTLM exchange among them. */
    memset(bridge->in.bytes, 0, bridge->in.capacity);
    memset(bridge->out.bytes, 0, bridge->out.capacity);
    free(bridge->in.bytes);
    free(bridge->out.bytes);
    free(bridge);
}

/* The app's side. */

size_t pt_bridge_feed(pt_bridge *bridge, const uint8_t *bytes, size_t length) {
    pthread_mutex_lock(&bridge->lock);
    size_t taken = 0;
    if (!bridge->closed && !bridge->in_closed) {
        taken = ring_put(&bridge->in, bytes, length);
        if (bridge->in.length > 0) SetEvent(bridge->readable);
        if (bridge->in.length == bridge->in.capacity) bridge->in_was_full = 1;
        pthread_cond_broadcast(&bridge->changed);
    }
    pthread_mutex_unlock(&bridge->lock);
    return taken;
}

size_t pt_bridge_inbox_free(pt_bridge *bridge) {
    pthread_mutex_lock(&bridge->lock);
    size_t room = bridge->closed ? 0 : bridge->in.capacity - bridge->in.length;
    if (room == 0) bridge->in_was_full = 1;
    pthread_mutex_unlock(&bridge->lock);
    return room;
}

void pt_bridge_feed_closed(pt_bridge *bridge) {
    pthread_mutex_lock(&bridge->lock);
    bridge->in_closed = 1;
    SetEvent(bridge->readable);
    pthread_cond_broadcast(&bridge->changed);
    pthread_mutex_unlock(&bridge->lock);
}

size_t pt_bridge_take(pt_bridge *bridge, uint8_t *buffer, size_t capacity) {
    pthread_mutex_lock(&bridge->lock);
    size_t count = ring_get(&bridge->out, buffer, capacity);
    if (count > 0) pthread_cond_broadcast(&bridge->changed);
    pthread_mutex_unlock(&bridge->lock);
    return count;
}

void pt_bridge_close(pt_bridge *bridge) {
    pthread_mutex_lock(&bridge->lock);
    bridge->closed = 1;
    bridge->in_closed = 1;
    SetEvent(bridge->readable);
    pthread_cond_broadcast(&bridge->changed);
    pthread_mutex_unlock(&bridge->lock);
}

void pt_bridge_abort(pt_bridge *bridge) {
    pthread_mutex_lock(&bridge->lock);
    bridge->aborted = 1;
    SetEvent(bridge->readable);
    pthread_cond_broadcast(&bridge->changed);
    pthread_mutex_unlock(&bridge->lock);
}

/* FreeRDP's side. */

int pt_bridge_read(pt_bridge *bridge, void *data, int bytes) {
    if (bytes <= 0) return 0;
    void (*space)(void *) = NULL;
    pthread_mutex_lock(&bridge->lock);
    size_t count = ring_get(&bridge->in, data, (size_t)bytes);
    int closed = bridge->in_closed || bridge->closed;
    if (bridge->in.length == 0 && !closed) ResetEvent(bridge->readable);
    if (count > 0 && bridge->in_was_full && bridge->in.length <= bridge->in.capacity / 2) {
        bridge->in_was_full = 0;
        space = bridge->callbacks.inbox_space;
    }
    pthread_mutex_unlock(&bridge->lock);
    if (space) space(bridge->callbacks.user);
    if (count > 0) return (int)count;
    if (closed) return 0;
    errno = EAGAIN;
    return -1;
}

int pt_bridge_write(pt_bridge *bridge, const void *data, int bytes) {
    if (bytes <= 0) return 0;
    void (*ready)(void *) = NULL;
    pthread_mutex_lock(&bridge->lock);
    if (bridge->closed) {
        pthread_mutex_unlock(&bridge->lock);
        errno = EPIPE;
        return -1;
    }
    int was_empty = bridge->out.length == 0;
    size_t count = ring_put(&bridge->out, data, (size_t)bytes);
    if (count > 0 && was_empty) ready = bridge->callbacks.outbox_ready;
    pthread_mutex_unlock(&bridge->lock);
    if (ready) ready(bridge->callbacks.user);
    if (count > 0) return (int)count;
    errno = EAGAIN;
    return -1;
}

static int ready_locked(const pt_bridge *bridge, BOOL write) {
    if (bridge->closed || bridge->aborted) return 1;
    if (write) return bridge->out.length < bridge->out.capacity;
    return bridge->in.length > 0 || bridge->in_closed;
}

BOOL pt_bridge_wait(pt_bridge *bridge, BOOL write, DWORD timeout_ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    /* INFINITE (0xFFFFFFFF) waits until ready, closed or aborted. */
    long long deadline_ms = timeout_ms == INFINITE ? LLONG_MAX
                                                   : (long long)now.tv_sec * 1000 + now.tv_usec / 1000 + timeout_ms;
    pthread_mutex_lock(&bridge->lock);
    int ready = ready_locked(bridge, write);
    while (!ready) {
        gettimeofday(&now, NULL);
        long long now_ms = (long long)now.tv_sec * 1000 + now.tv_usec / 1000;
        if (now_ms >= deadline_ms) break;
        long long slice = deadline_ms - now_ms;
        if (slice > 100) slice = 100;
        long long until = now_ms + slice;
        struct timespec at = { .tv_sec = (time_t)(until / 1000), .tv_nsec = (long)((until % 1000) * 1000000) };
        pthread_cond_timedwait(&bridge->changed, &bridge->lock, &at);
        ready = ready_locked(bridge, write);
    }
    pthread_mutex_unlock(&bridge->lock);
    return ready ? TRUE : FALSE;
}

HANDLE pt_bridge_event(pt_bridge *bridge) { return bridge->readable; }
