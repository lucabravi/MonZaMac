// Applet manager (appletOE), apm, and lm.
#include <stdlib.h>
#include <string.h>

#include "am.h"
#include "../hle.h"
#include "../ipc.h"
#include "../settings.h"

#define AM_NO_MESSAGE MAKE_RESULT(128, 3)
#define AM_NO_DATA MAKE_RESULT(128, 2)
#define AM_INVALID_ARGUMENT MAKE_RESULT(128, 500)
#define AM_INVALID_STATE MAKE_RESULT(128, 512)
#define AM_UNSUPPORTED MAKE_RESULT(10, 221)  // CMIF: invalid/unsupported command
#define AM_MAX_STORAGE_SIZE (1024u * 1024u)  // bounded storage for this headless error-applet implementation

static void am_objects_reset(void);
static uint32_t launchable_event_handle(void);

static uint32_t msg_event_r, msg_event_w;
static KEvent *msg_event;
static uint32_t msg_queue[16];
static int msg_count;

static bool preselected_popped;
RT_ON_RESET(am_reset) {  // (reboot: the message queue starts over with FocusStateChanged)
    msg_event = NULL;
    msg_event_r = msg_event_w = 0;
    msg_count = 0;
    preselected_popped = false;
    am_objects_reset();
}

static void am_init_once(void) {
    if (msg_event) return;
    msg_event = kernel_create_event_pair(&msg_event_w, &msg_event_r);
    msg_queue[msg_count++] = 15;  // FocusStateChanged
    pthread_mutex_lock(&g_klock);
    kernel_signal(msg_event);
    pthread_mutex_unlock(&g_klock);
}

static uint32_t new_event(void) {
    uint32_t w, r;
    kernel_create_event_pair(&w, &r);
    return r;
}

#define UNHANDLED(iface) LOG("[am] %s cmd %u (unhandled, ok)\n", iface, req->cmd)

// The mode the game is told: docked (1080p, performance boost) or handheld (720p, normal). Handheld draws far fewer pixels.
bool am_handheld(void) { return g_settings.handheld; }  // (also the render scale's: runtime/nvn/output_scale.c)

// Switch modes while the game runs: the console tells a game about a dock / undock with these two applet messages, and
// the game then reads the mode back. Whether Pokémon Z-A reacts live is untested; else it applies from the next start.
void am_set_handheld(bool on) {
    g_settings.handheld = on;
    LOG("[am] game mode: %s\n", on ? "handheld" : "docked");
    pthread_mutex_lock(&g_klock);
    if (msg_event && msg_count + 2 <= (int)(sizeof msg_queue / sizeof *msg_queue)) {
        msg_queue[msg_count++] = 30;  // OperationModeChanged
        msg_queue[msg_count++] = 31;  // PerformanceModeChanged
        kernel_signal(msg_event);
    }
    pthread_mutex_unlock(&g_klock);
}

static void common_state_getter(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 0: resp->copy_handles[resp->ncopy++] = msg_event_r; break;  // GetEventHandle
    case 1:  // ReceiveMessage
        pthread_mutex_lock(&g_klock);
        if (msg_count) {
            OUT(uint32_t, 0) = msg_queue[0];
            memmove(msg_queue, msg_queue + 1, --msg_count * sizeof(uint32_t));
            if (!msg_count) msg_event->signaled = false;
            resp_size(resp, 4);
        } else {
            resp->result = AM_NO_MESSAGE;
        }
        pthread_mutex_unlock(&g_klock);
        break;
    case 5: OUT(uint8_t, 0) = am_handheld() ? 0 : 1; resp_size(resp, 1); break;   // GetOperationMode
    case 6: OUT(uint32_t, 0) = am_handheld() ? 0 : 1; resp_size(resp, 4); break;  // GetPerformanceMode: normal / boost
    case 8: OUT(uint8_t, 0) = 0; resp_size(resp, 1); break;   // GetBootMode
    case 9: OUT(uint8_t, 0) = 1; resp_size(resp, 1); break;   // GetCurrentFocusState: in focus
    case 13: case 61: resp->copy_handles[resp->ncopy++] = new_event(); break;
    case 60: {  // GetDefaultDisplayResolution
        int h = am_handheld() ? 720 : 1080, w = getenv("LARECOMP_DISPLAY_W") ? atoi(getenv("LARECOMP_DISPLAY_W")) : h * 16 / 9;
        LOG("[am] GetDefaultDisplayResolution -> %dx%d\n", w, h);
        OUT(int32_t, 0) = w; OUT(int32_t, 4) = h; resp_size(resp, 8); break;
    }
    default: UNHANDLED("ICommonStateGetter");
    }
}

static void self_controller(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 0: LOG("[am] application requested exit\n"); exit(0);
    case 9: resp->copy_handles[resp->ncopy++] = launchable_event_handle(); break;
    case 40: OUT(uint64_t, 0) = 1; resp_size(resp, 8); break;  // CreateManagedDisplayLayer
    case 69: OUT(uint8_t, 0) = 0; resp_size(resp, 1); break;
    default: UNHANDLED("ISelfController");
    }
}

static void window_controller(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 1: OUT(uint64_t, 0) = 0x1234; resp_size(resp, 8); break;  // GetAppletResourceUserId
    default: UNHANDLED("IWindowController");
    }
}

static void generic_ok(Service *s, IpcReq *req, IpcResp *resp) {
    LOG("[am] %s cmd %u (ok)\n", s->name, req->cmd);
    resp_size(resp, 0x10);
}

// ------------------------------------------------------------------ IStorage / IStorageAccessor
typedef struct AmStorage {
    uint8_t *data;
    uint64_t size;
    unsigned refs;
    struct AmStorage *next;
} AmStorage;
static AmStorage *storages;

static void storage_release(AmStorage *st) {
    if (--st->refs) return;
    AmStorage **p = &storages;
    while (*p && *p != st) p = &(*p)->next;
    if (*p) *p = st->next;
    free(st->data);
    free(st);
}

static void storage_close(Service *s) {
    if (s->state) storage_release(s->state);
    s->state = NULL;
}

static Service *storage_service(const char *name, ServiceHandler handler, AmStorage *st) {
    Service *s = service_new(name, handler, st);
    st->refs++;
    s->on_close = storage_close;
    return s;
}

static void storage_accessor(Service *s, IpcReq *req, IpcResp *resp) {
    AmStorage *st = s->state;
    if (!st) { resp->result = AM_INVALID_STATE; return; }
    switch (req->cmd) {
    case 0: OUT(int64_t, 0) = (int64_t)st->size; resp_size(resp, 8); break;  // GetSize
    case 10: case 11: {  // Write(offset, A) / Read(offset, B)
        if (!req->data || req->data_size < 8) { resp->result = AM_INVALID_ARGUMENT; break; }
        int64_t off;
        memcpy(&off, req->data, sizeof off);
        IpcBuf *b = req->cmd == 10 ? in_buf(req, 0) : out_buf(req, 0);
        if (off < 0 || (uint64_t)off > st->size || !b || (b->size && !b->addr) ||
            b->addr > UINTPTR_MAX || b->size > UINTPTR_MAX - b->addr) {
            resp->result = AM_INVALID_ARGUMENT;
            break;
        }
        uint64_t n = b->size < st->size - (uint64_t)off ? b->size : st->size - (uint64_t)off;
        if (n && req->cmd == 10) memcpy(st->data + off, (void *)(uintptr_t)b->addr, n);
        if (n && req->cmd == 11) memcpy((void *)(uintptr_t)b->addr, st->data + off, n);
        break;
    }
    default: resp->result = AM_UNSUPPORTED;
    }
}

static void am_storage(Service *s, IpcReq *req, IpcResp *resp) {
    if (!s->state) { resp->result = AM_INVALID_STATE; return; }
    if (req->cmd == 0) ipc_return_object(resp, storage_service("IStorageAccessor", storage_accessor, s->state));
    else resp->result = AM_UNSUPPORTED;
}

static Service *new_am_storage(const void *data, uint64_t size) {
    AmStorage *st = calloc(1, sizeof *st);
    if (!st) return NULL;
    st->data = calloc(1, size);
    if (!st->data) { free(st); return NULL; }
    st->size = size;
    if (data) memcpy(st->data, data, size);
    st->next = storages;
    storages = st;
    return storage_service("IStorage", am_storage, st);
}

// ------------------------------------------------------------------ ILibraryAppletCreator / ILibraryAppletAccessor
// Only the error applet is acknowledged without UI. Other applets require real user interaction/results.
typedef struct AmAppletEvent {
    KEvent *event;
    struct AmAppletEvent *next;
} AmAppletEvent;
static AmAppletEvent *applet_events;
static AmAppletEvent *launchable_event;

typedef struct AmApplet {
    Service *owner;
    AmAppletEvent *state_event, *output_event, *interactive_event;
    AmStorage *inputs[16];
    unsigned ninputs;
    bool completed;
    struct AmApplet *next;
} AmApplet;
static AmApplet *applets;

static AmAppletEvent *applet_event(void) {
    AmAppletEvent *e = calloc(1, sizeof *e);
    uint32_t writable, readable;  // Internal owner handles remain valid when a guest closes its returned handle.
    e->event = kernel_create_event_pair(&writable, &readable);
    e->next = applet_events;
    applet_events = e;
    return e;
}

static uint32_t launchable_event_handle(void) {
    if (!launchable_event) {
        launchable_event = applet_event();
        pthread_mutex_lock(&g_klock);
        kernel_signal(launchable_event->event);
        pthread_mutex_unlock(&g_klock);
    }
    return kernel_new_handle(launchable_event->event);
}

static void applet_release_inputs(AmApplet *a) {
    for (unsigned i = 0; i < a->ninputs; i++) storage_release(a->inputs[i]);
    a->ninputs = 0;
}

static void applet_close(Service *s) {
    AmApplet *a = s->state;
    if (!a) return;
    AmApplet **p = &applets;
    while (*p && *p != a) p = &(*p)->next;
    if (*p) *p = a->next;
    applet_release_inputs(a);
    // Returned event handles can outlive the accessor; the events are retained until reboot.
    free(a);
    s->state = NULL;
}

static void am_objects_reset(void) {
    while (applets) applet_close(applets->owner);
    while (storages) {
        AmStorage *st = storages;
        storages = st->next;
        free(st->data);
        free(st);
    }
    // Reset hooks run with guest threads stopped, immediately before the kernel discards its handles.
    while (applet_events) {
        AmAppletEvent *e = applet_events;
        applet_events = e->next;
        free(e->event);
        free(e);
    }
    launchable_event = NULL;
}

static void applet_log_error(const AmApplet *a) {
    if (a->ninputs < 2) return;  // Common library-applet arguments precede the error arguments.
    const AmStorage *st = a->inputs[1];
    // Public libnx ErrorCommonArg / ErrorApplicationArg layout; never log message strings or context bytes.
    // https://github.com/switchbrew/libnx/blob/master/nx/include/switch/applets/error.h
    if (st->size == 0x1014 && st->data[0] == 2) {
        uint32_t number;
        memcpy(&number, st->data + 8, 4);
        LOG("[am] error applet: application error_number=%u\n", number);
    } else if (st->size == 0x14 && st->data[0] == 0) {
        uint32_t low, desc, result;
        memcpy(&low, st->data + 8, 4);
        memcpy(&desc, st->data + 12, 4);
        memcpy(&result, st->data + 16, 4);
        LOG("[am] error applet: result=0x%08x error_code=%u-%u\n", result, low, desc);
    }
}

static void applet_accessor(Service *s, IpcReq *req, IpcResp *resp) {
    AmApplet *a = s->state;
    if (!a) { resp->result = AM_INVALID_STATE; return; }
    if (req->cmd != 100 && (req->nmove || req->ncopy || req->ndomain_in)) {
        resp->result = AM_INVALID_ARGUMENT;
        return;
    }
    switch (req->cmd) {
    // IPC serializes copy-handle numbers without duplicating them, so each query needs a fresh guest handle.
    case 0: resp->copy_handles[resp->ncopy++] = kernel_new_handle(a->state_event->event); break;
    case 1: OUT(uint8_t, 0) = a->completed; resp_size(resp, 1); break;
    case 10:  // Start: headless acknowledgement, with no native dialog.
        if (a->completed) { resp->result = AM_INVALID_STATE; break; }
        applet_log_error(a);
        applet_release_inputs(a);
        pthread_mutex_lock(&g_klock);
        a->completed = true;
        kernel_signal(a->state_event->event);
        pthread_mutex_unlock(&g_klock);
        LOG("[am] error applet: acknowledged without UI\n");
        break;
    case 30: if (!a->completed) resp->result = AM_INVALID_STATE; break;
    case 100: {  // PushInData: bind the actual moved session or domain input object.
        if (a->completed || a->ninputs == 16) { resp->result = AM_INVALID_STATE; break; }
        Service *input = ipc_input_object(req, 0);
        if (req->ncopy || (req->domain ? req->ndomain_in != 1 : req->nmove != 1) ||
            !input || input->handler != am_storage || !input->state) {
            resp->result = AM_INVALID_ARGUMENT;
            break;
        }
        AmStorage *st = input->state;
        st->refs++;
        a->inputs[a->ninputs++] = st;
        break;
    }
    case 101: case 104: resp->result = AM_NO_DATA; break;
    case 105: case 106: {
        AmAppletEvent **e = req->cmd == 105 ? &a->output_event : &a->interactive_event;
        if (!*e) *e = applet_event();
        resp->copy_handles[resp->ncopy++] = kernel_new_handle((*e)->event);
        break;
    }
    default: resp->result = AM_UNSUPPORTED;
    }
}

static void library_applet_creator(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    if (req->nmove || req->ncopy || req->ndomain_in) { resp->result = AM_INVALID_ARGUMENT; return; }
    switch (req->cmd) {
    case 0: {  // CreateLibraryApplet(id, mode): error applet, AllForeground only.
        uint32_t args[2];
        if (!req->data || req->data_size < sizeof args) { resp->result = AM_INVALID_ARGUMENT; break; }
        memcpy(args, req->data, sizeof args);
        if (args[0] != 0x0e || args[1] != 0) { resp->result = AM_UNSUPPORTED; break; }
        AmApplet *a = calloc(1, sizeof *a);
        a->state_event = applet_event();
        a->owner = service_new("ILibraryAppletAccessor", applet_accessor, a);
        a->owner->on_close = applet_close;
        a->next = applets;
        applets = a;
        ipc_return_object(resp, a->owner);
        break;
    }
    case 10: {  // CreateStorage(size); transfer-memory/handle storage have different ABIs and remain unsupported.
        int64_t size;
        if (!req->data || req->data_size < sizeof size) { resp->result = AM_INVALID_ARGUMENT; break; }
        memcpy(&size, req->data, sizeof size);
        if (size <= 0 || size > AM_MAX_STORAGE_SIZE) { resp->result = AM_INVALID_ARGUMENT; break; }
        Service *storage = new_am_storage(NULL, (uint64_t)size);
        if (storage) ipc_return_object(resp, storage);
        else resp->result = AM_INVALID_STATE;
        break;
    }
    default: resp->result = AM_UNSUPPORTED;
    }
}

extern const uint8_t g_user_id[16];

static void application_functions(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 1:  // PopLaunchParameter(kind)
        if (IN(uint32_t, 0) == 2 && !preselected_popped) {  // PreselectedUser
            uint8_t p[0x88] = {0};
            *(uint32_t *)p = 0xC79497CA;
            *(uint32_t *)(p + 4) = 1;
            memcpy(p + 8, g_user_id, 16);
            Service *storage = new_am_storage(p, sizeof p);
            if (storage) {
                preselected_popped = true;
                ipc_return_object(resp, storage);
            } else resp->result = AM_INVALID_STATE;
        } else {
            resp->result = AM_NO_DATA;
        }
        break;
    case 20: OUT(uint64_t, 0) = 0; resp_size(resp, 8); break;  // EnsureSaveData
    case 21: {  // GetDesiredLanguage: the game's text language (settings: runtime/settings.c, "language")
        char lang[8] = {0};
        snprintf(lang, sizeof lang, "%s", settings_language());
        memcpy(resp->data, lang, 8);
        resp_size(resp, 8);
        break;
    }
    case 23: memcpy(resp->data, "1.0.0", 6); resp_size(resp, 0x10); break;
    case 40: OUT(uint8_t, 0) = 0; resp_size(resp, 1); break;  // NotifyRunning
    case 130: case 140: resp->copy_handles[resp->ncopy++] = new_event(); break;
    default: UNHANDLED("IApplicationFunctions");
    }
}

static void application_proxy(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    static const struct { int cmd; const char *name; ServiceHandler h; } subs[] = {
        {0, "ICommonStateGetter", common_state_getter},
        {1, "ISelfController", self_controller},
        {2, "IWindowController", window_controller},
        {3, "IAudioController", generic_ok},
        {4, "IDisplayController", generic_ok},
        {10, "IProcessWindingController", generic_ok},
        {11, "ILibraryAppletCreator", library_applet_creator},
        {20, "IApplicationFunctions", application_functions},
        {1000, "IDebugFunctions", generic_ok},
    };
    for (unsigned i = 0; i < sizeof subs / sizeof *subs; i++) {
        if (subs[i].cmd == (int)req->cmd) {
            ipc_return_object(resp, service_new(subs[i].name, subs[i].h, NULL));
            return;
        }
    }
    UNHANDLED("IApplicationProxy");
}

SERVICE("appletOE", applet_oe) {
    (void)s;
    am_init_once();
    if (req->cmd == 0) ipc_return_object(resp, service_new("IApplicationProxy", application_proxy, NULL));
    else UNHANDLED("appletOE");
}

// ------------------------------------------------------------------ apm
static void apm_session(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    if (req->cmd == 1) { OUT(uint32_t, 0) = 0x92220008; resp_size(resp, 4); }  // GetPerformanceConfiguration
}

SERVICE("apm", apm) {
    (void)s;
    if (req->cmd == 0) ipc_return_object(resp, service_new("apm:ISession", apm_session, NULL));
    else if (req->cmd == 1) { OUT(uint32_t, 0) = 1; resp_size(resp, 4); }
}

// ------------------------------------------------------------------ lm (guest log output)
static void lm_logger(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s; (void)resp;
    if (req->cmd != 0) return;
    IpcBuf *b = in_buf(req, 0);
    if (!b || !b->size) return;
    // Log packets are TLV chunks after a 0x18-byte header; print the string chunks.
    const uint8_t *p = (const uint8_t *)(uintptr_t)b->addr, *end = p + b->size;
    p += 0x18;
    char line[1024];
    int n = 0;
    while (p + 2 <= end) {
        uint8_t key = p[0], len = p[1];
        p += 2;
        if (p + len > end) break;
        if (key == 2 || key == 4 || key == 5 || key == 6 || key == 7) {  // message, file, function, module, thread
            n += snprintf(line + n, sizeof line - n, "%s%.*s", n ? " | " : "", len, (const char *)p);
            if (n >= (int)sizeof line) break;
        }
        p += len;
    }
    if (n) LOG("[lm] %s\n", line);
}

SERVICE("lm", lm) {
    (void)s;
    if (req->cmd == 0) ipc_return_object(resp, service_new("lm:ILogger", lm_logger, NULL));
}
