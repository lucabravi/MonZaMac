"""Asset-free package/import boundary checks: python3 tools/test_game_extract.py."""
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest

from game_extract import ImportFailure, Package, in_field, program_content, run_tool, validate_extracted


def container(magic, files):
    names = b''.join(n.encode() + b'\0' for n, _ in files)
    table = bytearray(); off = name_off = 0
    for name, data in files:
        entry = struct.pack('<QQII', off, len(data), name_off, 0)
        table += entry if magic == b'PFS0' else entry + bytes(40)
        off += len(data); name_off += len(name.encode()) + 1
    return struct.pack('<4sIII', magic, len(files), len(names), 0) + table + names + b''.join(d for _, d in files)


def cnmt(title=0x0100F43008C44000, kind=0x80):
    header = bytearray(32)
    struct.pack_into('<QIBxHH', header, 0, title, 1, kind, 0, 1)
    entry = bytearray(56); entry[32:48] = bytes.fromhex('ab' * 16); entry[54] = 1
    return bytes(header + entry)


class ImportBoundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def package(self, data, suffix='.nsp'):
        p = self.root / ('game' + suffix); p.write_bytes(data); return Package(p)

    def test_reads_only_named_bounded_members(self):
        p = self.package(container(b'PFS0', [('a.nca', b'abc'), ('b.nca', b'defg')]))
        dest = self.root / 'out.nca'; p.copy('b.nca', dest)
        self.assertEqual(dest.read_bytes(), b'defg')

    def test_rejects_unsafe_duplicate_and_truncated_entries(self):
        for data in (container(b'PFS0', [('../escape', b'bad')]),
                     container(b'PFS0', [('a', b'1'), ('a', b'2')]),
                     container(b'PFS0', [('a', b'abc')])[:-1], b'PFS0'):
            with self.subTest(data=data[:20]), self.assertRaises(ImportFailure): self.package(data)

    def test_reads_xci_secure_partition(self):
        secure = container(b'HFS0', [('a.nca', b'abc')])
        root = container(b'HFS0', [('secure', secure)])
        header = bytearray(0x200); header[0x100:0x104] = b'HEAD'
        struct.pack_into('<Q', header, 0x130, len(header))
        p = self.package(header + root, '.xci')
        dest = self.root / 'out'; p.copy('a.nca', dest)
        self.assertEqual(dest.read_bytes(), b'abc')

    def test_recognizes_an_archive_even_with_nsp_extension(self):
        with self.assertRaises(ImportFailure) as error:
            self.package(b'7z\xbc\xaf' + bytes(64))
        self.assertEqual(error.exception.code, 'archive-7z-nsp')
        archive = self.root / 'update.nsp'; archive.write_bytes(b'7z\xbc\xaf' + bytes(64))
        with self.assertRaises(ImportFailure) as error: in_field('update', Package, archive)
        self.assertEqual((error.exception.field, error.exception.code), ('update', 'archive-7z-nsp'))
        with self.assertRaises(ImportFailure) as error:
            self.package(b'7z\xbc\xaf' + bytes(64), '.7z')
        self.assertEqual(error.exception.code, 'archive-7z')

    def test_cnmt_checks_game_kind_and_program(self):
        self.assertEqual(program_content(cnmt(), False), 'ab' * 16 + '.nca')
        self.assertEqual(program_content(cnmt(0x0100F43008C44800, 0x81), True), 'ab' * 16 + '.nca')
        for data, patch in ((cnmt(1), False), (cnmt(), True), (cnmt()[:-1], False)):
            with self.subTest(patch=patch), self.assertRaises(ImportFailure): program_content(data, patch)

    def test_tool_failure_never_prints_raw_output(self):
        tool = self.root / 'tool'
        tool.write_text('#!/bin/sh\necho SECRET_DO_NOT_LOG\necho SECRET_DO_NOT_LOG >&2\nexit 1\n')
        tool.chmod(0o700)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            with self.assertRaises(ImportFailure) as error: run_tool(tool, [])
        self.assertNotIn('SECRET_DO_NOT_LOG', out.getvalue() + str(error.exception))

    def test_validates_the_za_pack_layout_and_build(self):
        exefs = self.root / 'exefs'; exefs.mkdir()
        build_id = bytes.fromhex('b1f12fd919eae86a')
        (exefs / 'main').write_bytes(bytes(64) + build_id)
        for name in ('main.npdm', 'rtld', 'sdk'): (exefs / name).write_bytes(b'test')
        arc = self.root / 'romfs/arc'; arc.mkdir(parents=True)
        (arc / 'data.trpfd').write_bytes(b'test')
        validate_extracted(self.root, build_id)
        with self.assertRaises(ImportFailure) as error: validate_extracted(self.root, bytes(8))
        self.assertEqual(error.exception.code, 'version')
        (arc / 'data.trpfd').unlink()
        (self.root / 'romfs/region_common').mkdir()
        with self.assertRaises(ImportFailure) as error: validate_extracted(self.root, build_id)
        self.assertEqual(error.exception.code, 'files')


if __name__ == '__main__': unittest.main()
