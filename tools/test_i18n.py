#!/usr/bin/env python3
"""Offline catalog and source integration checks; no game files are needed."""
from __future__ import annotations
import re
import unicodedata
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_i18n import LANGUAGES, I18N, ROOT, placeholders, source_data


def unescape(s: str) -> str:
    # Exactly mirrors the supported runtime TSV escapes.
    out = []
    i = 0
    escapes = {'n': '\n', 't': '\t', 'r': '\r', 's': ' ', '\\': '\\'}
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s) and s[i + 1] in escapes:
            out.append(escapes[s[i + 1]])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def catalog(lang: str) -> dict[str, str]:
    entries: dict[str, str] = {}
    path = I18N / 'catalog' / (lang + '.tsv')
    for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if line.startswith('#'):
            continue
        assert '\t' in line, f'{path}:{n}: missing separator'
        key, val = map(unescape, line.split('\t', 1))
        assert key and val, f'{path}:{n}: empty entry'
        assert key not in entries, f'{path}:{n}: duplicate {key!r}'
        entries[key] = val
    return entries


class LocalizationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = source_data()
        cls.tables = {lang: catalog(lang) for lang in LANGUAGES}

    def test_english_source_completeness(self):
        self.assertEqual(set(self.source), set(self.tables['en']))
        for key, value in self.tables['en'].items():
            self.assertEqual(key, value)

    def test_translation_coverage_and_placeholders(self):
        for lang in LANGUAGES[1:]:
            with self.subTest(lang=lang):
                entries = self.tables[lang]
                self.assertEqual(len(entries), len(self.source))
                for key, val in entries.items():
                    self.assertIn(key, self.source)
                    self.assertEqual(placeholders(key), placeholders(val), (lang, key))
                    self.assertNotIn('\ufffd', val)
                    self.assertNotIn('\x00', val)
                    self.assertEqual(unicodedata.normalize('NFC', val), val, (lang, key))

    def test_critical_labels(self):
        for lang in LANGUAGES[1:]:
            entries = self.tables[lang]
            for key in ('Settings', 'Play offline', 'Play online', 'Saves', 'Quit',
                        'Application language', 'Interface language', 'Game text language',
                        'Add DLC', 'Volume', 'Import a save'):
                self.assertIn(key, entries, (lang, key))

    def test_context_sensitive_terms(self):
        for lang in LANGUAGES[1:]:
            with self.subTest(lang=lang):
                e = self.tables[lang]
                for key in ('Switch keys', 'New save', 'New game', 'PLAY  %s',
                            'today', 'yesterday', '%ld days ago', 'On', 'Off',
                            'Up to %s', 'Match display (%dp)',
                            'Up to match display (%dp)', '%g degrees',
                            ' Click to update.', ' Click to check again.'):
                    self.assertIn(key, e)
                self.assertNotEqual(e['Switch keys'], e['Keyboard'])
                self.assertNotEqual(e['New save'], e['New game'])
                self.assertNotEqual(e['On'], e['Off'])
                self.assertNotEqual(e['PLAY  %s'], e['Play this save'])
                self.assertTrue(e[' Click to update.'].startswith(' '))

    def test_unicode_case_and_dynamic_labels_are_wired(self):
        option_rows = (ROOT / 'runtime/ui/option_rows.mm').read_text()
        i18n = (ROOT / 'runtime/ui/i18n.mm').read_text()
        menu = (ROOT / 'runtime/ui/menu.mm').read_text()
        launcher = (ROOT / 'runtime/ui/launcher.mm').read_text()
        self.assertIn('std::string t = ui_uppercase(ui_tr(title));', option_rows)
        self.assertIn('std::string ui_uppercase(const char *utf8)', i18n)
        self.assertIn('ui_tr("Up to match display (%dp)")', menu)
        self.assertIn('ui_tr("%g degrees")', menu)
        self.assertIn('ui_tr(status)', launcher)
        self.assertIn('ui_tr("Switch keys")', launcher)

    def test_source_of_truth_is_single_tsv(self):
        for name in ('translations_extra_western.txt', 'translations_extra_cjk.txt',
                     'translations_reviewed.txt', 'translations_help.txt',
                     'translations_missing.txt'):
            self.assertFalse((I18N / name).exists(), name)
        self.assertTrue((I18N / 'translations.tsv').is_file())

    def test_catalogs_bundled_by_macos_packager(self):
        script = (ROOT / 'tools' / 'bundle_macos.sh').read_text()
        self.assertIn('i18n/catalog/', script)
        for lang in LANGUAGES:
            self.assertTrue((I18N / 'catalog' / (lang + '.tsv')).is_file())

    def test_runtime_is_compiled_from_ui_wildcard(self):
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('UI_SRC   := $(wildcard runtime/ui/*.mm)', makefile)
        self.assertTrue((ROOT / 'runtime/ui/i18n.mm').is_file())
        self.assertTrue((ROOT / 'runtime/ui/i18n.h').is_file())


    def test_operational_ambiguities_have_explicit_meaning(self):
        # "PLAY" is elapsed save playtime; "route" is input recording, not a geographic path.
        tokens = {
            'it': ('TEMPO DI GIOCO', 'sequenza', 'Verifica'),
            'fr': ('TEMPS DE JEU', 'séquence', 'Vérifiez'),
            'es': ('TIEMPO DE JUEGO', 'secuencia', 'Comprueba'),
            'de': ('SPIELZEIT', 'Eingabe', 'Prüfe'),
            'pt-BR': ('TEMPO DE JOGO', 'sequência', 'Confira'),
            'ja': ('プレイ時間', '操作', '確認'),
            'zh-Hans': ('游戏时长', '操作', '确认'),
            'zh-Hant': ('遊戲時長', '操作', '確認'),
            'ko': ('플레이 시간', '입력', '확인'),
            'ru': ('ВРЕМЯ ИГРЫ', 'ввода', 'Убедитесь'),
        }
        for lang, (duration, route, free_space) in tokens.items():
            e = self.tables[lang]
            with self.subTest(lang=lang):
                self.assertIn(duration, e['PLAY  %s'])
                self.assertIn(route, e['Record a route'])
                self.assertIn(free_space, e["Make sure there's about 12 GB free and try again."])
                self.assertIn('Pokémon Legends: Z-A', e['I own an original copy of Pokémon Legends: Z-A'])
                self.assertNotEqual(e['Quit to Desktop'], e['Quit to Start Screen'])
                self.assertNotEqual(e['Input device'], e['Keyboard'])
                self.assertIn('7z', e['This file is a 7z archive despite its .nsp name. Choose an uncompressed NSP or XCI game package.'])

    def test_native_names_are_not_localized_as_interface_labels(self):
        opts = (ROOT / 'runtime/ui/option_rows.mm').read_text()
        saves = (ROOT / 'runtime/ui/saves_ui.mm').read_text()
        menu = (ROOT / 'runtime/ui/menu.mm').read_text()
        self.assertIn('literal_label ? label', opts)
        self.assertIn('literal_value ? value', opts)
        self.assertIn('opt_action(g_slots[cur].name, "In use", d, false, true, false)', saves)
        self.assertIn('opt_action(g_slots[i].name, v, d, false, true, true)', saves)
        self.assertIn('opt_choice("Input device"', menu)
        self.assertIn('false, true))', menu)
        self.assertIn('std::string(ui_tr(label)) + "###button"', saves)
        self.assertIn('ImGui::PushID(label)', saves)

    def test_visible_save_dialogs_and_backend_errors_have_catalogs(self):
        for lang in LANGUAGES[1:]:
            e = self.tables[lang]
            for key in (
                'Keep it', 'Yes, reload it', 'Yes, play it', 'Name', "Couldn't delete it.",
                'Y   hide the team', 'Y   show the team', 'I   hide the team',
                'I   show the team', 'Imported as "%s".', 'Copied as "%s".',
                'Recording "%s".', 'Exported to %s', "Couldn't export it to %s",
                "Couldn't prepare the import.",
                'No save in that folder (a folder with the file "main").',
                "That file couldn't be opened: choose a .zip or a folder.",
                'No save in that file (a folder with the file "main").',
                "That's too big to be a Z-A save.", "The save couldn't be copied.",
                "That's not a Pokémon Legends: Z-A save.",
            ):
                self.assertIn(key, e, (lang, key))
        saves = (ROOT / 'runtime/ui/saves_ui.mm').read_text()
        self.assertIn('"%s", ui_tr(title)', saves)
        self.assertIn('ui_tr(g_err)', saves)
        self.assertIn('ui_tr(g_msg)', saves)
        self.assertIn('char pl[16], pline[128];', saves)
        self.assertIn('Never split a multi-byte UTF-8 code point', saves)

    def test_online_statuses_and_font_feedback_are_translatable(self):
        launcher = (ROOT / 'runtime/ui/launcher.mm').read_text()
        for key in (
            'Lumiose Online (separate service)', 'Unsupported Lumiose build.',
            'Needs game version 2.0.2', 'Your game files are another version.',
            'This build has no online setup.',
            'Prepared once on this Mac; it takes a few minutes.',
            'Could not find the program to restart.',
            'Could not restart the game for online play.',
            'The online version could not be prepared.',
            'Could not start the online setup.',
            'Imported fonts: %d. Unrecognized files: %d. Active after the next game start.',
            'Imported fonts removed: the substitute font is used.',
        ):
            for lang in LANGUAGES[1:]:
                self.assertIn(key, self.tables[lang], (lang, key))
        self.assertIn('ui_tr("Imported fonts: %d.', launcher)
        self.assertIn('g_fonts_imported >= 0', launcher)
        self.assertIn('const char *label = ui_tr("Back")', launcher)
        self.assertIn(r'ui_tr("Ready \xc2\xb7 %s")', launcher)


if __name__ == '__main__':
    unittest.main(verbosity=2)
