// Output resolution, shared by the Metal and Vulkan backends (each calls output_scale() once per presented frame).
// Render targets the game sizes for the Switch's 1920x1080 screen are allocated at (sx, sy) times their size; the
// image is then drawn into (vx, vy, vw, vh) of the window. Video tab "Internal resolution" (g_settings.res_mode):
//   Match display  render at the window's own pixel size
//   1x .. 4x       N times the Switch's docked image (1x: the default): 1080 lines x N (wide windows keep their shape: 32:9 at 2x =
//                  7680 x 2160); capped to the GPU's 16384-pixel texture limit
//   75% / 50% / 25%  of the game's own image (810p / 540p / 270p docked; scaled up to the window - with MetalFX when chosen)
//   Dynamic 1.5x   1.5x, lowered the same way (to 0.75x at the floor); Dynamic 1x: 1x the same way
//   Dynamic        Match display, lowered in steps while the GPU can't hold the game's frame rate and raised again when it can
//                  (each change reallocates the render targets: a short hitch, so it changes rarely, with hysteresis)
// Test overrides: LARECOMP_SCALE=<f> (render height = 1080 x f), LARECOMP_WIDE_TEST=<f> (forced shape).
#include <math.h>
#include <stdlib.h>

#include "../hle.h"
#include "../settings.h"
#include "../services/am.h"
#include "output_scale.h"

extern bool g_za_frame_hook;  // (hle/framepace.c) the game is Pokémon Z-A

#define MAX_TEX 16384.0

// Dynamic resolution: a factor on the Match display scale, 0.5 .. 1 in 0.05 steps.
static double g_dyn = 1.0;
static double g_dyn_gpu_sum, g_dyn_dt_sum, g_last_t;
static int g_dyn_n, g_dyn_gpu_n, g_dyn_good;
#define DYN_PROBE_MIN 2.0   // seconds between two tries upwards when the last ones held
#define DYN_PROBE_MAX 16.0  // ... after tries that were too eager (the frames got slow right after)
static double g_dyn_cool_until, g_dyn_probe_wait = DYN_PROBE_MIN, g_dyn_probe_at;
static double g_dyn_last_raise = -100, g_dyn_last_slow = -100;
static double g_dyn_iv;  // the present interval of the last decision
static double g_dyn_last_dt = -1, g_dyn_last_gpu = -1;  // (the averages of the last decision: F3)
static bool g_dyn_gpu_ok;
int g_out_present_interval = 1;  // (objects.c: vsyncs per presented frame - 2 when the game runs at 30 fps)

static void dyn_update(double now, double gpu_ms) {
    double dt = g_last_t > 0 ? (now - g_last_t) * 1000.0 : 16.7;
    g_last_t = now;
    if (dt > 250) return;  // (loading, menus, a stall: not the GPU's steady state)
    g_dyn_dt_sum += dt;
    g_dyn_n++;
    if (gpu_ms >= 0) { g_dyn_gpu_sum += gpu_ms; g_dyn_gpu_n++; }
    if (g_dyn_n < 30) return;  // decide every ~half second
    double avg_dt = g_dyn_dt_sum / g_dyn_n, avg_gpu = g_dyn_gpu_n ? g_dyn_gpu_sum / g_dyn_gpu_n : -1;
    g_dyn_dt_sum = g_dyn_gpu_sum = 0;
    g_dyn_n = g_dyn_gpu_n = 0;
    if (now < g_dyn_cool_until) return;
    double prev = g_dyn;
    g_dyn_last_dt = avg_dt, g_dyn_last_gpu = avg_gpu;
    // The renderer supplies the union of GPU-active intervals clipped to this present window, not the sum of each
    // command buffer's overlapping span. Use the measured occupancy directly; unknown samples are already -1.
    g_dyn_gpu_ok = avg_gpu >= 0;
    // the budget is the game's frame period: at 30 fps (interval 2) every frame takes 33 ms by design, and judged
    // against 60 fps that read as too slow and lowered the resolution to the 0.5 floor
    double iv = g_out_present_interval >= 1 && g_out_present_interval <= 4 ? g_out_present_interval : 1;
    if (iv != g_dyn_iv) {  // a new frame budget (60 <-> 30 fps): what was learnt about the old one does not apply
        g_dyn_iv = iv;
        g_dyn_probe_wait = DYN_PROBE_MIN, g_dyn_probe_at = now, g_dyn_good = 0, g_dyn_last_raise = -100;
    }
    // Slow frames count only when the GPU is a real part of them: a frame that is long on the CPU side (under 9 ms of
    // GPU) is not helped by a lower resolution, and lowering it anyway left the picture soft for nothing.
    bool slow = avg_gpu >= 0 ? avg_gpu > 17.0 * iv || (avg_dt > 17.4 * iv && avg_gpu > 9.0 * iv) : avg_dt > 17.4 * iv;
    if (slow) {
        g_dyn = fmax(0.5, g_dyn - (avg_dt > 22 * iv ? 0.1 : 0.05));
        g_dyn_good = 0;
        g_dyn_last_slow = now;
        if (now - g_dyn_last_raise < 3.0) g_dyn_probe_wait = fmin(g_dyn_probe_wait * 2, DYN_PROBE_MAX);  // raised too eagerly
    } else if (g_dyn < 1.0) {
        g_dyn_good++;
        if (now - g_dyn_last_slow > 10.0) g_dyn_probe_wait = DYN_PROBE_MIN;  // (10 s without a slow frame: no backoff)
        // with GPU timing: raise when there is clear headroom; without (Vulkan): probe upwards now and then
        // raise when the next step (pixels grow with the square of the factor) is predicted to stay under the limit:
        // a fixed 10.5 ms bar left the factor low where a higher one would have held (stuck at its floor with 11 ms of GPU).
        // The GPU time is the busy share of a present window, so it tops out at the frame period: a GPU that is busy all the
        // time and still makes 60 fps reads about 16 ms (an M5 at 2880x1620: 16 ms, 60 fps; the bars 15.5 / 14.3 kept it at
        // 85%). So the bars sit at the top (17 slow, 16.3 raise) and a missed frame (over 17.4 ms) is what lowers the factor.
        double up = (g_dyn + 0.05) / g_dyn;
        bool room = avg_gpu >= 0 ? avg_gpu * up * up < 16.3 * iv && g_dyn_good >= 4 : now >= g_dyn_probe_at && g_dyn_good >= 2;
        // (two steps at once while nothing was slow for a while and the factor is far from the top: a climb of 20 s becomes 10)
        if (room) { g_dyn = fmin(1.0, g_dyn + (now - g_dyn_last_slow > 6.0 && g_dyn < 0.85 ? 0.10 : 0.05)); g_dyn_good = 0; g_dyn_last_raise = now; g_dyn_probe_at = now + g_dyn_probe_wait; }
    }
    g_dyn = round(g_dyn * 20) / 20;
    if (g_dyn != prev) {
        g_dyn_cool_until = now + 1.5;
        LOG("[dynres] %.2f -> %.2f (frame %.1f ms, gpu %.1f ms)\n", prev, g_dyn, avg_dt, avg_gpu);
    }
}

double output_scale_dynamic_factor(void) { return g_dyn; }
bool output_scale_dynamic_stats(double *frame_ms, double *gpu_ms) { *frame_ms = g_dyn_last_dt; *gpu_ms = g_dyn_last_gpu; return g_dyn_gpu_ok; }

// A change of the resolution mode starts the controller over: it kept the factor of the mode before, and the hitch of
// the change itself read as a slow frame.
static void dyn_reset(double now) {
    g_dyn = 1.0;
    g_dyn_gpu_sum = g_dyn_dt_sum = 0;
    g_dyn_n = g_dyn_gpu_n = g_dyn_good = 0;
    g_last_t = 0;
    g_dyn_probe_wait = DYN_PROBE_MIN, g_dyn_probe_at = 0;
    g_dyn_cool_until = now + 3.0;
}

double g_out_shape = 1.0;  // the last frame's shape (runtime/hle/za_mods.c: Pokémon Z-A's camera follows it)

void output_scale(double dw, double dh, bool reshape_allowed, double now, double gpu_ms, OutScale *o) {
    double fit = fmin(dw / 1920.0, dh / 1080.0);
    static double forced = -1, wide_test = -1;
    if (forced < 0) forced = getenv("LARECOMP_SCALE") ? atof(getenv("LARECOMP_SCALE")) : 0;
    if (wide_test < 0) wide_test = getenv("LARECOMP_WIDE_TEST") ? atof(getenv("LARECOMP_WIDE_TEST")) : 0;
    double shape = wide_test > 0 ? wide_test : (dw / dh) / (16.0 / 9.0);
    bool reshape = reshape_allowed && fabs(shape - 1.0) > 0.005;
    if (!reshape) shape = 1.0;
    // render height in units of the Switch's 1080 lines
    double h;
    int mode = g_settings.res_mode;
    static int last_mode = -1;
    if (mode != last_mode) {
        if (last_mode >= 0 && res_is_dynamic(mode)) dyn_reset(now);
        last_mode = mode;
    }
    if (forced > 0) h = forced;
    else if (mode >= 1 && mode <= 8) h = mode;
    else if (mode == RES_X15) h = 1.5;  // (between 1x and 2x: most of 2x's smoothing for about half its cost)
    else if (mode == RES_Q75) h = 0.75;  // (shares of the game's own image, for slower Macs; were shares of Match display)
    else if (mode == RES_Q50) h = 0.5;
    else if (mode == RES_Q25) h = 0.25;
    else if (mode == RES_DYNAMIC_X15) { dyn_update(now, gpu_ms); h = 1.5 * g_dyn; }  // (1.5x while the GPU holds the frame rate, lower when it can't)
    else if (mode == RES_DYNAMIC_X1) { dyn_update(now, gpu_ms); h = g_dyn; }  // (1080p the same way)
    else {
        h = reshape ? dh / 1080.0 : fit;  // Match display
        if (g_za_frame_hook && am_handheld()) h *= 1080.0 / 720.0;
        if (mode == RES_DYNAMIC) { dyn_update(now, gpu_ms); h *= g_dyn; }
    }
    h = fmax(h, 0.1);  // (.25x of a small window)
    // The game sizes its render targets for the screen of the mode it was told (handheld 1280x720, else 1920x1080) and
    // sx / sy are relative to that: a fixed N x is N times the game's own image; Match display and Dynamic count the
    // window in docked 1080 lines, hence the 1080 / 720 above.
    bool hh = g_za_frame_hook && am_handheld();
    double base_w = hh ? 1280.0 : 1920.0, base_h = hh ? 720.0 : 1080.0;
    double sx = h * shape, sy = h;
    double cap = fmin(MAX_TEX / (base_w * sx), MAX_TEX / (base_h * sy));
    if (cap < 1.0) { sx *= cap; sy *= cap; }
    o->sx = sx; o->sy = sy; o->shape = shape;
    g_out_shape = shape;
    // where the image goes in the window: fills it when reshaped, else a fitted 16:9 box
    if (reshape) { o->vw = dw; o->vh = dh; }
    else { o->vw = 1920.0 * fit; o->vh = 1080.0 * fit; }
    if (wide_test > 0) {
        double f2 = fmin(dw / (1920.0 * wide_test), dh / 1080.0);
        o->vw = 1920.0 * wide_test * f2; o->vh = 1080.0 * f2;
    }
    o->vx = (dw - o->vw) / 2; o->vy = (dh - o->vh) / 2;
}
