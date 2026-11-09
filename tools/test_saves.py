"""Asset-free save export failure checks: python3 tools/test_saves.py.

The production save code runs against temporary files and real child processes.
CC defaults to clang; Linux ZIP checks use bsdtar (or the TAR environment variable).
"""
import ctypes as ct
import os
from pathlib import Path
import shlex
import shutil
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
