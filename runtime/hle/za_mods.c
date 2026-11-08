// Pokémon Z-A's graphics options (Display tab), at the sites of StevensND's and Fl4sh9174's exefs mods
// (tools/patches.py ZA_DOF / ZA_FXAA / ZA_BLOOM / ZA_WIDE / ZA_FOV / ZA_LOD / ZA_SHADOW). Each applies from the next frame (4K shadows: when the game next sizes its shadow map).
//   LARECOMP_DOF / LARECOMP_FXAA / LARECOMP_BLOOM / LARECOMP_FOV / LARECOMP_LOD / LARECOMP_SHADOWS_4K = 0 / 1
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../settings.h"

static bool on(const char *what, const char *env, bool setting, int *logged) {
    bool v = env ? atoi(env) != 0 : setting;
    if (*logged != (int)v) { *logged = v; LOG("[za] %s %s\n", what, v ? "on" : "off"); }
    return v;
}

// The pass reads its intensity and skips itself at 0 (as the "Disable DOF" mod makes it)
uint32_t rt_za_dof(uint32_t intensity) {
    static int logged = -1;
    return on("depth of field", ENV("LARECOMP_DOF"), g_settings.dof, &logged) ? intensity : 0;
}

// The game's FXAA: its two parameters at 0 turn it off
uint32_t rt_za_fxaa(uint32_t param) {
    static int logged = -1;
    return on("FXAA", ENV("LARECOMP_FXAA"), g_settings.fxaa && !settings_temporal_upscale(), &logged) ? param : 0;
}

// Bloom: its intensity (0 skips the pass) and, called with 1, whether its extra call runs
uint32_t rt_za_bloom(uint32_t intensity) {
    static int logged = -1;
    return on("bloom", ENV("LARECOMP_BLOOM"), g_settings.bloom, &logged) ? intensity : 0;
}

// Widescreen: with the Unlocked aspect the render targets take the window's shape (runtime/nvn/output_scale.c); the
// camera's 16:9 then becomes the window's aspect, the HUD keeps 16:9 in the middle, and the presenter shows the whole
// image (runtime/nvn/present_crop.c) instead of its 16:9 centre. Taller windows keep the 16:9 band.
extern double g_out_shape;  // runtime/nvn/output_scale.c: window aspect / 16:9, 1 when not reshaped
bool g_za_wide;             // the camera is widened: the presenter shows all of the image
static double g_hud_shape = 1.0;

void rt_za_aspect(uint64_t addr) {
    double s = g_out_shape;  // (written by the present thread: an aligned double, read whole)
    if (s < 1.0) s = 1.0;
    float a = (float)(16.0 / 9.0 * s);
    if (*(float *)(uintptr_t)addr != a) {
        *(float *)(uintptr_t)addr = a;  // (rodata, but guest memory is writable)
        LOG("[za] camera aspect %.4f (window shape %.3f)\n", a, s);
    }
    g_hud_shape = s;
    g_za_wide = s > 1.0;
}

// The HUD's layout rectangle (x, y, w, h in the 1920 x 1080 screen) squeezed horizontally around the centre, so that
// stretched to the wider image it keeps its own proportions
__uint128_t rt_za_hud_rect(uint64_t addr) {
    float r[4];
    memcpy(r, (const void *)(uintptr_t)addr, sizeof r);
    double s = g_hud_shape;
    if (s > 1.0) r[0] = (float)(960 + (r[0] - 960) / s), r[2] = (float)(r[2] / s);
    __uint128_t q;
    memcpy(&q, r, sizeof q);
    return q;
}

// Improved FOV: the mod adds 0.203125 to the camera's field of view (fadd s1, s1, s30) and leaves s30 at that value
uint32_t rt_za_fov(Cpu *c, uint32_t w) {
    static int logged = -1;
    if (!on("field of view", ENV("LARECOMP_FOV"), g_settings.fov, &logged)) return w;
    float f;
    memcpy(&f, &w, sizeof f);
    f += 0.203125f;
    memcpy(&w, &f, sizeof w);
    c->v[30] = 0x3e500000u;
    return w;
}

// "Sharper textures" (the mods' Level of detail): the LOD bias (-1.0) and the anisotropic filtering (8.0), both constants of the mod
bool rt_za_lod(void) {
    static int logged = -1;
    return on("level of detail", ENV("LARECOMP_LOD"), g_settings.lod, &logged);
}

// 4K shadows: the shadow map is 4096 instead of the size the game loads
bool rt_za_shadows_4k(void) {
    static int logged = -1;
    return on("4K shadows", ENV("LARECOMP_SHADOWS_4K"), g_settings.shadows_4k, &logged);
}

// Z-A 2.0.2 budgets 20 active NPCs and 25 selection candidates. Raising both to 64 removed
// repeated TempExit churn in the tested station walk. This preserves the game's scoring,
// distance checks and exit lifecycle; it does not correct the underlying priority policy.
void rt_za_smooth_anim_install(void);
void rt_za_npc_capacity(void) {
    rt_za_smooth_anim_install();
    extern uint8_t g_game_build[8];
    static const uint8_t b202[8] = {0xb1, 0xf1, 0x2f, 0xd9, 0x19, 0xea, 0xe8, 0x6a};
    const char *e = ENV("LARECOMP_NPC_CAPACITY_FIX");
    if ((e && !atoi(e)) || memcmp(g_game_build, b202, sizeof b202)) return;

    const uint64_t logical_addr = 0x700610b878ull;
    uint32_t logical = LD32(logical_addr);
    if (logical != 20 && logical != 64) return; // Not initialized, or an unexpected configuration.
    uint64_t selector = LD64(0x700610b858ull);
    if (selector < ALIAS_BASE || selector > GUEST_HI - 0x318 || (selector & 7)) return;
    uint32_t selection = LD32(selector + 0x310);
    if ((selection != 25 && selection != 64) || (logical == 64 && selection == 64)) return;

    // These are 32-bit fields: the adjacent float and flag must remain unchanged.
    ST32(logical_addr, 64);
    ST32(selector + 0x310, 64);
    LOG("[za] NPC appearance budgets %u/%u -> 64/64\n", logical, selection);
}

// Smooth distant animation. Each animated entity runs two update channels per frame: 0x7001e732a0 (policy at ctx+0x180,
// result at ctx+0x1f0/0x1f4, components' update at vtable +0x48), then 0x7001e73d60 (policy at ctx+0x1c0, result at
// ctx+0x1f8/0x1fc, components' update at vtable +0x50). A policy updates only when the entity's rank (ctx+0x158, by distance
// and view) is within a shared limit (ctx+0x1e0), which the second policy advances: that is what moves distant characters
// and Pokémon in visible steps. Lowering the rank to the limit for the duration of the call keeps each policy's own timing,
// accumulators and explicit skip rules. All four policies are overridden, because the channels have to agree: relaxing only
// the first left the second on the reduced rate, and a Pokémon's head alternated between two poses every frame.
static bool za_anim_ptr(uint64_t p, size_t size) {
    return p >= 0x7000000000ull && p <= GUEST_HI - size;
}
static void za_smooth_anim_policy(Cpu *c, uint64_t address) {
    static int logged = -1;
    static const char *env;
    static bool env_read;
    if (!env_read) { env = ENV("LARECOMP_SMOOTH_ANIM"); env_read = true; }
    uint64_t rank_ptr = c->x[3];
    uint32_t rank = 0;
    bool changed = false;
    if (on("smooth distant animation", env, g_settings.smooth_anim, &logged) && za_anim_ptr(rank_ptr, 4) &&
        za_anim_ptr(c->x[5], 8)) {
        uint64_t limit_ptr = LD64(c->x[5]);
        if (za_anim_ptr(limit_ptr, 4)) {
            rank = LD32(rank_ptr);
            uint32_t limit = LD32(limit_ptr);
            if ((int32_t)rank > (int32_t)limit) {
                // The rank is a stack local of the caller, read synchronously by the policy.
                ST32(rank_ptr, limit);
                changed = true;
            }
        }
    }
    dispatch_lookup(address)(c);
    if (changed) ST32(rank_ptr, rank);
}
static void za_smooth_anim_policy_main(Cpu *c) { za_smooth_anim_policy(c, 0x7001e70db4ull); }
static void za_smooth_anim_policy_main2(Cpu *c) { za_smooth_anim_policy(c, 0x7001e70f04ull); }
static void za_smooth_anim_policy_world(Cpu *c) { za_smooth_anim_policy(c, 0x70029019f8ull); }
static void za_smooth_anim_policy_world2(Cpu *c) { za_smooth_anim_policy(c, 0x7002901a54ull); }

// Whether the option has any effect: the override is only installed for the build it was checked on (the menu row is
// greyed out on the others, and on the start screen, before the build is known)
bool rt_za_smooth_anim_supported(void) {
    extern uint8_t g_game_build[8];
    static const uint8_t b202[8] = {0xb1, 0xf1, 0x2f, 0xd9, 0x19, 0xea, 0xe8, 0x6a};
    return !memcmp(g_game_build, b202, sizeof b202);
}

void rt_za_smooth_anim_install(void) {
    extern uint8_t g_game_build[8];
    static const uint8_t b202[8] = {0xb1, 0xf1, 0x2f, 0xd9, 0x19, 0xea, 0xe8, 0x6a};
    static bool done;
    if (done || memcmp(g_game_build, b202, sizeof b202)) return;
    done = true;
    hle_override(0x7001e70db4ull, za_smooth_anim_policy_main, "za_smooth_anim_policy_main");
    hle_override(0x7001e70f04ull, za_smooth_anim_policy_main2, "za_smooth_anim_policy_main2");
    hle_override(0x70029019f8ull, za_smooth_anim_policy_world, "za_smooth_anim_policy_world");
    hle_override(0x7002901a54ull, za_smooth_anim_policy_world2, "za_smooth_anim_policy_world2");
}
