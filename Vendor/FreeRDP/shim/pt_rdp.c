/*
 * Passthrough's Remote Desktop session over FreeRDP (pt_rdp.h).
 *
 * Modelled on upstream's own iOS client (client/iOS/FreeRDP/ios_freerdp.m at
 * 3.33.1): a client context, PreConnect loading the compiled-in channels and
 * hooking the graphics pipeline when it opens, PostConnect starting the GDI in
 * BGRA32 with our pointer callbacks, and a loop of freerdp_get_event_handles,
 * wait, freerdp_check_event_handles.
 *
 * What is ours:
 *  - The transport: ConnectLayer hands FreeRDP a layer over pt_bridge (no
 *    socket; the hostname is never resolved).
 *  - NLA only, nothing weaker; the certificate is judged by the app alone
 *    (ExternalCertificateManagement), against the hash the host announced.
 *  - No gateway, proxy, multitransport, auto-reconnect, device redirection,
 *    RemoteApp or legacy codecs and caches.
 *  - Input is queued from any thread and sent from the engine thread, the
 *    only thread that calls FreeRDP. Pure pointer moves in a row are coalesced.
 *  - The desktop's shape: one monitor through display control, the newest
 *    request only, sent once Windows has said the channel's limits.
 */
#include "pt_rdp.h"
#include "pt_bridge.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/synch.h>
#include <winpr/handle.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/transport_io.h>

#include <openssl/crypto.h>

/* The protocol's large-pointer limit: bigger shapes are refused and the last one stays. */
#define PT_MAX_POINTER_SIDE 384
/* Past this many queued input commands the oldest pure moves go first. */
#define PT_MAX_COMMANDS 4096

typedef enum { PT_CMD_KEY, PT_CMD_UNICODE, PT_CMD_POINTER, PT_CMD_WHEEL, PT_CMD_SUPPRESS } pt_cmd_kind;

typedef struct {
    pt_cmd_kind kind;
    uint16_t a, b;   /* key: scancode, extended | unicode: unit | pointer, wheel: x, y */
    int16_t value;   /* key, unicode: down | pointer: buttons | wheel: rotation | suppress: on */
    uint8_t flag;    /* wheel: horizontal */
} pt_cmd;

struct pt_rdp {
    rdpContext *context;
    pt_rdp_callbacks callbacks;
    pt_bridge *bridge;
    HANDLE wake;

    pthread_mutex_t lock; /* the command queue and the wanted layout */
    pt_cmd *commands;
    size_t count;
    /* The newest shape asked for and not yet sent (width 0: none). */
    pt_rdp_layout_request wanted;

    /* Engine thread only. */
    uint8_t buttons;
    int signed_in;

    /* Display control, once its channel is open, and whether Windows has sent its limits (nothing may be sent
       before). Dynamic channels have a thread of their own (drdynvc's): it sets and clears these, the engine
       thread sends through them, both under disp_lock. */
    pthread_mutex_t disp_lock;
    DispClientContext *disp;
    int disp_ready;

    atomic_int aborted;
    atomic_int certificate_refused;
    atomic_int ran;
};

typedef struct {
    rdpClientContext common;
    pt_rdp *rdp;
} pt_context;

typedef struct {
    rdpPointer pointer;
    uint8_t *bgra; /* NULL: a shape this view doesn't take (too large) */
} pt_pointer;

static pt_rdp *rdp_of(rdpContext *context) { return context ? ((pt_context *)context)->rdp : NULL; }

static void wipe_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key) {
    const char *value = freerdp_settings_get_string(settings, key);
    if (value && *value) {
        /* settings_set_string frees the old copy; overwrite it first. */
        memset((char *)value, 0, strlen(value));
    }
    (void)freerdp_settings_set_string(settings, key, NULL);
}

/* MARK: Transport */

static int layer_read(void *user, void *data, int bytes) { return pt_bridge_read(*(pt_bridge **)user, data, bytes); }
static int layer_write(void *user, const void *data, int bytes) { return pt_bridge_write(*(pt_bridge **)user, data, bytes); }
static BOOL layer_close(void *user) {
    pt_bridge_close(*(pt_bridge **)user);
    return TRUE;
}
static BOOL layer_wait(void *user, BOOL write, DWORD timeout) { return pt_bridge_wait(*(pt_bridge **)user, write, timeout); }
static HANDLE layer_event(void *user) { return pt_bridge_event(*(pt_bridge **)user); }

/* In place of opening a socket: the bridge. The context of the layer holds only the bridge's pointer. */
static rdpTransportLayer *connect_layer(rdpTransport *transport, const char *hostname, int port, DWORD timeout) {
    (void)hostname;
    (void)port;
    (void)timeout;
    pt_rdp *rdp = rdp_of(transport_get_context(transport));
    if (!rdp) return NULL;
    rdpTransportLayer *layer = transport_layer_new(transport, sizeof(pt_bridge *));
    if (!layer) return NULL;
    *(pt_bridge **)layer->userContext = rdp->bridge;
    layer->Read = layer_read;
    layer->Write = layer_write;
    layer->Close = layer_close;
    layer->Wait = layer_wait;
    layer->GetEvent = layer_event;
    if (rdp->callbacks.phase) rdp->callbacks.phase(rdp->callbacks.user, PT_PHASE_NEGOTIATING);
    return layer;
}

static void bridge_outbox_ready(void *user) {
    pt_rdp *rdp = user;
    if (rdp->callbacks.outbox_ready) rdp->callbacks.outbox_ready(rdp->callbacks.user);
}

static void bridge_inbox_space(void *user) {
    pt_rdp *rdp = user;
    if (rdp->callbacks.inbox_space) rdp->callbacks.inbox_space(rdp->callbacks.user);
}

/* MARK: Certificate */

static int verify_certificate(freerdp *instance, const BYTE *data, size_t length, const char *hostname, UINT16 port,
                              DWORD flags) {
    (void)hostname;
    (void)port;
    (void)flags;
    pt_rdp *rdp = rdp_of(instance->context);
    if (!rdp || !rdp->callbacks.verify_certificate) return 0;
    if (rdp->callbacks.verify_certificate(rdp->callbacks.user, data, length) != 1) {
        atomic_store(&rdp->certificate_refused, 1);
        return 0;
    }
    if (rdp->callbacks.phase) rdp->callbacks.phase(rdp->callbacks.user, PT_PHASE_IDENTITY_CHECKED);
    /* 2: for this session only; nothing is stored. */
    return 2;
}

/* The login is in the settings; nothing is ever asked for. Missing credentials end the session. */
static BOOL authenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    (void)instance;
    (void)username;
    (void)password;
    (void)domain;
    (void)reason;
    return FALSE;
}

/* MARK: Pictures and the pointer */

static BOOL begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (hwnd->invalid) hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    pt_rdp *rdp = rdp_of(context);
    rdpGdi *gdi = context->gdi;
    if (!rdp || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (!hwnd->invalid || hwnd->invalid->null) return TRUE;
    pt_rect dirty = { hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w, hwnd->invalid->h };
    if (rdp->callbacks.painted && gdi->primary_buffer && gdi->width > 0 && gdi->height > 0) {
        rdp->callbacks.painted(rdp->callbacks.user, gdi->primary_buffer, gdi->stride, (uint32_t)gdi->width,
                               (uint32_t)gdi->height, dirty);
    }
    return TRUE;
}

static void announce_desktop(pt_rdp *rdp, rdpGdi *gdi) {
    if (rdp->callbacks.desktop && gdi && gdi->width > 0 && gdi->height > 0) {
        rdp->callbacks.desktop(rdp->callbacks.user, (uint32_t)gdi->width, (uint32_t)gdi->height);
    }
}

static BOOL desktop_resize(rdpContext *context) {
    pt_rdp *rdp = rdp_of(context);
    rdpSettings *settings = context->settings;
    if (!gdi_resize(context->gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                    freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight)))
        return FALSE;
    if (rdp) announce_desktop(rdp, context->gdi);
    return TRUE;
}

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    pt_pointer *ptr = (pt_pointer *)pointer;
    ptr->bgra = NULL;
    if (!context->gdi || pointer->width == 0 || pointer->height == 0) return TRUE;
    if (pointer->width > PT_MAX_POINTER_SIDE || pointer->height > PT_MAX_POINTER_SIDE) return TRUE;
    size_t size = 4u * pointer->width * pointer->height;
    uint8_t *bgra = calloc(1, size);
    if (!bgra) return FALSE;
    if (!freerdp_image_copy_from_pointer_data(bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height,
                                              pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
                                              pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette)) {
        free(bgra);
        return TRUE;
    }
    ptr->bgra = bgra;
    return TRUE;
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    pt_pointer *ptr = (pt_pointer *)pointer;
    free(ptr->bgra);
    ptr->bgra = NULL;
}

static BOOL pointer_set(rdpContext *context, rdpPointer *pointer) {
    pt_rdp *rdp = rdp_of(context);
    pt_pointer *ptr = (pt_pointer *)pointer;
    if (rdp && ptr->bgra && rdp->callbacks.pointer_shape) {
        rdp->callbacks.pointer_shape(rdp->callbacks.user, ptr->bgra, pointer->width, pointer->height, pointer->xPos,
                                     pointer->yPos);
    }
    return TRUE;
}

static BOOL pointer_set_null(rdpContext *context) {
    pt_rdp *rdp = rdp_of(context);
    if (rdp && rdp->callbacks.pointer_system) rdp->callbacks.pointer_system(rdp->callbacks.user, 0);
    return TRUE;
}

static BOOL pointer_set_default(rdpContext *context) {
    pt_rdp *rdp = rdp_of(context);
    if (rdp && rdp->callbacks.pointer_system) rdp->callbacks.pointer_system(rdp->callbacks.user, 1);
    return TRUE;
}

static BOOL pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    pt_rdp *rdp = rdp_of(context);
    if (rdp && rdp->callbacks.pointer_moved) rdp->callbacks.pointer_moved(rdp->callbacks.user, x, y);
    return TRUE;
}

/* MARK: Channels */

/* Windows said display control's limits: layouts may be sent from here on. */
static UINT disp_caps(DispClientContext *disp, UINT32 max_monitors, UINT32 area_a, UINT32 area_b) {
    (void)max_monitors;
    (void)area_a;
    (void)area_b;
    pt_rdp *rdp = disp ? disp->custom : NULL;
    if (!rdp) return CHANNEL_RC_OK;
    pthread_mutex_lock(&rdp->disp_lock);
    rdp->disp_ready = 1;
    pthread_mutex_unlock(&rdp->disp_lock);
    /* A shape asked for meanwhile goes with the next drain (the loop's next turn). */
    SetEvent(rdp->wake);
    return CHANNEL_RC_OK;
}

static void channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdpContext *ctx = context;
    if (!ctx || !e || !e->name) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0 && ctx->gdi) {
        (void)gdi_graphics_pipeline_init(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pt_rdp *rdp = rdp_of(ctx);
        DispClientContext *disp = (DispClientContext *)e->pInterface;
        if (!rdp || !disp) return;
        disp->custom = rdp;
        disp->DisplayControlCaps = disp_caps;
        pthread_mutex_lock(&rdp->disp_lock);
        rdp->disp = disp;
        rdp->disp_ready = 0;
        pthread_mutex_unlock(&rdp->disp_lock);
    }
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rdpContext *ctx = context;
    if (!ctx || !e || !e->name) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0 && ctx->gdi) {
        gdi_graphics_pipeline_uninit(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pt_rdp *rdp = rdp_of(ctx);
        if (!rdp) return;
        pthread_mutex_lock(&rdp->disp_lock);
        rdp->disp = NULL;
        rdp->disp_ready = 0;
        pthread_mutex_unlock(&rdp->disp_lock);
    }
}

/* MARK: Connection callbacks */

static BOOL pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    pt_rdp *rdp = rdp_of(context);
    if (!rdp) return FALSE;

    /* Our transport in place of a socket. */
    const rdpTransportIo *current = freerdp_get_io_callbacks(context);
    if (!current) return FALSE;
    rdpTransportIo io = *current;
    io.ConnectLayer = connect_layer;
    if (!freerdp_set_io_callbacks(context, &io)) return FALSE;

    if (PubSub_SubscribeChannelConnected(context->pubSub, channel_connected) != CHANNEL_RC_OK) return FALSE;
    if (PubSub_SubscribeChannelDisconnected(context->pubSub, channel_disconnected) != CHANNEL_RC_OK) return FALSE;
    /* Only what the settings ask for, and only from the compiled-in table (0001-no-dynamic-addins.patch). */
    return freerdp_client_load_addins(context->channels, context->settings);
}

static BOOL post_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    pt_rdp *rdp = rdp_of(context);
    if (!rdp) return FALSE;
    /* Windows has the login: FreeRDP's copy of the password is no longer needed. */
    wipe_string(context->settings, FreeRDP_Password);

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;

    rdpPointer pointer;
    memset(&pointer, 0, sizeof(pointer));
    pointer.size = sizeof(pt_pointer);
    pointer.New = pointer_new;
    pointer.Free = pointer_free;
    pointer.Set = pointer_set;
    pointer.SetNull = pointer_set_null;
    pointer.SetDefault = pointer_set_default;
    pointer.SetPosition = pointer_set_position;
    graphics_register_pointer(context->graphics, &pointer);

    context->update->BeginPaint = begin_paint;
    context->update->EndPaint = end_paint;
    context->update->DesktopResize = desktop_resize;

    rdp->signed_in = 1;
    if (rdp->callbacks.phase) rdp->callbacks.phase(rdp->callbacks.user, PT_PHASE_SIGNED_IN);
    announce_desktop(rdp, context->gdi);
    return TRUE;
}

static void post_disconnect(freerdp *instance) { gdi_free(instance); }

static BOOL client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->AuthenticateEx = authenticate;
    instance->VerifyX509Certificate = verify_certificate;
    instance->LogonErrorInfo = NULL;
    return TRUE;
}

static void client_free(freerdp *instance, rdpContext *context) {
    (void)instance;
    (void)context;
}

/* MARK: Settings */

#define SET_BOOL(key, value) \
    if (!freerdp_settings_set_bool(settings, FreeRDP_##key, (value) ? TRUE : FALSE)) return FALSE
#define SET_UINT32(key, value) \
    if (!freerdp_settings_set_uint32(settings, FreeRDP_##key, (UINT32)(value))) return FALSE
#define SET_STRING(key, value) \
    if (!freerdp_settings_set_string(settings, FreeRDP_##key, (value))) return FALSE

static BOOL configure(rdpSettings *settings, const pt_rdp_config *config) {
    /* NLA only, nothing weaker: the X.224 request offers CredSSP alone, and an answer selecting anything else ends it. */
    SET_BOOL(NlaSecurity, 1);
    SET_BOOL(TlsSecurity, 0);
    SET_BOOL(RdpSecurity, 0);
    SET_BOOL(ExtSecurity, 0);
    SET_BOOL(AadSecurity, 0);
    SET_BOOL(RdstlsSecurity, 0);
    SET_BOOL(NegotiateSecurityLayer, 1);
    SET_BOOL(UseRdpSecurityLayer, 0);
    SET_BOOL(RestrictedAdminModeRequired, 0);
    SET_BOOL(RemoteCredentialGuard, 0);
    SET_BOOL(SmartcardLogon, 0);

    /* The certificate is the app's to judge; nothing is stored, no trust on first use. */
    SET_BOOL(ExternalCertificateManagement, 1);
    SET_BOOL(CertificateCallbackPreferPEM, 1);
    SET_BOOL(IgnoreCertificate, 0);
    SET_BOOL(AutoAcceptCertificate, 0);
    SET_BOOL(AutoDenyCertificate, 1);
    /* Never created: FreeRDP has nowhere to write a known-hosts file. */
    SET_STRING(ConfigPath, "/var/empty/passthrough-rdp");

    /* No gateway, proxy or redirection of the connection; reconnects go through the host again. */
    SET_BOOL(GatewayEnabled, 0);
    SET_UINT32(ProxyType, PROXY_TYPE_NONE);
    SET_BOOL(SupportMultitransport, 0);
    SET_BOOL(NetworkAutoDetect, 0);
    /* With any of auto-detect, the heartbeat or multitransport on, freerdp_client_load_addins turns device
       redirection on and asks for rdpdr, which is not compiled in: PreConnect would fail before a byte is sent. */
    SET_BOOL(SupportHeartbeatPdu, 0);
    SET_BOOL(AutoReconnectionEnabled, 0);

    /* Graphics: the GFX pipeline; no RemoteFX, NSCodec or JPEG. */
    SET_BOOL(SupportGraphicsPipeline, 1);
    SET_BOOL(GfxH264, config->allow_h264);
    SET_BOOL(GfxAVC444, config->allow_h264);
    SET_BOOL(GfxAVC444v2, config->allow_h264);
    SET_BOOL(GfxProgressive, 1);
    SET_BOOL(GfxProgressiveV2, 1);
    SET_BOOL(GfxPlanar, 1);
    SET_BOOL(GfxSmallCache, 1);
    SET_UINT32(ColorDepth, 32);
    SET_BOOL(SoftwareGdi, 1);
    SET_BOOL(RemoteFxCodec, 0);
    SET_BOOL(NSCodec, 0);
    SET_BOOL(JpegCodec, 0);

    /* Legacy caches off. */
    SET_BOOL(BitmapCacheEnabled, 0);
    SET_BOOL(BitmapCacheV3Enabled, 0);
    SET_BOOL(BitmapCachePersistEnabled, 0);
    SET_UINT32(OffscreenSupportLevel, 0);
    SET_UINT32(GlyphSupportLevel, GLYPH_SUPPORT_NONE);

    /* Nothing of this device is redirected. */
    SET_BOOL(DeviceRedirection, 0);
    SET_BOOL(RedirectDrives, 0);
    SET_BOOL(RedirectHomeDrive, 0);
    SET_BOOL(RedirectPrinters, 0);
    SET_BOOL(RedirectSmartCards, 0);
    SET_BOOL(RedirectSerialPorts, 0);
    SET_BOOL(RedirectParallelPorts, 0);
    SET_BOOL(AudioPlayback, 0);
    SET_BOOL(AudioCapture, 0);
    SET_BOOL(RemoteApplicationMode, 0);
    SET_BOOL(SupportVideoOptimized, 0);
    /* The clipboard (text only) comes with copy and paste; off until then. */
    SET_BOOL(RedirectClipboard, 0);
    /* The desktop follows this device's shape through display control (disp over drdynvc, both compiled in):
       one monitor, never several. */
    SET_BOOL(SupportDisplayControl, 1);
    SET_BOOL(DynamicResolutionUpdate, 1);
    SET_BOOL(UseMultimon, 0);

    /* Shape. */
    SET_UINT32(DesktopWidth, config->width);
    SET_UINT32(DesktopHeight, config->height);
    SET_UINT32(DesktopScaleFactor, config->desktop_scale ? config->desktop_scale : 100);
    SET_UINT32(DeviceScaleFactor, config->device_scale ? config->device_scale : 100);

    /* Input: Unicode text; the PC's own keyboard layout. */
    SET_BOOL(UnicodeInput, 1);
    SET_BOOL(HasHorizontalWheel, 1);
    SET_BOOL(HasExtendedMouseEvent, 0);
    SET_UINT32(KeyboardLayout, 0);

    /* Session. The host name is never resolved: the transport is ours. */
    SET_BOOL(ConsoleSession, 0);
    SET_BOOL(AuthenticationOnly, 0);
    SET_STRING(ServerHostname, "passthrough-relay");
    SET_UINT32(ServerPort, 3389);
    SET_STRING(ClientHostname, config->client_name ? config->client_name : "Passthrough");
    SET_STRING(Username, config->username);
    SET_STRING(Domain, (config->domain && *config->domain) ? config->domain : NULL);
    SET_STRING(Password, config->password);
    SET_BOOL(AutoLogonEnabled, config->password && *config->password);
    return TRUE;
}

/* MARK: Lifetime */

pt_rdp *pt_rdp_new(const pt_rdp_config *config, const pt_rdp_callbacks *callbacks) {
    if (!config || !callbacks || !config->username || !config->password) return NULL;
    pt_rdp *rdp = calloc(1, sizeof(pt_rdp));
    if (!rdp) return NULL;
    rdp->callbacks = *callbacks;
    pthread_mutex_init(&rdp->lock, NULL);
    pthread_mutex_init(&rdp->disp_lock, NULL);
    rdp->commands = calloc(PT_MAX_COMMANDS, sizeof(pt_cmd));
    rdp->wake = CreateEventA(NULL, TRUE, FALSE, NULL);
    pt_bridge_callbacks bridge_callbacks = { .user = rdp, .outbox_ready = bridge_outbox_ready, .inbox_space = bridge_inbox_space };
    rdp->bridge = pt_bridge_new(PT_RDP_INBOX_BYTES, PT_RDP_OUTBOX_BYTES, &bridge_callbacks);
    if (!rdp->commands || !rdp->wake || !rdp->bridge) goto fail;

    RDP_CLIENT_ENTRY_POINTS entry;
    memset(&entry, 0, sizeof(entry));
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entry.ContextSize = sizeof(pt_context);
    entry.ClientNew = client_new;
    entry.ClientFree = client_free;
    rdp->context = freerdp_client_context_new(&entry);
    if (!rdp->context) goto fail;
    ((pt_context *)rdp->context)->rdp = rdp;
    if (!configure(rdp->context->settings, config)) goto fail;
    return rdp;
fail:
    pt_rdp_free(rdp);
    return NULL;
}

void pt_rdp_free(pt_rdp *rdp) {
    if (!rdp) return;
    if (rdp->context) {
        rdpSettings *settings = rdp->context->settings;
        if (settings) {
            wipe_string(settings, FreeRDP_Password);
            wipe_string(settings, FreeRDP_Username);
            wipe_string(settings, FreeRDP_Domain);
        }
        freerdp_client_context_free(rdp->context);
    }
    if (rdp->bridge) pt_bridge_free(rdp->bridge);
    if (rdp->wake) CloseHandle(rdp->wake);
    free(rdp->commands);
    pthread_mutex_destroy(&rdp->disp_lock);
    pthread_mutex_destroy(&rdp->lock);
    free(rdp);
}

/* MARK: Endings */

static pt_rdp_end_kind classify(pt_rdp *rdp, UINT32 last, UINT32 info) {
    if (atomic_load(&rdp->certificate_refused)) return PT_END_IDENTITY_MISMATCH;
    if (atomic_load(&rdp->aborted)) return PT_END_CLOSED_HERE;

    if (last == FREERDP_ERROR_CONNECT_WRONG_PASSWORD || last == FREERDP_ERROR_CONNECT_LOGON_FAILURE ||
        last == FREERDP_ERROR_AUTHENTICATION_FAILED)
        return PT_END_WRONG_PASSWORD;
    if (last == FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT) return PT_END_ACCOUNT_LOCKED;
    if (last == FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED || last == FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE ||
        last == FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED)
        return PT_END_PASSWORD_EXPIRED;
    if (last == FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED || last == FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION ||
        last == FREERDP_ERROR_CONNECT_ACCESS_DENIED || last == FREERDP_ERROR_INSUFFICIENT_PRIVILEGES ||
        last == FREERDP_ERROR_SERVER_INSUFFICIENT_PRIVILEGES || info == ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES)
        return PT_END_NOT_ALLOWED_REMOTELY;
    if (last == FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED || last == FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED)
        return PT_END_ACCOUNT_DISABLED;
    if (last == FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS) return PT_END_NO_CREDENTIALS;
    if (last == FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED || last == FREERDP_ERROR_CONNECT_NTLM_BLOCKED ||
        last == FREERDP_ERROR_TLS_CONNECT_FAILED)
        return PT_END_UNSUPPORTED;

    switch (info) {
        case ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION:
            return PT_END_TAKEN_OVER;
        case ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER:
        case ERRINFO_LOGOFF_BY_USER:
        case ERRINFO_RPC_INITIATED_LOGOFF:
            return PT_END_SIGNED_OUT;
        case ERRINFO_RPC_INITIATED_DISCONNECT:
        case ERRINFO_SERVER_DENIED_CONNECTION:
        case ERRINFO_IDLE_TIMEOUT:
        case ERRINFO_LOGON_TIMEOUT:
            return PT_END_HOST_ENDED;
        default:
            break;
    }
    if (info >= ERRINFO_LICENSE_INTERNAL && info <= 0x0000010A) return PT_END_NO_LICENCE;
    return PT_END_CONNECTION_LOST;
}

/* MARK: Input */

static void enqueue(pt_rdp *rdp, pt_cmd command) {
    if (atomic_load(&rdp->aborted)) return;
    pthread_mutex_lock(&rdp->lock);
    /* A pure move replaces a pure move just before it. */
    if (command.kind == PT_CMD_POINTER && rdp->count > 0) {
        pt_cmd *last = &rdp->commands[rdp->count - 1];
        if (last->kind == PT_CMD_POINTER && last->value == command.value) {
            *last = command;
            pthread_mutex_unlock(&rdp->lock);
            SetEvent(rdp->wake);
            return;
        }
    }
    if (rdp->count == PT_MAX_COMMANDS) {
        /* Full: the oldest pure move goes; with none, the newest command is dropped. */
        size_t i = 0;
        for (; i + 1 < rdp->count; i++) {
            if (rdp->commands[i].kind == PT_CMD_POINTER && rdp->commands[i + 1].kind == PT_CMD_POINTER &&
                rdp->commands[i].value == rdp->commands[i + 1].value)
                break;
        }
        if (i + 1 >= rdp->count) {
            pthread_mutex_unlock(&rdp->lock);
            return;
        }
        memmove(&rdp->commands[i], &rdp->commands[i + 1], (rdp->count - i - 1) * sizeof(pt_cmd));
        rdp->count--;
    }
    rdp->commands[rdp->count++] = command;
    pthread_mutex_unlock(&rdp->lock);
    SetEvent(rdp->wake);
}

static void send_pointer(pt_rdp *rdp, rdpInput *input, uint16_t x, uint16_t y, uint8_t buttons) {
    (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
    static const struct { uint8_t bit; uint16_t flag; } map[] = {
        { 1, PTR_FLAGS_BUTTON1 }, { 4, PTR_FLAGS_BUTTON2 }, { 2, PTR_FLAGS_BUTTON3 },
    };
    for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        uint8_t was = rdp->buttons & map[i].bit, now = buttons & map[i].bit;
        if (was == now) continue;
        (void)freerdp_input_send_mouse_event(input, (UINT16)(map[i].flag | (now ? PTR_FLAGS_DOWN : 0)), x, y);
    }
    rdp->buttons = buttons;
}

/* The newest shape asked for, once display control is ready: one monitor, primary, at the origin. */
static void send_layout(pt_rdp *rdp) {
    if (!rdp->signed_in) return;
    pthread_mutex_lock(&rdp->disp_lock);
    if (!rdp->disp || !rdp->disp_ready) {
        pthread_mutex_unlock(&rdp->disp_lock);
        return;
    }
    pthread_mutex_lock(&rdp->lock);
    pt_rdp_layout_request wanted = rdp->wanted;
    rdp->wanted.width = 0;
    pthread_mutex_unlock(&rdp->lock);
    if (wanted.width == 0 || wanted.height == 0) {
        pthread_mutex_unlock(&rdp->disp_lock);
        return;
    }
    DISPLAY_CONTROL_MONITOR_LAYOUT monitor;
    memset(&monitor, 0, sizeof(monitor));
    monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    monitor.Width = wanted.width;
    monitor.Height = wanted.height;
    monitor.DesktopScaleFactor = wanted.desktop_scale ? wanted.desktop_scale : 100;
    monitor.DeviceScaleFactor = wanted.device_scale ? wanted.device_scale : 100;
    if (rdp->disp->SendMonitorLayout) (void)rdp->disp->SendMonitorLayout(rdp->disp, 1, &monitor);
    pthread_mutex_unlock(&rdp->disp_lock);
}

static void drain(pt_rdp *rdp) {
    pt_cmd batch[256];
    rdpContext *context = rdp->context;
    rdpInput *input = context->input;
    send_layout(rdp);
    for (;;) {
        pthread_mutex_lock(&rdp->lock);
        size_t n = rdp->count < 256 ? rdp->count : 256;
        memcpy(batch, rdp->commands, n * sizeof(pt_cmd));
        memmove(rdp->commands, rdp->commands + n, (rdp->count - n) * sizeof(pt_cmd));
        rdp->count -= n;
        if (rdp->count == 0) ResetEvent(rdp->wake);
        pthread_mutex_unlock(&rdp->lock);
        if (n == 0) return;
        /* Input before the session is up would be refused: dropped. */
        if (!rdp->signed_in || !input) continue;
        for (size_t i = 0; i < n; i++) {
            pt_cmd c = batch[i];
            switch (c.kind) {
                case PT_CMD_KEY:
                    /* A press carries no flag (KBD_FLAGS_DOWN means "was already down": a repeat). */
                    (void)freerdp_input_send_keyboard_event(
                        input, (UINT16)((c.value ? 0 : KBD_FLAGS_RELEASE) | (c.b ? KBD_FLAGS_EXTENDED : 0)), (UINT8)c.a);
                    break;
                case PT_CMD_UNICODE:
                    (void)freerdp_input_send_unicode_keyboard_event(input, (UINT16)(c.value ? 0 : KBD_FLAGS_RELEASE), c.a);
                    break;
                case PT_CMD_POINTER:
                    send_pointer(rdp, input, c.a, c.b, (uint8_t)c.value);
                    break;
                case PT_CMD_WHEEL: {
                    UINT16 flags = c.flag ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
                    /* A 9-bit two's complement rotation: its sign bit is PTR_FLAGS_WHEEL_NEGATIVE. */
                    flags |= (UINT16)((uint16_t)c.value & WheelRotationMask);
                    (void)freerdp_input_send_mouse_event(input, flags, c.a, c.b);
                    break;
                }
                case PT_CMD_SUPPRESS:
                    (void)gdi_send_suppress_output(context->gdi, c.value ? TRUE : FALSE);
                    break;
            }
        }
    }
}

void pt_rdp_key(pt_rdp *rdp, uint8_t scancode, int extended, int down) {
    enqueue(rdp, (pt_cmd){ .kind = PT_CMD_KEY, .a = scancode, .b = extended ? 1 : 0, .value = down ? 1 : 0 });
}

void pt_rdp_unicode(pt_rdp *rdp, uint16_t unit, int down) {
    enqueue(rdp, (pt_cmd){ .kind = PT_CMD_UNICODE, .a = unit, .value = down ? 1 : 0 });
}

void pt_rdp_pointer(pt_rdp *rdp, uint16_t x, uint16_t y, uint8_t buttons) {
    enqueue(rdp, (pt_cmd){ .kind = PT_CMD_POINTER, .a = x, .b = y, .value = (int16_t)(buttons & 7) });
}

void pt_rdp_wheel(pt_rdp *rdp, uint16_t x, uint16_t y, int16_t rotation, int horizontal) {
    if (rotation > 255) rotation = 255;
    if (rotation < -255) rotation = -255;
    if (rotation == 0) return;
    enqueue(rdp, (pt_cmd){ .kind = PT_CMD_WHEEL, .a = x, .b = y, .value = rotation, .flag = horizontal ? 1 : 0 });
}

void pt_rdp_suppress_output(pt_rdp *rdp, int suppress) {
    enqueue(rdp, (pt_cmd){ .kind = PT_CMD_SUPPRESS, .value = suppress ? 1 : 0 });
}

void pt_rdp_layout(pt_rdp *rdp, const pt_rdp_layout_request *request) {
    if (!rdp || !request || atomic_load(&rdp->aborted)) return;
    pthread_mutex_lock(&rdp->lock);
    rdp->wanted = *request;
    pthread_mutex_unlock(&rdp->lock);
    SetEvent(rdp->wake);
}

/* MARK: Running */

pt_rdp_end pt_rdp_run(pt_rdp *rdp) {
    pt_rdp_end end = { PT_END_PROTOCOL_ERROR, 0, 0 };
    if (!rdp || atomic_exchange(&rdp->ran, 1)) return end;
    rdpContext *context = rdp->context;
    freerdp *instance = context->instance;

    if (atomic_load(&rdp->aborted) || !freerdp_connect(instance)) goto done;

    while (!freerdp_shall_disconnect_context(context) && !atomic_load(&rdp->aborted)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        memset(handles, 0, sizeof(handles));
        DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS - 1);
        if (count == 0) break;
        handles[count++] = rdp->wake;
        DWORD status = WaitForMultipleObjects(count, handles, FALSE, 250);
        if (status == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(context)) break;
        drain(rdp);
    }

done:
    end.last_error = freerdp_get_last_error(context);
    end.error_info = freerdp_error_info(instance);
    end.kind = classify(rdp, end.last_error, end.error_info);
    (void)freerdp_disconnect(instance);
    pt_bridge_close(rdp->bridge);
    return end;
}

void pt_rdp_abort(pt_rdp *rdp) {
    if (!rdp) return;
    atomic_store(&rdp->aborted, 1);
    if (rdp->context) (void)freerdp_abort_connect_context(rdp->context);
    pt_bridge_abort(rdp->bridge);
    pt_bridge_close(rdp->bridge);
    SetEvent(rdp->wake);
}

/* MARK: The app's side of the bridge */

size_t pt_rdp_feed(pt_rdp *rdp, const uint8_t *bytes, size_t length) { return pt_bridge_feed(rdp->bridge, bytes, length); }
size_t pt_rdp_inbox_free(pt_rdp *rdp) { return pt_bridge_inbox_free(rdp->bridge); }
void pt_rdp_feed_closed(pt_rdp *rdp) { pt_bridge_feed_closed(rdp->bridge); }
size_t pt_rdp_take(pt_rdp *rdp, uint8_t *buffer, size_t capacity) { return pt_bridge_take(rdp->bridge, buffer, capacity); }

/* MARK: Versions */

const char *pt_rdp_freerdp_version(void) { return freerdp_get_version_string(); }
const char *pt_rdp_openssl_version(void) { return OpenSSL_version(OPENSSL_VERSION); }

int pt_rdp_has_videotoolbox(void) {
#if defined(PT_HAS_VIDEOTOOLBOX)
    return 1;
#else
    return 0;
#endif
}
