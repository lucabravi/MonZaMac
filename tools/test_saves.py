"""Asset-free save import / export checks: python3 tools/test_saves.py.

The production save code runs against temporary files and real child processes.
CC defaults to clang; Linux ZIP checks use bsdtar (or the TAR environment variable).
"""
import ctypes as ct
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPAWN = ct.CFUNCTYPE(ct.c_ssize_t, ct.POINTER(ct.c_char_p), ct.c_char_p, ct.c_bool)
WAIT = ct.CFUNCTYPE(ct.c_int, ct.c_ssize_t, ct.c_bool)
BRIDGE = r'''
#include "platform.h"
const char *g_save_dir = "save";
static PlatProc (*start_cb)(const char *const *, const char *, bool);
static int (*wait_cb)(PlatProc, bool);
void test_init(PlatProc (*s)(const char *const *, const char *, bool), int (*w)(PlatProc, bool)) {
    start_cb = s; wait_cb = w;
}
PlatProc plat_spawn(const char *const *a, const char *l, bool append) { return start_cb(a, l, append); }
int plat_proc_wait(PlatProc p, bool block) { return wait_cb(p, block); }
'''


def synthetic_save(trainer):
    # A synthetic MyStatus block only; no game files, keys, or player data.
    status = bytearray(42)
    name = trainer.encode('utf-16-le')
    status[16:16 + len(name)] = name
    payload = bytearray(b'\x04' + struct.pack('<I', len(status)) + status)
    key = 0xE3E89BD1
    def step(value):
        value ^= (value << 2) & 0xFFFFFFFF
        value ^= value >> 15
        return value ^ ((value << 13) & 0xFFFFFFFF)
    state = key
    for _ in range(key.bit_count()): state = step(state)
    for i in range(len(payload)):
        payload[i] ^= (state >> (8 * (i % 4))) & 255
        if i % 4 == 3: state = step(state)
    block = struct.pack('<I', key) + payload
    pad = bytes.fromhex('a092d10607db32a1ae01f5c51e844fe353ca37f4a7b04da018b7c297da5f532b'
                        '75fa4816f8d48a6f6105f4e2fd04b5a30ffc4492cb')
    return bytes(a ^ b for a, b in zip(block, pad)) + bytes(32)


class SaveFiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='monzamac-save-build-')
        cls.addClassCleanup(cls.build.cleanup)
        build = Path(cls.build.name)
        bridge = build / 'bridge.c'; bridge.write_text(BRIDGE)
        library = build / 'saves.so'
        host = ['-U__linux__'] if sys.platform.startswith('linux') else []
        subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=gnu11', '-shared', '-fPIC',
                        *host, '-Iruntime', 'runtime/saves.c', 'runtime/save_info.c', str(bridge),
                        '-o', str(library)], cwd=ROOT, check=True)
        cls.lib = ct.CDLL(str(library))
        cls.lib.test_init.argtypes = [SPAWN, WAIT]
        cls.lib.saves_export.argtypes = [ct.c_char_p, ct.c_char_p]
        cls.lib.saves_export.restype = ct.c_bool
        cls.lib.saves_delete.argtypes = [ct.c_char_p]
        cls.lib.saves_delete.restype = ct.c_bool
        cls.lib.saves_copy.argtypes = [ct.c_char_p, ct.c_char_p]
        cls.lib.saves_copy.restype = ct.c_bool
        cls.lib.saves_select.argtypes = [ct.c_char_p]
        cls.lib.saves_current_path.restype = ct.c_char_p
        cls.lib.saves_route_replay_dir.argtypes = [ct.c_char_p]
        cls.lib.saves_route_replay_dir.restype = ct.c_char_p
        cls.lib.saves_route_begin.argtypes = [ct.c_char_p, ct.c_void_p, ct.c_size_t]
        cls.lib.saves_route_begin.restype = ct.c_bool

        cls.lib.saves_import_stage.argtypes = [ct.c_char_p, ct.c_void_p, ct.c_size_t]
        cls.lib.saves_import_stage.restype = ct.c_bool
        cls.lib.saves_import_cancel.argtypes = []
        cls.lib.save_info.argtypes = [ct.c_char_p]
        cls.lib.save_info.restype = ct.c_void_p

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='monzamac-saves-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        previous = Path.cwd(); os.chdir(self.root); self.addCleanup(os.chdir, previous)
        save = self.root / 'saves/Trainer/save_0'; save.mkdir(parents=True)
        (save / 'main').write_bytes(b'synthetic save bytes')
        self.fail_start = self.fail_write = False
        self.processes = {}
        self.callbacks = (SPAWN(self.spawn), WAIT(self.wait))
        self.lib.test_init(*self.callbacks)
        self.addCleanup(self.stop_children)

    def stop_children(self):
        for child in self.processes.values():
            if child.poll() is None: child.kill()
            child.wait()

    def spawn(self, argv, log, append):
        command = []; i = 0
        while argv[i]: command.append(os.fsdecode(argv[i])); i += 1
        if self.fail_start: return 0
        if self.fail_write:
            archive = command[command.index('-f') + 1]
            command = [sys.executable, '-c',
                       'import pathlib, sys; pathlib.Path(sys.argv[1]).write_bytes(b"partial archive"); sys.exit(1)',
                       archive]
        else:
            command[0] = os.environ.get('TAR') or (shutil.which('bsdtar') if sys.platform != 'darwin' else '/usr/bin/tar')
        try:
            child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, TypeError): return 0
        self.processes[child.pid] = child
        return child.pid

    def wait(self, pid, block):
        child = self.processes[pid]
        result = child.wait() if block else child.poll()
        if result is None: return -1
        del self.processes[pid]
        return result if result >= 0 else 255

    def export(self, path):
        return self.lib.saves_export(b'Trainer', os.fsencode(path))

    def import_folder(self, path):
        why = ct.create_string_buffer(256)
        result = self.lib.saves_import_stage(os.fsencode(path), why, len(why))
        self.why = why.value
        return result

    def test_short_route_path_leaves_no_half_created_route(self):
        self.lib.saves_select(b'Trainer')
        path = ct.create_string_buffer(4)
        self.assertFalse(self.lib.saves_route_begin(b'Recording', path, len(path)))
        self.assertFalse((self.root / 'routes/Recording').exists())

    def test_slot_ids_cannot_escape_saves_folder(self):
        # Delete / copy / export / replay all receive identifiers from elsewhere in the UI.
        outside = self.root / 'outside'; outside.mkdir()
        sentinel = outside / 'keep'; sentinel.write_text('preserve')
        self.assertFalse(self.lib.saves_delete(b'../outside'))
        self.assertFalse(self.lib.saves_copy(b'../outside', b'Copy'))
        self.assertFalse(self.lib.saves_export(b'../outside', os.fsencode(self.root / 'backup.zip')))
        self.lib.saves_select(b'../outside')
        self.assertEqual(self.lib.saves_current_path(), b'save')
        self.assertIsNone(self.lib.saves_route_replay_dir(b'../outside'))
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertFalse((self.root / 'saves/Copy').exists())

    def test_missing_source_copy_does_not_leave_target(self):
        self.assertFalse(self.lib.saves_copy(b'NoSuchSlot', b'Copy'))
        self.assertFalse((self.root / 'saves/Copy').exists())

    def test_sparse_import_cannot_overflow_total_size(self):
        source = self.root / 'sparse'; source.mkdir()
        (source / 'main').write_bytes(synthetic_save('Audit'))
        with (source / 'huge').open('wb') as output:
            output.truncate(1 << 30)
        self.assertFalse(self.import_folder(source))
        self.assertIn(b'too big', self.why)

    def test_import_rechecks_recreated_stage(self):
        source = self.root / 'input'; source.mkdir()
        main = source / 'main'; main.write_bytes(synthetic_save('Audit'))
        self.assertTrue(self.import_folder(source), self.why)
        staged = self.root / 'saves/.import/save_0/main'
        # Replacing the staging directory must not reuse its cached successful validation.
        self.lib.saves_import_cancel()
        main.write_bytes(b'invalid save bytes')
        self.assertFalse(self.import_folder(source), 'a malformed second import reused cached validation')
        self.assertIn(b'not a Pok', self.why)
        self.assertFalse(staged.exists())

    def test_save_card_refreshes_after_same_second_write(self):
        slot = self.root / 'card'; (slot / 'save_0').mkdir(parents=True)
        main = slot / 'save_0/main'
        main.write_bytes(synthetic_save('First'))
        second = 1700000000 * 1_000_000_000
        os.utime(main, ns=(second, second + 100))
        info = self.lib.save_info(os.fsencode(slot))
        self.assertTrue(info)
        self.assertEqual(ct.string_at(info), b'First')
        main.write_bytes(synthetic_save('Other'))
        os.utime(main, ns=(second, second + 200))
        info = self.lib.save_info(os.fsencode(slot))
        self.assertTrue(info)
        self.assertEqual(ct.string_at(info), b'Other')

    def test_failed_export_start_preserves_existing_archive(self):
        archive = self.root / 'backup.zip'; archive.write_bytes(b'previous archive')
        before = sorted(self.root.iterdir())
        self.fail_start = True
        self.assertFalse(self.export(archive))
        self.assertTrue(archive.exists(), 'failed export removed the previous archive')
        self.assertEqual(archive.read_bytes(), b'previous archive')
        self.assertEqual(sorted(self.root.iterdir()), before)

    def test_failed_export_write_preserves_existing_archive(self):
        archive = self.root / 'backup.zip'; archive.write_bytes(b'previous archive')
        before = sorted(self.root.iterdir())
        self.fail_write = True
        self.assertFalse(self.export(archive))
        self.assertEqual(archive.read_bytes(), b'previous archive')
        self.assertEqual(sorted(self.root.iterdir()), before)

    def test_completed_export_replaces_archive_with_a_zip(self):
        if sys.platform != 'darwin' and not (os.environ.get('TAR') or shutil.which('bsdtar')):
            self.skipTest('bsdtar is required to verify ZIP output on this host')
        archive = self.root / 'backup.zip'; archive.write_bytes(b'previous archive')
        before = sorted(self.root.iterdir())
        self.assertTrue(self.export(archive))
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.read('save_0/main'), b'synthetic save bytes')
        self.assertEqual(sorted(self.root.iterdir()), before)

    def test_failed_publication_keeps_destination_directory(self):
        if sys.platform != 'darwin' and not (os.environ.get('TAR') or shutil.which('bsdtar')):
            self.skipTest('bsdtar is required to finish the temporary ZIP')
        archive = self.root / 'backup.zip'; archive.mkdir()
        (archive / 'sentinel').write_bytes(b'keep')
        before = sorted(self.root.iterdir())
        self.assertFalse(self.export(archive))
        self.assertEqual((archive / 'sentinel').read_bytes(), b'keep')
        self.assertEqual(sorted(self.root.iterdir()), before)


if __name__ == '__main__': unittest.main()
