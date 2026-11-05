// Asset-free CMIF tests using the production applet, IPC and kernel implementations.
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../runtime/services/am.c"
#include "../runtime/ipc.c"
#include "../runtime/kernel.c"

// Unused host/UI dependencies; handles, events, dispatch and applet behavior are real.
Settings g_settings;
const uint8_t g_user_id[16] = {0};
volatile int g_rt_unwind;
const char *settings_language(void) { return "en-US"; }
const char *plat_symbol(uint64_t pc, uint64_t *off) { (void)pc; (void)off; return NULL; }
void rt_fatal_msg(const char *fmt, ...) { (void)fmt; }
void rt_fatal_trace(void) { abort(); }

typedef struct {
    uint32_t result, object, copy;
    unsigned nobjects, ncopy;
    uint8_t data[32];
} Reply;

static Reply call(uint32_t h, uint32_t obj, uint32_t cmd, const void *data, size_t size,
                  uint32_t input, bool domain_input) {
    uint32_t msg[64] __attribute__((aligned(16))) = {4, 0};
    uint32_t *p = msg + 2;
    if (input && !domain_input) {
        msg[1] = 0x80000000u;
        *p++ = 1 << 5;
        *p++ = input;
    }
    uint32_t *raw = (uint32_t *)(((uintptr_t)p + 15) & ~(uintptr_t)15);
    bool domain = ((KSession *)handle_get(h))->domain != NULL;
    if (domain) {
        raw[0] = 1 | ((input && domain_input ? 1u : 0u) << 8) | ((16 + (uint32_t)size) << 16);
        raw[1] = obj;
        if (input && domain_input) raw[8 + (size + 3) / 4] = input;
        raw += 4;
    }
    memcpy(raw, "SFCI", 4);
    raw[2] = cmd;
    if (size) memcpy(raw + 4, data, size);
    msg[1] |= (32 + size + (domain ? 16 : 0) + (domain_input && input ? 4 : 0) + 3) / 4;
    Cpu cpu = {.tpidrro = (uintptr_t)msg};
    assert(ipc_handle_request(&cpu, h) == 0);
    Reply out = {0};
    p = msg + 2;
    if (msg[1] & 0x80000000u) {
        uint32_t hd = *p++;
        out.ncopy = (hd >> 1) & 15;
        unsigned nmove = (hd >> 5) & 15;
        if (out.ncopy) out.copy = p[0];
        p += out.ncopy;
        if (nmove) out.object = p[0];
        if (!domain) out.nobjects = nmove;
        p += nmove;
    }
    raw = (uint32_t *)(((uintptr_t)p + 15) & ~(uintptr_t)15);
    if (domain) { out.nobjects = raw[0]; raw += 4; }
    assert(!memcmp(raw, "SFCO", 4));
    out.result = raw[2];
    memcpy(out.data, raw + 4, sizeof out.data);
    // The commands returning objects in this test have no CMIF output fields.
    if (domain && out.nobjects) out.object = raw[4];
    return out;
}

static Reply command(uint32_t h, uint32_t cmd) { return call(h, 0, cmd, NULL, 0, 0, false); }

static Service *session_service(uint32_t handle) {
    KObject *o = handle_get(handle);
    assert(o && o->type == KOBJ_SESSION);
    return ((KSession *)o)->svc;
}

static void close_session(uint32_t h) {
    uint32_t msg[64] __attribute__((aligned(16))) = {2, 0};
    Cpu cpu = {.tpidrro = (uintptr_t)msg};
    assert(!ipc_handle_request(&cpu, h));
    handle_close(h);
}

static void reset(void) {
    am_reset();
    kernel_reset();
    assert(!applets && !storages && !applet_events);
}

static uint32_t creator(void) {
    uint32_t oe = session_new(service_lookup("appletOE"));
    Reply proxy = command(oe, 0);
    assert(!proxy.result && proxy.nobjects == 1);
    Reply c = command(proxy.object, 11);
    assert(!c.result && c.nobjects == 1);
    Reply self = command(proxy.object, 1);
    Reply launchable = command(self.object, 9);
    assert(!launchable.result && launchable.ncopy == 1);
    KObject *event = handle_get(launchable.copy);
    assert(event && event->type == KOBJ_EVENT && event->signaled);
    return c.object;
}

static void check_protocol(void) {
    uint32_t c = creator(), args[2] = {0x0e, 0};
    Reply a = call(c, 0, 0, args, sizeof args, 0, false);
    assert(!a.result && a.nobjects == 1 && "CreateLibraryApplet must return an accessor");
    Reply event = command(a.object, 0);
    assert(!event.result && event.ncopy == 1);
    KObject *ev = handle_get(event.copy);
    assert(ev && ev->type == KOBJ_EVENT && !ev->signaled);
    Reply completed = command(a.object, 1);
    assert(!completed.result && !completed.data[0]);
    uint32_t output_events[2];
    for (unsigned i = 0; i < 2; i++) {
        Reply output = command(a.object, 105 + i);
        assert(!output.result && output.ncopy == 1);
        output_events[i] = output.copy;
        assert(handle_get(output.copy) && !handle_get(output.copy)->signaled);
        assert(handle_get(command(a.object, 105 + i).copy) == handle_get(output.copy));
    }
    assert(command(a.object, 30).result);  // GetResult cannot report success before Start.
    assert(!command(a.object, 10).result);
    assert(ev->signaled);
    completed = command(a.object, 1);
    assert(!completed.result && completed.data[0] == 1);
    assert(!command(a.object, 30).result);
    assert(command(a.object, 10).result);  // Start is a one-way transition.
    for (unsigned i = 0; i < 2; i++) assert(!handle_get(output_events[i])->signaled);
    assert(command(a.object, 101).result == AM_NO_DATA);
    assert(command(a.object, 104).result == AM_NO_DATA);
    assert(command(a.object, 999).result);
    assert(command(a.object, 103).result);  // Interactive input is unsupported.
    const uint32_t unsupported[] = {0x0a, 0x0f, 0x10, 0x11, 0x13, 0xff};
    for (unsigned i = 0; i < sizeof unsupported / sizeof *unsupported; i++) {
        args[0] = unsupported[i];
        Reply bad = call(c, 0, 0, args, sizeof args, 0, false);
        assert(bad.result && !bad.nobjects);
    }
    assert(command(c, 999).result);
    assert(command(c, 11).result && command(c, 12).result);
    args[0] = 0x0e; args[1] = 1;
    assert(call(c, 0, 0, args, sizeof args, 0, false).result);
    puts("PASS error-applet protocol");
}

static uint32_t requery_after_close(uint32_t session, uint32_t cmd, KObject **event) {
    Reply first = command(session, cmd);
    assert(!first.result && first.ncopy == 1);
    *event = handle_get(first.copy);
    assert(*event && (*event)->type == KOBJ_EVENT);
    handle_close(first.copy);  // The real kernel CloseHandle implementation.
    KObject unrelated = {.type = KOBJ_TMEM};
    uint32_t reused = kernel_new_handle(&unrelated);
    assert(reused == first.copy);  // Deliberately occupy the previous guest handle slot.
    Reply next = command(session, cmd);
    assert(!next.result && next.ncopy == 1 && next.copy != reused);
    assert(handle_get(next.copy) == *event && handle_get(reused) == &unrelated);
    handle_close(reused);
    return next.copy;
}

static void check_event_requery(void) {
    uint32_t oe = session_new(service_lookup("appletOE"));
    Reply proxy = command(oe, 0), self = command(proxy.object, 1), c = command(proxy.object, 11);
    KObject *launchable;
    uint32_t launchable_handle = requery_after_close(self.object, 9, &launchable);
    assert(launchable->signaled && handle_get(launchable_handle) == launchable);
    uint32_t args[2] = {0x0e, 0};
    Reply a = call(c.object, 0, 0, args, sizeof args, 0, false);
    KObject *state, *output, *interactive;
    uint32_t state_handle = requery_after_close(a.object, 0, &state);
    uint32_t output_handle = requery_after_close(a.object, 105, &output);
    uint32_t interactive_handle = requery_after_close(a.object, 106, &interactive);
    assert(!state->signaled && !output->signaled && !interactive->signaled);
    assert(!command(a.object, 10).result);
    assert(handle_get(state_handle) == state && state->signaled);
    assert(handle_get(output_handle) == output && !output->signaled);
    assert(handle_get(interactive_handle) == interactive && !interactive->signaled);
    puts("PASS event requery after CloseHandle and slot reuse");
}

static uint32_t storage(uint32_t c, int64_t size) {
    Reply s = call(c, 0, 10, &size, sizeof size, 0, false);
    assert(!s.result && s.nobjects == 1);
    return s.object;
}

static IpcResp storage_io(Service *s, bool write, int64_t off, void *data, uint64_t size) {
    IpcReq req = {.cmd = write ? 10 : 11, .data = (const uint8_t *)&off, .data_size = 8};
    IpcBuf buf = {(uintptr_t)data, size};
    if (write) { req.na = 1; req.a[0] = buf; }
    else { req.nb = 1; req.b[0] = buf; }
    IpcResp resp = {0};
    s->handler(s, &req, &resp);
    return resp;
}

static void check_moved_input(void) {
    uint32_t c = creator(), args[2] = {0x0e, 0};
    Reply a = call(c, 0, 0, args, sizeof args, 0, false);
    uint32_t common = storage(c, 0x20), sent = storage(c, 0x1014), decoy = storage(c, 0x1014);
    Reply access = command(sent, 0), other = command(decoy, 0);
    AmStorage *st = session_service(sent)->state;
    uint8_t error[0x1014] = {2};
    uint32_t number = 12345678;
    memcpy(error + 8, &number, 4);
    memcpy(error + 20, "PRIVATE_INPUT_CONTENT", 21);
    assert(!storage_io(session_service(access.object), true, 0, error, sizeof error).result);
    number = 87654321;
    memcpy(error + 8, &number, 4);
    assert(!storage_io(session_service(other.object), true, 0, error, sizeof error).result);
    assert(!call(a.object, 0, 100, NULL, 0, common, false).result);
    assert(!call(a.object, 0, 100, NULL, 0, sent, false).result);
    AmApplet *state = session_service(a.object)->state;
    assert(state->ninputs == 2 && state->inputs[1] == st);
    assert(st->refs == 3);  // Storage, storage accessor, and queued input each own the data.
    close_session(sent);
    assert(st->refs == 2);
    uint8_t readback[12] = {0};
    assert(!storage_io(session_service(access.object), false, 0, readback, sizeof readback).result);
    memcpy(&number, readback + 8, 4);
    assert(number == 12345678);
    close_session(access.object);
    assert(st->refs == 1);
    assert(!command(a.object, 10).result);  // Must log sent's number, despite decoy being written last.
    assert(!state->ninputs);
    assert(call(a.object, 0, 100, NULL, 0, decoy, false).result);
    Service *svc = session_service(a.object);
    uint32_t clone = session_new(svc);
    KObject *event = handle_get(command(a.object, 0).copy);
    close_session(a.object);
    assert(svc->state);
    close_session(clone);
    assert(!svc->state && event->signaled);  // The guest may retain its event after closing the accessor.
    puts("PASS moved input identity and close lifetime");
}

static uint32_t domain_creator(uint32_t *handle) {
    *handle = session_new(service_lookup("appletOE"));
    uint32_t msg[64] __attribute__((aligned(16))) = {5, 8, 0, 0};
    memcpy(msg + 4, "SFCI", 4);  // ConvertCurrentObjectToDomain (control cmd 0).
    Cpu cpu = {.tpidrro = (uintptr_t)msg};
    assert(!ipc_handle_request(&cpu, *handle));
    assert(((KSession *)handle_get(*handle))->domain);
    Reply proxy = call(*handle, 1, 0, NULL, 0, 0, false);
    assert(!proxy.result && proxy.nobjects == 1);
    Reply c = call(*handle, proxy.object, 11, NULL, 0, 0, false);
    assert(!c.result && c.nobjects == 1);
    return c.object;
}

static void close_domain_object(uint32_t h, uint32_t id) {
    uint32_t msg[64] __attribute__((aligned(16))) = {4, 8, 0, 0};
    msg[4] = 2;
    msg[5] = id;
    Cpu cpu = {.tpidrro = (uintptr_t)msg};
    assert(!ipc_handle_request(&cpu, h));
}

static void check_domain_input(void) {
    uint32_t h, other_h, c = domain_creator(&h), other_c = domain_creator(&other_h);
    uint32_t args[2] = {0x0e, 0};
    Reply a = call(h, c, 0, args, sizeof args, 0, false);
    Reply other_a = call(other_h, other_c, 0, args, sizeof args, 0, false);
    int64_t size = 16;
    Reply s = call(h, c, 10, &size, sizeof size, 0, false);
    Reply other_s = call(other_h, other_c, 10, &size, sizeof size, 0, false);
    assert(s.object == other_s.object && a.object == other_a.object);
    Domain *domain = ((KSession *)handle_get(h))->domain;
    Domain *other_domain = ((KSession *)handle_get(other_h))->domain;
    AmStorage *st = domain->objs[s.object]->state;
    AmStorage *other_st = other_domain->objs[other_s.object]->state;
    assert(st != other_st);
    st->data[0] = 0x31; other_st->data[0] = 0x72;
    assert(!call(h, a.object, 100, NULL, 0, s.object, true).result);
    assert(!call(other_h, other_a.object, 100, NULL, 0, other_s.object, true).result);
    AmApplet *state = domain->objs[a.object]->state;
    AmApplet *other_state = other_domain->objs[other_a.object]->state;
    assert(state->inputs[0] == st && state->inputs[0]->data[0] == 0x31);
    assert(other_state->inputs[0] == other_st && other_state->inputs[0]->data[0] == 0x72);
    assert(call(h, a.object, 100, NULL, 0, c, true).result);  // Wrong service type.
    assert(call(h, a.object, 100, NULL, 0, 255, true).result);  // Missing local object.
    assert(call(h, a.object, 100, NULL, 0, 256, true).result);  // Out-of-range object.
    assert(call(h, a.object, 100, NULL, 0, 0, true).result);  // No input object.
    Service *storage_svc = domain->objs[s.object];
    close_domain_object(h, s.object);
    assert(!storage_svc->state && st->refs == 1);
    assert(!call(h, a.object, 10, NULL, 0, 0, false).result);
    close_domain_object(h, a.object);
    assert(!domain->objs[a.object]);
    puts("PASS domain-local input identity and close lifetime");
}

static void check_validation(void) {
    uint32_t c = creator(), args[2] = {0x0e, 0};
    Service *creator_svc = session_service(c);
    for (unsigned cmd = 0; cmd <= 10; cmd += 10) {
        for (unsigned size = 0; size < 8; size++) {
            IpcReq req = {.cmd = cmd, .data = (const uint8_t *)args, .data_size = size};
            IpcResp resp = {0};
            creator_svc->handler(creator_svc, &req, &resp);
            assert(resp.result && !resp.nobjects);
        }
    }
    const int64_t bad_sizes[] = {-1, 0, INT64_MAX, AM_MAX_STORAGE_SIZE + 1};
    for (unsigned i = 0; i < sizeof bad_sizes / sizeof *bad_sizes; i++) {
        Reply bad = call(c, 0, 10, &bad_sizes[i], 8, 0, false);
        assert(bad.result && !bad.nobjects);
    }
    uint32_t maximum = storage(c, AM_MAX_STORAGE_SIZE);
    close_session(maximum);
    uint32_t s = storage(c, 8);
    Reply accessor = command(s, 0);
    Service *accessor_svc = session_service(accessor.object);
    Reply size_reply = command(accessor.object, 0);
    int64_t reported_size;
    memcpy(&reported_size, size_reply.data, 8);
    assert(!size_reply.result && reported_size == 8);
    uint8_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8}, out[8] = {0};
    assert(!storage_io(accessor_svc, true, 0, data, sizeof data).result);
    assert(!storage_io(accessor_svc, false, 0, out, sizeof out).result && !memcmp(data, out, 8));
    assert(!storage_io(accessor_svc, true, 6, data, 4).result);
    memset(out, 0x55, sizeof out);
    assert(!storage_io(accessor_svc, false, 6, out, sizeof out).result);
    assert(out[0] == 1 && out[1] == 2 && out[2] == 0x55);
    for (int write = 0; write <= 1; write++) {
        const int64_t bad_offsets[] = {-1, 9, INT64_MIN, INT64_MAX};
        for (unsigned i = 0; i < sizeof bad_offsets / sizeof *bad_offsets; i++)
            assert(storage_io(accessor_svc, write, bad_offsets[i], data, 1).result);
        assert(storage_io(accessor_svc, write, 0, NULL, 1).result);
        assert(storage_io(accessor_svc, write, 0, (void *)(UINTPTR_MAX - 3), 8).result);
        assert(storage_io(accessor_svc, write, 0, data, UINT64_MAX).result);
        assert(!storage_io(accessor_svc, write, 8, data, 1).result);
        int64_t off = 0;
        IpcReq missing = {.cmd = write ? 10 : 11, .data = (const uint8_t *)&off, .data_size = 8};
        IpcResp resp = {0};
        accessor_svc->handler(accessor_svc, &missing, &resp);
        assert(resp.result);
        missing.data_size = 7;
        missing.nb = missing.na = 1;
        missing.a[0] = missing.b[0] = (IpcBuf){(uintptr_t)data, 8};
        resp = (IpcResp){0};
        accessor_svc->handler(accessor_svc, &missing, &resp);
        assert(resp.result);
    }
    Reply a = call(c, 0, 0, args, sizeof args, 0, false);
    uint32_t event = command(a.object, 0).copy;
    assert(command(a.object, 100).result);
    assert(call(a.object, 0, 100, NULL, 0, event, false).result);
    assert(call(a.object, 0, 100, NULL, 0, c, false).result);
    assert(call(a.object, 0, 100, NULL, 0, accessor.object, false).result);
    assert(call(a.object, 0, 100, NULL, 0, 0xdead, false).result);
    assert(call(a.object, 0, 100, NULL, 0, 0xffff8000u, false).result);
    assert(call(c, 0, 0, args, 8, s, false).result);
    assert(call(a.object, 0, 10, NULL, 0, s, false).result);
    IpcReq invalid = {.nmove = 9};
    assert(!ipc_input_object(&invalid, 0));
    Domain domain = {0};
    invalid = (IpcReq){.domain = &domain, .ndomain_in = 9};
    assert(!ipc_input_object(&invalid, 0));
    invalid = (IpcReq){.domain = &domain, .ndomain_in = 1, .nmove = 1};
    assert(!ipc_input_object(&invalid, 0));
    for (unsigned i = 0; i < 16; i++) assert(!call(a.object, 0, 100, NULL, 0, s, false).result);
    assert(call(a.object, 0, 100, NULL, 0, s, false).result);
    assert(command(s, 2).result && command(accessor.object, 999).result);
    assert(!ipc_input_object(&invalid, -1));
    // Reject incoming handle counts before copying beyond IpcReq's fixed arrays.
    uint32_t malformed[64] __attribute__((aligned(16))) = {4, 0x80000008u, 9 << 5};
    Cpu cpu = {.tpidrro = (uintptr_t)malformed};
    assert(ipc_handle_request(&cpu, c) == 0xE401);
    puts("PASS request validation and bounded storage I/O");
}

static void check_domain_validation(void) {
    uint32_t h, c = domain_creator(&h);
    // A converted domain session is not an IStorage object supplied through a moved handle.
    IpcReq moved_domain = {.nmove = 1, .move_handles = {h}};
    assert(!ipc_input_object(&moved_domain, 0));
    const uint32_t bad_headers[] = {
        1 | (9 << 8) | (16 << 16),  // Too many domain input ids.
        1 | (1 << 8) | (4 << 16),   // CMIF header truncated.
        1 | (1 << 8) | (64 << 16),  // Input object list outside the raw region.
    };
    for (unsigned i = 0; i < sizeof bad_headers / sizeof *bad_headers; i++) {
        uint32_t msg[64] __attribute__((aligned(16))) = {4, 12, 0, 0};
        msg[4] = bad_headers[i]; msg[5] = c;
        Cpu cpu = {.tpidrro = (uintptr_t)msg};
        assert(ipc_handle_request(&cpu, h) == 0xE401);
    }
    for (unsigned cmd = 0; cmd <= 10; cmd += 10) {
        uint32_t msg[64] __attribute__((aligned(16))) = {4, 16, 0, 0};
        msg[4] = 1 | (16 << 16);  // A complete CMIF header, declaring no command arguments.
        msg[5] = c;
        memcpy(msg + 8, "SFCI", 4);
        msg[10] = cmd;
        // Plausible CreateLibraryApplet / CreateStorage arguments in transport padding are not payload.
        msg[12] = cmd == 0 ? 0x0e : 8;
        Cpu cpu = {.tpidrro = (uintptr_t)msg};
        assert(!ipc_handle_request(&cpu, h));
        assert(msg[10] == AM_INVALID_ARGUMENT && msg[4] == 0);
    }
    puts("PASS domain input framing validation");
}

static void check_reset(void) {
    uint32_t c = creator(), args[2] = {0x0e, 0};
    Reply a = call(c, 0, 0, args, sizeof args, 0, false);
    uint32_t s = storage(c, 32);
    assert(!call(a.object, 0, 100, NULL, 0, s, false).result);
    assert(applets && storages && applet_events);
    Service *accessor = session_service(a.object);
    reset();
    assert(!accessor->state && !handle_get(a.object));
    c = creator();
    a = call(c, 0, 0, args, sizeof args, 0, false);
    assert(!handle_get(command(a.object, 0).copy)->signaled);
    assert(!command(a.object, 1).data[0]);
    puts("PASS reset isolates applet state");
}

int main(void) {
    check_event_requery();
    reset();
    check_protocol();
    reset();
    check_moved_input();
    reset();
    check_domain_input();
    reset();
    check_validation();
    reset();
    check_domain_validation();
    reset();
    check_reset();
    reset();
    return 0;
}
