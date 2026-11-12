# MonZaMac interface localization

This feature branch adds a UI language preference **independent of the game's text language**. It translates MonZaMac's launcher, settings, save management, and dialogs. It does **not** translate Pokémon Legends: Z-A's own assets/text or the separate Lumiose Online mod.

## Available languages

English (`en`, the original and fallback), Italian (`it`), French (`fr`), Spanish (`es`), German (`de`), Brazilian Portuguese (`pt-BR`), Japanese (`ja`), Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Korean (`ko`) and Russian (`ru`).

Select **Settings > About > Application language > Interface language**. The game language dropdown displays the names of languages in their own languages (autonyms). The default **Automatic** follows the preferred macOS language when supported and falls back to English otherwise. The selection is stored as `ui_language` in `larecomp.ini` and applies immediately; `language` remains the separate, pre-existing setting sent to the game.

For testing, launch with `MONZAMAC_UI_LANG=ja` while `ui_language` is set to `auto`. Override the catalog directory with `MONZAMAC_I18N_DIR=/absolute/path/to/i18n/catalog`.

## Catalog and code architecture

- `runtime/ui/i18n.h` and `runtime/ui/i18n.mm`: locale detection, cached UTF-8 catalogs, English fallback and glyph merging using available system fonts.
- `i18n/translations.tsv`: the **single authoritative catalog source**, in UTF-8, with English lookup keys and ten reviewed locale columns.
- `i18n/catalog/*.tsv`: **generated** UTF-8 runtime resources. `tools/bundle_macos.sh` copies the catalogs to `MonZaMac.app/Contents/Resources/i18n/`.
- UI rendering uses `ui_tr(original_english)` or translates existing setting labels and descriptions at the drawing boundary. Internal ImGui IDs, folder names, keys, flags, shader identifiers, product names, version strings, and generated game text stay unchanged.

To update a translation, edit `i18n/translations.tsv` and regenerate:

```sh
python3 tools/build_i18n.py
python3 tools/build_i18n.py --verify
python3 tools/test_i18n.py
```

Translations containing format placeholders must retain the exact conversion specifiers **in the same order**. For example, `%s`, `%d`, and `%.1f` are not prose and cannot be translated. Use the literal `\n` sequence for embedded line breaks and `\s` for significant trailing spaces in translation sources and generated catalogs. The TSV columns are separated by tabs; do not insert literal tab characters into a translation. Use the original English text as its lookup key; do not translate technical IDs or filename extensions. The setting-row uppercase rendering is Unicode-aware for Latin accents and Cyrillic (including the German `ß`), and leaves CJK labels unchanged.

## Testing and limitations

Offline checks validate UTF-8/NFC, generated catalog consistency, placeholder safety, critical context-sensitive strings, dynamic labels, Unicode uppercase integration, and bundling. Build targets discover `runtime/ui/i18n.mm` automatically through the existing `UI_SRC` wildcard.

**A macOS build and visual QA are still required** on an Apple Silicon Mac, especially for glyph availability, font atlas memory, very long translated labels, controller focus, dialogs, and the separate online edition. macOS system font locations can vary with OS versions. Strings not represented in the catalog intentionally fall back to English; some low-level diagnostics and developer help text remain in English, so the UI is not guaranteed to be 100% translated. Localization does not alter game or mod behavior.

Suggested smoke-test matrix: launch with automatic Italian and Japanese system languages; manually switch each supported language while in the settings menu; navigate with keyboard and controller; open the save import/export panels; exercise error, download/setup, and legal screens; verify both standard and `LUMIOSE_ONLINE` editions; restart and check the saved UI/game language preferences independently.
