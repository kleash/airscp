#ifndef RDP_SHIM_H
#define RDP_SHIM_H

// AirSCP's RDP client: a flat C API over FreeRDP (vendored and linked statically, scripts/build-freerdp.sh), used by
// AirSCPCore/RDP.swift. This header includes no FreeRDP headers, so Swift never parses them.
//
// One rdp_session per connection: rdp_session_new, rdp_session_start, and rdp_session_free once
// RDP_EVENT_DISCONNECTED has arrived (or after rdp_session_stop). FreeRDP runs on the session's own thread; events
// arrive on FreeRDP's threads, never on the main thread. The input, display and clipboard calls may be made from any
// thread.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct rdp_session rdp_session;

typedef struct {
    /// The server: where to connect, and the name its certificate is checked and remembered under.
    const char *host;
    uint16_t port;
    const char *username;
    /// NULL or "": none.
    const char *domain;
    /// NULL: ask for it (RDP_EVENT_CREDENTIALS).
    const char *password;
    /// Nonzero: connect to 127.0.0.1 at this port instead, a local forward through an SSH host (`host` and `port`
    /// still name the server).
    uint16_t tunnel_port;
    /// The desktop in pixels.
    uint32_t width, height;
    /// Windows' scaling in percent (100 to 500), and the device's (100, 140 or 180).
    uint32_t desktop_scale, device_scale;
    /// A Windows keyboard layout id (rdp_keyboard_layout), 0 for FreeRDP's default.
    uint32_t keyboard_layout;
    /// FreeRDP's folder: the server certificates trusted with Always (server/), and the certificate authorities that
    /// verify servers (certs/: airscp_install_ca).
    const char *config_dir;
    /// Don't check the server's certificate at all (FreeRDP's IgnoreCertificate): no RDP_EVENT_CERTIFICATE.
    bool ignore_certificate;
    /// NULL or "": none. Else this Mac folder is \\tsclient\AirSCP in Windows.
    const char *shared_folder;
    /// Text and files both ways.
    bool clipboard;
    /// Log in and out again, without a desktop (Test Connection). Success: RDP_EVENT_DISCONNECTED with code 0.
    bool auth_only;
} rdp_config;

typedef enum {
    /// width, height: the desktop is up. code 1: NLA checked the password (else the server checks it only now).
    RDP_EVENT_CONNECTED = 1,
    /// Always the last event. code: 0 when stopped (or auth_only succeeded), else FreeRDP's error code; text says why.
    RDP_EVENT_DISCONNECTED,
    /// width, height: the frame buffer has a new size.
    RDP_EVENT_RESIZED,
    /// x, y, width, height: this part of the frame buffer changed.
    RDP_EVENT_PAINT,
    /// Answer with rdp_session_answer_certificate. text: host:port; subject, issuer, fingerprint (SHA-256);
    /// old_fingerprint when the server's certificate changed since it was trusted. code: FreeRDP's VERIFY_CERT_FLAG_*.
    RDP_EVENT_CERTIFICATE,
    /// Answer with rdp_session_answer_credentials. text: the user name so far.
    RDP_EVENT_CREDENTIALS,
    /// The mouse pointer: data is width × height BGRA (not premultiplied), x, y the hot spot. 0 × 0: hidden;
    /// code 1: the standard arrow.
    RDP_EVENT_POINTER,
    /// text: what Windows copied (UTF-8).
    RDP_EVENT_CLIPBOARD_TEXT,
    /// Windows copied files: code is how many files and folders (0: none any more), size their total bytes.
    /// Read them with rdp_session_remote_files.
    RDP_EVENT_CLIPBOARD_FILES,
    /// The server answered the shared folder's announcement: code 0 accepted, else its NTSTATUS.
    RDP_EVENT_SHARED_FOLDER,
} rdp_event_type;

typedef struct {
    rdp_event_type type;
    int32_t x, y, width, height;
    uint32_t code;
    uint64_t size;
    const char *text;
    const char *subject;
    const char *issuer;
    const char *fingerprint;
    const char *old_fingerprint;
    const uint8_t *data;
} rdp_event;

/// The pointers in an event are valid only during the call.
typedef void (*rdp_event_handler)(void *context, const rdp_event *event);

/// NULL if FreeRDP can't be set up with this configuration.
rdp_session *rdp_session_new(const rdp_config *config, rdp_event_handler handler, void *context);
/// Connects on the session's thread. False: the thread couldn't start (no events follow).
bool rdp_session_start(rdp_session *session);
/// Disconnects (or stops connecting); a question still waiting is answered "no". Returns at once.
void rdp_session_stop(rdp_session *session);
/// Waits for the session's thread to end, then frees everything.
void rdp_session_free(rdp_session *session);

/// RDP_EVENT_CERTIFICATE: 1 trust it from now on, 2 this time only, 0 don't connect.
void rdp_session_answer_certificate(rdp_session *session, int answer);
/// RDP_EVENT_CREDENTIALS: NULL username cancels.
void rdp_session_answer_credentials(rdp_session *session, const char *username, const char *domain,
                                    const char *password);

/// The frame buffer (BGRX, 32 bits per pixel), locked against resizing until rdp_session_unlock_frame. NULL when
/// there is none; unlock anyway.
const uint8_t *rdp_session_lock_frame(rdp_session *session, int32_t *width, int32_t *height, int32_t *stride);
void rdp_session_unlock_frame(rdp_session *session);

/// A Mac virtual key code. False when it has no scan code (send the characters with rdp_session_unicode).
bool rdp_session_key(rdp_session *session, uint16_t mac_keycode, bool down, bool repeat);
/// An RDP scan code, 0x100 set for an extended key (Ctrl+Alt+Del, modifiers).
void rdp_session_scancode(rdp_session *session, uint16_t scancode, bool down);
void rdp_session_unicode(rdp_session *session, uint16_t utf16, bool down);
/// x, y in desktop pixels. button: 0 left, 1 right, 2 middle, 3 and 4 the side buttons.
void rdp_session_mouse_move(rdp_session *session, int32_t x, int32_t y);
void rdp_session_mouse_button(rdp_session *session, int button, bool down, int32_t x, int32_t y);
/// delta: wheel units (120 = one notch); positive scrolls up (or right, horizontal).
void rdp_session_mouse_wheel(rdp_session *session, bool horizontal, int32_t delta, int32_t x, int32_t y);
/// The view got the keyboard focus: tells Windows the state of Caps Lock.
void rdp_session_focus(rdp_session *session, bool caps_lock);

/// Asks Windows to change the desktop size (display control channel). Sent once the server is ready for it.
void rdp_session_resize(rdp_session *session, uint32_t width, uint32_t height, uint32_t desktop_scale,
                        uint32_t device_scale);

/// The Mac's clipboard holds text: Windows can paste it.
void rdp_session_clipboard_text(rdp_session *session, const char *utf8);
/// A file or folder on the Mac's clipboard: folders first, then what is in them.
typedef struct {
    /// Where it is on the Mac.
    const char *path;
    /// What Windows calls it: the copied item's name, or a path inside a copied folder ("Folder/File.txt").
    const char *name;
    bool folder;
    uint64_t size;
    /// Last modified, in seconds since 1970.
    int64_t modified;
} rdp_local_file;

/// The Mac's clipboard holds files and folders: Windows can paste them (Explorer).
void rdp_session_clipboard_files(rdp_session *session, const rdp_local_file *files, int count);
/// The files Windows copied, as listed by the last RDP_EVENT_CLIPBOARD_FILES. *serial identifies the list; the
/// calls below fail once Windows' clipboard changed.
int rdp_session_remote_files(rdp_session *session, uint32_t *serial);
/// Entry `index`: its path (folders separated by "/"), size and whether it is a folder.
bool rdp_session_remote_file(rdp_session *session, uint32_t serial, int index, char *path, size_t path_size,
                             uint64_t *size, bool *folder);
/// Reads up to `length` bytes of entry `index` at `offset`, waiting for Windows. Returns the bytes read, -1 on failure
/// (cancelled, disconnected, the clipboard changed, or no answer within 30 s; 10 s for 64 KB or less).
int64_t rdp_session_read_remote_file(rdp_session *session, uint32_t serial, int index, uint64_t offset,
                                     void *buffer, uint32_t length);
/// Makes a waiting rdp_session_read_remote_file return -1.
void rdp_session_cancel_read(rdp_session *session);

/// The Windows keyboard layout for the Mac's current input source. Call it on the main thread.
uint32_t rdp_keyboard_layout(void);

/// One line of FreeRDP's log: "FreeRDP <level> <logger>: <text>". Called on FreeRDP's threads.
typedef void (*rdp_log_handler)(const char *line);
/// FreeRDP's own log (WLog) for AirSCP's debug log: to `handler` at INFO, and at DEBUG for the connection, TLS, NLA,
/// gateway, clipboard and drive channels; NULL (the default) turns it off. For the sessions made from then on. With
/// $WLOG_LEVEL set (a developer), FreeRDP logs to the console as it would by itself instead.
void rdp_log_to(rdp_log_handler handler);

#endif
