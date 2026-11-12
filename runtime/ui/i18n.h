// Launcher/overlay interface localization. This is deliberately separate from the
// emulated console language (settings.language), which controls the game's text.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Index 0 follows the OS; 1..11 select a UI translation (English is 1).
enum { UI_LANG_AUTO = 0, UI_LANG_EN = 1, UI_LANG_IT, UI_LANG_FR, UI_LANG_ES,
       UI_LANG_DE, UI_LANG_PT_BR, UI_LANG_JA, UI_LANG_ZH_HANS, UI_LANG_ZH_HANT,
       UI_LANG_KO, UI_LANG_RU, UI_LANGUAGE_COUNT };
extern const char *const ui_language_codes[UI_LANGUAGE_COUNT];
extern const char *const ui_language_names[UI_LANGUAGE_COUNT];
const char *ui_tr(const char *english);
int ui_auto_language(void);
const char *ui_language_name(void);
#ifdef __cplusplus
}
#include <string>
struct ImGuiIO;
struct ImFontGlyphRangesBuilder;
// Merge glyphs used by the translated UI from installed system fonts; never
// package proprietary fonts. Call just after adding each non-title ImGui font.
// Uppercase supported-language UI labels without breaking UTF-8 text.
std::string ui_uppercase(const char *utf8);
struct ImDrawList;
// The flag of a UI_LANG_* language (English: the Union Jack; UI_LANGUAGE_COUNT itself: the Netherlands), drawn from shapes at (x, y), w by h.
void ui_draw_flag(ImDrawList *dl, int lang, float x, float y, float w, float h);
struct ImVec2;
// ImGui::Button that is never narrower than its caption (translations run long): size.x is a minimum.
bool ui_button(const char *label, ImVec2 size);
bool ui_language_list(float s);  // the language choices inside an open popup; true when one was picked
void ui_merge_translation_fonts(ImGuiIO &io, float font_size, ImFontGlyphRangesBuilder *extras = nullptr);
#endif
