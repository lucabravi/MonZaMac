"""Shader-input indexing regressions; all containers are synthetic."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('shader_inputs', Path(__file__).parent / 'za/shader_inputs.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def container():
    d = bytearray(0x1100)
    d[:8] = b'BNSH\0\0\0\0'
    d[0xC:0xE] = b'\xff\xfe'
    struct.pack_into('<H', d, 0x16, 0x40)
    struct.pack_into('<I', d, 0x1C, len(d))
    d[0x40:0x44] = b'grsc'
    struct.pack_into('<I', d, 0x5C, 1)
    struct.pack_into('<Q', d, 0x60, 0x90)
    struct.pack_into('<Q', d, 0xA0, 0xE0)
    struct.pack_into('<Q', d, 0xE8, 0x140)
    struct.pack_into('<QQI', d, 0x148, 0x200, 0xA00, 0x100)
    struct.pack_into('<II', d, 0x8FC, 0x20, 0xC0)
    d[0xA00:0xAE0] = bytes(range(0xE0))
    struct.pack_into("<I", d, 0xA00, 0x12345678)
    struct.pack_into("<I", d, 0xA30, 1 << 10)
    return d


class Inputs(unittest.TestCase):
    def test_valid_reference_and_digest(self):
        d = container()
        got = list(mod.shader_spans(d))
        self.assertEqual(got, [(0, 0xA00, 0xE0, 0xC0, 0x20)])
        with tempfile.TemporaryDirectory() as tmp:
            index = {}
            mod.index_container(d, {'kind': 'synthetic', 'offset': 17}, Path(tmp), index)
            self.assertEqual(len(index), 1)
            h, entry = next(iter(index.items()))
            self.assertEqual(h, hashlib.sha256(d[0xA00:0xAE0]).hexdigest())
            self.assertEqual((Path(tmp) / (h + '.bin')).read_bytes(), d[0xA00:0xAE0])
            self.assertEqual(entry['origin']['decoded_offset'], 0xA00)
            self.assertEqual(entry['const_offset'], 0xC0)
            self.assertNotIn('code', entry)

    def test_truncated_and_invalid_offsets(self):
        d = container()
        self.assertEqual(list(mod.shader_spans(d[:-1])), [])
        struct.pack_into('<Q', d, 0x150, 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(list(mod.shader_spans(d)), [])
        d = container()
        struct.pack_into('<II', d, 0x8FC, 0xFFFFFFFF, 0xC0)
        self.assertEqual(list(mod.shader_spans(d)), [])

    def test_embedded_container_and_deduplication(self):
        d = b'padding!' + container()
        self.assertEqual(list(mod.shader_spans(d))[0][1], 0xA08)
        with tempfile.TemporaryDirectory() as tmp:
            index = {}
            for _ in range(2):
                mod.index_container(d, {'kind': 'synthetic'}, Path(tmp), index)
            self.assertEqual(len(index), 1)
            self.assertEqual(len(list(Path(tmp).glob('*.bin'))), 1)


if __name__ == '__main__':
    unittest.main()
