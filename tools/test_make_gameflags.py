"""Changing GENOPT must rebuild game objects and the runtime's matching identity.

Runs the real Makefile and compiler on synthetic C. No game assets, SDL or Apple
SDK are needed: only the two host-independent runtime objects are compiled.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GameFlags(unittest.TestCase):
    def test_changed_flags_recompile_and_unchanged_flags_reuse_objects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copyfile(ROOT / 'Makefile', root / 'Makefile')
            for name in ('runtime', 'tools'): (root / name).symlink_to(ROOT / name, target_is_directory=True)
            source = root / 'generated/main/main_000.c'; source.parent.mkdir(parents=True)
            source.write_text('int fixture_optimized(void) {\n#ifdef __OPTIMIZE__\nreturn 1;\n#else\nreturn 0;\n#endif\n}\n')
            probe = root / 'probe.c'; probe.write_text('int fixture_optimized(void); int main(void) { return fixture_optimized(); }\n')
            cc = shlex.split(os.environ.get('CC', 'clang'))
            cc[0] = shutil.which(cc[0]) or cc[0]
            host = ['-U__linux__'] if sys.platform.startswith('linux') else []
            make = shutil.which('gmake') or shutil.which('make')
            targets = ['gen-objs', 'build/rt/gamelib.o', 'build/rt/gamebuild.o']
            objects = [root / ('build/' + p) for p in ('obj/main/main_000.o', 'obj/tools/gamelib_entry.o',
                                                      'rt/gamelib.o', 'rt/gamebuild.o')]

            def build(opt):
                subprocess.run([make, '--no-print-directory', *targets, 'GENOPT=' + opt,
                                'CC=' + shlex.join(cc + host)], cwd=root, check=True, capture_output=True, text=True)
                return [p.stat().st_mtime_ns for p in objects]

            def optimized():
                exe = root / 'probe'
                subprocess.run(cc + [str(probe), str(objects[0]), '-o', str(exe)], check=True)
                return subprocess.run([str(exe)], check=False).returncode

            first = build('-O0')
            self.assertEqual(optimized(), 0)
            self.assertEqual(build('-O0'), first, 'an unchanged configuration must be a no-op')
            before = [p.read_bytes() for p in objects]
            build('-O2')
            self.assertEqual(optimized(), 1, 'make reused the object compiled with -O0')
            for path, old in zip(objects, before):
                self.assertNotEqual(path.read_bytes(), old, str(path.relative_to(root)) + ' kept the old flags or ID')
            warm = [p.stat().st_mtime_ns for p in objects]
            self.assertEqual(build('-O2'), warm, 'the new configuration must also become a no-op')


if __name__ == '__main__': unittest.main()
