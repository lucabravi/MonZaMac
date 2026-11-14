// Translations are UTF-8, tab-separated catalogs bundled under Resources/i18n.
// All lookups use the original English literal as key; no translation of
// internal ## widget IDs, game strings, protocol fields, shader identifiers.
#include "i18n.h"
#include <math.h>
extern "C" {
#include "../settings.h"
}
#include "imgui.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#ifdef __APPLE__
#import <Foundation/Foundation.h>
#endif

const char *const ui_language_codes[UI_LANGUAGE_COUNT] = {
    "auto", "en", "it", "fr", "es", "de", "pt-BR", "ja", "zh-Hans", "zh-Hant", "ko", "ru"
};
const char *const ui_language_names[UI_LANGUAGE_COUNT] = {
    "Automatic", "English", "Italiano", "Fran\xc3\xa7""ais", "Espa\xc3\xb1ol", "Deutsch",
    "Portugu\xc3\xaas (Brasil)", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e",
    "\xe7\xae\x80\xe4\xbd\x93\xe4\xb8\xad\xe6\x96\x87",
    "\xe7\xb9\x81\xe9\xab\x94\xe4\xb8\xad\xe6\x96\x87",
    "\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4", "\xd0\xa0\xd1\x83\xd1\x81\xd1\x81\xd0\xba\xd0\xb8\xd0\xb9"
};

static int from_locale(const char *loc) {
    if (!loc || !*loc) return UI_LANG_EN;
    std::string s(loc);
    for (char &c : s) if (c == '_') c = '-';
    for (char &c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if (s.rfind("zh", 0) == 0) {
        if (s.find("hant") != std::string::npos || s.find("-tw") != std::string::npos ||
            s.find("-hk") != std::string::npos || s.find("-mo") != std::string::npos) return UI_LANG_ZH_HANT;
        return UI_LANG_ZH_HANS;
    }
    if (s.rfind("pt", 0) == 0) return UI_LANG_PT_BR;
    static const char *const prefixes[] = {"en", "it", "fr", "es", "de", "", "ja", "", "", "ko", "ru"};
    for (int i = UI_LANG_EN; i < UI_LANGUAGE_COUNT; ++i)
        if (*prefixes[i - 1] && s.compare(0, strlen(prefixes[i - 1]), prefixes[i - 1]) == 0)
            return i;
    return UI_LANG_EN;
}

int ui_auto_language(void) {
    // Locale and environment are process-stable; never query NSLocale for every label
    // on every ImGui frame. The saved UI preference can still change immediately.
    static const int detected = []() -> int {
    const char *e = getenv("MONZAMAC_UI_LANG");
    if (e && *e) return from_locale(e);
#ifdef __APPLE__
    NSArray<NSString *> *langs = [NSLocale preferredLanguages];
    if (langs.count) return from_locale(langs.firstObject.UTF8String);
#endif
    e = getenv("LC_ALL");
    if (!e || !*e) e = getenv("LC_MESSAGES");
    if (!e || !*e) e = getenv("LANG");
    return from_locale(e);
    }();
    return detected;
}

static int selected_language(void) {
    int selected = g_settings.ui_language;
    return selected > UI_LANG_AUTO && selected < UI_LANGUAGE_COUNT ? selected : ui_auto_language();
}

const char *ui_language_name(void) { return ui_language_names[selected_language()]; }

static std::string catalog_path(int language) {
    std::string file = std::string(ui_language_codes[language]) + ".tsv";
    const char *override_dir = getenv("MONZAMAC_I18N_DIR");
    if (override_dir && *override_dir) return std::string(override_dir) + "/" + file;
#ifdef __APPLE__
    NSString *dir = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"i18n"];
    if (dir && [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:
                                                             [NSString stringWithUTF8String:file.c_str()]]])
        return std::string(dir.UTF8String) + "/" + file;
#endif
    return std::string("i18n/catalog/") + file; // source checkout, launched from repo root
}

static std::string unescape(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            switch (s[i + 1]) {
                case 'n': out += '\n'; ++i; continue;
                case 'r': out += '\r'; ++i; continue;
                case 't': out += '\t'; ++i; continue;
                case 's': out += ' '; ++i; continue;
                case '\\': out += '\\'; ++i; continue;
            }
        }
        out += s[i];
    }
    return out;
}

struct Catalog {
    std::map<std::string, std::string, std::less<>> strings;
    std::once_flag loaded;
};
static Catalog catalogs[UI_LANGUAGE_COUNT];

static const Catalog &get_catalog(int language) {
    Catalog &c = catalogs[language];
    std::call_once(c.loaded, [&] {
        std::ifstream in(catalog_path(language));
        std::string line;
        while (std::getline(in, line)) {
            size_t tab = line.find('\t');
            if (tab == std::string::npos || line[0] == '#') continue;
            std::string key = unescape(line.substr(0, tab));
            std::string val = unescape(line.substr(tab + 1));
            if (!key.empty() && !val.empty()) c.strings.emplace(std::move(key), std::move(val));
        }
    });
    return c;
}

// Only the character ranges used in current translated menu labels need case
// conversion. A byte-wise toupper() corrupts mixed-case accented text.
static void append_utf8(std::string &s, unsigned int cp) {
    if (cp < 0x80) s.push_back((char)cp);
    else if (cp < 0x800) {
        s.push_back((char)(0xc0 | (cp >> 6)));
        s.push_back((char)(0x80 | (cp & 0x3f)));
    } else if (cp < 0x10000) {
        s.push_back((char)(0xe0 | (cp >> 12)));
        s.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
        s.push_back((char)(0x80 | (cp & 0x3f)));
    } else {
        s.push_back((char)(0xf0 | (cp >> 18)));
        s.push_back((char)(0x80 | ((cp >> 12) & 0x3f)));
        s.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
        s.push_back((char)(0x80 | (cp & 0x3f)));
    }
}

std::string ui_uppercase(const char *utf8) {
    if (!utf8) return {};
    std::string result;
    const unsigned char *s = (const unsigned char *)utf8;
    while (*s) {
        const unsigned char *start = s;
        unsigned int cp = *s++;
        if (cp >= 0xc2 && cp <= 0xdf && (s[0] & 0xc0) == 0x80) {
            cp = ((cp & 0x1f) << 6) | (*s++ & 0x3f);
        } else if (cp >= 0xe0 && cp <= 0xef && s[0] && s[1] &&
                   (s[0] & 0xc0) == 0x80 && (s[1] & 0xc0) == 0x80) {
            cp = ((cp & 0x0f) << 12) | ((s[0] & 0x3f) << 6) | (s[1] & 0x3f);
            s += 2;
        } else if (cp >= 0xf0 && cp <= 0xf4 && s[0] && s[1] && s[2] &&
                   (s[0] & 0xc0) == 0x80 && (s[1] & 0xc0) == 0x80 && (s[2] & 0xc0) == 0x80) {
            cp = ((cp & 0x07) << 18) | ((s[0] & 0x3f) << 12) | ((s[1] & 0x3f) << 6) | (s[2] & 0x3f);
            s += 3;
        } else if (cp >= 0x80) {
            result.append((const char *)start, (size_t)(s - start));
            continue;
        }
        if (cp >= 'a' && cp <= 'z') cp -= 32;
        else if ((cp >= 0x00e0 && cp <= 0x00f6) || (cp >= 0x00f8 && cp <= 0x00fe)) cp -= 32;
        else if (cp == 0x00ff) cp = 0x0178;
        else if (cp == 0x00df) { result += "SS"; continue; }
        else if (cp >= 0x0430 && cp <= 0x044f) cp -= 32; // Cyrillic
        else if (cp == 0x0451) cp = 0x0401; // Cyrillic yo
        append_utf8(result, cp);
    }
    return result;
}

const char *ui_tr(const char *english) {
    if (!english || !*english || english[0] == '#') return english;
    int language = selected_language();
    if (language == UI_LANG_EN) return english;
    const auto &table = get_catalog(language).strings;
    auto it = table.find(english);
    return it == table.end() ? english : it->second.c_str();
}

void ui_merge_translation_fonts(ImGuiIO &io, float font_size, ImFontGlyphRangesBuilder *extras) {
    static ImVector<ImWchar> ranges;
    if (!ranges.Size) {
        ImFontGlyphRangesBuilder b;
        b.AddRanges(io.Fonts->GetGlyphRangesDefault());
        for (int i = UI_LANG_IT; i < UI_LANGUAGE_COUNT; ++i)
            for (const auto &s : get_catalog(i).strings) {
                b.AddText(s.second.c_str());
                // Setting labels are shown in uppercase; their extra glyphs must
                // be in the atlas even if absent from the lower-case catalog.
                b.AddText(ui_uppercase(s.second.c_str()).c_str());
            }
        for (const char *name : ui_language_names) b.AddText(name);
        if (extras) { // character range for trainer names is added per-font below
            // The extras builder has no public iterator. The caller can merge
            // separate glyphs after this function without affecting UI ranges.
        }
        b.BuildRanges(&ranges); // stored for the lifetime of the font atlas
    }
#ifdef __APPLE__
    // ImGui merges only missing glyphs, and macOS supplies these fonts. The
    // launcher/editor's original Baloo2 typeface remains the primary font.
    static const char *const sys[] = {
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode MS.ttf",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/AppleSDGothicNeo.ttc"
    };
#else
    static const char *const sys[] = {
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/arphic/uming.ttc",
        "/usr/share/fonts/truetype/nanum/NanumGothic.ttf"
    };
#endif
    for (const char *p : sys) {
        std::ifstream font(p, std::ios::binary);
        if (!font.good()) continue;
        ImFontConfig cfg;
        cfg.MergeMode = true;
        cfg.PixelSnapH = true;
        io.Fonts->AddFontFromFileTTF(p, font_size, &cfg, ranges.Data);
    }
}

// A language's flag, drawn from shapes (no flag emoji in the fonts, and no pictures to ship): at (x, y), w wide, h high.
void ui_draw_flag(ImDrawList *dl, int lang, float x, float y, float w, float h) {
    auto C = [](int r, int g, int b) { return IM_COL32(r, g, b, 255); };
    float rr = h * 0.18f;
    auto stripes = [&](bool vertical, std::initializer_list<ImU32> cols, std::initializer_list<float> weights) {
        float total = 0; for (float k : weights) total += k;
        float at = 0; int i = 0, n = (int)cols.size();
        auto wi = weights.begin();
        for (ImU32 c : cols) {
            float k = *wi++ / total, a = at, b = at + k;
            ImDrawFlags f = i == 0 ? (vertical ? ImDrawFlags_RoundCornersLeft : ImDrawFlags_RoundCornersTop)
                          : i == n - 1 ? (vertical ? ImDrawFlags_RoundCornersRight : ImDrawFlags_RoundCornersBottom) : ImDrawFlags_RoundCornersNone;
            if (vertical) dl->AddRectFilled(ImVec2(x + w * a, y), ImVec2(x + w * b, y + h), c, rr, f);
            else dl->AddRectFilled(ImVec2(x, y + h * a), ImVec2(x + w, y + h * b), c, rr, f);
            at = b; i++;
        }
    };
    ImVec2 c(x + w * 0.5f, y + h * 0.5f);
    switch (lang) {
    case UI_LANG_IT: stripes(true, {C(0, 146, 70), C(244, 245, 240), C(206, 43, 55)}, {1, 1, 1}); break;
    case UI_LANG_FR: stripes(true, {C(0, 85, 164), C(244, 245, 240), C(239, 65, 53)}, {1, 1, 1}); break;
    case UI_LANG_ES: stripes(false, {C(170, 21, 27), C(241, 191, 0), C(170, 21, 27)}, {1, 2, 1}); break;
    case UI_LANG_DE: stripes(false, {C(20, 20, 20), C(221, 0, 0), C(255, 206, 0)}, {1, 1, 1}); break;
    case UI_LANGUAGE_COUNT: stripes(false, {C(174, 28, 40), C(244, 245, 240), C(33, 70, 139)}, {1, 1, 1}); break;  // (the Netherlands: a game language with no interface translation)
    case UI_LANG_RU: stripes(false, {C(244, 245, 240), C(0, 57, 166), C(213, 43, 30)}, {1, 1, 1}); break;
    case UI_LANG_JA:
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(244, 245, 240), rr);
        dl->AddCircleFilled(c, h * 0.3f, C(188, 0, 45), 24);
        break;
    case UI_LANG_PT_BR:
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(0, 156, 59), rr);
        dl->AddQuadFilled(ImVec2(c.x, y + h * 0.12f), ImVec2(x + w * 0.9f, c.y), ImVec2(c.x, y + h * 0.88f), ImVec2(x + w * 0.1f, c.y), C(255, 223, 0));
        dl->AddCircleFilled(c, h * 0.22f, C(0, 39, 118), 20);
        break;
    case UI_LANG_ZH_HANS: {
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(222, 41, 16), rr);
        ImVec2 sc(x + w * 0.26f, y + h * 0.34f);
        float R = h * 0.22f; ImVec2 pts[10];
        for (int i = 0; i < 10; i++) { float a = -1.5708f + i * 0.62832f, r = i % 2 ? R * 0.42f : R; pts[i] = ImVec2(sc.x + cosf(a) * r, sc.y + sinf(a) * r); }
        dl->AddConcavePolyFilled(pts, 10, C(255, 222, 0));
        break;
    }
    case UI_LANG_ZH_HANT:
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(254, 0, 0), rr);
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w * 0.5f, y + h * 0.5f), C(0, 0, 149), rr, ImDrawFlags_RoundCornersTopLeft);
        dl->AddCircleFilled(ImVec2(x + w * 0.25f, y + h * 0.25f), h * 0.14f, C(255, 255, 255), 16);
        break;
    case UI_LANG_KO:
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(244, 245, 240), rr);
        dl->PathArcTo(c, h * 0.26f, 3.14159f, 6.28318f, 16); dl->PathFillConvex(C(205, 46, 58));
        dl->PathArcTo(c, h * 0.26f, 0.0f, 3.14159f, 16); dl->PathFillConvex(C(0, 71, 160));
        for (int k = 0; k < 4; k++) {  // (the four trigrams, as single bars in the corners)
            float cx = x + w * (k & 1 ? 0.86f : 0.14f), cy = y + h * (k & 2 ? 0.8f : 0.2f);
            dl->AddLine(ImVec2(cx - h * 0.1f, cy + (k & 1 ? -1 : 1) * (k & 2 ? -1 : 1) * h * 0.1f), ImVec2(cx + h * 0.1f, cy - (k & 1 ? -1 : 1) * (k & 2 ? -1 : 1) * h * 0.1f), C(30, 30, 30), h * 0.07f);
        }
        break;
    default:  // English: a simplified Union Jack
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), C(1, 33, 105), rr);
        dl->PushClipRect(ImVec2(x, y), ImVec2(x + w, y + h), true);
        dl->AddLine(ImVec2(x, y), ImVec2(x + w, y + h), C(255, 255, 255), h * 0.24f);
        dl->AddLine(ImVec2(x, y + h), ImVec2(x + w, y), C(255, 255, 255), h * 0.24f);
        dl->AddLine(ImVec2(x, y), ImVec2(x + w, y + h), C(200, 16, 46), h * 0.09f);
        dl->AddLine(ImVec2(x, y + h), ImVec2(x + w, y), C(200, 16, 46), h * 0.09f);
        dl->AddRectFilled(ImVec2(x, c.y - h * 0.17f), ImVec2(x + w, c.y + h * 0.17f), C(255, 255, 255));
        dl->AddRectFilled(ImVec2(c.x - w * 0.09f, y), ImVec2(c.x + w * 0.09f, y + h), C(255, 255, 255));
        dl->AddRectFilled(ImVec2(x, c.y - h * 0.1f), ImVec2(x + w, c.y + h * 0.1f), C(200, 16, 46));
        dl->AddRectFilled(ImVec2(c.x - w * 0.05f, y), ImVec2(c.x + w * 0.05f, y + h), C(200, 16, 46));
        dl->PopClipRect();
        break;
    }
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(255, 255, 255, 60), rr);
}


void ui_check(ImDrawList *dl, ImVec2 c, float r, ImU32 col);  // runtime/ui/saves_ui.mm

// The list of languages inside a popup the caller has begun: a flag and the name in its own language each, the current one
// ticked. s: the caller's layout unit (about 1 pixel at 720 p). True when a language was picked (g_settings.ui_language is set).
bool ui_language_list(float s) {
    bool picked = false;
    float ih = 40 * s, iw = 330 * s, fs = 24 * s;
    for (int i = UI_LANG_AUTO; i < UI_LANGUAGE_COUNT; i++) {
        ImVec2 a = ImGui::GetCursorScreenPos(), b(a.x + iw, a.y + ih);
        ImGui::PushID(i);
        bool pick = ImGui::Selectable("##l", false, 0, ImVec2(iw, ih));
        ImGui::PopID();
        bool sel = g_settings.ui_language == i, over = ImGui::IsItemHovered() || ImGui::IsItemFocused();
        ImDrawList *pl = ImGui::GetWindowDrawList();
        if (over) pl->AddRectFilled(a, b, IM_COL32(255, 255, 255, 28), 8 * s);
        else if (sel) pl->AddRectFilled(a, b, IM_COL32(255, 255, 255, 12), 8 * s);
        ui_draw_flag(pl, i == UI_LANG_AUTO ? ui_auto_language() : i, a.x + 12 * s, a.y + (ih - 24 * s) * 0.5f, 36 * s, 24 * s);
        const char *name = i == UI_LANG_AUTO ? ui_tr("Automatic") : ui_language_names[i];
        pl->AddText(ImGui::GetFont(), fs, ImVec2(a.x + 62 * s, a.y + (ih - fs) * 0.5f),
                    sel ? IM_COL32(72, 214, 255, 255) : IM_COL32(238, 244, 255, 255), name);
        if (sel) ui_check(pl, ImVec2(b.x - 22 * s, (a.y + b.y) * 0.5f), 11 * s, IM_COL32(72, 214, 255, 255));
        if (pick && !sel) { g_settings.ui_language = i; settings_save(); picked = true; }
    }
    return picked;
}

bool ui_button(const char *label, ImVec2 size) {
    float need = ImGui::CalcTextSize(label).x + ImGui::GetStyle().FramePadding.x * 4;
    if (size.x > 0 && size.x < need) size.x = need;
    return ImGui::Button(label, size);
}

extern "C" const char *ui_tr_c(const char *english) { return ui_tr(english); }  // (the Discord presence thread, plain C)
