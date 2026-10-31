"""Native NSO/LZ4 bounds checks on generated fixtures; use SANITIZE=1 for ASan/UBSan."""
import os
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile
import unittest

import lz4.block
from test_nso import fixture, symbol_fixture
from nso import DT_RELA, DT_RELASZ, DT_RELR, DT_RELRSZ, DT_HASH, DT_SYMTAB, DT_STRTAB, DT_STRSZ


class NativeLoader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.root = Path(__file__).resolve().parents[1]
        cls.exe = Path(cls.tmp.name) / 'test_loader'
        flags = ['-U__linux__'] if sys.platform.startswith('linux') else []
        # The production target is macOS; this test provides its own platform functions.
        if os.environ.get('SANITIZE') == '1':
            flags += ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
        subprocess.run([os.environ.get('CC', 'clang'), '-O1', '-g', *flags,
                        str(cls.root / 'tools/test_loader.c'), '-o', str(cls.exe)], check=True)
        cls.env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')

    def decode(self, data, size):
        return subprocess.run([str(self.exe), 'lz4', data.hex(), str(size)],
                              env=self.env, capture_output=True, timeout=10)

    def load(self, data):
        path = Path(self.tmp.name) / 'fixture.nso'
        path.write_bytes(data)
        return subprocess.run([str(self.exe), 'load', str(path)],
                              env=self.env, capture_output=True, timeout=10)

    def rejected(self, result):
        self.assertEqual(result.returncode, 42, result.stderr.decode(errors='replace')[-2000:])

    def test_valid_compressed_blocks(self):
        rng = random.Random(15)
        samples = [b'', b'hello', b'a' * 4096, bytes(range(256)) * 8]
        samples += [rng.randbytes(size) for size in (15, 16, 255, 256, 1024)]
        for value in samples:
            with self.subTest(size=len(value)):
                result = self.decode(lz4.block.compress(value, store_size=False), len(value))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, value)

    def test_truncated_extensions_and_offsets(self):
        for data in (b'\xf0', b'\xf0\xff', b'\x10A\x01', b'\x1fA\x01\x00', b'\x1fA\x01\x00\xff'):
            with self.subTest(block=data.hex()):
                self.rejected(self.decode(data, 4096))

    def test_invalid_back_references(self):
        for data in (b'\x10A\x00\x00', b'\x10A\x02\x00', b'\x00\x01\x00'):
            with self.subTest(block=data.hex()):
                self.rejected(self.decode(data, 4096))

    def test_output_capacity_and_truncated_literals(self):
        for data, size in ((b'\x20A', 10), (b'\x20AB', 1), (b'\x10A\x01\x00', 3)):
            with self.subTest(block=data.hex(), size=size):
                self.rejected(self.decode(data, size))

    def test_loads_valid_compressed_and_uncompressed_nso(self):
        a, b = self.load(fixture()), self.load(fixture(compressed=True))
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertEqual(b.returncode, 0, b.stderr)
        self.assertEqual(a.stdout, b.stdout)
        self.assertEqual(a.stdout[0x2000:0x2008], b'payload\0')

    def test_symbol_names_with_optional_string_table_size(self):
        for with_strsz in (True, False):
            with self.subTest(with_strsz=with_strsz):
                self.assertEqual(self.load(symbol_fixture(with_strsz)).returncode, 0)
        raw = symbol_fixture()
        struct.pack_into('<I', raw, 0x358, 16)
        self.rejected(self.load(raw))

    def test_header_and_segment_bounds(self):
        for data in (b'', b'NSO0', fixture()[:0xff], fixture()[:-1], fixture(compressed=True)[:-1]):
            with self.subTest(length=len(data)):
                self.rejected(self.load(data))
        for off, value in ((0x34, 0xfffff000), (0x38, 0xfffffff0), (0x3c, 0xfffffff0), (0x24, 0x80)):
            raw = fixture()
            struct.pack_into('<I', raw, off, value)
            with self.subTest(offset=off):
                self.rejected(self.load(raw))

    def test_mod0_dynamic_and_relocation_bounds(self):
        for off, value in ((0x104, 0xfffffff0), (0x140, 0), (0x144, 0xffffffb0)):
            raw = fixture()
            struct.pack_into('<I', raw, off, value)
            with self.subTest(offset=off):
                self.rejected(self.load(raw))
        for dynamic in (((DT_RELA, 0x2000), (DT_RELASZ, 25)),
                        ((DT_RELA, 0x3ff8), (DT_RELASZ, 24)),
                        ((DT_RELR, 0x2000), (DT_RELRSZ, 9)),
                        ((DT_HASH, 0x3ffc), (DT_SYMTAB, 0x2000)),
                        ((DT_STRTAB, 0x3ff0), (DT_STRSZ, 0x40))):
            with self.subTest(dynamic=dynamic):
                self.rejected(self.load(fixture(dynamic=dynamic)))
        raw = fixture(dynamic=((DT_RELR, 0x2000), (DT_RELRSZ, 8)))
        struct.pack_into('<Q', raw, 0x300, 3)
        self.rejected(self.load(raw))

    def test_constructor_metadata_is_bounded(self):
        for dynamic in (((25, 0x3ff8), (27, 16)), ((26, 0x3ff8), (28, 16)),
                        ((12, 0x4000),), ((13, 0x4000),), ((27, 8),),
                        ((25, 0x2081), (27, 8)), ((25, 0x2080), (27, 7))):
            with self.subTest(dynamic=dynamic):
                self.rejected(self.load(fixture(dynamic=dynamic)))
        self.assertEqual(self.load(fixture(dynamic=((12, 0x80), (25, 0x2080), (27, 8)))).returncode, 0)

    def test_rela_supports_unaligned_pointer_initializers(self):
        # AArch64 ELF permits an ABS64/RELATIVE target in a packed structure.
        for target in (0x2080, 0x2081):
            raw = fixture(dynamic=((DT_RELA, 0x2000), (DT_RELASZ, 24)))
            struct.pack_into('<QQq', raw, 0x300, target, 1027, 0x80)
            result = self.load(raw)
            self.assertEqual(result.returncode, 0, result.stderr)
            base = int(re.search(rb'at ([0-9a-f]+) size', result.stderr)[1], 16)
            self.assertEqual(struct.unpack_from('<Q', result.stdout, target)[0], base + 0x80)


if __name__ == '__main__':
    unittest.main()
