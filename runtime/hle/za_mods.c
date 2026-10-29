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
    return on("FXAA", ENV("LARECOMP_FXAA"), g_settings.fxaa, &logged) ? param : 0;
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
void rt_za_npc_capacity(void) {
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
