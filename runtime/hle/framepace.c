// Frame pacing: the game's speed doesn't depend on the frame rate.
// The game advances its world each frame by its frame period (16.67 ms) times the swap interval its frame timer
// (f_700000c910) reads from the system object - normally 1. When a frame takes longer than a vsync (GPU-bound at
// 32:9, a hitch), the next frame starts a vsync later but still advanced only 16.67 ms: slow motion (30 fps = half
// speed). tools/patches.py FRAME_STEPS_SITE routes that read here: we return how many vsyncs really passed since
// the last frame, so the world advances by the time that passed. The game's own waiting is unaffected (it reads
// the interval nowhere else). Shared by the macOS and Windows builds.
// FINDING (2026-10-09): forcing 2 steps did NOT change the player's walking speed - gameplay is a true fixed step per
// frame; this timer feeds something else. Kept for research, off by default.
//   LARECOMP_FRAMEPACE=1     hand the timer the vsyncs elapsed (default: the game's own value)
//   LARECOMP_FRAME_STEPS_MAX maximum steps per frame (default 4: after a long stall the game doesn't jump ahead)
//   LARECOMP_FORCE_STEPS=<n> (test) always n
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../platform.h"

extern volatile uint64_t g_vsync_count;  // runtime/hle/vi.c
uint64_t g_frame_steps_late;             // (stats) frames that advanced more than one step

uint32_t rt_frame_steps(uint32_t interval) {
    static int on = -1, max_steps, forced;
    if (on < 0) {
        const char *e = ENV("LARECOMP_FRAMEPACE");
        on = e ? atoi(e) != 0 : 0;  // off by default: the world (the player's movement) doesn't use this step (tested)
        e = ENV("LARECOMP_FRAME_STEPS_MAX");
        max_steps = e ? atoi(e) : 4;
        if (max_steps < 1) max_steps = 1;
        e = ENV("LARECOMP_FORCE_STEPS");
        forced = e ? atoi(e) : 0;
    }
    static int ncall;
    if (ENV("LARECOMP_LOG_FRAMEPACE") && ncall++ % 120 == 0) LOG("[framepace] call %d interval %u vsync %llu\n", ncall, interval, (unsigned long long)g_vsync_count);
    if (forced > 0) return (uint32_t)forced;
    static uint64_t last;
    uint64_t now = __atomic_load_n(&g_vsync_count, __ATOMIC_RELAXED);
    uint64_t steps = last ? now - last : 1;
    last = now;
    if (!on) return interval;
    if (steps < interval) steps = interval;  // (the game's own 30 fps mode: it waits that many vsyncs anyway)
    if (steps < 1) steps = 1;
    if (steps > (uint64_t)max_steps) steps = (uint64_t)max_steps;
    if (steps > 1) g_frame_steps_late++;
    return (uint32_t)steps;
}

// Pokémon Z-A's frame mode (tools/patches.py ZA_BUILDS): its configured vsyncs per frame - 1 (1: 30 fps). With
// the fps60 setting (or LARECOMP_FPS=60) 0: it presents every vsync and adapts its world step to the real frame
// time down to 30 fps. LARECOMP_FPS=30: as is. The retired LARECOMP_FPS_STEADY override is ignored.
#include "../settings.h"
bool g_za_frame_hook;  // (the game is Pokémon Z-A: exec.c leaves its GPU timing counters alone)

// 60 fps with a steady speed (after the "Dynamic 60 FPS" mod, Fl4sh9174). The game steps its world by a period in
// nanoseconds, read from two globals of its own: 16666667 (its 60 fps mode) and 33333334 (30 fps). At a fixed 60 the
// world slows down with every frame over 16.7 ms. Here the 60 mode's period is the real frame time (smoothed), from
// 58 fps down to 30 (at most 33.3 ms, the 30 mode's own). The mod also puts the game in its 30 fps mode under 46 fps,
// but that mode presents every two vsyncs, so the frame rate it then measures is ~30 and never leaves it: it stays
// in the 60 mode and only stretches the step. While the byte at the third site is set (loading, pause) the nominal
// period stays. The sites are data, not code, so they live here by build (2.0.2 only); a build without them, or a
// global that doesn't hold the nominal periods, turns this off.
#define STEP_NS60 16666667ull
#define STEP_NS30 33333334ull
extern uint8_t g_game_build[8];  // (main.c) the exefs/main build ID
static uint64_t g_step60, g_step30, g_step_flag;
static void step_sites(void) {
    static const uint8_t b202[8] = {0xb1, 0xf1, 0x2f, 0xd9, 0x19, 0xea, 0xe8, 0x6a};
    if (!memcmp(g_game_build, b202, 8)) g_step60 = 0x7003393e20, g_step30 = 0x7003393e28, g_step_flag = 0x700610b980;
}

static void dynamic_steps(void) {
    static int ok = -1;
    static uint64_t last;
    static double smooth;  // seconds per frame
    static int band = -1;
    if (ok < 0) {
        step_sites();
        ok = g_step60 && LD64(g_step60) == STEP_NS60 && LD64(g_step30) == STEP_NS30;
        if (!ok) LOG("[pace] 60 fps: the game's frame periods are not where expected: off\n");
    }
    if (!ok) return;
    uint64_t now = plat_now_ns();
    double dt = last ? (now - last) / 1e9 : 0;
    last = now;
    if (dt <= 0) return;
    if (dt > 0.25) dt = 0.25;  // (a stall or a load: not the frame rate)
    smooth = smooth > 0 ? dt * 0.05 + smooth * 0.95 : dt;
    int fps = (int)floor(1.0 / smooth);
    uint64_t period = STEP_NS60;
    if (fps < 58 && !LD8(g_step_flag)) {
        period = fps > 0 ? (uint64_t)(1e9f / (float)fps) : STEP_NS30;
        if (period > STEP_NS30) period = STEP_NS30;
    }
    ST64(g_step60, period);
    int now_band = period == STEP_NS60 ? 0 : period == STEP_NS30 ? 2 : 1;
    static int nlog;
    if (band != now_band && nlog++ < 30) LOG("[pace] 60 fps: step %.1f ms (%d fps)\n", period / 1e6, fps);
    band = now_band;
}

// Update appearance budgets on the guest frame thread, before its entity jobs run.
extern void rt_za_npc_capacity(void);
int32_t rt_za_frame_cfg(int32_t cfg) {
    rt_za_npc_capacity();
    g_za_frame_hook = true;
    const char *e = ENV("LARECOMP_FPS");
    bool on = e ? atoi(e) >= 60 : g_settings.fps60;
    static int logged = -1;
    if (logged != (int)on) { logged = on; LOG("[pace] game frame mode %d -> %d (%s)\n", cfg, on ? 0 : cfg, on ? "60 fps" : "as is"); }
    if (on) dynamic_steps();
    return on ? 0 : cfg;
}
