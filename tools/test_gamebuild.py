"""Asset-free build scheduler checks with tiny generated C and a real compiler.

Only resource lookup, guarded deletion and process launching cross the test bridge.
The production scheduler performs generation, compilation, linking and publication.
Run with python3 tools/test_gamebuild.py (CC defaults to clang).
"""
import ctypes as ct
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = r'''
#include "platform.h"
#include <stdio.h>
#include <time.h>
#include <unistd.h>
static const char *resources;
static PlatProc (*start_cb)(const char *const *, const char *, bool);
static int (*wait_cb)(PlatProc, bool);
static void (*kill_cb)(PlatProc);
static bool (*remove_cb)(const char *, const char *);
void test_init(const char *r, PlatProc (*s)(const char *const *, const char *, bool),
               int (*w)(PlatProc, bool), void (*k)(PlatProc), bool (*d)(const char *, const char *)) {
    resources=r; start_cb=s; wait_cb=w; kill_cb=k; remove_cb=d;
}
bool rt_resource(const char *name, const char *dev, char *out, size_t n) {
    return snprintf(out,n,"%s/%s",resources,dev ? dev : name)<(int)n && !access(out,F_OK);
}
bool rt_dev_mode(void) { return false; }
bool rt_remove_game_file(const char *dir, const char *name) { return remove_cb(dir,name); }
uint64_t plat_now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
void plat_sleep_until_ns(uint64_t t) { uint64_t now=plat_now_ns(); if(t>now) { struct timespec d={(t-now)/1000000000,(t-now)%1000000000}; nanosleep(&d,NULL); } }
PlatProc plat_spawn(const char *const *a, const char *l, bool append) { return start_cb(a,l,append); }
int plat_proc_wait(PlatProc p, bool block) { return wait_cb(p,block); }
void plat_proc_kill(PlatProc p) { kill_cb(p); }
'''
GENERATOR = r'''
import pathlib, sys
name, source, base, out = sys.argv[1:5]
out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
(out / (name + '_000.c')).write_text('int ' + name + '_chunk(void) { return 7; }\n')
print(name + ': progress 1/1 files 1', flush=True)
(out / (name + '_table.c')).write_text('int ' + name + '_table(void) { return 11; }\n')
'''
SPAWN = ct.CFUNCTYPE(ct.c_ssize_t, ct.POINTER(ct.c_char_p), ct.c_char_p, ct.c_bool)
WAIT = ct.CFUNCTYPE(ct.c_int, ct.c_ssize_t, ct.c_bool)
KILL = ct.CFUNCTYPE(None, ct.c_ssize_t)
REMOVE = ct.CFUNCTYPE(ct.c_bool, ct.c_char_p, ct.c_char_p)


class Options(ct.Structure):
    _fields_ = [('progress', ct.c_void_p), ('jobs', ct.c_int)]


class BuildWorkspace(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        build = Path(cls.build.name)
        bridge = build / 'bridge.c'; bridge.write_text(BRIDGE)
        cls.cc = shlex.split(os.environ.get('CC', 'clang'))
        cls.cc[0] = shutil.which(cls.cc[0]) or cls.cc[0]
        library = build / 'scheduler.so'
        # This tests host-independent scheduling on Linux; the app itself targets macOS.
        host = ['-U__linux__'] if sys.platform.startswith('linux') else []
        subprocess.run(cls.cc + ['-std=gnu11', '-shared', '-fPIC', '-pthread', *host,
            '-Iruntime', '-DGAMELIB_CFLAGS="-O0 -fPIC"', '-DGAMELIB_SHARED="-shared"',
            'runtime/gamebuild.c', str(bridge), '-o', str(library)], cwd=ROOT, check=True)
        cls.library = ct.CDLL(str(library))
        cls.library.test_init.argtypes = [ct.c_char_p, SPAWN, WAIT, KILL, REMOVE]
        cls.library.gamebuild_run.argtypes = [ct.c_char_p, ct.POINTER(Options), ct.c_void_p, ct.c_size_t]
        cls.library.gamebuild_run.restype = ct.c_bool

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.resources = self.root / 'resources'
        (self.resources / 'runtime/hle').mkdir(parents=True)
        (self.resources / 'tools').mkdir()
        (self.resources / 'runtime/cpu.h').write_text('/* fixture */\n')
        (self.resources / 'runtime/hle/hle_symbols.txt').write_text('fixture\n')
        (self.resources / 'tools/gamelib_entry.c').write_text('int fixture_entry(void) { return 3; }\n')
        self.generator = self.root / 'generator.py'; self.generator.write_text(GENERATOR)
        self.game = self.root / 'game with spaces'; (self.game / 'exefs').mkdir(parents=True)
        self.processes = {}; self.launched = []; self.next_id = 0
        self.env = {name: os.environ.get(name) for name in ('LARECOMP_GEN', 'LARECOMP_CC',
                                                        'ZIG_GLOBAL_CACHE_DIR', 'ZIG_LOCAL_CACHE_DIR')}
        os.environ['LARECOMP_GEN'] = str(self.generator)
        os.environ['LARECOMP_CC'] = self.cc[0]
        self.addCleanup(self.restore_env)
        self.callbacks = (SPAWN(self.spawn), WAIT(self.wait), KILL(self.kill), REMOVE(self.remove))
        self.resource_bytes = os.fsencode(self.resources)
        self.library.test_init(self.resource_bytes, *self.callbacks)
        self.addCleanup(self.stop_children)

    def restore_env(self):
        for name, value in self.env.items():
            # C's setenv is not reflected in Python's os.environ mapping.
            if value is None:
                os.environ.pop(name, None); os.unsetenv(name)
            else: os.environ[name] = value

    def stop_children(self):
        for pid in list(self.processes): self.kill(pid)

    def remove(self, directory, name):
        path = Path(os.fsdecode(directory)) / os.fsdecode(name)
        # Match paths.c's refusal to follow an app-created path replaced by a link.
        if path.is_symlink(): return False
        try:
            if path.is_dir(): shutil.rmtree(path)
            else: path.unlink(missing_ok=True)
            return True
        except OSError: return False

    def spawn(self, argv, log, append):
        command = []; i = 0
        while argv[i]: command.append(os.fsdecode(argv[i])); i += 1
        self.launched.append(command.copy())
        if command[0] == str(self.generator): command.insert(0, sys.executable)
        try:
            with open(os.fsdecode(log), 'ab' if append else 'wb') as stream:
                child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError: return 0
        self.next_id += 1; self.processes[self.next_id] = child
        return self.next_id

    def wait(self, pid, block):
        child = self.processes[pid]
        result = child.wait() if block else child.poll()
        if result is None: return -1
        del self.processes[pid]
        return result if result >= 0 else 255

    def kill(self, pid):
        child = self.processes.pop(pid)
        if child.poll() is None: os.killpg(child.pid, signal.SIGKILL)
        child.wait()

    def run_build(self, game=None):
        why = ct.create_string_buffer(512)
        ok = self.library.gamebuild_run(os.fsencode(game or self.game), ct.byref(Options(None, 2)), why, len(why))
        self.why = why.value
        return ok

    def test_builds_and_cleans_tiny_sources(self):
        self.assertTrue(self.run_build(), self.why)
        output = next(self.game.glob('lasgame.*'))
        if output.suffix == '.id': output = Path(str(output)[:-3])
        result = ct.CDLL(str(output))
        self.assertEqual((result.main_chunk(), result.sdk_table(), result.fixture_entry()), (7, 11, 3))
        self.assertFalse((self.game / '.gamebuild').exists())

    def test_refuses_linked_workspace_without_starting_children(self):
        outside = self.root / 'outside'; outside.mkdir()
        (outside / 'sentinel').write_text('keep')
        (self.game / '.gamebuild').symlink_to(outside, target_is_directory=True)
        self.assertFalse(self.run_build())
        self.assertEqual(self.launched, [])
        self.assertEqual([p.name for p in outside.iterdir()], ['sentinel'])

    def test_missing_parent_does_not_start_children(self):
        self.assertFalse(self.run_build(self.root / 'missing/game'))
        self.assertEqual(self.launched, [])

    def test_refuses_linked_identity_file_without_overwriting_it(self):
        outside = self.root / 'outside'; outside.write_text('keep')
        name = 'lasgame.dylib.id' if sys.platform == 'darwin' else 'lasgame.so.id'
        (self.game / name).symlink_to(outside)
        self.assertFalse(self.run_build())
        self.assertEqual(outside.read_text(), 'keep')
        self.assertEqual(self.launched, [])

    def test_zig_receives_existing_absolute_cache(self):
        zig = self.resources / 'zig/zig'; zig.parent.mkdir()
        # Exercise the launch contract fixed upstream for Zig's cache. The tiny
        # fixture uses the installed C compiler; this is not a Zig execution test.
        zig.write_text('#!' + sys.executable + '\n' +
            'import os, pathlib, subprocess, sys\n'
            'for name in ("ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR"):\n'
            '    path = pathlib.Path(os.environ.get(name, ""))\n'
            '    if not path.is_absolute() or not path.is_dir():\n'
            '        sys.exit("cache directory must exist and be absolute")\n'
            'sys.exit(subprocess.call(' + repr(self.cc) + ' + sys.argv[2:]))\n')
        zig.chmod(0o700)
        del os.environ['LARECOMP_CC']
        previous = Path.cwd(); os.chdir(self.root); self.addCleanup(os.chdir, previous)
        self.assertTrue(self.run_build(self.game.name), self.why)


if __name__ == '__main__': unittest.main()
