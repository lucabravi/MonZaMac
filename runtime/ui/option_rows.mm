// Two-pane settings pages (see option_rows.h): rows on the left, the selected / hovered row's description on the right.
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>

#include "i18n.h"
#include "imgui.h"
#include "imgui_internal.h"  // (SetKeyOwner, NavCursorVisible)

#include "option_rows.h"
#include "osk.h"

static float g_scale = 1;
static std::string g_desc_hover, g_desc_focus, g_desc_shown;  // this frame's hovered / selected row, and the last shown
static std::string g_desc_first;  // the page's first row (shown until a row is selected or hovered)

static const ImU32 kGold = IM_COL32(72, 214, 255, 255);
static bool g_next_disabled;
void opt_disable_next(void) { g_next_disabled = true; }
static int g_indent;
static bool g_focus_req, g_take_first;  // (opt_focus_first: requested / this page's first row takes it)
void opt_focus_first(bool on) { g_focus_req = on; }
static bool g_held;  // the last row's left / right has been held a while (steppers go faster)
void opt_indent(int step) { g_indent = g_indent + step < 0 ? 0 : g_indent + step; }

void opt_begin(const char *id, float scale) {
    g_scale = scale;
    g_take_first = g_focus_req;
    g_focus_req = false;
    if (g_take_first) ImGui::NavMoveRequestCancel();  // (this frame's Down goes to the first row instead)
    g_indent = 0;
    g_desc_hover.clear(), g_desc_focus.clear();
    ImVec2 avail = ImGui::GetContentRegionAvail();
    ImGui::PushID(id);
    ImGui::BeginChild("##rows", ImVec2(avail.x * 0.48f, avail.y), ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, 4 * scale));  // (rows close)
    g_desc_first.clear();
}

void opt_section(const char *title) {
    std::string t = ui_uppercase(ui_tr(title));
    if (ImGui::GetCursorPosY() > ImGui::GetStyle().WindowPadding.y + 1) ImGui::Dummy(ImVec2(0, 10 * g_scale));
    ImGui::TextColored(ImVec4(0.28f, 0.84f, 1.0f, 1), "%s", t.c_str());  // (the "Settings" title's blue)
    ImGui::Dummy(ImVec2(0, 6 * g_scale));
}

static int g_value_flag;  // (opt_choice with flags: the UI_LANG_* flag drawn left of the row's value; 0: none)

// One row: draws it, handles A / click and left / right while selected. Returns 2 (A / click), -1 / +1 (left / right) or 0.
// arrows: ◀ value ▶ (a choice of several, or a stepper): left / right step it, and the arrows click too
static int row(const char *label, const std::string &value, bool changed, const char *desc, bool upper = true,
               bool arrows = false, int at_end = 0, bool literal_label = false, bool literal_value = false) {  // at_end: 1 = nothing further left, 2 = nothing further right (that arrow is not drawn)
    ImGui::PushID(label);
    if (g_indent) ImGui::SetCursorPosX(ImGui::GetCursorPosX() + g_indent * 28 * g_scale);  // (an option of the row above)
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::GetContentRegionAvail().x, h = ImGui::GetFontSize() * 1.9f;
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));  // (the row's own border shows the selection)
    bool clicked = ImGui::InvisibleButton("##row", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    if (g_take_first) {  // (opt_focus_first)
        g_take_first = false;
        ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        ImGui::SetScrollHereY(0);
    }
    bool off = g_next_disabled || (ImGui::GetItemFlags() & ImGuiItemFlags_Disabled);  // also blocks our manual left/right handling
    g_next_disabled = false;
    bool hov = ImGui::IsItemHovered(), foc = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    int step = clicked && !off ? 2 : 0;
    g_held = false;
    if (foc && !off) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) ||
            ImGui::IsKeyPressed(ImGuiKey_LeftArrow))
            step = -1;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
            ImGui::IsKeyPressed(ImGuiKey_RightArrow))
            step = 1;
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadLStickLeft,
                           ImGuiKey_GamepadLStickRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            if (ImGui::GetKeyData(k)->DownDuration > 1.0f) g_held = true;
        // left / right belong to the row (navigation would otherwise try to move sideways)
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            ImGui::SetKeyOwner(k, ImGui::GetItemID());
    }
    if (foc) g_desc_focus = desc ? desc : "";
    if (hov) g_desc_hover = desc ? desc : "";
    if (g_desc_first.empty() && desc) g_desc_first = desc;

    ImDrawList *dl = ImGui::GetWindowDrawList();
    float r = 9 * g_scale, pad = 16 * g_scale, fs = ImGui::GetFontSize();
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), hov || foc ? IM_COL32(255, 255, 255, 22) : IM_COL32(0, 0, 0, 40), r);
    dl->AddRect(p, ImVec2(p.x + w, p.y + h), hov || foc ? (off ? IM_COL32(72, 214, 255, 120) : kGold)
                                                        : IM_COL32(255, 255, 255, off ? 18 : 38), r, 0,
                hov || foc ? 2.0f : 1.0f);
    std::string t = literal_label ? label : upper ? ui_uppercase(ui_tr(label)) : ui_tr(label);
    const std::string display_value = literal_value ? value : ui_tr(value.c_str());
    float ty = p.y + (h - fs) * 0.5f;
    ImU32 label_col = off ? IM_COL32(110, 110, 102, 255) : IM_COL32(238, 243, 252, 255);  // (greyed out: clearly dim)
    dl->AddText(ImVec2(p.x + pad, ty), label_col, t.c_str());
    float right = p.x + w - pad;  // (the value's right edge)
    if (arrows && !value.empty()) {  // ◀ value ▶, drawn (the fonts have no arrow glyphs); a click on one steps
        float aw = fs * 0.42f, gap = fs * 0.55f, cy = ty + fs * 0.52f;
        float flagw = g_value_flag ? fs * 1.45f + fs * 0.45f : 0;  // (a flag left of the value)
        float rx = right - aw, lx = rx - gap - ImGui::CalcTextSize(display_value.c_str()).x - flagw - gap - aw;
        ImU32 ac = off ? IM_COL32(110, 110, 100, 255) : hov || foc ? kGold : IM_COL32(150, 168, 200, 255);
        if (!(at_end & 1)) dl->AddTriangleFilled(ImVec2(lx, cy), ImVec2(lx + aw, cy - aw * 0.75f), ImVec2(lx + aw, cy + aw * 0.75f), ac);
        if (!(at_end & 2)) dl->AddTriangleFilled(ImVec2(rx + aw, cy), ImVec2(rx, cy - aw * 0.75f), ImVec2(rx, cy + aw * 0.75f), ac);
        if (clicked && !off) {
            float mx = ImGui::GetIO().MousePos.x, hit = gap;
            if (mx >= lx - hit && mx <= lx + aw + hit) step = -1;
            else if (mx >= rx - hit && mx <= rx + aw + hit) step = 1;
        }
        right = rx - gap;
    }
    if (!value.empty()) {
        float vw = ImGui::CalcTextSize(display_value.c_str()).x, vx = right - vw;
        if (g_value_flag) ui_draw_flag(dl, g_value_flag, vx - fs * 1.45f - fs * 0.45f, ty + fs * 0.05f, fs * 1.45f, fs * 0.95f);
        dl->AddText(ImVec2(vx, ty), off ? IM_COL32(110, 110, 102, 255) : changed ? IM_COL32(255, 255, 255, 255)
                                                                                 : IM_COL32(200, 212, 232, 255), display_value.c_str());
    }
    ImGui::PopID();
    return step;
}

bool opt_toggle(const char *label, bool *v, bool def, const char *desc) {
    if (!row(label, *v ? "On" : "Off", *v != def, desc)) return false;  // (any step flips it)
    *v = !*v;
    return true;
}

bool opt_choice(const char *label, int *v, const char *const *names, int n, int def, const char *desc,
                bool wrap, bool values_are_literal, const int *flag_langs) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    g_value_flag = flag_langs ? flag_langs[cur] : 0;
    int step = row(label, names[cur], cur != def, desc, true, true,
                   wrap ? 0 : (cur == 0 ? 1 : 0) | (cur == n - 1 ? 2 : 0), false, values_are_literal);
    g_value_flag = 0;
    // a mouse click on the value itself (not on an arrow) opens the list of choices; A on a controller still steps to the next
    ImVec2 ra = ImGui::GetItemRectMin(), rb = ImGui::GetItemRectMax();
    ImGui::PushID(label);
    if (step == 2 && ImGui::IsMouseReleased(ImGuiMouseButton_Left)) {
        ImGui::OpenPopup("##choices");
        step = 0;
    }
    bool picked = false;
    {   // below the row, or above it when there is more room there; as tall as fits (a long list scrolls inside), the current choice in view
        float fs0 = ImGui::GetFontSize(), need = n * (fs0 * 1.7f + 3 * g_scale) + 16 * g_scale, margin = 12 * g_scale;
        float below = ImGui::GetIO().DisplaySize.y - (rb.y + 4 * g_scale) - margin, above = ra.y - 4 * g_scale - margin;
        bool up = need > below && above > below;
        float room = fmaxf(up ? above : below, fs0 * 4);
        if (up) ImGui::SetNextWindowPos(ImVec2(rb.x, ra.y - 4 * g_scale), ImGuiCond_Always, ImVec2(1, 1));
        else ImGui::SetNextWindowPos(ImVec2(rb.x, rb.y + 4 * g_scale), ImGuiCond_Always, ImVec2(1, 0));
        ImGui::SetNextWindowSizeConstraints(ImVec2((rb.x - ra.x) * 0.45f, 0), ImVec2(FLT_MAX, room));
    }
    // the list in the rows' own look: a dark rounded panel, rows that light up under the mouse, the current one in gold with a check
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 12 * g_scale);
    ImGui::PushStyleVar(ImGuiStyleVar_PopupRounding, 12 * g_scale);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(8 * g_scale, 8 * g_scale));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 3 * g_scale));
    ImGui::PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1.0f);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.04f, 0.08f, 0.16f, 0.98f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(1, 1, 1, 0.16f));
    ImGui::PushStyleColor(ImGuiCol_Header, ImVec4(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_HeaderHovered, ImVec4(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_HeaderActive, ImVec4(0, 0, 0, 0));
    if (ImGui::BeginPopup("##choices")) {
        float fs = ImGui::GetFontSize(), ih = fs * 1.7f, iw = ImGui::GetContentRegionAvail().x;
        for (int i = 0; i < n; i++) {
            ImVec2 p0 = ImGui::GetCursorScreenPos();
            ImGui::PushID(i);
            bool pick = ImGui::Selectable("##i", false, 0, ImVec2(0, ih));  // (the row is drawn below)
            ImGui::PopID();
            bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
            ImDrawList *dl = ImGui::GetWindowDrawList();
            ImVec2 p1(p0.x + iw, p0.y + ih);
            if (hot) dl->AddRectFilled(p0, p1, IM_COL32(255, 255, 255, 28), 8 * g_scale);
            else if (i == cur) dl->AddRectFilled(p0, p1, IM_COL32(255, 255, 255, 12), 8 * g_scale);
            if (i == cur) {
                float cx = p1.x - 16 * g_scale, cy = (p0.y + p1.y) * 0.5f, k = fs * 0.28f;
                ImVec2 ck[3] = {ImVec2(cx - k, cy), ImVec2(cx - k * 0.3f, cy + k * 0.7f), ImVec2(cx + k, cy - k * 0.7f)};
                dl->AddPolyline(ck, 3, kGold, 0, 2.2f * g_scale);
            }
            float tx = 14 * g_scale;
            if (flag_langs) {
                ui_draw_flag(dl, flag_langs[i], p0.x + tx, p0.y + (ih - fs * 0.95f) * 0.5f, fs * 1.45f, fs * 0.95f);
                tx += fs * 1.45f + fs * 0.45f;
            }
            dl->AddText(ImVec2(p0.x + tx, p0.y + (ih - fs) * 0.5f), i == cur ? kGold : IM_COL32(238, 243, 252, 255), values_are_literal ? names[i] : ui_tr(names[i]));
            if (pick) { if (i != cur) *v = i, picked = true; }
            if (i == cur && !ImGui::IsAnyItemFocused()) ImGui::SetItemDefaultFocus();
            if (i == cur && ImGui::IsWindowAppearing()) ImGui::SetScrollHereY(0.5f);
        }
        ImGui::EndPopup();
    }
    ImGui::PopStyleColor(5);
    ImGui::PopStyleVar(5);
    ImGui::PopID();
    if (picked) return true;
    if (!step) return false;
    int nv = cur + (step == 2 ? 1 : step);
    nv = wrap ? (nv + n) % n : nv < 0 ? 0 : nv >= n ? n - 1 : nv;
    if (nv == cur) return false;
    *v = nv;
    return true;
}

bool opt_slider(const char *label, float *v, float lo, float hi, float step, float def, const char *fmt, const char *desc) {
    char buf[32];
    snprintf(buf, sizeof buf, fmt, *v);
    int s = row(label, buf, fabsf(*v - def) > step * 0.01f, desc, true, true, (*v <= lo + step * 0.01f ? 1 : 0) | (*v >= hi - step * 0.01f ? 2 : 0));
    if (!s) return false;
    float eps = step * 0.01f, n = roundf(*v / step) * step + (s == 2 ? step : s * step);
    if (s == 2 && n > hi + eps) n = lo;  // (A / click past the top wraps to the bottom; left / right stop at the ends)
    *v = n < lo ? lo : n > hi ? hi : n;
    return true;
}

bool opt_int(const char *label, int *v, int lo, int hi, int step, int def, const char *fmt, const char *desc,
             const char *lo_name) {
    char buf[48];
    if (lo_name && *v == lo) snprintf(buf, sizeof buf, "%s", ui_tr(lo_name));
    else snprintf(buf, sizeof buf, fmt, *v);
    int s = row(label, buf, *v != def, desc, true, true, (*v <= lo ? 1 : 0) | (*v >= hi ? 2 : 0));
    if (!s) return false;
    int d = s == 2 ? step : s * step * (g_held && hi - lo > 40 * step ? 10 : 1);
    int n = *v + d;
    if (s == 2 && n > hi) n = lo;  // (A / click past the top wraps; left / right stop at the ends)
    n = n < lo ? lo : n > hi ? hi : n;
    if (n == *v) return false;
    *v = n;
    return true;
}

bool opt_button(const char *label, const char *desc) { return row(label, "", false, desc) == 2; }

bool opt_radio(const char *label, bool selected, const char *desc) {
    bool off = g_next_disabled;
    bool chosen = row(label, "", false, desc) == 2;
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    float r = ImGui::GetFontSize() * 0.32f, cx = b.x - 16 * g_scale - r, cy = (a.y + b.y) * 0.5f;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 col = off ? IM_COL32(150, 150, 140, 255) : selected ? kGold : IM_COL32(200, 212, 232, 255);
    dl->AddCircle(ImVec2(cx, cy), r, col, 0, 2.0f);
    if (selected) dl->AddCircleFilled(ImVec2(cx, cy), r * 0.55f, col);
    return chosen && !selected;
}

bool opt_action(const char *label, const char *value, const char *desc, bool upper,
                bool label_is_literal, bool value_is_literal) {
    return row(label, value ? value : "", false, desc, upper, false, 0, label_is_literal, value_is_literal) == 2;
}

static ImGuiID g_text_editing;  // the text row turned into a field (one at a time)
bool opt_text_editing(const char *label) { return g_text_editing && g_text_editing == ImGui::GetID(label); }

bool opt_text(const char *label, char *buf, size_t cap, const char *hint, const char *desc) {
    ImGuiID &editing = g_text_editing;
    static int focus;        // frames left to give it the keyboard focus
    ImGuiID id = ImGui::GetID(label);
    if (editing != id) {
        if (row(label, buf[0] ? buf : (hint ? ui_tr(hint) : ""), false, desc) == 2) editing = id, focus = 2;
        return false;
    }
    ImGui::PushID(label);
    ImGui::SetNextItemWidth(-1);
    if (focus > 0) ImGui::SetKeyboardFocusHere(), focus--;
    bool done = ui_input_text("##text", buf, cap, ImGuiInputTextFlags_EnterReturnsTrue, hint, label);
    if (ImGui::IsItemFocused()) g_desc_focus = desc ? desc : "";
    if (done || ui_input_text_cancelled() || (focus == 0 && !ImGui::IsItemActive() && !osk_is_open())) editing = 0;
    ImGui::PopID();
    return done;
}

void opt_end(void) {
    ImGui::PopStyleVar();
    if (const char *t = getenv("LARECOMP_OPT_SCROLL")) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(t));  // (test)
    ImGui::EndChild();
    // the description: the hovered row (mouse) wins, else the selected one (controller), else the last shown
    if (!g_desc_hover.empty()) g_desc_shown = g_desc_hover;
    else if (!g_desc_focus.empty()) g_desc_shown = g_desc_focus;
    else if (g_desc_shown.empty()) g_desc_shown = g_desc_first;
    ImGui::SameLine(0, 0);
    ImVec2 p = ImGui::GetCursorScreenPos(), avail = ImGui::GetContentRegionAvail();
    float gap = 24 * g_scale;
    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + gap * 0.5f, p.y), ImVec2(p.x + gap * 0.5f, p.y + avail.y),
                                        IM_COL32(72, 214, 255, 110), 1.0f);
    ImGui::SetCursorScreenPos(ImVec2(p.x + gap, p.y));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14 * g_scale, 6 * g_scale));
    ImGui::BeginChild("##desc", ImVec2(0, avail.y), ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NoNav);
    ImGui::PopStyleVar();
    ImGui::SetWindowFontScale(1.3f);  // (the description reads at a glance)
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(ui_tr(g_desc_shown.c_str()));
    ImGui::PopTextWrapPos();
    ImGui::SetWindowFontScale(1.0f);
    ImGui::EndChild();
    ImGui::PopID();
}
