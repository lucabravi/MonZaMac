"""The Lumiose Online mod's pictures and UI font made from the player's own game files (tools/za/prompt_textures.py
--pictures; runtime/hle/pl.c hands them to the mod). Needs the game files and the picture tool's Python, so it is not in
tools/run_tests.sh: run it after a change to the tool or a new game version.

    python3 tools/test_lumiose_pictures.py            (game files: $MONZAMAC_ROMFS, else the app's data folder)

Skipped when there are no game files or no build/prompts-venv (gmake prompts-helper makes it). About a minute and a half.
Nothing it makes is kept: a temporary folder."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, 'tools', 'za', 'prompt_textures.py')
PY = os.path.join(REPO, 'build', 'prompts-venv', 'bin', 'python')
ROMFS = os.environ.get('MONZAMAC_ROMFS') or os.path.expanduser(
    '~/Library/Application Support/com.monzamac.app/extracted/romfs.bin')


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    assert head[:8] == b'\x89PNG\r\n\x1a\n', path
    return struct.unpack('>II', head[16:24])


@unittest.skipUnless(os.path.exists(ROMFS) and os.path.exists(PY), 'no game files or no build/prompts-venv')
class LumiosePictures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.pics = os.path.join(cls.tmp.name, 'lumiose')
        r = subprocess.run([PY, TOOL, '--romfs', ROMFS, '--out', os.path.join(cls.tmp.name, 'prompts'), '--styles', 'xbox',
                            '--pictures', cls.pics], capture_output=True, text=True, timeout=900)
        cls.code, cls.out = r.returncode, r.stdout + r.stderr

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_runs(self):
        self.assertEqual(self.code, 0, self.out[-2000:])

    def test_font_first_and_whole(self):
        # read straight from the archive, before the pass over every pack: the first thing said (Play online waits for it)
        self.assertIn('-ui.otf: the UI font', self.out.splitlines()[0], self.out[:500])
        with open(self.pics + '-ui.otf', 'rb') as f:
            font = f.read()
        self.assertEqual(font[:4], b'OTTO')  # (an OpenType font: the mod takes it as it is)
        self.assertIn(b'UniversNextPro-Cond', font.replace(b'\0', b''))
        self.assertLess(len(font), 0x280000)  # (the mod's limit for a font it copies: 2.5 MB)

    def test_pokemon_pictures(self):
        names = os.listdir(self.pics)
        self.assertGreater(sum(n.startswith('pm') for n in names), 1000)
        for n in ('pm147_0_0_0.png', 'pm147_0_0_1.png', 'pm25_0_1_0.png'):  # Dratini, its shiny look, female Pikachu
            self.assertEqual(png_size(os.path.join(self.pics, n)), (160, 160), n)

    def test_item_pictures(self):
        names = os.listdir(self.pics)
        self.assertGreater(sum(n.startswith('item_') for n in names), 300)
        for n in ('item_1.png', 'item_4.png', 'item_2619.png'):  # Master Ball, Poke Ball, an item of this game
            self.assertEqual(png_size(os.path.join(self.pics, n)), (160, 160), n)

    def test_made_mark(self):
        # runtime/ui/launcher.mm makes them again while it is not this
        with open(os.path.join(self.pics, '.made')) as f:
            self.assertEqual(f.read(), '3')



@unittest.skipUnless(os.path.exists(ROMFS) and os.path.exists(PY), 'no game files or no build/prompts-venv')
class LumioseFontFallback(unittest.TestCase):
    """The font where the archive lookup can't find it (another game version): found in the pass over every pack."""
    def test_font_found_in_the_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            pics = os.path.join(tmp, 'lumiose')
            r = subprocess.run([PY, TOOL, '--romfs', ROMFS, '--out', os.path.join(tmp, 'prompts'), '--styles', 'xbox',
                                '--pictures', pics], capture_output=True, text=True, timeout=900,
                               env=dict(os.environ, ZAPROMPTS_UI_FONT_HASH='1'))
            out = r.stdout + r.stderr
            self.assertEqual(r.returncode, 0, out[-2000:])
            self.assertIn('looked for in every pack', out)
            with open(pics + '-ui.otf', 'rb') as f:
                self.assertIn(b'UniversNextPro-Cond', f.read().replace(b'\0', b''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
