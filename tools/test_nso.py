"""Synthetic NSO loader regressions; no game files are used."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

import lz4.block

from nso import Nso, DT_NULL, DT_STRTAB, DT_STRSZ, DT_SYMTAB, DT_HASH, DT_RELA, DT_RELASZ, DT_RELR, DT_RELRSZ


def fixture(compressed=False, hashes=False, dynamic=()):
    text, ro, data = bytearray(0x100), bytearray(0x100), bytearray(0x100)
    struct.pack_into('<I', text, 4, 0x40)
    text[0x40:0x44] = b'MOD0'
    struct.pack_into('<6i', text, 0x44, 0x1000 - 0x40, 0x2100 - 0x40,
                     0x2200 - 0x40, -0x40, -0x40, -0x40)
    for i, pair in enumerate((*dynamic, (DT_NULL, 0))):
        struct.pack_into('<QQ', ro, i * 16, *pair)
    data[:8] = b'payload\0'
    header = bytearray(0x100)
    header[:4] = b'NSO0'
    header[0x40:0x60] = bytes(range(32))
    struct.pack_into('<I', header, 0xc, (7 if compressed else 0) | (0x38 if hashes else 0))
    struct.pack_into('<I', header, 0x3c, 0x100)
    payload = bytearray()
    for i, segment in enumerate((text, ro, data)):
        stored = lz4.block.compress(bytes(segment), store_size=False) if compressed else segment
        struct.pack_into('<III', header, 0x10 + 0x10 * i, 0x100 + len(payload), i * 0x1000, len(segment))
        struct.pack_into('<I', header, 0x60 + i * 4, len(stored))
        header[0xa0 + i * 32:0xc0 + i * 32] = hashlib.sha256(segment).digest()
        payload += stored
    return header + payload


def symbol_fixture(with_strsz=True):
    dynamic = ((DT_HASH, 0x20c0), (DT_SYMTAB, 0x2040), (DT_STRTAB, 0x2080))
    raw = fixture(dynamic=dynamic + (((DT_STRSZ, 16),) if with_strsz else ()))
    struct.pack_into('<II', raw, 0x3c0, 1, 2)
    struct.pack_into('<IBBHQQ', raw, 0x358, 1, 0x12, 0, 1, 0x80, 4)
    raw[0x380:0x389] = b'\0fixture\0'
    return raw


class NsoValidation(unittest.TestCase):
    def load(self, raw):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'synthetic.nso'
            path.write_bytes(raw)
            return Nso(path)

    def test_compressed_and_uncompressed_images_match(self):
        plain = self.load(fixture())
        packed = self.load(fixture(compressed=True, hashes=True))
        self.assertEqual(plain.image, packed.image)
        self.assertEqual(plain.text, (0, 0x100))
        self.assertEqual(plain.image[0x2000:0x2008], b'payload\0')
        self.assertEqual(plain.image[0x2100:0x2200], bytes(0x100))

    def test_symbols_with_optional_string_table_size(self):
        for with_strsz in (True, False):
            with self.subTest(with_strsz=with_strsz):
                module = self.load(symbol_fixture(with_strsz))
                self.assertEqual(module.exports(), [('fixture', 0x12, 1, 0x80, 4)])

    def test_uncompressed_uses_segment_size(self):
        raw = fixture()
        raw[0x60:0x6c] = bytes(12)  # compressed-size fields are unused for stored segments
        self.assertEqual(self.load(raw).image, self.load(fixture()).image)

    def test_truncated_and_invalid_header(self):
        for raw in (b'', b'NSO0', bytes(0x100), fixture()[:0xff]):
            with self.subTest(size=len(raw)), self.assertRaisesRegex(ValueError, 'NSO'):
                self.load(raw)

    def test_segment_truncation(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed), self.assertRaisesRegex(ValueError, 'segment'):
                self.load(fixture(compressed=compressed)[:-1])

    def test_decompressed_size_is_exact(self):
        raw = fixture(compressed=True)
        struct.pack_into('<I', raw, 0x18, 0x101)
        with self.assertRaisesRegex(ValueError, 'size'):
            self.load(raw)

    def test_segment_hash_checked_when_flag_set(self):
        raw = fixture(hashes=True)
        raw[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'hash'):
            self.load(raw)
        struct.pack_into('<I', raw, 0xc, 0)
        self.load(raw)  # hash fields do not apply when the flags are clear

    def test_overlapping_memory_segments(self):
        raw = fixture()
        struct.pack_into('<I', raw, 0x24, 0x80)
        with self.assertRaisesRegex(ValueError, 'overlap'):
            self.load(raw)

    def test_image_limit_checked_before_allocation(self):
        raw = fixture()
        struct.pack_into('<I', raw, 0x34, 0xfffff000)
        with mock.patch('nso.bytearray', side_effect=AssertionError('allocation before validation'), create=True):
            with self.assertRaisesRegex(ValueError, 'image'):
                self.load(raw)

    def test_bad_mod0_and_dynamic_offsets(self):
        raw = fixture()
        struct.pack_into('<I', raw, 0x104, 0xfffffff0)
        with self.assertRaises(ValueError):
            self.load(raw)
        raw = fixture()
        struct.pack_into('<i', raw, 0x144, -0x50)
        with self.assertRaisesRegex(ValueError, 'dynamic'):
            self.load(raw)

    def test_dynamic_table_must_terminate_inside_image(self):
        raw = fixture()
        struct.pack_into('<i', raw, 0x144, 0x2ff8 - 0x40)
        with self.assertRaisesRegex(ValueError, 'dynamic'):
            self.load(raw)

    def test_symbol_and_string_tables_are_bounded(self):
        raw = fixture(dynamic=((DT_HASH, 0x20fc), (DT_SYMTAB, 0x2000), (DT_STRTAB, 0x2000)))
        struct.pack_into('<I', raw, 0x3fc, 0xffffffff)  # nbucket; nchain falls in zeroed BSS
        # A hash outside the entire image is rejected before its count is read.
        struct.pack_into('<Q', raw, 0x208, 0x2ffc)
        with self.assertRaises(ValueError):
            self.load(raw)
        raw = fixture(dynamic=((DT_STRTAB, 0x2ff0), (DT_STRSZ, 0x40)))
        with self.assertRaisesRegex(ValueError, 'string'):
            self.load(raw)

    def test_relocation_tables_and_targets_are_bounded(self):
        for dynamic in (((DT_RELA, 0x2000), (DT_RELASZ, 25)),
                        ((DT_RELA, 0x2ff8), (DT_RELASZ, 24)),
                        ((DT_RELR, 0x2000), (DT_RELRSZ, 9)), ((DT_RELASZ, 24),)):
            with self.subTest(dynamic=dynamic), self.assertRaises(ValueError):
                self.load(fixture(dynamic=dynamic))
        raw = fixture(dynamic=((DT_RELR, 0x2000), (DT_RELRSZ, 8)))
        struct.pack_into('<Q', raw, 0x300, 3)  # bitmap before any base address
        with self.assertRaisesRegex(ValueError, 'RELR'):
            self.load(raw)

    def test_constructor_metadata_is_bounded(self):
        for dynamic in (((25, 0x2ff8), (27, 16)), ((26, 0x2ff8), (28, 16)),
                        ((12, 0x3000),), ((13, 0x3000),), ((27, 8),),
                        ((25, 0x2081), (27, 8)), ((25, 0x2080), (27, 7))):
            with self.subTest(dynamic=dynamic), self.assertRaises(ValueError):
                self.load(fixture(dynamic=dynamic))
        self.load(fixture(dynamic=((12, 0x80), (25, 0x2080), (27, 8))))


if __name__ == '__main__':
    unittest.main()
