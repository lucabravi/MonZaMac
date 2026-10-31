// The start screen's save picker (runtime/saves.h): one card per save slot, a new / copy / rename / delete / import /
// export bar under them. Drawn inside the launcher's window (runtime/ui/launcher.mm).
#include <float.h>
#include <initializer_list>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <atomic>
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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

enum Ask { NONE, NEW, COPY, RENAME, DELETE, IMPORT };
static int g_open = -1;  // the save showing its whole team (its expand button, or Y on a pad, I on the keyboard, on the selected one)
static SaveSlot g_slots[SAVE_SLOTS_MAX];
static int g_n, g_sel, g_focus = -1, g_ask = NONE;
static char g_name[SAVE_NAME_MAX * 4 + 1], g_err[96], g_created[SAVE_NAME_MAX + 1];
static bool g_made;  // NEW just made the slot g_created (the home screen's NEW GAME goes on with it)
static char g_msg[160];  // under the bar: what the last import / export did
static bool g_msg_bad;

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

static void when(const SaveSlot &s, char *out, size_t n, bool prefix = true) {
    if (!s.played) { snprintf(out, n, "No progress yet"); return; }
    time_t t = (time_t)s.played;
    char date[48];
    strftime(date, sizeof date, "%d %b %Y, %H:%M", localtime(&t));
    long d = (long)(difftime(time(NULL), t) / 86400);
    const char *head = prefix ? "Last played  " : "";
    if (d <= 0) snprintf(out, n, "%s%s  \xc2\xb7  today", head, date);
    else if (d == 1) snprintf(out, n, "%s%s  \xc2\xb7  yesterday", head, date);
    else snprintf(out, n, "%s%s  \xc2\xb7  %ld days ago", head, date, d);
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
        dl->AddText(small_, u * 0.8f, ImVec2(at.x, at.y - u * 0.4f), pal::sub, "No Pokémon yet");
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
    if (k >= n) k = n - 1;
    for (; k > 0; k--) {
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

static bool bar_button(const char *label, float w, float h, ImFont *font, bool danger = false) {
    if (g_menu_look) {
        ImGui::PushFont(font);
        if (danger) ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(pal::warn));
        bool r = ImGui::Button(label, ImVec2(w, h));
        if (danger) ImGui::PopStyleColor();
        ImGui::PopFont();
        return r;
    }
    ImGui::PushFont(font);
    ImGui::PushStyleColor(ImGuiCol_Button, ImGui::ColorConvertU32ToFloat4(pal::card));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImGui::ColorConvertU32ToFloat4(pal::card_hot));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImGui::ColorConvertU32ToFloat4(pal::card_hot));
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(danger ? pal::warn : pal::text));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, h * 0.3f);
    bool r = ImGui::Button(label, ImVec2(w, h));
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(4);
    ImGui::PopFont();
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
    dl->AddText(small_, u * 1.1f, ImVec2(x, p.y + u * 0.3f), pal::text, si->trainer[0] ? si->trainer : "Trainer");
    char pl[16], pline[32];
    fmt_played(si->played, pl, sizeof pl);
    snprintf(pline, sizeof pline, "PLAY  %s", pl);
    dl->AddText(small_, u * 0.8f, ImVec2(x, p.y + u * 1.55f), pal::sub, pline);
    money_row(dl, small_, ImVec2(rx, p.y + u * 0.35f), u, si->money, true);
    team_row(dl, small_, ImVec2(x, p.y + u * 2.75f), u * 0.8f, si);
    ImGui::Dummy(ImVec2(w, h + 10 * sc));
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), "It becomes a new save: your saves stay as they are.");
}

// The new slot's name (saves_import_name), in the name field
static void import_name(const char *src) { saves_import_name(src, g_name, sizeof g_name); }

// The Mac's open / save panels run on the main thread only (AppKit), while the in-game menu draws on the game's
// thread: they're opened there, answer when the player has chosen, and what they did reaches the next frame through
// these (main thread -> drawing thread).
static std::atomic<bool> g_panel_up, g_import_ready, g_msg_ready;
static char g_import_src[1024], g_msg_next[160];
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
        op.title = @"Import a save";
        op.message = @"Choose a save exported from MonZaMac (.zip), or a folder holding a Z-A save (a JKSV backup, a copy from a console).";
        op.prompt = @"Import";
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
        sp.title = @"Export a save";
        sp.message = @"A .zip of this save: keep it, or import it on another Mac.";
        sp.prompt = @"Export";
        sp.allowedContentTypes = @[ UTTypeZIP ];
        sp.nameFieldStringValue = name;
        [sp beginWithCompletionHandler:^(NSModalResponse r) {
            g_panel_up = false;
            if (r != NSModalResponseOK || !sp.URL) return;
            bool ok = saves_export(sid.UTF8String, sp.URL.fileSystemRepresentation);
            char m[160];
            snprintf(m, sizeof m, ok ? "Exported to %s" : "Couldn't export it to %s", sp.URL.lastPathComponent.UTF8String);
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
    bool naming = g_ask == NEW || g_ask == COPY || g_ask == RENAME || g_ask == IMPORT;
    const char *title = g_ask == NEW ? "New save" : g_ask == COPY ? "Copy save" : g_ask == RENAME ? "Rename save"
                      : g_ask == IMPORT ? "Import save" : "Delete save?";
    ImGui::PushFont(body);
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::accent), "%s", title);
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0, 8 * sc));
    bool ok = false, cancel = ImGui::IsKeyPressed(ImGuiKey_Escape, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false);
    if (naming) {
        if (ImGui::IsWindowAppearing()) {
            if (g_ask != IMPORT) snprintf(g_name, sizeof g_name, "%s", g_ask == RENAME ? cur.name : "");  // (import: the trainer's, set when staged)
            if (g_ask == COPY) copy_name(cur);
            for (int k = 1; g_ask == NEW && k < 100; k++) {  // "Save 1", "Save 2", ...: the first free
                char t[32];
                bool taken = false;
                snprintf(t, sizeof t, "Save %d", k);
                for (int i = 0; i < g_n; i++) taken |= !strcmp(g_slots[i].id, t);
                if (!taken) { snprintf(g_name, sizeof g_name, "%s", t); break; }
            }
        }
        if (g_ask == COPY) ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), "Name for the copy of \"%s\"", cur.name);
        if (g_ask == IMPORT) import_preview(sc, small_);
        ImGui::SetNextItemWidth(-1);
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        ok = ui_input_text("##savename", g_name, sizeof g_name, ImGuiInputTextFlags_EnterReturnsTrue, "Name", title);
        ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), "Letters, numbers, space, - and _ (up to %d).", SAVE_NAME_MAX);
        if (*g_err) ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::warn), "%s", g_err);
        if (ui_text_busy()) cancel = false;  // (B / Esc belong to the keyboard)
    } else {
        ImGui::PushTextWrapPos(0);
        ImGui::Text("\"%s\" will be removed from this computer. This can't be undone.", cur.name);
        ImGui::PopTextWrapPos();
    }
    ImGui::Dummy(ImVec2(0, 14 * sc));
    float bw = 200 * sc, gap = 16 * sc;
    ImGui::SetCursorPosX((ImGui::GetWindowWidth() - 2 * bw - gap) * 0.5f);
    bool go = bar_button(naming ? "OK" : "Delete", bw, 44 * sc, small_, !naming);
    ImGui::SameLine(0, gap);
    if (!naming && ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();  // (delete: "Keep it" is the one selected)
    if (bar_button(naming ? "Cancel" : "Keep it", bw, 44 * sc, small_)) cancel = true;
    if (go || ok) {
        bool done;
        if (g_ask == IMPORT) {
            done = saves_import_commit(g_name, g_created);
            if (done) select_id(g_created), snprintf(g_msg, sizeof g_msg, "Imported as \"%s\".", g_created), g_msg_bad = false;
        } else if (g_ask == COPY) {
            done = saves_copy(cur.id, g_name);
            if (done) snprintf(g_msg, sizeof g_msg, "Copied as \"%s\".", g_name), g_msg_bad = false;
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

// 1: a slot was chosen (selected and remembered, play on), -1: back, 0: still here
int saves_screen_draw(float sc, ImFont *body, ImFont *small_) {
    int result = 0;
    g_menu_look = false;
    panels_poll();
    ImVec2 ds = ImGui::GetIO().DisplaySize, wp = ImGui::GetWindowPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddRectFilledMultiColor(wp, ImVec2(wp.x + ds.x, wp.y + ds.y), IM_COL32(3, 8, 24, 215), IM_COL32(3, 8, 24, 150),
                                IM_COL32(3, 8, 24, 235), IM_COL32(3, 8, 24, 235));
    // the column is centered, as the home screen's; wide enough for the buttons under it (about 27 units of the font)
    float w = fminf(ds.x - 240 * sc, fmaxf(1180 * sc, small_->FontSize * 27.5f)), x0 = wp.x + (ds.x - w) * 0.5f;

    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + 70 * sc));
    ImGui::PushFont(body);
    ImGui::PushStyleColor(ImGuiCol_Text, pal::text);
    ImGui::TextUnformatted("SELECT A SAVE");
    ImGui::PopStyleColor();
    float th = ImGui::GetTextLineHeight();
    ImGui::PopFont();
    dl->AddRectFilledMultiColor(ImVec2(x0, wp.y + 70 * sc + th + 6 * sc), ImVec2(x0 + w, wp.y + 70 * sc + th + 10 * sc),
                                pal::accent, IM_COL32(72, 214, 255, 0), IM_COL32(72, 214, 255, 0), pal::accent);

    // (sizes follow the font: the start screen's fonts are big)
    float u = small_->FontSize;
    if (g_n) {
        // (the key of the device last used: a pad's Y or the keyboard's I)
        bool pad = ImGui::GetCurrentContext()->NavInputSource == ImGuiInputSource_Gamepad;
        const char *hint = g_open == g_sel ? (pad ? "Y   hide the team" : "I   hide the team")
                                           : (pad ? "Y   show the team" : "I   show the team");
        dl->AddText(small_, u * 0.8f, ImVec2(x0 + w - small_->CalcTextSizeA(u * 0.8f, FLT_MAX, 0, hint).x, wp.y + 70 * sc + th - u * 0.7f),
                    pal::sub, hint);
    }
    float top = 70 * sc + th + 36 * sc, bar_h = u * 1.9f, foot = u * 5.0f;
    float card_h = u * 3.9f, gap = u * 0.4f;
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + top));
    ImGui::BeginChild("##savelist", ImVec2(w, ds.y - top - foot), 0, ImGuiWindowFlags_NavFlattened);
    ImDrawList *cl = ImGui::GetWindowDrawList();
    ImGui::PushFont(small_);
    if (!g_n) {
        ImGui::PushStyleColor(ImGuiCol_Text, pal::sub);
        ImGui::TextUnformatted("No saves yet. Use + New save, or NEW GAME on the start screen.");
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
        if (hot) cl->AddRectFilled(ImVec2(p.x - 4 * sc, p.y - 4 * sc), ImVec2(qf.x + 4 * sc, qf.y + 4 * sc), IM_COL32(72, 214, 255, 38), r + 4 * sc);
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
                const char *none = "No Pokémon yet";
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
            char pl[16], pline[32];
            fmt_played(si->played, pl, sizeof pl);
            snprintf(pline, sizeof pline, "PLAY  %s", pl);
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
                cl->AddText(small_, u * 0.9f, ImVec2(nx, cy - u * 0.45f), m.egg ? pal::sub : pal::text, m.egg ? "Egg" : mon_label(small_, m, nm, sizeof nm));
                cl->PopClipRect();
                cl->AddText(small_, u * 0.8f, ImVec2(cr - lw, cy - u * 0.4f), pal::sub, lv);
            }
        }
        if (!s.played) {  // (a slot with no progress: the NEW GAME badge, on the right)
            const char *nw = "NEW GAME";
            ImVec2 zs = small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, nw);
            ImVec2 a(q.x - pad - zs.x - 24 * sc, bc.y - zs.y * 0.5f - 8 * sc), b(q.x - pad, bc.y + zs.y * 0.5f + 8 * sc);
            cl->AddRectFilled(a, b, IM_COL32(120, 255, 200, 30), (b.y - a.y) * 0.5f);
            cl->AddRect(a, b, pal::accent2, (b.y - a.y) * 0.5f, 0, 1.5f * sc);
            cl->AddText(small_, small_->FontSize, ImVec2(a.x + 12 * sc, bc.y - zs.y * 0.5f), pal::accent2, nw);
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
    float by = ds.y - foot + u * 0.4f;
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + by));
    // (each button as wide as its label; Back apart on the right)
    // (padding shrinks so that the seven fit the column)
    static const char *const labels[] = {"+ New save", "Import", "Copy", "Export", "Rename", "Delete", "Back"};
    float bgap = u * 0.35f, text_w = 0;
    for (const char *l : labels) text_w += small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, l).x;
    float padx = fminf(u * 1.4f, (w - text_w - bgap * 8.5f) / 7);
    auto bwid = [&](const char *l) { return small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, l).x + padx; };
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
    if (bar_button("Delete", bwid("Delete"), bar_h, small_, true)) g_ask = DELETE, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, 0);
    ImGui::SetCursorScreenPos(ImVec2(x0 + w - bwid("Back"), wp.y + by));
    if (bar_button("Back", bwid("Back"), bar_h, small_)) result = -1;
    if (*g_msg) {  // what the last import / export did
        ImGui::PushFont(small_);
        ImU32 col = g_msg_bad ? pal::warn : pal::accent2;
        dl->AddText(small_, u * 0.8f, ImVec2(x0, wp.y + by + bar_h + u * 0.45f), col, g_msg);
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
    dl->AddRectFilled(p, q, hot ? pal::card_hot : pal::card, r);
    dl->AddRect(p, q, hot ? pal::accent : pal::edge, r, 0, hot ? 3.0f : 1.5f);
    ImVec2 ts = font->CalcTextSizeA(size, FLT_MAX, 0, label);
    ImU32 col = !enabled ? IM_COL32(120, 135, 165, 150) : hot ? pal::accent : pal::text;
    dl->AddText(font, size, ImVec2(p.x + (w - ts.x) * 0.5f, p.y + (h - ts.y) * 0.5f), col, label);
    return clicked && enabled;
}

// 1 CONTINUE, 2 NEW GAME, 3 SAVES, 4 SETTINGS, 5 SET UP GAME FILES, 6 QUIT; 0 nothing yet
static float g_foot[4];  // x, y, width, unit of the lines under the panel
void saves_home_footer(float *x, float *y, float *w, float *u) { *x = g_foot[0], *y = g_foot[1], *w = g_foot[2], *u = g_foot[3]; }

int saves_home_draw(ImFont *title, ImFont *small_, ImTextureID logo, bool ready, bool show_setup, bool focus_first) {
    static int age = 1000;
    if (++age > 90) { reload(); age = 0; }
    ImVec2 ds = ImGui::GetIO().DisplaySize, wp = ImGui::GetWindowPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    // one unit u: the small font's size, shrunk when the window is short (the whole column then fits)
    int n = show_setup ? 6 : 5;
    const float card_u = 5.3f;  // the save card's height (room for the trainer's data)
    float u = small_->FontSize, rows = 3.9f + card_u + 0.55f + n * 1.75f + 0.2f;
    const float foot = 4.4f;  // (the panel's padding, the gap and the two lines under it, in units)
    u *= fminf(1.0f, ds.y * 0.94f / ((rows + foot) * u));
    float w = fminf(ds.x * 0.92f, u * 17.0f), x = wp.x + (ds.x - w) * 0.5f, y = wp.y + (ds.y - (rows + foot) * u) * 0.5f + u * 0.7f;
    g_foot[0] = x, g_foot[1] = y + rows * u + u * 1.5f, g_foot[2] = w, g_foot[3] = u;

    // the glass panel behind it all
    dl->AddRectFilled(ImVec2(x - u, y - u * 0.7f), ImVec2(x + w + u, y + rows * u + u * 0.7f), IM_COL32(4, 10, 26, 205), u * 0.8f);
    dl->AddRect(ImVec2(x - u, y - u * 0.7f), ImVec2(x + w + u, y + rows * u + u * 0.7f), pal::edge, u * 0.8f, 0, 1.5f);

    // logo and name
    float ls = u * 3.2f;
    if (logo) dl->AddImage(logo, ImVec2(x, y), ImVec2(x + ls, y + ls));
    float ts = u * 2.0f;
    ImVec2 tp(x + ls + u * 0.6f, y + (ls - ts) * 0.5f);
    for (float d : {3.0f, 1.5f}) dl->AddText(title, ts, ImVec2(tp.x + d, tp.y + d), IM_COL32(0, 4, 20, 140), "MonZaMac");
    dl->AddText(title, ts, tp, pal::text, "MonZaMac");
    float ty = y + ls + u * 0.7f;
    dl->AddRectFilledMultiColor(ImVec2(x, ty - u * 0.35f), ImVec2(x + w, ty - u * 0.28f), pal::accent, IM_COL32(72, 214, 255, 0),
                                IM_COL32(72, 214, 255, 0), pal::accent);

    // the save last played: the trainer's card (name, play time, money, team), as the games' title screens show it
    const SaveSlot *cur = latest();  // CONTINUE plays this one
    bool any = cur != NULL;
    if (!cur) cur = &g_none;
    const SaveInfo *si = any ? save_info(cur->path) : NULL;
    float ch = u * card_u;
    ImVec2 cp(x, ty), cq(x + w, ty + ch);
    dl->AddRectFilled(cp, cq, IM_COL32(22, 40, 74, 235), u * 0.4f);
    dl->AddRect(cp, cq, pal::edge, u * 0.4f, 0, 1.5f);
    if (any) {
        float ar = u * 0.78f, acx = x + u * 0.8f + ar, acy = ty + u * 1.62f;
        ball(dl, ImVec2(acx, acy), ar, true, false);  // the card's ball
        float tx = acx + ar + u * 0.75f;
        // two columns: what's written on the left, the values on the right edge, rows on one pitch
        float rx = cq.x - u * 0.8f, y1 = ty + u * 0.5f, y2 = ty + u * 1.85f, y3 = ty + u * 2.8f;
        {  // the save's own name as the title (as on the save list), cut short before the ID
            char tcut[64];
            float room = rx - tx - (si ? small_->CalcTextSizeA(u * 0.75f, FLT_MAX, 0, "ID 000000").x + u * 0.6f : 0);
            dl->AddText(small_, u * 1.2f, ImVec2(tx, ty + u * 0.38f), pal::text, fit(small_, u * 1.2f, cur->name, room, tcut, sizeof tcut));
        }
        auto right_text = [&](float yy, float fs, const char *t) {
            dl->AddText(small_, fs, ImVec2(rx - small_->CalcTextSizeA(fs, FLT_MAX, 0, t).x, yy), pal::sub, t);
        };
        if (si) {  // (the trainer's ID, as on the games' trainer cards)
            char idb[16];
            snprintf(idb, sizeof idb, "ID %06u", si->id);
            right_text(y1 + u * 0.2f, u * 0.75f, idb);
        }
        char line[96];
        when(*cur, line, sizeof line, false);
        if (si && si->trainer[0] && strcmp(cur->name, si->trainer)) {  // (the trainer, when not the save's name already)
            char cut[64];
            float room = rx - (tx + small_->CalcTextSizeA(u * 0.78f, FLT_MAX, 0, line).x + u * 0.8f);
            right_text(y2, u * 0.78f, fit(small_, u * 0.78f, si->trainer, room, cut, sizeof cut));
        }
        dl->AddText(small_, u * 0.78f, ImVec2(tx, y2), pal::sub, line);
        if (si) {
            char pl[16], pline[32];
            fmt_played(si->played, pl, sizeof pl);
            snprintf(pline, sizeof pline, "PLAY  %s", pl);
            dl->AddText(small_, u * 0.8f, ImVec2(tx, y3), pal::sub, pline);
            money_row(dl, small_, ImVec2(rx, y3), u, si->money, true);
            team_row(dl, small_, ImVec2(tx, ty + u * 4.2f), u, si);
        }
    } else {
        dl->AddText(small_, u * 1.0f, ImVec2(x + u * 0.7f, ty + u * 0.45f), pal::text, "No saves yet");
        dl->AddText(small_, u * 0.8f, ImVec2(x + u * 0.7f, ty + u * 1.55f), pal::sub, "Choose NEW GAME to begin.");
    }

    // the buttons
    float by = ty + ch + u * 0.55f, bh = u * 1.45f, step = u * 1.75f;
    struct Item { const char *label; bool on; int act; } items[6] = {
        {"CONTINUE", ready && any, 1}, {"NEW GAME", ready, 2}, {"SAVES", ready, 3}, {"SETTINGS", true, 4},
        {"SET UP GAME FILES", true, 5}, {"QUIT", true, 6}};
    if (!show_setup) items[4] = items[5];
    int act = 0;
    bool first_focus = focus_first;
    for (int i = 0; i < n; i++) {
        bool f = first_focus && items[i].on;
        if (f) first_focus = false;
        if (wide_button(dl, items[i].label, ImVec2(x, by + step * i), w, bh, small_, u * 0.95f, items[i].on, f)) act = items[i].act;
    }
    return act;
}

// CONTINUE: the most recent save is selected and remembered (false: no save has progress).
bool saves_use_latest(void) {
    const SaveSlot *l = latest();
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
        snprintf(m, sizeof m, "%s%s Lv. %u", k ? ", " : "", si->party[k].egg ? "Egg" : si->party[k].name, si->party[k].level);
        strncat(team, m, sizeof team - strlen(team) - 1);
    }
    when(s, line, sizeof line);
    if (!si) { snprintf(out, n, "%s", line); return; }
    snprintf(out, n, "%s%s%s%s\nPlay time %s  \xc2\xb7  %s coins\nTeam: %s", si->trainer[0] ? "Trainer " : "", si->trainer,
             si->trainer[0] ? "\n" : "", line, pl, mo, *team ? team : "none yet");
}

static void save_value(const SaveSlot &s, char *out, size_t n) {  // (the row's right side: trainer and play time)
    const SaveInfo *si = save_info(s.path);
    if (!si) { snprintf(out, n, "%s", s.played ? "" : "New game"); return; }
    char pl[16];
    fmt_played(si->played, pl, sizeof pl);
    snprintf(out, n, "%s  \xc2\xb7  %s", si->trainer[0] ? si->trainer : "?", pl);
}

// The action window of one save (not the one being played). true: the game restarts with it (close the menu).
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
    const bool now = g_act == cur;  // the save being played: only copy and export
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
        ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::warn), "Play \"%s\"? The game restarts with it: progress in \"%s\" "
                           "since its last save is lost.", s.name, cur >= 0 ? g_slots[cur].name : "this game");
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 10 * sc));
        float hw = (bw - 16 * sc) * 0.5f;
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        if (bar_button("Yes, play it", hw, bh, small_) || (g_test_yes && !ImGui::IsWindowAppearing())) {
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
        if (!now && bar_button("Play this save", bw, bh, small_)) g_act_confirm = true;
        bool one = g_n < SAVE_SLOTS_MAX;
        ImGui::BeginDisabled(!one || !s.played);
        if (bar_button("Copy", bw, bh, small_)) g_sel = g_act, g_ask = COPY, g_err[0] = 0, close();
        ImGui::EndDisabled();
        ImGui::BeginDisabled(!s.played);
        if (bar_button("Export", bw, bh, small_)) { const SaveSlot c = s; close(); export_pick(c); }
        ImGui::EndDisabled();
        if (!now && bar_button("Rename", bw, bh, small_)) g_sel = g_act, g_ask = RENAME, g_err[0] = 0, close();
        if (!now && bar_button("Delete", bw, bh, small_, true)) g_sel = g_act, g_ask = DELETE, g_err[0] = 0, close();
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
    char d[512], v[96];
    opt_begin("##saves", scale);
    opt_section("Playing now");
    if (cur < 0) {
        opt_disable_next();
        opt_action("No save yet", "", "Save in the game first: then it can be copied and exported here.");
    } else {
        save_desc(g_slots[cur], d, sizeof d);
        strncat(d, "\n\nCopy or export what the game last saved (save in the game first for the latest).",
                sizeof d - strlen(d) - 1);
        if (opt_action(g_slots[cur].name, "In use", d, false)) g_act = cur, g_act_confirm = false;
    }
    opt_section("Other saves");
    int others = 0;
    for (int i = 0; i < g_n; i++) {
        if (i == cur) continue;
        others++;
        save_value(g_slots[i], v, sizeof v);
        save_desc(g_slots[i], d, sizeof d);
        strncat(d, "\n\nPlay it (the game restarts with it), copy, export, rename or delete it.", sizeof d - strlen(d) - 1);
        ImGui::PushID(i);
        if (opt_action(g_slots[i].name, v, d, false)) g_act = i, g_act_confirm = false;
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
        opt_action(g_msg, "", "", false);
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
