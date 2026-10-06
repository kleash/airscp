// AirSCP's RDP session over FreeRDP: connecting (certificate and credential questions), the event loop on the
// session's own thread, the frame buffer, the mouse pointer, keyboard and mouse input, desktop resizing, and the
// shared folder. The clipboard is in rdp_clipboard.c.

#include "rdp_internal.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/channels.h>
#include <freerdp/channels/rdpdr.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/codec/color.h>
#include <freerdp/constants.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/locale/keyboard.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>

static rdp_session *session_of(rdpContext *context) {
    return ((shim_context *)context)->session;
}

void rdp_emit(rdp_session *s, const rdp_event *event) {
    s->handler(s->handler_context, event);
}

static void emit_rect(rdp_session *s, rdp_event_type type, int32_t x, int32_t y, int32_t width, int32_t height) {
    rdp_event event = { .type = type, .x = x, .y = y, .width = width, .height = height };
    rdp_emit(s, &event);
}

// MARK: Questions (the session's thread waits for the answer)

/// Asks with `event` and waits for rdp_session_answer_*; false when the session is stopping instead.
static bool ask(rdp_session *s, const rdp_event *event) {
    pthread_mutex_lock(&s->lock);
    if (s->stopping) {
        pthread_mutex_unlock(&s->lock);
        return false;
    }
    s->asking = true;
    pthread_mutex_unlock(&s->lock);
    rdp_emit(s, event);
    pthread_mutex_lock(&s->lock);
    while (s->asking && !s->stopping)
        pthread_cond_wait(&s->answered, &s->lock);
    s->asking = false;
    bool answered = !s->stopping;
    pthread_mutex_unlock(&s->lock);
    return answered;
}

static DWORD ask_certificate(rdp_session *s, const char *host, UINT16 port, const char *subject, const char *issuer,
                             const char *fingerprint, const char *old_fingerprint, DWORD flags) {
    char where[512];
    snprintf(where, sizeof where, "%s:%u", host ? host : "", (unsigned)port);
    rdp_event event = {
        .type = RDP_EVENT_CERTIFICATE, .code = flags, .text = where, .subject = subject ? subject : "",
        .issuer = issuer ? issuer : "", .fingerprint = fingerprint ? fingerprint : "", .old_fingerprint = old_fingerprint,
    };
    s->certificate_answer = 0;
    if (!ask(s, &event))
        return 0;
    return (DWORD)s->certificate_answer;
}

static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    (void)common_name;
    return ask_certificate(session_of(instance->context), host, port, subject, issuer, fingerprint, NULL, flags);
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                        const char *subject, const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer, const char *old_fingerprint,
                                        DWORD flags) {
    (void)common_name;
    (void)old_subject;
    (void)old_issuer;
    return ask_certificate(session_of(instance->context), host, port, subject, issuer, fingerprint,
                           old_fingerprint ? old_fingerprint : "", flags);
}

static void replace(char **field, char *value) {
    free(*field);
    *field = value;
}

static BOOL authenticate(freerdp *instance, char **username, char **password, char **domain,
                         rdp_auth_reason reason) {
    rdp_session *s = session_of(instance->context);
    switch (reason) {
    case AUTH_NLA:
        break;
    case AUTH_TLS:
    case AUTH_RDP:
        if (*username && *password)
            return TRUE;
        break;
    default:
        return FALSE;  // smart cards and gateways aren't supported
    }
    pthread_mutex_lock(&s->lock);
    s->credentials_given = false;
    replace(&s->answer_username, NULL);
    replace(&s->answer_domain, NULL);
    replace(&s->answer_password, NULL);
    pthread_mutex_unlock(&s->lock);
    rdp_event event = { .type = RDP_EVENT_CREDENTIALS, .text = *username ? *username : "" };
    if (!ask(s, &event) || !s->credentials_given)
        return FALSE;
    pthread_mutex_lock(&s->lock);
    replace(username, s->answer_username);
    replace(domain, s->answer_domain);
    replace(password, s->answer_password);
    s->answer_username = s->answer_domain = s->answer_password = NULL;
    pthread_mutex_unlock(&s->lock);
    return TRUE;
}

void rdp_session_answer_certificate(rdp_session *s, int answer) {
    pthread_mutex_lock(&s->lock);
    if (s->asking) {
        s->certificate_answer = answer;
        s->asking = false;
        pthread_cond_broadcast(&s->answered);
    }
    pthread_mutex_unlock(&s->lock);
}

void rdp_session_answer_credentials(rdp_session *s, const char *username, const char *domain, const char *password) {
    pthread_mutex_lock(&s->lock);
    if (s->asking) {
        s->credentials_given = username != NULL;
        if (username) {
            replace(&s->answer_username, strdup(username));
            replace(&s->answer_domain, domain && domain[0] ? strdup(domain) : NULL);
            replace(&s->answer_password, strdup(password ? password : ""));
        }
        s->asking = false;
        pthread_cond_broadcast(&s->answered);
    }
    pthread_mutex_unlock(&s->lock);
}

static int logon_error_info(freerdp *instance, UINT32 data, UINT32 type) {
    (void)instance;
    (void)data;
    (void)type;
    return 1;
}

// MARK: Frame buffer and pointer

static BOOL end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;
    HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
    if (!invalid || invalid->null)
        return TRUE;
    emit_rect(session_of(context), RDP_EVENT_PAINT, invalid->x, invalid->y, invalid->w, invalid->h);
    invalid->null = TRUE;
    gdi->primary->hdc->hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    rdp_session *s = session_of(context);
    if (!context->gdi)
        return TRUE;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    pthread_mutex_lock(&s->frame_lock);
    const BOOL resized = gdi_resize(context->gdi, width, height);
    pthread_mutex_unlock(&s->frame_lock);
    if (resized)
        emit_rect(s, RDP_EVENT_RESIZED, 0, 0, (int32_t)width, (int32_t)height);
    return resized;
}

const uint8_t *rdp_session_lock_frame(rdp_session *s, int32_t *width, int32_t *height, int32_t *stride) {
    pthread_mutex_lock(&s->frame_lock);
    rdpGdi *gdi = s->context->gdi;
    if (!gdi || !gdi->primary_buffer)
        return NULL;
    *width = gdi->width;
    *height = gdi->height;
    *stride = (int32_t)gdi->stride;
    return gdi->primary_buffer;
}

void rdp_session_unlock_frame(rdp_session *s) {
    pthread_mutex_unlock(&s->frame_lock);
}

typedef struct {
    rdpPointer pointer;
    BYTE *image;  // BGRA
} shim_pointer;

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    shim_pointer *p = (shim_pointer *)pointer;
    const size_t size = (size_t)pointer->width * pointer->height * 4;
    p->image = calloc(1, size ? size : 1);
    if (!p->image)
        return FALSE;
    if (size && !freerdp_image_copy_from_pointer_data(p->image, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width,
                                                      pointer->height, pointer->xorMaskData, pointer->lengthXorMask,
                                                      pointer->andMaskData, pointer->lengthAndMask,
                                                      pointer->xorBpp, NULL)) {
        free(p->image);
        p->image = NULL;
        return FALSE;
    }
    return TRUE;
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    shim_pointer *p = (shim_pointer *)pointer;
    free(p->image);
    p->image = NULL;
}

static BOOL pointer_set(rdpContext *context, rdpPointer *pointer) {
    shim_pointer *p = (shim_pointer *)pointer;
    if (!p->image)
        return TRUE;
    rdp_event event = {
        .type = RDP_EVENT_POINTER, .x = (int32_t)pointer->xPos, .y = (int32_t)pointer->yPos,
        .width = (int32_t)pointer->width, .height = (int32_t)pointer->height, .data = p->image,
    };
    rdp_emit(session_of(context), &event);
    return TRUE;
}

static BOOL pointer_set_null(rdpContext *context) {
    rdp_event event = { .type = RDP_EVENT_POINTER };
    rdp_emit(session_of(context), &event);
    return TRUE;
}

static BOOL pointer_set_default(rdpContext *context) {
    rdp_event event = { .type = RDP_EVENT_POINTER, .code = 1 };
    rdp_emit(session_of(context), &event);
    return TRUE;
}

static BOOL pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    (void)context;
    (void)x;
    (void)y;
    return TRUE;
}

// MARK: Display control

/// Sends the size asked for once the server is ready for it. Called with `lock` held.
static void send_layout(rdp_session *s) {
    if (!s->disp || !s->disp_ready || !s->disp_pending)
        return;
    s->disp_pending = false;
    if (s->disp->SendMonitorLayout(s->disp, 1, &s->disp_layout) != CHANNEL_RC_OK)
        WLog_WARN("com.kleash.airscp.rdp", "SendMonitorLayout failed");
}

static UINT display_control_caps(DispClientContext *disp, UINT32 max_monitors, UINT32 factor_a, UINT32 factor_b) {
    (void)max_monitors;
    (void)factor_a;
    (void)factor_b;
    rdp_session *s = disp->custom;
    pthread_mutex_lock(&s->lock);
    s->disp_ready = true;
    send_layout(s);
    pthread_mutex_unlock(&s->lock);
    return CHANNEL_RC_OK;
}

static uint32_t clamp(uint32_t value, uint32_t low, uint32_t high) {
    return value < low ? low : value > high ? high : value;
}

void rdp_session_resize(rdp_session *s, uint32_t width, uint32_t height, uint32_t desktop_scale,
                        uint32_t device_scale) {
    // [MS-RDPEDISP] 2.2.2.2.1: 200 to 8192 pixels, and an even width.
    width = clamp(width, DISPLAY_CONTROL_MIN_MONITOR_WIDTH, DISPLAY_CONTROL_MAX_MONITOR_WIDTH) & ~1u;
    height = clamp(height, DISPLAY_CONTROL_MIN_MONITOR_HEIGHT, DISPLAY_CONTROL_MAX_MONITOR_HEIGHT);
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = {
        .Flags = DISPLAY_CONTROL_MONITOR_PRIMARY, .Width = width, .Height = height,
        .PhysicalWidth = clamp((uint32_t)(width / 75.0 * 25.4), 10, 10000),
        .PhysicalHeight = clamp((uint32_t)(height / 75.0 * 25.4), 10, 10000),
        .DesktopScaleFactor = clamp(desktop_scale, 100, 500), .DeviceScaleFactor = device_scale,
    };
    pthread_mutex_lock(&s->lock);
    s->disp_layout = layout;
    s->disp_pending = true;
    send_layout(s);
    pthread_mutex_unlock(&s->lock);
}

// MARK: Channels

static void channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdp_session *s = session_of(context);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (s->clipboard)
            rdp_clipboard_connected(s, (CliprdrClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = e->pInterface;
        disp->custom = s;
        disp->DisplayControlCaps = display_control_caps;
        pthread_mutex_lock(&s->lock);
        s->disp = disp;
        pthread_mutex_unlock(&s->lock);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, e);
    }
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rdp_session *s = session_of(context);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        rdp_clipboard_disconnected(s);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&s->lock);
        s->disp = NULL;
        s->disp_ready = false;
        pthread_mutex_unlock(&s->lock);
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }
}

/// Watches the device redirection channel for the server's reply to the shared folder (the only device announced).
static BOOL receive_channel_data(freerdp *instance, UINT16 channel_id, const BYTE *data, size_t size, UINT32 flags,
                                 size_t total_size) {
    rdp_session *s = session_of(instance->context);
    if (s->shared_folder && (flags & CHANNEL_FLAG_FIRST) && size >= 12
        && channel_id == freerdp_channels_get_id_by_name(instance, RDPDR_SVC_CHANNEL_NAME)) {
        const UINT16 component = (UINT16)(data[0] | data[1] << 8), packet = (UINT16)(data[2] | data[3] << 8);
        if (component == RDPDR_CTYP_CORE && packet == PAKID_CORE_DEVICE_REPLY) {
            const UINT32 status = (UINT32)data[8] | (UINT32)data[9] << 8 | (UINT32)data[10] << 16
                | (UINT32)data[11] << 24;
            rdp_event event = { .type = RDP_EVENT_SHARED_FOLDER, .code = status };
            rdp_emit(s, &event);
        }
    }
    return s->default_receive(instance, channel_id, data, size, flags, total_size);
}

/// Reads a DER length at *i.
static bool der_length(const BYTE *p, size_t n, size_t *i, size_t *length) {
    if (*i >= n)
        return false;
    const BYTE first = p[(*i)++];
    if (first < 0x80) {
        *length = first;
        return true;
    }
    const size_t bytes = first & 0x7F;
    if (bytes == 0 || bytes > 4 || *i + bytes > n)
        return false;
    *length = 0;
    for (size_t b = 0; b < bytes; b++)
        *length = *length << 8 | p[(*i)++];
    return true;
}

/// A CredSSP TSRequest that carries the user's credentials: authInfo [2] right after the version [0].
static bool is_credentials(const BYTE *p, size_t n) {
    size_t i = 0, length = 0;
    if (n < 2 || p[i++] != 0x30 || !der_length(p, n, &i, &length))
        return false;
    if (i >= n || p[i++] != 0xA0 || !der_length(p, n, &i, &length) || i + length > n)
        return false;
    i += length;
    return i < n && p[i] == 0xA2;
}

/// auth_only: NLA has proved the password once the server answered with its public key, and the next message
/// would hand the password over for a logon. It isn't sent: a logon started and dropped makes Windows hold the
/// account's next logon for a minute.
static int auth_only_write(rdpTransport *transport, wStream *stream) {
    rdp_session *s = session_of(transport_get_context(transport));
    if (is_credentials(Stream_Buffer(stream), Stream_GetPosition(stream))) {
        s->auth_verified = true;
        return -1;
    }
    return s->default_write(transport, stream);
}

/// Through an SSH host: the connection goes to the local end of the forward instead of the server.
static int tunnel_connect(rdpContext *context, rdpSettings *settings, const char *hostname, int port, DWORD timeout) {
    (void)hostname;
    (void)port;
    rdp_session *s = session_of(context);
    return s->default_tcp_connect(context, settings, "127.0.0.1", s->tunnel_port, timeout);
}

// MARK: Connecting

static BOOL pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    if (!freerdp_settings_set_uint32(context->settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH)
        || !freerdp_settings_set_uint32(context->settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
        return FALSE;
    context->update->EndPaint = end_paint;
    context->update->DesktopResize = desktop_resize;
    return TRUE;
}

static BOOL post_connect(freerdp *instance) {
    rdp_session *s = session_of(instance->context);
    pthread_mutex_lock(&s->frame_lock);
    const BOOL ok = gdi_init(instance, PIXEL_FORMAT_BGRX32);
    pthread_mutex_unlock(&s->frame_lock);
    if (!ok)
        return FALSE;
    const rdpPointer pointer = {
        .size = sizeof(shim_pointer), .New = pointer_new, .Free = pointer_free, .Set = pointer_set,
        .SetNull = pointer_set_null, .SetDefault = pointer_set_default, .SetPosition = pointer_set_position,
    };
    graphics_register_pointer(instance->context->graphics, &pointer);
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    rdp_session *s = session_of(instance->context);
    pthread_mutex_lock(&s->frame_lock);
    gdi_free(instance);
    pthread_mutex_unlock(&s->frame_lock);
}

static BOOL client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->AuthenticateEx = authenticate;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;
    instance->LogonErrorInfo = logon_error_info;
    return TRUE;
}

static void client_free(freerdp *instance, rdpContext *context) {
    (void)instance;
    (void)context;
}

static bool configure(rdp_session *s, const rdp_config *c) {
    rdpSettings *settings = s->context->settings;
    const uint32_t device_scale = c->device_scale == 140 || c->device_scale == 180 ? c->device_scale : 100;
    if (!freerdp_settings_set_string(settings, FreeRDP_ServerHostname, c->host)
        || !freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, c->port)
        || !freerdp_settings_set_string(settings, FreeRDP_Username, c->username)
        || !freerdp_settings_set_string(settings, FreeRDP_Domain, c->domain && c->domain[0] ? c->domain : NULL)
        || !freerdp_settings_set_string(settings, FreeRDP_Password, c->password)
        || !freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, clamp(c->width, 200, 8192))
        || !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, clamp(c->height, 200, 8192))
        || !freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, clamp(c->desktop_scale, 100, 500))
        || !freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, device_scale)
        || !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32)
        || !freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE)
        || !freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE)
        || !freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE)
        || !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, c->clipboard)
        || !freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE)
        || !freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE)
        || !freerdp_settings_set_bool(settings, FreeRDP_AuthenticationOnly, c->auth_only)
        || !freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, c->ignore_certificate)
        || !freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, 15000)
        // Activation: FreeRDP's own 9 s, but Windows took up to 50 s to reactivate a session just left (a reconnect, or
        // another client taking it over). AirSCP's connect watchdog (60 s) still bounds it.
        || !freerdp_settings_set_uint32(settings, FreeRDP_TcpAckTimeout, 60000))
        return false;
    if (c->keyboard_layout && !freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, c->keyboard_layout))
        return false;
    if (c->config_dir && c->config_dir[0] && !freerdp_settings_set_string(settings, FreeRDP_ConfigPath, c->config_dir))
        return false;
    if (c->shared_folder && c->shared_folder[0]) {
        const char *const drive[] = { "drive", "AirSCP", c->shared_folder };
        if (!freerdp_client_add_device_channel(settings, 3, drive))
            return false;
        s->shared_folder = true;
    }
    return true;
}

// MARK: FreeRDP's log

static _Atomic(rdp_log_handler) log_handler;

void rdp_log_to(rdp_log_handler handler) {
    atomic_store(&log_handler, handler);
}

static BOOL log_message(const wLogMessage *message) {
    const rdp_log_handler handler = atomic_load(&log_handler);
    if (handler && message->TextString) {
        char line[8192];
        (void)snprintf(line, sizeof line, "FreeRDP %s%s", message->PrefixString ? message->PrefixString : "",
                       message->TextString);
        handler(line);
    }
    return TRUE;
}

/// Lines through `log_message`, as "<level> <logger>: <text>" (FreeRDP's hex dumps and packets aren't text: left out).
static void use_log_callback(void) {
    wLog *root = WLog_GetRoot();
    static wLogCallbacks callbacks = { .message = log_message };
    if (WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK))
        (void)WLog_ConfigureAppender(WLog_GetLogAppender(root), "callbacks", &callbacks);
    (void)WLog_Layout_SetPrefixFormat(root, WLog_GetLogLayout(root), "%lv %mn: ");
}

/// rdp_log_to's choice, for a new session: FreeRDP's log is off unless AirSCP's debug log is on (AirSCP reports what
/// went wrong itself), or $WLOG_LEVEL asks for its own.
static void configure_log(void) {
    if (getenv("WLOG_LEVEL"))
        return;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, use_log_callback);
    static const char *const detailed[] = {
        "com.freerdp.core.connection", "com.freerdp.crypto", "com.freerdp.core.nla", "com.freerdp.core.auth",
        "com.freerdp.core.gateway.tsg", "com.freerdp.core.gateway.rdg", "com.freerdp.core.gateway.rpc",
        "com.freerdp.core.gateway.http", "com.freerdp.core.gateway.wst", "com.freerdp.core.gateway.websocket",
        "com.freerdp.core.gateway.ntlm", "com.freerdp.core.gateway.rts", "com.freerdp.core.gateway.arm",
        "com.freerdp.channels.cliprdr.client", "com.freerdp.channels.cliprdr.common", "com.freerdp.channels.rdpdr.client",
        "com.freerdp.channels.drive.client",
    };
    const bool on = atomic_load(&log_handler) != NULL;
    (void)WLog_SetLogLevel(WLog_GetRoot(), on ? WLOG_INFO : WLOG_OFF);
    for (size_t i = 0; i < ARRAYSIZE(detailed); i++)
        (void)WLog_SetLogLevel(WLog_Get(detailed[i]), on ? WLOG_DEBUG : WLOG_LEVEL_INHERIT);
}

rdp_session *rdp_session_new(const rdp_config *config, rdp_event_handler handler, void *handler_context) {
    if (!config || !config->host || !handler)
        return NULL;
    configure_log();
    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.Size = sizeof(entry);
    entry.ContextSize = sizeof(shim_context);
    entry.ClientNew = client_new;
    entry.ClientFree = client_free;
    rdpContext *context = freerdp_client_context_new(&entry);
    if (!context)
        return NULL;
    rdp_session *s = calloc(1, sizeof *s);
    if (!s) {
        freerdp_client_context_free(context);
        return NULL;
    }
    ((shim_context *)context)->session = s;
    s->context = context;
    s->handler = handler;
    s->handler_context = handler_context;
    s->auth_only = config->auth_only;
    s->clipboard = config->clipboard;
    s->tunnel_port = config->tunnel_port;
    pthread_mutex_init(&s->frame_lock, NULL);
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->answered, NULL);
    pthread_mutex_init(&s->clip_lock, NULL);
    pthread_cond_init(&s->clip_cond, NULL);

    freerdp *instance = context->instance;
    s->default_receive = instance->ReceiveChannelData;
    instance->ReceiveChannelData = receive_channel_data;
    if (s->tunnel_port || s->auth_only) {
        rdpTransportIo io = *freerdp_get_io_callbacks(context);
        s->default_tcp_connect = io.TCPConnect;
        s->default_write = io.WritePdu;
        if (s->tunnel_port)
            io.TCPConnect = tunnel_connect;
        if (s->auth_only)
            io.WritePdu = auth_only_write;
        if (!freerdp_set_io_callbacks(context, &io)) {
            rdp_session_free(s);
            return NULL;
        }
    }
    if (PubSub_SubscribeChannelConnected(context->pubSub, channel_connected) < 0
        || PubSub_SubscribeChannelDisconnected(context->pubSub, channel_disconnected) < 0
        || !configure(s, config)) {
        rdp_session_free(s);
        return NULL;
    }
    return s;
}

/// Says why it ended: FreeRDP's last error, which includes the server's reason (logged off, another connection...).
static void finish(rdp_session *s, UINT32 error) {
    pthread_mutex_lock(&s->lock);
    const bool stopped = s->stopping;
    pthread_mutex_unlock(&s->lock);
    UINT32 code = error;
    if (stopped)
        code = s->auth_only ? FREERDP_ERROR_CONNECT_CANCELLED : 0;
    else if (s->auth_verified)
        code = FREERDP_ERROR_SUCCESS;
    else if (code == FREERDP_ERROR_SUCCESS && !s->auth_only)
        code = MAKE_FREERDP_ERROR(CONNECT, ERRCONNECT_CONNECT_TRANSPORT_FAILED);
    rdp_event event = {
        .type = RDP_EVENT_DISCONNECTED, .code = code,
        .text = code == 0 ? "" : freerdp_get_last_error_string(code),
    };
    rdp_emit(s, &event);
}

static void *run(void *argument) {
    rdp_session *s = argument;
    rdpContext *context = s->context;
    freerdp *instance = context->instance;
    if (!freerdp_connect(instance)) {
        finish(s, freerdp_get_last_error(context));
        return NULL;
    }
    pthread_mutex_lock(&s->lock);
    s->input_ready = !s->stopping;
    pthread_mutex_unlock(&s->lock);
    // NLA (PROTOCOL_HYBRID 0x2, PROTOCOL_HYBRID_EX 0x8) checked the password before this: otherwise the server checks
    // it only now, at its own logon screen.
    const UINT32 protocol = freerdp_settings_get_uint32(context->settings, FreeRDP_SelectedProtocol);
    rdp_event connected = {
        .type = RDP_EVENT_CONNECTED, .code = (protocol & 0x0A) ? 1 : 0,
        .width = (int32_t)freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
        .height = (int32_t)freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight),
    };
    rdp_emit(s, &connected);
    HANDLE handles[MAXIMUM_WAIT_OBJECTS];
    while (!freerdp_shall_disconnect_context(context)) {
        const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
        if (count == 0 || WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED)
            break;
        if (!freerdp_check_event_handles(context))
            break;
    }
    pthread_mutex_lock(&s->lock);
    s->input_ready = false;
    pthread_mutex_unlock(&s->lock);
    const UINT32 error = freerdp_get_last_error(context);  // before freerdp_disconnect, which may change it
    freerdp_disconnect(instance);
    finish(s, error);
    return NULL;
}

bool rdp_session_start(rdp_session *s) {
    if (s->thread_started)
        return false;
    s->thread_started = pthread_create(&s->thread, NULL, run, s) == 0;
    return s->thread_started;
}

void rdp_session_stop(rdp_session *s) {
    pthread_mutex_lock(&s->lock);
    s->stopping = true;
    pthread_cond_broadcast(&s->answered);
    pthread_mutex_unlock(&s->lock);
    rdp_session_cancel_read(s);
    freerdp_abort_connect_context(s->context);
}

void rdp_session_free(rdp_session *s) {
    if (!s)
        return;
    if (s->thread_started) {
        rdp_session_stop(s);
        pthread_join(s->thread, NULL);
    }
    PubSub_UnsubscribeChannelConnected(s->context->pubSub, channel_connected);
    PubSub_UnsubscribeChannelDisconnected(s->context->pubSub, channel_disconnected);
    freerdp_client_context_free(s->context);
    rdp_clipboard_free(s);
    free(s->answer_username);
    free(s->answer_domain);
    free(s->answer_password);
    pthread_mutex_destroy(&s->frame_lock);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->answered);
    pthread_mutex_destroy(&s->clip_lock);
    pthread_cond_destroy(&s->clip_cond);
    free(s);
}

// MARK: Input (only while connected)

static rdpInput *input_locked(rdp_session *s) {
    pthread_mutex_lock(&s->lock);
    if (s->input_ready)
        return s->context->input;
    pthread_mutex_unlock(&s->lock);
    return NULL;
}

bool rdp_session_key(rdp_session *s, uint16_t mac_keycode, bool down, bool repeat) {
    const DWORD vk = GetVirtualKeyCodeFromKeycode(mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
    if (vk == 0 || (scancode & 0xFF) == 0)
        return false;
    rdpInput *input = input_locked(s);
    if (input) {
        (void)freerdp_input_send_keyboard_event_ex(input, down, repeat, scancode);
        pthread_mutex_unlock(&s->lock);
    }
    return true;
}

void rdp_session_scancode(rdp_session *s, uint16_t scancode, bool down) {
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    (void)freerdp_input_send_keyboard_event_ex(input, down, false, scancode);
    pthread_mutex_unlock(&s->lock);
}

void rdp_session_unicode(rdp_session *s, uint16_t utf16, bool down) {
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    (void)freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, utf16);
    pthread_mutex_unlock(&s->lock);
}

static UINT16 coordinate(int32_t value) {
    return (UINT16)(value < 0 ? 0 : value > UINT16_MAX ? UINT16_MAX : value);
}

void rdp_session_mouse_move(rdp_session *s, int32_t x, int32_t y) {
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, coordinate(x), coordinate(y));
    pthread_mutex_unlock(&s->lock);
}

void rdp_session_mouse_button(rdp_session *s, int button, bool down, int32_t x, int32_t y) {
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    if (button <= 2) {
        const UINT16 flags = button == 0 ? PTR_FLAGS_BUTTON1 : button == 1 ? PTR_FLAGS_BUTTON2 : PTR_FLAGS_BUTTON3;
        (void)freerdp_input_send_mouse_event(input, flags | (down ? PTR_FLAGS_DOWN : 0), coordinate(x), coordinate(y));
    } else {
        const UINT16 flags = button == 3 ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2;
        (void)freerdp_input_send_extended_mouse_event(input, flags | (down ? PTR_XFLAGS_DOWN : 0), coordinate(x),
                                                      coordinate(y));
    }
    pthread_mutex_unlock(&s->lock);
}

void rdp_session_mouse_wheel(rdp_session *s, bool horizontal, int32_t delta, int32_t x, int32_t y) {
    if (delta == 0)
        return;
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    // The rotation is 9 bits, two's complement; one event carries at most 255 units.
    int32_t left = delta;
    while (left != 0) {
        const int32_t step = left > 255 ? 255 : left < -255 ? -255 : left;
        left -= step;
        UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
        if (step < 0)
            flags |= PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)((0x200 + step) & 0xFF);
        else
            flags |= (UINT16)step;
        (void)freerdp_input_send_mouse_event(input, flags, coordinate(x), coordinate(y));
    }
    pthread_mutex_unlock(&s->lock);
}

void rdp_session_focus(rdp_session *s, bool caps_lock) {
    rdpInput *input = input_locked(s);
    if (!input)
        return;
    (void)freerdp_input_send_focus_in_event(input, caps_lock ? KBD_SYNC_CAPS_LOCK : 0);
    pthread_mutex_unlock(&s->lock);
}

// MARK: Misc

uint32_t rdp_keyboard_layout(void) {
    return freerdp_keyboard_init(0);
}
