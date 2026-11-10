// Runtime-internal declarations.
#pragma once
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>

#include "cpu.h"
#include "platform.h"

// runtime/crash_explain.c: the fatal line / crash spot, and the player's explanation of it (the crash alert)
void rt_fatal_msg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void rt_crash_fault(const char *what, uint64_t fa, uint64_t pc);
void rt_crash_explain(char *out, size_t n, const char *log_path);

#define LOG(...) fprintf(stderr, __VA_ARGS__)
#define FATAL(...) (rt_fatal_msg(__VA_ARGS__), rt_fatal_trace())  // (runtime/crash_explain.c keeps the line)

// ---- address space layout (guest addresses == host addresses)
// Guest addresses must fit in 39 bits; the window starts at 0x70_0000_0000, above the region macOS reserves.
// Two reservations (runtime/guest_layout.c). The low window, 7 GB at GUEST_LO: the images (their addresses are in the
// generated code), the host-implemented functions, TLS, stacks and heap. The alias region: the SDK's virtual address
// memory (Pokémon Legends Z-A reserves 12 GB in it), 16 GB, right behind the low window when the address space is free
// there and in the first free hole below 2^39 when it is not (macOS 27 keeps two ~12 GB blocks of its own at random
// places in 0x70_0000_0000..2^39, so one 32 GB window never fits). Pages are committed on first touch: address space only.
#define GUEST_LO     0x7000000000ull
#define GUEST_LOW_END 0x71C0000000ull
#define GUEST_LIMIT  0x8000000000ull   // 2^39
extern uint64_t g_alias_base, g_alias_size;
#define MAIN_BASE    0x7000000000ull
#define SDK_BASE     0x7008000000ull   // (128 MB for main: Pokémon Legends Z-A's image is 0x5f7a000)
#define HLE_BASE     0x7080000000ull   // fake addresses for host-implemented functions
#define HLE_SIZE     0x0000100000ull
#define HLE_CODE_BASE (HLE_BASE + HLE_SIZE)
#define HLE_CODE_STRIDE 64ull
#define HLE_CODE_SIZE 0x40000ull
#define TLS_BASE     0x7090000000ull
#define TLS_SIZE     0x0000100000ull
#define HLE_HEAP     0x7092000000ull   // guest-visible memory owned by host code
#define HLE_HEAP_SIZE 0x000E000000ull
#define ALIAS_BASE   g_alias_base      // alias region (svcMapMemory targets; an SDK's virtual address memory reserves its address regions here)
#define ALIAS_SIZE   g_alias_size      // 16 GB, or less when only a smaller hole is free
#define HEAP_BASE    0x70E0000000ull
#define HEAP_MAX     0x00D0000000ull   // 3.25 GB, up to GUEST_LOW_END

// An address range inside memory the host reserved (the low window or the alias region).
static inline bool guest_contains(uint64_t a, uint64_t n) {
    if (a >= GUEST_LO && a < GUEST_LOW_END) return n <= GUEST_LOW_END - a;
    return a >= g_alias_base && a - g_alias_base < g_alias_size && n <= g_alias_size - (a - g_alias_base);
}
// The end of the one reserved span that starts at GUEST_LO: both reservations when the alias region is right behind
// the low window, else the low window alone. (What GetInfo reports as the ASLR region: all of it is memory we own.)
static inline uint64_t guest_span_end(void) {
    return g_alias_base == GUEST_LOW_END ? g_alias_base + g_alias_size : GUEST_LOW_END;
}

// ---- the game (kernel.c; set from exefs/main.npdm by main.c)
extern uint64_t g_program_id;  // GetInfo 18, Pokémon Legends: Z-A's by default
extern uint64_t g_system_resource_size;  // GetInfo 16 (META+0x14): non-zero turns on the SDK's virtual address memory

// ---- loader.c
typedef struct Module {
    const char *name;
    uint64_t base, size;
    uint64_t text_off, text_size, ro_off, ro_size, data_off, data_size;
    uint64_t dynamic, init, fini, init_array, init_array_sz, fini_array, fini_array_sz;
    uint64_t symtab, strtab, nsyms, strtab_size;
} Module;

extern Module g_modules[4];
extern int g_nmodules;
void loader_load(const char *exefs_dir);  // (again after a reboot: modules are reloaded into wiped memory)
uint64_t loader_find_symbol(const char *name);
const char *loader_symbol_at(uint64_t addr, uint64_t *offset);

// ---- dispatch.c
typedef void (*HostFn)(Cpu *c);
void dispatch_init(void);
GuestFn dispatch_lookup(uint64_t addr);
uint64_t hle_register(const char *name, HostFn fn);  // returns fake guest address
HostFn hle_lookup_impl(const char *name);
void hle_override(uint64_t guest_addr, HostFn fn, const char *name);
void hle_guest_code_init(bool enabled);  // caller backs the guest veneer region first
bool hle_guest_code_range(uint64_t addr, uint64_t size);
void lumiose_test_store(uint64_t addr, uint64_t value, unsigned size);
bool hle_guest_code_commit(uint64_t addr, uint64_t size);  // publish complete patches after writable alias closes
void rt_fatal_trace(void) __attribute__((noreturn));
void crash_handler_install(void);  // per thread (alternate signal stack)

// ---- kernel.c
typedef struct KThread KThread;
void kernel_init(void);
void kernel_stop_threads(void (*idle)(void));  // reboot: unwind every guest thread and join it (idle: called while waiting)
void kernel_reset(void);                       // reboot: empty handle table, memory map, thread list
KThread *kernel_create_main_thread(uint64_t entry, uint64_t stack_size, int prio);
void kernel_run_main(KThread *t, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4);
uint32_t kernel_current_thread_handle(void);
Cpu *kernel_current_cpu(void);

// ---- ipc.c
typedef struct Service Service;
int ipc_handle_request(Cpu *c, uint32_t handle);
uint32_t ipc_connect_named_port(const char *name);

// ---- guest_layout.c
bool guest_reserve(void);  // both reservations (the low window and the alias region); false: start again
bool guest_reset(void);    // fresh zero pages over both

// ---- in-place reboot (main.c): switch seeds or go back to the start screen without leaving the process
enum { RT_REBOOT_NONE, RT_REBOOT_GAME, RT_REBOOT_TITLE };  // GAME: boot again at once (new seed); TITLE: start screen
void rt_request_reboot(int kind);  // any thread; the window loop (ui_run) returns it and main() carries it out
int rt_reboot_requested(void);
extern volatile int g_rt_unwind;   // set while guest threads are being stopped (kernel.c)
void rt_unwind_point(void);        // guest threads: unwind to thread_main if a reboot is stopping them

// ---- ui (runtime/nvn/metal.m)
int ui_run(void);  // window loop; returns RT_REBOOT_NONE on quit, otherwise the requested reboot kind

// ---- helpers
void guest_call(Cpu *c, uint64_t addr);   // call guest function at addr (saves/restores x30)
uint64_t guest_sym(const char *name);     // cached loader_find_symbol, fatal if missing
void *hle_alloc(uint64_t size);           // zeroed guest-visible memory (never freed)
extern const char *g_romfs_dir;

// Local Lumiose preparation: validate paired native libraries and bound offline capture.
bool lumiose_library_matches(void *library);
bool lumiose_capture_only(void);
