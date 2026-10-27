"""Check that guest RCsc loads cannot become RCpc LDAPR on Apple Silicon.

Run with python3 tools/test_cpu_ordering.py. This checks the real CPU helpers
with RCpc enabled, where a C acquire load alone is insufficient for guest LDAR.
"""
import pathlib
import platform
import re
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "requires the Apple Silicon compiler target")
class CpuOrdering(unittest.TestCase):
    def test_store_load_ordering(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe = pathlib.Path(tmp) / 'ordering'
            subprocess.run(['clang', '-O2', '-march=armv8.3-a+rcpc', '-pthread',
                            '-I', str(root / 'runtime'),
                            str(root / 'tools/test_cpu_ordering.c'), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True, timeout=60)

    def test_rcsc_loads(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = '#include "cpu.h"\n'
        for bits in (8, 16, 32, 64):
            source += (f'__attribute__((noinline)) uint64_t acquire{bits}(uint64_t a) '
                       f'{{ return lda{bits}(a); }}\n'
                       f'__attribute__((noinline)) uint64_t exclusive{bits}(Cpu *c, uint64_t a) '
                       f'{{ return ldx{bits}(c, a); }}\n')
        with tempfile.TemporaryDirectory() as tmp:
            c = pathlib.Path(tmp) / 'loads.c'
            asm = pathlib.Path(tmp) / 'loads.s'
            c.write_text(source)
            subprocess.run(['clang', '-O2', '-march=armv8.3-a+rcpc', '-S',
                            '-I', str(root / 'runtime'), str(c), '-o', str(asm)], check=True)
            text = asm.read_text()
        self.assertNotRegex(text, r'\bldapr(?:b|h)?\b', 'RCpc loads weaken guest RCsc ordering')
        self.assertEqual(len(re.findall(r'\bldar(?:b|h)?\s', text)), 8,
                         'all four widths of both helper families must retain RCsc loads')


if __name__ == '__main__':
    unittest.main()
