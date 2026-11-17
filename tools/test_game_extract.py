"""Asset-free package/import boundary checks: python3 tools/test_game_extract.py."""
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

import hashlib

from game_extract import (ImportFailure, Package, extract_nup, in_field, program_content, run_tool,
                          validate_extracted)

APP = 0x0100F43008C44000
BUILD = bytes.fromhex('b1f12fd919eae86a')


def nup_file(packages, compress=None):
    """A NUP v1 container. packages: (title id, kind, version, {name: bytes or {...}}); the tree's top level is the
    package's exefs / romfs folders. compress: packs files named *.trpfd with zstd (codec 1)."""
    pool = bytearray(); blob = bytearray(); dirs = []; files = []; children = []
    def name(s):
        raw = s.encode(); off = len(pool); pool.extend(raw); return off, len(raw)
    def add_dir(label, tree):
        me = len(dirs); dirs.append(None); kids = []
        for n, v in tree.items():
            if isinstance(v, dict): kids.append(('d', add_dir(n, v)))
            else:
                stored = compress(v) if compress and n.endswith('.trpfd') else v
                off = len(blob); blob.extend(stored); blob.extend(bytes(-len(blob) % 16))
                files.append((name(n), len(v), off, len(stored), hashlib.sha256(v).digest(), int(stored is not v)))
                kids.append(('f', len(files) - 1))
        dirs[me] = (name(label), kids)
        return me
    pkgs = []
    for title, kind, version, tree in packages:
        root = add_dir('', tree)
        sub = {dirs[i][0]: i for t, i in dirs[root][1] if t == 'd'}
        find = lambda label: next((i for (o, l), i in sub.items() if pool[o:o + l] == label), 0xFFFFFFFF)
        pkgs.append(struct.pack('<QIIIIBBHIQI20x', title, root, find(b'exefs'), find(b'romfs'), version, kind, 0, 0, 0, 0, 0))
    drec = b''
    for (noff, nlen), kids in dirs:
        drec += struct.pack('<IIIIQ', noff, nlen, len(children), len(kids), 0)
        children += [i if t == 'd' else len(dirs) + i for t, i in kids]
    fixed = 48 + len(pkgs) * 64 + len(dirs) * 24 + len(files) * 80
    pool_off = fixed + 4 * len(children)
    blob_off = (0x80 + pool_off + len(pool) + 15) & ~15
    frec = b''.join(struct.pack('<IIQQQ32sBBH12x', no, nl, size, blob_off + off, stored, sha, codec, 0, 0)
                    for (no, nl), size, off, stored, sha, codec in files)
    toc = struct.pack('<4sIQQQQQ', b'TOC\x01', len(pkgs), len(dirs), len(files), pool_off, len(pool), 0)
    toc += b''.join(pkgs) + drec + frec + struct.pack('<%dI' % len(children), *children) + pool
    header = struct.pack('<4sHHQQ32sQQII16s32s', b'NUP\x01', 0x80, 1, 0x80, len(toc), hashlib.sha256(toc).digest(),
                         blob_off, blob_off + len(blob), len(pkgs), 0, bytes(16), bytes(32))
    return header + toc + bytes(blob_off - 0x80 - len(toc)) + bytes(blob)


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

    def test_reads_a_nup_container(self):
        try:
            import zstandard
        except ImportError:
            self.skipTest('zstandard not installed')
        from nup import Nup, NupError
        main = bytes(64) + BUILD
        path = self.root / 'game.nup'
        path.write_bytes(nup_file([(APP, 0, 0, {'exefs': {'main': main}, 'romfs': {'arc': {'data.trpfd': b'hello'}}})],
                                  compress=zstandard.ZstdCompressor().compress))
        out = self.root / 'out'; out.mkdir()
        with Nup(path) as n:
            self.assertEqual((n.packages[0].title_id, n.packages[0].kind), (APP, 0))
            n.extract(n.packages[0].root_dir, out)
        self.assertEqual((out / 'exefs/main').read_bytes(), main)
        self.assertEqual((out / 'romfs/arc/data.trpfd').read_bytes(), b'hello')
        path.write_bytes(path.read_bytes()[:0x80] + b'X' + path.read_bytes()[0x81:])
        with self.assertRaises(NupError): Nup(path)

    def test_nup_names_cannot_leave_the_output(self):
        from nup import Nup, NupError
        for bad in ('..', '.', 'a/b', 'a\\b', 'a\0b'):
            path = self.root / 'bad.nup'
            path.write_bytes(nup_file([(APP, 0, 0, {'exefs': {bad: b'x'}})]))
            with self.assertRaises(NupError, msg=repr(bad)): Nup(path)

    def nup_game(self, packages):
        path = self.root / 'game.nup'; path.write_bytes(nup_file(packages))
        out = self.root / 'stage'; out.mkdir()
        free = mock.patch('game_extract.shutil.disk_usage', return_value=mock.Mock(free=1 << 40))  # (not the host's disk)
        free.start(); self.addCleanup(free.stop)
        return path, out

    def test_nup_import_applies_the_update_and_keeps_addons(self):
        exefs = {n: b'base' for n in ('main.npdm', 'rtld', 'sdk')}
        path, out = self.nup_game([
            (APP, 0, 0, {'exefs': dict(exefs, main=bytes(72)), 'romfs': {'arc': {'data.trpfd': b'v1'}, 'keep': b'k'}}),
            (APP, 1, 3, {'exefs': {'main': bytes(64) + BUILD}, 'romfs': {'arc': {'data.trpfd': b'v2'}}}),
            (APP, 1, 2, {'exefs': {'main': bytes(72)}}),   # (an older update: not the one applied)
            (APP + 0x1001, 2, 0, {'romfs': {'dlc.bin': b'd'}})])
        with contextlib.redirect_stdout(io.StringIO()):
            extract_nup(path, out, BUILD)
        self.assertEqual((out / 'exefs/main').read_bytes()[64:], BUILD)
        self.assertEqual((out / 'exefs/sdk').read_bytes(), b'base')
        self.assertEqual((out / 'romfs/arc/data.trpfd').read_bytes(), b'v2')
        self.assertEqual((out / 'romfs/keep').read_bytes(), b'k')
        self.assertEqual((out / 'aoc-tree' / ('%016x' % (APP + 0x1001)) / 'dlc.bin').read_bytes(), b'd')

    def test_nup_import_refuses_other_games_and_damaged_files(self):
        tree = {'exefs': {n: bytes(64) + BUILD for n in ('main', 'main.npdm', 'rtld', 'sdk')},
                'romfs': {'arc': {'data.trpfd': b'payload-payload'}}}
        path, out = self.nup_game([(APP + 0x10000, 0, 0, tree)])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ImportFailure) as e:
            extract_nup(path, out, BUILD)
        self.assertEqual(e.exception.code, 'game')
        data = bytearray(nup_file([(APP, 0, 0, tree)]))
        at = data.rindex(b'payload-payload'); data[at] ^= 1   # (one flipped bit in a file's content)
        path.write_bytes(data)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ImportFailure) as e:
            extract_nup(path, out, BUILD)
        self.assertEqual(e.exception.code, 'nup')
        self.assertEqual(sorted(p.name for p in out.iterdir()), [])   # nothing half-written is left behind

    def test_reads_the_addon_meta(self):
        import struct
        def cnmt(kind, ctype):
            head = struct.pack('<QIBxHH', 0x0100F43008C45002, 0, kind, 0, 1) + bytes(14)
            return head + bytes(32) + bytes([0xAB]) * 16 + bytes(6) + bytes([ctype, 0])
        from game_extract import addon_content
        self.assertEqual(addon_content(cnmt(0x82, 2)), (0x0100F43008C45002, 'ab' * 16 + '.nca'))
        self.assertIsNone(addon_content(cnmt(0x80, 1)))


if __name__ == '__main__': unittest.main()
