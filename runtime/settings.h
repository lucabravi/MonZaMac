// User settings (larecomp.ini next to the executable's working directory), edited from the in-game menu.
#pragma once
#include <stdbool.h>

enum { ASPECT_UNLOCKED = 0, ASPECT_ORIGINAL = 1 };
enum { RES_MATCH = 0, /* 1..8 = 1x..8x */ RES_DYNAMIC = 9, RES_Q75 = 10, RES_Q25 = 11, RES_Q50 = 12, RES_X15 = 13, RES_DYNAMIC_X15 = 14, RES_DYNAMIC_X1 = 15 };
// the dynamic modes: lowered while the GPU can't hold the frame rate (up to the screen, 1620p, 1080p)
static inline int res_is_dynamic(int m) { return m == RES_DYNAMIC || m == RES_DYNAMIC_X15 || m == RES_DYNAMIC_X1; }
// (11 was 67% of the display: larecomp.ini "67%" now loads as RES_Q75)
enum { UPSCALE_BILINEAR = 0, UPSCALE_METALFX = 1 /* macOS */, UPSCALE_FSR1 = 2 /* Windows: AMD FSR 1 */ };
#ifdef __APPLE__
#define UPSCALE_SHARP UPSCALE_METALFX  // each OS's non-bilinear upscaler (the default)
#else
#define UPSCALE_SHARP UPSCALE_FSR1
#endif
enum { AA_OFF = 0, AA_SMAA = 1 };
enum { PROMPTS_AUTO = 0, PROMPTS_NINTENDO = 1, PROMPTS_XBOX = 2, PROMPTS_PLAYSTATION = 3, PROMPTS_KEYBOARD = 4 };  // (keyboard: Pokémon Z-A's font glyphs, runtime/hle/pl.c)
// System language served to the game (runtime/services/am.c GetDesiredLanguage, services/hid_set.c GetLanguageCode):
// the game picks its text language from it, as it would from the Switch's own system setting. LANG_AUTO follows the
// host locale ($LC_ALL / $LC_MESSAGES / $LANG); the rest are the codes of the languages the game has text for.
enum { LANG_AUTO = 0, N_LANGUAGES = 12 };
extern const char *const g_language_codes[N_LANGUAGES];  // what the game is told: "ja", "en-US", "es", ...
extern const char *const g_language_names[N_LANGUAGES];  // for the menu ("Auto", "Japanese", ..., "Spanish")

enum { MOUSE_CAM_OFF, MOUSE_CAM_HOLD /* while a button is held */, MOUSE_CAM_ALWAYS /* cursor held in the window */ };
enum { MOUSE_BTN_RIGHT, MOUSE_BTN_LEFT, MOUSE_BTN_MIDDLE, MOUSE_BTN_ANY };

typedef struct {
    int aspect;          // ASPECT_*: unlocked = fill the window (wider/taller views), original = 16:9 with bars
    bool fullscreen;
    int res_mode;        // RES_MATCH, 1..4 (N x the Switch's 1080p), RES_X15, RES_Q75/50/25 (share of the display), dynamic: res_is_dynamic
    int upscaler;        // UPSCALE_*: how a lower internal resolution reaches the window (MetalFX: macOS, FSR 1: Windows)
    int antialias;       // AA_*: anti-aliasing of the game image before it is scaled to the window
    float volume;        // master volume, 1 = 100%
    bool reverb;         // room reverb effect
    bool movie_audio;
    bool show_fps;
    bool handheld;       // Pokémon Z-A: the game is told it runs handheld (720p, lighter settings), not docked (runtime/services/am.c)
    bool fps60;  // Pokémon Z-A: 60 fps with a dynamic world step down to 30 fps (runtime/hle/framepace.c)
    bool developer;      // the Developer tab of the menu is shown (ini "developer = 1", LARECOMP_DEVELOPER, Cmd+Shift+D)
    bool dev_gpu_trace;  // Developer: the GPU time per present window in the log (LARECOMP_GPU_TIMING_TRACE adds a line per command buffer)
    bool dev_uncapped_fps; // Developer benchmark only: presentation uncapped, gameplay timing may be incorrect
    bool dev_frame_stats;  // Developer: CPU submit time and GPU busy time per frame on the F3 overlay
    bool xfb_barrier;    // on by default (Developer tab): the render pass stays open after GPU skinning (a buffer barrier instead of ending it; LARECOMP_XFB_END_BARRIER=0/1 overrides)
    bool gpu_overlap;    // on by default (Developer tab): the game's frame fence is waited one frame late, so its CPU work on frame N+1 overlaps the GPU's frame N (runtime/nvn/renderer.m)
    bool prepare_shaders; // optional catalog-based preparation before first graphics use
    bool wait_shaders;   // compile a new shader or pipeline when the game first needs it and wait for it (else its draws are skipped meanwhile)
    bool game_drs;       // Pokémon Z-A: the game's own dynamic resolution may react to the GPU time it is told (runtime/nvn/renderer.m)
    bool dof;            // Pokémon Z-A: its depth of field blur (runtime/hle/za_mods.c)
    bool fxaa;           // Pokémon Z-A: its own FXAA anti-aliasing
    bool bloom;          // Pokémon Z-A: its bloom (glow around bright light)
    bool fov;            // Pokémon Z-A: a wider field of view (runtime/hle/za_mods.c rt_za_fov)
    bool lod;            // Pokémon Z-A: 8x anisotropic filtering and LOD bias -1.0 (the bias needs macOS 26) (rt_za_lod)
    bool shadows_4k;     // Pokémon Z-A: 4096 shadow map, only with LARECOMP_SHADOWS_4K=1 (rt_za_shadows_4k): no menu entry or ini key any more, see shadow_res
    int shadow_res;      // 1-4: the shadow maps are drawn at that many times the game's size, from the next start (runtime/nvn/metal.m)
    int shadow_sharp;    // 1-4: the game's shadow filter that many times narrower, up to shadow_res (runtime/nvn/renderer.m)
    bool dpad_move;      // the d-pad (and arrow keys) move like the stick
    float mouse_speed;   // the mouse's camera speed, 1 = the default (runtime/hle/input.c)
    int mouse_camera;        // MOUSE_CAM_*: when the mouse turns the camera (runtime/hle/input.c)
    int mouse_camera_button; // MOUSE_BTN_*: the button held for MOUSE_CAM_HOLD
    bool trackpad_camera;    // two fingers on the trackpad turn the camera (its scroll events)
    bool invert_mouse_x, invert_mouse_y;  // the camera's direction, per axis (mouse and trackpad)
    int rstick_snap;     // degrees: a right stick this close to an axis is held on it (0 = off; runtime/hle/input.c)
    bool mirror_mode;    // the world mirrored left to right (Gameplay tab): renderers + runtime/hle/input.c
    int language;        // LANG_AUTO or an index into g_language_codes: the game's text language
    int prompts;         // PROMPTS_*: button glyphs (auto = follow the controller SDL reports): runtime/nvn/texpatch.c
    bool aspect_asked;   // the start screen's one-time "authentic 16:9 or unlocked?" question was answered
    bool menu_tip_seen;  // the start screen's one-time "how to open the menu" note was shown (first PLAY ever)
    char save_slot[41];  // (SAVE_NAME_MAX + 1) the save slot played last (its id; empty = the original `save/`)
} Settings;


extern Settings g_settings;

void settings_load(void);
void settings_save(void);
bool settings_uncapped_fps(void); // LARECOMP_UNCAPPED_FPS overrides the Developer toggle
// The language code to serve the game ("es", "en-US", ...): the setting, or the host locale for LANG_AUTO
const char *settings_language(void);
// That code's name for the menu ("Spanish")
const char *settings_language_name(void);
