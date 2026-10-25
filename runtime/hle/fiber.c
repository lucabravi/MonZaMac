// nn::os fibers (Pokémon Z-A's job system runs its jobs on them). The SDK switches fibers in
// nn::os::detail::DispatchFiberContext: push the callee-saved registers on the current stack, store that sp in the
// current fiber's context, load the other fiber's sp, pop its registers and `ret` to its x30. Recompiled, that `ret`
// is a C return into the *current* host stack, which belongs to the fiber being left - so each guest fiber gets a
// host context of its own (its own host stack: a ucontext, or a Win32 fiber on Windows), and the switch is a host
// context switch.
//
// A switch publishes the fiber being left (its context in guest memory) before the host is off that fiber's stack, and
// a job system may resume it on another thread right away: two threads on one stack. So a switch goes through a
// trampoline fiber of the switching thread's own: there the fiber left is released (busy = 0: nothing runs on it any
// more), the thread waits until the fiber it switches to is released by whoever left it, claims it and switches.
// (Waiting on the trampoline, holding nothing, two threads swapping each other's fibers can't deadlock.)
//
// Each fiber also gets its own Cpu: the host frames of a suspended fiber hold their `Cpu *c`, and a job system may
// resume the fiber on another thread. A switch copies the running thread's identity (thread object, TLS) into the
// Cpu of the fiber it starts or resumes. The guest-visible state stays as the SDK leaves it: the 0xf0-byte register
// frame on the fiber's stack, its sp in FiberType+0x50.
#if defined(__APPLE__)
#define _XOPEN_SOURCE 700  // ucontext.h is gated behind it in the macOS SDK
#define _DARWIN_C_SOURCE
#endif
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <ucontext.h>
#endif

#include "../hle.h"

#define CTX_FRAME 0xf0
#define CO_STACK (64ull << 20)  // reserved, not committed: recompiled code runs on the host stack

typedef struct Co {
    uint64_t key;  // guest address of the fiber's context (FiberType + 0x50, or the thread's own on its stack)
#ifdef _WIN32
    void *fiber;   // the Win32 fiber: ours (CreateFiberEx) when own, else a thread's (ConvertThreadToFiber)
    bool own;
#else
    ucontext_t uc;
    void *stack;
#endif
    Cpu *cpu;
    int started;
    atomic_int busy;  // a host thread runs on this fiber (or is still leaving it)
} Co;

static Co *fibers[1024];
static int ncos;
static pthread_mutex_t co_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread Co *co_starting;
// this thread's switch in progress (the trampoline's work) and its trampoline
static __thread Co *t_from, *t_to;
#ifdef _WIN32
static __thread void *t_tramp;
#else
static __thread ucontext_t t_tramp_uc, t_dummy_uc;
static __thread void *t_tramp_stack;
#endif

static void tramp_step(void) {
    atomic_store_explicit(&t_from->busy, 0, memory_order_release);
    int spins = 0;
    while (atomic_exchange_explicit(&t_to->busy, 1, memory_order_acquire))
        if (++spins > 64) sched_yield();
}

static Co *co_get(uint64_t key) {
    for (int i = 0; i < ncos; i++) if (fibers[i]->key == key) return fibers[i];
    if (ncos == (int)(sizeof fibers / sizeof *fibers)) FATAL("[fiber] too many fibers\n");
    Co *co = calloc(1, sizeof *co);
    co->key = key;
    fibers[ncos++] = co;
    return co;
}

RT_ON_RESET(fiber_reset) {
    for (int i = 0; i < ncos; i++) {
#ifdef _WIN32
        if (fibers[i]->own) DeleteFiber(fibers[i]->fiber);
#else
        if (fibers[i]->stack) munmap(fibers[i]->stack, CO_STACK);
#endif
        free(fibers[i]->cpu);
        free(fibers[i]);
    }
    ncos = 0;
}

static void frame_save(Cpu *c, uint64_t sp) {
    ST64(sp, 0);
    for (int r = 19; r <= 30; r++) ST64(sp + 8 + (r - 19) * 8, c->x[r]);
    ST64(sp + 0x68, 0);
    for (int r = 8; r <= 15; r++) memcpy((void *)(uintptr_t)(sp + 0x70 + (r - 8) * 16), &c->v[r], 16);
}

static void frame_load(Cpu *c, uint64_t sp) {
    c->x[0] = LD64(sp);
    for (int r = 19; r <= 30; r++) c->x[r] = LD64(sp + 8 + (r - 19) * 8);
    for (int r = 8; r <= 15; r++) memcpy(&c->v[r], (const void *)(uintptr_t)(sp + 0x70 + (r - 8) * 16), 16);
    c->sp = sp + CTX_FRAME;
}

static void identity(Cpu *to, const Cpu *from) {
    to->thread = from->thread;
    to->tpidr = from->tpidr;
    to->tpidrro = from->tpidrro;
    to->fpcr = from->fpcr;
    to->fpsr = from->fpsr;
}

// A fiber's first run, on its own host stack: the SDK's InitializeImpl frame holds x0 = the FiberType and
// x30 = the entry trampoline (it calls the fiber function, then switches to the fiber it returns - never returns).
static void co_main(void) {
    Co *co = co_starting;
    Cpu *c = co->cpu;
    frame_load(c, LD64(co->key));
    c->pc = c->x[30];
    rt_dispatch(c);
    FATAL("[fiber] fiber at %llx returned\n", (unsigned long long)co->key);
}
#ifdef _WIN32
static void WINAPI co_fiber_main(void *p) { (void)p; co_main(); }
static void WINAPI tramp_main(void *p) {
    (void)p;
    for (;;) { tramp_step(); SwitchToFiber(t_to->fiber); }
}
#else
static void tramp_main(void) {
    for (;;) { tramp_step(); swapcontext(&t_dummy_uc, &t_to->uc); }
}
#endif

// nn::os::detail::FiberImplByHorizon::InitializeImpl(FiberType *fiber, void *entry): as the SDK, and a reused
// FiberType starts afresh
HLE_FUNC("_ZN2nn2os6detail18FiberImplByHorizon14InitializeImplEPNS0_9FiberTypeEPv", fiber_initialize) {
    uint64_t f = c->x[0];
    uint64_t sp = LD64(f + 0x40) + LD64(f + 0x48) - CTX_FRAME;
    ST64(sp, f);
    ST64(sp + 0x60, c->x[1]);
    ST64(f + 0x50, sp);
    pthread_mutex_lock(&co_lock);
    co_get(f + 0x50)->started = 0;
    pthread_mutex_unlock(&co_lock);
}

// nn::os::detail::DispatchFiberContext(FiberContextForHorizon **from, FiberContextForHorizon **to)
HLE_FUNC("_ZN2nn2os6detail20DispatchFiberContextEPPNS1_22FiberContextForHorizonES4_", fiber_dispatch) {
    uint64_t from = c->x[0], to = c->x[1];
    uint64_t sp = c->sp - CTX_FRAME;
    frame_save(c, sp);
    ST64(from, sp);
    pthread_mutex_lock(&co_lock);
    Co *me = co_get(from), *dst = co_get(to);
    me->cpu = c;  // (whatever runs now: a fiber's own Cpu, or the thread's on its first switch)
    me->started = 1;
    atomic_store(&me->busy, 1);  // (running on it: already so when we got here through a trampoline)
    if (!dst->cpu) {
        dst->cpu = calloc(1, sizeof(Cpu));  // (16-byte aligned on the 64-bit hosts)
    }
    identity(dst->cpu, c);
    bool fresh = !dst->started;
#ifdef _WIN32
    // whatever runs now is a Win32 fiber from here on (a thread's first switch converts it)
    me->fiber = IsThreadAFiber() ? GetCurrentFiber() : ConvertThreadToFiber(NULL);
    if (!me->fiber) FATAL("[fiber] ConvertThreadToFiber failed (%lu)\n", GetLastError());
    if (fresh) {
        if (dst->own) DeleteFiber(dst->fiber);  // (a reused FiberType: not running, its old fiber starts afresh)
        dst->fiber = CreateFiberEx(0, CO_STACK, FIBER_FLAG_FLOAT_SWITCH, co_fiber_main, NULL);
        if (!dst->fiber) FATAL("[fiber] no host fiber (%lu)\n", GetLastError());
        dst->own = true;
        dst->started = 1;
    }
#else
    if (fresh) {
        if (!dst->stack) {
            dst->stack = mmap(NULL, CO_STACK, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
            if (dst->stack == MAP_FAILED) FATAL("[fiber] no host stack\n");
        }
        getcontext(&dst->uc);
        dst->uc.uc_stack.ss_sp = dst->stack;
        dst->uc.uc_stack.ss_size = CO_STACK;
        dst->uc.uc_link = NULL;
        makecontext(&dst->uc, co_main, 0);
        dst->started = 1;
    }
#endif
    pthread_mutex_unlock(&co_lock);
    if (fresh) co_starting = dst;
    t_from = me;
    t_to = dst;
#ifdef _WIN32
    if (!t_tramp && !(t_tramp = CreateFiberEx(0, 1 << 16, FIBER_FLAG_FLOAT_SWITCH, tramp_main, NULL)))
        FATAL("[fiber] no trampoline fiber (%lu)\n", GetLastError());
    SwitchToFiber(t_tramp);
#else
    if (!t_tramp_stack) {
        t_tramp_stack = mmap(NULL, 1 << 16, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (t_tramp_stack == MAP_FAILED) FATAL("[fiber] no trampoline stack\n");
        getcontext(&t_tramp_uc);
        t_tramp_uc.uc_stack.ss_sp = t_tramp_stack;
        t_tramp_uc.uc_stack.ss_size = 1 << 16;
        t_tramp_uc.uc_link = NULL;
        makecontext(&t_tramp_uc, tramp_main, 0);
    }
    swapcontext(&me->uc, &t_tramp_uc);
#endif
    // resumed (perhaps on another thread: whoever switched back copied its identity into c)
    frame_load(c, LD64(from));
}
