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
// the fps60 setting (or LARECOMP_FPS=60) 0: it presents every vsync and steps its world 1/60 s a frame; slower frames
// still get the vsyncs that really passed (the game's own dynamic step), so the speed holds. LARECOMP_FPS=30: as is.
#include "../settings.h"
bool g_za_frame_hook;  // (the game is Pokémon Z-A: exec.c leaves its GPU timing counters alone)

// 60 fps with a steady speed (the "Dynamic 60 FPS" mod, Fl4sh9174). The game steps its world by a period in
// nanoseconds, read from two globals of its own: 16666667 (its 60 fps mode) and 33333334 (30 fps). At a fixed 60 the
// world slows down with every frame over 16.7 ms. Here each frame's real time (smoothed) replaces the period of the
// mode in use: from about 58 fps down to 46 the 60 mode steps by the real period; under 46 the game is put in its 30
// fps mode, stepping by the real period (at most 33.3 ms). While the byte at the third site is set (loading, pause)
// the nominal periods stay. The sites are 2.0.2's (tools/patches.py ZA_STEP); a global that doesn't hold the nominal
// periods turns this off.
#define STEP_NS60 16666667ull
#define STEP_NS30 33333334ull
static uint64_t g_step60, g_step30, g_step_flag;
void rt_za_step_sites(uint64_t a60, uint64_t a30, uint64_t flag) { g_step60 = a60, g_step30 = a30, g_step_flag = flag; }

static bool g_step_slow;  // the game's 30 fps mode (under 46 fps), as of the last frame
static void dynamic_steps(void) {
    static int ok = -1;
    static uint64_t last;
    static double smooth;  // seconds per frame
    if (ok < 0) {
        ok = g_step60 && LD64(g_step60) == STEP_NS60 && LD64(g_step30) == STEP_NS30;
        if (!ok) LOG("[pace] steady 60: the game's frame periods are not where expected: off\n");
    }
    if (!ok) return;
    uint64_t now = plat_now_ns();
    double dt = last ? (now - last) / 1e9 : 0;
    last = now;
    if (dt <= 0) return;
    if (dt > 0.25) dt = 0.25;  // (a stall or a load: not the frame rate)
    smooth = smooth > 0 ? dt * 0.05 + smooth * 0.95 : dt;
    int fps = (int)floor(1.0 / smooth);
    uint64_t real = fps > 0 ? (uint64_t)(1e9f / (float)fps) : STEP_NS30;
    bool hold = LD8(g_step_flag) != 0;
    uint64_t p60 = STEP_NS60, p30 = STEP_NS30;
    if (fps < 46) {
        p30 = fps < 31 || hold ? STEP_NS30 : real;
    } else {
        p60 = fps >= 58 || hold ? STEP_NS60 : real;
    }
    ST64(g_step60, p60);
    ST64(g_step30, p30);
    if (g_step_slow != (fps < 46)) LOG("[pace] steady 60: %s (%d fps)\n", fps < 46 ? "game's 30 fps mode" : "60 fps mode", fps);
    g_step_slow = fps < 46;
}

int32_t rt_za_frame_cfg(int32_t cfg) {
    g_za_frame_hook = true;
    const char *e = ENV("LARECOMP_FPS");
    bool on = e ? atoi(e) >= 60 : g_settings.fps60;
    static int logged = -1;
    if (logged != (int)on) { logged = on; LOG("[pace] game frame mode %d -> %d (%s)\n", cfg, on ? 0 : cfg, on ? "60 fps" : "as is"); }
    if (on && (ENV("LARECOMP_FPS_STEADY") ? atoi(ENV("LARECOMP_FPS_STEADY")) : g_settings.fps60_steady)) {
        int32_t prev = g_step_slow;  // (the mode decided a frame ago: the game reads it before the new period)
        dynamic_steps();
        return prev;
    }
    return on ? 0 : cfg;
}
