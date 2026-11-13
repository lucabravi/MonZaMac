// The start screen's save picker (runtime/saves.h): one card per save slot, a new / copy / rename / delete / import /
// export bar under them. Drawn inside the launcher's window (runtime/ui/launcher.mm).
#include <float.h>
#include <initializer_list>
#include <string>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <atomic>
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "i18n.h"
#include "imgui.h"
#include "imgui_internal.h"  // ImTextCharFromUtf8
#include "osk.h"
#include "../save_info.h"
#include "../saves.h"
extern "C" {
#include "../settings.h"
}

// The picker's colours in one place: a deep blue glass panel, white text, one cool accent.
namespace pal {
static const ImU32 dim = IM_COL32(3, 7, 18, 205);
static const ImU32 card = IM_COL32(16, 28, 52, 215), card_hot = IM_COL32(26, 52, 92, 240);
static const ImU32 edge = IM_COL32(120, 160, 220, 60), accent = IM_COL32(72, 214, 255, 255);
static const ImU32 accent2 = IM_COL32(120, 255, 200, 255), text = IM_COL32(244, 248, 255, 255);
static const ImU32 sub = IM_COL32(150, 172, 210, 255), warn = IM_COL32(255, 120, 120, 255);
static const ImU32 gold = IM_COL32(244, 194, 72, 255);
}

enum Ask { NONE, NEW, COPY, RENAME, DELETE, IMPORT, ROUTE };
static int g_open = -1;  // the save showing its whole team (its expand button, or Y on a pad, I on the keyboard, on the selected one)
static SaveSlot g_slots[SAVE_SLOTS_MAX];
static int g_n, g_sel, g_focus = -1, g_ask = NONE;
static char g_name[SAVE_NAME_MAX * 4 + 1], g_err[96], g_created[SAVE_NAME_MAX + 1];
static bool g_made;  // NEW just made the slot g_created (the home screen's NEW GAME goes on with it)
static char g_msg[1024];  // under the bar: what the last import / export did
static bool g_msg_bad;
extern "C" bool route_record_start(const char *file);  // runtime/hle/input.c
extern "C" void route_record_stop(void);
extern "C" bool route_recording(void);
static char g_route_name[SAVE_NAME_MAX + 1];  // the route being recorded (its save slot has the same name)

static SaveSlot g_none;  // (stands in for the selected slot when there is none)
static void reload(void) { g_n = saves_list(g_slots, SAVE_SLOTS_MAX); if (g_sel >= g_n) g_sel = g_n - 1; if (g_sel < 0) g_sel = 0; }
static SaveSlot &sel_slot(void) { return g_n ? g_slots[g_sel] : g_none; }

// Called when the page opens: the slot played last is the one selected.
void saves_screen_open(void) {
    reload();
    g_sel = 0;
    for (int i = 0; i < g_n; i++)
        if (!strcmp(g_slots[i].id, g_settings.save_slot)) g_sel = i;
    g_focus = g_sel;
    g_ask = NONE;
}

// The save last played (most recent write), or NULL when none has progress
static const SaveSlot *latest(void) {
    const SaveSlot *l = NULL;
    for (int i = 0; i < g_n; i++)
        if (g_slots[i].played && (!l || g_slots[i].played > l->played)) l = &g_slots[i];
    return l;
}

// The save the home page shows and CONTINUE plays: the one chosen on the Saves page (when it has progress), else the latest.
static const SaveSlot *chosen(void) {
    for (int i = 0; i < g_n; i++)
        if (!strcmp(g_slots[i].id, g_settings.save_slot)) return &g_slots[i];  // (a save with no progress yet too: the one just made and picked)
    return latest();
}

// Delete the selected save: a save with no progress holds nothing to lose, so it goes at once; one with progress asks first.
static void ask_delete(void) {
    const SaveSlot &s = sel_slot();
    g_err[0] = 0;
    if (g_n && !s.played && saves_delete(s.id)) {
        if (!strcmp(g_settings.save_slot, s.id)) g_settings.save_slot[0] = 0;
        settings_save();
        reload();
        return;
    }
    g_ask = DELETE;
}

static void when(const SaveSlot &s, char *out, size_t n, bool prefix = true) {
    if (!s.played) { snprintf(out, n, "%s", ui_tr("No progress yet")); return; }
    time_t t = (time_t)s.played;
    char date[48];
    // Numeric ISO date: month names should not be tied to the process C locale.
    strftime(date, sizeof date, "%Y-%m-%d %H:%M", localtime(&t));
    long d = (long)(difftime(time(NULL), t) / 86400);
    const char *head = prefix ? ui_tr("Last played  ") : "";
    char ago[64];
    if (d <= 0) snprintf(ago, sizeof ago, "%s", ui_tr("today"));
    else if (d == 1) snprintf(ago, sizeof ago, "%s", ui_tr("yesterday"));
    else snprintf(ago, sizeof ago, ui_tr("%ld days ago"), d);
    snprintf(out, n, "%s%s  \xc2\xb7  %s", head, date, ago);
}

// ------------------------------------------------------------------ the save's own data (runtime/save_info.c)
// Play time as the games show it: hours:minutes
static void fmt_played(double sec, char *out, size_t n) {
    unsigned t = sec > 0 ? (unsigned)sec : 0;
    snprintf(out, n, "%u:%02u", t / 3600, t / 60 % 60);
}

// 10000 -> "10 000" (a thin grouping works in every language the launcher has)
static void fmt_money(unsigned v, char *out, size_t n) {
    char d[16];
    int k = snprintf(d, sizeof d, "%u", v), w = 0;
    for (int i = 0; i < k && w + 2 < (int)n; i++) {
        if (i && (k - i) % 3 == 0) out[w++] = ' ';
        out[w++] = d[i];
    }
    out[w] = 0;
}

// The one check mark every screen draws (centre c, size r = the radius of the disc it sits on): a single stroke, so the arms join
void ui_check(ImDrawList *dl, ImVec2 c, float r, ImU32 col) {
    ImVec2 pts[3] = {ImVec2(c.x - 0.45f * r, c.y), ImVec2(c.x - 0.14f * r, c.y + 0.36f * r), ImVec2(c.x + 0.5f * r, c.y - 0.36f * r)};
    dl->AddPolyline(pts, 3, col, 0, 0.2f * r);
}

// A Poké Ball from shapes (the game's artwork isn't shipped): red, gold for a shiny, a dim outline for an empty slot
static void ball(ImDrawList *dl, ImVec2 c, float r, bool filled, bool shiny) {
    if (!filled) {
        dl->AddCircle(c, r, IM_COL32(150, 172, 210, 70), 24, fmaxf(1.0f, r * 0.16f));
        return;
    }
    ImU32 top = shiny ? pal::gold : IM_COL32(226, 64, 76, 255), bottom = IM_COL32(242, 246, 255, 255);
    dl->AddCircleFilled(c, r, bottom, 28);
    dl->PathArcTo(c, r, 3.14159265f, 6.28318531f, 20);  // (the top half: y grows down)
    dl->PathFillConvex(top);
    dl->AddRectFilled(ImVec2(c.x - r, c.y - r * 0.10f), ImVec2(c.x + r, c.y + r * 0.10f), IM_COL32(24, 30, 48, 255));
    dl->AddCircleFilled(c, r * 0.30f, IM_COL32(24, 30, 48, 255), 16);
    dl->AddCircleFilled(c, r * 0.19f, bottom, 16);
    if (shiny) {  // a little star at its shoulder
        ImVec2 p[8];
        ImVec2 s(c.x + r * 0.78f, c.y - r * 0.78f);
        for (int i = 0; i < 8; i++) {
            float a = i * 0.78539816f, rr = (i & 1) ? r * 0.14f : r * 0.38f;
            p[i] = ImVec2(s.x + cosf(a) * rr, s.y + sinf(a) * rr);
        }
        dl->AddConvexPolyFilled(p, 8, IM_COL32(255, 238, 160, 255));
    }
}

// The party as a row of balls with each level under it (the games show their sprites, which aren't shipped)
static void team_row(ImDrawList *dl, ImFont *small_, ImVec2 at, float u, const SaveInfo *si) {
    if (!si->party_n) {
        dl->AddText(small_, u * 0.8f, ImVec2(at.x, at.y - u * 0.4f), pal::sub, ui_tr("No Pokémon yet"));
        return;
    }
    float r = u * 0.40f, step = u * 1.9f;
    for (int i = 0; i < SAVE_PARTY_MAX; i++) {
        bool on = i < si->party_n;
        ImVec2 c(at.x + r + step * i, at.y);
        ball(dl, c, r, on, on && si->party[i].shiny);
        if (!on) continue;
        char lv[8];
        snprintf(lv, sizeof lv, "%u", si->party[i].level);
        float w = small_->CalcTextSizeA(u * 0.55f, FLT_MAX, 0, lv).x;
        dl->AddText(small_, u * 0.55f, ImVec2(c.x - w * 0.5f, c.y + r + u * 0.10f), pal::sub, lv);
    }
}

// A gold coin and an amount, the way the games draw money
static void money_row(ImDrawList *dl, ImFont *small_, ImVec2 at, float u, unsigned money, bool right = false) {
    float r = u * 0.28f;
    char mo[24];
    fmt_money(money, mo, sizeof mo);
    if (right) at.x -= r * 2 + u * 0.35f + small_->CalcTextSizeA(u * 0.8f, FLT_MAX, 0, mo).x;  // (at: the right edge)
    ImVec2 c(at.x + r, at.y + u * 0.40f);
    dl->AddCircleFilled(c, r, pal::gold, 20);
    dl->AddCircle(c, r * 0.66f, IM_COL32(140, 96, 20, 255), 20, fmaxf(1.0f, u * 0.045f));
    dl->AddText(small_, u * 0.8f, ImVec2(c.x + r + u * 0.35f, at.y), pal::text, mo);
}

// t cut to fit max_w at this size, with "..." when it doesn't (a long slot name beside the date)
static const char *fit(ImFont *f, float size, const char *t, float max_w, char *buf, size_t n) {
    if (f->CalcTextSizeA(size, FLT_MAX, 0, t).x <= max_w) return t;
    size_t k = strlen(t);
    if (n < 4) return "";
    if (k + 4 > n) k = n - 4;
    for (; k > 0; k--) {
        // Never split a multi-byte UTF-8 code point in a displayed name.
        if (((unsigned char)t[k] & 0xc0) == 0x80) continue;
        snprintf(buf, n, "%.*s...", (int)k, t);
        if (f->CalcTextSizeA(size, FLT_MAX, 0, buf).x <= max_w) return buf;
    }
    return "";
}

// The launcher's font covers Latin only: a name in another script (a save from a game in another language) shows the
// Pokédex number instead of "???"
static const char *mon_label(ImFont *font, const SaveMon &m, char *buf, size_t n) {
    for (const char *c = m.name; *c;) {
        unsigned cp;
        c += ImTextCharFromUtf8(&cp, c, NULL);
        if (cp >= 0x80 && !font->FindGlyphNoFallback((ImWchar)cp)) return snprintf(buf, n, "#%u", m.species), buf;
    }
    return m.name;
}

// Every character the saves' names use, for the launcher to load from a system font before it builds its atlas
// (a save from a game in another language: runtime/ui/launcher.mm)
void saves_name_glyphs(ImFontGlyphRangesBuilder *b) {
    reload();
    for (int i = 0; i < g_n; i++) {
        b->AddText(g_slots[i].name);
        const SaveInfo *si = save_info(g_slots[i].path);
        if (!si) continue;
        b->AddText(si->trainer);
        for (int k = 0; k < si->party_n; k++) b->AddText(si->party[k].name);
    }
}

// The mouse moving over an item gives it the focus: then only one thing is lit, the one used last (the pad / keyboard
// focus or the pointer). true: it has the focus now.
static ImGuiID g_mouse_focus;  // the item the pointer gave the focus to (it doesn't scroll the list); 0 after a nav key
static bool hover_takes_focus(void) {
    ImGuiIO &io = ImGui::GetIO();
    if (ImGui::IsItemHovered() && (io.MouseDelta.x != 0 || io.MouseDelta.y != 0) && !ImGui::IsItemFocused()) {
        ImGui::FocusItem();
        g_mouse_focus = ImGui::GetItemID();
        return true;
    }
    return ImGui::IsItemFocused();
}
// the item has the focus from the keyboard or a pad (scroll it into the middle of the list)
static bool focused_by_nav(void) {
    for (ImGuiKey k : {ImGuiKey_UpArrow, ImGuiKey_DownArrow, ImGuiKey_LeftArrow, ImGuiKey_RightArrow, ImGuiKey_Tab,
                       ImGuiKey_GamepadDpadUp, ImGuiKey_GamepadDpadDown, ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight,
                       ImGuiKey_GamepadLStickUp, ImGuiKey_GamepadLStickDown})
        if (ImGui::IsKeyDown(k)) g_mouse_focus = 0;
    return ImGui::IsItemFocused() && ImGui::GetItemID() != g_mouse_focus;
}

static bool g_menu_look;  // drawn in the in-game menu: its own style (colours, buttons, windows), not the start screen's

// Small line icons for the toolbar buttons (centre c, half-size r)
enum ToolIcon { IC_IMPORT, IC_EXPORT, IC_PLUS, IC_COPY, IC_RENAME, IC_DELETE };
static void tool_icon(ImDrawList *dl, int kind, ImVec2 c, float r, ImU32 col) {
    float th = fmaxf(1.5f, r * 0.2f);
    auto line = [&](float x0, float y0, float x1, float y1) { dl->AddLine(ImVec2(c.x + x0 * r, c.y + y0 * r), ImVec2(c.x + x1 * r, c.y + y1 * r), col, th); };
    switch (kind) {
    case IC_IMPORT: case IC_EXPORT: {
        float d = kind == IC_IMPORT ? 1.0f : -1.0f;  // (the arrow goes down into the tray, or up out of it)
        line(-1, 0.3f, -1, 1); line(-1, 1, 1, 1); line(1, 1, 1, 0.3f);
        line(0, -d * 0.9f + 0.1f, 0, d * 0.5f + 0.1f);
        line(-0.5f, d * 0.05f + 0.1f, 0, d * 0.55f + 0.1f); line(0.5f, d * 0.05f + 0.1f, 0, d * 0.55f + 0.1f);
        break;
    }
    case IC_PLUS: line(-0.9f, 0, 0.9f, 0); line(0, -0.9f, 0, 0.9f); break;
    case IC_COPY:
        dl->AddRect(ImVec2(c.x - r * 0.2f, c.y - r * 0.9f), ImVec2(c.x + r * 0.95f, c.y + r * 0.25f), col, r * 0.2f, 0, th);
        dl->AddRect(ImVec2(c.x - r * 0.95f, c.y - r * 0.25f), ImVec2(c.x + r * 0.2f, c.y + r * 0.9f), col, r * 0.2f, 0, th);
        break;
    case IC_RENAME: line(-0.9f, 0.9f, 0.7f, -0.7f); line(-0.9f, 0.9f, -0.9f, 0.45f); line(-0.9f, 0.9f, -0.45f, 0.9f); line(0.35f, -1.0f, 1.0f, -0.35f); break;
    case IC_DELETE:
        line(-1, -0.55f, 1, -0.55f); line(-0.35f, -0.55f, -0.35f, -0.95f); line(-0.35f, -0.95f, 0.35f, -0.95f); line(0.35f, -0.95f, 0.35f, -0.55f);
        line(-0.7f, -0.55f, -0.55f, 1); line(0.7f, -0.55f, 0.55f, 1); line(-0.55f, 1, 0.55f, 1);
        break;
    }
}

// A toolbar button at an absolute position: an icon and a label. style 0: flat (a highlight when hot), 1: the primary
// action (filled), 2: dangerous (tinted red), 3: a quiet box. Disabled (ImGui::BeginDisabled around it) dims it.
static bool tool_button(const char *id, const char *label, int icon, ImVec2 p, float w, float h, ImFont *font, float fs, int style) {
    ImGui::SetCursorScreenPos(p);
    ImGui::PushID(id);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    bool clicked = ImGui::InvisibleButton("##t", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    bool off = ImGui::GetItemFlags() & ImGuiItemFlags_Disabled;  // (the flags of the item just made: before it they are the previous item's)
    ImGui::PopStyleColor();
    ImGui::PopID();
    bool hot = !off && (ImGui::IsItemHovered() || ImGui::IsItemFocused());
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 q(p.x + w, p.y + h);
    float r = h * 0.28f;
    ImU32 ink = style == 1 ? IM_COL32(6, 20, 44, 255) : style == 2 ? pal::warn : pal::text;
    if (off) ink = IM_COL32(120, 135, 165, 120);
    if (style == 1) dl->AddRectFilled(p, q, off ? IM_COL32(22, 36, 64, 255) : hot ? IM_COL32(120, 232, 255, 255) : IM_COL32(60, 205, 255, 255), r);
    else if (style == 2) dl->AddRectFilled(p, q, hot ? IM_COL32(120, 40, 50, 150) : IM_COL32(90, 30, 40, off ? 40 : 90), r);
    else if (style == 3) {
        dl->AddRectFilled(p, q, hot ? IM_COL32(30, 52, 92, 235) : IM_COL32(16, 28, 54, 230), r);
        dl->AddRect(p, q, hot ? pal::accent : IM_COL32(76, 100, 137, 180), r);
    } else if (hot) dl->AddRectFilled(p, q, IM_COL32(255, 255, 255, 22), r);
    float ir = fs * 0.36f, gap = fs * 0.5f;
    label = ui_tr(label);
    ImVec2 ts = font->CalcTextSizeA(fs, FLT_MAX, 0, label);
    float cw = ir * 2 + gap + ts.x, x = p.x + (w - cw) * 0.5f;
    tool_icon(dl, icon, ImVec2(x + ir, p.y + h * 0.5f), ir, ink);
    dl->AddText(font, fs, ImVec2(x + ir * 2 + gap, p.y + (h - ts.y) * 0.5f), ink, label);
    return clicked && !off;
}

static bool bar_button(const char *label, float w, float h, ImFont *font, bool danger = false) {
    // The original English label is a stable widget ID; only the visible caption is localized.
    std::string caption = std::string(ui_tr(label)) + "###button";
    ImGui::PushID(label);
    ImGui::PushFont(font);
    w = fmaxf(w, ImGui::CalcTextSize(ui_tr(label)).x + ImGui::GetStyle().FramePadding.x * 4);  // (a longer translation widens the button instead of being cut)
    ImGui::PopFont();
    if (g_menu_look) {
        ImGui::PushFont(font);
        if (danger) ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(pal::warn));
        bool r = ImGui::Button(caption.c_str(), ImVec2(w, h));
        if (danger) ImGui::PopStyleColor();
        ImGui::PopFont();
        ImGui::PopID();
        return r;
    }
    ImGui::PushFont(font);
    ImGui::PushStyleColor(ImGuiCol_Button, ImGui::ColorConvertU32ToFloat4(pal::card));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImGui::ColorConvertU32ToFloat4(pal::card_hot));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImGui::ColorConvertU32ToFloat4(pal::card_hot));
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(danger ? pal::warn : pal::text));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, h * 0.3f);
    bool r = ImGui::Button(caption.c_str(), ImVec2(w, h));
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(4);
    ImGui::PopFont();
    ImGui::PopID();
    return r;
}

// After a reload: put the selection on this slot (an import just made it)
static char g_pending_sel[SAVE_NAME_MAX + 1];
static void select_id(const char *id) { snprintf(g_pending_sel, sizeof g_pending_sel, "%s", id); }

// The import dialog's top: whose save it is, as its card would show it (trainer, play time, money, team)
static void import_preview(float sc, ImFont *small_) {
    const SaveInfo *si = save_info(saves_import_staged());
    if (!si) return;
    float u = small_->FontSize, h = u * 3.6f, w = ImGui::GetContentRegionAvail().x;
    ImVec2 p = ImGui::GetCursorScreenPos(), q(p.x + w, p.y + h);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(p, q, pal::card, u * 0.4f);
    dl->AddRect(p, q, pal::edge, u * 0.4f, 0, 1.5f);
    float x = p.x + u * 0.7f, rx = q.x - u * 0.7f;
    dl->AddText(small_, u * 1.1f, ImVec2(x, p.y + u * 0.3f), pal::text, si->trainer[0] ? si->trainer : ui_tr("Trainer"));
    char pl[16], pline[128];
    fmt_played(si->played, pl, sizeof pl);
    snprintf(pline, sizeof pline, ui_tr("PLAY  %s"), pl);
    dl->AddText(small_, u * 0.8f, ImVec2(x, p.y + u * 1.55f), pal::sub, pline);
    money_row(dl, small_, ImVec2(rx, p.y + u * 0.35f), u, si->money, true);
    team_row(dl, small_, ImVec2(x, p.y + u * 2.75f), u * 0.8f, si);
    ImGui::Dummy(ImVec2(w, h + 10 * sc));
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), ui_tr("It becomes a new save: your saves stay as they are."));
}

// The new slot's name (saves_import_name), in the name field
static void import_name(const char *src) { saves_import_name(src, g_name, sizeof g_name); }

// The Mac's open / save panels run on the main thread only (AppKit), while the in-game menu draws on the game's
// thread: they're opened there, answer when the player has chosen, and what they did reaches the next frame through
// these (main thread -> drawing thread).
static std::atomic<bool> g_panel_up, g_import_ready, g_msg_ready;
static char g_import_src[1024], g_msg_next[1024];
static bool g_msg_next_bad;
static void post_msg(const char *m, bool bad) {  // (main thread)
    snprintf(g_msg_next, sizeof g_msg_next, "%s", m), g_msg_next_bad = bad;
    g_msg_ready = true;
}
static void import_name(const char *src);
static void panels_poll(void) {  // (drawing thread, each frame)
    if (g_msg_ready.exchange(false)) snprintf(g_msg, sizeof g_msg, "%s", g_msg_next), g_msg_bad = g_msg_next_bad;
    if (g_import_ready.exchange(false)) g_msg[0] = 0, import_name(g_import_src), g_ask = IMPORT, g_err[0] = 0;
}

// Import: a folder or a .zip, staged when chosen (the import dialog opens on the next frame)
static void import_pick(void) {
    if (g_panel_up.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSOpenPanel *op = [NSOpenPanel openPanel];
        op.title = [NSString stringWithUTF8String:ui_tr("Import a save")];
        op.message = [NSString stringWithUTF8String:ui_tr("Choose a save exported from MonZaMac (.zip), or a folder holding a Z-A save (a JKSV backup, a copy from a console).")];
        op.prompt = [NSString stringWithUTF8String:ui_tr("Import")];
        op.canChooseFiles = YES;
        op.canChooseDirectories = YES;
        op.allowsMultipleSelection = NO;
        op.allowedContentTypes = @[ UTTypeZIP, UTTypeFolder ];
        [op beginWithCompletionHandler:^(NSModalResponse r) {
            g_panel_up = false;
            if (r != NSModalResponseOK || !op.URL) return;
            char err[160];
            if (!saves_import_stage(op.URL.fileSystemRepresentation, err, sizeof err)) { post_msg(err, true); return; }
            snprintf(g_import_src, sizeof g_import_src, "%s", op.URL.fileSystemRepresentation);
            g_import_ready = true;
        }];
    });
}

// (screenshots: LARECOMP_LAUNCHER_SHOT=<frame>:saves-import=<path> opens the import dialog on that save)
extern "C" void saves_screen_test_import(const char *src) {
    char err[160];
    if (!saves_import_stage(src, err, sizeof err)) { snprintf(g_msg, sizeof g_msg, "%s", err), g_msg_bad = true; return; }
    import_name(src);
    g_ask = IMPORT;
}

// Export: the Mac's save panel, then the slot as a .zip (on the main thread, when chosen)
static void export_pick(const SaveSlot &s) {
    if (g_panel_up.exchange(true)) return;
    // the slot's own name (what the player calls it), its play time and today's date: two exports of one save at
    // different points don't take the same file name
    const SaveInfo *si = save_info(s.path);
    char file[96], day[16];
    time_t now = time(NULL);
    strftime(day, sizeof day, "%Y-%m-%d", localtime(&now));
    unsigned t = si && si->played > 0 ? (unsigned)si->played : 0;
    if (si) snprintf(file, sizeof file, "%s - %uh%02u - %s.zip", s.name, t / 3600, t / 60 % 60, day);
    else snprintf(file, sizeof file, "%s - %s.zip", s.name, day);
    NSString *name = @(file), *sid = @(s.id);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSSavePanel *sp = [NSSavePanel savePanel];
        sp.title = [NSString stringWithUTF8String:ui_tr("Export a save")];
        sp.message = [NSString stringWithUTF8String:ui_tr("A .zip of this save: keep it, or import it on another Mac.")];
        sp.prompt = [NSString stringWithUTF8String:ui_tr("Export")];
        sp.allowedContentTypes = @[ UTTypeZIP ];
        sp.nameFieldStringValue = name;
        [sp beginWithCompletionHandler:^(NSModalResponse r) {
            g_panel_up = false;
            if (r != NSModalResponseOK || !sp.URL) return;
            bool ok = saves_export(sid.UTF8String, sp.URL.fileSystemRepresentation);
            char m[1024];
            snprintf(m, sizeof m, ui_tr(ok ? "Exported to %s" : "Couldn't export it to %s"), sp.URL.lastPathComponent.UTF8String);
            post_msg(m, !ok);
        }];
    });
}

// A copy's name, offered in the field: the save's name and its play time ("Trainer - 12h34"), made free with " 2"...
static void copy_name(const SaveSlot &s) {
    const SaveInfo *si = save_info(s.path);
    unsigned t = si && si->played > 0 ? (unsigned)si->played : 0;
    char base[SAVE_NAME_MAX * 2];
    if (si) snprintf(base, sizeof base, "%s - %uh%02u", s.name, t / 3600, t / 60 % 60);
    else snprintf(base, sizeof base, "%s copy", s.name);
    base[SAVE_NAME_MAX - 3] = 0;  // (room for a " 2")
    snprintf(g_name, sizeof g_name, "%s", base);
    for (int n = 2; n < 100; n++) {
        bool taken = false;
        for (int i = 0; i < g_n; i++) taken |= !strcasecmp(g_slots[i].id, g_name) || !strcasecmp(g_slots[i].name, g_name);
        if (!taken) break;
        snprintf(g_name, sizeof g_name, "%s %d", base, n);
    }
}

// One modal for naming (new / copy / rename / import) and one for the delete question. true when confirmed and done.
static bool dialogs(float sc, ImFont *body, ImFont *small_) {
    bool changed = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    const SaveSlot &cur = sel_slot();
    if (g_ask != NONE && !ImGui::IsPopupOpen("##saveask")) ImGui::OpenPopup("##saveask");
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 720 * sc), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * sc, 28 * sc));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * sc);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, g_menu_look ? ImGui::GetStyleColorVec4(ImGuiCol_PopupBg) : ImVec4(0.04f, 0.07f, 0.14f, 0.97f));
    bool open = ImGui::BeginPopupModal("##saveask", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (!open) return false;
    ImGui::PushFont(small_);
    bool naming = g_ask == NEW || g_ask == COPY || g_ask == RENAME || g_ask == IMPORT || g_ask == ROUTE;
    const char *title = g_ask == NEW ? "New save" : g_ask == COPY ? "Copy save" : g_ask == RENAME ? "Rename save"
                      : g_ask == IMPORT ? "Import save" : g_ask == ROUTE ? "Record a route" : "Delete save?";
    ImGui::PushFont(body);
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::accent), "%s", ui_tr(title));
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0, 8 * sc));
    bool ok = false, cancel = ImGui::IsKeyPressed(ImGuiKey_Escape, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false);
    if (naming) {
        if (ImGui::IsWindowAppearing()) {
            if (g_ask != IMPORT) snprintf(g_name, sizeof g_name, "%s", g_ask == RENAME ? cur.name : "");  // (import: the trainer's, set when staged)
            if (g_ask == COPY) copy_name(cur);
            for (int k = 1; (g_ask == NEW || g_ask == ROUTE) && k < 100; k++) {  // "Save 1", "Save 2", ...: the first free
                char t[32];
                bool taken = false;
                snprintf(t, sizeof t, g_ask == ROUTE ? "Route %d" : "Save %d", k);
                for (int i = 0; i < g_n; i++) taken |= !strcmp(g_slots[i].id, t);
                if (g_ask == ROUTE) taken = saves_route_names(t);
                if (!taken) { snprintf(g_name, sizeof g_name, "%s", t); break; }
            }
        }
        if (g_ask == COPY) ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), ui_tr("Name for the copy of \"%s\""), cur.name);
        if (g_ask == ROUTE) {
            ImGui::PushTextWrapPos(0);
            ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), ui_tr("The save in use (\"%s\", as the game last saved it) is copied into routes/ first (it does not show in the save list), then the pad is "
                               "recorded until you stop."), cur.name);
            ImGui::PopTextWrapPos();
        }
        if (g_ask == IMPORT) import_preview(sc, small_);
        ImGui::SetNextItemWidth(-1);
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        ok = ui_input_text("##savename", g_name, sizeof g_name, ImGuiInputTextFlags_EnterReturnsTrue, "Name", title);
        ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), ui_tr("Letters, numbers, space, - and _ (up to %d)."), SAVE_NAME_MAX);
        if (*g_err) ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::warn), "%s", ui_tr(g_err));
        if (ui_text_busy()) cancel = false;  // (B / Esc belong to the keyboard)
    } else {
        ImGui::PushTextWrapPos(0);
        ImGui::Text(ui_tr("\"%s\" will be removed from this computer. This can't be undone."), cur.name);
        ImGui::PopTextWrapPos();
    }
    ImGui::Dummy(ImVec2(0, 14 * sc));
    float bw = 200 * sc, gap = 16 * sc;
    // each button as wide as its caption needs (translations run long); the row is centred on their real total
    auto wd = [&](const char *l) { return fmaxf(bw, ImGui::CalcTextSize(ui_tr(l)).x + ImGui::GetStyle().FramePadding.x * 4); };
    const char *l1 = naming ? "OK" : "Delete", *l2 = naming ? "Cancel" : "Keep it";  // (delete: Delete, Keep it, Cancel)
    float w1 = wd(l1), w2 = wd(l2), w3 = naming ? 0 : wd("Cancel");
    float total = w1 + gap + w2 + (naming ? 0 : gap + w3);
    ImGui::SetCursorPosX(fmaxf(ImGui::GetStyle().WindowPadding.x, (ImGui::GetWindowWidth() - total) * 0.5f));
    bool go = bar_button(l1, w1, 44 * sc, small_, !naming);
    ImGui::SameLine(0, gap);
    if (!naming && ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();  // (delete: "Keep it" is the one selected)
    if (bar_button(l2, w2, 44 * sc, small_)) cancel = true;
    if (!naming) {
        ImGui::SameLine(0, gap);
        if (bar_button("Cancel", w3, 44 * sc, small_)) cancel = true;
    }
    if (go || ok) {
        bool done;
        if (g_ask == IMPORT) {
            done = saves_import_commit(g_name, g_created);
            if (done) select_id(g_created), snprintf(g_msg, sizeof g_msg, ui_tr("Imported as \"%s\"."), g_created), g_msg_bad = false;
        } else if (g_ask == ROUTE) {
            char f[200];
            done = saves_route_begin(g_name, f, sizeof f) && route_record_start(f);  // (the start is copied before the first pad change)
            if (done) snprintf(g_route_name, sizeof g_route_name, "%s", g_name), snprintf(g_msg, sizeof g_msg, ui_tr("Recording \"%s\"."), g_name), g_msg_bad = false;
        } else if (g_ask == COPY) {
            done = saves_copy(cur.id, g_name);
            if (done) snprintf(g_msg, sizeof g_msg, ui_tr("Copied as \"%s\"."), g_name), g_msg_bad = false;
        } else if (g_ask == NEW) done = g_made = saves_create(g_name, g_created);
        else if (g_ask == RENAME) done = !strcmp(g_name, cur.name) || saves_rename(cur.id, g_name, g_created);  // (same name: nothing to do)
        else done = saves_delete(cur.id);
        if (done) {
            if (g_ask == RENAME && strcmp(g_name, cur.name) && !strcmp(g_settings.save_slot, cur.id)) snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", g_created);
            if (g_ask == DELETE && !strcmp(g_settings.save_slot, cur.id)) g_settings.save_slot[0] = 0;
            g_err[0] = 0, g_ask = NONE, changed = true;
            ImGui::CloseCurrentPopup();
        } else
            snprintf(g_err, sizeof g_err, "%s", naming ? "That name can't be used (empty, or already taken)." : "Couldn't delete it.");
    } else if (cancel) {
        if (g_ask == IMPORT) saves_import_cancel();
        g_err[0] = 0, g_ask = NONE;
        ImGui::CloseCurrentPopup();
    }
    ImGui::PopFont();
    ImGui::EndPopup();
    if (changed) {
        reload();
        for (int i = 0; *g_pending_sel && i < g_n; i++)
            if (!strcmp(g_slots[i].id, g_pending_sel)) g_sel = i, g_focus = i;
        g_pending_sel[0] = 0;
    }
    return changed;
}

// 1: a slot was chosen (selected and remembered; back to the home page, which plays it on CONTINUE), -1: back, 0: still here
int saves_screen_draw(float sc, ImFont *body, ImFont *small_, float top_y, float hint_x, float hint_y) {  // top_y > 0: framed by the launcher (header, title and Back are its own), the list starts there; the team hint ends at hint_x, centred on hint_y
    int result = 0;
    g_menu_look = false;
    panels_poll();
    ImVec2 ds = ImGui::GetIO().DisplaySize, wp = ImGui::GetWindowPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    bool framed = top_y > 0;
    float w, x0, th = 0;
    if (framed) {  // (like Settings: the whole width less its margins; the launcher draws the panel, the title and Back)
        w = ds.x - 96 * sc, x0 = wp.x + 48 * sc;
    } else {
        dl->AddRectFilledMultiColor(wp, ImVec2(wp.x + ds.x, wp.y + ds.y), IM_COL32(3, 8, 24, 215), IM_COL32(3, 8, 24, 150),
                                    IM_COL32(3, 8, 24, 235), IM_COL32(3, 8, 24, 235));
        // the column is centered, as the home screen's; wide enough for the buttons under it (about 27 units of the font)
        w = fminf(ds.x - 240 * sc, fmaxf(1180 * sc, small_->FontSize * 27.5f)), x0 = wp.x + (ds.x - w) * 0.5f;

        ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + 70 * sc));
        ImGui::PushFont(body);
        ImGui::PushStyleColor(ImGuiCol_Text, pal::text);
        ImGui::TextUnformatted(ui_tr("SELECT A SAVE"));
        ImGui::PopStyleColor();
        th = ImGui::GetTextLineHeight();
        ImGui::PopFont();
        dl->AddRectFilledMultiColor(ImVec2(x0, wp.y + 70 * sc + th + 6 * sc), ImVec2(x0 + w, wp.y + 70 * sc + th + 10 * sc),
                                    pal::accent, IM_COL32(72, 214, 255, 0), IM_COL32(72, 214, 255, 0), pal::accent);
    }

    // (sizes follow the font: the start screen's fonts are big)
    float u = small_->FontSize;
    if (framed) {  // the actions that add a save, on the title's row (left of Back and the hint)
        float fs = 36 * sc, bh = 60 * sc, gap = 14 * sc, right = hint_x;
        auto wid = [&](const char *l) { return small_->CalcTextSizeA(fs, FLT_MAX, 0, ui_tr(l)).x + fs * 0.72f + fs * 0.5f + 48 * sc; };
        float y = hint_y - bh * 0.5f;
        bool one_more = g_n < SAVE_SLOTS_MAX;
        ImGui::BeginDisabled(!one_more);
        float w1 = wid("New save");
        if (tool_button("new", "New save", IC_PLUS, ImVec2(right - w1, y), w1, bh, small_, fs, 1)) g_ask = NEW, g_err[0] = 0;
        right -= w1 + gap;
        float w2 = wid("Import");
        if (tool_button("imp", "Import", IC_IMPORT, ImVec2(right - w2, y), w2, bh, small_, fs, 3)) import_pick();
        ImGui::EndDisabled();
        hint_x = right - w2 - 28 * sc;
    }
    if (g_n && !framed) {  // (framed by the launcher: no hint line; the key still works)
        // (the key of the device last used: a pad's Y or the keyboard's I)
        bool pad = ImGui::GetCurrentContext()->NavInputSource == ImGuiInputSource_Gamepad;
        const char *hint = ui_tr(g_open == g_sel ? (pad ? "Y   hide the team" : "I   hide the team")
                                                 : (pad ? "Y   show the team" : "I   show the team"));
        ImVec2 hs = small_->CalcTextSizeA(u * 0.8f, FLT_MAX, 0, hint);
        dl->AddText(small_, u * 0.8f, framed ? ImVec2(hint_x - hs.x, hint_y - hs.y * 0.5f)
                                             : ImVec2(x0 + w - hs.x, wp.y + 70 * sc + th - u * 0.7f), pal::sub, hint);
    }
    float top = framed ? top_y : 70 * sc + th + 36 * sc, bar_h = u * 1.9f, foot = framed ? 176 * sc : u * 5.0f;
    float card_h = u * 3.9f, gap = u * 0.4f;
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + top));
    ImGui::BeginChild("##savelist", ImVec2(w, ds.y - top - foot), 0, ImGuiWindowFlags_NavFlattened);
    ImDrawList *cl = ImGui::GetWindowDrawList();
    ImGui::PushFont(small_);
    if (!g_n) {
        ImGui::PushStyleColor(ImGuiCol_Text, pal::sub);
        ImGui::TextUnformatted(ui_tr("No saves yet. Use + New save, or NEW GAME on the start screen."));
        ImGui::PopStyleColor();
    }
    static bool s_hover_prev;  // the pointer was over a card last frame
    bool hover_now = false;
    for (int i = 0; i < g_n; i++) {
        const SaveSlot &s = g_slots[i];
        ImVec2 p = ImGui::GetCursorScreenPos();
        float cw = ImGui::GetContentRegionAvail().x - 6 * sc;
        const SaveInfo *si = save_info(s.path);
        const float rp = u * 1.4f, team_h = u * 0.5f + rp * 3;  // (the team: 2 columns of 3 rows under the card)
        bool has_team = si && si->party_n;
        bool open = g_open == i && has_team;
        float hh = open ? card_h + team_h : card_h, bw = u * 2.4f;  // (bw: the expand button's column, there on every card: the right edges line up)
        ImGui::PushID(i);
        if (g_focus == i) ImGui::SetKeyboardFocusHere(), g_focus = -1;
        ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
        bool clicked = ImGui::InvisibleButton("##card", ImVec2(cw - bw, hh), ImGuiButtonFlags_EnableNav);
        ImGui::PopStyleColor();
        // The selected save (what Copy / Export / Rename / Delete act on) follows the pad and keyboard focus, or a click;
        // the pointer only passing over a card doesn't change it (on its way to the buttons). A click on the selected
        // card, a double click, or A / Enter plays it.
        // lit: the card under the pointer, else the one with the pad / keyboard focus (never both: s_hover_prev)
        bool hovered = ImGui::IsItemHovered();
        if (hovered && (ImGui::IsMouseClicked(0) || ImGui::IsMouseDown(0) || ImGui::IsMouseReleased(0)))
            g_mouse_focus = ImGui::GetItemID();  // (a click focuses the card too: that focus is the pointer's, not a pad's)
        bool nav = focused_by_nav(), was_sel = g_sel == i;
        bool hot = hovered || (ImGui::IsItemFocused() && !s_hover_prev);
        hover_now |= hovered;
        bool play = clicked && (was_sel || nav);  // (a double click: the first click selects, the second plays)
        if (clicked || nav) g_sel = i;
        if (nav) ImGui::SetScrollHereY(0.5f);
        bool more_hot = false;
        if (has_team) {  // the expand button: the card's right column, reached with Right from the card
            ImGui::SetCursorScreenPos(ImVec2(p.x + cw - bw, p.y));
            ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
            if (ImGui::InvisibleButton("##team", ImVec2(bw, card_h), ImGuiButtonFlags_EnableNav)) g_open = open ? -1 : i;
            ImGui::PopStyleColor();
            bool mh = ImGui::IsItemHovered();
            more_hot = mh || (ImGui::IsItemFocused() && !s_hover_prev);
            hover_now |= mh;
            if (focused_by_nav()) g_sel = i, ImGui::SetScrollHereY(0.5f);
            ImGui::SetCursorScreenPos(ImVec2(p.x, p.y + hh + ImGui::GetStyle().ItemSpacing.y));
        }
        ImGui::PopID();
        float r = u * 0.5f;
        ImVec2 qf(p.x + cw, p.y + hh), q(qf.x - bw, qf.y);  // (qf: the card; q: where its text may reach)
        hot = hot || more_hot;
        bool chosen = g_sel == i;  // (marked while the focus is on the buttons too: what they act on)
        {   // a soft glow that eases in under the pointer and stays faint on the selected save
            static float glow[64];
            float &g = glow[i & 63], target = hot ? 1.0f : chosen ? 0.45f : 0.0f;
            g += (target - g) * fminf(1.0f, ImGui::GetIO().DeltaTime * 14.0f);
            if (g > 0.02f) {
                cl->AddRectFilled(ImVec2(p.x - 7 * sc, p.y - 7 * sc), ImVec2(qf.x + 7 * sc, qf.y + 7 * sc), IM_COL32(72, 214, 255, (int)(16 * g)), r + 7 * sc);
                cl->AddRectFilled(ImVec2(p.x - 4 * sc, p.y - 4 * sc), ImVec2(qf.x + 4 * sc, qf.y + 4 * sc), IM_COL32(72, 214, 255, (int)(34 * g)), r + 4 * sc);
            }
        }
        cl->AddRectFilled(p, qf, hot || chosen ? pal::card_hot : pal::card, r);
        cl->AddRect(p, qf, hot || chosen ? pal::accent : pal::edge, r, 0, hot ? 3 * sc : chosen ? 2 * sc : 1.5f * sc);
        {  // the button: a divider and a triangle (right: closed, down: open); dim, and not a stop for the focus, with no team
            float bx = qf.x - bw, cx = bx + bw * 0.5f, cy = p.y + card_h * 0.5f, t = u * 0.4f;
            if (more_hot) cl->AddRectFilled(ImVec2(bx, p.y + 2), ImVec2(qf.x - 2, p.y + card_h - 2), IM_COL32(72, 214, 255, 40), r);
            cl->AddLine(ImVec2(bx, p.y + card_h * 0.2f), ImVec2(bx, p.y + card_h * 0.8f), has_team ? pal::edge : IM_COL32(120, 160, 220, 25), 1.5f);
            ImU32 col = more_hot ? pal::accent : has_team ? pal::sub : IM_COL32(120, 135, 165, 70);
            if (open) cl->AddTriangleFilled(ImVec2(cx - t, cy - t * 0.5f), ImVec2(cx + t, cy - t * 0.5f), ImVec2(cx, cy + t * 0.6f), col);
            else cl->AddTriangleFilled(ImVec2(cx - t * 0.5f, cy - t), ImVec2(cx - t * 0.5f, cy + t), ImVec2(cx + t * 0.6f, cy), col);
        }
        float pad = u * 0.8f, bd = u * 1.7f;
        ImVec2 bc(p.x + pad + bd * 0.5f, p.y + card_h * 0.5f);  // the slot's number
        cl->AddCircleFilled(bc, bd * 0.5f, hot || chosen ? pal::accent : IM_COL32(44, 70, 118, 255), 32);
        char num[8];
        snprintf(num, sizeof num, "%d", i + 1);
        ImVec2 ns = body->CalcTextSizeA(u * 1.1f, FLT_MAX, 0, num);
        cl->AddText(body, u * 1.1f, ImVec2(bc.x - ns.x * 0.5f, bc.y - ns.y * 0.5f),
                    hot || chosen ? IM_COL32(4, 12, 28, 255) : pal::text, num);
        bool named = si && si->trainer[0];
        float tx = p.x + pad + bd + u * 0.8f;
        float nh = u * 1.25f;                           // the trainer
        float sh = u * 0.85f, ph = si ? u * 0.85f : 0;  // last played / play time and money
        float block = nh + u * 0.12f + sh + (si ? u * 0.12f + ph : 0);
        float ty = p.y + (card_h - block) * 0.5f;
        // the slot's name (the player's own) as the title, cut short before the team; the trainer beside the date
        float title_room = q.x - pad - tx - (si ? u * 0.95f * (SAVE_PARTY_MAX - 1) + u * 0.6f + u : 0);
        char tcut[64];
        cl->AddText(body, nh, ImVec2(tx, ty), pal::text, fit(body, nh, s.name, title_room, tcut, sizeof tcut));
        if (si) {  // (the team on the title's right; the games show their sprites, the launcher ships none)
            if (si->party_n) {
                float rr = u * 0.30f, st = u * 0.95f, tw = st * (SAVE_PARTY_MAX - 1) + rr * 2;
                for (int k = 0; k < SAVE_PARTY_MAX; k++)
                    ball(cl, ImVec2(q.x - pad - tw + rr + st * k, ty + nh * 0.5f), rr, k < si->party_n,
                         k < si->party_n && si->party[k].shiny);
            } else {
                const char *none = ui_tr("No Pokémon yet");
                ImVec2 ws = small_->CalcTextSizeA(u * 0.8f, FLT_MAX, 0, none);
                cl->AddText(small_, u * 0.8f, ImVec2(q.x - pad - ws.x, ty + (nh - u * 0.8f) * 0.5f), pal::sub, none);
            }
        }
        char line[96];
        when(s, line, sizeof line);
        float ly = ty + nh + u * 0.12f;
        cl->AddText(small_, sh, ImVec2(tx, ly), pal::sub, line);
        float py = ly + sh + u * 0.12f;
        if (named && strcmp(s.name, si->trainer)) {  // (the trainer, right of the date, when not the slot's name already)
            char cut[64];
            float room = q.x - pad - (tx + small_->CalcTextSizeA(sh, FLT_MAX, 0, line).x + u);
            const char *nm = fit(small_, sh, si->trainer, room, cut, sizeof cut);
            ImVec2 ws = small_->CalcTextSizeA(sh, FLT_MAX, 0, nm);
            cl->AddText(small_, sh, ImVec2(q.x - pad - ws.x, ly), pal::sub, nm);
        }
        if (si) {
            char pl[16], pline[128];
            fmt_played(si->played, pl, sizeof pl);
            snprintf(pline, sizeof pline, ui_tr("PLAY  %s"), pl);
            cl->AddText(small_, ph, ImVec2(tx, py), pal::sub, pline);
            money_row(cl, small_, ImVec2(q.x - pad, py), u, si->money, true);
        }
        if (open) {  // the whole team: its ball, name and level, two to a row
            float y0 = p.y + card_h, colw = (q.x - pad - tx) * 0.5f, r0 = u * 0.4f;
            cl->AddLine(ImVec2(tx, y0 - u * 0.1f), ImVec2(q.x - pad, y0 - u * 0.1f), pal::edge, 1.5f);
            for (int k = 0; k < si->party_n; k++) {
                const SaveMon &m = si->party[k];
                float cx = tx + (k % 2) * colw, cy = y0 + u * 0.2f + rp * (k / 2) + rp * 0.5f;
                ball(cl, ImVec2(cx + r0, cy), r0, true, m.shiny);
                char lv[16], nm[16];
                snprintf(lv, sizeof lv, "Lv. %u", m.level);
                float lw = small_->CalcTextSizeA(u * 0.8f, FLT_MAX, 0, lv).x, nx = cx + r0 * 2 + u * 0.5f, cr = cx + colw - u * 0.6f;
                cl->PushClipRect(ImVec2(nx, cy - rp * 0.5f), ImVec2(cr - lw - u * 0.3f, cy + rp * 0.5f), true);
                cl->AddText(small_, u * 0.9f, ImVec2(nx, cy - u * 0.45f), m.egg ? pal::sub : pal::text, m.egg ? ui_tr("Egg") : mon_label(small_, m, nm, sizeof nm));
                cl->PopClipRect();
                cl->AddText(small_, u * 0.8f, ImVec2(cr - lw, cy - u * 0.4f), pal::sub, lv);
            }
        }
        if (!s.played) {  // (a slot with no progress: the NEW GAME badge, on the right)
            const char *nw = ui_tr("NEW GAME");
            ImVec2 zs = small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, nw);
            ImVec2 a(q.x - pad - zs.x - 24 * sc, bc.y - zs.y * 0.5f - 8 * sc), b(q.x - pad, bc.y + zs.y * 0.5f + 8 * sc);
            cl->AddRectFilled(a, b, IM_COL32(120, 255, 200, 30), (b.y - a.y) * 0.5f);
            cl->AddRect(a, b, pal::accent2, (b.y - a.y) * 0.5f, 0, 1.5f * sc);
            cl->AddText(small_, small_->FontSize, ImVec2(a.x + 12 * sc, bc.y - zs.y * 0.5f), pal::accent2, ui_tr(nw));
        }
        if (play) {
            saves_select(s.id);
            snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", s.id);
            result = 1;
        }
        ImGui::Dummy(ImVec2(0, gap));
    }
    s_hover_prev = hover_now;
    ImGui::PopFont();
    ImGui::EndChild();

    // under the list: the actions on the selected save, then the "ask every time" switch
    float by = framed ? ds.y - 150 * sc : ds.y - foot + u * 0.4f;  // (framed: the toolbar, 110 high, ends 40 above the window's bottom)
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + by));
    if (framed) {  // a toolbar in one container, for the selected save: Copy, Export, Rename, and Delete apart on the right
        float fs = 36 * sc, bh = 56 * sc, pad = 10 * sc, cy0 = wp.y + by + 34 * sc, ch2 = bh + 2 * pad;
        char nm[96], cut[96];
        std::string head = ui_uppercase(ui_tr("Selected save"));
        if (g_n) head += "  \xc2\xb7  " + ui_uppercase(sel_slot().name);
        snprintf(nm, sizeof nm, "%s", head.c_str());
        dl->AddText(small_, 26 * sc, ImVec2(x0, wp.y + by), IM_COL32(176, 196, 226, 225), fit(small_, 26 * sc, nm, w, cut, sizeof cut));
        dl->AddRectFilled(ImVec2(x0, cy0), ImVec2(x0 + w, cy0 + ch2), IM_COL32(16, 28, 54, 200), 16 * sc);
        dl->AddRect(ImVec2(x0, cy0), ImVec2(x0 + w, cy0 + ch2), IM_COL32(76, 100, 137, 120), 16 * sc);
        auto wid = [&](const char *l) { return small_->CalcTextSizeA(fs, FLT_MAX, 0, ui_tr(l)).x + fs * 0.72f + fs * 0.5f + 48 * sc; };
        float bx = x0 + pad, by2 = cy0 + pad;
        bool one = g_n < SAVE_SLOTS_MAX;
        ImGui::BeginDisabled(!one || !sel_slot().played);
        if (tool_button("cp", "Copy", IC_COPY, ImVec2(bx, by2), wid("Copy"), bh, small_, fs, 0)) g_ask = COPY, g_err[0] = 0;
        ImGui::EndDisabled();
        bx += wid("Copy") + 6 * sc;
        ImGui::BeginDisabled(!g_n || !sel_slot().played);
        if (tool_button("ex", "Export", IC_EXPORT, ImVec2(bx, by2), wid("Export"), bh, small_, fs, 0)) export_pick(sel_slot());
        ImGui::EndDisabled();
        bx += wid("Export") + 6 * sc;
        ImGui::BeginDisabled(!g_n);
        if (tool_button("rn", "Rename", IC_RENAME, ImVec2(bx, by2), wid("Rename"), bh, small_, fs, 0)) g_ask = RENAME, g_err[0] = 0;
        if (tool_button("del", "Delete", IC_DELETE, ImVec2(x0 + w - pad - wid("Delete"), by2), wid("Delete"), bh, small_, fs, 2)) ask_delete();
        ImGui::EndDisabled();
        by += 34 * sc + ch2 - bar_h;  // (the message line below the container)
    } else {
    // (each button as wide as its label; Back apart on the right)
    // (padding shrinks so that the seven fit the column)
    static const char *const labels[] = {"+ New save", "Import", "Copy", "Export", "Rename", "Delete", "Back"};
    float bgap = u * 0.35f, text_w = 0;
    for (const char *l : labels) text_w += small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, ui_tr(l)).x;
    float padx = fminf(u * 1.4f, (w - text_w - bgap * 8.5f) / 7);
    auto bwid = [&](const char *l) { return small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, ui_tr(l)).x + padx; };
    bool one = g_n < SAVE_SLOTS_MAX;
    ImGui::BeginDisabled(!one);
    if (bar_button("+ New save", bwid("+ New save"), bar_h, small_)) g_ask = NEW, g_err[0] = 0;
    ImGui::SameLine(0, bgap);
    if (bar_button("Import", bwid("Import"), bar_h, small_)) import_pick();
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap * 2.5f);
    ImGui::BeginDisabled(!one || !sel_slot().played);
    if (bar_button("Copy", bwid("Copy"), bar_h, small_)) g_ask = COPY, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_n || !sel_slot().played);
    if (bar_button("Export", bwid("Export"), bar_h, small_)) export_pick(sel_slot());
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_n);
    if (bar_button("Rename", bwid("Rename"), bar_h, small_)) g_ask = RENAME, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_n);
    if (bar_button("Delete", bwid("Delete"), bar_h, small_, true)) ask_delete();
    ImGui::EndDisabled();
    ImGui::SameLine(0, 0);
    ImGui::SetCursorScreenPos(ImVec2(x0 + w - bwid("Back"), wp.y + by));
    if (bar_button("Back", bwid("Back"), bar_h, small_)) result = -1;
    }
    if (*g_msg) {  // what the last import / export did
        ImGui::PushFont(small_);
        ImU32 col = g_msg_bad ? pal::warn : pal::accent2;
        char clipped[1024];
        const char *shown = fit(small_, u * 0.8f, ui_tr(g_msg), w, clipped, sizeof clipped);
        dl->AddText(small_, u * 0.8f, ImVec2(x0, wp.y + by + bar_h + u * 0.45f), col, shown);
        ImGui::PopFont();
    }

    if (g_ask != NONE || ImGui::IsPopupOpen("##saveask")) dialogs(sc, body, small_);
    bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId);
    if (!popup && !ui_text_busy() && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceUp, false) || ImGui::IsKeyPressed(ImGuiKey_I, false)))
        g_open = g_open == g_sel ? -1 : g_sel;
    if (!result && !popup && !ui_text_busy() &&
        (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
        result = -1;
    if (result) settings_save();
    return result;
}

// ------------------------------------------------------------------ home screen
// The start screen's main page, after the Pokémon games' title menu: the logo and name, a card with the save last
// played, then one wide button per choice.
void saves_new_game_begin(void) { reload(); g_ask = NEW; g_err[0] = 0; }

// The NEW GAME name dialog; true once the slot is made (it is selected and remembered, the game can start).
bool saves_new_game_draw(float sc, ImFont *body, ImFont *small_) {
    if (g_ask != NEW && !ImGui::IsPopupOpen("##saveask")) return false;
    dialogs(sc, body, small_);
    if (!g_made) return false;
    g_made = false;
    saves_select(g_created);
    snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", g_created);
    settings_save();
    return true;
}

static bool wide_button(ImDrawList *dl, const char *label, ImVec2 p, float w, float h, ImFont *font, float size, bool enabled,
                        bool focus) {
    ImGui::SetCursorScreenPos(p);
    ImGui::PushID(label);
    if (focus) ImGui::SetKeyboardFocusHere();
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    ImGui::BeginDisabled(!enabled);
    bool clicked = ImGui::InvisibleButton("##b", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    bool hot = enabled && hover_takes_focus();
    ImGui::EndDisabled();
    ImGui::PopStyleColor();
    ImGui::PopID();
    ImVec2 q(p.x + w, p.y + h);
    float r = h * 0.28f;
    if (hot) dl->AddRectFilled(ImVec2(p.x - 3, p.y - 3), ImVec2(q.x + 3, q.y + 3), IM_COL32(72, 214, 255, 40), r + 3);
    bool primary = !strcmp(label, "Continue");  // (filled like PLAY ONLINE; the others are quiet)
    if (primary && enabled) {
        dl->AddRectFilled(p, q, hot ? IM_COL32(120, 232, 255, 255) : IM_COL32(60, 205, 255, 255), r);
    } else {
        dl->AddRectFilled(p, q, hot ? IM_COL32(30, 52, 92, 235) : IM_COL32(16, 28, 54, 200), r);
        if (hot) dl->AddRect(p, q, pal::accent, r, 0, 2.0f);
    }
    const std::string shown = ui_uppercase(ui_tr(label));
    ImVec2 ts = font->CalcTextSizeA(size, FLT_MAX, 0, shown.c_str());
    ImU32 col = !enabled ? IM_COL32(120, 135, 165, 150) : primary ? IM_COL32(6, 20, 44, 255) : hot ? pal::accent : pal::text;
    dl->AddText(font, size, ImVec2(p.x + (w - ts.x) * 0.5f, p.y + (h - ts.y) * 0.5f), col, shown.c_str());
    return clicked && enabled;
}

// The "Play offline" column of the start screen, in the rectangle (rx, ry, rw, rh) of the window: the last save's trainer
// card and the buttons. 1 CONTINUE, 2 NEW GAME, 3 SAVES, 5 SET UP GAME FILES; 0 nothing yet. (The title, SETTINGS and
// QUIT are in the header, runtime/ui/launcher.mm home_chrome.)
extern ImFont *g_font_column_title;  // runtime/ui/launcher.mm
static float g_home_u;  // the home page's unit, as saves_home_draw fitted it (the online column uses the same)
int saves_home_draw(ImFont *small_, bool ready, bool show_setup, bool focus_first, bool local_chip, float rx, float ry, float rw, float rh) {
    static int age = 1000;
    if (++age > 90) { reload(); age = 0; }
    ImDrawList *dl = ImGui::GetWindowDrawList();
    // one unit u: the small font's size, shrunk until the column's content fits its rectangle
    int n = show_setup ? 4 : 3;
    const float card_u = 8.6f;  // the save card's height (room for the trainer's data)
    float u = small_->FontSize, rows = 2.9f + card_u + 0.55f + (n - 1) * 1.6f + 0.2f;
    u *= fminf(1.0f, fminf(rh / ((rows + 2.0f) * u), rw / (19.0f * u)));
    g_home_u = u;
    float x = rx + u, w = rw - 2 * u, y = ry + u;

    // the glass panel behind it all
    dl->AddRectFilled(ImVec2(rx, ry), ImVec2(rx + rw, ry + rh), IM_COL32(4, 10, 26, 205), u * 0.8f);
    dl->AddRect(ImVec2(rx, ry), ImVec2(rx + rw, ry + rh), pal::edge, u * 0.8f, 0, 1.5f);

    {  // (the title: a play mark and the column's name)
        ImVec2 c(x + u * 0.95f, y + u * 0.95f);
        dl->AddCircle(c, u * 0.9f, pal::accent, 32, u * 0.14f);
        dl->AddTriangleFilled(ImVec2(c.x - u * 0.28f, c.y - u * 0.42f), ImVec2(c.x - u * 0.28f, c.y + u * 0.42f), ImVec2(c.x + u * 0.46f, c.y), pal::accent);
    }
    dl->AddText(g_font_column_title ? g_font_column_title : small_, u * 1.9f, ImVec2(x + u * 2.5f, y - u * 0.15f), pal::text, ui_tr("Play offline"));
    if (local_chip) {  // (the offline edition's tag, top right)
        const char *lc = "Local only";
        float fs = u * 0.95f, tw = small_->CalcTextSizeA(fs, FLT_MAX, 0, ui_tr(lc)).x, cw = tw + u * 3.4f, chh = u * 1.7f;
        ImVec2 a(x + w - cw, y + u * 0.1f), b(a.x + cw, a.y + chh);
        dl->AddRectFilled(a, b, IM_COL32(10, 40, 62, 200), chh * 0.5f);
        dl->AddRect(a, b, pal::accent, chh * 0.5f, 0, 1.5f);
        ImVec2 c(a.x + u * 1.0f, a.y + chh * 0.5f);  // a drive
        dl->AddRect(ImVec2(c.x - u * 0.5f, c.y - u * 0.3f), ImVec2(c.x + u * 0.5f, c.y + u * 0.3f), pal::accent, u * 0.12f, 0, u * 0.1f);
        dl->AddCircleFilled(ImVec2(c.x + u * 0.3f, c.y + u * 0.05f), u * 0.05f, pal::accent);
        dl->AddText(small_, fs, ImVec2(a.x + u * 1.9f, a.y + (chh - fs) * 0.5f), pal::text, ui_tr(lc));
    }
    float ty = y + u * 2.9f;
    dl->AddRectFilledMultiColor(ImVec2(x, ty - u * 0.35f), ImVec2(x + w, ty - u * 0.28f), pal::accent, IM_COL32(72, 214, 255, 0),
                                IM_COL32(72, 214, 255, 0), pal::accent);

    // the save last played: the trainer's card (who, the save's name, play time, money, date, team), as the games' title screens show it
    const SaveSlot *cur = chosen();  // CONTINUE plays this one
    bool any = cur != NULL;
    if (!cur) cur = &g_none;
    const SaveInfo *si = any ? save_info(cur->path) : NULL;
    float ch = u * card_u;
    // the buttons sit at the column's bottom like PLAY ONLINE; the card is centred in the space between the title and them
    float bh = u * 1.3f, step = u * 1.6f, gap = u * 0.4f, hw = (w - gap) * 0.5f;
    float by = ry + rh - u - ((n - 2) * step + bh);
    float cty = ty + fmaxf(0.0f, (by - u * 0.55f - ty - ch) * 0.5f);
    ImVec2 cp(x, cty), cq(x + w, cty + ch);
    dl->AddRectFilled(cp, cq, IM_COL32(20, 36, 68, 150), u * 0.5f);  // (a light card: no outline)
    if (any) {
        float tx = x + u * 0.9f, tx2 = x + w * 0.42f, rx = cq.x - u * 0.9f;
        const ImU32 faint = IM_COL32(176, 196, 226, 225);
        auto label = [&](float xx, float yy, const char *t) { dl->AddText(small_, u * 0.72f, ImVec2(xx, yy), faint, ui_tr(t)); };
        char cut[96];
        dl->AddText(small_, u * 0.72f, ImVec2(tx, cty + u * 0.55f), faint, ui_uppercase(ui_tr("Selected save")).c_str());
        if (si) {  // (the trainer's ID, as on the games' trainer cards)
            char idb[16];
            snprintf(idb, sizeof idb, "ID %06u", si->id);
            float iw = small_->CalcTextSizeA(u * 0.72f, FLT_MAX, 0, idb).x;
            label(rx - iw, cty + u * 0.55f, idb);
        }
        const char *who = si && si->trainer[0] ? si->trainer : cur->name;
        dl->AddText(small_, u * 1.45f, ImVec2(tx, cty + u * 1.2f), pal::text, fit(small_, u * 1.45f, who, rx - tx, cut, sizeof cut));
        dl->AddLine(ImVec2(tx, cty + u * 3.0f), ImVec2(rx, cty + u * 3.0f), IM_COL32(76, 100, 137, 120), 1.0f);
        float r1 = cty + u * 3.4f, r2 = cty + u * 5.4f, vfs = u * 1.0f;  // (the two rows of label + value)
        label(tx, r1, "Save name");
        dl->AddText(small_, vfs, ImVec2(tx, r1 + u * 0.85f), pal::text, fit(small_, vfs, cur->name, tx2 - tx - u * 0.5f, cut, sizeof cut));
        label(tx2, r1, "Play time");
        char pl[16];
        fmt_played(si ? si->played : 0, pl, sizeof pl);
        {  // a small clock, centred on the time's line
            ImVec2 cc(tx2 + u * 0.34f, r1 + u * 0.85f + vfs * 0.5f - u * 0.04f);
            dl->AddCircle(cc, u * 0.34f, pal::sub, 20, u * 0.1f);
            dl->AddLine(cc, ImVec2(cc.x, cc.y - u * 0.22f), pal::sub, u * 0.1f);
            dl->AddLine(cc, ImVec2(cc.x + u * 0.17f, cc.y + u * 0.07f), pal::sub, u * 0.1f);
            dl->AddText(small_, vfs, ImVec2(tx2 + u * 0.95f, r1 + u * 0.85f), pal::text, pl);
        }
        label(tx, r2, "Money");
        if (si) money_row(dl, small_, ImVec2(tx, r2 + u * 0.85f), u, si->money);
        label(tx2, r2, "Last saved");
        char line[96], lcut[96];
        when(*cur, line, sizeof line, false);
        dl->AddText(small_, u * 0.85f, ImVec2(tx2, r2 + u * 0.88f), pal::text, fit(small_, u * 0.85f, line, rx - tx2, lcut, sizeof lcut));
        if (si) team_row(dl, small_, ImVec2(tx, cty + u * 7.7f), u, si);
    } else {
        dl->AddText(small_, u * 1.0f, ImVec2(x + u * 0.7f, cty + u * 0.45f), pal::text, ui_tr("No saves yet"));
        dl->AddText(small_, u * 0.8f, ImVec2(x + u * 0.7f, cty + u * 1.55f), pal::sub, ui_tr("Choose NEW GAME to begin."));
    }

    // the buttons: CONTINUE across, NEW GAME and SAVES side by side, then (when needed) the setup button
    struct Item { const char *label; bool on; int act; float x, w; int row; } items[4] = {
        {"Continue", ready && any, 1, x, w, 0}, {"New game", ready, 2, x, hw, 1}, {"Saves", ready, 3, x + hw + gap, hw, 1},
        {"Set up game files", true, 5, x, w, 2}};  // (keys of the catalog; shown in capitals)
    int act = 0;
    bool first_focus = focus_first;
    for (int i = 0; i < n; i++) {
        bool f = first_focus && items[i].on;
        if (f) first_focus = false;
        if (wide_button(dl, items[i].label, ImVec2(items[i].x, by + step * items[i].row), items[i].w, bh, small_, u * 0.95f, items[i].on, f)) act = items[i].act;
    }
    return act;
}

#ifdef LUMIOSE_ONLINE
#include "online_view.h"
// The "Lumiose Online" column, beside the offline one: 1 PLAY ONLINE, 0 nothing.
int saves_online_draw(ImFont *small_, ImTextureID bg, float bg_aspect, const OnlineView &v, float rx, float ry, float rw, float rh) {
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float u = fminf(g_home_u ? g_home_u : small_->FontSize, fminf(rh / (20.4f), rw / 19.0f));
    float x = rx + u, w = rw - 2 * u, r = u * 0.8f;
    float ph = rh;  // (as tall as the offline column's panel)
    const ImU32 purple = IM_COL32(150, 110, 255, 170);
    dl->AddRectFilled(ImVec2(rx, ry), ImVec2(rx + rw, ry + ph), IM_COL32(8, 12, 36, 255), r);
    if (bg && bg_aspect > 0) {  // the picture across the top, as wide as the column; cropped from above to the banner's height
        float bh = ph - u * 7.3f, full = rw / bg_aspect, vis = fminf(1.0f, bh / full), v0 = 0.0f, v1 = vis;  // (down to where the state begins, fading out)
        float u0 = 0, u1 = 1;
        if (vis >= 1.0f) {  // (a banner taller than the picture: crop its sides instead)
            float wv = rw / (bh * bg_aspect);
            u0 = fmaxf(0.0f, fminf(1 - wv, 0.84f - wv * 0.5f)), u1 = u0 + wv, v0 = 0, v1 = 1;
        }
        dl->AddImageRounded(bg, ImVec2(rx, ry), ImVec2(rx + rw, ry + bh), ImVec2(u0, v0), ImVec2(u1, v1), IM_COL32_WHITE, r, ImDrawFlags_RoundCornersTop);
        dl->AddRectFilledMultiColor(ImVec2(rx + 1, ry + bh - u * 5.0f), ImVec2(rx + rw - 1, ry + bh), IM_COL32(8, 12, 36, 0), IM_COL32(8, 12, 36, 0),
                                    IM_COL32(8, 12, 36, 255), IM_COL32(8, 12, 36, 255));
    }
    dl->AddRect(ImVec2(rx, ry), ImVec2(rx + rw, ry + ph), purple, r, 0, 1.5f);
    // the mark: an arc over a bar with a ring in the middle (a ball, opened), and the name
    {
        const ImU32 gold = IM_COL32(250, 198, 84, 255);
        ImVec2 c(x + u * 1.9f, ry + u * 3.1f);
        float R = u * 1.55f, ring = u * 0.55f, th = u * 0.22f;
        dl->PathArcTo(c, R, 3.14159f, 6.28318f, 28);
        dl->PathStroke(gold, 0, th);
        dl->AddLine(ImVec2(c.x - R, c.y), ImVec2(c.x - ring, c.y), gold, th);
        dl->AddLine(ImVec2(c.x + ring, c.y), ImVec2(c.x + R, c.y), gold, th);
        dl->AddCircle(c, ring, gold, 24, th);
        // the arcs go on below the middle (about 70 degrees) and fade out, thinner towards the bottom
        const int n = 14;
        const float span = 1.22f;
        for (int side = -1; side <= 1; side += 2)
            for (int i = 0; i < n; i++) {
                float t0 = span * i / n, t1 = span * (i + 1) / n, f = 1.0f - (float)(i + 1) / n;
                ImVec2 a0(c.x + side * R * cosf(t0), c.y + R * sinf(t0)), a1(c.x + side * R * cosf(t1), c.y + R * sinf(t1));
                ImU32 col = IM_COL32(250, 198, 84, (int)(255 * f));
                float w = th * (0.35f + 0.65f * f);
                dl->AddLine(a0, a1, col, w);
                dl->AddCircleFilled(a0, i == 0 ? th * 0.5f : th * (0.35f + 0.65f * (1.0f - (float)i / n)) * 0.5f, i == 0 ? IM_COL32(250, 198, 84, 255) : col);  // (round joints: no gaps between segments, nor at the join with the top arc)
            }
    }
    {   // "Lumiose" in the gold of the mark, the rest white
        ImFont *tf = g_font_column_title ? g_font_column_title : small_;
        const char *name = ui_tr("Lumiose Online"), *sp = strchr(name, ' ');
        ImVec2 tp(x + u * 4.2f, ry + u * 1.3f);
        float tw = sp ? tf->CalcTextSizeA(u * 1.75f, FLT_MAX, 0, name, sp).x : 0;
        dl->AddText(tf, u * 1.75f, tp, sp ? IM_COL32(250, 198, 84, 255) : IM_COL32(255, 255, 255, 255), name, sp);
        if (sp) dl->AddText(tf, u * 1.75f, ImVec2(tp.x + tw, tp.y), IM_COL32(255, 255, 255, 255), sp);
    }
    // the state
    float ch = u * 3.4f, cy = ry + ph - u - u * 2.05f - u * 0.9f - ch;  // (the state sits right above the button, at the column's bottom)
    ImVec2 ic(x + u * 1.0f, cy + u * 1.35f);
    const ImU32 dot = v.good ? IM_COL32(70, 214, 110, 255) : v.bad ? IM_COL32(255, 170, 90, 255) : IM_COL32(150, 172, 210, 255);
    const ImU32 dark = IM_COL32(8, 18, 35, 255);
    dl->AddCircleFilled(ic, u * 0.95f, dot, 24);
    if (v.good) {
        ui_check(dl, ic, u * 0.95f, dark);
    } else {  // "!" for a problem, "i" otherwise
        dl->AddText(small_, u * 1.1f, ImVec2(ic.x - u * (v.bad ? 0.1f : 0.12f), ic.y - u * 0.62f), dark, v.bad ? "!" : "i");
    }
    char fit_line[96];
    dl->AddText(small_, u * 1.15f, ImVec2(x + u * 2.5f, cy + u * 0.05f), v.good ? pal::accent2 : v.bad ? pal::warn : pal::text, ui_tr(v.headline));
    dl->AddText(small_, u * 0.85f, ImVec2(x + u * 2.5f, cy + u * 1.45f), pal::sub, fit(small_, u * 0.85f, ui_tr(v.line), w - u * 2.5f, fit_line, sizeof fit_line));
    dl->AddText(small_, u * 0.85f, ImVec2(x + u * 2.5f, cy + u * 2.45f), pal::sub, ui_tr("Uses the save selected offline"));
    // PLAY ONLINE
    ImVec2 p(x, cy + ch + u * 0.9f), q(x + w, p.y + u * 2.05f);
    ImGui::SetCursorScreenPos(p);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    ImGui::BeginDisabled(!v.on);
    bool clicked = ImGui::InvisibleButton("##play-online", ImVec2(w, q.y - p.y), ImGuiButtonFlags_EnableNav);
    bool hot = v.on && (ImGui::IsItemHovered() || ImGui::IsItemFocused());
    ImGui::EndDisabled();
    ImGui::PopStyleColor();
    if (hot) dl->AddRectFilled(ImVec2(p.x - 3, p.y - 3), ImVec2(q.x + 3, q.y + 3), IM_COL32(250, 198, 84, 55), u * 0.7f);
    const ImU32 ink = v.on ? IM_COL32(6, 20, 44, 255) : IM_COL32(150, 172, 210, 255);
    if (v.progress >= 0) {  // preparing: the button fills as it goes
        dl->AddRectFilled(p, q, IM_COL32(58, 46, 20, 255), u * 0.55f);
        dl->PushClipRect(p, ImVec2(p.x + (q.x - p.x) * fminf(1.0f, v.progress), q.y), true);
        dl->AddRectFilled(p, q, IM_COL32(190, 140, 40, 255), u * 0.55f);
        dl->PopClipRect();
    } else {
        dl->AddRectFilled(p, q, !v.on ? IM_COL32(22, 36, 64, 255) : hot ? IM_COL32(255, 218, 125, 255) : IM_COL32(250, 198, 84, 255), u * 0.55f);
    }
    ImVec2 ts = small_->CalcTextSizeA(u * 1.2f, FLT_MAX, 0, ui_tr(v.button));
    float tx0 = p.x + (w - ts.x - u * 1.8f) * 0.5f + u * 1.8f, my = (p.y + q.y) * 0.5f;
    dl->AddText(small_, u * 1.2f, ImVec2(tx0, my - ts.y * 0.5f), v.progress >= 0 ? IM_COL32(255, 255, 255, 255) : ink, ui_tr(v.button));
    ImVec2 gc(tx0 - u * 1.0f, my);  // a globe
    const ImU32 gink = v.progress >= 0 ? IM_COL32(255, 255, 255, 255) : ink;
    dl->AddCircle(gc, u * 0.62f, gink, 24, u * 0.12f);
    dl->AddEllipse(gc, ImVec2(u * 0.28f, u * 0.62f), gink, 0, 24, u * 0.1f);
    dl->AddLine(ImVec2(gc.x - u * 0.62f, gc.y), ImVec2(gc.x + u * 0.62f, gc.y), gink, u * 0.1f);
    return clicked ? 1 : 0;
}
#endif

// CONTINUE: the chosen (else the most recent) save is selected and remembered (false: no save has progress).
bool saves_use_latest(void) {
    const SaveSlot *l = chosen();
    if (!l) return false;
    saves_select(l->id);
    snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", l->id);
    return true;
}

// ------------------------------------------------------------------ in-game menu: Saves tab (runtime/ui/menu.mm)
// Every save while the game runs: the one being played (copy / export it), the others (play one - the game restarts
// with it, after a yes -, copy, export, rename, delete), import, and a new game in a new save. The save being played
// can't be renamed or deleted while the game has it open. Copies and exports hold what the game last wrote.
#include "option_rows.h"
extern "C" void rt_request_reboot(int kind);  // runtime/main.c (RT_REBOOT_GAME = 1: boot again at once)

static int g_act = -1;        // the save whose action window is open (index into g_slots)
static bool g_act_confirm;    // that window asks "play this save?"
static bool g_new_then_play;  // a New save made from the tab: offer to play it
static bool g_test_yes;       // (LARECOMP_MENU_SAVEACT=<n>:yes)

static void save_desc(const SaveSlot &s, char *out, size_t n) {
    const SaveInfo *si = save_info(s.path);
    char pl[16], mo[24], team[256] = "", line[96];
    fmt_played(si ? si->played : 0, pl, sizeof pl);
    fmt_money(si ? si->money : 0, mo, sizeof mo);
    for (int k = 0; si && k < si->party_n; k++) {
        char m[64];
        snprintf(m, sizeof m, "%s%s Lv. %u", k ? ", " : "", si->party[k].egg ? ui_tr("Egg") : si->party[k].name, si->party[k].level);
        strncat(team, m, sizeof team - strlen(team) - 1);
    }
    when(s, line, sizeof line);
    if (!si) { snprintf(out, n, "%s", line); return; }
    snprintf(out, n, ui_tr("%s%s%s%s\nPlay time %s  \xc2\xb7  %s coins\nTeam: %s"), si->trainer[0] ? ui_tr("Trainer ") : "", si->trainer,
             si->trainer[0] ? "\n" : "", line, pl, mo, *team ? team : ui_tr("none yet"));
}

static void save_value(const SaveSlot &s, char *out, size_t n) {  // (the row's right side: trainer and play time)
    const SaveInfo *si = save_info(s.path);
    if (!si) { snprintf(out, n, "%s", s.played ? "" : ui_tr("New game")); return; }
    char pl[16];
    fmt_played(si->played, pl, sizeof pl);
    snprintf(out, n, "%s  \xc2\xb7  %s", si->trainer[0] ? si->trainer : "?", pl);
}

// The action window of one save. true: the game restarts with it (close the menu). The save being played can be reloaded too:
// the game restarts from what it last saved there (to undo what happened since).
static bool action_window(float sc, int cur, ImFont *body, ImFont *small_) {
    if (g_act < 0 || g_act >= g_n) { g_act = -1; return false; }
    bool restart = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    if (!ImGui::IsPopupOpen("##saveact")) ImGui::OpenPopup("##saveact");
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 720 * sc), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * sc, 28 * sc));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * sc);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, g_menu_look ? ImGui::GetStyleColorVec4(ImGuiCol_PopupBg) : ImVec4(0.04f, 0.07f, 0.14f, 0.97f));
    bool open = ImGui::BeginPopupModal("##saveact", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (!open) return false;
    const SaveSlot &s = g_slots[g_act];
    const bool now = g_act == cur;  // the save being played: reload, copy and export (no rename or delete)
    ImGui::PushFont(body);
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::accent), "%s", s.name);
    ImGui::PopFont();
    ImGui::PushFont(small_);
    char d[512];
    save_desc(s, d, sizeof d);
    ImGui::PushTextWrapPos(0);
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), "%s", d);
    ImGui::PopTextWrapPos();
    ImGui::Dummy(ImVec2(0, 14 * sc));
    float bw = ImGui::GetContentRegionAvail().x, bh = 44 * sc;
    bool back = ImGui::IsKeyPressed(ImGuiKey_Escape, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false);
    auto close = [&]() { g_act = -1, g_act_confirm = false; ImGui::CloseCurrentPopup(); };
    if (g_act_confirm) {
        ImGui::PushTextWrapPos(0);
        if (now)
            ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::warn), ui_tr("Reload \"%s\"? The game restarts from its last save: "
                               "progress since then is lost."), s.name);
        else
            ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::warn), ui_tr("Play \"%s\"? The game restarts with it: progress in \"%s\" "
                               "since its last save is lost."), s.name, cur >= 0 ? g_slots[cur].name : ui_tr("this game"));
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 10 * sc));
        float hw = (bw - 16 * sc) * 0.5f;
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        if (bar_button(now ? "Yes, reload it" : "Yes, play it", hw, bh, small_) || (g_test_yes && !ImGui::IsWindowAppearing())) {
            g_test_yes = false;
            saves_select(s.id);
            snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", s.id);
            settings_save();
            rt_request_reboot(1);
            restart = true;
            close();
        }
        ImGui::SameLine(0, 16 * sc);
        if (bar_button("Cancel", hw, bh, small_) || back) g_act_confirm = false;
    } else {
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        if (bar_button(now ? "Reload this save" : "Play this save", bw, bh, small_)) g_act_confirm = true;
        bool one = g_n < SAVE_SLOTS_MAX;
        ImGui::BeginDisabled(!one || !s.played);
        if (bar_button("Copy", bw, bh, small_)) g_sel = g_act, g_ask = COPY, g_err[0] = 0, close();
        ImGui::EndDisabled();
        ImGui::BeginDisabled(!s.played);
        if (bar_button("Export", bw, bh, small_)) { const SaveSlot c = s; close(); export_pick(c); }
        ImGui::EndDisabled();
        if (!now && bar_button("Rename", bw, bh, small_)) g_sel = g_act, g_ask = RENAME, g_err[0] = 0, close();
        if (!now && bar_button("Delete", bw, bh, small_, true)) g_sel = g_act, ask_delete(), close();
        if (bar_button("Close", bw, bh, small_) || back) close();
    }
    ImGui::PopFont();
    ImGui::EndPopup();
    return restart;
}

// true: the game restarts with another save (the menu closes)
bool saves_ingame_tab(float scale, ImFont *body, ImFont *small_) {
    static int age = 1000;
    g_menu_look = true;
    panels_poll();
    bool busy = g_ask != NONE || g_act >= 0;
    if (!busy && ++age > 60) reload(), age = 0;  // (a second: the list from disk, a copy or import just made too)
    int cur = -1;
    for (int i = 0; i < g_n; i++)  // (the folder the game reads: CONTINUE / --play may have picked another than the remembered one)
        if (!strcmp(g_slots[i].path, saves_current_path())) cur = i;
    static const char *test = getenv("LARECOMP_MENU_SAVEACT");  // (tests: <n>[:confirm|:yes] - the n-th other save's window)
    if (test && g_n) {
        int want = atoi(test), k = 0;
        for (int i = 0; i < g_n; i++)
            if (i != cur && k++ == want) g_act = i, g_act_confirm = strchr(test, ':') != NULL;
        g_test_yes = strstr(test, ":yes") != NULL;
        test = NULL;
    }
    char d[2048], v[96];
    opt_begin("##saves", scale);
    opt_section("Playing now");
    if (cur < 0) {
        opt_disable_next();
        opt_action("No save yet", "", "Save in the game first: then it can be copied and exported here.");
    } else {
        save_desc(g_slots[cur], d, sizeof d);
        strncat(d, "\n\n", sizeof d - strlen(d) - 1);
        strncat(d, ui_tr("Reload it (the game restarts from its last save), or copy or export what the game last saved (save in the game first for the latest)."),
                sizeof d - strlen(d) - 1);
        if (opt_action(g_slots[cur].name, "In use", d, false, true, false)) g_act = cur, g_act_confirm = false;
    }
    opt_section("Other saves");
    int others = 0;
    for (int i = 0; i < g_n; i++) {
        if (i == cur) continue;
        others++;
        save_value(g_slots[i], v, sizeof v);
        save_desc(g_slots[i], d, sizeof d);
        strncat(d, "\n\n", sizeof d - strlen(d) - 1);
        strncat(d, ui_tr("Play it (the game restarts with it), copy, export, rename or delete it."), sizeof d - strlen(d) - 1);
        ImGui::PushID(i);
        if (opt_action(g_slots[i].name, v, d, false, true, true)) g_act = i, g_act_confirm = false;
        ImGui::PopID();
    }
    if (!others) {
        opt_disable_next();
        opt_action("None yet", "", "Copies, imports and new games show up here.");
    }
    opt_section("Add a save");
    bool one = g_n < SAVE_SLOTS_MAX;
    if (!one) opt_disable_next();
    if (opt_action("Import a save", "", "A .zip exported from MonZaMac, or a folder with a Z-A save (a JKSV backup, a "
                   "copy from a console). It becomes a new save: yours stay as they are."))
        import_pick();
    if (!one) opt_disable_next();
    if (opt_action("New game in a new save", "", "An empty save with a name of your own, ready to play: you're asked "
                   "before the game restarts with it."))
        g_ask = NEW, g_err[0] = 0, g_new_then_play = true;
    if (*g_msg) {
        opt_disable_next();
        opt_action(ui_tr(g_msg), "", "", false, true);
    }
    opt_end();
    bool restart = false;
    if (g_ask != NONE || ImGui::IsPopupOpen("##saveask")) {
        bool was_new = g_ask == NEW;
        if (dialogs(scale, body, small_) && was_new && g_new_then_play && g_made) {  // the new save: offer to play it
            g_made = false, g_new_then_play = false;
            for (int i = 0; i < g_n; i++)
                if (!strcmp(g_slots[i].id, g_created)) g_act = i, g_act_confirm = true;
        }
        if (g_ask == NONE) g_new_then_play = false;
    }
    if (g_act >= 0) restart = action_window(scale, cur, body, small_);
    return restart;
}

// Developer tab: the entry that records a route (a save copy + the pad changes), and its name dialog.
void saves_route_entry(void) {
    static int age = 1000;
    if (g_ask == NONE && ++age > 60) reload(), age = 0;
    if (route_recording()) {
        char d[1600];
        snprintf(d, sizeof d, ui_tr("Recording \"%s\": the pad is written to route.txt in the folder of that save. Stop when the route is done."), g_route_name);
        if (opt_action("Stop recording", g_route_name, d)) route_record_stop();
        return;
    }
    int cur = -1;
    for (int i = 0; i < g_n; i++)
        if (!strcmp(g_slots[i].path, saves_current_path())) cur = i;
    if (cur < 0 || g_n >= SAVE_SLOTS_MAX) opt_disable_next();
    if (opt_action("Record a route", "", "Asks for a name, copies the save in use (as the game last saved it: save first) to routes/<name>, then "
                   "records everything you press until you stop. The copy keeps the starting point; it is kept in routes/<name>, not in the save list. "
                   "To play it back: LARECOMP_ROUTE=<name> (a fresh copy of the starting save each time; LARECOMP_INPUT_REPLAY_AT=<frame> starts it later).") && cur >= 0) {
        g_sel = cur;
        g_ask = ROUTE, g_err[0] = 0;
    }
}
void saves_route_dialog(float scale, ImFont *body, ImFont *small_) {
    g_menu_look = true;
    if (g_ask == ROUTE || ImGui::IsPopupOpen("##saveask")) dialogs(scale, body, small_);
}
