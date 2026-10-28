// The start screen's save picker (runtime/saves.h): one card per save slot, a new / copy / rename / delete bar under
// them. Drawn inside the launcher's window (runtime/ui/launcher.mm).
#include <float.h>
#include <initializer_list>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "imgui.h"
#include "osk.h"
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
}

enum Ask { NONE, NEW, COPY, RENAME, DELETE };
static SaveSlot g_slots[SAVE_SLOTS_MAX];
static int g_n, g_sel, g_focus = -1, g_ask = NONE;
static char g_name[SAVE_NAME_MAX * 4 + 1], g_err[96], g_created[SAVE_NAME_MAX + 1];
static bool g_made;  // NEW just made the slot g_created (the home screen's NEW GAME goes on with it)

static void reload(void) { g_n = saves_list(g_slots, SAVE_SLOTS_MAX); if (g_sel >= g_n) g_sel = g_n - 1; }

// Called when the page opens: the slot played last is the one selected.
void saves_screen_open(void) {
    reload();
    g_sel = 0;
    for (int i = 0; i < g_n; i++)
        if (!strcmp(g_slots[i].id, g_settings.save_slot)) g_sel = i;
    g_focus = g_sel;
    g_ask = NONE;
}

static void when(const SaveSlot &s, char *out, size_t n) {
    if (!s.played) { snprintf(out, n, "No progress yet"); return; }
    time_t t = (time_t)s.played;
    char date[48];
    strftime(date, sizeof date, "%d %b %Y, %H:%M", localtime(&t));
    long d = (long)(difftime(time(NULL), t) / 86400);
    if (d <= 0) snprintf(out, n, "Last played  %s  \xc2\xb7  today", date);
    else if (d == 1) snprintf(out, n, "Last played  %s  \xc2\xb7  yesterday", date);
    else snprintf(out, n, "Last played  %s  \xc2\xb7  %ld days ago", date, d);
}

static void size_label(unsigned long long b, char *out, size_t n) {
    if (b >= 1024ull * 1024) snprintf(out, n, "%.1f MB", (double)b / (1024 * 1024));
    else snprintf(out, n, "%llu KB", (b + 1023) / 1024);
}

static bool bar_button(const char *label, float w, float h, ImFont *font, bool danger = false) {
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

// One modal for naming (new / copy / rename) and one for the delete question. true when confirmed and done.
static bool dialogs(float sc, ImFont *body, ImFont *small_) {
    bool changed = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    const SaveSlot &cur = g_slots[g_sel];
    if (g_ask != NONE && !ImGui::IsPopupOpen("##saveask")) ImGui::OpenPopup("##saveask");
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 720 * sc), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * sc, 28 * sc));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * sc);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.04f, 0.07f, 0.14f, 0.97f));
    bool open = ImGui::BeginPopupModal("##saveask", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (!open) return false;
    ImGui::PushFont(small_);
    bool naming = g_ask == NEW || g_ask == COPY || g_ask == RENAME;
    const char *title = g_ask == NEW ? "New save" : g_ask == COPY ? "Copy save" : g_ask == RENAME ? "Rename save" : "Delete save?";
    ImGui::PushFont(body);
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::accent), "%s", title);
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0, 8 * sc));
    bool ok = false, cancel = ImGui::IsKeyPressed(ImGuiKey_Escape, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false);
    if (naming) {
        if (ImGui::IsWindowAppearing()) {
            snprintf(g_name, sizeof g_name, "%s", g_ask == RENAME ? cur.name : "");
            for (int k = 1; g_ask == NEW && k < 100; k++) {  // "Save 1", "Save 2", ...: the first free
                char t[32];
                bool taken = false;
                snprintf(t, sizeof t, "Save %d", k);
                for (int i = 0; i < g_n; i++) taken |= !strcmp(g_slots[i].id, t);
                if (!taken) { snprintf(g_name, sizeof g_name, "%s", t); break; }
            }
        }
        if (g_ask == COPY) ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(pal::sub), "Name for the copy of \"%s\"", cur.name);
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
        if (g_ask == NEW) done = g_made = saves_create(g_name, g_created);
        else if (g_ask == COPY) done = saves_copy(cur.id, g_name);
        else if (g_ask == RENAME) done = saves_rename(cur.id, g_name);
        else done = saves_delete(cur.id);
        if (done) {
            if (g_ask == RENAME && !strcmp(g_settings.save_slot, cur.id)) snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", g_name);
            if (g_ask == DELETE && !strcmp(g_settings.save_slot, cur.id)) g_settings.save_slot[0] = 0;
            g_err[0] = 0, g_ask = NONE, changed = true;
            ImGui::CloseCurrentPopup();
        } else
            snprintf(g_err, sizeof g_err, "%s", naming ? "That name can't be used (empty, or already taken)." : "Couldn't delete it.");
    } else if (cancel) {
        g_err[0] = 0, g_ask = NONE;
        ImGui::CloseCurrentPopup();
    }
    ImGui::PopFont();
    ImGui::EndPopup();
    if (changed) reload();
    return changed;
}

// 1: a slot was chosen (selected and remembered, play on), -1: back, 0: still here
int saves_screen_draw(float sc, ImFont *body, ImFont *small_) {
    int result = 0;
    ImVec2 ds = ImGui::GetIO().DisplaySize, wp = ImGui::GetWindowPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddRectFilledMultiColor(wp, ImVec2(wp.x + ds.x, wp.y + ds.y), IM_COL32(3, 8, 24, 215), IM_COL32(3, 8, 24, 150),
                                IM_COL32(3, 8, 24, 235), IM_COL32(3, 8, 24, 235));
    float x0 = wp.x + 120 * sc, w = fminf(ds.x - 240 * sc, 1180 * sc);

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
    float top = 70 * sc + th + 36 * sc, bar_h = u * 1.9f, foot = u * 5.0f;
    float card_h = u * 2.9f, gap = u * 0.4f;
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + top));
    ImGui::BeginChild("##savelist", ImVec2(w, ds.y - top - foot), 0, ImGuiWindowFlags_NavFlattened);
    ImDrawList *cl = ImGui::GetWindowDrawList();
    ImGui::PushFont(small_);
    for (int i = 0; i < g_n; i++) {
        const SaveSlot &s = g_slots[i];
        ImVec2 p = ImGui::GetCursorScreenPos();
        float cw = ImGui::GetContentRegionAvail().x - 6 * sc;
        ImGui::PushID(i);
        if (g_focus == i) ImGui::SetKeyboardFocusHere(), g_focus = -1;
        ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
        bool clicked = ImGui::InvisibleButton("##card", ImVec2(cw, card_h), ImGuiButtonFlags_EnableNav);
        ImGui::PopStyleColor();
        bool hot = ImGui::IsItemFocused() || ImGui::IsItemHovered();
        if (ImGui::IsItemFocused()) {
            g_sel = i;
            ImGui::SetScrollHereY(0.5f);
        } else if (ImGui::IsItemHovered() && ImGui::GetIO().MouseDelta.x + ImGui::GetIO().MouseDelta.y != 0) g_sel = i;
        ImGui::PopID();
        float r = u * 0.5f;
        ImVec2 q(p.x + cw, p.y + card_h);
        if (hot) cl->AddRectFilled(ImVec2(p.x - 4 * sc, p.y - 4 * sc), ImVec2(q.x + 4 * sc, q.y + 4 * sc), IM_COL32(72, 214, 255, 38), r + 4 * sc);
        cl->AddRectFilled(p, q, hot ? pal::card_hot : pal::card, r);
        cl->AddRect(p, q, hot ? pal::accent : pal::edge, r, 0, hot ? 3 * sc : 1.5f * sc);
        float pad = u * 0.8f, bd = u * 1.7f;
        ImVec2 bc(p.x + pad + bd * 0.5f, p.y + card_h * 0.5f);  // the slot's number
        cl->AddCircleFilled(bc, bd * 0.5f, hot ? pal::accent : IM_COL32(44, 70, 118, 255), 32);
        char num[8];
        snprintf(num, sizeof num, "%d", i + 1);
        ImVec2 ns = body->CalcTextSizeA(u * 1.1f, FLT_MAX, 0, num);
        cl->AddText(body, u * 1.1f, ImVec2(bc.x - ns.x * 0.5f, bc.y - ns.y * 0.5f),
                    hot ? IM_COL32(4, 12, 28, 255) : pal::text, num);
        float tx = p.x + pad + bd + u * 0.8f;
        char line[96], sz[24];
        when(s, line, sizeof line);
        float nh = u * 1.3f;
        float ty = p.y + (card_h - nh - u * 0.95f) * 0.5f;
        cl->AddText(body, nh, ImVec2(tx, ty), pal::text, s.name);
        cl->AddText(small_, u * 0.85f, ImVec2(tx, ty + nh + u * 0.1f), pal::sub, line);
        if (s.played) {  // right side: how big the save is
            size_label(s.bytes, sz, sizeof sz);
            ImVec2 zs = small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, sz);
            cl->AddText(small_, small_->FontSize, ImVec2(q.x - pad - zs.x, bc.y - zs.y * 0.5f), pal::sub, sz);
        } else {
            const char *nw = "NEW GAME";
            ImVec2 zs = small_->CalcTextSizeA(small_->FontSize, FLT_MAX, 0, nw);
            ImVec2 a(q.x - pad - zs.x - 24 * sc, bc.y - zs.y * 0.5f - 8 * sc), b(q.x - pad, bc.y + zs.y * 0.5f + 8 * sc);
            cl->AddRectFilled(a, b, IM_COL32(120, 255, 200, 30), (b.y - a.y) * 0.5f);
            cl->AddRect(a, b, pal::accent2, (b.y - a.y) * 0.5f, 0, 1.5f * sc);
            cl->AddText(small_, small_->FontSize, ImVec2(a.x + 12 * sc, bc.y - zs.y * 0.5f), pal::accent2, nw);
        }
        if (clicked) {
            saves_select(s.id);
            snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", s.id);
            result = 1;
        }
        ImGui::Dummy(ImVec2(0, gap));
    }
    ImGui::PopFont();
    ImGui::EndChild();

    // under the list: the actions on the selected save, then the "ask every time" switch
    float by = ds.y - foot + u * 0.4f;
    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + by));
    float bw = u * 6.2f, bgap = u * 0.5f;
    bool one = g_n < SAVE_SLOTS_MAX;
    ImGui::BeginDisabled(!one);
    if (bar_button("+ New save", bw, bar_h, small_)) g_ask = NEW, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!one || !g_slots[g_sel].played);
    if (bar_button("Copy", bw * 0.7f, bar_h, small_)) g_ask = COPY, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!*g_slots[g_sel].id);
    if (bar_button("Rename", bw * 0.8f, bar_h, small_)) g_ask = RENAME, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_slots[g_sel].played && !*g_slots[g_sel].id);
    if (bar_button("Delete", bw * 0.7f, bar_h, small_, true)) g_ask = DELETE, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap * 3);
    if (bar_button("Back", bw * 0.6f, bar_h, small_)) result = -1;

    ImGui::SetCursorScreenPos(ImVec2(x0, wp.y + by + bar_h + u * 0.5f));
    ImGui::PushFont(small_);
    ImGui::Checkbox("Ask which save to use every time I press CONTINUE", &g_settings.save_ask);
    ImGui::PopFont();

    if (g_ask != NONE || ImGui::IsPopupOpen("##saveask")) dialogs(sc, body, small_);
    bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId);
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
    bool hot = enabled && (ImGui::IsItemFocused() || ImGui::IsItemHovered());
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
int saves_home_draw(ImFont *title, ImFont *small_, ImTextureID logo, bool ready, bool show_setup, bool focus_first) {
    static int age = 1000;
    if (++age > 90) { reload(); age = 0; }
    ImVec2 ds = ImGui::GetIO().DisplaySize, wp = ImGui::GetWindowPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    // one unit u: the small font's size, shrunk when the window is short (the whole column then fits)
    int n = show_setup ? 6 : 5;
    float u = small_->FontSize, rows = 3.9f + 3.2f + n * 1.75f + 0.2f;
    u *= fminf(1.0f, ds.y * 0.94f / (rows * u));
    float w = fminf(ds.x * 0.92f, u * 17.0f), x = wp.x + (ds.x - w) * 0.5f, y = wp.y + (ds.y - rows * u) * 0.5f;

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

    // the save last played
    const SaveSlot *cur = &g_slots[0];
    bool any = false;
    for (int i = 0; i < g_n; i++) {
        any |= g_slots[i].played > 0;
        if (!strcmp(g_slots[i].id, g_settings.save_slot)) cur = &g_slots[i];
    }
    float ch = u * 2.7f;
    ImVec2 cp(x, ty), cq(x + w, ty + ch);
    dl->AddRectFilled(cp, cq, IM_COL32(22, 40, 74, 235), u * 0.4f);
    dl->AddRect(cp, cq, pal::edge, u * 0.4f, 0, 1.5f);
    if (any) {
        char line[96], sz[24];
        when(*cur, line, sizeof line);
        dl->AddText(small_, u * 1.15f, ImVec2(x + u * 0.7f, ty + u * 0.35f), pal::text, cur->name);
        dl->AddText(small_, u * 0.8f, ImVec2(x + u * 0.7f, ty + u * 1.6f), pal::sub, line);
        size_label(cur->bytes, sz, sizeof sz);
        ImVec2 zs = small_->CalcTextSizeA(u * 0.85f, FLT_MAX, 0, sz);
        dl->AddText(small_, u * 0.85f, ImVec2(x + w - u * 0.7f - zs.x, ty + (ch - zs.y) * 0.5f), pal::sub, sz);
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
