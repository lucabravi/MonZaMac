// In-game overlay menu built with Dear ImGui (Metal renderer on macOS, Vulkan elsewhere; input fed from SDL events).
//
// Threads: SDL events arrive on the main thread and are queued; the menu is laid out and drawn on the
// render thread inside backend_present, after the game image, into the same drawable.
#ifdef __APPLE__
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#include <SDL3/SDL.h>
#include <math.h>
#include <pthread.h>
#include <atomic>
#include <vector>
#include <string>

#include "imgui.h"
#include "option_rows.h"
#include "imgui_internal.h"  // (NavCursorVisible)
#include "osk.h"
#include "../services/am.h"
#ifdef __APPLE__
#include "imgui_impl_metal.h"
extern "C" void renderer_profile_pass_end(const char *reason);
#else
#include "imgui_impl_vulkan.h"
extern "C" bool vk_imgui_backend_init(void);  // runtime/nvn/vulkan/imgui_glue.cpp
#endif

extern "C" {
#include "../hle.h"
#include "../settings.h"
#include "menu.h"
#include "../nvn/output_scale.h"
void input_reset(void);
void controls_bindings_draw(float scale);  // controls_ui.mm
#include "../input_bind.h"
#include "../paths.h"
extern "C" SDL_Window *ui_window(void);  // (runtime/nvn/metal.m)
}

// ------------------------------------------------------------------ state shared with the main thread
static std::atomic<bool> g_open{false};
static std::atomic<bool> g_stats{false};  // F3: fps and the render resolution on screen, for this run (not saved)
static std::atomic<bool> g_text_busy{false};  // a text field / the on-screen keyboard has the keys (render thread: ui_text_busy)
static std::atomic<bool> g_want_fullscreen_apply{false};

#ifdef __APPLE__
extern "C" unsigned renderer_recipe_count(void);
extern "C" bool renderer_export_recipes(const char *, char *, size_t);
static std::atomic<bool> g_recipe_export_request{false}, g_recipe_export_busy{false};
static pthread_mutex_t recipe_message_lock = PTHREAD_MUTEX_INITIALIZER;
static char recipe_export_message[320];
static void recipe_export_dialog(void) {  // main thread; the game never uploads this file
    if (g_recipe_export_busy.exchange(true)) return;
    input_reset();
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export shader recipes";
    panel.message = @"Only shader hashes and numeric graphics state. No game code, keys, saves or personal information. Nothing is uploaded automatically.";
    panel.prompt = @"Export";
    panel.allowedContentTypes = @[ UTTypeJSON ];
    panel.nameFieldStringValue = @"MonZaMac-shader-recipes.json";
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) { g_recipe_export_busy = false; return; }
        NSURL *destination = panel.URL;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool {
            char error[256] = {0};
            bool ok = renderer_export_recipes(destination.fileSystemRepresentation, error, sizeof error);
            pthread_mutex_lock(&recipe_message_lock);
            if (ok) snprintf(recipe_export_message, sizeof recipe_export_message, "Exported %s. Nothing was uploaded.", destination.lastPathComponent.UTF8String);
            else snprintf(recipe_export_message, sizeof recipe_export_message, "%s", error);
            pthread_mutex_unlock(&recipe_message_lock);
            g_recipe_export_busy = false;
        }});
    }];
}
#endif

struct QEvent {
    enum { KEY, ANALOG, MOUSE_POS, MOUSE_BUTTON, WHEEL, TEXT } kind;
    ImGuiKey key;
    bool down;
    float value, x, y;
    int button;
    char text[32];
};
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<QEvent> q_events;
static float g_pixel_density = 1;

static void push(const QEvent &e) {
    pthread_mutex_lock(&q_lock);
    q_events.push_back(e);
    pthread_mutex_unlock(&q_lock);
}

bool menu_is_open(void) { return g_open.load(); }
static void set_open(bool open);
extern "C" void menu_test_open(void) {
    set_open(true);
    if (getenv("LARECOMP_MENU_TAB")) { extern int g_tab_request_ext; g_tab_request_ext = atoi(getenv("LARECOMP_MENU_TAB")); }
}

void menu_tabs_focus(bool first_tab);
static void set_open(bool open) {
    if (open == g_open.load()) return;
    g_open.store(open);
    input_reset();  // nothing held while the menu had focus leaks into the game
    bind_capture_cancel();
    if (open) {
        static bool opened;  // the controller's cursor: the first tab (Controls) the first time this session, later the
        menu_tabs_focus(!opened);  // selected one
        opened = true;
    }
    else { settings_save(); osk_cancel(); g_text_busy = false; }
}

static ImGuiKey key_from_scancode(SDL_Scancode sc) {
    switch (sc) {
    case SDL_SCANCODE_UP: return ImGuiKey_UpArrow;
    case SDL_SCANCODE_DOWN: return ImGuiKey_DownArrow;
    case SDL_SCANCODE_LEFT: return ImGuiKey_LeftArrow;
    case SDL_SCANCODE_RIGHT: return ImGuiKey_RightArrow;
    case SDL_SCANCODE_RETURN: return ImGuiKey_Enter;
    case SDL_SCANCODE_KP_ENTER: return ImGuiKey_KeypadEnter;
    case SDL_SCANCODE_SPACE: return ImGuiKey_Space;
    case SDL_SCANCODE_TAB: return ImGuiKey_Tab;
    case SDL_SCANCODE_BACKSPACE: return ImGuiKey_Backspace;
    case SDL_SCANCODE_DELETE: return ImGuiKey_Delete;
    case SDL_SCANCODE_HOME: return ImGuiKey_Home;
    case SDL_SCANCODE_END: return ImGuiKey_End;
    case SDL_SCANCODE_PAGEUP: return ImGuiKey_PageUp;
    case SDL_SCANCODE_PAGEDOWN: return ImGuiKey_PageDown;
    case SDL_SCANCODE_LSHIFT: return ImGuiKey_LeftShift;
    case SDL_SCANCODE_RSHIFT: return ImGuiKey_RightShift;
    case SDL_SCANCODE_LCTRL: return ImGuiKey_LeftCtrl;
    case SDL_SCANCODE_RCTRL: return ImGuiKey_RightCtrl;
    case SDL_SCANCODE_LGUI: return ImGuiKey_LeftSuper;
    case SDL_SCANCODE_RGUI: return ImGuiKey_RightSuper;
    case SDL_SCANCODE_A: return ImGuiKey_A;
    case SDL_SCANCODE_C: return ImGuiKey_C;
    case SDL_SCANCODE_V: return ImGuiKey_V;
    case SDL_SCANCODE_X: return ImGuiKey_X;
    case SDL_SCANCODE_Z: return ImGuiKey_Z;
    case SDL_SCANCODE_Q: return ImGuiKey_Q;  // previous tab
    case SDL_SCANCODE_E: return ImGuiKey_E;  // next tab
    default: return ImGuiKey_None;
    }
}

// Nintendo layout: the right face button (A) confirms, the bottom one (B) goes back.
static ImGuiKey key_from_pad(Uint8 b) {
    switch (b) {
    case SDL_GAMEPAD_BUTTON_EAST: return ImGuiKey_GamepadFaceDown;   // activate
    case SDL_GAMEPAD_BUTTON_SOUTH: return ImGuiKey_GamepadFaceRight; // cancel / back
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    case SDL_GAMEPAD_BUTTON_START: return ImGuiKey_GamepadStart;
    case SDL_GAMEPAD_BUTTON_BACK: return ImGuiKey_GamepadBack;
    default: return ImGuiKey_None;
    }
}

// ---- software keyboard (runtime/hle/swkbd.c: the game's name entry etc.) --------------------------------------
// The game thread waits in menu_keyboard_run (re-presenting the last frame); this dialog takes the text: typed
// directly when the player last used a keyboard, an on-screen keyboard (d-pad + A, B deletes, Start / + OK) when
// they last used a controller.
static std::atomic<int> g_kbd{0};  // 1 open, 2 confirmed, 3 cancelled
static std::atomic<bool> g_kbd_enter{false};  // Enter pressed: confirmed by the render thread once the typed text is in the field
static std::atomic<bool> g_last_pad{false};
static char g_kbd_text[96];
static int g_kbd_max = 8;
static bool capturing() { return g_open.load() || g_kbd.load() == 1; }
// The game gets no input while this is true (runtime/hle/input.c): menu or name entry up.
extern "C" bool menu_input_captured(void) { return capturing(); }

bool menu_handle_event(const SDL_Event *e) {
    static bool back_down, start_down;
    if (g_open.load() && bind_capture_event(e)) return true;  // Controls tab waiting for a new binding: it takes the press
    if (e->type == SDL_EVENT_KEY_DOWN) g_last_pad = false;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) g_last_pad = true;
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat) {  // Enter confirms, Esc cancels
        // (not g_kbd = 2 here: the characters typed just before are still queued for the render thread, and the game
        // thread would read the name without them - the last letters of a typed name were lost while frames were slow)
        if (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER) { g_kbd_enter = true; return true; }
        if (e->key.scancode == SDL_SCANCODE_ESCAPE) { g_kbd = 3; return true; }
    }
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e->gbutton.button == SDL_GAMEPAD_BUTTON_START) {
        g_kbd = 2;
        return true;
    }
    // typing (a text field, the on-screen keyboard, the name entry): keys are text, not menu shortcuts
    bool typing = g_kbd.load() == 1 || (g_open.load() && g_text_busy.load());
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN:
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F1 ||
                               (e->key.scancode == SDL_SCANCODE_ESCAPE && !g_open.load()))) {
            if (!typing) set_open(!g_open.load());  // (Esc with the menu open goes to ImGui below: it cancels a field)
            return true;
        }
        if (!e->key.repeat && e->key.scancode == SDL_SCANCODE_D && (e->key.mod & SDL_KMOD_GUI) && (e->key.mod & SDL_KMOD_SHIFT)) {
            g_settings.developer = !g_settings.developer;  // Cmd+Shift+D: the Developer tab
            settings_save();
            return true;
        }
        if (!e->key.repeat && e->key.scancode == SDL_SCANCODE_F3) {
            g_stats = !g_stats.load();
            return true;
        }
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F11 ||
                               (e->key.scancode == SDL_SCANCODE_RETURN && (e->key.mod & (SDL_KMOD_ALT | SDL_KMOD_GUI))) ||
                               (e->key.scancode == SDL_SCANCODE_F && (e->key.mod & SDL_KMOD_GUI) && (e->key.mod & SDL_KMOD_CTRL)))) {
            g_settings.fullscreen = !g_settings.fullscreen;
            g_want_fullscreen_apply.store(true);
            settings_save();
            return true;
        }
        extern bool g_za_frame_hook;
        if (!e->key.repeat && g_za_frame_hook && e->key.scancode == SDL_SCANCODE_H && (e->key.mod & SDL_KMOD_GUI) &&
            (e->key.mod & SDL_KMOD_CTRL)) {  // Cmd+Ctrl+H: docked <-> handheld
            am_set_handheld(!g_settings.handheld);
            settings_save();
            return true;
        }
        /* fallthrough */
    case SDL_EVENT_KEY_UP: {
        if (!capturing()) return false;
        bool down = e->type == SDL_EVENT_KEY_DOWN;
        if (down && e->key.scancode == SDL_SCANCODE_ESCAPE) {  // Esc: back out of popups, else close
            QEvent q = {};
            q.kind = QEvent::KEY; q.key = ImGuiKey_Escape; q.down = true; push(q);
            q.down = false; push(q);
            return true;
        }
        ImGuiKey k = key_from_scancode(e->key.scancode);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_TEXT_INPUT:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::TEXT; strlcpy(q.text, e->text.text, sizeof q.text); push(q); }
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        bool down = e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_BACK) back_down = down;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_START) start_down = down;
        if (down && !typing && ((back_down && start_down) || e->gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE)) {
            set_open(!g_open.load());
            return true;
        }
        if (!capturing()) return false;
        ImGuiKey k = key_from_pad(e->gbutton.button);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        if (!capturing()) return false;
        float v = e->gaxis.value / 32767.0f;
        QEvent q = {};
        q.kind = QEvent::ANALOG;
        switch (e->gaxis.axis) {
        case SDL_GAMEPAD_AXIS_LEFTX:
            q.key = ImGuiKey_GamepadLStickLeft; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickRight; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFTY:
            q.key = ImGuiKey_GamepadLStickUp; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickDown; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFT_TRIGGER: q.key = ImGuiKey_GamepadL2; q.value = v; push(q); break;
        case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: q.key = ImGuiKey_GamepadR2; q.value = v; push(q); break;
        default: break;
        }
        return true;
    }
    case SDL_EVENT_MOUSE_MOTION:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::MOUSE_POS; q.x = e->motion.x * g_pixel_density; q.y = e->motion.y * g_pixel_density; push(q); }
        return true;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!capturing()) return false;
        {
            QEvent q = {};
            q.kind = QEvent::MOUSE_BUTTON;
            q.button = e->button.button == SDL_BUTTON_LEFT ? 0 : e->button.button == SDL_BUTTON_RIGHT ? 1 : 2;
            q.down = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
            push(q);
        }
        return true;
    case SDL_EVENT_MOUSE_WHEEL:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::WHEEL; q.x = e->wheel.x; q.y = e->wheel.y; push(q); }
        return true;
    default:
        return false;
    }
}

void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
#ifdef __APPLE__
    if (g_recipe_export_request.exchange(false)) recipe_export_dialog();
#endif
    g_pixel_density = SDL_GetWindowPixelDensity(w);
    static bool text_input;
    bool want_text = capturing();
    if (want_text != text_input) {
        if (want_text) SDL_StartTextInput(w);
        else SDL_StopTextInput(w);
        text_input = want_text;
    }
    static bool first = true;
    if (first || g_want_fullscreen_apply.exchange(false)) {
        first = false;
        SDL_SetWindowFullscreen(w, g_settings.fullscreen);
    }
}

// ------------------------------------------------------------------ render thread
static bool g_inited;
static ImGuiContext *g_ctx;  // ours: the start screen (back to it after a reboot) has its own context
static ImFont *g_font, *g_font_big;
static ImFont *g_menu_font, *g_menu_font_big;  // the menu window (Baloo 2); everything else keeps g_font
static int g_tab_request_next = -2;  // (set while the tab bar is drawn: the tab the cursor moved onto)
static int g_tab, g_tab_request = -2;  // (-2: no request; -1 is the Prelaunch tab)
static int g_focus_tab = -99;  // put the nav cursor on this tab next frame (-100: the selected one; -99: none)
static int g_focus_frames;

// The start screen's Settings opening: the controller's cursor starts on the first tab the first time in a session,
// later on the tab that's selected
void menu_tabs_focus(bool first_tab) { g_focus_tab = first_tab ? -1 : -100, g_focus_frames = 0; }
int g_tab_request_ext = -1;

static void style_init(void) {
    ImGuiStyle &s = ImGui::GetStyle();
    ImGui::StyleColorsDark();
    s.WindowRounding = 14; s.FrameRounding = 8; s.GrabRounding = 8; s.TabRounding = 8; s.ChildRounding = 10;
    s.WindowPadding = ImVec2(28, 24); s.FramePadding = ImVec2(14, 8); s.ItemSpacing = ImVec2(14, 12);
    s.WindowBorderSize = 0; s.ScrollbarSize = 18;
    ImVec4 *c = s.Colors;
    ImVec4 gold(0.28f, 0.84f, 1.0f, 1), gold_dim(0.16f, 0.46f, 0.58f, 1), green(0.10f, 0.25f, 0.45f, 1);  // (the accent, kept under its old names)
    c[ImGuiCol_WindowBg] = ImVec4(0.04f, 0.07f, 0.14f, 0.94f);
    c[ImGuiCol_ChildBg] = ImVec4(0.06f, 0.11f, 0.20f, 0.85f);
    c[ImGuiCol_PopupBg] = ImVec4(0.05f, 0.08f, 0.16f, 0.98f);
    c[ImGuiCol_Text] = ImVec4(0.95f, 0.97f, 1.0f, 1);
    c[ImGuiCol_TextDisabled] = ImVec4(0.58f, 0.64f, 0.74f, 1);
    c[ImGuiCol_FrameBg] = ImVec4(0.09f, 0.16f, 0.28f, 1);
    c[ImGuiCol_FrameBgHovered] = green;
    c[ImGuiCol_FrameBgActive] = ImVec4(0.14f, 0.34f, 0.58f, 1);
    c[ImGuiCol_Button] = ImVec4(0.10f, 0.18f, 0.32f, 1);
    c[ImGuiCol_ButtonHovered] = green;
    c[ImGuiCol_ButtonActive] = ImVec4(0.16f, 0.38f, 0.64f, 1);
    c[ImGuiCol_Header] = green;
    c[ImGuiCol_HeaderHovered] = ImVec4(0.14f, 0.34f, 0.58f, 1);
    c[ImGuiCol_HeaderActive] = ImVec4(0.16f, 0.38f, 0.64f, 1);
    c[ImGuiCol_Tab] = ImVec4(0.08f, 0.14f, 0.26f, 1);
    c[ImGuiCol_TabHovered] = green;
    c[ImGuiCol_TabSelected] = ImVec4(0.14f, 0.34f, 0.56f, 1);
    c[ImGuiCol_TabSelectedOverline] = gold;
    c[ImGuiCol_CheckMark] = gold;
    c[ImGuiCol_SliderGrab] = gold_dim;
    c[ImGuiCol_SliderGrabActive] = gold;
    c[ImGuiCol_NavCursor] = gold;
    c[ImGuiCol_Separator] = ImVec4(0.22f, 0.32f, 0.48f, 1);
    c[ImGuiCol_TitleBg] = c[ImGuiCol_TitleBgActive] = c[ImGuiCol_WindowBg];
}


#ifdef __APPLE__
static void init(id<MTLDevice> dev) {
#else
static void init(void) {
#endif
    IMGUI_CHECKVERSION();
    g_ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    io.IniFilename = NULL;
    ImFontConfig cfg;
    cfg.OversampleH = 2;
    const char *paths[] = {"/System/Library/Fonts/Avenir Next.ttc", "/System/Library/Fonts/Helvetica.ttc",
                           "C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                           "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"};
    for (const char *p : paths) {
        if (FILE *f = fopen(p, "rb")) fclose(f);  // a missing file is an assertion in ImGui, not a NULL return
        else continue;
        if (!g_font) g_font = io.Fonts->AddFontFromFileTTF(p, 34, &cfg);
        if (g_font && !g_font_big) { ImFontConfig b = cfg; b.FontNo = 0; g_font_big = io.Fonts->AddFontFromFileTTF(p, 56, &b); }
    }
    // the menu window itself: Baloo 2 SemiBold, as on the start screen (shipped, OFL), at its Settings window's sizes; the
    // FPS counter, overlays and on-screen keyboard keep the fonts above
    char baloo[1024];
    if (const char *f = getenv("LARECOMP_MENU_FONT")) strlcpy(baloo, f, sizeof baloo);  // (test) another weight / face
    if (getenv("LARECOMP_MENU_FONT") || rt_resource("Baloo2-SemiBold.ttf", "third_party/fonts/Baloo2/Baloo2-SemiBold.ttf", baloo, sizeof baloo)) {
        g_menu_font = io.Fonts->AddFontFromFileTTF(baloo, 33, &cfg);
        g_menu_font_big = io.Fonts->AddFontFromFileTTF(baloo, 54, &cfg);
    }
    if (!g_font) g_font = io.Fonts->AddFontDefault();
    if (!g_font_big) g_font_big = g_font;
    if (!g_menu_font || !g_menu_font_big) g_menu_font = g_font, g_menu_font_big = g_font_big;
    style_init();
#ifdef __APPLE__
    ImGui_ImplMetal_Init(dev);
#else
    vk_imgui_backend_init();
#endif
    g_inited = true;
}

static void drain_events(ImGuiIO &io) {
    pthread_mutex_lock(&q_lock);
    std::vector<QEvent> ev;
    ev.swap(q_events);
    pthread_mutex_unlock(&q_lock);
    for (const QEvent &q : ev) {
        switch (q.kind) {
        case QEvent::KEY: io.AddKeyEvent(q.key, q.down); break;
        case QEvent::ANALOG: io.AddKeyAnalogEvent(q.key, q.value > 0.1f, q.value); break;
        case QEvent::MOUSE_POS: io.AddMousePosEvent(q.x, q.y); break;
        case QEvent::MOUSE_BUTTON: io.AddMouseButtonEvent(q.button, q.down); break;
        case QEvent::WHEEL: io.AddMouseWheelEvent(q.x, q.y); break;
        case QEvent::TEXT: io.AddInputCharactersUTF8(q.text); break;
        }
    }
}

// Section header in the big font.
static void header(const char *t) {
    ImGui::PushFont(g_font_big);
    ImGui::TextColored(ImVec4(0.28f, 0.84f, 1.0f, 1), "%s", t);
    ImGui::PopFont();
    ImGui::Separator();
    ImGui::Spacing();
}

static void hint(const char *t) {
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", t);
    ImGui::PopTextWrapPos();
}

// A row with a label on the left and a choice of options on the right (dpad left/right cycles).
// reserve: room kept free right of the combo (a button on the same line)
static bool choice(const char *label, int *value, const char *const *names, int n, float reserve = 0) {
    ImGui::PushID(label);
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(label);
    ImGui::SameLine(ImGui::GetContentRegionAvail().x * 0.45f);
    bool changed = false;
    ImGui::SetNextItemWidth(reserve > 0 ? -reserve : -1);
    if (ImGui::BeginCombo("##c", names[*value])) {
        for (int i = 0; i < n; i++) {
            if (ImGui::Selectable(names[i], i == *value)) { *value = i; changed = true; }
            if (i == *value) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    if (ImGui::IsItemFocused() && !ImGui::IsPopupOpen("##c")) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
            *value = (*value + 1) % n; changed = true;
        }
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
            *value = (*value + n - 1) % n; changed = true;
        }
    }
    ImGui::PopID();
    return changed;
}

static bool toggle(const char *label, bool *v) {
    const char *names[] = {"Off", "On"};
    int i = *v;
    bool ch = choice(label, &i, names, 2);
    *v = i;
    return ch;
}

extern "C" void renderer_get_scale(float *sx, float *sy);
extern "C" const char *rt_version_label(void);  // launcher.mm: "0.1.1"
extern "C" int input_pad_family(void);  // runtime/hle/input.c

extern "C" int g_start_screen;  // runtime/ui/launcher.mm
// The Z-A-only rows: while the game runs, and on the start screen (this app plays nothing else: they were missing there)
static bool za_rows(void) {
    extern bool g_za_frame_hook;
    return g_za_frame_hook || g_start_screen;
}

static void tab_display(void) {
    float scale = ImGui::GetFontSize() / 34;
    opt_begin("##video", scale);
    opt_section("Display");
    const char *aspects[] = {"Unlocked", "Original 16:9"};
    opt_choice("Aspect ratio", &g_settings.aspect, aspects, 2, ASPECT_ORIGINAL,
               "Unlocked: the view fills the window, so wider (or taller) windows show more of the world - up to "
               "ultrawide. Original 16:9: the game's own framing, with bars.");
    bool fs = g_settings.fullscreen;
    if (opt_toggle("Fullscreen", &fs, false, "Fills the screen. Also: F11, Alt+Enter or Cmd+Ctrl+F.")) {
        g_settings.fullscreen = fs;
        g_want_fullscreen_apply.store(true);
    }
    opt_toggle("Show FPS", &g_settings.show_fps, false, "Shows the frame rate in the top right corner. F3 does it for this run only, adding the render resolution.");
    {   // Pokémon Z-A's game mode (runtime/services/am.c): the mode the game is told it runs in
        if (za_rows()) {
            int gm = g_settings.handheld ? 1 : 0;
            static const char *modes[] = {"Docked (1080p)", "Handheld (720p)"};
            if (opt_choice("Game mode", &gm, modes, 2, 0,
                           "The mode the game believes it runs in. Handheld: it draws 720p with lighter effects, as on the "
                           "Switch's own screen - far less work for the GPU, for slower Macs. Docked: 1080p. Also Cmd+Ctrl+H. "
                           "If the picture does not follow at once, restart the game."))
                am_set_handheld(gm == 1);
        }
    }
    {   // Pokémon Z-A's frame mode (runtime/hle/framepace.c rt_za_frame_cfg): applies from the next frame
        if (za_rows()) {
            int fr = g_settings.fps60 ? 1 : 0;
            static const char *rates[] = {"30 fps (Switch)", "60 fps"};
            if (opt_choice("Frame rate", &fr, rates, 2, 0,
                           "30 fps: as on the Switch. 60 fps: smoother motion, with the world step adapting to the "
                           "time each frame takes to keep the game speed steady down to 30 fps. Needs a faster CPU."))
                g_settings.fps60 = fr == 1;
        }
    }

    opt_section("Rendering");
    // Two choices: Fixed or Dynamic, then the resolution - for Dynamic how far up it may go (it's lowered while the GPU
    // can't hold the frame rate). Display order -> RES_* (the ini / enum order predates the menu order).
    // (Fixed: Match display in the middle, left from it 75% / 50% / 25%, right 1x-4x; user 2026-10-11)
    // (the same names in both: lines of the game's image - 1080p docked, 720p handheld - N times, or the display's own)
    // (the same names in both: lines of the game's image - 1080p docked, 720p handheld - N times, or the display's own;
    // each list in order of lines, Match display and the shares of it where the window puts them)
    static char lines[5][16], up[2][24], match[32], up_match[40], share[3][24];
    int base = g_settings.handheld ? 720 : 1080;
    const double mul[5] = {1, 1.5, 2, 3, 4};
    for (int i = 0; i < 5; i++) snprintf(lines[i], sizeof lines[i], "%dp", (int)(base * mul[i]));
    for (int i = 0; i < 2; i++) snprintf(up[i], sizeof up[i], "Up to %s", lines[i]);
    int ww = 0, wh = 0;
    if (ui_window()) SDL_GetWindowSizeInPixels(ui_window(), &ww, &wh);
    int ml = ww > 0 && wh > 0 ? (int)lround(fmin(ww / 1920.0, wh / 1080.0) * 1080.0) : 0;  // (as output_scale: 16:9 fitted)
    const int pct[3] = {25, 50, 75};  // (of the game's own image)
    for (int i = 0; i < 3; i++) snprintf(share[i], sizeof share[i], "%dp (%d%%)", base * pct[i] / 100, pct[i]);
    if (ml) snprintf(match, sizeof match, "Match display (%dp)", ml), snprintf(up_match, sizeof up_match, "Up to match display (%dp)", ml);
    else snprintf(match, sizeof match, "Match display"), snprintf(up_match, sizeof up_match, "Up to match display");
    struct Res { const char *name; int mode, lines; };
    Res fr[] = {{share[0], RES_Q25, base / 4}, {share[1], RES_Q50, base / 2}, {share[2], RES_Q75, base * 3 / 4}, {match, RES_MATCH, ml},
                {lines[0], 1, base}, {lines[1], RES_X15, base * 3 / 2}, {lines[2], 2, base * 2}, {lines[3], 3, base * 3},
                {lines[4], 4, base * 4}};
    Res dr[] = {{up[0], RES_DYNAMIC_X1, base}, {up[1], RES_DYNAMIC_X15, base * 3 / 2}, {up_match, RES_DYNAMIC, ml}};
    enum { NFIXED = sizeof fr / sizeof fr[0], NDYN = sizeof dr / sizeof dr[0] };
    auto by_lines = [&](Res *r, int n) {  // (stable: equal lines keep the order above; no window yet: as listed)
        for (int a = 1; ml && a < n; a++)
            for (int b = a; b > 0 && r[b].lines < r[b - 1].lines; b--) std::swap(r[b], r[b - 1]);
    };
    by_lines(fr, NFIXED), by_lines(dr, NDYN);
    const char *fixed[NFIXED], *dyn[NDYN];
    int fixed_mode[NFIXED], dyn_mode[NDYN], fixed_def = 0, dyn_def = 0;
    for (int i = 0; i < NFIXED; i++) { fixed[i] = fr[i].name, fixed_mode[i] = fr[i].mode; if (fr[i].mode == 1) fixed_def = i; }
    for (int i = 0; i < NDYN; i++) { dyn[i] = dr[i].name, dyn_mode[i] = dr[i].mode; if (dr[i].mode == RES_DYNAMIC_X1) dyn_def = i; }
    {
        bool is_dyn = res_is_dynamic(g_settings.res_mode);
        float sx, sy;
        renderer_get_scale(&sx, &sy);
        char d[640];
        int n = snprintf(d, sizeof d, "Fixed: always the resolution you choose. Dynamic: as sharp as your GPU can draw while "
                                      "keeping the frame rate, lowered when it can't, up to the resolution you choose.\n\n"
                                      "Rendering at %.0f x %.0f.", 1920.0 * sx, 1080.0 * sy);
        if (is_dyn) snprintf(d + n, sizeof d - n, " Dynamic: %.0f%% of its top resolution right now.", output_scale_dynamic_factor() * 100);
        static const char *modes[] = {"Fixed", "Dynamic"};
        int mi = is_dyn;
        if (opt_choice("Resolution mode", &mi, modes, 2, 1, d, false) && mi != (int)is_dyn) {
            // the nearest of the other kind: Match display <-> this screen, 1x and below <-> 1080p, above <-> 1620p
            int m = g_settings.res_mode;
            if (mi) g_settings.res_mode = m == RES_MATCH ? RES_DYNAMIC : (m == 1 || m == RES_Q25 || m == RES_Q50 || m == RES_Q75) ? RES_DYNAMIC_X1 : RES_DYNAMIC_X15;
            else g_settings.res_mode = m == RES_DYNAMIC ? RES_MATCH : m == RES_DYNAMIC_X1 ? 1 : RES_X15;
            is_dyn = mi;
        }
        char d2[480];
        if (is_dyn) {
            snprintf(d2, sizeof d2, "The sharpest the dynamic resolution goes: the game's own %s, %s (1.5x), or your "
                                    "display's own resolution. It's lowered from there while your GPU can't keep the frame rate.",
                     lines[0], lines[1]);
            int ri = dyn_def;
            for (int i = 0; i < NDYN; i++) if (dyn_mode[i] == g_settings.res_mode) ri = i;
            if (opt_choice("Internal resolution", &ri, dyn, NDYN, dyn_def, d2, false)) g_settings.res_mode = dyn_mode[ri];
        } else {
            snprintf(d2, sizeof d2, "How sharp the 3D image is. Match display: your display's own resolution. %s: the game's "
                                    "own image (%s mode), %s-%s: 1.5x to 4x that. The percentages: a share of the game's own image, "
                                    "for slower Macs.", lines[0], g_settings.handheld ? "handheld" : "docked", lines[1], lines[4]);
            int ri = fixed_def;
            for (int i = 0; i < NFIXED; i++) if (fixed_mode[i] == g_settings.res_mode) ri = i;
            if (opt_choice("Internal resolution", &ri, fixed, NFIXED, fixed_def, d2, false)) g_settings.res_mode = fixed_mode[ri];
        }
    }
    {   // each OS's own upscaler next to bilinear (UPSCALE_SHARP: MetalFX on macOS, AMD FSR 1 on Windows)
#ifdef __APPLE__
        static const char *ups[] = {"Bilinear", "MetalFX"};
        const char *ud = "How the image is scaled up to the window when it renders at a lower resolution. MetalFX: Apple's "
                         "upscaler, sharper. Bilinear: plain and soft.";
#else
        static const char *ups[] = {"Bilinear", "AMD FSR 1"};
        const char *ud = "How the image is scaled up to the window when it renders at a lower resolution. AMD FSR 1: "
                         "edge-aware upscaling and sharpening, sharper. Bilinear: plain and soft.";
#endif
        int ui = g_settings.upscaler == UPSCALE_BILINEAR ? 0 : 1;
        char udm[512];
        if (g_settings.res_mode == RES_MATCH) {  // (renders at the window's size: nothing to scale up)
            snprintf(udm, sizeof udm, "%s\n\nNot used at Match display: the game already renders at your display's resolution.", ud);
            ud = udm;
            opt_disable_next();
        }
        if (opt_choice("Upscaler", &ui, ups, 2, 1, ud)) g_settings.upscaler = ui ? UPSCALE_SHARP : UPSCALE_BILINEAR;
    }
    static const char *aa[] = {"Off", "SMAA"};
    opt_choice("Anti-aliasing", &g_settings.antialias, aa, 2, AA_SMAA,
               "Smooths jagged edges of the game image before it is scaled to the window. SMAA: finds the edges and "
               "blends only along them, so textures stay sharp. Most useful at a lower internal resolution.");
    opt_toggle("Prepare known shaders", &g_settings.prepare_shaders, false,
               "Before starting, build the graphics pipelines in an installed shader catalog from your own game files. "
               "Reduces first-encounter stutter for covered effects. Takes extra time at startup; unseen variants still compile normally. "
               "Requires a compatible catalog. Changes apply on the next game start.");
#ifdef __APPLE__
    opt_toggle("Collect new shader recipes", &g_settings.collect_shader_recipes, true,
               "Locally records only new graphics pipeline recipes missing from the prepared catalog. Metadata is deduplicated "
               "and saved in the background; game code, keys and saves are not included. Nothing is uploaded. "
               "New shader programs are collected from the next game start.");
    unsigned recipes = renderer_recipe_count();
    char value[48]; snprintf(value, sizeof value, g_recipe_export_busy.load() ? "Exporting..." : "%u recipes", recipes);
    std::string description = "Save a metadata-only JSON contribution for manual review and sharing. "
                              "Export does not submit it anywhere. Recipes with unknown source locations still need investigation.";
    pthread_mutex_lock(&recipe_message_lock);
    if (*recipe_export_message) { description += "\n\n"; description += recipe_export_message; }
    pthread_mutex_unlock(&recipe_message_lock);
    if (!recipes || g_recipe_export_busy.load()) opt_disable_next();
    if (opt_action("Export shader recipes", value, description.c_str())) g_recipe_export_request = true;
#endif
    opt_toggle("Wait for shaders", &g_settings.wait_shaders, false,
               "A shader or pipeline the game needs for the first time is compiled on the spot, and the game waits: a short "
               "stutter, but nothing is missing from the picture. Off: it compiles in the background and the objects that "
               "need it are left out of the picture until it is ready (the pipelines saved from earlier runs are quick).");
    {   // Pokémon Z-A's own effects (runtime/hle/za_mods.c): the same patch build as the frame mode
        if (za_rows()) {
            opt_toggle("Game FXAA", &g_settings.fxaa, true,
                       "The game's own anti-aliasing, a light blur over the whole image. Off: sharper, with more jagged "
                       "edges (SMAA above can smooth them instead).");
            opt_toggle("Game dynamic resolution", &g_settings.game_drs, false,
                       "The game's own resolution scaling, which lowers the picture when it thinks the GPU is slow. Off: "
                       "it stays at full (a window in the background no longer makes it blurry for a while). Separate "
                       "from Internal resolution > Dynamic.");
            opt_toggle("Depth of field", &g_settings.dof, true,
                       "The game's blur of what is far from the camera's focus. Off: the whole view stays sharp.");
            opt_toggle("Bloom", &g_settings.bloom, true,
                       "The game's glow around bright light. Off: no glow, a plainer image.");
            opt_toggle("Wider view", &g_settings.fov, false,
                       "The camera's field of view a little wider: more of the scene at the sides. Off: the game's own.");
            opt_toggle("Sharper textures", &g_settings.lod, true,
                       "Textures stay sharp on ground and walls seen at a slant, and (macOS 26 or later) farther away too. "
                       "Off: the game's own.");
            {   // the shadow map's size (runtime/nvn/metal.m: taken at start) and its filter's width (runtime/nvn/renderer.m)
                static const char *sz[] = {"Game's", "2x", "3x", "4x"};
                int si = g_settings.shadow_res - 1;
                if (opt_choice("Shadow resolution", &si, sz, 4, 0,
                               "The size of the map the sun's shadows are drawn from (the game's: 1024 x 1024). Higher: "
                               "smoother shadow edges, without the stair steps, for a little GPU time and more GPU memory "
                               "(4x: about 240 MB, 2x: 60 MB). From the next start."))
                    g_settings.shadow_res = si + 1;
                int sh = g_settings.shadow_sharp - 1;
                if (g_settings.shadow_res == 1) opt_disable_next();  // (nothing to narrow at the game's size)
                if (opt_choice("Shadow sharpness", &sh, sz, 4, 0,
                               "How soft the edges of the sun's shadows are: the game's own blur, or 2-4 times narrower, "
                               "so sharper shadows. At most the shadow resolution (the blur is measured in the map's texels). "
                               "Changes at once."))
                    g_settings.shadow_sharp = sh + 1;
            }
        }
    }

    opt_end();
}

static void tab_audio(void) {
    opt_begin("##audio", ImGui::GetFontSize() / 34);
    opt_section("Sound");
    float pct = roundf(g_settings.volume * 100);
    if (opt_slider("Volume", &pct, 0, 200, 5, 100, "%g%%",
                   "The game's volume. 100% is the game's own level; above it, louder."))
        g_settings.volume = pct / 100.0f;
    opt_toggle("Room reverb", &g_settings.reverb, true,
               "The game's echo in caves, dungeons and big rooms.");
    opt_toggle("Movie audio", &g_settings.movie_audio, true,
               "Sound in the game's movies (the opening and the ending). Applies the next time a movie starts.");
    opt_end();
}

// Quit: back to the start screen (in game: the game reboots to it) or out to the desktop. Each asks first (progress
// since the last save is lost); B / Esc or Cancel backs out.
extern "C" void rt_request_reboot(int kind);  // runtime/main.c (RT_REBOOT_TITLE = 2: the start screen)
static void tab_quit(float scale, bool in_game) {
    static int ask;  // 0: the two choices; 1: start screen?; 2: desktop?
    if (ask && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
        ask = 0;
    const char *lost = in_game ? "\n\nProgress since your last save is lost." : "";
    char d1[200], d2[200];
    snprintf(d1, sizeof d1, "Leaves the game and goes back to the MonZaMac start screen.%s", lost);
    snprintf(d2, sizeof d2, "Closes MonZaMac.%s", lost);
    opt_begin("##quit", scale);
    opt_section("Quit");
    if (!ask) {
        if (!in_game) opt_disable_next();  // (already on it)
        if (opt_action("Quit to Start Screen", "", in_game ? d1 : "You're on the start screen.")) ask = 1;
        if (opt_action("Quit to Desktop", "", d2)) ask = 2;
    } else {
        if (opt_action(ask == 1 ? "Yes, quit to Start Screen" : "Yes, quit to Desktop", "", ask == 1 ? d1 : d2)) {
            settings_save();
            if (ask == 1) {
                rt_request_reboot(2);
                set_open(false);
            } else {
                SDL_Event q = {};
                q.type = SDL_EVENT_QUIT;
                SDL_PushEvent(&q);
            }
            ask = 0;
        }
        if (opt_action("Cancel", "", "Stays where you are.")) ask = 0;
    }
    opt_end();
}

// Developer: switches for diagnostics, shown with "developer = 1" in the ini (or LARECOMP_DEVELOPER=1, or Cmd+Shift+D).
// Each applies at once; LARECOMP_* variables still work and win where a feature has one.
static void tab_developer(void) {
    opt_begin("##developer", ImGui::GetFontSize() / 34);
    opt_section("Diagnostics");
    opt_toggle("Frame times in F3", &g_settings.dev_frame_stats, false,
               "Adds to the F3 overlay the time the CPU spends translating and submitting a frame's commands (the game's "
               "thread) and the time the GPU is busy per frame (smoothed). If the CPU number is close to the frame time, "
               "the CPU is the limit; if the GPU number is, the GPU is.");
    opt_toggle("GPU timing log", &g_settings.dev_gpu_trace, false,
               "Writes the GPU time of each frame's present window to the log, two lines per frame. For measuring. "
               "LARECOMP_GPU_TIMING_TRACE=1 also writes a line per command buffer (about 140 a frame).");
    opt_section("Experimental");
    opt_toggle("Uncapped FPS (benchmark)", &g_settings.dev_uncapped_fps, false,
               "For throughput measurements only. Removes frame pacing and display sync. Gameplay, animations and "
               "timers may run too fast. Turn off for normal play; this overrides the selected frame rate.");
    opt_toggle("CPU/GPU overlap", &g_settings.gpu_overlap, true,
               "The game waits for each frame's GPU work right after sending it, so the CPU and the GPU take turns. On: the "
               "wait is one frame late, so the CPU prepares the next frame while the GPU draws this one: a higher frame "
               "rate when CPU and GPU are both well used. Risk: the game may overwrite a frame's vertex data "
               "while the GPU still reads it (flicker or glitched geometry; none seen so far). Turn it off if anything looks "
               "wrong, and tell us where.");
    opt_toggle("Keep passes open after skinning", &g_settings.xfb_barrier, true,
               "The characters' skinning (transform feedback) used to end the GPU's render pass each time. On: the pass "
               "stays open and a barrier orders the data instead, about 1 ms less GPU time a frame in the tested scenes "
               "(4% at 1.5x, one test went from 38 to 42 fps). Applies at once. Risk: if the ordering is not enough, characters can "
               "look deformed or missing for a frame. Turn it off if anything looks wrong, and tell us where.");
    opt_section("Menu");
    opt_toggle("Show this tab", &g_settings.developer, false,
               "Off hides the Developer tab again (Cmd+Shift+D or \"developer = 1\" in larecomp.ini bring it back).");
    opt_end();
}

static void tab_about(void) {
    header("Movement");
    toggle("D-pad moves the character", &g_settings.dpad_move);
    hint("The d-pad and the arrow keys move like the left stick.");
    {
        float snap = (float)g_settings.rstick_snap;
        if (opt_slider("Right stick snap", &snap, 0, 20, 1, 0, "%g degrees",
                   "A right stick (or mouse camera) pointed within this many degrees of up, down, left or right is held exactly on that direction. 0: off."))
            g_settings.rstick_snap = (int)roundf(snap);
    }
    ImGui::Spacing();
    header("Mouse");
    {
        static const char *const cam[] = {"Off", "While holding a button", "Always (cursor held in the window)"};
        choice("Camera", &g_settings.mouse_camera, cam, 3);
        hint("While holding a button: the mouse turns the camera while the chosen button is held. Always: the camera "
             "follows the mouse all the time, and the cursor is held inside the window (the menus free it).");
    }
    if (g_settings.mouse_camera == MOUSE_CAM_HOLD) {
        static const char *const btn[] = {"Right button", "Left button", "Middle button", "Any button"};
        choice("Button to hold", &g_settings.mouse_camera_button, btn, 4);
    }
    toggle("Two-finger drag on the trackpad", &g_settings.trackpad_camera);
    hint("The trackpad's two-finger scroll turns the camera, as the mouse does.");
    ImGui::Checkbox("Invert horizontal", &g_settings.invert_mouse_x);
    ImGui::Checkbox("Invert vertical", &g_settings.invert_mouse_y);
    {
        float pct = roundf(g_settings.mouse_speed * 100);
        if (opt_slider("Mouse camera speed", &pct, 25, 300, 5, 100, "%g%%",
                   "How fast the mouse and the trackpad turn the camera. 100% is the default."))
            g_settings.mouse_speed = pct / 100.0f;
    }
    ImGui::Spacing();
    header("Button prompts");
    {
        static const char *const fam[] = {"Nintendo", "Xbox", "PlayStation"};
        char autol[64];
        snprintf(autol, sizeof autol, "Auto (%s)", fam[input_pad_family() % 3]);
        const char *names[] = {autol, "Nintendo", "Xbox", "PlayStation", "Keyboard"};  // (Keyboard: Z-A, from the next boot)
        choice("Button icons", &g_settings.prompts, names, 5);
    }
    ImGui::Spacing();
    header("System language");
    {
        // what the game is told the console's language is: its text follows this (runtime/settings.c)
        char autol[64];
        snprintf(autol, sizeof autol, "Auto (%s)", settings_language_name());
        const char *names[N_LANGUAGES];
        names[0] = autol;
        for (int i = 1; i < N_LANGUAGES; i++) names[i] = g_language_names[i];
        if (choice("Language", &g_settings.language, names, N_LANGUAGES)) settings_save();
    }
    hint("The game's text language, as its own system setting. Applies when the game restarts: Quit -> Title "
         "screen, then Play.");
    ImGui::Spacing();
    header("Controls");
    controls_bindings_draw(ImGui::GetFontSize() / 34);
    ImGui::Spacing();
    header("Menu");
    ImGui::TextUnformatted("Open / close this menu:  F1, Esc, the controller's Home / Xbox / PlayStation button, or Back + Start");
    ImGui::TextUnformatted("Switch tabs:  L / R  (Q / E)        Back:  B  (Esc)");
    ImGui::TextUnformatted("Fullscreen:  F11 / Alt+Enter");
}

// Reboot (runtime/main.c): the game is gone - menu and name dialog close; the ImGui context stays.
RT_ON_RESET(menu_reset) {
    set_open(false);
    g_kbd = 0;
    osk_cancel();
    pthread_mutex_lock(&q_lock);
    q_events.clear();
    pthread_mutex_unlock(&q_lock);
}

static void keyboard_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 120));
    float w = fminf(io.DisplaySize.x * 0.9f, 1100 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    ImGui::Begin("##kbd", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                    ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PushFont(g_font_big);
    ImGui::TextColored(ImVec4(0.28f, 0.84f, 1.0f, 1), "Enter your name");
    ImGui::PopFont();
    static bool was_open, was_pad;
    bool pad = g_last_pad.load(), appearing = !was_open || pad != was_pad;  // (switching device: focus the new one)
    was_open = true, was_pad = pad;
    if (!pad) {  // keyboard: type straight into the field
        if (appearing) ImGui::SetKeyboardFocusHere();
        ImGui::SetNextItemWidth(-1);
        ImGui::PushFont(g_font_big);
        ImGui::InputText("##name", g_kbd_text, (size_t)(g_kbd_max * 4 + 1 < (int)sizeof g_kbd_text ? g_kbd_max * 4 + 1 : sizeof g_kbd_text),
                         ImGuiInputTextFlags_CallbackCharFilter,
                         [](ImGuiInputTextCallbackData *d) -> int { return d->EventChar < 0x20 ? 1 : 0; });
        ImGui::PopFont();
        if ((int)strlen(g_kbd_text) > g_kbd_max) g_kbd_text[g_kbd_max] = 0;
        if (g_kbd_enter.load()) {  // confirm only once every queued character has reached the field
            pthread_mutex_lock(&q_lock);
            bool drained = q_events.empty();
            pthread_mutex_unlock(&q_lock);
            if (drained) { g_kbd_enter = false; g_kbd = 2; }
        }
        ImGui::TextDisabled("Enter  confirm      Esc  cancel      (%d / %d)", (int)strlen(g_kbd_text), g_kbd_max);
    } else {  // controller: on-screen keyboard (osk.mm, shared with our menus' text fields)
        int r = osk_keys(g_kbd_text, sizeof g_kbd_text, g_kbd_max, appearing, scale, g_font_big);
        if (r) g_kbd = r > 0 ? 2 : 3;  // (Start / + confirms in menu_handle_event too)
    }
    ImGui::End();
    if (g_kbd.load() != 1) was_open = false;
}

// Game thread (runtime/hle/swkbd.c): show the dialog, re-present the last frame until it's answered.
// Returns 1 confirmed (out = text, UTF-8), 0 cancelled.
extern "C" int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    extern void backend_represent(void);
    snprintf(g_kbd_text, sizeof g_kbd_text, "%s", initial ? initial : "");
    g_kbd_max = max_len > 0 && max_len < (int)sizeof g_kbd_text / 4 ? max_len : 8;
    input_reset();
    g_kbd_enter = false;
    g_kbd = 1;
    // (test) LARECOMP_KBD_AUTO=<text>: answer at once
    if (getenv("LARECOMP_KBD_AUTO")) { snprintf(g_kbd_text, sizeof g_kbd_text, "%s", getenv("LARECOMP_KBD_AUTO")); g_kbd = 2; }
    // Re-present only while the game itself doesn't: a game with its own render thread (Pokémon Z-A) keeps presenting
    // (its menu_render draws this dialog), and two threads in the backend at once break it (ImGui, Vulkan)
    extern uint64_t renderer_present_count(void);
    uint64_t seen = renderer_present_count(), quiet_since = SDL_GetTicks();
    while (g_kbd.load() == 1 && !g_rt_unwind) {  // ~60 Hz (a reboot cancels)
        uint64_t t0 = SDL_GetTicks();
        if (renderer_present_count() != seen) {
            seen = renderer_present_count();
            quiet_since = t0;
        } else if (t0 - quiet_since >= 250) {
            backend_represent();
            seen = renderer_present_count();
        }
        uint64_t dt = SDL_GetTicks() - t0;
        if (dt < 16) SDL_Delay((uint32_t)(16 - dt));
    }
    bool ok = g_kbd.load() == 2 && g_kbd_text[0];
    if (ok) snprintf(out, cap, "%s", g_kbd_text);
    g_kbd = 0;
    input_reset();
    return ok;
}

// The tab bar and its pages, into the current window: the in-game menu, and the start screen's Settings (in_game
// false: nothing of the game is loaded yet - the tabs that need it are greyed out; prelaunch: the start screen's own
// first tab, game files and fonts, drawn by launcher.mm).
static void tabs_body(float scale, bool in_game, void (*prelaunch)(float)) {
    // (id: the page; -1 = Prelaunch)
    struct Tab { const char *name; int id; bool on; };
    Tab tabs[8];
    int ntabs = 0;
    if (prelaunch) tabs[ntabs++] = {"Prelaunch", -1, true};
    static const char *names[] = {"Video", "Audio", "", "", "", "", "", "", "Controls", "Quit", "Developer", "Saves"};
    static const int order[] = {8, 0, 1, 11, 9};  // Controls, Video, Audio, Saves, Quit (ids stay: test hooks)
    for (int i : order)  // (Saves and Quit: in game only - the start screen has its own SAVES and QUIT)
        if ((i != 9 && i != 11) || !prelaunch) tabs[ntabs++] = {names[i], i, true};
    if (g_settings.developer || getenv("LARECOMP_DEVELOPER")) tabs[ntabs++] = {names[10], 10, true};
    int cur = 0;  // g_tab / g_tab_request hold ids
    for (int i = 0; i < ntabs; i++) if (tabs[i].id == g_tab) cur = i;
    if (!tabs[cur].on) cur = 0;
    // L/R (or Q/E) switch tabs, skipping greyed-out ones (not while typing: Q / E are letters then, and the on-screen
    // keyboard has the controller)
    if (g_tab_request_ext >= 0) { g_tab_request = g_tab_request_ext; g_tab_request_ext = -1; }
    bool any_popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId), typing = ui_text_busy();
    static int focused_tab = -99;  // the tab the controller's cursor is on (from the frame before; -99: none)
    if (!any_popup && !typing) {
        int step = ImGui::IsKeyPressed(ImGuiKey_GamepadR1, false) || ImGui::IsKeyPressed(ImGuiKey_E, false) ? 1
                 : ImGui::IsKeyPressed(ImGuiKey_GamepadL1, false) || ImGui::IsKeyPressed(ImGuiKey_Q, false) ? -1 : 0;
        if (step) {
            int i = cur;
            do i = (i + step + ntabs) % ntabs; while (!tabs[i].on);
            g_tab_request = tabs[i].id;
            // the cursor on the tab bar goes along (left behind, A on it switched straight back; user 2026-10-11)
            if (focused_tab != -99) g_focus_tab = tabs[i].id, g_focus_frames = 0;
        }
    }
    // Down with the cursor on the tab bar: the page's first row (option rows; other pages keep ImGui's own pick)
    bool down_from_tab = focused_tab != -99 && ImGui::GetCurrentContext()->NavCursorVisible && !any_popup &&
                         (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadDown) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickDown) ||
                          ImGui::IsKeyPressed(ImGuiKey_DownArrow));
    opt_focus_first(down_from_tab);
    if (ImGui::BeginTabBar("##tabs", ImGuiTabBarFlags_NoTabListScrollingButtons)) {
        for (int k = 0; k < ntabs; k++) {
            const Tab &t = tabs[k];
            ImGuiTabItemFlags f = g_tab_request == t.id && t.on ? ImGuiTabItemFlags_SetSelected : 0;
            char lbl[64];
            snprintf(lbl, sizeof lbl, prelaunch ? " %s " : "  %s  ", t.name);  // (ten tabs: tighter, so none is cut short)
            ImGui::BeginDisabled(!t.on);  // (out of the game: Save Editor, Warp, Cheats)
            // focus (controller / keyboard): the tab lights up a little with a gold bar along its bottom, instead of
            // ImGui's outline (it sits 4 px outside the tab and the tab bar's clipping could cut its top off on macOS)
            // (focused_tab: from the frame before - colours go in before the tab is drawn)
            bool lit = focused_tab == t.id && ImGui::GetCurrentContext()->NavCursorVisible;
            ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
            if (lit) {
                ImGui::PushStyleColor(ImGuiCol_Tab, ImVec4(0.12f, 0.20f, 0.34f, 1));
                ImGui::PushStyleColor(ImGuiCol_TabHovered, ImVec4(0.12f, 0.20f, 0.34f, 1));
            }
            if (g_focus_tab == -1 && !prelaunch) g_focus_tab = 8;  // (no Prelaunch in game: Controls, the first tab)
            bool focus_here = g_focus_tab == t.id || (g_focus_tab == -100 && t.id == g_tab);
            bool open = ImGui::BeginTabItem(lbl, NULL, f);
            ImGui::PopStyleColor(lit ? 3 : 1);
            if (focus_here) {  // the controller's cursor starts on this tab (SetKeyboardFocusHere skips tabs: no tab stop)
                ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
                ImGui::SetNavCursorVisible(true);
                // a few frames: the page's child window appearing makes ImGui pick its first widget once it's laid out
                if (++g_focus_frames >= 4) g_focus_tab = -99, g_focus_frames = 0;
                else g_focus_tab = t.id;
            }
            if (lit) {
                ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
                float h = 4 * scale > 2 ? 4 * scale : 2;
                ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(a.x + 2, b.y - h), ImVec2(b.x - 2, b.y),
                                                          IM_COL32(72, 214, 255, 255));  // (the menu's gold)
            }
            if (ImGui::IsItemFocused()) {
                focused_tab = t.id;
                // keyboard / controller: the cursor moving onto a tab opens it, as L/R do (the mouse still clicks)
                ImGuiContext &g = *ImGui::GetCurrentContext();
                if (t.on && t.id != g_tab && g.NavCursorVisible && g.NavInputSource != ImGuiInputSource_Mouse && !any_popup)
                    g_tab_request_next = t.id;
            }
            else if (focused_tab == t.id) focused_tab = -99;
            ImGui::EndDisabled();
            if (open) {
                g_tab = t.id;
                ImGui::Spacing();
                ImGui::BeginChild("##page", ImVec2(0, 0), ImGuiChildFlags_None,  // (the rest of the window: no hint line)
                                  ImGuiWindowFlags_NavFlattened);
                // Down from the tab bar, pages that aren't option rows (Prelaunch, Controls): their first control
                // (option-row pages: opt_focus_first)
                if (down_from_tab && (t.id == -1 || t.id == 8)) {
                    opt_focus_first(false);
                    ImGui::SetKeyboardFocusHere();
                    ImGui::SetNavCursorVisible(true);
                }
                switch (t.id) {
                case -1: prelaunch(scale); break;
                case 0: tab_display(); break;
                case 1: tab_audio(); break;
                case 8: tab_about(); break;
                case 9: tab_quit(scale, in_game); break;
                case 10: tab_developer(); break;
                case 11: {  // (true: the game restarts with another save)
                    bool saves_ingame_tab(float, ImFont *, ImFont *);
                    if (saves_ingame_tab(scale, g_font_big, g_font)) set_open(false);
                    break;
                }
                }
                static const char *scroll_test = getenv("LARECOMP_MENU_SCROLL");  // test hook: page scroll, 0..1
                if (scroll_test) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(scroll_test));
                ImGui::EndChild();
                ImGui::EndTabItem();
            }
        }
        g_tab_request = g_tab_request_next, g_tab_request_next = -2;
        opt_focus_first(false);  // (a page without option rows: nothing took it)
        ImGui::EndTabBar();
    }
}

void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float)) {
    ImFont *f0 = g_font, *f1 = g_font_big;
    g_font = font, g_font_big = font_big;
    ImGuiStyle saved = ImGui::GetStyle();  // the menu's look (the start screen has its own style)
    style_init();
    ImGui::GetStyle().ScaleAllSizes(scale);
    tabs_body(scale, in_game, prelaunch);
    ImGui::GetStyle() = saved;
    g_font = f0, g_font_big = f1;
}

#ifdef __APPLE__
void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    const double tw = target.width, th = target.height;
#else
void menu_render(void *cmd, uint32_t target_w, uint32_t target_h) {
    const double tw = target_w, th = target_h;
#endif
    bool open = g_open.load();
    bool kbd = g_kbd.load() == 1;
    if (!open && !kbd && !g_settings.show_fps && !g_stats.load()) {
        if (g_inited) { pthread_mutex_lock(&q_lock); q_events.clear(); pthread_mutex_unlock(&q_lock); }
        return;
    }
#ifdef __APPLE__
    if (!g_inited) init(dev);
#else
    if (!g_inited) init();
#endif
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tw, (float)th);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    static double last;
    double now = SDL_GetTicks() / 1000.0;
    io.DeltaTime = last > 0 && now > last ? (float)(now - last) : 1.0f / 60;
    last = now;
    drain_events(io);
    // fonts are built at 34/56 px for a ~1080 px tall output; scale to the window
    float scale = (float)(th / 1080.0);
    if (scale < 0.45f) scale = 0.45f;
    io.FontGlobalScale = scale;

#ifdef __APPLE__
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
#endif
    // spacing/rounding follow the output size too (style tuned for 1080 p)
    static ImGuiStyle base;
    static float style_scale = -1;
    if (style_scale < 0) base = ImGui::GetStyle();
    if (fabsf(style_scale - scale) > 0.01f) {
        ImGui::GetStyle() = base;
        ImGui::GetStyle().ScaleAllSizes(scale);
        style_scale = scale;
    }
#ifdef __APPLE__
    ImGui_ImplMetal_NewFrame(rp);
#else
    ImGui_ImplVulkan_NewFrame();
#endif
    ImGui::NewFrame();

    if (g_settings.show_fps || g_stats.load()) {
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 16 * scale, 16 * scale), 0, ImVec2(1, 0));
        ImGui::SetNextWindowBgAlpha(0.5f);
        ImGui::Begin("##fps", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                        ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
        ImGui::Text("%.0f fps", io.Framerate);
        if (settings_uncapped_fps()) ImGui::TextUnformatted("BENCHMARK: game speed may change");
        if (g_stats.load()) {  // F3: what the 3D image renders at (the game's own size times the output scale)
            extern int g_out_present_interval;
            float sx, sy;
            renderer_get_scale(&sx, &sy);
            extern bool g_za_frame_hook;
            bool hh = g_za_frame_hook && am_handheld();  // (the game's own size: handheld renders for 1280x720)
            ImGui::Text("render %.0f x %.0f%s", (hh ? 1280.0 : 1920.0) * sx, (hh ? 720.0 : 1080.0) * sy, hh ? " (handheld)" : "");
            if (res_is_dynamic(g_settings.res_mode)) {
                double fm, gm;
                bool gok = output_scale_dynamic_stats(&fm, &gm);
                ImGui::Text("dynamic %.0f%%  (frame %.1f ms, gpu %.1f ms%s)", output_scale_dynamic_factor() * 100, fm, gm, gok ? "" : ", not used");
            }
            ImGui::Text("present interval %d", g_out_present_interval);
            if (g_settings.dev_frame_stats) {  // Developer: where the frame's time goes
                extern double g_stat_cpu_ms, g_stat_gpu_ms;
                ImGui::Text("submit cpu %.1f ms   gpu %.1f ms   (frame %.1f ms)", g_stat_cpu_ms, g_stat_gpu_ms, 1000.0 / fmax(io.Framerate, 1.0f));
            }
        }
        ImGui::End();
    }

    if (open) {
        // dim the game behind the menu
        ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 110));
        float w = fminf(io.DisplaySize.x * 0.78f, 1260 * scale), h = io.DisplaySize.y * 0.84f;  // (a window over the game, not all of it)
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
        ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
        ImGui::Begin("##menu", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
        ImFont *keep_big = g_font_big;  // (the window in the menu's font; header() uses g_font_big)
        g_font_big = g_menu_font_big;
        ImGui::PushFont(g_menu_font);
        // header as on the start screen's Settings: the title, and a close X in the corner (B / Esc too). ("Title
        // screen" - rt_request_reboot(RT_REBOOT_TITLE) - is to find a new home; user 2026-10-11.)
        ImVec2 title_at = ImGui::GetCursorScreenPos();
        ImGui::PushFont(g_font_big);
        ImGui::TextColored(ImVec4(0.28f, 0.84f, 1.0f, 1), "Settings");
        float title_h = ImGui::GetTextLineHeight();
        ImGui::PopFont();
        {   // the build's version (bug reports name it): small, right side of the header, before the close X
            char ver[64];
            snprintf(ver, sizeof ver, "MonZaMac %s", rt_version_label());
            float vs = ImGui::GetFontSize() * 0.85f, vw = ImGui::GetFont()->CalcTextSizeA(vs, FLT_MAX, 0, ver).x;
            float right = ImGui::GetWindowPos().x + ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - 44 * scale - 26 * scale;
            ImGui::GetWindowDrawList()->AddText(ImGui::GetFont(), vs, ImVec2(right - vw, title_at.y + (title_h - vs) * 0.6f),
                                                IM_COL32(150, 172, 210, 255), ver);
        }
        {
            float bx = 44 * scale;
            ImGui::SameLine(ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - bx);
            ImVec2 p = ImGui::GetCursorScreenPos();
            ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
            bool close = ImGui::InvisibleButton("##close", ImVec2(bx, bx), ImGuiButtonFlags_EnableNav);
            ImGui::PopStyleColor();
            bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
            ImU32 col = hot ? IM_COL32(72, 214, 255, 255) : IM_COL32(220, 228, 240, 255);
            float m = bx * 0.3f, t = (hot ? 3.0f : 2.4f) * scale * 1.5f;
            ImDrawList *dl = ImGui::GetWindowDrawList();
            if (hot) dl->AddRectFilled(p, ImVec2(p.x + bx, p.y + bx), IM_COL32(255, 255, 255, 20), 8 * scale);
            dl->AddLine(ImVec2(p.x + m, p.y + m), ImVec2(p.x + bx - m, p.y + bx - m), col, t);
            dl->AddLine(ImVec2(p.x + bx - m, p.y + m), ImVec2(p.x + m, p.y + bx - m), col, t);
            if (close) set_open(false);
        }

        bool any_popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId), typing = ui_text_busy();  // (before the
        tabs_body(scale, true, NULL);                                                                          //  pages run)
        // B with nothing focused-deeper closes the menu (not the Esc / B that ends typing: typing is from the frame
        // before, so it's still true the frame a field lets go)
        if (!any_popup && !typing && !ui_text_busy() && ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows) &&
            (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
            set_open(false);
        ImGui::PopFont();
        g_font_big = keep_big;
        ImGui::End();
        osk_draw(g_font_big, scale);  // (a text field activated with the controller)
    }

    if (kbd) keyboard_draw(io, scale);
    ImGui::Render();
    g_text_busy = open && ui_text_busy();
#ifdef __APPLE__
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    renderer_profile_pass_end("overlay");
#else
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)cmd);  // inside the window image's rendering
#endif
}
