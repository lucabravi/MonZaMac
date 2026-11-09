"""Preparation invariants using synthetic metadata/instructions only."""
from pathlib import Path
import importlib.util
import json
import struct
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/lumiose'))
spec = importlib.util.spec_from_file_location('preparation', ROOT / 'tools/lumiose/prepare.py')
prep = importlib.util.module_from_spec(spec); spec.loader.exec_module(prep)

class PreparationTests(unittest.TestCase):
    def jump_table_nso(self, values):
        code = [0xB0000019, 0x91000339,  # adrp x25, #0x1000 ; add x25, x25, #0
                0x7100083F, 0x54000808,  # cmp w1, #2 ; b.hi
                0x78615B21, 0x10000062,  # ldrh w1, [x25, w1, uxtw #1] ; adr x2, #0x20
                0x8B21A841, 0xD61F0020]  # add x1, x2, w1, sxth #2 ; br x1
        image = bytearray(struct.pack('<%dI' % len(code), *code)).ljust(0x1000, b'\0')
        image += struct.pack('<%dh' % len(values), *values).ljust(0x100, b'\0')
        return types.SimpleNamespace(text=(0, 0x1000), rodata=(0x1000, 0x100), image=bytes(image))

    def test_finds_a_switch_table_and_its_bound_in_the_code(self):
        from versions import jump_tables
        self.assertEqual(jump_tables(self.jump_table_nso([0, 1, 2])), [(0x1000, 3, 'h', 0x20)])

    def test_leaves_out_a_table_pointing_outside_the_code(self):
        from versions import jump_tables
        self.assertEqual(jump_tables(self.jump_table_nso([0, 0x7000, 2])), [])

    def test_build_id_from_nso_is_the_full_padded_id(self):
        # tools/nso.py trims the zero padding of the build id; the runtime uses all 32 bytes
        from versions import full_build_id
        from test_nso import fixture
        from nso import Nso
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'module.nso'
            path.write_bytes(fixture(compressed=True, hashes=True))
            self.assertEqual(len(full_build_id(Nso(path).build_id)), 64)

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
