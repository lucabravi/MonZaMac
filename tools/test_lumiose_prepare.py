"""Preparation invariants using synthetic metadata/instructions only."""
from pathlib import Path
import importlib.util
import json
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/lumiose'))
spec = importlib.util.spec_from_file_location('preparation', ROOT / 'tools/lumiose/prepare.py')
prep = importlib.util.module_from_spec(spec); spec.loader.exec_module(prep)

class PreparationTests(unittest.TestCase):
    def test_known_profiles_only(self):
        from versions import PROFILES, profile
        for build in PROFILES:
            self.assertEqual(len(build), 64)
            self.assertTrue(profile(build)[1])
        with self.assertRaises(ValueError): profile('00' * 32)

    def test_build_id_from_nso_is_the_full_padded_id(self):
        # tools/nso.py trims the zero padding of the build id; the profiles and the runtime use all 32 bytes
        from versions import PROFILES, full_build_id, profile
        for build in PROFILES:
            trimmed = build.rstrip('0')
            self.assertEqual(full_build_id(trimmed), build)
            self.assertEqual(profile(trimmed), profile(build))
        from test_nso import fixture
        from nso import Nso
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'module.nso'
            path.write_bytes(fixture(compressed=True, hashes=True))
            self.assertEqual(len(full_build_id(Nso(path).build_id)), 64)
        real = ROOT / 'build/m2-143/original.subsdk9'  # (a local, untracked module, when present)
        if real.is_file():
            self.assertTrue(profile(Nso(real).build_id)[1])

    def test_branch_returns_both_directions(self):
        image = struct.pack('<II', 0x14000004, 0x17fffffc)
        self.assertEqual(list(prep.branch_targets(image, 0x1000, (0, 8))), [0x1010, 0xff4])

    def test_capture_staging_preserves_original_ro_and_data(self):
        from test_nso import fixture
        from nso import Nso
        with tempfile.TemporaryDirectory() as tmp:
            original = Path(tmp) / 'original.nso'; staged = Path(tmp) / 'staged.nso'
            original.write_bytes(fixture(compressed=True, hashes=True))
            n = Nso(original); image = bytearray(n.image)
            image[0x80:0x84] = b'code'; image[0x2000:0x2008] = b'changed!'
            prep.stage_text(original, image, staged)
            result = Nso(staged)
            self.assertEqual(result.image[0x80:0x84], b'code')
            self.assertEqual(result.image[0x1000:], n.image[0x1000:])
            self.assertEqual(result.build_id, n.build_id)
            with self.assertRaises(ValueError): prep.stage_text(original, image[:64], staged)

    def test_ready_requires_all_matching_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            names = ['subsdk9', 'lumiose.dylib', 'lasgame.dylib', 'lasgame.dylib.id']
            for name in names: (directory / name).write_text(name)
            ready = {'identity': 'test', 'outputs': {n: prep.digest(directory / n) for n in names}}
            prep.write_json(directory / 'ready.json', ready)
            self.assertTrue(prep.valid_result(directory, 'test'))
            self.assertFalse(prep.valid_result(directory, 'other'))
            (directory / 'subsdk9').write_text('changed')
            self.assertFalse(prep.valid_result(directory, 'test'))
            for outputs in [{}, [], {'../outside': 'bad'}]:
                ready['outputs'] = outputs; prep.write_json(directory / 'ready.json', ready)
                self.assertFalse(prep.valid_result(directory, 'test'))

if __name__ == '__main__': unittest.main()
