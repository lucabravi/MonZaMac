#!/usr/bin/env python3
"""Exercise the shared Video page with real ImGui navigation, without a GPU or game."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "runtime/ui/menu.mm"
#include <assert.h>
#include <map>

bool g_za_frame_hook = false;
void osk_cancel(void) {}
extern "C" {
int g_start_screen = 1;
static bool temporal_available = true;
bool fg_supported(void) { return true; }
bool temporal_supported(void) { return temporal_available; }
bool rt_za_smooth_anim_supported(void) { return true; }
SDL_Window *ui_window(void) { return NULL; }
void renderer_get_scale(float *sx, float *sy) { *sx = *sy = 1; }
double output_scale_dynamic_factor(void) { return 1; }
void am_set_handheld(bool on) { g_settings.handheld = on; }
bool bind_settings_load(const char *key, const char *value) { return false; }
void bind_settings_save(FILE *f) {}
void bind_capture_cancel(void) {}
void input_reset(void) {}
}

struct Row { ImGuiID id; ImGuiWindow *window; };
static std::map<std::string, Row> rows;
static const char *labels[] = {"Fullscreen", "Show FPS", "Game mode", "Resolution mode", "Internal resolution",
    "Game dynamic resolution", "Upscaler", "Anti-aliasing", "Game FXAA", "Frame rate", "Frame generation",
    "Frame generation quality", "Depth of field", "Bloom", "Wider view", "Smooth distant animation",
    "Sharper textures", "Shadow resolution", "Shadow sharpness"};
void ImGuiTestEngineHook_ItemAdd(ImGuiContext *, ImGuiID, const ImRect &, const ImGuiLastItemData *) {}
void ImGuiTestEngineHook_ItemInfo(ImGuiContext *ctx, ImGuiID id, const char *label, ImGuiItemStatusFlags) {
    if (strcmp(label, "##row")) return;
    for (const char *name : labels)
        if (id == ImHashStr("##row", 0, ImHashStr(name, 0, ctx->CurrentWindow->ID)))
            rows[name] = {id, ctx->CurrentWindow};
}
void ImGuiTestEngineHook_Log(ImGuiContext *, const char *, ...) {}
const char *ImGuiTestEngine_FindItemDebugLabel(ImGuiContext *, ImGuiID) { return NULL; }

static std::string frame(const char *target = NULL, ImGuiKey key = ImGuiKey_None) {
    ImGuiIO &io = ImGui::GetIO();
    if (key != ImGuiKey_None) io.AddKeyEvent(key, true);
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(1900, 2900));
    ImGui::Begin("test", NULL, ImGuiWindowFlags_NoSavedSettings);
    if (target) {
        Row r = rows.at(target);
        ImGui::FocusWindow(r.window);
        ImGui::SetFocusID(r.id, r.window);
        ImGui::SetNavCursorVisible(true);
        if (key == ImGuiKey_None) {
            GImGui->NavActivateId = GImGui->NavActivateDownId = GImGui->NavActivatePressedId = r.id;
        }
    }
    ImGui::LogToBuffer();
    tab_display();
    std::string text = GImGui->LogBuffer.c_str();
    ImGui::LogFinish();
    ImGui::End();
    ImGui::Render();
    if (key != ImGuiKey_None) io.AddKeyEvent(key, false);
    return text;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(2000, 3000);
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    io.IniFilename = NULL;
    assert(io.Fonts->AddFontFromFileTTF(argv[1], 33));
    unsigned char *pixels; int w, h;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &w, &h);
    GImGui->TestEngineHookItems = true;
    frame(); frame();
    assert(rows.size() == sizeof labels / sizeof *labels);
    auto launcher_rows = rows;

    g_settings.upscaler = UPSCALE_METALFX;
    frame("Upscaler", ImGuiKey_RightArrow);
    assert(g_settings.upscaler == 3);
    frame();
    g_settings.antialias = AA_SMAA;
    g_settings.fxaa = true;
    g_settings.frame_generation = FRAME_GENERATION_60_120;
    g_settings.frame_generation_performance = true;
    frame("Anti-aliasing"); assert(g_settings.antialias == AA_SMAA);
    frame("Game FXAA"); assert(g_settings.fxaa);
    frame("Frame generation quality"); assert(g_settings.frame_generation_performance);
    g_settings.res_mode = RES_MATCH;
    g_settings.upscaler = UPSCALE_METALFX;
    frame("Upscaler", ImGuiKey_GamepadDpadRight);
    assert(g_settings.upscaler == 3);
    frame();

    temporal_available = false;
    frame("Anti-aliasing"); assert(g_settings.antialias == AA_OFF);
    frame("Game FXAA"); assert(!g_settings.fxaa);
    frame("Frame generation quality"); assert(!g_settings.frame_generation_performance);
    frame("Upscaler", ImGuiKey_LeftArrow);
    assert(g_settings.upscaler == UPSCALE_METALFX);
    frame();
    temporal_available = true;

    g_start_screen = 0; g_za_frame_hook = true;
    std::string text = frame();
    for (const auto &row : launcher_rows) assert(rows.at(row.first).id == row.second.id);
    size_t pos = 0;
    for (const char *section : {"DISPLAY", "RENDERING RESOLUTION", "FRAME RATE AND GENERATION",
                                "UPSCALING AND AA", "GAME EFFECTS", "SHADOWS"}) {
        pos = text.find(section, pos);
        assert(pos != std::string::npos);
        pos++;
    }
    ImGui::DestroyContext();
    puts("PASS: shared Video sections, row IDs, keyboard/controller upscaler selection and temporal conflicts");
}
'''

if sys.platform != 'darwin':
    print('SKIP: Video page test needs macOS UI headers')
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix='temporal-upscale-menu-') as name:
    tmp = Path(name)
    source = tmp / 'check.mm'
    source.write_text(SOURCE)
    subprocess.run(['cc', '-std=gnu11', '-I', str(ROOT), '-c', str(ROOT / 'runtime/settings.c'),
                    '-o', str(tmp / 'settings.o')], check=True)
    imgui = ROOT / 'third_party/imgui'
    binary = tmp / 'check'
    subprocess.run(['clang++', '-std=c++17', '-O1', '-fobjc-arc', '-DIMGUI_ENABLE_TEST_ENGINE',
                    '-I', str(ROOT), '-I', str(imgui), '-I', str(imgui / 'backends'),
                    '-I/opt/homebrew/opt/sdl3/include', str(source), str(tmp / 'settings.o'),
                    str(ROOT / 'runtime/ui/option_rows.mm'),
                    *(str(imgui / f'{part}.cpp') for part in ('imgui', 'imgui_draw', 'imgui_tables', 'imgui_widgets')),
                    '-L/opt/homebrew/opt/sdl3/lib', '-lSDL3', '-Wl,-dead_strip',
                    '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'UniformTypeIdentifiers',
                    '-o', str(binary)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('LARECOMP_')}
    subprocess.run([str(binary), str(ROOT / 'third_party/fonts/Baloo2/Baloo2-SemiBold.ttf')],
                   cwd=tmp, env=env, check=True)
