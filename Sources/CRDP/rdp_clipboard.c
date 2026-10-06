// The clipboard channel (MS-RDPECLIP): text both ways (CF_UNICODETEXT), and files both ways as file lists
// (FileGroupDescriptorW) whose contents are read in ranges (File Contents Request/Response).
//
// Windows' side is fetched as soon as it changes: its text goes to the Mac's clipboard (RDP_EVENT_CLIPBOARD_TEXT),
// its file list is kept for rdp_session_read_remote_file (RDP_EVENT_CLIPBOARD_FILES). The Mac's side is offered when
// Swift says it changed, and handed over when Windows asks for it.

#include "rdp_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <freerdp/channels/cliprdr.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/file.h>
#include <winpr/string.h>
#include <winpr/user.h>

/// AirSCP's format id for FileGroupDescriptorW (registered formats are 0xC000 and up; Windows maps them by name).
#define FILES_FORMAT 0xC0F1
static const char files_format_name[] = "FileGroupDescriptorW";
static const UINT32 client_flags =
    CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS | CB_HUGE_FILE_SUPPORT_ENABLED;
enum { REQUEST_NONE, REQUEST_TEXT, REQUEST_FILES };

static void clear_local(rdp_session *s) {
    free(s->local_text);
    s->local_text = NULL;
    s->local_text_bytes = 0;
    for (uint32_t i = 0; i < s->local_count; i++)
        free(s->local_paths[i]);
    free(s->local_paths);
    free(s->local_files);
    s->local_paths = NULL;
    s->local_files = NULL;
    s->local_count = 0;
}

/// Tells Windows what the Mac's clipboard holds. Called with clip_lock held.
static void send_format_list(rdp_session *s) {
    if (!s->cliprdr || !s->clip_ready)
        return;
    CLIPRDR_FORMAT format = { 0 };
    CLIPRDR_FORMAT_LIST list = { .common.msgType = CB_FORMAT_LIST, .formats = &format };
    if (s->local_count > 0 && (s->server_flags & CB_STREAM_FILECLIP_ENABLED)) {
        format.formatId = FILES_FORMAT;
        format.formatName = (char *)files_format_name;
        list.numFormats = 1;
    } else if (s->local_text) {
        format.formatId = CF_UNICODETEXT;
        list.numFormats = 1;
    }
    (void)s->cliprdr->ClientFormatList(s->cliprdr, &list);
}

/// Fetches the next of Windows' formats still wanted, one at a time. Called with clip_lock held.
static void request_next(rdp_session *s) {
    if (s->requested != REQUEST_NONE || !s->cliprdr)
        return;
    UINT32 format = 0;
    if (s->pending_text_format) {
        format = s->pending_text_format;
        s->pending_text_format = 0;
        s->requested = REQUEST_TEXT;
    } else if (s->pending_files_format) {
        format = s->pending_files_format;
        s->pending_files_format = 0;
        s->requested = REQUEST_FILES;
    } else {
        return;
    }
    const CLIPRDR_FORMAT_DATA_REQUEST request = {
        .common.msgType = CB_FORMAT_DATA_REQUEST, .requestedFormatId = format,
    };
    if (s->cliprdr->ClientFormatDataRequest(s->cliprdr, &request) != CHANNEL_RC_OK)
        s->requested = REQUEST_NONE;
}

static UINT monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    rdp_session *s = cliprdr->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {
        .capabilitySetType = CB_CAPSTYPE_GENERAL, .capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN,
        .version = CB_CAPS_VERSION_2, .generalFlags = client_flags,
    };
    const CLIPRDR_CAPABILITIES capabilities = {
        .common.msgType = CB_CLIP_CAPS, .cCapabilitiesSets = 1, .capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general,
    };
    const UINT rc = cliprdr->ClientCapabilities(cliprdr, &capabilities);
    pthread_mutex_lock(&s->clip_lock);
    s->clip_ready = true;
    send_format_list(s);  // the first one is sent even when empty
    pthread_mutex_unlock(&s->clip_lock);
    return rc;
}

static UINT server_capabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *capabilities) {
    rdp_session *s = cliprdr->custom;
    UINT32 flags = 0;
    for (UINT32 i = 0; i < capabilities->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *set = &capabilities->capabilitySets[i];
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL && set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) {
            flags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)set)->generalFlags;
            break;
        }
    }
    pthread_mutex_lock(&s->clip_lock);
    s->server_flags = flags & client_flags;
    pthread_mutex_unlock(&s->clip_lock);
    return CHANNEL_RC_OK;
}

static UINT server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    rdp_session *s = cliprdr->custom;
    const CLIPRDR_FORMAT_LIST_RESPONSE response = {
        .common.msgType = CB_FORMAT_LIST_RESPONSE, .common.msgFlags = CB_RESPONSE_OK,
    };
    const UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    UINT32 text = 0, files = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT *format = &list->formats[i];
        if (format->formatId == CF_UNICODETEXT)
            text = CF_UNICODETEXT;
        else if (format->formatName && strcmp(format->formatName, files_format_name) == 0)
            files = format->formatId;
    }
    pthread_mutex_lock(&s->clip_lock);
    const bool had_files = s->remote_count > 0;
    s->remote_serial++;
    free(s->remote_files);
    s->remote_files = NULL;
    s->remote_count = 0;
    s->pending_text_format = text;
    s->pending_files_format = (s->server_flags & CB_STREAM_FILECLIP_ENABLED) ? files : 0;
    request_next(s);
    pthread_mutex_unlock(&s->clip_lock);
    if (had_files && !files) {
        rdp_event event = { .type = RDP_EVENT_CLIPBOARD_FILES };
        rdp_emit(s, &event);
    }
    return rc;
}

static UINT server_format_list_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)cliprdr;
    (void)response;
    return CHANNEL_RC_OK;
}

static UINT server_lock(CliprdrClientContext *cliprdr, const CLIPRDR_LOCK_CLIPBOARD_DATA *lock) {
    (void)cliprdr;
    (void)lock;
    return CHANNEL_RC_OK;
}

static UINT server_unlock(CliprdrClientContext *cliprdr, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *unlock) {
    (void)cliprdr;
    (void)unlock;
    return CHANNEL_RC_OK;
}

/// Windows pastes the Mac's text or file list.
static UINT server_format_data_request(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    rdp_session *s = cliprdr->custom;
    BYTE *data = NULL;
    UINT32 size = 0;
    pthread_mutex_lock(&s->clip_lock);
    if (request->requestedFormatId == CF_UNICODETEXT && s->local_text) {
        data = malloc(s->local_text_bytes);
        if (data) {
            memcpy(data, s->local_text, s->local_text_bytes);
            size = (UINT32)s->local_text_bytes;
        }
    } else if (request->requestedFormatId == FILES_FORMAT && s->local_count > 0) {
        if (cliprdr_serialize_file_list_ex(s->server_flags, s->local_files, s->local_count, &data, &size) != NO_ERROR) {
            data = NULL;
            size = 0;
        }
    }
    pthread_mutex_unlock(&s->clip_lock);
    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common.msgType = CB_FORMAT_DATA_RESPONSE, .common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
        .common.dataLen = size, .requestedFormatData = data,
    };
    const UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(data);
    return rc;
}

/// Windows' text, or its file list, as asked for by request_next.
static UINT server_format_data_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    rdp_session *s = cliprdr->custom;
    pthread_mutex_lock(&s->clip_lock);
    const int requested = s->requested;
    const uint32_t serial = s->remote_serial;
    s->requested = REQUEST_NONE;
    pthread_mutex_unlock(&s->clip_lock);
    const BYTE *data = response->requestedFormatData;
    const UINT32 length = response->common.dataLen;
    if (!(response->common.msgFlags & CB_RESPONSE_FAIL) && data && length > 0) {
        if (requested == REQUEST_TEXT) {
            WCHAR *text = calloc(length / 2 + 1, sizeof(WCHAR));  // aligned, and terminated
            if (text) {
                memcpy(text, data, length / 2 * sizeof(WCHAR));
                char *utf8 = ConvertWCharNToUtf8Alloc(text, length / 2, NULL);
                if (utf8) {
                    rdp_event event = { .type = RDP_EVENT_CLIPBOARD_TEXT, .text = utf8 };
                    rdp_emit(s, &event);
                }
                free(utf8);
                free(text);
            }
        } else if (requested == REQUEST_FILES) {
            FILEDESCRIPTORW *files = NULL;
            UINT32 count = 0;
            if (cliprdr_parse_file_list(data, length, &files, &count) == NO_ERROR && count > 0) {
                uint64_t total = 0;
                for (UINT32 i = 0; i < count; i++) {
                    if (!(files[i].dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
                        total += (uint64_t)files[i].nFileSizeHigh << 32 | files[i].nFileSizeLow;
                }
                pthread_mutex_lock(&s->clip_lock);
                const bool current = serial == s->remote_serial;
                if (current) {
                    free(s->remote_files);
                    s->remote_files = files;
                    s->remote_count = count;
                    files = NULL;
                }
                pthread_mutex_unlock(&s->clip_lock);
                if (current) {
                    rdp_event event = { .type = RDP_EVENT_CLIPBOARD_FILES, .code = count, .size = total };
                    rdp_emit(s, &event);
                }
            }
            free(files);
        }
    }
    pthread_mutex_lock(&s->clip_lock);
    request_next(s);
    pthread_mutex_unlock(&s->clip_lock);
    return CHANNEL_RC_OK;
}

/// Reads up to `length` bytes of `path` at `offset` into a new buffer.
static BYTE *read_range(const char *path, uint64_t offset, uint32_t length, UINT32 *got) {
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return NULL;
    BYTE *data = malloc(length ? length : 1);
    size_t done = 0;
    while (data && done < length) {
        const ssize_t n = pread(fd, data + done, length - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0) {
            free(data);
            data = NULL;
        } else if (n == 0) {
            break;
        } else {
            done += (size_t)n;
        }
    }
    close(fd);
    *got = (UINT32)done;
    return data;
}

/// Windows reads a file of the Mac's file list (its size, or a range of it).
static UINT server_file_contents_request(CliprdrClientContext *cliprdr, const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    rdp_session *s = cliprdr->custom;
    char *path = NULL;
    pthread_mutex_lock(&s->clip_lock);
    if (request->listIndex < s->local_count)
        path = strdup(s->local_paths[request->listIndex]);
    pthread_mutex_unlock(&s->clip_lock);
    BYTE *data = NULL;
    UINT32 size = 0;
    if (path && (request->dwFlags & FILECONTENTS_SIZE)) {
        struct stat info;
        if (stat(path, &info) == 0 && (data = malloc(8))) {
            const uint64_t value = (uint64_t)info.st_size;
            for (int i = 0; i < 8; i++)
                data[i] = (BYTE)(value >> (8 * i));
            size = 8;
        }
    } else if (path && (request->dwFlags & FILECONTENTS_RANGE)) {
        const uint64_t offset = (uint64_t)request->nPositionHigh << 32 | request->nPositionLow;
        const uint32_t length = request->cbRequested > (16u << 20) ? (16u << 20) : request->cbRequested;
        data = read_range(path, offset, length, &size);
    }
    free(path);
    const CLIPRDR_FILE_CONTENTS_RESPONSE response = {
        .common.msgType = CB_FILECONTENTS_RESPONSE, .common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
        .common.dataLen = 4 + size, .streamId = request->streamId, .cbRequested = size, .requestedData = data,
    };
    const UINT rc = cliprdr->ClientFileContentsResponse(cliprdr, &response);
    free(data);
    return rc;
}

/// A range of one of Windows' files, for the read waiting in rdp_session_read_remote_file.
static UINT server_file_contents_response(CliprdrClientContext *cliprdr,
                                          const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    rdp_session *s = cliprdr->custom;
    pthread_mutex_lock(&s->clip_lock);
    if (s->reading && !s->read_done && response->streamId == s->read_stream) {
        if (response->common.msgFlags & CB_RESPONSE_FAIL) {
            s->read_failed = true;
        } else {
            const uint32_t n = response->cbRequested < s->read_capacity ? response->cbRequested : s->read_capacity;
            memcpy(s->read_buffer, response->requestedData, n);
            s->read_got = n;
        }
        s->read_done = true;
        pthread_cond_broadcast(&s->clip_cond);
    }
    pthread_mutex_unlock(&s->clip_lock);
    return CHANNEL_RC_OK;
}

void rdp_clipboard_connected(rdp_session *s, CliprdrClientContext *cliprdr) {
    cliprdr->custom = s;
    cliprdr->MonitorReady = monitor_ready;
    cliprdr->ServerCapabilities = server_capabilities;
    cliprdr->ServerFormatList = server_format_list;
    cliprdr->ServerFormatListResponse = server_format_list_response;
    cliprdr->ServerLockClipboardData = server_lock;
    cliprdr->ServerUnlockClipboardData = server_unlock;
    cliprdr->ServerFormatDataRequest = server_format_data_request;
    cliprdr->ServerFormatDataResponse = server_format_data_response;
    cliprdr->ServerFileContentsRequest = server_file_contents_request;
    cliprdr->ServerFileContentsResponse = server_file_contents_response;
    pthread_mutex_lock(&s->clip_lock);
    s->cliprdr = cliprdr;
    s->clip_ready = false;
    pthread_mutex_unlock(&s->clip_lock);
}

void rdp_clipboard_disconnected(rdp_session *s) {
    pthread_mutex_lock(&s->clip_lock);
    s->cliprdr = NULL;
    s->clip_ready = false;
    s->requested = REQUEST_NONE;
    s->pending_text_format = s->pending_files_format = 0;
    if (s->reading) {
        s->read_failed = true;
        s->read_done = true;
        pthread_cond_broadcast(&s->clip_cond);
    }
    pthread_mutex_unlock(&s->clip_lock);
}

void rdp_clipboard_free(rdp_session *s) {
    clear_local(s);
    free(s->remote_files);
    s->remote_files = NULL;
    s->remote_count = 0;
}

// MARK: Called from Swift

void rdp_session_clipboard_text(rdp_session *s, const char *utf8) {
    size_t chars = 0;
    WCHAR *text = utf8 ? ConvertUtf8ToWCharAlloc(utf8, &chars) : NULL;
    pthread_mutex_lock(&s->clip_lock);
    clear_local(s);
    s->local_text = text;
    s->local_text_bytes = text ? (chars + 1) * sizeof(WCHAR) : 0;
    send_format_list(s);
    pthread_mutex_unlock(&s->clip_lock);
}

void rdp_session_clipboard_files(rdp_session *s, const rdp_local_file *files, int count) {
    FILEDESCRIPTORW *descriptors = calloc(count > 0 ? (size_t)count : 1, sizeof(FILEDESCRIPTORW));
    char **paths = calloc(count > 0 ? (size_t)count : 1, sizeof(char *));
    uint32_t n = 0;
    for (int i = 0; descriptors && paths && i < count; i++) {
        size_t chars = 0;
        WCHAR *name = ConvertUtf8ToWCharAlloc(files[i].name, &chars);
        // Windows' file list holds names of up to 259 characters (MAX_PATH with its terminator).
        if (name && chars > 0 && chars < ARRAYSIZE(descriptors[n].cFileName) && (paths[n] = strdup(files[i].path))) {
            FILEDESCRIPTORW *d = &descriptors[n++];
            for (size_t c = 0; c < chars; c++)
                d->cFileName[c] = name[c] == '/' ? '\\' : name[c];
            d->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_WRITESTIME | FD_PROGRESSUI;
            d->dwFileAttributes = files[i].folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
            const uint64_t size = files[i].folder ? 0 : files[i].size;
            d->nFileSizeHigh = (DWORD)(size >> 32);
            d->nFileSizeLow = (DWORD)size;
            // FILETIME: 100-nanosecond intervals since 1601.
            const uint64_t time = ((uint64_t)(files[i].modified > 0 ? files[i].modified : 0) + 11644473600ULL) * 10000000ULL;
            d->ftLastWriteTime.dwHighDateTime = (DWORD)(time >> 32);
            d->ftLastWriteTime.dwLowDateTime = (DWORD)time;
        }
        free(name);
    }
    pthread_mutex_lock(&s->clip_lock);
    clear_local(s);
    if (descriptors && paths && n > 0) {
        s->local_files = descriptors;
        s->local_paths = paths;
        s->local_count = n;
        descriptors = NULL;
        paths = NULL;
    }
    send_format_list(s);
    pthread_mutex_unlock(&s->clip_lock);
    if (paths) {
        for (uint32_t i = 0; i < n; i++)
            free(paths[i]);
    }
    free(paths);
    free(descriptors);
}

int rdp_session_remote_files(rdp_session *s, uint32_t *serial) {
    pthread_mutex_lock(&s->clip_lock);
    const int count = (int)s->remote_count;
    if (serial)
        *serial = s->remote_serial;
    pthread_mutex_unlock(&s->clip_lock);
    return count;
}

bool rdp_session_remote_file(rdp_session *s, uint32_t serial, int index, char *path, size_t path_size,
                             uint64_t *size, bool *folder) {
    bool found = false;
    pthread_mutex_lock(&s->clip_lock);
    if (serial == s->remote_serial && index >= 0 && (uint32_t)index < s->remote_count && path_size > 0) {
        const FILEDESCRIPTORW *d = &s->remote_files[index];
        char *name = ConvertWCharNToUtf8Alloc(d->cFileName, ARRAYSIZE(d->cFileName), NULL);
        if (name && strlen(name) < path_size) {
            for (char *c = name; *c; c++) {
                if (*c == '\\')
                    *c = '/';
            }
            strcpy(path, name);
            *size = (uint64_t)d->nFileSizeHigh << 32 | d->nFileSizeLow;
            *folder = (d->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            found = true;
        }
        free(name);
    }
    pthread_mutex_unlock(&s->clip_lock);
    return found;
}

int64_t rdp_session_read_remote_file(rdp_session *s, uint32_t serial, int index, uint64_t offset, void *buffer,
                                     uint32_t length) {
    pthread_mutex_lock(&s->clip_lock);
    if (!s->cliprdr || s->reading || serial != s->remote_serial || index < 0 || (uint32_t)index >= s->remote_count
        || length == 0) {
        pthread_mutex_unlock(&s->clip_lock);
        return -1;
    }
    s->reading = true;
    s->read_done = s->read_failed = s->read_cancelled = false;
    s->read_buffer = buffer;
    s->read_capacity = length;
    s->read_got = 0;
    s->read_stream = ++s->stream_counter;
    const CLIPRDR_FILE_CONTENTS_REQUEST request = {
        .common.msgType = CB_FILECONTENTS_REQUEST, .streamId = s->read_stream, .listIndex = (UINT32)index,
        .dwFlags = FILECONTENTS_RANGE, .nPositionLow = (UINT32)offset, .nPositionHigh = (UINT32)(offset >> 32),
        .cbRequested = length,
    };
    const UINT rc = s->cliprdr->ClientFileContentsRequest(s->cliprdr, &request);
    if (rc == CHANNEL_RC_OK) {
        // 30 s for a range of up to 4 MB; 10 s for 64 KB or less, which Windows answers at once when it answers: a
        // range it doesn't is then soon asked for again in smaller pieces (RDPSession.fetch).
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += length <= 65536 ? 10 : 30;
        while (!s->read_done && !s->read_cancelled) {
            if (pthread_cond_timedwait(&s->clip_cond, &s->clip_lock, &deadline) == ETIMEDOUT)
                break;
        }
    }
    const int64_t result =
        rc == CHANNEL_RC_OK && s->read_done && !s->read_failed && !s->read_cancelled ? (int64_t)s->read_got : -1;
    s->reading = false;
    s->read_buffer = NULL;
    pthread_mutex_unlock(&s->clip_lock);
    return result;
}

void rdp_session_cancel_read(rdp_session *s) {
    pthread_mutex_lock(&s->clip_lock);
    if (s->reading) {
        s->read_cancelled = true;
        pthread_cond_broadcast(&s->clip_cond);
    }
    pthread_mutex_unlock(&s->clip_lock);
}
