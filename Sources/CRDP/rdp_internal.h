#ifndef RDP_INTERNAL_H
#define RDP_INTERNAL_H

// Shared by rdp_shim.c (connection, desktop, input) and rdp_clipboard.c (clipboard text and files).

#include "rdp_shim.h"

#include <pthread.h>

#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/freerdp.h>
#include <freerdp/transport_io.h>
#include <winpr/shell.h>

struct rdp_session {
    rdpContext *context;
    rdp_event_handler handler;
    void *handler_context;
    pthread_t thread;
    bool thread_started;
    bool auth_only;
    bool clipboard;
    bool shared_folder;
    uint16_t tunnel_port;
    pTCPConnect default_tcp_connect;
    pTransportRWFkt default_write;
    pReceiveChannelData default_receive;
    /// auth_only: the server accepted the user name and password.
    bool auth_verified;

    /// Held while the frame buffer is made, resized or freed, and while the view reads it.
    pthread_mutex_t frame_lock;

    /// Questions (certificate, credentials) wait on `answered`; `stopping` makes every wait end.
    pthread_mutex_t lock;
    pthread_cond_t answered;
    bool stopping;
    bool asking;
    int certificate_answer;
    bool credentials_given;
    char *answer_username, *answer_domain, *answer_password;
    /// Input is sent only while connected.
    bool input_ready;

    /// Display control: the size asked for, sent once the server announced its capabilities.
    DispClientContext *disp;
    bool disp_ready, disp_pending;
    DISPLAY_CONTROL_MONITOR_LAYOUT disp_layout;

    /// Clipboard: everything below is guarded by `clip_lock`.
    pthread_mutex_t clip_lock;
    pthread_cond_t clip_cond;
    CliprdrClientContext *cliprdr;
    bool clip_ready;
    uint32_t server_flags;
    /// The Mac's side: text (UTF-16LE with its terminator) or files.
    WCHAR *local_text;
    size_t local_text_bytes;
    FILEDESCRIPTORW *local_files;
    char **local_paths;
    uint32_t local_count;
    /// Windows' side: the formats still to fetch, the one asked for, and the files it copied.
    uint32_t pending_text_format, pending_files_format;
    int requested;
    FILEDESCRIPTORW *remote_files;
    uint32_t remote_count;
    uint32_t remote_serial;
    /// The one file read in flight (rdp_session_read_remote_file).
    bool reading, read_done, read_failed, read_cancelled;
    uint32_t read_stream, stream_counter;
    void *read_buffer;
    uint32_t read_capacity;
    uint32_t read_got;
};

/// The FreeRDP context: FreeRDP's client context first, then the session it belongs to.
typedef struct {
    rdpClientContext common;
    rdp_session *session;
} shim_context;

void rdp_emit(rdp_session *session, const rdp_event *event);

/// rdp_clipboard.c: hooks up the clipboard channel when it connects, and lets go of it when it disconnects.
void rdp_clipboard_connected(rdp_session *session, CliprdrClientContext *cliprdr);
void rdp_clipboard_disconnected(rdp_session *session);
void rdp_clipboard_free(rdp_session *session);

#endif
