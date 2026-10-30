// The start screen's save picker (runtime/saves.h): one card per save slot, a new / copy / rename / delete bar under
// them. Drawn inside the launcher's window (runtime/ui/launcher.mm).
#include <float.h>
#include <initializer_list>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
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

enum Ask { NONE, NEW, COPY, RENAME, DELETE };
static int g_open = -1;  // the save showing its whole team (its expand button, or Y / I on the selected one)
static SaveSlot g_slots[SAVE_SLOTS_MAX];
static int g_n, g_sel, g_focus = -1, g_ask = NONE;
static char g_name[SAVE_NAME_MAX * 4 + 1], g_err[96], g_created[SAVE_NAME_MAX + 1];
static bool g_made;  // NEW just made the slot g_created (the home screen's NEW GAME goes on with it)

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
    const SaveSlot &cur = sel_slot();
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
        else if (g_ask == RENAME) done = saves_rename(cur.id, g_name, g_created);
        else done = saves_delete(cur.id);
        if (done) {
            if (g_ask == RENAME && !strcmp(g_settings.save_slot, cur.id)) snprintf(g_settings.save_slot, sizeof g_settings.save_slot, "%s", g_created);
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
        const char *hint = g_open == g_sel ? "Y / I   hide the team" : "Y / I   show the team";
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
        bool hot = ImGui::IsItemFocused() || ImGui::IsItemHovered();
        if (ImGui::IsItemFocused()) {
            g_sel = i;
            ImGui::SetScrollHereY(0.5f);
        } else if (ImGui::IsItemHovered() && ImGui::GetIO().MouseDelta.x + ImGui::GetIO().MouseDelta.y != 0) g_sel = i;
        bool more_hot = false;
        if (has_team) {  // the expand button: the card's right column, reached with Right from the card
            ImGui::SetCursorScreenPos(ImVec2(p.x + cw - bw, p.y));
            ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
            if (ImGui::InvisibleButton("##team", ImVec2(bw, card_h), ImGuiButtonFlags_EnableNav)) g_open = open ? -1 : i;
            ImGui::PopStyleColor();
            more_hot = ImGui::IsItemFocused() || ImGui::IsItemHovered();
            if (ImGui::IsItemFocused()) g_sel = i, ImGui::SetScrollHereY(0.5f);
            ImGui::SetCursorScreenPos(ImVec2(p.x, p.y + hh + ImGui::GetStyle().ItemSpacing.y));
        }
        ImGui::PopID();
        float r = u * 0.5f;
        ImVec2 qf(p.x + cw, p.y + hh), q(qf.x - bw, qf.y);  // (qf: the card; q: where its text may reach)
        hot = hot || more_hot;
        if (hot) cl->AddRectFilled(ImVec2(p.x - 4 * sc, p.y - 4 * sc), ImVec2(qf.x + 4 * sc, qf.y + 4 * sc), IM_COL32(72, 214, 255, 38), r + 4 * sc);
        cl->AddRectFilled(p, qf, hot ? pal::card_hot : pal::card, r);
        cl->AddRect(p, qf, hot ? pal::accent : pal::edge, r, 0, hot ? 3 * sc : 1.5f * sc);
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
        cl->AddCircleFilled(bc, bd * 0.5f, hot ? pal::accent : IM_COL32(44, 70, 118, 255), 32);
        char num[8];
        snprintf(num, sizeof num, "%d", i + 1);
        ImVec2 ns = body->CalcTextSizeA(u * 1.1f, FLT_MAX, 0, num);
        cl->AddText(body, u * 1.1f, ImVec2(bc.x - ns.x * 0.5f, bc.y - ns.y * 0.5f),
                    hot ? IM_COL32(4, 12, 28, 255) : pal::text, num);
        bool named = si && si->trainer[0];
        float tx = p.x + pad + bd + u * 0.8f;
        float nh = u * 1.25f;                           // the trainer
        float sh = u * 0.85f, ph = si ? u * 0.85f : 0;  // last played / play time and money
        float block = nh + u * 0.12f + sh + (si ? u * 0.12f + ph : 0);
        float ty = p.y + (card_h - block) * 0.5f;
        const char *title = named ? si->trainer : s.name;
        cl->AddText(body, nh, ImVec2(tx, ty), pal::text, title);
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
        if (named && strcmp(s.name, si->trainer)) {  // (the slot's own name, right of the date)
            ImVec2 ws = small_->CalcTextSizeA(sh, FLT_MAX, 0, s.name);
            cl->AddText(small_, sh, ImVec2(q.x - pad - ws.x, ly), pal::sub, s.name);
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
    ImGui::BeginDisabled(!one || !sel_slot().played);
    if (bar_button("Copy", bw * 0.7f, bar_h, small_)) g_ask = COPY, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_n);
    if (bar_button("Rename", bw * 0.8f, bar_h, small_)) g_ask = RENAME, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap);
    ImGui::BeginDisabled(!g_n);
    if (bar_button("Delete", bw * 0.7f, bar_h, small_, true)) g_ask = DELETE, g_err[0] = 0;
    ImGui::EndDisabled();
    ImGui::SameLine(0, bgap * 3);
    if (bar_button("Back", bw * 0.6f, bar_h, small_)) result = -1;

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
        const char *title = si && si->trainer[0] ? si->trainer : cur->name;
        dl->AddText(small_, u * 1.2f, ImVec2(tx, ty + u * 0.38f), pal::text, title);
        // two columns: what's written on the left, the values on the right edge, rows on one pitch
        float rx = cq.x - u * 0.8f, y1 = ty + u * 0.5f, y2 = ty + u * 1.85f, y3 = ty + u * 2.8f;
        auto right_text = [&](float yy, float fs, const char *t) {
            dl->AddText(small_, fs, ImVec2(rx - small_->CalcTextSizeA(fs, FLT_MAX, 0, t).x, yy), pal::sub, t);
        };
        if (si) {  // (the trainer's ID, as on the games' trainer cards)
            char idb[16];
            snprintf(idb, sizeof idb, "ID %06u", si->id);
            right_text(y1 + u * 0.2f, u * 0.75f, idb);
        }
        if (si && si->trainer[0] && strcmp(cur->name, si->trainer))  // (the slot's own name, when it differs)
            right_text(y2, u * 0.78f, cur->name);
        char line[96];
        when(*cur, line, sizeof line, false);
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
